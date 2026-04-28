#!/usr/bin/env bash
# One-shot AWS EC2 deployment of the demo target. Bootstraps entirely via
# SSM and user-data; no SSH access from the operator's machine is needed.
#
# Default action (`deploy`):
#   1. Create / reuse an S3 bucket for the code tarball.
#   2. Tar the local repo and upload it.
#   3. Put the local .env contents in SSM Parameter Store as a SecureString.
#   4. Create an IAM role + instance profile that can pull both.
#   5. Create / reuse a security group (only the app port is opened
#      inbound; SSH is not exposed at all by default).
#   6. Launch a t3.small Amazon Linux 2023 instance with the instance
#      profile attached.
#   7. Wait for the public health endpoint to come up (poll over the same
#      port AIRS will use; no SSM cli plugin or SSH required for monitoring).
#   8. Print the public URL plus the AIRS Red Teaming target settings.
#
# `--destroy`: terminate the instance, delete the SG, IAM role + profile,
#              SSM parameter, and (with KEEP_BUCKET=false, the default) the
#              S3 bucket. Idempotent.
# `--status`:  show whether the demo is currently deployed and where.
#
# Why this shape:
#   The earlier SSH-driven deploy worked but locked customers out of any
#   network where outbound 22 is filtered (corp VPNs, restrictive guest
#   wifi). Going through user-data + SSM keeps the entire deploy on
#   port 443 to AWS APIs - which always works if the AWS CLI itself works.
#
# Conventions:
#   - Resources are tagged Project=aws-bedrock-redteam-demo so we can find
#     them later without saving local state.
#   - All resource names share the PROJECT_TAG prefix.
#   - The instance is intentionally launched WITHOUT a keypair. If you need
#     to debug, use `aws ssm start-session --target <id>` (port 443).

set -euo pipefail

# ---------- defaults (override via env) ----------
PROJECT_TAG="${PROJECT_TAG:-aws-bedrock-redteam-demo}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.small}"
AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo us-east-1)}"
SG_NAME="${SG_NAME:-${PROJECT_TAG}-sg}"
ROLE_NAME="${ROLE_NAME:-${PROJECT_TAG}-instance-role}"
PROFILE_NAME="${PROFILE_NAME:-${PROJECT_TAG}-instance-profile}"
SSM_PARAM_NAME="${SSM_PARAM_NAME:-/demo/airs-bedrock-redteam/env}"
APP_PORT="${APP_PORT:-8080}"
RED_TEAM_CIDR="${RED_TEAM_CIDR:-0.0.0.0/0}"  # production: lock to AIRS source IPs
ENV_FILE="${ENV_FILE:-${PWD}/.env}"
AMI_ID="${AMI_ID:-}"

# Per-account bucket name. S3 bucket names are globally unique, so we
# scope to account + region. Override BUCKET to point at a pre-existing one.
BUCKET="${BUCKET:-}"

