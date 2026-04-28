# Configuring the AIRS Red Teaming Target

Once the demo is reachable on a public URL (locally or on EC2), this is how to wire it up as a Red Teaming target in Strata Cloud Manager. The recommended path uses the **AIRS native AWS Bedrock connection method** - AIRS calls Bedrock directly with our vulnerable system prompt, no Flask app or REST parsing in the loop. The Flask app stays in the picture only for Phase 2 (Runtime overlay before/after demo).

Two configuration options are documented below:

| Option | Use when | Connection Method | Notes |
| --- | --- | --- | --- |
| **A. AWS Bedrock (recommended)** | Phase 1 baseline scan on a Bedrock-backed target | AWS Bedrock | Cleanest path. AIRS hits Bedrock directly with our system prompt loaded. No REST parsing surface area. |
| **B. REST against the Flask app** | Phase 2 (Runtime overlay ON) or any target where Bedrock native is unavailable | REST | Required for the before / after Runtime demo, since the AIRS Runtime overlay lives inside the Flask app. |

## Prerequisites (both options)

- A Prisma AIRS tenant with Red Teaming enabled
- SCM admin or AI Security admin role
- Bedrock model access approved on the AWS account for the auth mode you'll use (see Option A's "AWS account approval" step below if using sigv4)

---

## Option A: AWS Bedrock connection method (recommended)

### A.1 - One-time AWS account approval for sigv4 access

AIRS's Bedrock connector authenticates with **IAM access key + secret (sigv4)**. AWS Bedrock gates sigv4 access to Anthropic models behind a use-case form that is **separate from the bearer-token approval** the Flask app uses. If you only ever ran the Flask app's bearer-token path, sigv4 access on this account is probably still pending.

To check / request approval:

1. AWS console -> Bedrock -> **Model access** (left nav).
2. Find the Claude model you intend to use (e.g. `Claude Sonnet 4.5 (cross-region inference)`).
3. If status is not "Access granted", click **Manage model access** -> **Request model access**.
4. Fill out the Anthropic use-case form (industry, use case, employee count, intended use) and submit.
5. Wait ~15 minutes. Re-check via `./scripts/test-bedrock-creds.sh` (uses bearer token) and `aws bedrock-runtime converse ...` (sigv4) until both succeed.

If Bedrock console shows a "Model use case details have not been submitted" banner when you try to invoke a Claude model with sigv4, the form has not been completed for this auth path on this account. Bearer-token access alone is not enough.

### A.2 - Provision a scoped IAM user for AIRS

Run the provided helper. It creates an IAM user with the minimum policy AIRS needs (Bedrock invoke + list on Anthropic Claude models only) and prints a one-time access key / secret to paste into the AIRS UI.

```bash
./scripts/provision-airs-bedrock-iam.sh
```

The output looks like:

```
Region:           us-east-1
IAM Access ID:    AKIA...
IAM Access Secret:...
Model Name:       us.anthropic.claude-sonnet-4-5-20250929-v1:0
```

When the demo is over, revoke with:

```bash
./scripts/provision-airs-bedrock-iam.sh --destroy
```

### A.3 - Add the target in SCM

In SCM: **AI Security -> AI Red Teaming -> Targets -> Add Target**.

| Field | Value |
| --- | --- |
| Name | `aws-bedrock-redteam-demo` |
| Target Type | APPLICATION |
| Connection Method | **AWS Bedrock** |
| Endpoint Type | PUBLIC |
| Region | `us-east-1` |
| IAM Access ID | (from `provision-airs-bedrock-iam.sh` output) |
| IAM Access Secret | (from `provision-airs-bedrock-iam.sh` output) |
| Session Token | (leave blank - long-term access key) |
| Model Name | `us.anthropic.claude-sonnet-4-5-20250929-v1:0` |
| Model Streaming | off |

### A.4 - Paste the vulnerable system prompt

In the **Additional Context** section of the target form:

