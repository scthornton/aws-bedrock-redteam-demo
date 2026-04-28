# Customer Handoff

A one-pager for sending this repo to a customer so they can run the AIRS Red Teaming before / after demo on their own AWS account.

## What this gives the customer

A real Prisma AIRS Red Teaming scan and report against a Bedrock-backed LLM target running in their own AWS account, in **under an hour**, with no IT or OTI involvement beyond standard AWS console access.

## What the customer needs

- An AWS account with permissions to launch EC2 and access Bedrock
- Bedrock model access granted for at least one Claude model (Bedrock console → Model access → Anthropic use-case form, ~15 min)
- A Bedrock API key (long-term bearer token, generated from the Bedrock console)
- A Prisma AIRS tenant with Red Teaming enabled

## What the customer does

| # | Step | Time | Doc |
| --- | --- | --- | --- |
| 1 | Clone the repo, set `AWS_BEARER_TOKEN_BEDROCK` in `.env` | 2 min | [QUICKSTART.md](QUICKSTART.md) |
| 2 | `./deploy-aws-vm.sh` deploys to EC2 | 5 min | [AWS_DEPLOYMENT.md](AWS_DEPLOYMENT.md) |
| 3 | Add the deployed URL as an AIRS target via cURL import | 5 min | [RED_TEAM_SETUP.md](RED_TEAM_SETUP.md) |
| 4 | Run a 10-attack PROMPT_INJECTION scan to verify wiring | 5 min | RED_TEAM_SETUP.md Step 7 |
| 5 | Run the full Attack Library | 30-90 min | RED_TEAM_SETUP.md Step 8 |
| 6 | Flip Runtime overlay ON via SSM and re-scan for the before/after delta | 30-90 min | [BEFORE_AFTER_DEMO.md](BEFORE_AFTER_DEMO.md) |
| 7 | `./deploy-aws-vm.sh --destroy` | 1 min | AWS_DEPLOYMENT.md |

Total active hands-on time: ~20 minutes. Most of the wall-clock is the Attack Library scan running in the background.

## What the customer gets

- A real AIRS scan report against a Bedrock-backed LLM target
- Concrete examples of PII / PCI / credential leakage from a vulnerable system prompt under attack
- A direct comparison of the same scan with and without AIRS Runtime Security in front
- A working reference implementation for plumbing AIRS Runtime into their own LLM apps

## What this is NOT

- A production-ready chatbot. The vulnerabilities are intentional and the data is synthetic. See [SECURITY.md](SECURITY.md).
- A replacement for scanning the customer's actual production app. The real value of AIRS Red Teaming is on real targets; this is the parallel-track demo when that's blocked.
- A multi-cloud deployment template. AWS EC2 only for v1.

## The single most important AIRS UI field

When importing the cURL into AIRS, the **Response JSON** field controls how AIRS extracts the model's text from the response. AIRS auto-guesses this from the cURL import and **the guess is usually wrong** (it picks `content` because it sees `content` in the request body). It must be set to:

```json
{"output":"{RESPONSE}"}
```

That single field was the root cause of every "Response key 'content' not found" / "Empty output" / "endpoint connection failed" error during initial development. The repo is now hardened against the surrounding failure modes (4 gunicorn workers, sentinel strings on empty/error responses, always HTTP 200) - but Response JSON is configured in the AIRS UI, not in the repo, so it's the customer's one job.

[RED_TEAM_SETUP.md](RED_TEAM_SETUP.md) has the full walkthrough plus a troubleshooting matrix covering every failure mode that came up during initial deployment.

## Things to point out during the call

- The AWS deploy script tags everything `Project=aws-bedrock-redteam-demo` so cleanup doesn't leave anything billable behind.
- The `BLOCK_STATUS_CODE=200` invariant matters: AIRS Red Teaming scores by response body, not HTTP status. Don't change this knob. The app also returns 200 on Bedrock errors with a sentinel string, for the same reason.
- Bedrock 4.x models require an inference profile prefix (`us.anthropic.claude-...`). Older `claude-3-*` models support direct on-demand throughput. `./scripts/list-bedrock-models.sh` shows what's available on the customer's account.
- Time-to-first-result on a fresh AWS account: about 45 minutes if they haven't requested Bedrock model access yet (the Anthropic use-case form is the longest single step).
- AIRS Red Teaming has two separate Bedrock approval gates: bearer-token (what the Flask app uses) and sigv4 (what the AIRS native BEDROCK connector uses). They're approved independently. Bearer-token is enough for this demo.

## Time-to-first-result table

| Customer state | Approx time |
| --- | --- |
| Already has Bedrock + AIRS, just running the demo | 15-20 min |
| Has AIRS, needs Bedrock model access | 45 min (mostly waiting on the Anthropic form) |
| Needs both AIRS and AWS access | 1 to 2 days (license + Bedrock approval) |
