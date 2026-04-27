#!/usr/bin/env bash
# Verify AWS_BEARER_TOKEN_BEDROCK works against the configured model.
# Independent of the app - just a curl test of the Converse API.
#
# Usage:
#   source .env && ./scripts/test-bedrock-creds.sh
# or
#   AWS_BEARER_TOKEN_BEDROCK=ABSK... BEDROCK_MODEL_ID=us.anthropic.claude-sonnet-4-5-20250929-v1:0 ./scripts/test-bedrock-creds.sh
#
# Exit codes:
#   0  - success, model returned a response
#   1  - missing env var
#   2  - HTTP error from Bedrock
set -euo pipefail

: "${AWS_BEARER_TOKEN_BEDROCK:?Required: set AWS_BEARER_TOKEN_BEDROCK in .env}"
: "${BEDROCK_MODEL_ID:=us.anthropic.claude-sonnet-4-5-20250929-v1:0}"
: "${AWS_REGION:=us-east-1}"

echo "Region:   ${AWS_REGION}"
echo "Model ID: ${BEDROCK_MODEL_ID}"
echo "Token:    ${AWS_BEARER_TOKEN_BEDROCK:0:6}... (length ${#AWS_BEARER_TOKEN_BEDROCK})"
echo

URL="https://bedrock-runtime.${AWS_REGION}.amazonaws.com/model/${BEDROCK_MODEL_ID}/converse"

response_file=$(mktemp)
trap 'rm -f "${response_file}"' EXIT

http_code=$(curl -sS -o "${response_file}" -w "%{http_code}" -X POST "${URL}" \
    -H "Authorization: Bearer ${AWS_BEARER_TOKEN_BEDROCK}" \
    -H "Content-Type: application/json" \
    -d '{
        "messages": [{"role":"user","content":[{"text":"Reply with exactly: OK"}]}],
        "inferenceConfig": {"maxTokens": 20}
    }')

echo "HTTP ${http_code}"
if command -v jq >/dev/null 2>&1; then
    jq . < "${response_file}" || cat "${response_file}"
else
    cat "${response_file}"
fi

if [[ "${http_code}" != "200" ]]; then
    echo
    echo "FAILED. Common causes:"
    echo "  401/403 - bearer token wrong or expired"
    echo "  400 with 'inference profile' - model needs a us.* / global.* profile prefix"
    echo "  400 with 'access' - model access not enabled in Bedrock console for this account/region"
    exit 2
fi

echo
echo "OK: Bedrock bearer-token auth is working."
