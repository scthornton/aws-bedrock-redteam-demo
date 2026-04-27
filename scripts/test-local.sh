#!/usr/bin/env bash
# Smoke-test the running demo app at $BASE_URL (default http://127.0.0.1:8080).
# Hits every endpoint, asserts shape, and exits non-zero on the first failure.
#
# Usage:
#   source .env && ./scripts/test-local.sh
#   BASE_URL=http://1.2.3.4:8080 ./scripts/test-local.sh
set -euo pipefail

: "${DEMO_API_KEY:?Required: set DEMO_API_KEY in .env}"
: "${BASE_URL:=http://127.0.0.1:8080}"

pass() { printf "  \033[32mPASS\033[0m %s\n" "$*"; }
fail() { printf "  \033[31mFAIL\033[0m %s\n" "$*"; exit 1; }
section() { printf "\n=== %s ===\n" "$*"; }

curl_json() {
    # curl_json METHOD PATH [DATA]  - fails fast on non-2xx, returns JSON on stdout
    local method="$1" path="$2" data="${3:-}"
    local args=(-sS -X "$method" -H "Authorization: Bearer ${DEMO_API_KEY}" -H "Content-Type: application/json")
    if [[ -n "$data" ]]; then args+=(-d "$data"); fi
    curl "${args[@]}" "${BASE_URL}${path}"
}

section "1. /healthz"
health=$(curl -sS "${BASE_URL}/healthz")
echo "$health" | jq .
echo "$health" | jq -e '.status == "ok"' >/dev/null && pass "status=ok" || fail "status not ok"
echo "$health" | jq -e '.bedrock_reachable == true' >/dev/null && pass "bedrock reachable" || fail "bedrock not reachable"

section "2. /v1/models requires auth"
status=$(curl -sS -o /dev/null -w "%{http_code}" "${BASE_URL}/v1/models")
[[ "$status" == "401" ]] && pass "401 without bearer" || fail "expected 401, got $status"

section "3. /v1/models with auth"
models=$(curl_json GET "/v1/models")
echo "$models" | jq .
echo "$models" | jq -e '.data | length >= 1' >/dev/null && pass "at least one model returned" || fail "no models"

section "4. benign /v1/chat/completions"
benign=$(curl_json POST "/v1/chat/completions" \
    '{"model":"any","messages":[{"role":"user","content":"Reply with exactly: pong"}],"max_tokens":20}')
echo "$benign" | jq '{model, finish_reason: .choices[0].finish_reason, usage}'
echo "$benign" | jq -e '.choices[0].message.content | length > 0' >/dev/null \
    && pass "model returned content" || fail "no content in response"
echo "$benign" | jq -e '.choices[0].finish_reason == "stop"' >/dev/null \
    && pass "finish_reason=stop" || fail "unexpected finish_reason"
echo "$benign" | jq -e '.usage.prompt_tokens > 0 and .usage.completion_tokens > 0' >/dev/null \
    && pass "usage tokens present" || fail "usage tokens missing"

section "5. /v1/chat/completions with empty body"
status=$(curl -sS -o /dev/null -w "%{http_code}" -X POST \
    -H "Authorization: Bearer ${DEMO_API_KEY}" -H "Content-Type: application/json" \
    -d '{}' "${BASE_URL}/v1/chat/completions")
[[ "$status" == "400" ]] && pass "400 on empty messages" || fail "expected 400, got $status"

printf "\n\033[32mAll smoke tests passed.\033[0m  (BASE_URL=%s)\n" "$BASE_URL"
