# aws-bedrock-redteam-demo

An intentionally-vulnerable AWS Bedrock-backed chat app for Prisma AIRS Red
Teaming demos. Speaks the OpenAI `/v1/chat/completions` wire format so it
plugs into AIRS's native OpenAI connector with no custom REST configuration.
Optionally fronts itself with the Prisma AIRS Runtime Security overlay so a
single binary can serve both phases of the before / after demo.

> WARNING: This app is intentionally vulnerable. It seeds synthetic PII, fake
> credit card numbers, and fake admin credentials directly into its system
> prompt so red-team scans produce dramatic findings. Do not deploy outside
> an isolated POV environment. See [SECURITY.md](SECURITY.md).

## Why this exists

Most AIRS Red Teaming demos require pointing a scanner at a customer's real
production app, which often takes weeks of OTI / IT / security review (IAM
service accounts, network access, SSO mappings). This repo is the parallel
track: a customer clones it, deploys it to their own AWS account, points
AIRS at it, and gets a real before / after report in under an hour. No IAM
service account needed, no production traffic involved.

## Architecture

```
+----------------------+
|  AIRS Red Teaming    |  attacks via OpenAI connector
|  (SCM cloud)         |
+----------+-----------+
           |  HTTPS POST /v1/chat/completions
           |  Authorization: Bearer <DEMO_API_KEY>
           v
+----------------------------------------------------------+
|  Demo App (Flask, port 8080)                             |
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
|  |  Build vulnerable system prompt (embeds fake PII)  |  |
|  |  Call Bedrock Converse API                         |  |
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

## What's in the box

| File | Purpose |
| --- | --- |
| `app.py` | Flask routes; OpenAI <-> Bedrock translation; AIRS overlay wiring |
| `bedrock_client.py` | Plain-HTTP Converse API client using `AWS_BEARER_TOKEN_BEDROCK` (no boto3) |
| `vulnerabilities.py` | `FAKE_DATABASE` and the CSR-tool system prompt |
| `airs_runtime.py` | `scan()` helper for the optional Runtime overlay |
| `Dockerfile`, `docker-compose.yml` | Local + EC2 runtime |
| `deploy-aws-vm.sh` | One-shot EC2 deploy / destroy / status |
| `scripts/` | Pre-flight credential test, smoke test, attack test |
| `examples/` | AIRS target config, attack-prompt CSV |

## Quickstart

See [QUICKSTART.md](QUICKSTART.md) for the 5-minute local path. For AWS EC2
deployment, see [AWS_DEPLOYMENT.md](AWS_DEPLOYMENT.md). For the AIRS-side
target setup, see [RED_TEAM_SETUP.md](RED_TEAM_SETUP.md). For the
choreographed customer-facing flow, see [BEFORE_AFTER_DEMO.md](BEFORE_AFTER_DEMO.md).

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

The `BLOCK_STATUS_CODE=200` invariant matters: AIRS Red Teaming's response
parser scores by body content, so returning 4xx classifies a block as an
API error rather than an attack outcome. Block responses are intentionally
HTTP 200 with a refusal message in the body and `finish_reason=content_filter`.

## Choosing a Bedrock model

Sonnet / Opus 4.x models on Bedrock require a US or global *inference profile*
prefix (e.g. `us.anthropic.claude-sonnet-4-5-20250929-v1:0`), not the bare model
ID. Older `anthropic.claude-3-*` models support direct ON_DEMAND throughput.

Run `./scripts/list-bedrock-models.sh` to see what's available on your AWS
account, or open the Bedrock console and request access to whichever Claude
models you want to demo against.

## Status of v1

- [x] OpenAI-shaped `/v1/chat/completions` backed by Bedrock bearer-token auth
- [x] Optional Prisma AIRS Runtime overlay (pre and post scan)
- [x] AWS EC2 deploy / destroy script
- [x] Synthetic FAKE_DATABASE with PII / PCI / secrets
- [x] CSR-tool system prompt (produces real leaks against current Sonnet 4.5)
- [x] AIRS Red Teaming target import config
- [ ] Streaming responses (out of scope for v1; non-streaming only)
- [ ] Multi-turn over a long session (basic history pass-through is in; not heavily tested)
- [ ] TLS termination (out of scope for v1; put an ALB or Caddy in front if you need it)

## License

MIT. See [LICENSE](LICENSE).
