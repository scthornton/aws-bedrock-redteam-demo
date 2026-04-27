# Configuring the AIRS Red Teaming target

Once the demo is reachable on a public URL (locally or on EC2), this is
how you wire it up as a Red Teaming target in Strata Cloud Manager.

## Prerequisites

- A Prisma AIRS tenant with Red Teaming enabled
- SCM admin or AI Security admin role
- The demo's public URL (e.g. `http://<EC2-IP>:8080` or
  `http://localhost:8080` if you tunnelled it)
- The `DEMO_API_KEY` from your `.env`

## Add the target

1. In SCM, go to **AI Security > AI Red Teaming > Targets**.
2. Click **Add Target**.
3. Choose connector type **OpenAI**. (This is the key step. The demo
   speaks the OpenAI wire format precisely so this connector works
   without a custom REST configuration.)
4. Fill in:
   - **Name:** `aws-bedrock-redteam-demo` (or anything)
   - **Endpoint:** `http://<host>:8080/v1/chat/completions`
   - **API key:** value of `DEMO_API_KEY`
   - **Model:** anything. The demo accepts whatever the client sends and
     routes to the configured Bedrock model. `sbassist` or
     `claude-bedrock-demo` both work.
5. Click **Test Connection**. You should get a green check. If not, see
   Troubleshooting below.
6. Save.

A reference JSON shape for this configuration is in
[`examples/airs-target-config.json`](examples/airs-target-config.json).

## Run a scan

1. From the target detail page, click **Run Scan**.
2. Pick **Attack Library** (the default broad scan).
3. Optionally narrow to a single category for faster turnaround during
   first-time setup. The demo's vulnerability surface is most active for:
   - Sensitive Data Exposure
   - Prompt Injection
   - Insecure Output Handling
   - System Prompt Extraction
4. Start the scan.

A full Attack Library run against this target with `ENABLE_RUNTIME_SECURITY=false`
typically produces 50 to 100+ findings. Numbers vary by which Claude model
you pointed at; better-aligned models refuse more attacks but the scan still
records the attempts as detection signal.

## Custom prompts (optional)

The repo ships a starter set in
[`examples/attack-prompts.csv`](examples/attack-prompts.csv) with category
labels and sentinel strings. Import these into AIRS as a custom prompt set
if you want a smaller, more targeted scan that always hits the seeded
vulnerabilities.

## Run the scan a second time with the overlay on

This is where the demo earns its keep. See
[BEFORE_AFTER_DEMO.md](BEFORE_AFTER_DEMO.md) for the full choreography.

## Troubleshooting

**Test Connection fails with "Connection refused"**
The app isn't reachable from AIRS's source IPs. Confirm:
- Security group allows inbound on the app port from AIRS source IPs (or
  `0.0.0.0/0` while you're getting things working)
- The container is up: `docker compose ps` shows `healthy`
- `curl http://<host>:8080/healthz` returns `status: ok` from outside the box

**Test Connection fails with "Invalid response shape"**
Usually means the connector got a 4xx or non-JSON body. Tail the app
logs (`docker compose logs app -f`) and watch the request as you click
Test Connection. The endpoint must be the full
`/v1/chat/completions` path, not just the base URL.

**Test Connection passes but scans return zero findings**
You may have left `ENABLE_RUNTIME_SECURITY=true` on, in which case AIRS
sees a refusal for every attack and scores accordingly. Flip it to
`false` for Phase 1.

**Scan reports lots of "API errors" rather than attack outcomes**
This is the `BLOCK_STATUS_CODE` pitfall. If anything has overridden the
default of `200`, restore it. Non-2xx responses are classified as API
errors by the parser instead of being scored as attack outcomes.