# ---------- helpers ----------
red()   { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
blue()  { printf "\033[34m%s\033[0m\n" "$*"; }

# Log to stderr so command-substitution callers ($(helper)) only capture
# the function's actual stdout return value, not the human-readable log.
log() { printf "\033[36m[deploy]\033[0m %s\n" "$*" >&2; }
die() { red "ERROR: $*" >&2; exit 1; }

aws_cmd() { aws --region "${AWS_REGION}" "$@"; }
require()  { command -v "$1" >/dev/null 2>&1 || die "Missing required tool: $1"; }

resolve_bucket_name() {
    if [[ -n "$BUCKET" ]]; then return; fi
    local account
    account=$(aws_cmd sts get-caller-identity --query Account --output text)
    BUCKET="${PROJECT_TAG}-bootstrap-${account}-${AWS_REGION}"
}

resolve_ami() {
    if [[ -n "$AMI_ID" ]]; then return; fi
    AMI_ID=$(aws_cmd ssm get-parameter \
        --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
        --query "Parameter.Value" --output text 2>/dev/null) \
        || die "Could not resolve AL2023 AMI for region ${AWS_REGION}"
    log "Resolved AL2023 AMI: ${AMI_ID}"
}

ensure_bucket() {
    resolve_bucket_name
    if aws_cmd s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
        log "Bucket ${BUCKET} present"
        return
    fi
    log "Creating bucket ${BUCKET}"
    if [[ "$AWS_REGION" == "us-east-1" ]]; then
        aws_cmd s3api create-bucket --bucket "$BUCKET" >/dev/null
    else
        aws_cmd s3api create-bucket --bucket "$BUCKET" \
            --create-bucket-configuration "LocationConstraint=${AWS_REGION}" >/dev/null
    fi
    aws_cmd s3api put-bucket-encryption --bucket "$BUCKET" \
        --server-side-encryption-configuration \
        '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' >/dev/null
    aws_cmd s3api put-public-access-block --bucket "$BUCKET" \
        --public-access-block-configuration \
        "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" >/dev/null
}

upload_code() {
    log "Tarring repo and uploading to s3://${BUCKET}/${PROJECT_TAG}.tgz"
    local tgz
    tgz=$(mktemp -t "${PROJECT_TAG}.XXXXX.tgz")
    tar --exclude='.git' --exclude='.venv' --exclude='__pycache__' \
        --exclude='*.pem' --exclude='.env' --exclude='*.tgz' \
        -czf "$tgz" -C "$PWD" .
    aws_cmd s3 cp "$tgz" "s3://${BUCKET}/${PROJECT_TAG}.tgz" >/dev/null
    rm -f "$tgz"
}

put_env_param() {
    [[ -f "$ENV_FILE" ]] || die ".env not found at ${ENV_FILE}. Copy .env.example and fill it in first."
    log "Storing .env in SSM as SecureString at ${SSM_PARAM_NAME}"
    aws_cmd ssm put-parameter --name "${SSM_PARAM_NAME}" \
        --type SecureString --value "$(cat "$ENV_FILE")" --overwrite >/dev/null
}

ensure_iam() {
    local account
    account=$(aws_cmd sts get-caller-identity --query Account --output text)

    if ! aws_cmd iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
        log "Creating IAM role ${ROLE_NAME}"
        aws_cmd iam create-role --role-name "${ROLE_NAME}" \
            --assume-role-policy-document \
            '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
            --tags "Key=Project,Value=${PROJECT_TAG}" >/dev/null
    fi
    aws_cmd iam attach-role-policy --role-name "${ROLE_NAME}" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" >/dev/null 2>&1 || true

    local inline
    inline=$(cat <<EOF
{"Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Action":["s3:GetObject"],"Resource":"arn:aws:s3:::${BUCKET}/*"},
  {"Effect":"Allow","Action":["ssm:GetParameter","ssm:GetParameters"],"Resource":"arn:aws:ssm:${AWS_REGION}:${account}:parameter${SSM_PARAM_NAME}"},
  {"Effect":"Allow","Action":["kms:Decrypt"],"Resource":"*"}
]}
EOF
)
    aws_cmd iam put-role-policy --role-name "${ROLE_NAME}" \
        --policy-name bootstrap-fetch --policy-document "$inline" >/dev/null
    log "IAM role ${ROLE_NAME} ready"

    if ! aws_cmd iam get-instance-profile --instance-profile-name "${PROFILE_NAME}" >/dev/null 2>&1; then
        log "Creating instance profile ${PROFILE_NAME}"
        aws_cmd iam create-instance-profile --instance-profile-name "${PROFILE_NAME}" \
            --tags "Key=Project,Value=${PROJECT_TAG}" >/dev/null
        aws_cmd iam add-role-to-instance-profile \
            --instance-profile-name "${PROFILE_NAME}" --role-name "${ROLE_NAME}" >/dev/null
        log "Sleeping 12s for IAM eventual consistency..."
        sleep 12
    fi
}

ensure_security_group() {
    local sg_id
    sg_id=$(aws_cmd ec2 describe-security-groups \
        --filters "Name=group-name,Values=${SG_NAME}" \
        --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || echo "None")
    if [[ "$sg_id" != "None" && -n "$sg_id" ]]; then
        log "Security group ${SG_NAME} exists (${sg_id})"
        echo "$sg_id"; return
    fi
    log "Creating security group ${SG_NAME}"
    sg_id=$(aws_cmd ec2 create-security-group --group-name "${SG_NAME}" \
        --description "AIRS Bedrock vulnerable demo target" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Project,Value=${PROJECT_TAG}}]" \
        --query "GroupId" --output text)
    aws_cmd ec2 authorize-security-group-ingress --group-id "$sg_id" \
        --protocol tcp --port "${APP_PORT}" --cidr "${RED_TEAM_CIDR}" >/dev/null
    log "Security group ${sg_id} created (app port ${APP_PORT} open from ${RED_TEAM_CIDR})"
    log "SSH is intentionally NOT opened. Use 'aws ssm start-session --target <id>' for shell access."
    echo "$sg_id"
}

find_existing_instance() {
    aws_cmd ec2 describe-instances \
        --filters "Name=tag:Project,Values=${PROJECT_TAG}" \
                  "Name=instance-state-name,Values=pending,running,stopped,stopping" \
        --query "Reservations[].Instances[0].InstanceId" --output text 2>/dev/null
}

