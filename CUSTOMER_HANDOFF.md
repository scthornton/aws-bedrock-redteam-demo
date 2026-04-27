# Customer Handoff

A one-pager for sending this repo to a customer so they can run the
before / after demo on their own AWS account.

## What this gives the customer

A real AIRS Red Teaming scan and report against an LLM target they
deployed in their own AWS account, in under an hour, with no IT or OTI
involvement beyond standard AWS console access.

## What the customer needs

- An AWS account with permissions to launch EC2 and access Bedrock
- Bedrock model access granted for at least one Claude model in their
  chosen region (request via Bedrock console > Model access)
- A Bedrock API key (long-term bearer token, generated from the Bedrock
  console)
- A Prisma AIRS tenant with Red Teaming enabled
- An AIRS scan API key (only if they want to run the Runtime overlay
  for the before / after comparison)

## What the customer does

1. Fork or clone this repo.
2. Follow [QUICKSTART.md](QUICKSTART.md) for the local check (5 min).
3. Follow [AWS_DEPLOYMENT.md](AWS_DEPLOYMENT.md) to deploy to EC2 (5 min).
4. Follow [RED_TEAM_SETUP.md](RED_TEAM_SETUP.md) to add the deployed
   URL as an AIRS target (2 min).
5. Run an Attack Library scan and review findings (10 to 30 min,
   depending on scan scope).
6. Optionally toggle the Runtime overlay and re-run for the before /
   after comparison ([BEFORE_AFTER_DEMO.md](BEFORE_AFTER_DEMO.md)).
7. Run `./deploy-aws-vm.sh --destroy` to clean up.

## What the customer gets

- A real AIRS scan report against an LLM target
- Concrete examples of PII / PCI / credential leakage from a Bedrock-backed
  model under attack
- A direct comparison of the same scan with and without AIRS Runtime
  Security in front
- A working reference implementation for plumbing AIRS Runtime into
  their own LLM apps

## What this is NOT

- A production-ready chatbot. The vulnerabilities are intentional and
  the data is synthetic. See [SECURITY.md](SECURITY.md).
- A replacement for scanning the customer's actual production app. The
  real value of AIRS Red Teaming is on real targets; this is the
  parallel-track demo when that's blocked.
- A multi-cloud deployment template. AWS EC2 only for v1.

## Things to point out during the call

- The AWS deploy script tags everything `Project=aws-bedrock-redteam-demo`
  so cleanup doesn't leave anything billable behind.
- The `BLOCK_STATUS_CODE=200` invariant matters: AIRS Red Teaming scores
  by response body, not HTTP status. Don't change this knob.
- Bedrock 4.x models require an inference profile prefix
  (`us.anthropic.claude-...`). Older `claude-3-*` models support direct
  on-demand throughput. The script `./scripts/list-bedrock-models.sh`
  shows what's available on the customer's account.
- Time-to-first-result on a fresh AWS account: about 45 minutes if they
  haven't requested Bedrock model access yet (the Anthropic use-case
  form is the longest single step).

## Time-to-first-result table

| Customer state | Approx time |
| --- | --- |
| Already has Bedrock + AIRS, just running the demo | 15 min |
| Has AIRS, needs Bedrock model access | 45 min (mostly waiting on the Anthropic form) |
| Needs both AIRS and AWS access | 1 to 2 days (license + Bedrock approval) |
