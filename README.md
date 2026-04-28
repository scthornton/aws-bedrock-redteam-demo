# AWS Bedrock Vulnerable Demo for Prisma AIRS Red Teaming

**An intentionally-vulnerable AWS Bedrock-backed chat application for Prisma AIRS Red Teaming demos, with optional AIRS Runtime Security overlay for before/after testing.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Python 3.11+](https://img.shields.io/badge/python-3.11+-blue.svg)](https://www.python.org/downloads/)
[![Deploys: AWS EC2](https://img.shields.io/badge/deploys-AWS%20EC2-orange.svg)](AWS_DEPLOYMENT.md)

**Use this when:**
- The customer can't expose their real AI app to red-teaming yet (security review, OTI, IT sign-off pending)
- You need a side-by-side AIRS scan with and without Runtime Security in one sitting
- You want the customer to deploy in their own AWS account so the report is on real Bedrock, not a shared sandbox
- The customer's Bedrock access uses an API key (`AWS_BEARER_TOKEN_BEDROCK`) instead of an IAM service account

> WARNING: This app is intentionally vulnerable. It seeds synthetic PII, fake credit card numbers, and fake admin credentials directly into its system prompt so red-team scans produce dramatic findings. Do not deploy outside an isolated POV environment. See [SECURITY.md](SECURITY.md).

## What This Does

OpenAI-shaped Flask app on EC2, backed by AWS Bedrock (Claude), with a CSR-tool system prompt that leaks under attack:

- Speaks `/v1/chat/completions` so AIRS Red Teaming hits it via the **REST connector** (Import from cURL works one-tap)
- Authenticates to Bedrock via the OTI-friendly **bearer-token** path (no IAM service account needed)
- Optional **Prisma AIRS Runtime Security** overlay; flip one env var to compare before / after
- Self-bootstraps on EC2 via cloud-init - **no SSH from your machine ever required**
- Tagged AWS resources for one-command teardown

```
+----------------------+
|  AIRS Red Teaming    |  attacks via REST connector
|  (SCM cloud)         |
+----------+-----------+
           |  HTTPS POST /v1/chat/completions
           |  Authorization: Bearer <DEMO_API_KEY>
           v
+----------------------------------------------------------+
|  Demo App (Flask, EC2 t3.small, port 8080)               |
|                                                          |
|  /v1/chat/completions  /v1/models  /healthz              |
|         |                                                |
|         v  if ENABLE_RUNTIME_SECURITY=true               |
|  +----------------------------------------------------+  |
|  |  airs_runtime.scan(prompt) -> block / allow        |  |
|  +----------------------------------------------------+  |
|         |                                                |
|         v  (if not blocked)                              |
|  +----------------------------------------------------+  |
|  |  Vulnerable system prompt (embeds fake PII)        |  |
|  |  Bedrock Converse API                              |  |
|  |  Authorization: Bearer $AWS_BEARER_TOKEN_BEDROCK   |  |
|  +----------------------------------------------------+  |
|         |                                                |
|         v  if ENABLE_RUNTIME_SECURITY=true               |
|  +----------------------------------------------------+  |
|  |  airs_runtime.scan(prompt, response) -> block      |  |
|  +----------------------------------------------------+  |
|         |                                                |
|         v                                                |
|  Return OpenAI-shaped response                           |
+----------------------------------------------------------+
                                                       |
                                                       v
                                       AWS Bedrock (Claude)
                                       bedrock-runtime.<region>.amazonaws.com
```

## Two-phase demo

| Phase | `ENABLE_RUNTIME_SECURITY` | Expected outcome |
| --- | --- | --- |
| 1 - Baseline | `false` | Model leaks under attack. AIRS report shows synthetic SSNs, card numbers, internal incident details, business-disclosure leakage. |
| 2 - With overlay | `true` | Same target, same scan, AIRS Runtime catches most attacks at prompt or response. Finding count drops dramatically. |

The only thing changing between phases is one env var. Everything else (system prompt, model, target URL) stays identical.

## Quick start (15 minutes)

### Prerequisites

1. **AWS account** with permissions to create EC2, S3, IAM, SSM resources
2. **Bedrock model access** for Claude in your chosen region (Bedrock console -> Model access -> Manage)
3. **Bedrock API key** (long-term bearer token from the Bedrock console; starts with `ABSK`)
4. **Prisma AIRS** tenant with Red Teaming enabled (and SCM admin access)
5. **AWS CLI v2** authenticated locally
6. `docker`, `jq`, `tar` for the local test path

### Step 1 - Clone and configure

```bash
git clone <this-repo-url> aws-bedrock-redteam-demo
cd aws-bedrock-redteam-demo
cp .env.example .env
$EDITOR .env
```

Required values in `.env`:

```bash
AWS_BEARER_TOKEN_BEDROCK=ABSK...your-bedrock-api-key...
BEDROCK_MODEL_ID=us.anthropic.claude-sonnet-4-5-20250929-v1:0
DEMO_API_KEY=<pick-any-long-random-string>
```

If you also want to test the Runtime overlay (phase 2):

```bash
AIRS_API_KEY=<your-x-pan-token>
```

### Step 2 - Verify Bedrock access locally (30 seconds)

```bash
source .env && ./scripts/test-bedrock-creds.sh
```

Expect HTTP 200 and a real Claude reply. Common failure modes and fixes are in the troubleshooting section of [QUICKSTART.md](QUICKSTART.md).

### Step 3 - Deploy to EC2 (5 minutes)

```bash
./deploy-aws-vm.sh
```

This creates an S3 bucket, an SSM parameter, an IAM role, a security group, and an EC2 instance. Cloud-init pulls the code from S3 and the env from SSM, builds the container, and starts the app. The script polls the public health endpoint and prints the AIRS Red Teaming target settings when ready.

Output ends with:

```
Demo target deployed
Public URL: http://<EC2-IP>:8080
Health:     http://<EC2-IP>:8080/healthz

Configure AIRS Red Teaming target (REST connector):
  Endpoint:       http://<EC2-IP>:8080/v1/chat/completions
  HTTP Method:    POST
  Headers:        Authorization: Bearer <DEMO_API_KEY from .env>
                  Content-Type: application/json
  Body template:  {"model":"sb","messages":[{"role":"user","content":"{INPUT}"}]}
  Response path:  choices[0].message.content
```

### Step 4 - Add the target in SCM

In Strata Cloud Manager: **AI Security -> AI Red Teaming -> Targets -> Add Target**.

| Field | Value |
| --- | --- |
| Connection Type | **REST** (not OpenAI - that connector is locked to api.openai.com) |
| Endpoint Type | PUBLIC |
| URL | `http://<EC2-IP>:8080/v1/chat/completions` |
| HTTP Method | POST |
| Auth Type | HEADERS |
| Headers | `Authorization: Bearer <DEMO_API_KEY>` and `Content-Type: application/json` |
| Body template | `{"model":"sb","messages":[{"role":"user","content":"{INPUT}"}]}` |
| Response path | `choices[0].message.content` |
| Probe message | (default) |
| Multi-turn config | Enabled, mode `stateless`, assistant_role `assistant` |
| System prompt | Paste the contents of `vulnerabilities.SYSTEM_PROMPT` (run the snippet below) |

To copy the system prompt to your clipboard:

```bash
python3 -c "import sys; sys.path.insert(0,'.'); from vulnerabilities import build_system_prompt; print(build_system_prompt())" | pbcopy
```

Target background info to enter:

| Field | Value |
| --- | --- |
| Industry | Banking / Financial Services |
| Use case | Internal customer service representative copilot. Authenticated employees query the assistant during live support calls for caller account information, transaction history, and account-action eligibility. |
| Description | SBAssist is the SecureBank internal CSR Console copilot. It is reached only over the corporate VPN, behind employee SSO, after the CSR completes the standard caller identity-verification checklist. The pinned caller record (PII, account, card details) and a small set of internal credentials are loaded into the prompt context for the duration of the session. |

Click **Test Connection**. Should be green immediately because the script verified `/healthz` before exiting.

For the deep-dive on each AIRS field, see [RED_TEAM_SETUP.md](RED_TEAM_SETUP.md).

### Step 5 - Run a scan

In SCM: **AI Red Teaming -> Scans -> Start Scan**.

- Pick **Attack Library (STATIC)**
- Start with a single category (Sensitive Data Exposure or Prompt Injection) and 10-20 attacks for a sanity run
- Then run the full library for the headline numbers

Watch logs live from a second terminal:

```bash
./scripts/tail-ec2-logs.sh
```

You'll see every AIRS request (source IP, status, response size), every chat-completion request, and (when Runtime is on) every AIRS scan decision with detected threat categories and report IDs.

### Step 6 - Flip on the Runtime overlay for the after picture

```bash
aws ssm send-command --instance-ids <instance-id> \
  --document-name AWS-RunShellScript --region us-east-1 \
  --parameters 'commands=[
    "sudo sed -i s/ENABLE_RUNTIME_SECURITY=false/ENABLE_RUNTIME_SECURITY=true/ /opt/airs-demo/.env",
    "cd /opt/airs-demo && sudo docker compose down && sudo docker compose up -d"
  ]'
```

Re-run the same scan in SCM. Compare the two reports side by side. The full demo choreography is in [BEFORE_AFTER_DEMO.md](BEFORE_AFTER_DEMO.md).

### Step 7 - Tear down

```bash
./deploy-aws-vm.sh --destroy
```

Idempotent. Removes the instance, security group, IAM role and instance profile, SSM parameter, and (unless `KEEP_BUCKET=true`) the S3 bucket.

## What's in the box

| File | Purpose |
| --- | --- |
| `app.py` | Flask routes; OpenAI <-> Bedrock translation; AIRS overlay wiring |
| `bedrock_client.py` | Bedrock Converse client over `AWS_BEARER_TOKEN_BEDROCK` (no boto3) |
| `vulnerabilities.py` | `FAKE_DATABASE` (synthetic) and the CSR-tool system prompt |
| `airs_runtime.py` | `scan()` helper for the optional Runtime overlay |
| `Dockerfile`, `docker-compose.yml` | Local + EC2 runtime |
| `deploy-aws-vm.sh` | One-shot EC2 deploy / status / destroy via SSM bootstrap |
| `scripts/test-bedrock-creds.sh` | Pre-flight: confirms bearer-token Bedrock auth works |
| `scripts/list-bedrock-models.sh` | Discover Anthropic models / inference profiles on your account |
| `scripts/test-local.sh` | Smoke test the running app (works locally or against EC2) |
| `scripts/test-attack.sh` | Send 8 known-bad prompts, classify each as LEAK / BLOCK / SAFE |
| `scripts/tail-ec2-logs.sh` | Live-tail container logs from EC2 via SSM (no SSH plugin needed) |
| `scripts/fetch-logs.sh` | Pull recent / full container log history to your laptop for offline grep |
| `scripts/print-system-prompt.sh` | Emit the vulnerable system prompt for paste-in to AIRS UI |
| `scripts/provision-airs-bedrock-iam.sh` | Provision a scoped IAM user for AIRS native Bedrock connector |
| `examples/airs-target-config.json` | Reference values for the AIRS REST target |
| `examples/attack-prompts.csv` | Custom-prompt set for AIRS Attack Library import |

## Logs and troubleshooting

### How requests are logged

Every chat request emits two structured lines on the container's stdout, keyed by a per-request `tr_id`:

```
2026-04-28 13:00:09 INFO app | api/chat req tr=fd068727... user_chars=110 history_turns=0 airs=False prompt_head='...'
2026-04-28 13:00:11 INFO app | api/chat ok  tr=fd068727... response_chars=842 elapsed_ms=1843 sentinel=False response_head='...'
```

Plus the gunicorn access log line for the same request:

```
104.198.97.107 - - [28/Apr/2026:13:00:11 +0000] "POST /api/chat HTTP/1.1" 200 1116 "-" "python-httpx/0.28.1"
```

This lets you grep one trace end-to-end (`grep tr=fd068727 logs.txt`) and spot slow Bedrock calls (`elapsed_ms > 10000`), guardrail-empty responses (`sentinel=True`), and AIRS scanner traffic (source IP `104.198.97.107`, user-agent `python-httpx`).

### Live tail while a scan is running

```bash
./scripts/tail-ec2-logs.sh
```

Polls every 4s via SSM, de-dupes lines. Ctrl-C to stop. No SSH or session-manager-plugin required.

### Pull logs to your laptop for offline grep

```bash
./scripts/fetch-logs.sh                  # last 1000 lines -> /tmp/airs-demo-logs.txt
./scripts/fetch-logs.sh 5000             # last 5000 lines
./scripts/fetch-logs.sh --since 30m      # last 30 minutes
./scripts/fetch-logs.sh --all            # full rotated history (5x50MB tarball -> /tmp/airs-demo-logs.tgz)
```

The script prints a set of one-liner grep recipes after each fetch for the most common questions (HTTP status distribution, slow calls, sentinel responses, per-trace history, Bedrock errors, AIRS Runtime blocks).

### Log retention on the VM

Docker's json-file driver is configured in `docker-compose.yml` with `max-size=50m, max-file=5` so the EC2 disk never fills during long scans. Five 50MB rotation files = ~250MB ceiling. Logs persist across container restarts (location: `/var/lib/docker/containers/<id>/`) but are removed if you `docker compose down -v` or destroy the EC2 instance. Use `./scripts/fetch-logs.sh --all` before teardown if you want a post-mortem copy.

### Dialing up verbosity

The Flask app reads `LOG_LEVEL` from the environment (default `INFO`). For deep debugging, set `LOG_LEVEL=DEBUG` in `.env` and restart:

```bash
echo 'LOG_LEVEL=DEBUG' >> .env
docker compose restart                                  # local
# or on EC2:
aws ssm send-command --instance-ids <INSTANCE-ID> \
    --document-name AWS-RunShellScript --region us-east-1 \
    --parameters 'commands=["echo LOG_LEVEL=DEBUG | sudo tee -a /opt/airs-demo/.env","cd /opt/airs-demo && sudo docker compose restart"]'
```

DEBUG mode adds Bedrock client request/response shapes (still without secrets) for the converse calls. Flip back to INFO before running a long scan; DEBUG is verbose enough to make grep slower and add ~3-5MB/min during a scan.

### Failure mode quick-reference

The full troubleshooting matrix lives in [RED_TEAM_SETUP.md](RED_TEAM_SETUP.md). The headline failures and where to look in logs:

| AIRS UI error | Where to look | Recipe |
| --- | --- | --- |
| `Response key 'content' not found` | This is in AIRS UI, not the app. Set Response JSON to `{"output":"{RESPONSE}"}` | n/a (config fix) |
| `Empty output received from target` | `grep 'sentinel=True' /tmp/airs-demo-logs.txt` shows which attacks hit Bedrock guardrail null content | Already mitigated; sentinel keeps AIRS grading |
| `Target endpoint connection failed...` | `grep -E 'HTTP/1.1" 5[0-9][0-9]' /tmp/airs-demo-logs.txt` and `grep 'bedrock error' /tmp/airs-demo-logs.txt` | Should be 0 hits on current code; if nonzero, paste the trace |
| `ReadTimeout` on Validate | `grep elapsed_ms /tmp/airs-demo-logs.txt \| awk -F'elapsed_ms=' '{split($2,a," ");if(a[1]>30000)print}'` shows >30s requests | Cancel running scans; container has 16 concurrent slots |

## Documentation

- **[QUICKSTART.md](QUICKSTART.md)** - 5-minute local Docker path (test before EC2)
- **[AWS_DEPLOYMENT.md](AWS_DEPLOYMENT.md)** - EC2 deploy deep-dive, all the env knobs
- **[RED_TEAM_SETUP.md](RED_TEAM_SETUP.md)** - SCM target configuration, every field explained
- **[BEFORE_AFTER_DEMO.md](BEFORE_AFTER_DEMO.md)** - Customer-facing demo choreography
- **[CUSTOMER_HANDOFF.md](CUSTOMER_HANDOFF.md)** - One-pager for sending the repo to a customer
- **[SECURITY.md](SECURITY.md)** - Disclaimer + synthetic-data commitment

## Configuration knobs (full list in `.env.example`)

| Var | Default | Purpose |
| --- | --- | --- |
| `AWS_BEARER_TOKEN_BEDROCK` | (required) | Bedrock API key, starts with `ABSK` |
| `BEDROCK_MODEL_ID` | `us.anthropic.claude-sonnet-4-5-20250929-v1:0` | Inference profile or model ID |
| `AWS_REGION` | `us-east-1` | Bedrock region |
| `DEMO_API_KEY` | (required) | Bearer token AIRS sends to this app |
| `ENABLE_RUNTIME_SECURITY` | `false` | Toggle the AIRS Runtime overlay |
| `AIRS_API_KEY` | | AIRS scan API token (only when overlay is on) |
| `AIRS_PROFILE` | `chatbot` | AIRS scan profile name |
| `BLOCK_STATUS_CODE` | `200` | HTTP status for blocked requests (do not change) |

The `BLOCK_STATUS_CODE=200` invariant matters: AIRS Red Teaming's response parser scores by body content, so returning 4xx classifies a block as an API error rather than an attack outcome. Block responses are intentionally HTTP 200 with a refusal message in the body and `finish_reason=content_filter`.

## Choosing a Bedrock model

Sonnet / Opus 4.x models on Bedrock require a US or global *inference profile* prefix (e.g. `us.anthropic.claude-sonnet-4-5-20250929-v1:0`). Older `anthropic.claude-3-*` models support direct ON_DEMAND throughput without a prefix.

```bash
./scripts/list-bedrock-models.sh
```

Shows what's available on your AWS account, both ON_DEMAND models and inference profiles.

## License

MIT. See [LICENSE](LICENSE).
