# AWS EC2 Deployment

This page covers the full path: deploy a fresh demo target to your AWS
account, give AIRS a public URL, and tear it down when you're done.

## Prerequisites

- AWS CLI v2 installed and authenticated (e.g. `aws sso login`)
- Bedrock model access already granted in the same region you'll deploy to
- Local checkout of this repo with a working `.env` (see [QUICKSTART.md](QUICKSTART.md))
- An SSH client and `scp` (the script uses both)

## Verify your AWS context

```bash
aws sts get-caller-identity --query Arn --output text
```

You should see your role ARN. If you get `InvalidClientTokenId`, your SSO
session has expired or you're using a stale access key. Re-authenticate
before continuing.

## Deploy

```bash
./deploy-aws-vm.sh
```

What this does, in order:

1. Resolves the latest Amazon Linux 2023 AMI for your region via SSM.
2. Creates a keypair `aws-bedrock-redteam-demo` (saved to
   `./aws-bedrock-redteam-demo.pem`, mode 600, gitignored).
3. Creates a security group `aws-bedrock-redteam-demo-sg`:
   - Inbound 22/tcp from your current public IP/32 (auto-detected)
   - Inbound 8080/tcp from `0.0.0.0/0` by default (override via
     `RED_TEAM_CIDR=...`)
   - Outbound all
4. Launches a `t3.small` instance, tagged `Project=aws-bedrock-redteam-demo`.
5. Waits for the instance to reach `running` and SSH to be reachable.
6. Installs Docker via user-data (cloud-init); waits 60s for cloud-init.
7. `tar`s up the local repo (excluding `.git`, `.venv`, `*.pem`, `.env`),
   `scp`s it plus your `.env` to the instance.
8. SSHs in, builds the image, starts the container, runs a `/healthz` probe.
9. Prints the public URL and the AIRS target endpoint to use.

Total deploy time: about 4 to 6 minutes.

## Verify

The script ends with the `/healthz` body. You should see `"status": "ok"`
and `"bedrock_reachable": true`. If not, SSH in and check:

```bash
ssh -i ./aws-bedrock-redteam-demo.pem ec2-user@<public-ip>
cd ~/app
sudo docker compose ps
sudo docker compose logs app --tail 50
```

## Hand it to AIRS

Use the URL the script printed:
`http://<public-ip>:8080/v1/chat/completions`. The DEMO_API_KEY from
your `.env` is what AIRS sends as Bearer. See
[RED_TEAM_SETUP.md](RED_TEAM_SETUP.md) for the SCM-side configuration.

## Status

```bash
./deploy-aws-vm.sh --status
```

Tells you whether an instance tagged `Project=aws-bedrock-redteam-demo`
exists, its state, and the public URL.

## Tear down

```bash
./deploy-aws-vm.sh --destroy
```

Terminates the instance, deletes the security group (with retry for ENI
cleanup lag), and deletes the keypair plus local `.pem`. Set
`KEEP_KEY=true` to keep the keypair around for re-use.

The script is idempotent: running it after everything's already gone
just prints "No instance found" and exits clean.

## Customizing the deploy

All knobs are env vars:

| Var | Default | Notes |
| --- | --- | --- |
| `AWS_REGION` | `us-east-1` | Must match your Bedrock model access |
| `INSTANCE_TYPE` | `t3.small` | Bump to `t3.medium` if scan latency drives load |
| `APP_PORT` | `8080` | Change if you front with an ALB on 80/443 |
| `ADMIN_CIDR` | `<your IP>/32` | Restrict SSH ingress |
| `RED_TEAM_CIDR` | `0.0.0.0/0` | Set to AIRS source IPs in production |
| `KEY_NAME` | `aws-bedrock-redteam-demo` | Reuse a different keypair |
| `PROJECT_TAG` | `aws-bedrock-redteam-demo` | Used for resource discovery |

For a production-shape deployment, narrow `RED_TEAM_CIDR` to the AIRS
Red Teaming source IPs documented in your SCM tenant settings, and put
an ALB with TLS in front. The app itself does not terminate TLS.

## Common deploy issues

**Security-group delete fails on `--destroy`**
ENI cleanup can lag for a minute after the instance terminates. The
script retries up to 4 times. If it still fails, wait 60 seconds and
run `--destroy` again.

**SCP / SSH hangs after deploy**
First-boot cloud-init can take longer than the script's 60s wait on
some regions. SSH in manually and run `docker compose up -d --build`
in `~/app/`.

**`HTTP 400 inference profile` in container logs**
Same fix as the local case. Update `BEDROCK_MODEL_ID` in `.env`,
re-`scp` it to the instance, restart the container.
