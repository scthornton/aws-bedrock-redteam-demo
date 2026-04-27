# Quickstart - 5 minutes to a working local demo

This walks you through running the demo on your laptop with Docker. For
AWS EC2 deployment, see [AWS_DEPLOYMENT.md](AWS_DEPLOYMENT.md).

## Prerequisites

- AWS account with Bedrock access enabled (you have requested model access
  in the Bedrock console for at least one Claude model)
- An AWS Bedrock API key (long-lived bearer token, starts with `ABSK`)
- Docker Desktop or Docker Engine + Compose v2
- `curl` and `jq` for the smoke tests
- (Optional) A Prisma AIRS tenant + scan API key, if you want to test the
  Runtime overlay locally

## 1. Get a Bedrock API key

In the AWS console, open Amazon Bedrock > **API keys** > Create API key.
Pick **Long-term** for non-expiring tokens. Save the value; you can never
see it again after creation. The token starts with `ABSK` and is around
132 characters.

If you haven't requested Claude model access yet, do that first under
Bedrock > Model access > Manage model access. Sonnet 4.5 (or whichever
Claude you want to demo against) needs to be in the "Access granted"
column for your region.

## 2. Clone and configure

```bash
git clone <your-fork-url> aws-bedrock-redteam-demo
cd aws-bedrock-redteam-demo
cp .env.example .env
$EDITOR .env
```

Fill in at least:

```bash
AWS_BEARER_TOKEN_BEDROCK=ABSK...your-actual-key-here...
BEDROCK_MODEL_ID=us.anthropic.claude-sonnet-4-5-20250929-v1:0
DEMO_API_KEY=<pick-any-long-random-string>
```

## 3. Verify Bedrock works

```bash
source .env && ./scripts/test-bedrock-creds.sh
```

Expect to see HTTP 200 and a real Claude reply ending with
`OK: Bedrock bearer-token auth is working.` If not, see the Troubleshooting
section at the bottom of this file.

## 4. Run the app

```bash
docker compose up -d
docker compose ps    # 'app' should be 'Up' and 'healthy'
```

## 5. Hit the endpoints

```bash
# health (no auth)
curl -s http://localhost:8080/healthz | jq .

# list models (auth required)
curl -s -H "Authorization: Bearer $DEMO_API_KEY" \
    http://localhost:8080/v1/models | jq .

# benign chat
curl -s -X POST http://localhost:8080/v1/chat/completions \
    -H "Authorization: Bearer $DEMO_API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"model":"any","messages":[{"role":"user","content":"What is your purpose?"}]}' \
    | jq -r '.choices[0].message.content'

# attack (with Runtime OFF, the default - expect a leak on at least some)
./scripts/test-attack.sh
```

## 6. Toggle the Runtime overlay (optional)

If you have an AIRS scan API key and want to see the before / after delta:

```bash
# In .env, set:
ENABLE_RUNTIME_SECURITY=true
AIRS_API_KEY=<your-x-pan-token>

# Restart
docker compose down && docker compose up -d

# Re-run the same attack set
./scripts/test-attack.sh
```

You should see most attacks now classified as `BLOCK` instead of `LEAK`.
That delta is the full content of the before / after demo.

## Troubleshooting

**`HTTP 400 ... inference profile`**
Bedrock 4.x models (Sonnet 4.5, Opus 4.5/4.7, etc.) require an inference
profile prefix. Set `BEDROCK_MODEL_ID` to a value like
`us.anthropic.claude-sonnet-4-5-20250929-v1:0` instead of the bare
`anthropic.claude-sonnet-4-5-...`. Run `./scripts/list-bedrock-models.sh`
to see what's available on your account.

**`HTTP 404 ... use case details have not been submitted`**
Anthropic models on Bedrock require a one-time use-case form per AWS
account. Open Bedrock > Model access > the Anthropic row > Submit use
case details. Wait 15 minutes after submitting.

**`HTTP 401` from `/v1/chat/completions`**
Either the `Authorization: Bearer` header is missing, or the value
doesn't match `DEMO_API_KEY` in the running container. If you changed
`.env`, you need to `docker compose down && docker compose up -d` for
the container to pick up the new value.

**Healthz says `bedrock_reachable: false`**
The bearer token is wrong or expired, or the model ID is rejected by
the region. Run `./scripts/test-bedrock-creds.sh` to isolate which.

**Container won't start**
`docker compose logs app` will usually tell you. Most commonly: a missing
required env var (`DEMO_API_KEY`) or a malformed `.env` line.
