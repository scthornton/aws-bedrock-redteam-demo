# AWS Bedrock Vulnerable Demo for Prisma AIRS Red Teaming

An intentionally vulnerable AWS Bedrock-backed chat app for Prisma AIRS Red Teaming demos, with an optional AIRS Runtime Security overlay for before/after testing.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Python 3.11+](https://img.shields.io/badge/python-3.11+-blue.svg)](https://www.python.org/downloads/)
[![Deploys: AWS EC2](https://img.shields.io/badge/deploys-AWS%20EC2-orange.svg)](#deploy)

> **Warning:** Synthetic PII, fake card numbers, and fake admin credentials are seeded directly into the system prompt so red-team scans produce dramatic findings. Do not deploy outside an isolated POV environment. See [SECURITY.md](SECURITY.md).

## Use this when

- The customer can't expose their real AI app to red-teaming yet (security review, OTI, IT sign-off pending)
- You need a side-by-side AIRS scan with and without Runtime Security in one sitting
- The customer's Bedrock access uses an API key (`AWS_BEARER_TOKEN_BEDROCK`) instead of an IAM service account

## Architecture

```
+----------------------+
|  AIRS Red Teaming    |  attack prompts via REST connector
|  (SCM cloud)         |
+----------+-----------+
           |  POST /api/chat
           |  Authorization: Bearer <DEMO_API_KEY>
           v
+----------------------------------------------------------+
|  Demo App (Flask, EC2 t3.small, port 8080)               |
|                                                          |
|  /api/chat  /v1/chat/completions  /healthz               |
|         |                                                |
|         v  if ENABLE_RUNTIME_SECURITY=true               |
|   +-----------------+  pre-scan blocks before Bedrock    |
|   | AIRS Runtime    |  post-scan blocks unsafe responses |
|   +--------+--------+                                    |
|            v                                             |
|     Bedrock Converse API (Authorization: Bearer ABSK...) |
+----------------------------------------------------------+
```

The vulnerable surface lives in the **system prompt** (`vulnerabilities.py`): a CSR-tool persona for "SecureBank" loaded with synthetic PII, fake transaction history, fake admin credentials, and weak role boundaries. Prompt-injection / role-confusion attacks succeed reliably even against well-aligned models because the leak target is already inside the prompt context.

## Deploy

End-to-end EC2 deployment via SSM bootstrap. No SSH from your laptop required.

**Prerequisites:**
- AWS CLI v2 authenticated (`aws sso login` or static creds), permissions to launch EC2, IAM, S3, and SSM. If you use SSO profiles, export it first: `export AWS_PROFILE=<your-profile-name>`
- Bedrock model access granted in your chosen region. In the AWS console: **Amazon Bedrock -> Model access -> Modify model access -> check Anthropic Claude models -> Submit**. Takes ~15 min to activate.
- Bedrock API key (bearer token starting with `ABSK`). In the AWS console: **Amazon Bedrock -> API keys -> Create API key**. Copy the token immediately, it is shown only once.
- Docker (only needed if you also want to run locally)

**Deploy:**

```bash
git clone https://github.com/scthornton/aws-bedrock-redteam-demo.git
cd aws-bedrock-redteam-demo
cp .env.example .env

# Edit .env - fill in these two required values:
#   AWS_BEARER_TOKEN_BEDROCK=ABSK...   (your Bedrock API key from above)
#   DEMO_API_KEY=<random string>       (generate one with the command below)
nano .env

# If you need a random API key for DEMO_API_KEY:
#   python3 -c "import secrets; print(secrets.token_hex(24))"

set -a; source .env; set +a           # export env vars for the test scripts below
./scripts/test-bedrock-creds.sh       # pre-flight: confirms bearer-token Bedrock auth works
./deploy-aws-vm.sh                    # 4-6 min: S3, IAM, SG, EC2, cloud-init bootstrap
```

The deploy script ends by printing the AIRS target settings. Test the live endpoint from your laptop:

```bash
curl -X POST 'http://<EC2-IP>:8080/api/chat' \
  -H 'Authorization: Bearer <DEMO_API_KEY>' \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"reply with one word: pong"}]}'
# Expected: {"output": "pong"} in 2-5 seconds
```

**Verify the deployment:**

```bash
# Is the app healthy?
curl -sS http://<EC2-IP>:8080/healthz | python3 -m json.tool

# Quick ping test (should return {"output":"pong"})
curl -sS -X POST http://<EC2-IP>:8080/api/chat \
  -H 'Authorization: Bearer <DEMO_API_KEY>' \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"reply with one word: pong"}]}'

# Is AIRS scan traffic arriving? (run during a scan)
./scripts/fetch-logs.sh --since 5m && grep 'POST /api/chat' /tmp/airs-demo-logs.txt

# HTTP status distribution (should be all 200s)
grep -oE 'HTTP/1.1" [0-9]+' /tmp/airs-demo-logs.txt | sort | uniq -c | sort -rn

# Live tail (watch requests in real-time, Ctrl-C to stop)
./scripts/tail-ec2-logs.sh
```

**Status / teardown:**

```bash
./deploy-aws-vm.sh --status
./deploy-aws-vm.sh --destroy          # removes EC2, SG, IAM role, SSM param, and S3 bucket
```

### Deploying multiple targets (different models)

You can run multiple instances side-by-side to compare red teaming results across
models. Each instance needs its own `PROJECT_TAG`, `SSM_PARAM_NAME`, and `.env` file
with a different `BEDROCK_MODEL_ID`. All other code is shared.

```bash
# Create a second .env for Opus 4.5
cp .env .env.opus
# Edit .env.opus: change BEDROCK_MODEL_ID and APP_NAME
#   BEDROCK_MODEL_ID=us.anthropic.claude-opus-4-5-20251101-v1:0
#   APP_NAME=aws-bedrock-redteam-opus

# Deploy with a separate project tag and SSM param
PROJECT_TAG="aws-bedrock-redteam-opus" \
SSM_PARAM_NAME="/demo/airs-bedrock-redteam-opus/env" \
ENV_FILE="$(pwd)/.env.opus" \
  ./deploy-aws-vm.sh deploy

# Status / teardown for the second instance
PROJECT_TAG="aws-bedrock-redteam-opus" \
SSM_PARAM_NAME="/demo/airs-bedrock-redteam-opus/env" \
  ./deploy-aws-vm.sh --status

PROJECT_TAG="aws-bedrock-redteam-opus" \
SSM_PARAM_NAME="/demo/airs-bedrock-redteam-opus/env" \
  ./deploy-aws-vm.sh --destroy
```

Each instance gets its own EC2 instance, security group, IAM role, and S3 bucket,
all namespaced by `PROJECT_TAG`. Create a separate AIRS Red Teaming target for each
and run the same scan against both to compare model resilience.

## Configure AIRS Red Teaming target

Full field-by-field walkthrough lives in **[RED_TEAM_SETUP.md](RED_TEAM_SETUP.md)**. The 30-second version:

In SCM: AI Security -> AI Red Teaming -> Targets -> Add Target -> Connection Method: **REST API** -> **Import from cURL**.

```bash
curl 'http://<EC2-IP>:8080/api/chat' \
  -H 'Authorization: Bearer <DEMO_API_KEY>' \
  -H 'Content-Type: application/json' \
  --data '{"messages":[{"role":"user","content":"{INPUT}"}]}'
```

After import, **set the Response JSON to `{"output":"{RESPONSE}"}` exactly**. The cURL importer auto-fills it wrong (as `{"content":"{RESPONSE}"}`) and that single field is the difference between scans grading and scans erroring with "Response key 'content' not found" / "Empty output received from target".

Paste the system prompt into Additional Context -> System Prompt:

```bash
./scripts/print-system-prompt.sh | pbcopy          # macOS
# ./scripts/print-system-prompt.sh | xclip -sel c  # Linux
# ./scripts/print-system-prompt.sh                  # prints to terminal, copy manually
```

Validate. Then run a 10-attack PROMPT_INJECTION scan first to confirm grading before launching the full Attack Library.

## Two-phase before/after demo

The headline customer demo: same scan, same target, with and without the AIRS Runtime overlay.

**Phase 1 - Runtime OFF (vulnerable baseline):**

Confirm `ENABLE_RUNTIME_SECURITY=false` is set, run the AIRS Attack Library against the target, capture the report. Expect dramatic findings - synthetic SSN/PCI leaks, system-prompt extraction, role confusion, the seeded incident postmortem, the OFFSHORE-LTD wire transfer story.

**Flip the overlay on:**

```bash
INSTANCE=$(aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=aws-bedrock-redteam-demo" \
              "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" --output text)

aws ssm send-command --instance-ids "$INSTANCE" \
    --document-name AWS-RunShellScript --region us-east-1 \
    --parameters 'commands=[
        "sudo sed -i \"s/^ENABLE_RUNTIME_SECURITY=.*/ENABLE_RUNTIME_SECURITY=true/\" /opt/airs-demo/.env",
        "cd /opt/airs-demo && sudo docker compose restart"
    ]'
```

Verify with `curl http://<EC2-IP>:8080/healthz`; `runtime_security_enabled` flips to true.

**Phase 2 - Runtime ON:**

Re-run the **same** scan against the **same** target. Finding count drops dramatically. The delta is the demo. Export both reports as PDF and CSV.

**After the demo:**

```bash
./deploy-aws-vm.sh --destroy
```

## Local development

The same container runs on your laptop:

```bash
cp .env.example .env && nano .env      # fill in AWS_BEARER_TOKEN_BEDROCK and DEMO_API_KEY
docker compose up -d
set -a; source .env; set +a            # export env vars for the test scripts below
./scripts/test-local.sh                # smoke test: /healthz, benign chat, auth check
./scripts/test-attack.sh               # send 8 known-bad prompts, classify LEAK / BLOCK / SAFE
```

Run `test-attack.sh` once with `ENABLE_RUNTIME_SECURITY=false` and once with `=true` to see the same prompts go from LEAK to BLOCK. Useful for sanity-checking before pointing AIRS at it.

## Logs and troubleshooting

### Structured per-request logs

Every chat request emits two lines keyed by a unique `tr_id`:

```
2026-04-28 13:00:09 INFO app | api/chat req tr=fd068727... user_chars=110 history_turns=0 airs=False prompt_head='...'
2026-04-28 13:00:11 INFO app | api/chat ok  tr=fd068727... response_chars=842 elapsed_ms=1843 sentinel=False response_head='...'
```

Plus the gunicorn access line. Grep one trace end-to-end with `grep tr=fd068727`. Source IP `104.198.97.107` is AIRS; user-agent `python-httpx` confirms scanner traffic.

### View logs

```bash
./scripts/tail-ec2-logs.sh             # live tail via SSM (no SSH needed)
./scripts/fetch-logs.sh                # last 1000 lines -> /tmp/airs-demo-logs.txt
./scripts/fetch-logs.sh --since 30m    # last 30 minutes
./scripts/fetch-logs.sh --all          # full rotated history (5x50MB tarball)
```

`fetch-logs.sh` prints grep one-liners for the most common questions (HTTP status distribution, slow calls, sentinel responses, Bedrock errors, AIRS Runtime blocks).

Docker is configured for log rotation (`max-size=50m, max-file=5`, ~250MB ceiling) so long scans never fill the EC2 disk. Logs persist across container restarts.

### Failure mode quick-reference

| AIRS UI error | Cause | Fix |
| --- | --- | --- |
| `Response key 'content' not found` | Response JSON template is `{"content":"{RESPONSE}"}` (cURL-import auto-fill) | Set Response JSON to `{"output":"{RESPONSE}"}` exactly |
| `Empty output received from target` | Bedrock returned empty for a guardrail-filtered prompt | Already mitigated in app.py: empty output substituted with `[empty model response]` sentinel |
| `Target endpoint connection failed...` | App returned non-2xx | Already mitigated: all errors return HTTP 200 with sentinel string |
| `ReadTimeout` on Validate | gunicorn workers all busy with an in-progress scan | Cancel running scans first; container has 4 workers x 4 threads = 16 concurrent slots |
| `Invalid API key` (401) on test cURL | Shell expanded `${DEMO_API_KEY}` from parent shell (empty) before inline assignment | Either `export DEMO_API_KEY=...` first, or paste the literal key into curl |
| `Connection refused` / `timeout` | EC2 not reachable from AIRS source IPs | Confirm SG inbound 8080 from `0.0.0.0/0` (or AIRS source IP `104.198.97.107`); confirm container up via `./deploy-aws-vm.sh --status` |
| Findings count unexpectedly low | Runtime overlay accidentally left ON during Phase 1 | Set `ENABLE_RUNTIME_SECURITY=false`, restart container |

The full troubleshooting matrix lives in [RED_TEAM_SETUP.md](RED_TEAM_SETUP.md).

## What's in the box

| File | Purpose |
| --- | --- |
| `app.py` | Flask routes; OpenAI <-> Bedrock translation; AIRS overlay wiring |
| `bedrock_client.py` | Bedrock Converse client over `AWS_BEARER_TOKEN_BEDROCK` (no boto3) |
| `vulnerabilities.py` | `FAKE_DATABASE` (synthetic) and the CSR-tool system prompt |
| `airs_runtime.py` | `scan()` helper for the optional Runtime overlay |
| `Dockerfile`, `docker-compose.yml` | Local + EC2 runtime; gunicorn 4w x 4t with json-file log rotation |
| `deploy-aws-vm.sh` | One-shot EC2 deploy / status / destroy via SSM bootstrap |
| `scripts/` | Pre-flight checks, log tailing/fetching, system-prompt printer, IAM provisioner for AIRS native Bedrock |
| `examples/attack-prompts.csv` | Custom-prompt set for AIRS Attack Library import |

## Configuration knobs

Full list in `.env.example`. Highlights:

| Var | Default | Purpose |
| --- | --- | --- |
| `AWS_BEARER_TOKEN_BEDROCK` | (required) | Bedrock API key, `ABSK...` |
| `BEDROCK_MODEL_ID` | `us.anthropic.claude-3-haiku-20240307-v1:0` | Inference profile or model ID (see `.env.example` for common IDs) |
| `DEMO_API_KEY` | (required) | Bearer token AIRS sends to this app |
| `ENABLE_RUNTIME_SECURITY` | `false` | Flip to `true` for Phase 2 of the demo |
| `AIRS_API_KEY`, `AIRS_PROFILE`, `AIRS_API_URL` | - | Required only when Runtime overlay is on |
| `BLOCK_STATUS_CODE` | `200` | **Do not change.** AIRS scores by body content; non-2xx classifies as API error |
| `LOG_LEVEL` | `INFO` | Set `DEBUG` for deep request/response tracing |

## Documentation

- **[RED_TEAM_SETUP.md](RED_TEAM_SETUP.md)** - Full AIRS target configuration walkthrough + troubleshooting matrix
- **[SECURITY.md](SECURITY.md)** - Disclaimer + synthetic-data commitment

## License

MIT - see [LICENSE](LICENSE).
