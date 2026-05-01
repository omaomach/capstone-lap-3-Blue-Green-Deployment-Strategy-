# Architecture

This document explains the design decisions behind the Blue-Green deployment, complementing the visual in `diagrams/architecture.svg`.

## Components

| Component | Resource | Count |
|---|---|---|
| VPC | Default VPC in eu-west-1 | 1 |
| Subnets | Public subnets across eu-west-1a and eu-west-1b | 2 |
| EC2 instances | t2.micro, Amazon Linux 2023, nginx | 4 (2 Blue, 2 Green) |
| Security group (ALB) | `bluegreen-alb-sg` | 1 |
| Security group (EC2) | `bluegreen-ec2-sg` | 1 |
| Application Load Balancer | `bluegreen-alb`, internet-facing | 1 |
| Listener | HTTP:80 with 2 rules | 1 |
| Target groups | `tg-blue`, `tg-green` | 2 |
| CloudWatch alarms | 5xx errors, response time, unhealthy hosts | 3 |
| EventBridge rule | `bluegreen-alarm-to-rollback` | 1 |
| Lambda function | `bluegreen-rollback` | 1 |
| IAM role | `bluegreen-rollback-lambda-role` | 1 |

## Design decisions

**Why two target groups, not one with weighted routing?** Two target groups give a clean cutover. With weighted routing (e.g. 95% Blue, 5% Green), users see different versions on different requests during the transition window. Two separate target groups mean a single listener change atomically flips production from one version to the other.

**Why chained security groups?** The EC2 security group accepts HTTP only from the ALB security group, not from `0.0.0.0/0`. This means EC2 instances are unreachable from the internet directly — all traffic must go through the ALB. The ALB is the only public entry point. This pattern is more secure than IP-range allowlists because the ALB's IPs can change without breaking the rule.

**Why multi-AZ (eu-west-1a + eu-west-1b) for both Blue and Green?** ALBs require targets in at least 2 AZs to be highly available. Putting both Blue and both Green instances across the same two AZs gives Blue and Green identical AZ distribution — essential for parity. After the switch, Green is running with the same AZ topology Blue had.

**Why a path-based test rule for Green?** The listener has two rules: a priority-10 rule that forwards `/green-test*` to tg-green, and the default rule that forwards everything else to tg-blue. This lets us validate Green via the public ALB DNS (smoke tests, browser checks) while production traffic continues to Blue. When ready to cut over, only the default rule changes.

**Why scope CloudWatch alarms to tg-green specifically (not the ALB overall)?** Per-target-group alarms tell us about the *new* environment specifically. ALB-level metrics aggregate Blue and Green together, which would mask Green-specific regressions during the validation window. After the cutover, tg-green is what's serving production, so the alarms continue to monitor live traffic.

**Why three alarms with different thresholds?** Each alarm catches a different failure mode:

- 5xx errors: 1 datapoint, 1 minute — errors are unambiguous, fast response is fine
- Slow responses: 2 datapoints, 2 minutes — latency naturally fluctuates, want sustained slowness
- Unhealthy hosts: 2 datapoints, 2 minutes — gives transient health-check flaps a chance to recover

The threshold differences reflect the noise characteristics of each metric.

## Environment parity

The rubric grades on environment parity (20% Validation). What we kept identical between Blue and Green:

- AMI (Amazon Linux 2023, same launch)
- Instance type (t2.micro)
- Security group (`bluegreen-ec2-sg` — both Blue and Green instances use the same SG)
- AZ pattern (blue-1 and green-1 in eu-west-1a; blue-2 and green-2 in eu-west-1b)
- IAM (default — no instance profiles)
- VPC and subnets

The only differences:

- Instance names (`blue-1`, `blue-2` vs `green-1`, `green-2`)
- Application content (the nginx page identifies as Blue v1 or Green v2)
- Target group registration (Blue → tg-blue, Green → tg-green)

If parity slipped (different SG, different subnet, different AMI), validating Green wouldn't actually validate what production looks like after the switch. That gap is the most common reason real-world blue-green deployments fail despite "successful" pre-switch tests.

## Failure modes the design catches

| Failure | Detected by | Recovered by |
|---|---|---|
| Green app returns 5xx | `bluegreen-tg-green-5xx-errors` alarm | Auto-rollback Lambda |
| Green app slow | `bluegreen-tg-green-slow-responses` alarm | Auto-rollback Lambda |
| Green instance/health endpoint fails | `bluegreen-tg-green-unhealthy-hosts` alarm | Auto-rollback Lambda |
| Operator notices issue | Manual observation | Manual rollback (listener edit) |
| Lambda fails or alarm misconfigured | Operator inspection | Manual rollback (CLI fallback) |

Multiple paths to recovery — automation is the safety net, the manual path is the failsafe.
