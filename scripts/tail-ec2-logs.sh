#!/usr/bin/env bash
# Tail demo-target container logs from an EC2 instance via SSM Run Command,
# without needing SSH or the Session Manager plugin. Polls every 4 seconds,
# de-dupes lines we've already printed.
#
# Usage:
#   ./scripts/tail-ec2-logs.sh                 # auto-find by Project tag
#   INSTANCE_ID=i-... ./scripts/tail-ec2-logs.sh
set -euo pipefail

: "${AWS_REGION:=us-east-1}"
: "${PROJECT_TAG:=aws-bedrock-redteam-demo}"
: "${CONTAINER:=aws-bedrock-redteam-demo}"
: "${POLL_INTERVAL:=4}"

if [[ -z "${INSTANCE_ID:-}" ]]; then
    INSTANCE_ID=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --filters "Name=tag:Project,Values=${PROJECT_TAG}" \
                  "Name=instance-state-name,Values=running" \
        --query "Reservations[].Instances[0].InstanceId" --output text)
fi

if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
    echo "No running instance tagged Project=${PROJECT_TAG}" >&2
    exit 1
fi

echo "Tailing logs from container '${CONTAINER}' on ${INSTANCE_ID} (Ctrl-C to stop)" >&2
seen_file=$(mktemp)
trap 'rm -f "$seen_file"' EXIT

while true; do
    cmd_id=$(aws ssm send-command --region "$AWS_REGION" \
        --instance-ids "$INSTANCE_ID" \
        --document-name AWS-RunShellScript \
        --parameters "commands=[\"sudo docker logs --tail 80 ${CONTAINER} 2>&1\"]" \
        --query 'Command.CommandId' --output text 2>/dev/null) || { sleep "$POLL_INTERVAL"; continue; }

    # Wait briefly for completion
    for _ in 1 2 3 4 5 6 7 8; do
        status=$(aws ssm get-command-invocation --region "$AWS_REGION" \
            --command-id "$cmd_id" --instance-id "$INSTANCE_ID" \
            --query 'Status' --output text 2>/dev/null || echo Pending)
        [[ "$status" == "Success" || "$status" == "Failed" ]] && break
        sleep 1
    done

    output=$(aws ssm get-command-invocation --region "$AWS_REGION" \
        --command-id "$cmd_id" --instance-id "$INSTANCE_ID" \
        --query 'StandardOutputContent' --output text 2>/dev/null || echo "")

    # Print only lines we haven't seen this poll cycle
    new_lines=$(comm -13 <(sort -u "$seen_file") <(echo "$output" | sort -u) || true)
    if [[ -n "$new_lines" ]]; then
        echo "$output" | grep -F -f <(echo "$new_lines") || true
    fi
    echo "$output" | sort -u > "$seen_file"

    sleep "$POLL_INTERVAL"
done
