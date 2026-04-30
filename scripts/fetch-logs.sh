#!/usr/bin/env bash
# Pull recent EC2 container logs to the local laptop for offline review.
#
# Usage:
#   ./scripts/fetch-logs.sh                 # last 1000 lines to /tmp/airs-demo-logs.txt
#   ./scripts/fetch-logs.sh 5000            # last 5000 lines
#   ./scripts/fetch-logs.sh --since 30m     # last 30 minutes (any docker logs --since arg)
#   ./scripts/fetch-logs.sh --all           # full rotated history (5x50MB tarball)
#
# Why: AIRS scans can produce thousands of log lines. Pulling them down once
# lets you grep without round-tripping through SSM for every query. The full
# --all mode also captures the rotated json-file history so post-mortem on
# attacks that happened earlier in a long scan is possible.

set -euo pipefail

REGION="${REGION:-us-east-1}"
PROJECT_TAG="${PROJECT_TAG:-aws-bedrock-redteam-demo}"
OUT="${OUT:-/tmp/airs-demo-logs.txt}"

if [[ -z "${INSTANCE_ID:-}" ]]; then
    INSTANCE_ID=$(aws ec2 describe-instances --region "$REGION" \
        --filters "Name=tag:Project,Values=${PROJECT_TAG}" \
                  "Name=instance-state-name,Values=running" \
        --query "Reservations[].Instances[0].InstanceId" --output text 2>/dev/null || echo "")
fi
if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
    echo "ERROR: No running instance tagged Project=${PROJECT_TAG}" >&2
    exit 1
fi

require_aws() {
    if ! aws sts get-caller-identity --output json >/dev/null 2>&1; then
        echo "ERROR: AWS credentials are missing or expired." >&2
        echo "Refresh from your AWS access portal and re-run." >&2
        exit 2
    fi
}

case "${1:-}" in
    --all)
        require_aws
        echo "Fetching full rotated log history from ${INSTANCE_ID}..." >&2
        ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
        BUCKET="aws-bedrock-redteam-demo-bootstrap-${ACCOUNT}-${REGION}"
        CMD_ID=$(aws ssm send-command --instance-ids "${INSTANCE_ID}" \
            --document-name AWS-RunShellScript --region "${REGION}" \
            --parameters 'commands=[
                "C=$(sudo docker ps -q --filter name=aws-bedrock-redteam-demo)",
                "LOGDIR=$(sudo docker inspect --format \"{{.LogPath}}\" $C | xargs -I{} dirname {})",
                "sudo tar -czf /tmp/airs-demo-logs.tgz -C $LOGDIR .",
                "sudo aws s3 cp /tmp/airs-demo-logs.tgz s3://'${BUCKET}'/airs-demo-logs.tgz --region '${REGION}'"
            ]' --query 'Command.CommandId' --output text)
        until [ "$(aws ssm list-command-invocations --command-id "${CMD_ID}" --details --region "${REGION}" --query 'CommandInvocations[0].Status' --output text 2>/dev/null)" = "Success" ]; do sleep 3; done
        aws s3 cp "s3://${BUCKET}/airs-demo-logs.tgz" "/tmp/airs-demo-logs.tgz" --region "${REGION}" --quiet
        echo "Saved to /tmp/airs-demo-logs.tgz" >&2
        echo "Extract with: tar -xzf /tmp/airs-demo-logs.tgz -C /tmp/airs-demo-logs/" >&2
        ;;
    --since)
        require_aws
        SINCE="${2:-30m}"
        echo "Fetching logs since ${SINCE} from ${INSTANCE_ID}..." >&2
        CMD_ID=$(aws ssm send-command --instance-ids "${INSTANCE_ID}" \
            --document-name AWS-RunShellScript --region "${REGION}" \
            --parameters "commands=[\"C=\$(sudo docker ps -q --filter name=aws-bedrock-redteam-demo)\",\"sudo docker logs --since ${SINCE} \$C 2>&1\"]" \
            --query 'Command.CommandId' --output text)
        until [ "$(aws ssm list-command-invocations --command-id "${CMD_ID}" --details --region "${REGION}" --query 'CommandInvocations[0].Status' --output text 2>/dev/null)" = "Success" ]; do sleep 2; done
        aws ssm list-command-invocations --command-id "${CMD_ID}" --details --region "${REGION}" \
            --query 'CommandInvocations[0].CommandPlugins[0].Output' --output text > "${OUT}"
        echo "Saved $(wc -l < "${OUT}") lines to ${OUT}" >&2
        ;;
    *)
        require_aws
        TAIL="${1:-1000}"
        echo "Fetching last ${TAIL} log lines from ${INSTANCE_ID}..." >&2
        CMD_ID=$(aws ssm send-command --instance-ids "${INSTANCE_ID}" \
            --document-name AWS-RunShellScript --region "${REGION}" \
            --parameters "commands=[\"C=\$(sudo docker ps -q --filter name=aws-bedrock-redteam-demo)\",\"sudo docker logs --tail ${TAIL} \$C 2>&1\"]" \
            --query 'Command.CommandId' --output text)
        until [ "$(aws ssm list-command-invocations --command-id "${CMD_ID}" --details --region "${REGION}" --query 'CommandInvocations[0].Status' --output text 2>/dev/null)" = "Success" ]; do sleep 2; done
        aws ssm list-command-invocations --command-id "${CMD_ID}" --details --region "${REGION}" \
            --query 'CommandInvocations[0].CommandPlugins[0].Output' --output text > "${OUT}"
        echo "Saved $(wc -l < "${OUT}") lines to ${OUT}" >&2
        ;;
esac

cat <<EOF >&2

Quick analysis examples:
  HTTP status distribution:
    grep -oE 'HTTP/1.1" [0-9]+' "${OUT}" | sort | uniq -c | sort -rn

  Slow Bedrock calls (>10s):
    grep 'elapsed_ms=' "${OUT}" | awk -F'elapsed_ms=' '{split(\$2,a,\" \"); if (a[1]>10000) print}'

  Sentinel responses (empty model output):
    grep 'sentinel=True' "${OUT}"

  Per-attack trace by tr_id:
    grep 'tr=<TR_ID_HERE>' "${OUT}"

  Bedrock errors:
    grep -i 'bedrock error' "${OUT}"

  AIRS Runtime blocks:
    grep -E 'airs (PRE|POST) block' "${OUT}"
EOF
