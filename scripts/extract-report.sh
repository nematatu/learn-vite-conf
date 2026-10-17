#!/usr/bin/env bash
set -euo pipefail
umask 077
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
[ "$#" -eq 0 ] || die '使い方: bash scripts/extract-report.sh'
require jq
require shasum
manifest="$ROOT/.local/logs/first-30m-run.json"
[ -f "$manifest" ] || die '実行記録がありません。先に実行スクリプトをご利用ください。'
id=$(jq -er '.runId | select(type == "string") | select(test("^[A-Za-z0-9.]+$"))' "$manifest") || die '実行IDが不正です。'
run_dir="$ROOT/.local/runs/$id"
response="$run_dir/response.json"
[ -f "$run_dir/run.json" ] && [ -f "$response" ] || die '実行が中断されたか、保存データが不十分です。自動再送は行いません。'
cmp -s "$manifest" "$run_dir/run.json" || die '実行記録の対応が不一致です。'
[ "$(sha256 "$run_dir/request.json")" = "$(jq -r .requestSha256 "$manifest")" ] || die '送信リクエストのハッシュが不一致です。'
mkdir -p "$ROOT/.local/reports"
if ! jq -e 'type == "object"' "$response" >/dev/null 2>&1; then
  die 'レスポンスがJSONオブジェクトではありません。ローカルの生レスポンスとcurlログをご確認ください。'
fi
# 認証情報、任意のエラーメッセージ、thoughtSignature等をコピーしない。
jq -n --slurpfile run "$manifest" --slurpfile response "$response" '
  def count: if type == "number" and . >= 0 and floor == . then . else null end;
  $run[0] as $m | $response[0] as $r |
  {
    runId:$m.runId,startedAt:$m.startedAt,finishedAt:$m.finishedAt,
    requestedModel:$m.config.model,
    modelVersion:($r.modelVersion | if type == "string" and test("^gemini-[a-zA-Z0-9._-]+$") then . else null end),
    videoUrl:$m.config.videoUrl,startOffset:$m.config.startOffset,endOffset:$m.config.endOffset,
    processingMode:$m.config.processingMode,methodologyVersion:$m.config.methodologyVersion,
    maxOutputTokens:$m.config.maxOutputTokens,
    requestSha256:$m.requestSha256,promptSha256:$m.promptSha256,
    httpStatus:$m.httpStatus,curlExit:$m.curlExit,
    hasApiError:($r.error != null),apiErrorCode:($r.error.code | count),
    finishReasons:[$r.candidates[]?.finishReason | if type == "string" and test("^[A-Z_]+$") then . else "UNKNOWN" end],
    promptTokenCount:($r.usageMetadata.promptTokenCount | count),
    candidatesTokenCount:($r.usageMetadata.candidatesTokenCount | count),
    thoughtsTokenCount:($r.usageMetadata.thoughtsTokenCount | count),
    totalTokenCount:($r.usageMetadata.totalTokenCount | count),
    videoInputTokenCount:([$r.usageMetadata.promptTokensDetails[]? |
      select(.modality == "VIDEO") | .tokenCount | count | select(. != null)] |
      if length > 0 then add else null end),
    verification:{transport:"pending",videoCrossCheck:"not_performed",publicationReview:"pending"}
  }' > "$ROOT/.local/reports/first-30m.metadata.json"
if ! jq -e '.httpStatus == 200 and .curlExit == 0' "$manifest" >/dev/null || \
   ! jq -e '
     .error == null and .promptFeedback.blockReason == null and
     (.candidates | type == "array" and length == 1) and
     .candidates[0].finishReason == "STOP" and
     ([.candidates[0].content.parts[]? | select(.thought != true) |
       .text? | select(type == "string")] | join("") | test("\\S"))
   ' "$response" >/dev/null; then
  # 打ち切り内容も失わずローカル保存。公開ノートを上書きしない。
  jq -r '[.candidates[]?.content.parts[]? | select(.thought != true) |
    .text? | select(type == "string")] | join("")' "$response" \
    > "$ROOT/.local/reports/first-30m.incomplete.md"
  die '完全な応答の条件を満たしていません。メタデータと不完全な本文は.local/reports/へ保存しました。APIの自動再実行・公開ノート更新は行いません。'
fi
tmp=$(mktemp "$ROOT/.local/reports/.report.XXXXXX")
trap 'rm -f "$tmp"' EXIT
{
  printf '<!-- AI_GENERATED_UNVERIFIED: 元動画との照合・公開前レビューが必要です。 -->\n\n'
  printf '> Geminiが生成した未検証の解析です。本文中の「確認済み」はモデルの自己申告であり、人による照合済みを意味しません。\n'
  printf '> 実行条件・トークン数: [メタデータ](first-30-minutes.metadata.json)\n\n'
  jq -r '[.candidates[0].content.parts[]? | select(.thought != true) |
    .text? | select(type == "string")] | join("")' "$response"
} > "$tmp"
jq '.verification.transport = "complete_response"' "$ROOT/.local/reports/first-30m.metadata.json" \
  > "$ROOT/.local/reports/first-30m.metadata.complete.json"
mkdir -p "$ROOT/notes"
mv "$tmp" "$ROOT/notes/first-30-minutes.md"
cp "$ROOT/.local/reports/first-30m.metadata.complete.json" "$ROOT/notes/first-30-minutes.metadata.json"
printf '本文を省略せず抽出しました: notes/first-30-minutes.md\n'
printf 'API応答条件を満たしました。映像との照合・技術内容・引用範囲のレビューは未実施です。自動コミット・pushは行いません。\n'
