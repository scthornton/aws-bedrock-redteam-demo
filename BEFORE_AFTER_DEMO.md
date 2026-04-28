# Before / After Demo Choreography

This is the script for a 30-minute customer-facing demo using the same
EC2 instance for both phases. The point is to show the same scan, against
the same target, with and without the AIRS Runtime Security overlay, and
let the customer compare the two reports side by side.

## What you need

- One deployed instance of this demo (see [AWS_DEPLOYMENT.md](AWS_DEPLOYMENT.md))
- An AIRS tenant with Red Teaming enabled
- The target already configured in SCM (see [RED_TEAM_SETUP.md](RED_TEAM_SETUP.md))
- About 30 minutes of customer attention

## Phase 1: Runtime OFF (the vulnerable baseline)

Verify the running state from your laptop (no SSH; SSM Run Command over port 443):

```bash
INSTANCE=$(aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=aws-bedrock-redteam-demo" \
              "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" --output text)
aws ssm send-command --instance-ids "$INSTANCE" \
    --document-name AWS-RunShellScript --region us-east-1 \
    --parameters 'commands=[
        "grep ENABLE_RUNTIME_SECURITY /opt/airs-demo/.env",
        "sudo docker compose -f /opt/airs-demo/docker-compose.yml ps"
    ]'
```

Expect `ENABLE_RUNTIME_SECURITY=false` and a healthy container.

In SCM:

1. Go to AI Security > AI Red Teaming > Targets > your target.
2. Click **Run Scan** > Attack Library.
3. Start the scan. While it runs, narrate:
   - "We're not changing the app at all. Same endpoint, same auth."
   - "All we're doing is letting AIRS hit it with our standard attack
     library and watching what comes back."
4. When the scan finishes, open the report.
5. Note the headline numbers (high / medium / low findings, top
   detected categories, leaked data examples). Save the report as PDF.

Expected at end of Phase 1: 50 to 100+ total findings, with a heavy
mix of sensitive data exposure, prompt injection, and insecure output
handling. Specific PII leaks (synthetic SSNs, fake card numbers from
`vulnerabilities.py`) should appear in the response examples.

## Flip the overlay on (60 seconds)

From your laptop, no SSH:

```bash
aws ssm send-command --instance-ids "$INSTANCE" \
    --document-name AWS-RunShellScript --region us-east-1 \
    --parameters 'commands=[
        "sudo sed -i s/ENABLE_RUNTIME_SECURITY=false/ENABLE_RUNTIME_SECURITY=true/ /opt/airs-demo/.env",
        "cd /opt/airs-demo && sudo docker compose down && sudo docker compose up -d",
        "sleep 8",
        "curl -fsS http://127.0.0.1:8080/healthz | head -c 300"
    ]'
```

Expect `runtime_security_enabled: true` in the healthz output. This is the only change between the two phases. The Bedrock model is the same, the system prompt is the same, the vulnerabilities are the same.

## Phase 2: Runtime ON

In SCM:

1. From the same target, click **Run Scan** > Attack Library again.
2. Start the scan. Narrate while it runs:
   - "Same target, same endpoint, same attack set."
   - "AIRS is now wrapping the app with the Runtime Security overlay,
     scanning every prompt before the model sees it and every response
     before the user sees it."
3. When the scan finishes, open the report.

Expected at end of Phase 2: most attacks blocked at the prompt or response
boundary; finding count drops dramatically. The remaining findings tend to
be lower-signal categories the chatbot scan profile doesn't aggressively
filter (e.g. specific business-context disclosures). Save this report
as PDF.

## Side by side

Open both PDFs next to each other. Talk through:

- Total finding counts (typical drop: 50 to 100+ down to single digits)
- Categories that went to zero (the obvious-bad-actor patterns)
- Categories that still have findings (where the customer's real Runtime
  profile would need tuning)
- A couple of specific examples: an attack that leaked PII in Phase 1
  and got blocked in Phase 2

## After the demo

Tear it down so nothing lingers in the customer's account:

```bash
./deploy-aws-vm.sh --destroy
```

Send the customer:

- Both PDFs
- A link to this repo so they can re-run the demo themselves
- The [CUSTOMER_HANDOFF.md](CUSTOMER_HANDOFF.md) one-pager
