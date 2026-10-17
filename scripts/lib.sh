#!/usr/bin/env bash
# scripts/run.shから読み込みます。Bash 3.2以上。
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
die() { printf '%s\n' "$*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || die "必要なコマンドがありません: $1"; }
sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

init() {
  require jq; require curl; require shasum
  CONFIG="$ROOT/config/viteconf-2026.json"
  jq -e '
    (.eventId | test("^[a-z0-9]+(-[a-z0-9]+)*$")) and
    (.videoUrl | test("^https://www.youtube.com/watch\\?v=[A-Za-z0-9_-]+$")) and
    (.scheduleUrl | startswith("https://")) and
    (.model | test("^gemini-[a-zA-Z0-9._-]+$")) and
    (.maxSegmentSeconds | type == "number" and floor == . and . > 0 and . <= 1800) and
    (.maxOutputTokens | type == "number" and floor == . and . > 0 and . <= 32768) and
    (.discoveryOutputTokens | type == "number" and floor == . and . > 0 and . <= 32768) and
    (.test.maxSeconds | type == "number" and floor == . and . > 0 and . <= 1800) and
    (.test.speaker | type == "string" and length > 0)
  ' "$CONFIG" >/dev/null || die '設定が不正です。1リクエストの動画入力は最大1800秒です。'
  event=$(jq -r .eventId "$CONFIG")
  video=$(jq -r .videoUrl "$CONFIG")
  model=$(jq -r .model "$CONFIG")
  chunk=$(jq -r .maxSegmentSeconds "$CONFIG")
  CACHE="$ROOT/.local/$event"
  OUT="$ROOT/notes/$event"
  EXPORT="$ROOT/notebooklm/$event"
}

get_key() {
  if [ -z "${GEMINI_API_KEY:-}" ]; then
    if ! { exec 3<>/dev/tty; } 2>/dev/null; then
      die 'APIキーがありません。ご自身のターミナルから実行して非表示入力してください。'
    fi
    printf 'Gemini APIキー（非表示）: ' >&3
    IFS= read -r -s GEMINI_API_KEY <&3 || die 'キーを読み取れませんでした。'
    printf '\n' >&3
    exec 3>&-
  fi
  [ -n "${GEMINI_API_KEY:-}" ] || die 'APIキーが空です。'
  case "$GEMINI_API_KEY" in *[!a-zA-Z0-9_-]*) die 'APIキーの形式が不正です。' ;; esac
}

