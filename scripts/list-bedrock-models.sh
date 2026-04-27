#!/usr/bin/env bash
# List Anthropic models and inference profiles available on the current AWS account.
# Use this to pick a value for BEDROCK_MODEL_ID in .env.
#
# Requires: aws CLI authenticated via SSO/IAM (sigv4). Independent of the bearer token.
set -euo pipefail

: "${AWS_REGION:=us-east-1}"

echo "=== Models with ON_DEMAND throughput (use modelId directly) ==="
aws bedrock list-foundation-models \
    --region "${AWS_REGION}" \
    --by-provider Anthropic \
    --by-output-modality TEXT \
    --query 'modelSummaries[?contains(inferenceTypesSupported, `ON_DEMAND`)].[modelId,modelName]' \
    --output table

echo
echo "=== Inference profiles (use these for Sonnet/Opus 4.x models) ==="
aws bedrock list-inference-profiles \
    --region "${AWS_REGION}" \
    --type-equals SYSTEM_DEFINED \
    --query 'inferenceProfileSummaries[?contains(inferenceProfileId, `claude`)].[inferenceProfileId,inferenceProfileName,status]' \
    --output table
