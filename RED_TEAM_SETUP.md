# AIRS Red Teaming Target Setup

This is the 5-minute customer path. It assumes you already deployed the demo to EC2 (`./deploy-aws-vm.sh` from the [README](README.md)) and have a Prisma AIRS tenant with Red Teaming enabled.

## Before you start

You need:

- Demo URL with public IP (e.g. `http://<EC2-IP>:8080`) - from `./deploy-aws-vm.sh`
- `DEMO_API_KEY` from `.env` - the bearer token AIRS will use to auth to the demo
- SCM admin or AI Security admin role on a Prisma AIRS tenant with Red Teaming enabled

Copy the API key to your clipboard now:

```bash
grep ^DEMO_API_KEY .env | cut -d= -f2 | tr -d '\n' | pbcopy   # macOS
# grep ^DEMO_API_KEY .env | cut -d= -f2                        # any OS - prints to terminal
```

## Step 1 - verify the endpoint is live

Run this from your laptop. Substitute your EC2 IP and paste the API key inline (do **not** use `${DEMO_API_KEY}` shell expansion - that has a known gotcha that fails silently with empty token):

```bash
curl -X POST 'http://<EC2-IP>:8080/api/chat' \
  -H 'Authorization: Bearer <PASTE-DEMO-API-KEY-HERE>' \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"reply with one word: pong"}]}'
```

Expected: `{"output": "pong"}` in 2-5 seconds. If you get a timeout or 401, fix that before touching AIRS - see Troubleshooting below.

## Step 2 - import target into AIRS

In SCM: **AI Security → AI Red Teaming → Targets → Add Target**

| Field | Value |
| --- | --- |
| Target Name | `bedrock-demo` (anything) |
| Target Type | **Application** |
| Connection Method | **REST API** |
| Endpoint Accessibility | **Public** |
| Choose Method | **cURL Import** |

In the **cURL String** box, paste this (substitute your EC2 IP and the actual API key):

```bash
curl 'http://<EC2-IP>:8080/api/chat' \
  -H 'Authorization: Bearer <PASTE-DEMO-API-KEY-HERE>' \
  -H 'Content-Type: application/json' \
  --data '{"messages":[{"role":"user","content":"{INPUT}"}]}'
```

Click **Import**. AIRS auto-fills the API endpoint, headers, and Request JSON.

## Step 3 - set the Response JSON template (the one field that matters)

After import, scroll to the **Response JSON** section. AIRS may have auto-filled this with a guess. **Replace whatever is there with exactly:**

```json
{"output":"{RESPONSE}"}
```

This is the most important single field in the whole target config. AIRS uses this template to extract the AI text from the response. Our `/api/chat` endpoint returns `{"output":"<text>"}`, so this template tells AIRS the model's reply lives at the `output` key.

## Step 4 - target background

Fill in (or paste from the helper):

| Field | Value |
| --- | --- |
| Industry | Banking / Financial Services |
| Use Case | Internal CSR copilot. Authenticated employees query the assistant for caller account information, transaction history, and account-action eligibility during live support calls. |
| System Prompt | output of `./scripts/print-system-prompt.sh` (copy to clipboard, see below) |

```bash
./scripts/print-system-prompt.sh | pbcopy          # macOS - copies to clipboard
# ./scripts/print-system-prompt.sh                  # any OS - prints to terminal, copy manually
```

Paste the copied system prompt into the System Prompt field.

The system prompt is what makes this demo a vulnerable target. It contains the synthetic FAKE_DATABASE, weak role boundaries, and the pre-seeded "verified user" loophole the AIRS Attack Library exploits. Without it, AIRS hits raw Claude and the scan grades as "model alignment is decent" - a much weaker demo. With it, expect 50-100+ findings on the Attack Library.

## Step 5 - multi-turn

| Field | Value |
| --- | --- |
| Multi-Turn / Supports Sessions | **No** (stateless mode) |
| Assistant role (if asked) | `assistant` |

Skip multi-turn entirely if your UI doesn't expose it. The only attacks you lose are the multi-turn rules in the SECURITY category - everything else runs.

## Step 6 - validate

Click **Test Connection** / **Validate**. Expected: green within ~3 seconds.

If validation **ReadTimeouts**, you have a previous scan still running and saturating the target's worker pool. Cancel any in-progress scans first, then validate again. The container handles 16 concurrent requests; once nothing is hammering it, validation completes instantly.

## Step 7 - small test scan first

**Don't** kick off the full Attack Library on the first run. Do this instead:

1. **Run Scan → Attack Library**
2. Select **PROMPT_INJECTION** category only
3. Limit to **10-20 attacks**
4. **Start**

Expected: progress advances past 0% within 30 seconds; per-attack rows show non-empty Response captures with real Claude text. ASR will be high - that's the point of this demo.

## Step 8 - full library

If the small scan grades cleanly, run the full Attack Library against the same target. 30 minutes to a few hours. Treat as a background job.

## Step 9 - Phase 2 (Runtime ON / Before-After)

Flip the AIRS Runtime overlay on the EC2 instance. First, find your instance ID (or copy it from `./deploy-aws-vm.sh --status`):