| Field | Value |
| --- | --- |
| System Prompt | (output of `./scripts/print-system-prompt.sh`) |
| Base Model | `Anthropic Claude Sonnet 4.5` |
| Core Architecture | Single-LLM with system-prompt-embedded RAG context |
| Languages Supported | English |
| Banned Keywords | (leave blank) |
| Tools Accessible | (leave blank) |

Copy the system prompt to your clipboard (does not echo to terminal):

```bash
./scripts/print-system-prompt.sh | pbcopy
```

The system prompt is what makes this demo a vulnerable target. It contains the synthetic FAKE_DATABASE, weak role boundaries, and the pre-seeded "verified user" loophole that the AIRS Attack Library exploits. Without it, AIRS hits raw Claude and the scan grades as "model alignment is decent" - which is a much weaker demo. With it, expect 50 to 100+ findings on the Attack Library.

### A.5 - Target Background

| Field | Value |
| --- | --- |
| Industry | Banking / Financial Services |
| Use Case | Internal customer service representative copilot. Authenticated employees query the assistant for caller account information, transaction history, and account-action eligibility during live support calls. |
| Competitors | (leave blank) |

### A.6 - Multi-turn

Multi-turn isn't directly applicable to native Bedrock targets (AIRS handles the messages array itself). Leave at default. Multi-turn SECURITY rules will run normally because AIRS owns the conversation state.

### A.7 - Validate, then scan

1. Click **Test Connection** / **Validate**. Should be green within seconds.
2. Save the target.
3. From the target detail page, click **Run Scan** -> **Attack Library**.
4. For the first run, pick a single category (Sensitive Data Exposure or Prompt Injection) and 10-20 attacks. Verify the response capture is non-empty before committing scan time to the full library.
5. Once the small scan looks right, run the full Attack Library for headline numbers.

---

## Option B: REST connector against the Flask app

Use this when:

