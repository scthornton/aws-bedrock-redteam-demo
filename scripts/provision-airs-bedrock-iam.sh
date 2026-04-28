#!/usr/bin/env bash
# Provision an IAM user with the minimum permissions AIRS Red Teaming needs to
# call Bedrock directly, then print the access key, secret key, and region for
# paste-in to the AIRS UI (Targets > AWS Bedrock connection).
#
# What this creates:
#   - IAM user:    airs-redteam-bedrock-demo
#   - IAM policy:  airs-redteam-bedrock-invoke (inline)
#                  bedrock:InvokeModel + bedrock:InvokeModelWithResponseStream
#                  on the Claude inference profile and underlying foundation
#                  models in us-east-1.
#   - One access key for the user.
#
# Why a dedicated IAM user: AIRS stores the access key + secret in its own
# tenancy. Use a scoped, demo-only IAM user so the credential pasted into AIRS
# can be rotated and audited independently of your console SSO.
#
# Idempotent. Safe to re-run; if the user exists it just re-prints the policy
# state and creates a fresh access key (max 2 per user; old ones will need to
# be deactivated/deleted manually if you have stale ones).
#
# Cleanup: ./scripts/provision-airs-bedrock-iam.sh --destroy

set -euo pipefail

USER_NAME="${USER_NAME:-airs-redteam-bedrock-demo}"
POLICY_NAME="${POLICY_NAME:-airs-redteam-bedrock-invoke}"
REGION="${REGION:-us-east-1}"
MODEL_ID="${MODEL_ID:-us.anthropic.claude-sonnet-4-5-20250929-v1:0}"

log() { echo "[$(date +%H:%M:%S)] $*" >&2; }

if [[ "${1:-}" == "--destroy" ]]; then
    log "Destroying IAM user ${USER_NAME}"
    for k in $(aws iam list-access-keys --user-name "${USER_NAME}" \
                 --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null || true); do
        log "  deleting access key ${k}"
        aws iam delete-access-key --user-name "${USER_NAME}" --access-key-id "${k}" || true
    done
    aws iam delete-user-policy --user-name "${USER_NAME}" --policy-name "${POLICY_NAME}" 2>/dev/null || true
    aws iam delete-user --user-name "${USER_NAME}" 2>/dev/null || true
    log "Destroy complete."
    exit 0
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
log "Account: ${ACCOUNT_ID}  Region: ${REGION}"
log "Target model: ${MODEL_ID}"

# Create the user if it doesn't exist.
if aws iam get-user --user-name "${USER_NAME}" >/dev/null 2>&1; then
    log "IAM user ${USER_NAME} already exists; reusing."
else
    log "Creating IAM user ${USER_NAME}"
    aws iam create-user --user-name "${USER_NAME}" \
        --tags Key=Project,Value=aws-bedrock-redteam-demo Key=Purpose,Value=airs-bedrock-target >/dev/null
fi

# The inference profile and the underlying foundation models both need to be
# allowed; cross-region inference profiles route to multiple regional model
# ARNs at runtime, so the policy uses a wildcard on the foundation-model arn.
POLICY_DOC=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "InvokeBedrockModels",
      "Effect": "Allow",
      "Action": [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
        "bedrock:Converse",
        "bedrock:ConverseStream"
      ],
      "Resource": [
        "arn:aws:bedrock:*::foundation-model/anthropic.claude-*",
        "arn:aws:bedrock:*:${ACCOUNT_ID}:inference-profile/us.anthropic.claude-*"
      ]
    },
    {
      "Sid": "ListBedrockModels",
      "Effect": "Allow",
      "Action": [
        "bedrock:ListFoundationModels",
        "bedrock:GetFoundationModel",
        "bedrock:ListInferenceProfiles",
        "bedrock:GetInferenceProfile"
      ],
      "Resource": "*"
    }
  ]
}
JSON
)

log "Attaching inline policy ${POLICY_NAME}"
aws iam put-user-policy --user-name "${USER_NAME}" \
    --policy-name "${POLICY_NAME}" --policy-document "${POLICY_DOC}" >/dev/null

EXISTING_KEYS=$(aws iam list-access-keys --user-name "${USER_NAME}" \
    --query 'length(AccessKeyMetadata)' --output text)
if [[ "${EXISTING_KEYS}" -ge 2 ]]; then
    log "WARN: ${USER_NAME} already has 2 access keys (AWS limit). Delete one first or run --destroy then re-run."
    exit 1
fi

log "Creating access key (one-time secret display)"
KEY_JSON=$(aws iam create-access-key --user-name "${USER_NAME}")
ACCESS_KEY_ID=$(echo "${KEY_JSON}" | python3 -c "import sys,json;print(json.load(sys.stdin)['AccessKey']['AccessKeyId'])")
SECRET_KEY=$(echo "${KEY_JSON}" | python3 -c "import sys,json;print(json.load(sys.stdin)['AccessKey']['SecretAccessKey'])")

cat <<EOF

============================================================
AIRS Red Teaming - AWS Bedrock target credentials
============================================================
Paste these into SCM at:
  AI Security > AI Red Teaming > Targets > Add Target
  Connection Method: AWS Bedrock

  Region:           ${REGION}
  IAM Access ID:    ${ACCESS_KEY_ID}
  IAM Access Secret:${SECRET_KEY}
  Session Token:    (leave blank - this is a long-term key)
  Model Name:       ${MODEL_ID}
  Model Streaming:  off

System prompt (paste into Additional Context > System Prompt):
  ./scripts/print-system-prompt.sh | pbcopy

To revoke when done:
  ./scripts/provision-airs-bedrock-iam.sh --destroy
============================================================
EOF