# エラーの分類結果・根拠・次の対応を保存し、利用者にも同じ内容を示します。
report_error() {
  local phase=$1 talk=$2 start=$3 end=$4 http=$5 rc=$6 response=$7
  local category=${8:-} log=${9:-} context classified valid=false parsed
  mkdir -p "$CACHE" "$OUT"
  parsed="$WORK/error-response.json"
  if [ -f "$response" ] && jq -s -e 'length==1 and (.[0]|type=="object")' "$response" >/dev/null 2>&1; then
    # 形式がJSONでもフィールド型が異なるケースは分類器で不正応答に落とします。
    jq . "$response" > "$parsed"
    valid=true
  else
    printf '{}\n' > "$parsed"
  fi
  context=$(jq -n --arg phase "$phase" --arg talk "$talk" --arg model "$model" \
    --argjson start "$start" --argjson end "$end" --argjson http "$http" \
    --argjson rc "$rc" --argjson valid "$valid" \
    '{phase:$phase,talk:$talk,start:$start,end:$end,model:$model,
      httpStatus:$http,curlExit:$rc,responseValid:$valid}')
  if ! classified=$(jq --argjson context "$context" --arg localCategory "$category" \
    -f "$ROOT/scripts/classify-error.jq" "$parsed" 2> "$WORK/classifier.stderr"); then
    # 予期しない型の応答でも、分類器自体の失敗でエラーを隠さない。
    context=$(printf '%s' "$context" | jq '.responseValid=false')
    classified=$(printf '{}' | jq --argjson context "$context" --arg localCategory "" \
      -f "$ROOT/scripts/classify-error.jq")
  fi
  # キーをjqの引数へ渡さず、返却文中に含まれていた場合も表示・要約前に伏せます。
  if [ -n "${GEMINI_API_KEY:-}" ]; then
    classified=${classified//"$GEMINI_API_KEY"/[REDACTED]}
  fi
  printf '%s\n' "$classified" > "$WORK/last-error.json"
  jq -c . "$WORK/last-error.json" >> "$CACHE/errors.jsonl"
  if [ "$phase" = discovery ] || jq -e .stopRun "$WORK/last-error.json" >/dev/null; then
    STOP_RUN=true
  fi
  printf '\n' >&2
  jq -r '"エラー [\(.category)]\n工程: \(.phase) / 登壇: \(.talk)",
    (if .start==null or .end==null then "対象区間: なし" else "元動画: \(.start)〜\(.end)秒" end),
    "原因: \(.summary)\n次の対応: \(.action)\nHTTP: \(.httpStatus) / curl: \(.curlExit)",
    (if .apiStatus!="" then "APIステータス: " + .apiStatus else empty end),
    (if .finishReason!="" then "finishReason: " + .finishReason else empty end),
    (if .blockReason!="" then "blockReason: " + .blockReason else empty end),
    "判定根拠: " + ({api_status_or_reason:"APIステータスまたは構造化された理由",api_status:"APIステータス",http_status:"HTTPステータス",
      quota_details:"返却された割当の詳細",message_inference:"APIメッセージの文言からの判断（推定）",curl_exit:"curl終了コード",
      finish_reason:"生成の終了理由",block_or_finish_reason:"ブロック情報または終了理由",response_validation:"応答の形式・本文検査",
      local_validation:"ローカルでの検証",unclassified:"原因を特定できる情報なし"}[.basis] // .basis),
    (if .apiMessage!="" then "APIの返却文: " + .apiMessage else empty end),
    (if (.reasons|length)>0 then "APIの理由: " + (.reasons|join(", ")) else empty end),
    (.quotaViolations[] | "割当: " + .quotaId + " / " + .quotaMetric + " / " + .description),
    (.fieldViolations[] | "不正なフィールド: " + .field + " / " + .description),
    (if .retryDelay!=null then "APIが返した待機時間: " + .retryDelay else empty end),
    (if .finishMessage!="" then "終了メッセージ: " + .finishMessage else empty end),
    (if .usage.totalTokenCount!=null or .usage.thoughtsTokenCount!=null then
      "返却された使用量: 入力=" + (.usage.promptTokenCount|tostring) +
      " / 出力=" + (.usage.candidatesTokenCount|tostring) +
      " / 思考=" + (.usage.thoughtsTokenCount|tostring) +
      " / 合計=" + (.usage.totalTokenCount|tostring) + "（nullは不明）" else empty end)
  ' "$WORK/last-error.json" >&2
  if "$STOP_RUN"; then
    printf '処理方針: 追加のAPI送信を停止します。自動再送はしません。\n' >&2
  else
    printf '処理方針: この区間を未完了にし、他の区間の処理を続けます。自動再送はしません。\n' >&2
  fi
  [ -z "$log" ] || printf '詳細記録: %s\n' "$log" >&2
  write_error_summary
  if [ "$phase" = source ]; then
    printf '{"state":"source_failed","errorsFile":"errors.json"}\n' > "$OUT/status.json"
  fi
}

write_error_summary() {
  [ -f "$CACHE/errors.jsonl" ] || return 0
  # APIの生メッセージやプロジェクト固有情報は公開用の要約へコピーしません。
  jq -s 'map({category,summary,action,stopRun,basis,phase,talk,start,end,
    httpStatus,curlExit,apiStatus,finishReason,blockReason,retryDelay})' \
    "$CACHE/errors.jsonl" > "$OUT/errors.json"
}

