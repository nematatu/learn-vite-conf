#!/usr/bin/env bash
# 動画メタデータ・Gemini・Gitをモック化して自動ワークフローを検証します。
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/viteconf-offline.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/yt-dlp" <<'MOCK'
#!/usr/bin/env bash
printf '{"id":"PfyIEgLzNYI","title":"Offline fixture","duration":4000,"chapters":null}\n'
MOCK
cat > "$tmp/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = '-q' ]
[ -z "${GEMINI_API_KEY+x}" ]
out=''
request=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output|-o) out=$2; shift ;;
    --data-binary) request=${2#@}; shift ;;
    *offline-test-key*) exit 99 ;;
  esac
  shift
done
if [ -z "$request" ]; then
  printf '<html><script>ignore me</script><p>Evan You - Agentic Era</p><p>Alice - Second talk</p></html>\n' > "$out"
  printf '%s' "${OFFLINE_SCHEDULE_HTTP:-200}"
  exit 0
fi
IFS= read -r header
[ "$header" = 'header = "x-goog-api-key: offline-test-key"' ]
start=$(jq -r '.contents[0].parts[0].videoMetadata.startOffset|rtrimstr("s")' "$request")
end=$(jq -r '.contents[0].parts[0].videoMetadata.endOffset|rtrimstr("s")' "$request")
[ "$((end-start))" -le 1800 ]
if jq -e '.generationConfig.responseFormat' "$request" >/dev/null; then
  printf 'discover %s %s\n' "$start" "$end" >> "$OFFLINE_STATE/calls"
  case "$start" in
    0) content='{"segments":[{"start":0,"end":60,"kind":"other","key":"welcome","speaker":"Host","title":"Welcome","evidence":"Welcome slide"},{"start":60,"end":1800,"kind":"talk","key":"evan-agentic-era","speaker":"Evan You","title":"Agentic Era","evidence":"Evan slide"}]}' ;;
    1800) content='{"segments":[{"start":1800,"end":2000,"kind":"talk","key":"evan-agentic-era","speaker":"Evan You","title":"Agentic Era","evidence":"Evan continues"},{"start":2000,"end":3600,"kind":"talk","key":"second-talk","speaker":"Alice","title":"Second talk","evidence":"Alice slide"}]}' ;;
    3600) content='{"segments":[{"start":3600,"end":3900,"kind":"talk","key":"second-talk","speaker":"Alice","title":"Second talk","evidence":"Alice continues"},{"start":3900,"end":4000,"kind":"other","key":"closing","speaker":"Host","title":"Closing","evidence":"Closing slide"}]}' ;;
    *) exit 90 ;;
  esac
  if [ "${OFFLINE_INVALID_DISCOVERY:-0}" = 1 ]; then
    content=$(printf '%s' "$content" | jq '.segments[0].end=99999')
  fi
else
  printf 'analyze %s %s\n' "$start" "$end" >> "$OFFLINE_STATE/calls"
  if [ "$start" = "${OFFLINE_ERROR_START:--1}" ]; then
    cp "$OFFLINE_ERROR_RESPONSE" "$out"
    printf '%s' "$OFFLINE_ERROR_HTTP"
    exit "${OFFLINE_ERROR_CURL:-0}"
  fi
  # 原文プロンプトを省略せず含むことも確認。
  jq -e --rawfile p "$OFFLINE_STATE/prompts/gemini-talk-analysis.md" \
    '.contents[0].parts[1].text|startswith($p)' "$request" >/dev/null
  content="# テスト専用解析 ${start}-${end}"
  if [ "$start" = "${OFFLINE_FAIL_START:--1}" ]; then
    printf '{"error":{"code":500}}' > "$out"
    printf 500
    exit 0
  fi
fi
jq -n --arg content "$content" --arg reason "${OFFLINE_FINISH:-STOP}" \
  '{candidates:[{finishReason:$reason,content:{parts:[
    {thought:true,text:"PRIVATE_THOUGHT"},{text:$content,thoughtSignature:"PRIVATE_SIGNATURE"}
  ]}}],usageMetadata:{promptTokenCount:100,candidatesTokenCount:30,thoughtsTokenCount:20,totalTokenCount:150}}' > "$out"
printf 200
MOCK
cat > "$tmp/bin/git" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OFFLINE_STATE/git-calls"
if [ "${OFFLINE_GIT_FAIL:-0}" = 1 ] && [ "${3:-}" = push ]; then
  printf 'offline git push rejected\n' >&2
  exit 1
