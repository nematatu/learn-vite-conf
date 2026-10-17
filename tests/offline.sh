#!/usr/bin/env bash
# 実APIに接続せず、通信回数・終了条件・抽出・秘密情報の扱いを検証します。
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
command -v jq >/dev/null
tmp=$(mktemp -d "${TMPDIR:-/tmp}/viteconf-offline.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
# このモックは外部通信をしません。
[ "$1" = '-q' ] || exit 91
[ -z "${GEMINI_API_KEY+x}" ] || exit 92
IFS= read -r header
[ "$header" = 'header = "x-goog-api-key: offline-test-key"' ] || exit 93
printf 'call\n' >> "$OFFLINE_TEST_STATE/calls"
out=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    *offline-test-key*) exit 94 ;;
    --output) out=$2; shift ;;
  esac
  shift
done
cp "$OFFLINE_TEST_STATE/fixture.json" "$out"
printf '%s' "${OFFLINE_TEST_HTTP:-200}"
exit "${OFFLINE_TEST_CURL_EXIT:-0}"
MOCK
chmod +x "$tmp/bin/curl"
cat > "$tmp/base.json" <<'JSON'
{
  "modelVersion": "gemini-3.8-flash",
  "candidates": [{"finishReason":"STOP","content":{"parts":[
    {"thought":true,"text":"PRIVATE_THOUGHT_MARKER"},
    {"text":"# オフライン検証用\n\n前半", "thoughtSignature":"PRIVATE_SIGNATURE_MARKER"},
    {"text":"と後半。\n"}
  ]}}],
  "usageMetadata": {
    "promptTokenCount":100,"candidatesTokenCount":30,"thoughtsTokenCount":20,"totalTokenCount":150,
    "promptTokensDetails":[{"modality":"VIDEO","tokenCount":70},{"modality":"AUDIO","tokenCount":10}]
  }
}
JSON
new_case() {
  case_root="$tmp/$1"
  mkdir -p "$case_root"
  cp -R "$ROOT/scripts" "$ROOT/config" "$ROOT/prompts" "$case_root/"
  cp "$tmp/base.json" "$case_root/fixture.json"
}
run_case() {
  GEMINI_API_KEY=offline-test-key PATH="$tmp/bin:$PATH" \
    OFFLINE_TEST_STATE="$case_root" OFFLINE_TEST_HTTP="${test_http:-200}" \
    OFFLINE_TEST_CURL_EXIT="${test_exit:-0}" \
    bash "$case_root/scripts/run-first-30m.sh" "$@" > "$case_root/output.log" 2>&1
}
assert_one_call() { [ "$(wc -l < "$case_root/calls" | tr -d ' ')" = 1 ]; }

