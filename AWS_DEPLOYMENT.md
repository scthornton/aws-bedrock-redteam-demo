# AWS EC2 Deployment

End-to-end EC2 deployment of the demo target. The deploy uses an SSM-based bootstrap path (no SSH from your machine), so it works from any network where the AWS CLI works.

## Prerequisites

- AWS CLI v2 authenticated (e.g. `aws sso login` or static creds)
- Bedrock model access granted in the same region you'll deploy to
- Local checkout of this repo with a working `.env` (see [QUICKSTART.md](QUICKSTART.md))

The IAM principal you're running as needs to be able to:
- Create / delete S3 buckets and put objects
- Create / delete IAM roles and instance profiles
- Put / get / delete SSM parameters (with KMS decrypt)
- Run EC2 (instances, security groups)
- Use SSM Run Command + Session Manager (for log tailing and shell access)

`AWSAdministratorAccess` covers everything. For least-privilege, the script's actions are documented in `deploy-aws-vm.sh` itself.

## Deploy

```bash
./deploy-aws-vm.sh
```

What this does, in order:

1. Creates / reuses an S3 bucket: `<project>-bootstrap-<account>-<region>` (encryption + public-access-block on)
2. Tars the local repo (excluding `.git`, `.venv`, `*.pem`, `.env`, `*.tgz`) and uploads it
3. Stores the contents of `.env` in SSM Parameter Store as a `SecureString`
4. Creates an IAM role + instance profile with `AmazonSSMManagedInstanceCore`, S3 read for the tarball, and SSM read for the parameter
5. Creates / reuses a security group: only the app port is open inbound; SSH is intentionally not exposed
6. Resolves the latest Amazon Linux 2023 AMI for your region via SSM
7. Launches a `t3.small` with the instance profile attached and a self-bootstrapping cloud-init script
8. Cloud-init installs Docker + the buildx and compose CLI plugins, fetches the code from S3 and the env from SSM, builds and starts the container
9. The deploy script polls `http://<public-ip>:8080/healthz` until the app is up
10. Prints the public URL and the AIRS Red Teaming target settings

Total time: 4 to 6 minutes.

## Verify

The script doesn't exit until `/healthz` returns `status: ok`. If it does exit successfully, the app is reachable. To inspect later:

```bash
./deploy-aws-vm.sh --status
./scripts/tail-ec2-logs.sh
```

To open a shell on the instance (no SSH; uses SSM Session Manager over port 443):

```bash
aws ssm start-session --target <instance-id>
```

Requires the Session Manager plugin: `brew install --cask session-manager-plugin` on macOS, or [the official installer](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html).

## Hand it to AIRS

Use the URL the script printed. The DEMO_API_KEY from your `.env` is what AIRS sends as Bearer. Use the **REST connector** (not OpenAI - the OpenAI connector is locked to api.openai.com). Full SCM-side configuration walkthrough is in [RED_TEAM_SETUP.md](RED_TEAM_SETUP.md).

## Status

```bash
./deploy-aws-vm.sh --status
```

Tells you whether an instance tagged `Project=aws-bedrock-redteam-demo` exists, its state, and the public URL.

## Tear down

```bash
./deploy-aws-vm.sh --destroy
```

Removes:
- EC2 instance
- Security group
- IAM role + instance profile
- SSM parameter (the encrypted `.env` content)
- S3 bucket and the code tarball inside it (set `KEEP_BUCKET=true` to keep it)

The script is idempotent; running it after everything's already gone just prints "No instance found" and exits clean.

## Customizing the deploy

All knobs are env vars:

| Var | Default | Notes |
| --- | --- | --- |
| `AWS_REGION` | `us-east-1` | Must match your Bedrock model access |
| `INSTANCE_TYPE` | `t3.small` | Bump to `t3.medium` if scan latency drives load (single-worker gunicorn) |
| `APP_PORT` | `8080` | Change if you front the app with an ALB on 80/443 |
| `RED_TEAM_CIDR` | `0.0.0.0/0` | Set to AIRS source IPs in production |
| `PROJECT_TAG` | `aws-bedrock-redteam-demo` | Used for resource discovery |
| `SSM_PARAM_NAME` | `/demo/airs-bedrock-redteam/env` | Where the encrypted `.env` lands |
| `BUCKET` | auto: `<project>-bootstrap-<account>-<region>` | Override to use a pre-existing bucket |
| `KEEP_BUCKET=true` | (unset) | Don't delete the S3 bucket on `--destroy` |

For a production-shape deployment, narrow `RED_TEAM_CIDR` to the AIRS Red Teaming source IPs documented in your SCM tenant settings, and put an ALB with TLS in front. The app itself does not terminate TLS.

## Updating the running instance

The cleanest path is `--destroy` then `deploy` again. Each cycle is ~5 minutes.

To update only the env (e.g. flip `ENABLE_RUNTIME_SECURITY` for the after picture) without re-deploying:

```bash
# Update the SSM parameter with new env contents
aws ssm put-parameter --name /demo/airs-bedrock-redteam/env \
    --type SecureString --value "$(cat .env)" --overwrite --region us-east-1

# Re-fetch and restart on the instance
INSTANCE=$(aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=aws-bedrock-redteam-demo" \
              "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" --output text)
aws ssm send-command --instance-ids "$INSTANCE" \
    --document-name AWS-RunShellScript --region us-east-1 \
    --parameters 'commands=[
      "sudo aws ssm get-parameter --name /demo/airs-bedrock-redteam/env --with-decryption --region us-east-1 --query Parameter.Value --output text > /opt/airs-demo/.env",
      "cd /opt/airs-demo && sudo docker compose down && sudo docker compose up -d"
    ]'
```

## Common deploy issues

**Cloud-init takes longer than 5 minutes**
Most often the docker compose build is genuinely slow (pip install, base image pull). Check the bootstrap log:

```bash
aws ssm send-command --region us-east-1 --instance-ids <id> \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["sudo tail -80 /var/log/airs-demo-bootstrap.log"]'
```

**"compose build requires buildx 0.17.0 or later"**
The buildx plugin install in cloud-init failed (network glitch, GitHub release URL changed). Re-run buildx install via SSM:

```bash
aws ssm send-command --instance-ids <id> --document-name AWS-RunShellScript \
  --region us-east-1 --parameters 'commands=[
    "sudo curl -sSL https://github.com/docker/buildx/releases/download/v0.17.1/buildx-v0.17.1.linux-amd64 -o /usr/libexec/docker/cli-plugins/docker-buildx",
    "sudo chmod +x /usr/libexec/docker/cli-plugins/docker-buildx"
  ]'
```

**Security-group delete fails on `--destroy`**
ENI cleanup can lag for a minute after the instance terminates. The script retries up to 4 times. If it still fails, wait 60 seconds and run `--destroy` again.

**`HTTP 400 inference profile` in container logs**
Same fix as the local case. Update `BEDROCK_MODEL_ID` in `.env`, push the new value to SSM Parameter Store with `aws ssm put-parameter --overwrite`, restart the container via SSM.

**`HTTP 404 ... use case details have not been submitted`**
Anthropic models on Bedrock require a one-time use-case form per AWS account. Open Bedrock -> Model access -> the Anthropic row -> Submit use case details. Wait 15 minutes. This is per-account, so a fresh Bedrock API key in a new account requires a new submission.
