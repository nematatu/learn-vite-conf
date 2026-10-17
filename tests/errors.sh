#!/usr/bin/env bash
# エラーの意味による分類と処理方針を、ネットワークなしで検証します。
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/viteconf-errors.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
passed=0
check() {
  local name=$1 expected=$2 stop=$3 http=$4 curl_exit=$5 response=$6 valid=${7:-true}
  local context
  context=$(jq -nc --argjson http "$http" --argjson curl "$curl_exit" --argjson valid "$valid" \
    '{phase:"analysis",talk:"fixture",start:60,end:1800,model:"gemini-3.8-flash",
      httpStatus:$http,curlExit:$curl,responseValid:$valid}')
  printf '%s\n' "$response" | jq --argjson context "$context" --arg localCategory "" \
    -f "$ROOT/scripts/classify-error.jq" > "$tmp/result.json"
  if ! jq -e --arg category "$expected" --argjson stop "$stop" \
    '.category==$category and .stopRun==$stop and (.summary|length)>0 and (.action|length)>0 and
      .phase=="analysis" and .start==60 and .end==1800' "$tmp/result.json" >/dev/null; then
    printf 'FAIL: %s\n' "$name"
    cat "$tmp/result.json"
    exit 1
  fi
  passed=$((passed+1))
}
check key_on_400 authentication true 400 0 '{"error":{"status":"INVALID_ARGUMENT","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"API_KEY_INVALID"}]}}'
check auth_401 authentication true 401 0 '{}'
check permission permission_denied true 403 0 '{"error":{"status":"PERMISSION_DENIED"}}'
check payment billing_required true 402 0 '{}'
check zero_quota quota_unavailable true 429 0 '{"error":{"details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{"quotaId":"PerDay","quotaValue":"0"}]}]}}'
check daily daily_quota true 429 0 '{"error":{"details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{"quotaId":"GenerateRequestsPerDay"}]}]}}'
check minute rate_limit true 429 0 '{"error":{"details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{"quotaId":"GenerateTokensPerMinute"}]}]}}'
check reason_rate rate_limit true 429 0 '{"error":{"details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"RATE_LIMIT_EXCEEDED"}]}}'
check ambiguous_429 resource_exhausted true 429 0 '{"error":{"status":"RESOURCE_EXHAUSTED","message":"Quota exceeded"}}'
check input_tokens input_token_limit false 400 0 '{"error":{"status":"INVALID_ARGUMENT","message":"The input token count (2000000) exceeds the maximum number of tokens allowed (1048576)."}}'
jq -e '.basis=="message_inference"' "$tmp/result.json" >/dev/null
check not_every_400_is_tokens invalid_request true 400 0 '{"error":{"status":"INVALID_ARGUMENT","message":"Invalid request format","details":[{"@type":"type.googleapis.com/google.rpc.BadRequest","fieldViolations":[{"field":"contents[0]","description":"invalid"}]}]}}'
jq -e '.fieldViolations[0].field=="contents[0]"' "$tmp/result.json" >/dev/null
check unknown_token_field invalid_request true 400 0 '{"error":{"status":"INVALID_ARGUMENT","message":"Unknown field input_token_limit"}}'
check inaccessible_video media_unavailable true 400 0 '{"error":{"message":"Unable to access YouTube video"}}'
check not_found resource_not_found true 404 0 '{"error":{"status":"NOT_FOUND"}}'
check precondition failed_precondition true 400 0 '{"error":{"status":"FAILED_PRECONDITION"}}'
check internal service_error false 500 0 '{}'
check unavailable service_error false 503 0 '{"error":{"status":"UNAVAILABLE"}}'
check server_timeout server_timeout false 504 0 '{}'
check unknown_api unknown_api_error true 418 0 '{"error":{"message":"unrecognized error"}}'
check timeout network_timeout false 0 28 '{}'
check dns dns_error true 0 6 '{}'
check connection connection_failed true 0 7 '{}'
check certificate tls_error true 0 60 '{}'
check disk local_io_error true 0 23 '{}'
check other_transport transport_error true 0 56 '{}'
check invalid_json invalid_response false 200 0 '{}' false
check max_tokens output_token_limit false 200 0 '{"candidates":[{"finishReason":"MAX_TOKENS"}],"usageMetadata":{"thoughtsTokenCount":20}}'
jq -e '.usage.thoughtsTokenCount==20' "$tmp/result.json" >/dev/null
check continuation continuation_required false 200 0 '{"candidates":[{"finishReason":"CONTINUATION"}]}'
check safety content_blocked false 200 0 '{"candidates":[{"finishReason":"SAFETY"}]}'
check recitation content_blocked false 200 0 '{"candidates":[{"finishReason":"RECITATION"}]}'
check prompt_block content_blocked false 200 0 '{"promptFeedback":{"blockReason":"SAFETY"}}'
check no_candidates missing_candidate false 200 0 '{}'
check extra_candidates unexpected_candidates false 200 0 '{"candidates":[{},{}]}'
check unknown_finish unexpected_finish false 200 0 '{"candidates":[{"finishReason":"OTHER"}]}'
check empty_text empty_output false 200 0 '{"candidates":[{"finishReason":"STOP","content":{"parts":[{"thought":true,"text":"thought only"},{"text":" \n"}]}}]}'
check retry_hint resource_exhausted true 429 0 '{"error":{"details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"12.5s"}]}}'
jq -e '.retryDelay=="12.5s"' "$tmp/result.json" >/dev/null
check sanitized unknown_api_error true 418 0 '{"error":{"message":"bad \u001b[31m key=secret-value and token=private-value"}}'
if grep -E 'secret-value|private-value' "$tmp/result.json" >/dev/null; then exit 1; fi
printf 'PASS: エラー分類%sケース（原因・処理方針・根拠・対象区間・未知エラー・機密除外）\n' "$passed"