fi
exit 0
MOCK
chmod +x "$tmp/bin/"*
new_case() {
  project="$tmp/$1"
  mkdir -p "$project"
  cp -R "$ROOT/scripts" "$ROOT/config" "$ROOT/prompts" "$project/"
}
run_case() {
  GEMINI_API_KEY=offline-test-key PATH="$tmp/bin:$PATH" OFFLINE_STATE="$project" \
    OFFLINE_FAIL_START="${fail_start:--1}" OFFLINE_FINISH="${finish:-STOP}" \
    OFFLINE_INVALID_DISCOVERY="${invalid:-0}" \
    OFFLINE_ERROR_START="${error_start:--1}" OFFLINE_ERROR_RESPONSE="${error_response:-}" \
    OFFLINE_ERROR_HTTP="${error_http:-200}" OFFLINE_ERROR_CURL="${error_curl:-0}" \
    OFFLINE_SCHEDULE_HTTP="${schedule_http:-200}" OFFLINE_GIT_FAIL="${git_fail:-0}" \
    bash "$project/scripts/run.sh" "$@" > "$project/output.log" 2>&1
}
for script in "$ROOT"/scripts/*.sh "$ROOT"/tests/*.sh; do bash -n "$script"; done
new_case pipeline
run_case all --dry-run
[ ! -e "$project/calls" ]
run_case test
[ "$(wc -l < "$project/calls" | tr -d ' ')" = 2 ]
[ -e "$project/notebooklm/viteconf-2026/60-evan-agentic-era.md" ]
[ ! -e "$project/notes/viteconf-2026/talks/0-welcome" ]
# 本番の長さはテスト上限を超える。allでは自動識別・結合・分割して全登壇へ進む。
fail_start=3800
if run_case all; then exit 1; fi
jq -e '.failedParts==1 and .coveredUntil==4000 and .state=="partial_failure"' \
  "$project/notes/viteconf-2026/status.json" >/dev/null
[ ! -e "$project/notebooklm/viteconf-2026/2000-second-talk.md" ]
[ ! -e "$project/notes/viteconf-2026/talks/60-evan-agentic-era/part-000060-001800.md" ]
# 同じコマンドで成功したAPI応答を再利用し、失敗した一部分だけを再送。
count_before=$(wc -l < "$project/calls" | tr -d ' ')
fail_start=-1
run_case all --push
count_after=$(wc -l < "$project/calls" | tr -d ' ')
[ "$((count_after-count_before))" = 1 ]
[ -s "$project/git-calls" ]
[ -e "$project/notebooklm/viteconf-2026/2000-second-talk.md" ]
jq -e '.complete==true and .parts==2' "$project/notes/viteconf-2026/talks/60-evan-agentic-era/status.json" >/dev/null
jq -e '.failedParts==0 and .coveredUntil==4000' "$project/notes/viteconf-2026/status.json" >/dev/null
# 重複実行はAPI再送なし。自動出力は外部の相対リンクなしで読める資料。
run_case all
[ "$(wc -l < "$project/calls" | tr -d ' ')" = "$count_after" ]
grep -q 'テスト専用解析 60-1860' "$project/notebooklm/viteconf-2026/60-evan-agentic-era.md"
grep -q 'テスト専用解析 1860-2000' "$project/notebooklm/viteconf-2026/60-evan-agentic-era.md"
if grep -R -E 'PRIVATE_THOUGHT|PRIVATE_SIGNATURE' "$project/notes" "$project/notebooklm" >/dev/null; then exit 1; fi
printf 'PASS: Evanテスト→全編自動識別→講演の結合・分割→自動保存・索引・NotebookLM出力\n'
printf 'PASS: 部分失敗の表示・完成ソースからの除外・未完了分だけ再開・完了分の再送なし・Git公開経路\n'
new_case invalid_timeline
invalid=1
if run_case test; then exit 1; fi
[ ! -e "$project/notebooklm/viteconf-2026/60-evan-agentic-era.md" ]
invalid=0
run_case test
[ -e "$project/notebooklm/viteconf-2026/60-evan-agentic-era.md" ]
printf 'PASS: 区間外の識別時刻を拒否し、次回に修復可能\n'
new_case truncated
finish=MAX_TOKENS
if run_case test; then exit 1; fi
[ ! -e "$project/notebooklm/viteconf-2026/60-evan-agentic-era.md" ]
finish=STOP
new_case scope
jq '.maxSegmentSeconds=36000' "$project/config/viteconf-2026.json" > "$project/config/invalid.json"
mv "$project/config/invalid.json" "$project/config/viteconf-2026.json"
if run_case all; then exit 1; fi
[ ! -e "$project/calls" ]
if grep -R -l 'offline-test-key' "$tmp" --exclude=curl >/dev/null; then exit 1; fi
printf 'PASS: 出力打ち切り・巨大入力の拒否・思考情報/署名/キーの非公開\n'

# APIの意味から分類し、出力だけでなく実際に継続/停止することを検証。
new_case auth_error
error_start=60
error_http=400
error_response="$tmp/auth.json"
cat > "$error_response" <<'JSON'
{"error":{"code":400,"status":"INVALID_ARGUMENT","message":"Invalid key: offline-test-key\u001b[31m","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"API_KEY_INVALID"}]}}
JSON
if run_case all; then exit 1; fi
jq -e '.[0].category=="authentication" and .[0].stopRun==true and .[0].start==60 and .[0].end==1860' \
  "$project/notes/viteconf-2026/errors.json" >/dev/null
[ "$(grep -c '^analyze ' "$project/calls")" = 1 ]
grep -q 'APIキーの認証に失敗' "$project/output.log"
grep -q '\[REDACTED\]' "$project/output.log"
if grep -R 'offline-test-key' "$project/output.log" "$project/notes" >/dev/null; then exit 1; fi
# 詳細はローカルにのみ残し、公開用JSONには生の返却文を混ぜない。
if grep -q 'apiMessage' "$project/notes/viteconf-2026/errors.json"; then exit 1; fi
jq -e '.state=="stopped_on_error"' "$project/notes/viteconf-2026/status.json" >/dev/null
new_case token_error
error_start=60
error_http=200
error_response="$tmp/tokens.json"
printf '{"candidates":[{"finishReason":"MAX_TOKENS","content":{"parts":[{"text":"unfinished"}]}}],"usageMetadata":{"thoughtsTokenCount":10}}\n' > "$error_response"
if run_case all; then exit 1; fi
jq -e '.[0].category=="output_token_limit" and .[0].stopRun==false' "$project/notes/viteconf-2026/errors.json" >/dev/null
grep -q '生成が指定のトークン上限で打ち切られました' "$project/output.log"
[ ! -e "$project/notebooklm/viteconf-2026/60-evan-agentic-era.md" ]
[ -e "$project/notebooklm/viteconf-2026/2000-second-talk.md" ]
error_start=-1
run_case all
jq -e 'length==0' "$project/notes/viteconf-2026/errors.json" >/dev/null
new_case quota_error
error_start=60
error_http=429
error_response="$tmp/quota.json"
cat > "$error_response" <<'JSON'
{"error":{"status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{"quotaId":"GenerateRequestsPerDay","quotaMetric":"generate_content_free_tier_requests"}]},{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"42s"}]}}
JSON
if run_case all; then exit 1; fi
jq -e '.[0].category=="daily_quota" and .[0].retryDelay=="42s"' "$project/notes/viteconf-2026/errors.json" >/dev/null
[ "$(grep -c '^analyze ' "$project/calls")" = 1 ]
grep -q 'APIが返した待機時間: 42s' "$project/output.log"
new_case network_error
error_start=60
error_http=000
error_curl=6
if run_case all; then exit 1; fi
jq -e '.[0].category=="dns_error" and .[0].curlExit==6' "$project/notes/viteconf-2026/errors.json" >/dev/null
error_start=-1
error_curl=0
new_case schedule_error
schedule_http=503
if run_case test; then exit 1; fi
[ ! -e "$project/calls" ]
jq -e '.[0].category=="schedule_fetch" and .[0].httpStatus==503' "$project/notes/viteconf-2026/errors.json" >/dev/null
schedule_http=200
new_case publication_error
git_fail=1
if run_case test --push; then exit 1; fi
[ -e "$project/notebooklm/viteconf-2026/60-evan-agentic-era.md" ]
jq -e '.[0].category=="publication_failed"' "$project/notes/viteconf-2026/errors.json" >/dev/null
jq -e '.publication=="failed"' "$project/notes/viteconf-2026/status.json" >/dev/null
printf 'PASS: 認証/日次枠/DNSで後続停止、打ち切り理由・待機時間を表示、機密除外、復旧時にエラーを更新、取得/公開の失敗を明示\n'
printf 'すべてのオフライン検証が成功しました。実Gemini解析は未実行です。\n'
