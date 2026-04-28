#!/usr/bin/env bash
# One-shot AWS EC2 deployment of the demo target.
#
# Default action: create SG + keypair + t3.small Amazon Linux 2023 instance,
# wait for SSH, copy the local repo + .env, build and start the container,
# print the public URL.
#
# --destroy:  terminate the instance, delete the SG, optionally delete the
#             keypair. Idempotent; safe to run twice.
# --status:   show whether the demo is currently deployed and where.
#
# Conventions:
#   - Resources are tagged Project=aws-bedrock-redteam-demo so we can find
#     them later without saving local state.
#   - Keypair material lands at ./aws-bedrock-redteam-demo.pem (gitignored
#     by *.pem in .gitignore).
#   - Region defaults to whatever's in your AWS_REGION / aws config.
#
# Why bash and not Terraform: the v1 deploy is a single instance, no real
# state to manage, and the operator usually wants to ship-and-destroy in
# the same hour. Bash is faster to read and faster to fork. A Terraform
# variant lives in terraform/ for customers who'd rather use that path.

set -euo pipefail

# ---------- defaults (override via env) ----------
PROJECT_TAG="${PROJECT_TAG:-aws-bedrock-redteam-demo}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.small}"
AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo us-east-1)}"
KEY_NAME="${KEY_NAME:-${PROJECT_TAG}}"
KEY_FILE="${KEY_FILE:-${PWD}/${PROJECT_TAG}.pem}"
SG_NAME="${SG_NAME:-${PROJECT_TAG}-sg}"
APP_PORT="${APP_PORT:-8080}"
ADMIN_CIDR="${ADMIN_CIDR:-$(curl -sS https://checkip.amazonaws.com 2>/dev/null | tr -d '\n')/32}"
RED_TEAM_CIDR="${RED_TEAM_CIDR:-0.0.0.0/0}"  # production: lock down to AIRS source IPs
ENV_FILE="${ENV_FILE:-${PWD}/.env}"

# Amazon Linux 2023 (x86_64) AMI ID resolved per region via SSM
AMI_ID="${AMI_ID:-}"

# ---------- helpers ----------
red()   { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
blue()  { printf "\033[34m%s\033[0m\n" "$*"; }

# Log messages go to stderr so they don't end up captured by $(...) calls
# that read the stdout of helper functions.
log() { printf "\033[36m[deploy]\033[0m %s\n" "$*" >&2; }
die() { red "ERROR: $*" >&2; exit 1; }

aws_cmd() { aws --region "${AWS_REGION}" "$@"; }

require() { command -v "$1" >/dev/null 2>&1 || die "Missing required tool: $1"; }

resolve_ami() {
    if [[ -n "$AMI_ID" ]]; then return; fi
    AMI_ID=$(aws_cmd ssm get-parameter \
        --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
        --query "Parameter.Value" --output text 2>/dev/null) \
        || die "Could not resolve AL2023 AMI for region ${AWS_REGION}"
    log "Resolved AL2023 AMI: ${AMI_ID}"
}

find_existing_instance() {
    aws_cmd ec2 describe-instances \
        --filters "Name=tag:Project,Values=${PROJECT_TAG}" \
                  "Name=instance-state-name,Values=pending,running,stopped,stopping" \
        --query "Reservations[].Instances[0].InstanceId" --output text 2>/dev/null
}

ensure_keypair() {
    if aws_cmd ec2 describe-key-pairs --key-names "${KEY_NAME}" >/dev/null 2>&1; then
        if [[ ! -f "$KEY_FILE" ]]; then
            die "Keypair ${KEY_NAME} exists in AWS but ${KEY_FILE} is missing locally. Either re-create the keypair or restore the .pem."
        fi
        log "Keypair ${KEY_NAME} present"
    else
        log "Creating keypair ${KEY_NAME} -> ${KEY_FILE}"
        aws_cmd ec2 create-key-pair --key-name "${KEY_NAME}" \
            --query "KeyMaterial" --output text > "${KEY_FILE}"
        chmod 600 "${KEY_FILE}"
    fi
}

ensure_security_group() {
    local sg_id
    sg_id=$(aws_cmd ec2 describe-security-groups \
        --filters "Name=group-name,Values=${SG_NAME}" \
        --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || echo "None")
    if [[ "$sg_id" != "None" && -n "$sg_id" ]]; then
        log "Security group ${SG_NAME} exists (${sg_id})"
        echo "$sg_id"
        return
    fi
    log "Creating security group ${SG_NAME}"
    sg_id=$(aws_cmd ec2 create-security-group --group-name "${SG_NAME}" \
        --description "AIRS Bedrock vulnerable demo target" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=${PROJECT_TAG}}]" \
        --query "GroupId" --output text)
    aws_cmd ec2 authorize-security-group-ingress --group-id "$sg_id" \
        --protocol tcp --port 22 --cidr "${ADMIN_CIDR}" >/dev/null
    aws_cmd ec2 authorize-security-group-ingress --group-id "$sg_id" \
        --protocol tcp --port "${APP_PORT}" --cidr "${RED_TEAM_CIDR}" >/dev/null
    log "Security group ${sg_id} created (ssh from ${ADMIN_CIDR}, app from ${RED_TEAM_CIDR})"
    echo "$sg_id"
}