build_userdata() {
    # Self-contained bootstrap script that runs on the instance via cloud-init.
    # Notes from earlier debugging:
    #   - awscli is pre-installed on AL2023 (do NOT add awscli2 to dnf, it isn't a package)
    #   - docker compose v2 plugin needs buildx 0.17+ for `docker compose build`;
    #     install both compose and buildx as standalone CLI plugins
    cat <<USERDATA
#!/bin/bash
set -euxo pipefail
exec > /var/log/airs-demo-bootstrap.log 2>&1

# Tools (aws CLI is already on AL2023, do not reinstall)
dnf -y install docker
systemctl enable --now docker
usermod -aG docker ec2-user

# docker compose plugin
mkdir -p /usr/libexec/docker/cli-plugins
curl -sSL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
    -o /usr/libexec/docker/cli-plugins/docker-compose
chmod +x /usr/libexec/docker/cli-plugins/docker-compose

# buildx plugin (required by 'docker compose build' on the AL2023 docker version)
curl -sSL https://github.com/docker/buildx/releases/download/v0.17.1/buildx-v0.17.1.linux-amd64 \
    -o /usr/libexec/docker/cli-plugins/docker-buildx
chmod +x /usr/libexec/docker/cli-plugins/docker-buildx

# Fetch code from S3
mkdir -p /opt/airs-demo
cd /opt/airs-demo
aws s3 cp s3://${BUCKET}/${PROJECT_TAG}.tgz /tmp/app.tgz --region ${AWS_REGION}
tar -xzf /tmp/app.tgz -C /opt/airs-demo

# Fetch .env from SSM (SecureString)
aws ssm get-parameter --name "${SSM_PARAM_NAME}" --with-decryption --region ${AWS_REGION} \
    --query 'Parameter.Value' --output text > /opt/airs-demo/.env
chmod 600 /opt/airs-demo/.env

# Build and start
cd /opt/airs-demo
docker compose up -d --build

# Wait until /healthz returns 200 (gives us a clear bootstrap-success marker)
for i in \$(seq 1 30); do
    if curl -fsS http://127.0.0.1:${APP_PORT}/healthz >/dev/null; then
        echo "OK: app is healthy"
        exit 0
    fi
    sleep 4
done
echo "WARN: app did not become healthy within 2 minutes"
exit 1
USERDATA
}

