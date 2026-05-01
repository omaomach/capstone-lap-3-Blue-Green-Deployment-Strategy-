# Deployment Guide

This document describes the procedure for deploying a new version of the application to Green and validating it before any traffic switch.

The procedure assumes Blue is currently serving production. The goal of this phase is to bring Green up with the new version, attach it to the ALB without routing traffic to it, and validate it through automated and manual checks. The actual traffic switch is documented separately in `TRAFFIC_SWITCH.md`.

## Step 1 — Launch Green instances

Launch two EC2 instances using the same configuration as Blue:

- AMI: Amazon Linux 2023
- Instance type: t2.micro
- Key pair: `bluegreen-lab-key`
- Security group: `bluegreen-ec2-sg` (same SG as Blue — parity requirement)
- AZ distribution: green-1 in eu-west-1a, green-2 in eu-west-1b (matches Blue's AZ pattern)
- User data: `scripts/user-data-green.sh`

The user-data script installs nginx, writes the v2 page identifying as Green, and creates the `/health` endpoint that the ALB will use for health checks.

Wait until both instances show **Running** with **2/2 status checks passed** before continuing.

## Step 2 — Create tg-green target group

Settings must match `tg-blue` exactly except for the name:

- Target type: Instances
- Protocol/port: HTTP/80
- VPC: same default VPC as Blue
- Health check path: `/health`
- Health check interval: 15 seconds
- Healthy threshold: 2 / Unhealthy threshold: 2
- Success codes: 200

Register both Green instances and wait for both to show **healthy** in the Targets tab. (The status will show "Unused" until the target group is attached to a load balancer in step 3.)

## Step 3 — Attach tg-green to the ALB via a path-based test rule

We do not switch the default rule yet. Instead, add a priority-10 listener rule that routes `/green-test*` to tg-green. Production traffic continues to flow through the default rule to tg-blue, while the test rule lets us validate Green via the same public DNS.

In the ALB listener (HTTP:80):

- Add rule, priority 10
- Condition: path is `/green-test*`
- Action: forward to tg-green

Once any rule references tg-green, the ALB starts performing health checks against it. Wait for both Green targets to show **healthy** (this confirms not just that nginx is up, but that the ALB itself sees Green as healthy enough to route to).

## Step 4 — Add the test page

The `/green-test*` rule routes to Green, but Green has no file at that path by default. SSH into each Green instance and create one:

```bash
sudo cp /usr/share/nginx/html/index.html /usr/share/nginx/html/green-test.html
```

(File extension matters — without `.html`, nginx serves the file as `application/octet-stream` and the browser downloads it instead of rendering.)

Verify by hitting `http://<alb-dns>/green-test.html` in a browser. You should see the Green page. Refresh several times — the instance ID and AZ should alternate between green-1 and green-2.

## Step 5 — Run the smoke test

The smoke test script validates Green automatically and produces a pass/fail exit code that can be wired into automation:

```bash
./scripts/smoke-test.sh
```

The script performs three test groups:

1. **Reachability** — 10 HTTP requests to `/green-test.html`, checking status codes (200), latency (< 2000 ms), and that both Green instance IDs appear in the response set
2. **Content** — verifies the response contains "GREEN" and "Application v2.0", and does NOT contain "BLUE" (catches routing bugs where Blue content might leak into Green's path)
3. **AWS API health** — calls `aws elbv2 describe-target-health` to confirm tg-green has 2/2 healthy targets from the ALB's perspective

Exit code 0 means safe to switch; exit code 1 means do not switch.

The script is idempotent — running it again is harmless. It hits a public path and reads target health via the AWS API.

## Step 6 — Manual browser check (optional but recommended)

Open `/green-test.html` in an incognito tab. Confirm the page renders correctly, the version number is correct, and refreshing alternates the instance ID. This is a sanity check that the smoke test cannot replace — visual regressions wouldn't be caught by an automated content check.

## Step 7 — Pre-flight verification before traffic switch

Before executing the switch (`TRAFFIC_SWITCH.md`):

1. Smoke test passes with 0 failures
2. All three CloudWatch alarms (`bluegreen-tg-green-5xx-errors`, `bluegreen-tg-green-slow-responses`, `bluegreen-tg-green-unhealthy-hosts`) are in **OK** state, not Insufficient Data and not In alarm
3. Production root path still serves Blue: `curl -s http://<alb-dns>/ | grep -oP '<h1>\K[^<]+'` returns `BLUE`

If any pre-flight check fails, abort and investigate. Do not switch traffic to a Green that hasn't passed validation.

## What this guide deliberately does not include

- The actual traffic switch — see `docs/TRAFFIC_SWITCH.md`
- The rollback procedure — see `docs/ROLLBACK_PLAN.md`
- The CloudWatch alarm definitions — see `monitoring/alarms.md`

These are separate concerns deliberately split into separate documents. Each follows a planned-vs-observed structure so anyone reading them can see what was intended and what actually happened during the lab execution.
