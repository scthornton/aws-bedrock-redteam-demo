# Configuring the AIRS Red Teaming Target

Once the demo is reachable on a public URL (locally or on EC2), this is how to wire it up as a Red Teaming target in Strata Cloud Manager.

## Prerequisites

- A Prisma AIRS tenant with Red Teaming enabled
- SCM admin or AI Security admin role
- The demo's public URL (e.g. `http://<EC2-IP>:8080`)
- The `DEMO_API_KEY` from your `.env` (use `Cmd+V` after the helper below)

## Why REST and not OpenAI

The OpenAI connector in AIRS Red Teaming is locked to `api.openai.com` - the custom endpoint field is greyed out. Even though our app speaks the OpenAI wire format, AIRS won't let you point that connector at a different URL.

Use the **REST** connector instead. AIRS substitutes `{INPUT}` for each attack prompt and reads the model's reply from a JSONPath you specify. Multi-turn works too.

## Endpoint choice

The app exposes two endpoints that both call the same Bedrock backend with the same vulnerable system prompt. Pick whichever one matches the response-extraction style your AIRS UI exposes:

- **`/v1/chat/completions`** - canonical OpenAI shape. Configure AIRS with a JSONPath-style `Response path` of `choices[0].message.content`. This is the path the AIRS docs call out by name for OpenAI-compatible APIs ([howto-configure-red-team-target](https://docs.paloaltonetworks.com/), Phase 6 and 7).
- **`/api/chat`** - flat single-key shape `{"output": "<text>"}`. Configure AIRS with a `Response path` of `output` (or, if your UI uses a `{RESPONSE}` template field instead of JSONPath, set the template to `{"output":"{RESPONSE}"}`). This matches the proven DVLA flat-shape pattern that other customers run successfully.

If one fails to grade attacks, switch to the other. They are functionally identical underneath.

## Add the target (Option A: OpenAI-shape - recommended)

In SCM: **AI Security -> AI Red Teaming -> Targets -> Add Target**.

| Field | Value |
| --- | --- |
| Name | `aws-bedrock-redteam-demo` |
| Target Type | APPLICATION |
| Connection Type | **REST** |
| Endpoint Type | PUBLIC |
| URL | `http://<EC2-IP>:8080/v1/chat/completions` |
| HTTP Method | POST |
| Request timeout | 110 (default) |
| Auth Type | HEADERS |
| Headers | `Authorization: Bearer <DEMO_API_KEY>` and `Content-Type: application/json` |
| Body template | `{"model":"sb","messages":[{"role":"user","content":"{INPUT}"}]}` |
| Response path | `choices[0].message.content` |
| Probe message | (default is fine) |

## Add the target (Option B: flat shape - DVLA-style fallback)

Use this if Option A's UI does not expose a JSONPath response field, or if validation passes but the scan still grades 0% with "Empty output" / "Response key not found" errors.

| Field | Value |
| --- | --- |
| Name | `aws-bedrock-redteam-demo-flat` |
| Target Type | APPLICATION |
| Connection Type | **REST** |
| Endpoint Type | PUBLIC |
| URL | `http://<EC2-IP>:8080/api/chat` |
| HTTP Method | POST |
| Request timeout | 110 (default) |
| Auth Type | HEADERS |
| Headers | `Authorization: Bearer <DEMO_API_KEY>` and `Content-Type: application/json` |
| Body template | `{"messages":[{"role":"user","content":"{INPUT}"}]}` |
| Response path | `output` |
| Probe message | (default is fine) |

The `/api/chat` endpoint also accepts `{"input":"{INPUT}"}` as a body template if your AIRS instance uses that pattern.

To copy `DEMO_API_KEY` to your clipboard without echoing it to your terminal:

```bash
grep ^DEMO_API_KEY .env | cut -d= -f2 | pbcopy
```

## Multi-turn configuration

Enable it. The demo is OpenAI-shaped (full `messages[]` history sent on every request, no server-side session IDs), so use **stateless** mode:

| Field | Value |
| --- | --- |
| Multi-turn | Enabled |
| Mode | `stateless` |
| Assistant role | `assistant` |

Skip multi-turn entirely and you only lose the multi-turn techniques inside the SECURITY attack category. Everything else still runs.

Don't pick `stateful` - that's for APIs where the server maintains conversation state by session ID (Bedrock Agents, Copilot Studio). Our app is stateless by design.

## System prompt

Provide it. AIRS uses the system prompt as ground truth to score `system_prompt_extraction` and `prompt_disclosure` findings on a continuum (full leak vs partial vs none) instead of guessing. It also tailors follow-up attacks against the known persona.

Copy the prompt to your clipboard:

```bash
python3 -c "import sys; sys.path.insert(0,'.'); from vulnerabilities import build_system_prompt; print(build_system_prompt())" | pbcopy
```

Paste into the System Prompt field. Length is ~3,500 characters; well under any practical AIRS UI limit.

## Target background info

This populates the target profile that AIRS uses to tailor attacks (industry-specific PII, regulated-content topics, etc.). The closer the values match the system prompt, the more relevant the attack library becomes.

| Field | Value |
| --- | --- |
| Industry | Banking / Financial Services |
| Use case | Internal customer service representative copilot. Authenticated employees query the assistant for caller account information, transaction history, and account-action eligibility during live support calls. |
| Description | SBAssist is the SecureBank internal CSR Console copilot. It is reached only over the corporate VPN, behind employee SSO, after the CSR completes the standard caller identity-verification checklist. The pinned caller record (PII, account, card details) and a small set of internal credentials are loaded into the prompt context for the duration of the session. |
| Competitors | (leave blank, or list 1-2 banks if the field is required) |

## Validate, then scan

1. Click **Test Connection** / **Validate**. Should be green.
2. Save the target.
3. From the target detail page, click **Run Scan** -> **Attack Library**.
4. For the first run, pick a single category (Sensitive Data Exposure or Prompt Injection) and 10-20 attacks. This verifies the response parsing and the quota model before committing scan time to the full library.
5. Once that completes cleanly, run the full Attack Library for the headline numbers.

A full Attack Library run against this target with `ENABLE_RUNTIME_SECURITY=false` typically produces 50 to 100+ findings depending on which Claude model you pointed at.

## Custom prompts (optional)

Import [`examples/attack-prompts.csv`](examples/attack-prompts.csv) as a custom prompt set if you want a smaller, more targeted scan that always hits the seeded vulnerabilities. Each row has category, prompt, expected outcome, and a sentinel string.

## Troubleshooting

**Validate fails with "Connection refused" or "Connection timeout"**
The app isn't reachable from AIRS's source IPs. Confirm:
- Security group allows inbound on port 8080 from `0.0.0.0/0` (or AIRS source IPs at minimum)
- Container is up: `./deploy-aws-vm.sh --status`
- `curl http://<EC2-IP>:8080/healthz` returns `status: ok` from outside the box

**Validate passes but probe responses look empty**
Most likely the response path is wrong. The default for our app is `choices[0].message.content`. Tail the app logs (`./scripts/tail-ec2-logs.sh`) and watch the request as you click Validate.

**Single attack failures during a scan**
AIRS's default request timeout is 110 seconds. Long input prompts (some attacks are 2,000+ chars) can occasionally exceed that on a single-worker container. AIRS marks that one attack as failed and moves on; the scan continues. See an elevated failure rate (>5% of attacks)? Bump the gunicorn worker count via SSM.

**"Target endpoint connection failed" in the AIRS UI mid-scan**
Same root cause as above. Watch your container logs for any `bedrock error` or `5xx` lines; if there are none, the scan is healthy and the UI message refers to a single attack.

**Findings count is unexpectedly low**
You may have left `ENABLE_RUNTIME_SECURITY=true` on, in which case AIRS sees a refusal for every attack. Flip it to `false` for the Phase 1 baseline.

**Scan reports lots of "API errors" rather than attack outcomes**
Check that `BLOCK_STATUS_CODE=200`. Non-2xx responses get classified as API errors instead of being scored as attack outcomes.
