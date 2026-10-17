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

# request.jsonを唯一の送信原本とし、同じモデル・内容の正常応答を再利用します。
generate() {
  local request=$1 hash http rc started finished
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
    printf '応答未完了: HTTP %s / curl %s。記録: %s\n' "$http" "$rc" "$JOB" >&2
    # 認証・割当エラーでは残りを送っても同じ失敗になり得るため停止。
    case "$http" in 401|403|429) die '認証・利用枠エラーのため追加送信を止めました。';; esac
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