deploy() {
    require aws
    require tar

    aws_cmd sts get-caller-identity --query 'Arn' --output text >/dev/null \
        || die "AWS CLI not authenticated. See README for SSO login flow."

    local existing
    existing=$(find_existing_instance || true)
    if [[ -n "$existing" && "$existing" != "None" ]]; then
        die "Instance ${existing} already tagged with Project=${PROJECT_TAG}. Run --destroy first or use --status."
    fi

    resolve_bucket_name
    ensure_bucket
    upload_code
    put_env_param
    ensure_iam
    resolve_ami
    local sg_id
    sg_id=$(ensure_security_group)

    log "Launching ${INSTANCE_TYPE} in ${AWS_REGION}"
    local userdata_file
    userdata_file=$(mktemp -t airs-demo-userdata.XXXXXX)
    build_userdata > "$userdata_file"

    local instance_id
    instance_id=$(aws_cmd ec2 run-instances \
        --image-id "${AMI_ID}" \
        --instance-type "${INSTANCE_TYPE}" \
        --security-group-ids "${sg_id}" \
        --iam-instance-profile "Name=${PROFILE_NAME}" \
        --tag-specifications \
            "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT_TAG}},{Key=Project,Value=${PROJECT_TAG}}]" \
        --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=2" \
        --user-data "file://${userdata_file}" \
        --query "Instances[0].InstanceId" --output text)
    rm -f "$userdata_file"
    log "Instance ${instance_id} launching"

    log "Waiting for instance to reach 'running' state..."
    aws_cmd ec2 wait instance-running --instance-ids "${instance_id}"

    local public_ip
    public_ip=$(aws_cmd ec2 describe-instances --instance-ids "${instance_id}" \
        --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
    log "Public IP: ${public_ip}"

    log "Polling http://${public_ip}:${APP_PORT}/healthz (cloud-init build takes ~3-4 min)..."
    local ok=0
    for i in $(seq 1 60); do
        if curl -sS --max-time 4 "http://${public_ip}:${APP_PORT}/healthz" 2>/dev/null \
                | grep -q '"status"'; then
            ok=1; break
        fi
        sleep 5
    done

    if [[ "$ok" != "1" ]]; then
        red ""
        red "Endpoint did not become healthy within 5 minutes."
        red "Inspect the bootstrap log via SSM:"
        red "  aws ssm send-command --region ${AWS_REGION} --instance-ids ${instance_id} \\"
        red "    --document-name AWS-RunShellScript \\"
        red "    --parameters 'commands=[\"sudo tail -80 /var/log/airs-demo-bootstrap.log\"]'"
        exit 2
    fi

    green ""
    green "==============================================="
    green "  Demo target deployed"
    green "  Public URL: http://${public_ip}:${APP_PORT}"
    green "  Health:     http://${public_ip}:${APP_PORT}/healthz"
    green ""
    green "  Configure AIRS Red Teaming target (REST connector):"
    green "    Endpoint:       http://${public_ip}:${APP_PORT}/v1/chat/completions"
    green "    HTTP Method:    POST"
    green "    Headers:        Authorization: Bearer <DEMO_API_KEY from .env>"
    green "                    Content-Type: application/json"
    green "    Body template:  {\"model\":\"sb\",\"messages\":[{\"role\":\"user\",\"content\":\"{INPUT}\"}]}"
    green "    Response path:  choices[0].message.content"
    green ""
    green "  Tail logs:"
    green "    ./scripts/tail-ec2-logs.sh"
    green "  Open shell on the instance (no SSH; uses SSM Session Manager):"
    green "    aws ssm start-session --target ${instance_id}"
    green ""
    green "  Tear down:"
    green "    ./deploy-aws-vm.sh --destroy"
    green "==============================================="
}

destroy() {
    require aws
    aws_cmd sts get-caller-identity --query 'Arn' --output text >/dev/null \
        || die "AWS CLI not authenticated."

    resolve_bucket_name

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
        for _ in 1 2 3 4; do
            aws_cmd ec2 delete-security-group --group-id "${sg_id}" 2>/dev/null && { log "Security group deleted"; break; }
            sleep 5
        done
    fi

    if aws_cmd iam get-instance-profile --instance-profile-name "${PROFILE_NAME}" >/dev/null 2>&1; then
        log "Detaching role and deleting instance profile ${PROFILE_NAME}"
        aws_cmd iam remove-role-from-instance-profile \
            --instance-profile-name "${PROFILE_NAME}" --role-name "${ROLE_NAME}" 2>/dev/null || true
        aws_cmd iam delete-instance-profile --instance-profile-name "${PROFILE_NAME}" 2>/dev/null || true
    fi

    if aws_cmd iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
        log "Deleting IAM role ${ROLE_NAME}"
        aws_cmd iam delete-role-policy --role-name "${ROLE_NAME}" --policy-name bootstrap-fetch 2>/dev/null || true
        aws_cmd iam detach-role-policy --role-name "${ROLE_NAME}" \
            --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" 2>/dev/null || true
        aws_cmd iam delete-role --role-name "${ROLE_NAME}" 2>/dev/null || true
    fi

    if aws_cmd ssm get-parameter --name "${SSM_PARAM_NAME}" >/dev/null 2>&1; then
        log "Deleting SSM parameter ${SSM_PARAM_NAME}"
        aws_cmd ssm delete-parameter --name "${SSM_PARAM_NAME}" >/dev/null || true
    fi

    if [[ "${KEEP_BUCKET:-false}" != "true" ]]; then
        if aws_cmd s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
            log "Emptying and deleting bucket ${BUCKET}"
            aws_cmd s3 rm "s3://${BUCKET}" --recursive >/dev/null 2>&1 || true
            aws_cmd s3api delete-bucket --bucket "$BUCKET" 2>/dev/null || true
        fi
    fi

    green "Cleanup complete"
}

status() {
    require aws
    resolve_bucket_name
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
        blue "URL:           http://${ip}:${APP_PORT}/healthz"
        blue "AIRS endpoint: http://${ip}:${APP_PORT}/v1/chat/completions"
        blue "Tail logs:     ./scripts/tail-ec2-logs.sh"
        blue "Open shell:    aws ssm start-session --target ${instance_id}"
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
    RED_TEAM_CIDR    (default 0.0.0.0/0; lock down to AIRS source IPs in production)
    SSM_PARAM_NAME   (default /demo/airs-bedrock-redteam/env)
    BUCKET           (auto: \${PROJECT_TAG}-bootstrap-\${ACCOUNT}-\${REGION})
    KEEP_BUCKET=true don't delete the S3 bucket on --destroy

Bootstrap path: code -> S3, .env -> SSM SecureString, EC2 instance pulls
both via attached IAM instance profile during cloud-init. No SSH from the
operator's machine. For interactive shell, use:
    aws ssm start-session --target <instance-id>
EOF
        ;;
    *) die "Unknown command: $1. Try --help." ;;
esac
