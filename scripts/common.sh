#!/usr/bin/env bash
# Bash 3.2以上。呼び出し側で set -euo pipefail を指定すること。
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

die() { printf '%s\n' "$*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || die "必要なコマンドがありません: $1"; }
sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

validate_config() {
  require jq
  require shasum
  jq -e '
    .schemaVersion == 1 and
    .methodologyVersion == "static-video-metadata-v1" and
    .model == "gemini-3.8-flash" and
    .videoUrl == "https://www.youtube.com/watch?v=PfyIEgLzNYI" and
    .processingMode == "STATIC" and
    (.startOffset | type == "string" and test("^(0|[1-9][0-9]*)s$")) and
    (.endOffset | type == "string" and test("^(0|[1-9][0-9]*)s$")) and
    (.startOffset | rtrimstr("s") | tonumber) >= 0 and
    (.endOffset | rtrimstr("s") | tonumber) <= 1800 and
    ((.startOffset | rtrimstr("s") | tonumber) < (.endOffset | rtrimstr("s") | tonumber)) and
    (.maxOutputTokens | type == "number" and floor == . and . > 0 and . <= 32768)
  ' "$ROOT/config/viteconf-2026.json" >/dev/null ||
    die '設定が不正です。対応範囲は指定動画・指定モデル・Static・最初の1800秒以内です。'
  [ -s "$ROOT/prompts/gemini-talk-analysis.md" ] || die 'プロンプトが空です。'
}