```bash
# Get the instance ID
INSTANCE=$(aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=aws-bedrock-redteam-demo" \
              "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" --output text)
echo "Instance: $INSTANCE"

# Flip the overlay on and restart the container
aws ssm send-command --instance-ids "$INSTANCE" \
    --document-name AWS-RunShellScript --region us-east-1 \
    --parameters 'commands=[
        "sudo sed -i \"s/^ENABLE_RUNTIME_SECURITY=.*/ENABLE_RUNTIME_SECURITY=true/\" /opt/airs-demo/.env",
        "cd /opt/airs-demo && sudo docker compose restart"
    ]'
```

Re-scan against the **same target** with the **same scan config**. Finding count drops dramatically. That delta is the customer demo.

---

## Troubleshooting

The failure modes below were all hit during initial deployment and are now closed at the app layer. They should not recur, but if they do:

| Symptom in AIRS UI | Real cause | Fix |
| --- | --- | --- |
| `Response key 'content' not found in response` | Response JSON template field is `{"content":"{RESPONSE}"}` (default cURL-import auto-fill) and the `/api/chat` endpoint returns `output`, not `content` | Set Response JSON to `{"output":"{RESPONSE}"}` exactly |
| `Empty output received from target` | Bedrock returned empty text for a guardrail-filtered prompt | Already fixed in app.py - empty model output now returns `[empty model response]` sentinel string. If you see this on a fresh deploy, your container is older than commit `ceb512e` |
| `Target endpoint connection failed or returned an unknown error while generating output` | App returned non-2xx (e.g. 502 on BedrockError) | Already fixed in app.py - all errors return HTTP 200 with sentinel output. If you see this, your container is older than commit `ceb512e` |
| `Target functionality test failed: ReadTimeout` during Validate | gunicorn workers all busy with an in-progress scan; validation queues and times out | Cancel running scans, retry validation. Container ships with 4 workers × 4 threads = 16 concurrent slots, which is sized for AIRS scan rate |
| `Invalid API key` (401) on test cURL from your laptop | Shell expanded `${DEMO_API_KEY}` from the parent shell (empty) before the inline `DEMO_API_KEY=...` assignment took effect | Either `export DEMO_API_KEY=...` first, or paste the literal key into the curl command |
| `Connection refused` / `Connection timeout` | EC2 not reachable from AIRS source IPs | Confirm SG allows inbound 8080 from `0.0.0.0/0` (or AIRS source IP `104.198.97.107`); confirm container is up via `./deploy-aws-vm.sh --status` |
| Findings count unexpectedly low | Runtime overlay accidentally left ON during Phase 1 | Set `ENABLE_RUNTIME_SECURITY=false`, restart container |
| Scan reports lots of "API errors" rather than attack outcomes | Some path in app.py returns non-2xx | Should not happen on current code; if it does, tail container logs and look for the offending request |

### How to read the logs while a scan is running

```bash
./scripts/tail-ec2-logs.sh
```

Healthy scan looks like:

```
104.198.97.107 - - [DATE] "POST /api/chat HTTP/1.1" 200 1234 ...
2026-04-28 13:00:09,478 INFO app | api/chat req tr=... user_chars=112 ...
```

Source IP `104.198.97.107` confirms AIRS is the caller. Status `200` and 4-digit-byte response body confirms real model content. If you see body sizes consistently below ~50 bytes or 4xx/5xx codes, drop into the troubleshooting matrix above.

---

## Appendix: AWS Bedrock native connector (alternative path)

The flat-shape REST path above is the primary recommendation. If you want AIRS to call Bedrock directly (no Flask app in the loop), see the AWS Bedrock connector setup in [docs.paloaltonetworks.com](https://docs.paloaltonetworks.com/ai-runtime-security/ai-red-teaming/identify-ai-system-risks-with-ai-red-teaming/get-started-with-prisma-airs-ai-red-teaming/targets/add-a-target-aws-bedrock-cm). Trade-offs:

- **Pros:** No Flask app, no REST parser surface area; AIRS does sigv4 directly.
- **Cons:** Requires the Anthropic use-case form approval **for sigv4 access**, which is gated separately from bearer-token approval. Bearer-token approval (which the Flask app uses) is not enough. Form takes ~15 minutes to clear.
- **System prompt:** Goes into the AIRS target's "Additional Context > System Prompt" field. Get it via `./scripts/print-system-prompt.sh | pbcopy`.
- **IAM credentials:** Run `./scripts/provision-airs-bedrock-iam.sh` to create a scoped IAM user. It prints the access key, secret, and model ID for direct paste into the AIRS UI.

For the Phase 2 (Runtime ON) demo, you must use the REST connector path above - the Runtime overlay lives in the Flask app. AWS Bedrock native bypasses the app entirely.

## Appendix: OpenAI-shape `/v1/chat/completions` (legacy)

The app also exposes `/v1/chat/completions` returning canonical OpenAI shape. Some AIRS UI variants accept JSONPath-style response paths (`choices[0].message.content`); some expect a structural template (`{"choices":[{"message":{"content":"{RESPONSE}"}}]}`). The flat `/api/chat` is simpler and proven, so prefer it. This route stays for legacy clients and OpenAI-compatible tooling.