wait_for_ssh() {
    local ip="$1"
    log "Waiting for SSH on ${ip}..."
    for i in $(seq 1 30); do
        if ssh -i "${KEY_FILE}" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
            -o BatchMode=yes "ec2-user@${ip}" "true" >/dev/null 2>&1; then
            log "SSH ready"
            return
        fi
        sleep 5
    done
    die "SSH never came up on ${ip}"
}

remote() {
    local ip="$1"; shift
    ssh -i "${KEY_FILE}" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "ec2-user@${ip}" "$@"
}

deploy() {
    require aws
    require ssh
    require scp
    require tar

    aws_cmd sts get-caller-identity --query 'Arn' --output text >/dev/null \
        || die "AWS CLI not authenticated. See README for SSO login flow."

    [[ -f "$ENV_FILE" ]] || die ".env not found at ${ENV_FILE}. Copy .env.example and fill it in first."

    local existing
    existing=$(find_existing_instance || true)
    if [[ -n "$existing" && "$existing" != "None" ]]; then
        die "Instance ${existing} already tagged with Project=${PROJECT_TAG}. Run --destroy first or use --status."
    fi

    resolve_ami
    ensure_keypair
    local sg_id
    sg_id=$(ensure_security_group)

    log "Launching ${INSTANCE_TYPE} in ${AWS_REGION}"
    local userdata_file
    userdata_file=$(mktemp -t airs-demo-userdata.XXXXXX)
    cat > "${userdata_file}" <<'USERDATA'
#!/bin/bash
set -e
dnf -y install docker
systemctl enable --now docker
usermod -aG docker ec2-user
mkdir -p /usr/libexec/docker/cli-plugins
curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" \
    -o /usr/libexec/docker/cli-plugins/docker-compose
chmod +x /usr/libexec/docker/cli-plugins/docker-compose
USERDATA

    local instance_id
    instance_id=$(aws_cmd ec2 run-instances \
        --image-id "${AMI_ID}" \
        --instance-type "${INSTANCE_TYPE}" \
        --key-name "${KEY_NAME}" \
        --security-group-ids "${sg_id}" \
        --tag-specifications \
            "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT_TAG}},{Key=Project,Value=${PROJECT_TAG}}]" \
        --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=2" \
        --user-data "file://${userdata_file}" \
        --query "Instances[0].InstanceId" --output text)
    rm -f "${userdata_file}"
    log "Instance ${instance_id} launching"

    log "Waiting for instance to reach 'running' state..."
    aws_cmd ec2 wait instance-running --instance-ids "${instance_id}"

    local public_ip
    public_ip=$(aws_cmd ec2 describe-instances --instance-ids "${instance_id}" \
        --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
    log "Public IP: ${public_ip}"

    wait_for_ssh "${public_ip}"

    log "Waiting another 60s for cloud-init / docker install to finish..."
    sleep 60

    log "Copying repo + .env to instance"
    tar --exclude='.git' --exclude='.venv' --exclude='__pycache__' --exclude='*.pem' \
        --exclude='.env' \
        -czf /tmp/${PROJECT_TAG}-app.tgz -C "$PWD" .
    scp -i "${KEY_FILE}" -o StrictHostKeyChecking=no \
        /tmp/${PROJECT_TAG}-app.tgz "ec2-user@${public_ip}:/tmp/app.tgz"
    scp -i "${KEY_FILE}" -o StrictHostKeyChecking=no \
        "${ENV_FILE}" "ec2-user@${public_ip}:/tmp/.env"
    rm /tmp/${PROJECT_TAG}-app.tgz

    log "Building and starting container on instance"
    remote "${public_ip}" "set -e
mkdir -p ~/app && cd ~/app && tar -xzf /tmp/app.tgz
mv /tmp/.env ~/app/.env
sudo docker compose up -d --build
sleep 8
sudo docker compose ps
curl -fsS http://127.0.0.1:${APP_PORT}/healthz | head -c 400
echo"

    green ""
    green "==============================================="
    green "  Demo target deployed"
    green "  Public URL: http://${public_ip}:${APP_PORT}"
    green "  Health:     http://${public_ip}:${APP_PORT}/healthz"
    green ""
    green "  Configure AIRS Red Teaming target:"
    green "    Endpoint: http://${public_ip}:${APP_PORT}/v1/chat/completions"
    green "    API key:  (DEMO_API_KEY from your .env)"
    green ""
    green "  SSH access:"
    green "    ssh -i ${KEY_FILE} ec2-user@${public_ip}"
    green ""
    green "  Tear down (when done):"
    green "    ./deploy-aws-vm.sh --destroy"
    green "==============================================="
}

destroy() {
    require aws

    aws_cmd sts get-caller-identity --query 'Arn' --output text >/dev/null \
        || die "AWS CLI not authenticated."

    local instance_id
    instance_id=$(find_existing_instance || true)
    if [[ -n "$instance_id" && "$instance_id" != "None" ]]; then
        log "Terminating instance ${instance_id}"
        aws_cmd ec2 terminate-instances --instance-ids "${instance_id}" >/dev/null
        log "Waiting for terminate..."
        aws_cmd ec2 wait instance-terminated --instance-ids "${instance_id}"
        log "Instance terminated"
    else
        log "No instance found with Project=${PROJECT_TAG}"
    fi

    local sg_id
    sg_id=$(aws_cmd ec2 describe-security-groups --filters "Name=group-name,Values=${SG_NAME}" \
        --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || echo "None")
    if [[ "$sg_id" != "None" && -n "$sg_id" ]]; then
        log "Deleting security group ${sg_id}"
        # Retry briefly in case ENI cleanup lags
        for i in 1 2 3 4; do
            if aws_cmd ec2 delete-security-group --group-id "${sg_id}" 2>/dev/null; then
                log "Security group deleted"
                break
            fi
            sleep 5
        done
    fi

    if [[ "${KEEP_KEY:-false}" != "true" ]]; then
        if aws_cmd ec2 describe-key-pairs --key-names "${KEY_NAME}" >/dev/null 2>&1; then
            log "Deleting keypair ${KEY_NAME}"
            aws_cmd ec2 delete-key-pair --key-name "${KEY_NAME}" >/dev/null
        fi
        if [[ -f "${KEY_FILE}" ]]; then
            log "Removing local ${KEY_FILE}"
            rm -f "${KEY_FILE}"
        fi
    else
        log "KEEP_KEY=true; leaving keypair in place"
    fi

    green "Cleanup complete"
}

status() {
    require aws
    local instance_id state ip
    instance_id=$(find_existing_instance || true)
    if [[ -z "$instance_id" || "$instance_id" == "None" ]]; then
        blue "No instance tagged Project=${PROJECT_TAG} in ${AWS_REGION}"
        return
    fi
    state=$(aws_cmd ec2 describe-instances --instance-ids "${instance_id}" \
        --query "Reservations[0].Instances[0].State.Name" --output text)
    ip=$(aws_cmd ec2 describe-instances --instance-ids "${instance_id}" \
        --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
    blue "Instance ${instance_id} state=${state} public_ip=${ip}"
    if [[ "$state" == "running" && -n "$ip" && "$ip" != "None" ]]; then
        blue "URL: http://${ip}:${APP_PORT}/healthz"
    fi
}

case "${1:-deploy}" in
    deploy) deploy ;;
    --destroy|destroy) destroy ;;
    --status|status) status ;;
    -h|--help)
        cat <<EOF
Usage: $0 [deploy|--destroy|--status]

Env overrides:
    AWS_REGION       (default us-east-1)
    INSTANCE_TYPE    (default t3.small)
    PROJECT_TAG      (default aws-bedrock-redteam-demo)
    APP_PORT         (default 8080)
    ADMIN_CIDR       (default <your IP>/32)
    RED_TEAM_CIDR    (default 0.0.0.0/0 - lock down to AIRS source IPs in production)
    KEEP_KEY=true    don't delete keypair on --destroy
EOF
        ;;
    *) die "Unknown command: $1. Try --help." ;;
esac
