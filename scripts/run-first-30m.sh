#!/usr/bin/env bash
# xtrace/verboseを止め、環境変数や入力したキーをログへ流さない。
set +xv
set -euo pipefail
umask 077
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
dry_run=false
rerun=false
case "${1:-}" in
  '') ;;
  --dry-run) dry_run=true ;;
  --rerun) rerun=true ;;
  *) die '使い方: bash scripts/run-first-30m.sh [--dry-run | --rerun]' ;;
esac
[ "$#" -le 1 ] || die '引数が多すぎます。'
bash "$ROOT/scripts/build-request.sh"
jq -r '"動画: \(.videoUrl)\nモデル: \(.model)\n範囲: \(.startOffset)〜\(.endOffset)\n方式: \(.processingMode)（既定のStatic処理）\n出力上限: \(.maxOutputTokens)"' \
  "$ROOT/config/viteconf-2026.json"
if "$dry_run"; then
  printf 'ドライラン完了。API通信・キー入力は行っていません。\n'
  exit 0
fi
require curl
mkdir -p "$ROOT/.local/responses" "$ROOT/.local/logs" "$ROOT/.local/runs"
lock="$ROOT/.local/first-30m.lock"
mkdir "$lock" 2>/dev/null || die '他の実行中、または中断後のロックが残っています。READMEをご確認ください。'
cleanup() { unset GEMINI_API_KEY; rmdir "$lock" 2>/dev/null || true; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
if [ -f "$ROOT/.local/logs/first-30m-run.json" ] && ! "$rerun"; then
  die '過去の実行記録があります。先にレスポンスを確認してください。意図的な再実行のみ --rerun を指定できます。'
fi
if [ -z "${GEMINI_API_KEY:-}" ]; then
  if ! { exec 3<>/dev/tty; } 2>/dev/null; then
    die 'APIキーがありません。ご自身のターミナルで bash scripts/run-first-30m.sh を実行してください。'
  fi
  printf 'Gemini APIキー（非表示）: ' >&3
  IFS= read -r -s GEMINI_API_KEY <&3 || die 'キーを読み取れませんでした。'
  printf '\n' >&3
  exec 3>&-
fi
[ -n "${GEMINI_API_KEY:-}" ] || die 'APIキーが空です。'
# ヘッダーへの改行注入やcurl設定としての解釈を防ぐ。
case "$GEMINI_API_KEY" in *[!a-zA-Z0-9_-]*) die 'APIキーの形式を確認してください（空白・改行は使用できません）。' ;; esac
run_dir=$(mktemp -d "$ROOT/.local/runs/$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
cp "$ROOT/requests/first-30m.json" "$run_dir/request.json"
cp "$ROOT/config/viteconf-2026.json" "$run_dir/config.json"
cp "$ROOT/prompts/gemini-talk-analysis.md" "$run_dir/prompt.md"
request_hash=$(sha256 "$run_dir/request.json")
prompt_hash=$(sha256 "$run_dir/prompt.md")
model=$(jq -r .model "$run_dir/config.json")
endpoint="https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent"
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# 送信前にも記録を残す。接続中断時の無意識な再送を防ぐ。
jq -n --arg started "$started" --arg id "$(basename "$run_dir")" \
  '{runId:$id,startedAt:$started,state:"started"}' > "$ROOT/.local/logs/first-30m-run.json"
printf '1リクエストを送信します。自動再試行・継続リクエストはありません。\n'
curl_exit=0
# -qを最初に指定し、個人の.curlrcによるverbose/trace/retryを無効化。
# キーはstdinから渡すため、curlのプロセス引数・ディスクに含まれない。
# curlプロセスの環境からもキーを除外する。
http_status=$(printf 'header = "x-goog-api-key: %s"\n' "$GEMINI_API_KEY" | \
  (unset GEMINI_API_KEY; exec curl -q --config - --silent --show-error \
    --proto '=https' --connect-timeout 30 --max-time 1200 --retry 0 \
    --output "$run_dir/response.json" --write-out '%{http_code}' \
    --header 'Content-Type: application/json' \
    --data-binary "@$run_dir/request.json" "$endpoint") \
    2> "$run_dir/curl.stderr") || curl_exit=$?
unset GEMINI_API_KEY
finished=$(date -u +%Y-%m-%dT%H:%M:%SZ)
case "$http_status" in [0-9][0-9][0-9]) ;; *) http_status=000 ;; esac
jq -n --slurpfile config "$run_dir/config.json" \
  --arg id "$(basename "$run_dir")" --arg started "$started" --arg finished "$finished" \
  --arg hash "$request_hash" --arg promptHash "$prompt_hash" \
  --argjson http "$((10#$http_status))" --argjson curlExit "$curl_exit" '
  {runId:$id,startedAt:$started,finishedAt:$finished,state:"returned",
   httpStatus:$http,curlExit:$curlExit,requestSha256:$hash,promptSha256:$promptHash,
   config:$config[0]}' > "$run_dir/run.json"
[ -f "$run_dir/response.json" ] || : > "$run_dir/response.json"
cp "$run_dir/response.json" "$ROOT/.local/responses/first-30m.json"
cp "$run_dir/run.json" "$ROOT/.local/logs/first-30m-run.json"
cp "$run_dir/curl.stderr" "$ROOT/.local/logs/first-30m-curl.stderr"
printf 'HTTP %s / curl終了コード %s\n' "$http_status" "$curl_exit"
bash "$ROOT/scripts/extract-report.sh"