- Phase 2 of the demo (Runtime overlay ON) - the Flask app sits between AIRS and Bedrock and runs the Runtime scan pre/post.
- AWS account does not yet have sigv4 access for Bedrock (and you can't wait for the form approval).
- Customer environment does not allow direct AIRS -> Bedrock egress.

The app exposes two endpoints. Pick whichever matches the response-extraction style your AIRS UI exposes.

### B.1 - URL choice

- **`/v1/chat/completions`** - canonical OpenAI shape. Configure with `Response path` = `choices[0].message.content`. Matches the AIRS docs verbatim.
- **`/api/chat`** - flat single-key shape `{"output":"<text>"}`. Configure with `Response path` = `output`. Matches the proven DVLA flat-shape pattern customers already run successfully.

If one fails to grade attacks after a fresh import, switch to the other. They call the same Bedrock backend.

### B.2 - Add the target (OpenAI-shape)

| Field | Value |
| --- | --- |
| Name | `aws-bedrock-redteam-demo-rest` |
| Target Type | APPLICATION |
| Connection Method | **REST** |
| Endpoint Type | PUBLIC |
| URL | `http://<EC2-IP>:8080/v1/chat/completions` |
| HTTP Method | POST |
| Request timeout | 110 (default) |
| Auth Type | HEADERS |
| Headers | `Authorization: Bearer <DEMO_API_KEY>` and `Content-Type: application/json` |
| Body template | `{"model":"sb","messages":[{"role":"user","content":"{INPUT}"}]}` |
| Response path | `choices[0].message.content` |

### B.3 - Add the target (flat shape, DVLA fallback)

| Field | Value |
| --- | --- |
| URL | `http://<EC2-IP>:8080/api/chat` |
| Body template | `{"messages":[{"role":"user","content":"{INPUT}"}]}` |
| Response path | `output` |

The `/api/chat` endpoint also accepts `{"input":"{INPUT}"}` as a body template if your AIRS instance uses that pattern. Auth headers are identical.

To copy the DEMO_API_KEY to clipboard:

```bash
grep ^DEMO_API_KEY .env | cut -d= -f2 | pbcopy
```

### B.4 - Multi-turn (REST only)

Enable it. The app is OpenAI-shaped (full `messages[]` history sent on every request, no server-side session IDs), so use **stateless**:

| Field | Value |
| --- | --- |
| Multi-turn | Enabled |
| Mode | `stateless` |
| Assistant role | `assistant` |

Skip multi-turn entirely and you only lose the multi-turn techniques inside the SECURITY attack category.

### B.5 - System prompt and target background

The Flask app already injects the vulnerable system prompt at request time via `vulnerabilities.build_system_prompt()` - you do **not** need to paste it into the AIRS UI for the REST target. Still fill in the Target Background (industry, use case) so AIRS tailors the attack library appropriately. Use the same values as Option A's section A.5.

---

## Phase 1 -> Phase 2 flip (Runtime overlay before/after)

The repo's headline demo is a before/after comparison: scan once with AIRS Runtime OFF, scan again with it ON, show the finding-count delta.

- **Phase 1 (Runtime OFF)**: use Option A (Bedrock native). Cleanest baseline. The system prompt's seeded vulnerabilities surface as a long list of findings.
- **Phase 2 (Runtime ON)**: switch to Option B (REST against the Flask app) and toggle `ENABLE_RUNTIME_SECURITY=true` on the EC2 instance. AIRS Runtime scans pre/post inside the app and blocks unsafe content. Re-run the scan; finding count drops dramatically.

Toggle the env var via SSM:

```bash
aws ssm send-command --instance-ids i-0a19f6d22c501959a \
    --document-name AWS-RunShellScript --region us-east-1 \
    --parameters 'commands=[
        "sudo sed -i \"s/^ENABLE_RUNTIME_SECURITY=.*/ENABLE_RUNTIME_SECURITY=true/\" /opt/airs-demo/.env",
        "cd /opt/airs-demo && sudo docker compose restart"
    ]'
```

Phase 1 and Phase 2 use different target configs in AIRS, but the scan reports are directly comparable - same Attack Library, same model (Claude Sonnet 4.5), same vulnerable system prompt.

---

## Troubleshooting

**Validate fails with "Connection refused" or "Connection timeout" (Option B only)**
The Flask app isn't reachable from AIRS's source IPs. Confirm:
- Security group allows inbound on port 8080 from `0.0.0.0/0` (or AIRS source IPs at minimum)
- Container is up: `./deploy-aws-vm.sh --status`
- `curl http://<EC2-IP>:8080/healthz` returns `status: ok` from outside the box

**Validate passes but probe responses look empty (Option B)**
Most likely the response path is wrong. The AIRS docs are explicit: for OpenAI-compatible APIs the path is `choices[0].message.content`; for the flat `/api/chat` shape it is `output`. Tail logs (`./scripts/tail-ec2-logs.sh`) and watch the request as you click Validate. If the UI shows a `{RESPONSE}` template field rather than a JSONPath, set the template to `{"choices":[{"message":{"content":"{RESPONSE}"}}]}` (OpenAI) or `{"output":"{RESPONSE}"}` (flat).

**"Model use case details have not been submitted" when validating Option A**
The AWS account has not approved sigv4 access for the chosen Anthropic model. Bearer-token approval (which the Flask app uses) is separate. Submit the use-case form via Bedrock console -> Model access, wait 15 minutes, retry. See section A.1.

**Single attack failures during a scan**
AIRS's default request timeout is 110 seconds. Long input prompts (some attacks are 2000+ chars) can exceed that on a single-worker container. AIRS marks the attack failed and moves on; the scan continues. Failure rate >5%? Bump gunicorn worker count via SSM.

**"Target endpoint connection failed" mid-scan**
Same root cause as above. Watch container logs for any `bedrock error` or `5xx` lines; if there are none, the scan is healthy and the UI message refers to a single attack.

**Scan reports lots of "API errors" rather than attack outcomes**
Check that `BLOCK_STATUS_CODE=200`. Non-2xx responses get classified as API errors instead of being scored as attack outcomes. This is intentional and must not be changed.

**Findings count is unexpectedly low**
You may have left `ENABLE_RUNTIME_SECURITY=true` on, in which case AIRS sees a refusal for every attack. Flip it to `false` for the Phase 1 baseline.
