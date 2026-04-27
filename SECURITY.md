# Security Notes

## This app is intentionally vulnerable

This repo seeds synthetic PII, fake credit card numbers, and fake admin
credentials directly into a Bedrock-backed chatbot's system prompt so red-team
scans produce dramatic, plentiful findings. That is the point.

Do not deploy this outside an isolated POV environment. Specifically:

- Do not put it behind a public DNS record without IP-based access controls.
- Do not connect it to a real customer database or any real PII source.
- Do not run it on shared infrastructure with production workloads.
- Do not let it accept real customer traffic, ever.

The deploy script (`deploy-aws-vm.sh`) defaults to opening the app port to
`0.0.0.0/0` to make the AIRS connection setup frictionless. That default is
fine for a short-lived POV. For anything longer-lived, narrow `RED_TEAM_CIDR`
to the AIRS Red Teaming source IPs documented in your SCM tenant.

## Synthetic data only

Every value in `vulnerabilities.py` is fake:

- SSNs follow the format but are not assigned to real individuals.
- Card numbers come from public test ranges (4111-1111-1111-1111,
  5555-5555-5555-4444, 3782-822463-10005, etc.).
- Admin credentials, API tokens, SSH fingerprints, Stripe keys, Datadog
  keys are all literal strings like `fake-jwt-do-not-use` and
  `sk_live_fakefakefakefake...`.

If you fork this repo and add real values to `vulnerabilities.py`, you've
defeated the point and you've created a real exposure. Don't.

## Secrets handling

- `.env` is gitignored. The `.env.example` template is the only env
  reference checked in.
- The `deploy-aws-vm.sh` script generates a keypair locally
  (`./aws-bedrock-redteam-demo.pem`) and never echoes the key material to
  stdout. The `.pem` is gitignored via `*.pem` in `.gitignore`.
- The AWS Bedrock API key, the AIRS scan API key, and the demo's own
  bearer key all live in `.env` and are never logged.
- The deploy script `scp`s `.env` to the EC2 instance over the keypair
  it just created. There is no transit over the public internet
  un-encrypted.

If you accidentally commit a secret, rotate immediately:

- Bedrock API key: console > Bedrock > API keys > delete + regenerate
- AIRS scan API key: SCM tenant settings > rotate
- `DEMO_API_KEY`: pick a new random string, update `.env`, restart container

## What this project does not protect against

- Compromise of the EC2 instance hosting the demo. If the AWS account is
  compromised, attacker has the keypair, the env file, and access to
  Bedrock via the bearer token.
- Persistent compromise via prompt injection. The app is stateless and
  in-memory; restarting the container resets everything. There is no
  persistence layer to corrupt.
- Bill shock from an attacker hammering the Bedrock backend through the
  public app port. Bedrock charges per token, and the demo has no rate
  limiting. For real customer-shape deployments, add a rate limit or
  put the app behind a WAF / API Gateway.

## License

MIT. See [LICENSE](LICENSE). The "as is" and "no warranty" clauses
apply, and they apply hardest to a project that is intentionally
vulnerable by design.
