# Lessons Learned

This document captures what we observed during the build, what we'd do differently in a real production setup, and the gaps between the lab implementation and what a production-grade blue-green deployment would look like.

## What worked well

**The path-based test rule pattern.** Adding `/green-test*` as a priority-10 rule before changing the default rule meant we could validate Green via the same public DNS as production, against the real ALB, without touching production traffic. This made the smoke test more authentic — we tested the actual network path requests would take after the switch, not a separate dev environment.

**Writing the runbook before executing the switch.** `TRAFFIC_SWITCH.md` was written with planned steps and a blank "observed behavior" section, then filled in during execution. This forced us to think through edge cases before they happened, and the resulting doc is honest evidence rather than retroactive narrative.

**The smoke test exit code.** Returning 0 or 1 from `smoke-test.sh` meant the validation was machine-readable. This is the foundation for wiring it into CI later as a deployment gate. A passed smoke test followed by a manual traffic switch is fine for a lab; in production the next step is automating the switch behind that gate.

**Idempotency in the Lambda.** The check for "is the listener already on tg-blue" turned out to be more useful than expected. During the manual Lambda test in Step 6.3e the listener was flipped to Blue manually, then needed to be flipped back to Green for the real failure test. If we hadn't put that check in, alarm storms could have caused unpredictable double-flips.

## What we'd change in a production setup

**Faster alarm response.** Our alarms wait 2 consecutive 1-minute datapoints (~2 minutes) before firing. The end-to-end recovery time was 3 minutes 50 seconds, dominated entirely by alarm evaluation. In production this would be too slow — users would see 503s for 2+ minutes during a real failure. The fix is `1 datapoint to alarm` plus possibly using high-resolution metrics, accepting more sensitivity to flaps in exchange for faster recovery.

**Notification on rollback.** The Lambda currently flips the listener silently. In production it should also publish to SNS or post to Slack so the on-call engineer knows production just rolled back automatically — without that, the team learns about the incident from CloudWatch hours later.

**Alarm coverage gaps.** During our test, only the unhealthy-hosts alarm fired. The 5xx and slow-responses alarms stayed in OK because no traffic was reaching the unhealthy targets, so no metrics were being published. In production you'd want overlapping alarms that fire even when targets are unreachable — for example, an alarm on the ALB-level RequestCount dropping unexpectedly.

**Decommission strategy.** We left Blue running indefinitely after the switch. In production you'd want a defined retention window (24-48 hours is typical) followed by automated termination. Otherwise the cost accumulates and engineers stop trusting which environment is the rollback target.

**Stricter IAM scoping.** The `BlueGreenListenerModify` policy uses `"Resource": "*"` because `DescribeListeners` doesn't support resource-level permissions. In a stricter setup we'd split this into two statements (Describe with `*`, Modify scoped to the specific listener ARN) so a compromised Lambda can only modify our one listener, not any listener in the account.

**No HTTPS.** The ALB listens on HTTP:80, no TLS. For real production this would need an ACM certificate, an HTTPS listener on :443, and an HTTP-to-HTTPS redirect rule. We omitted this for the lab to focus on the blue-green mechanics, but it's the first thing to add in a real deployment.

## What broke during the lab

**The `/health` endpoint as a directory.** Our first user-data script created `/usr/share/nginx/html/health/index.html`. nginx redirected `/health` to `/health/` with a 301, and the ALB's health check expected 200. Caught only because we manually `curl`ed `/health` after the instance booted — would have surfaced as failed health checks otherwise. Fixed by making `/health` a regular file. The corrected approach was carried forward into the Green user-data script.

**Filename without extension.** The first attempt at `/green-test` as an extensionless filename caused nginx to serve it as `application/octet-stream`, triggering a browser download instead of rendering. Fixed by renaming to `green-test.html`. Lesson: when nginx is serving static files, the extension is the contract, not the filename.

**CloudWatch metric not searchable.** When trying to create the 5xx alarm, the metric `HTTPCode_Target_5XX_Count` didn't appear in the metric search because tg-green had never recorded a 5xx datapoint. Worked around by navigating from EC2 → Target Groups → tg-green → Monitoring → the relevant graph → "View in metrics", which pre-populates the dimensions. Lesson: CloudWatch's metric search hides metrics with no historical datapoints, even if they're well-defined; navigate from the resource side instead.

## What would the next iteration look like

If this were the next sprint and we had a week:

1. **Replace path-based test rule with a separate test ALB.** Production and pre-production traffic on the same ALB is convenient for a lab but mixes concerns. A dedicated test ALB pointed at tg-green during validation would isolate cleanly.
2. **Add a deployment pipeline.** Today the deployment is `git push → manual launch instances → manual smoke test → manual traffic switch`. The pipeline would be `git push → CodeBuild builds AMI → CodeDeploy launches Green → smoke test (gate) → automated switch → automated alarm watch (5 min) → automated decommission of Blue`.
3. **Move from EC2 to ECS Fargate.** The Rally Platform deployment we worked on previously already uses ECS. For new web tier work, blue-green on ECS Fargate (using AWS CodeDeploy's ECS blue-green feature) abstracts away most of the manual ALB target group management.
4. **Database migration strategy.** The lab assumed v1 and v2 are schema-compatible. In real life, blue-green collides with database migrations because rollback requires the schema to also rollback. Solving this means expand-contract migrations: deploy schema changes that are backward-compatible, then deploy the code, then later remove the old schema. Worth a separate runbook.

## Honest assessment vs the rubric

| Criterion | What we did well | Gap |
|---|---|---|
| Architecture (25%) | Clear separation, parity between Blue and Green, multi-AZ, chained SGs | No HTTPS, no NAT for private subnets — used default VPC's public subnets throughout |
| Validation (20%) | Automated smoke test with exit code, AZ parity, /green-test* path for pre-switch validation | Smoke test only validates HTTP layer, not application semantics |
| Monitoring (20%) | Three alarms covering different failure modes, deliberate threshold rationale | Alarm thresholds are lab-grade; production would need traffic-volume-aware tuning |
| Reliability (20%) | Tested auto-rollback end-to-end with real failure, idempotent Lambda, manual fallback documented | 4-minute RTO is too slow for real production |
| Documentation (15%) | Planned-vs-observed split in TRAFFIC_SWITCH.md and ROLLBACK_PLAN.md, evidence files mapped to rubric | Some docs (this one included) verge on long; a senior reviewer might want a one-page exec summary on top |

The honest gaps above are not failures — they're the gaps every lab implementation has compared to production. Documenting them shows we know where the line is.