for script in "$ROOT"/scripts/*.sh "$ROOT"/tests/*.sh; do bash -n "$script"; done
new_case dry
run_case --dry-run
[ ! -e "$case_root/calls" ]
jq -e --rawfile prompt "$case_root/prompts/gemini-talk-analysis.md" '
  .contents[0].parts[1].text == $prompt and
  .contents[0].parts[0].videoMetadata == {startOffset:"0s",endOffset:"1800s"} and
  .contents[0].parts[0].fileData.fileUri == "https://www.youtube.com/watch?v=PfyIEgLzNYI" and
  .generationConfig.maxOutputTokens == 32768
' "$case_root/requests/first-30m.json" >/dev/null
printf 'PASS: 構文・ドライラン・区間・プロンプト全文\n'

new_case success
run_case
assert_one_call
jq -e '.verification.transport == "complete_response" and
  .verification.videoCrossCheck == "not_performed" and
  .videoInputTokenCount == 70 and .promptTokenCount == 100 and
  .thoughtsTokenCount == 20 and .finishReasons == ["STOP"] and
  .httpStatus == 200 and .curlExit == 0' \
  "$case_root/notes/first-30-minutes.metadata.json" >/dev/null
[[ "$(cat "$case_root/notes/first-30-minutes.md")" == *'前半と後半。'* ]]
if /usr/bin/grep -R -E 'PRIVATE_THOUGHT_MARKER|PRIVATE_SIGNATURE_MARKER' "$case_root/notes" >/dev/null; then exit 1; fi
# 既存の応答は明示しない限り再送しない。再抽出では通信しない。
if run_case; then exit 1; fi
assert_one_call
bash "$case_root/scripts/extract-report.sh" >/dev/null
assert_one_call
run_case --rerun
[ "$(wc -l < "$case_root/calls" | tr -d ' ')" = 2 ]
[ "$(find "$case_root/.local/runs" -name run.json | wc -l | tr -d ' ')" = 2 ]
# 送信JSONの改変を見逃さない。
run_id=$(jq -r .runId "$case_root/.local/logs/first-30m-run.json")
printf '\n' >> "$case_root/.local/runs/$run_id/request.json"
if bash "$case_root/scripts/extract-report.sh" > /dev/null 2>&1; then exit 1; fi
printf 'PASS: 正常抽出・思考/署名の除外・1回送信・再送防止・実行履歴・ハッシュ照合\n'

for scenario in max_tokens continuation empty blocked api_error whitespace multiple http_error timeout invalid_json; do
  new_case "$scenario"
  test_http=200
  test_exit=0
  case "$scenario" in
    max_tokens) filter='.candidates[0].finishReason = "MAX_TOKENS"' ;;
    continuation) filter='.candidates[0].finishReason = "CONTINUATION"' ;;
    empty) filter='.candidates = []' ;;
    blocked) filter='.promptFeedback.blockReason = "SAFETY"' ;;
    api_error) filter='.error = {code:400,message:"PRIVATE_ERROR_MARKER"}' ;;
    whitespace) filter='.candidates[0].content.parts = [{text:" \n\t"}]' ;;
    multiple) filter='.candidates += .candidates' ;;
    http_error) filter='.'; test_http=429 ;;
    timeout) filter='.'; test_exit=28; test_http=000 ;;
    invalid_json) filter='.' ;;
  esac
  jq "$filter" "$tmp/base.json" > "$case_root/fixture.json"
  if [ "$scenario" = invalid_json ]; then printf 'not json\n' > "$case_root/fixture.json"; fi
  mkdir -p "$case_root/notes"
  printf '既存ノートを保護\n' > "$case_root/notes/first-30-minutes.md"
  if run_case; then printf 'FAIL: %s\n' "$scenario"; exit 1; fi
  assert_one_call
  [ "$(cat "$case_root/notes/first-30-minutes.md")" = '既存ノートを保護' ]
  [ -e "$case_root/.local/responses/first-30m.json" ]
  if [ "$scenario" != invalid_json ]; then
    [ -e "$case_root/.local/reports/first-30m.metadata.json" ]
    if /usr/bin/grep -q PRIVATE_ERROR_MARKER "$case_root/.local/reports/first-30m.metadata.json"; then exit 1; fi
  fi
done
printf 'PASS: 打ち切り・継続・空本文・ブロック・API/HTTPエラー・タイムアウト・不正JSONで公開ノートを保護\n'

new_case missing_usage
test_http=200
test_exit=0
jq 'del(.usageMetadata)' "$tmp/base.json" > "$case_root/fixture.json"
run_case
jq -e '.promptTokenCount == null and .videoInputTokenCount == null and
  .totalTokenCount == null' "$case_root/notes/first-30-minutes.metadata.json" >/dev/null
printf 'PASS: 未返却の使用量をnullとして保持\n'

for scenario in full_video bad_model bad_mode bad_tokens missing_end; do
  new_case "$scenario"
  case "$scenario" in
    full_video) filter='.endOffset="36000s"' ;;
    bad_model) filter='.model="another-model"' ;;
    bad_mode) filter='.processingMode="AGENTIC"' ;;
    bad_tokens) filter='.maxOutputTokens=65536' ;;
    missing_end) filter='del(.endOffset)' ;;
  esac
  jq "$filter" "$case_root/config/viteconf-2026.json" > "$case_root/config/invalid.json"
  mv "$case_root/config/invalid.json" "$case_root/config/viteconf-2026.json"
  if run_case --dry-run; then exit 1; fi
  [ ! -e "$case_root/calls" ]
done
# キーを引数・保存ファイルへ含めていないことを検査。
if /usr/bin/grep -R -l 'offline-test-key' "$tmp" --exclude=curl >/dev/null; then
  printf 'FAIL: 検証用キーが保存ファイルへ漏れています。\n'; exit 1
fi
printf 'PASS: 全編送信・モデル/方式変更・過大出力・区間欠落を拒否、キーの非保存\n'
printf 'すべてのオフライン検証が成功しました（実API未実行）。\n'
