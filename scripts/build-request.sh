#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
[ "$#" -eq 0 ] || die '使い方: bash scripts/build-request.sh'
validate_config
mkdir -p "$ROOT/requests"
tmp=$(mktemp "$ROOT/requests/.first-30m.XXXXXX")
trap 'rm -f "$tmp"' EXIT
jq -n --slurpfile cfg "$ROOT/config/viteconf-2026.json" \
  --rawfile prompt "$ROOT/prompts/gemini-talk-analysis.md" '
  $cfg[0] as $c | {
    contents: [{parts: [
      {fileData: {fileUri: $c.videoUrl, mimeType: "video/*"},
       videoMetadata: {startOffset: $c.startOffset, endOffset: $c.endOffset}},
      {text: $prompt}
    ]}],
    generationConfig: {maxOutputTokens: $c.maxOutputTokens}
  }' > "$tmp"
jq -e --rawfile prompt "$ROOT/prompts/gemini-talk-analysis.md" \
  --slurpfile cfg "$ROOT/config/viteconf-2026.json" '
    .contents[0].parts[1].text == $prompt and
    .contents[0].parts[0].videoMetadata.startOffset == $cfg[0].startOffset and
    .contents[0].parts[0].videoMetadata.endOffset == $cfg[0].endOffset and
    .contents[0].parts[0].fileData.fileUri == $cfg[0].videoUrl
  ' "$tmp" >/dev/null
mv "$tmp" "$ROOT/requests/first-30m.json"
printf '生成・検証完了: requests/first-30m.json（API通信なし）\n'