# request.jsonを唯一の送信原本とし、同じモデル・内容の正常応答を再利用します。
generate() {
  local request=$1 phase=$2 talk=$3 start=$4 end=$5 hash http rc started finished
  hash=$( { printf '%s\n' "$model"; cat "$request"; } | shasum -a 256 | awk '{print $1}')
  JOB="$CACHE/jobs/$hash"
  mkdir -p "$JOB"
  cp "$request" "$JOB/request.json"
  if [ -s "$JOB/result.txt" ] && [ -s "$JOB/metadata.json" ] &&
    jq -e '.status == "complete"' "$JOB/metadata.json" >/dev/null; then
    return 0
  fi
  started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # エラー時もこのディレクトリに要求・応答・HTTP・日時を残します。
  rc=0
  http=$(printf 'header = "x-goog-api-key: %s"\n' "$GEMINI_API_KEY" |
    (unset GEMINI_API_KEY; exec curl -q --config - --silent --show-error \
      --proto '=https' --connect-timeout 30 --max-time 1200 --retry 0 \
      --output "$JOB/response.json" --write-out '%{http_code}' \
      --header 'Content-Type: application/json' --data-binary "@$JOB/request.json" \
      "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent") \
      2> "$JOB/curl.stderr") || rc=$?
  finished=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  case "$http" in [0-9][0-9][0-9]) ;; *) http=000 ;; esac
  jq -n --arg started "$started" --arg finished "$finished" --arg model "$model" \
    --arg hash "$hash" --arg requestHash "$(sha256 "$request")" \
    --argjson http "$((10#$http))" --argjson rc "$rc" \
    '{startedAt:$started,finishedAt:$finished,model:$model,jobId:$hash,
      requestSha256:$requestHash,httpStatus:$http,curlExit:$rc,status:"failed"}' > "$JOB/metadata.json"
  if [ "$http" != 200 ] || [ "$rc" -ne 0 ] ||
    ! jq -e '.error == null and .promptFeedback.blockReason == null and
      (.candidates | type == "array" and length == 1) and
      .candidates[0].finishReason == "STOP" and
      ([.candidates[0].content.parts[]? | select(.thought != true) |
        .text? | select(type == "string")] | join("") | test("\\S"))' \
      "$JOB/response.json" >/dev/null 2>&1; then
    report_error "$phase" "$talk" "$start" "$end" "$((10#$http))" "$rc" "$JOB/response.json" "" "$JOB"
    cp "$WORK/last-error.json" "$JOB/error.json"
    jq --slurpfile issue "$JOB/error.json" '.error=$issue[0]' "$JOB/metadata.json" > "$JOB/metadata.tmp"
    mv "$JOB/metadata.tmp" "$JOB/metadata.json"
    return 1
  fi
  jq -r '[.candidates[0].content.parts[]? | select(.thought != true) |
    .text? | select(type == "string")] | join("")' "$JOB/response.json" > "$JOB/result.txt"
  jq --slurpfile response "$JOB/response.json" '
    def count: if type == "number" and . >= 0 and floor == . then . else null end;
    .status="complete" | .finishReason="STOP" |
    .promptTokenCount=($response[0].usageMetadata.promptTokenCount | count) |
    .candidatesTokenCount=($response[0].usageMetadata.candidatesTokenCount | count) |
    .thoughtsTokenCount=($response[0].usageMetadata.thoughtsTokenCount | count) |
    .totalTokenCount=($response[0].usageMetadata.totalTokenCount | count) |
    .videoInputTokenCount=([$response[0].usageMetadata.promptTokensDetails[]? |
      select(.modality=="VIDEO") | .tokenCount | count | select(. != null)] |
      if length > 0 then add else null end)
  ' "$JOB/metadata.json" > "$JOB/metadata.tmp"
  mv "$JOB/metadata.tmp" "$JOB/metadata.json"
}

make_request() {
  local start=$1 end=$2 prompt=$3 output=$4
  [ "$end" -gt "$start" ] && [ "$((end-start))" -le "$chunk" ] || die '動画区間が不正です。'
  jq -n --arg video "$video" --arg start "${start}s" --arg end "${end}s" \
    --rawfile prompt "$prompt" --argjson tokens "$(jq -r .maxOutputTokens "$CONFIG")" \
    '{contents:[{parts:[{fileData:{fileUri:$video,mimeType:"video/*"},
      videoMetadata:{startOffset:$start,endOffset:$end}},{text:$prompt}]}],
      generationConfig:{maxOutputTokens:$tokens}}' > "$output"
}
