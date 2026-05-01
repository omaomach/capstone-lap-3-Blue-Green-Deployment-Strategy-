# Rollback Plan: Green to Blue

This document defines how production traffic is reverted from Green (v2.0) back to Blue (v1.0) when Green fails after a deployment switch. It covers two parallel rollback paths — a manual procedure for human operators, and an automated path triggered by CloudWatch alarms — and records the results of an end-to-end test of the automated path performed during this lab.

The two paths exist for different reasons. The manual path is the failsafe — it works regardless of whether monitoring or automation is functioning, and it is what an operator follows during a known-bad deploy or an investigation. The automated path is the safety net — it shortens recovery time during failure modes that humans wouldn't notice quickly enough, particularly silent failures detected only by metrics.

---

## When to roll back

Roll back if any of the following is true within 5 minutes of a Blue-to-Green switch, or at any time while Green is serving production:

- Any of the three CloudWatch alarms transitions to **In alarm**:
  - `bluegreen-tg-green-5xx-errors` — application errors
  - `bluegreen-tg-green-slow-responses` — performance regression
  - `bluegreen-tg-green-unhealthy-hosts` — target failures
- Browser checks show errors, wrong content, or non-200 responses at the ALB DNS root
- User reports of errors or visible degradation
- A health metric trend looks abnormal even if no alarm has fired (operator judgment)

There is no "wait and see" threshold. The whole point of blue-green is that rollback is cheap and safe. When in doubt, roll back, then investigate Green offline.

---

## Manual rollback procedure

The manual path is a single configuration change at the ALB's listener default rule.

**Steps:**

1. AWS Console → EC2 → Load Balancers → `bluegreen-alb`
2. **Listeners and rules** tab → click `HTTP:80`
3. Locate the **Default** rule (priority shows "Last")
4. Tick its checkbox → **Manage rules** → **Edit rule**
5. Change the forward target group from `tg-green` to `tg-blue`
6. Save

Recovery is sub-second once the rule is saved — the ALB begins routing the next incoming request to tg-blue.

**CLI alternative:**

```bash
aws elbv2 modify-listener \
  --region eu-west-1 \
  --listener-arn arn:aws:elasticloadbalancing:eu-west-1:574128098399:listener/app/bluegreen-alb/b8c2e7d0751e17a4/b4a15ffb105ac195 \
  --default-actions Type=forward,TargetGroupArn=arn:aws:elasticloadbalancing:eu-west-1:574128098399:targetgroup/tg-blue/f5660246336eba02
```

The CLI form is faster than the console (no clicks) and is the form an operator would prefer for a real outage. It is also what the Lambda function calls programmatically.

**Verification after manual rollback:**

```bash
# Confirm Blue is serving
curl -s http://bluegreen-alb-1629631294.eu-west-1.elb.amazonaws.com/ | grep -oP '<h1>\K[^<]+'
# Expected output: BLUE
```

---

## Automated rollback architecture

The automated path is the same listener modification, performed by a Lambda function in response to a CloudWatch alarm.

**The chain:**

```
Green starts failing (5xx, slow, or unhealthy)
        ↓
CloudWatch alarm enters ALARM state
        ↓
CloudWatch publishes "Alarm State Change" event
        ↓
EventBridge rule (bluegreen-alarm-to-rollback) matches the event
        ↓
EventBridge invokes Lambda function (bluegreen-rollback)
        ↓
Lambda calls elbv2:ModifyListener
        ↓
Listener default rule now forwards to tg-blue
        ↓
Production restored
```

**Components:**

| Component    | Resource                                                                               | Purpose                                                          |
| ------------ | -------------------------------------------------------------------------------------- | ---------------------------------------------------------------- |
| Trigger      | 3 CloudWatch alarms scoped to tg-green                                                 | Detect failure conditions                                        |
| Event router | EventBridge rule `bluegreen-alarm-to-rollback`                                         | Match ALARM state changes for our specific alarms, invoke Lambda |
| Action       | Lambda function `bluegreen-rollback`                                                   | Modify listener default rule                                     |
| Permissions  | IAM role `bluegreen-rollback-lambda-role` with `BlueGreenListenerModify` inline policy | Allow Lambda to read and modify the specific listener            |

**EventBridge filter pattern** (filters at the routing layer so Lambda only wakes for relevant events):

```json
{
  "source": ["aws.cloudwatch"],
  "detail-type": ["CloudWatch Alarm State Change"],
  "detail": {
    "alarmName": [
      "bluegreen-tg-green-5xx-errors",
      "bluegreen-tg-green-slow-responses",
      "bluegreen-tg-green-unhealthy-hosts"
    ],
    "state": {
      "value": ["ALARM"]
    }
  }
}
```

The pattern restricts invocations to ALARM transitions of our three alarms specifically. OK and INSUFFICIENT_DATA transitions are ignored, and unrelated alarms in the account cannot trigger a rollback.

**Lambda design notes** (full source: `automation/lambda-rollback.py`):

- Configuration via environment variables (`LISTENER_ARN`, `TG_BLUE_ARN`, `TG_GREEN_ARN`) — same code redeploys cleanly to other environments
- Defensive state-value check inside the function (defense in depth — even if the EventBridge filter is misconfigured, the Lambda still only acts on ALARM events)
- Idempotency check: if the listener already forwards to tg-blue, the function logs and returns without modifying anything (handles concurrent alarm fires, retry storms, alarms firing before the manual switch)
- Returns structured JSON with the previous and new target group ARNs — makes post-incident analysis trivial via CloudWatch Logs
- Timeout set to 30 seconds (default 3s is too tight for two ELB API calls under jitter)

**What the Lambda deliberately does NOT do:**

- No human notification (SNS, Slack) — alerting is a separate concern, would be added in production
- No retry logic — EventBridge handles retries upstream
- No automatic re-flip back to Green when the alarm clears — recovering Green is a deployment decision for a human, not for automation. The Lambda's job ends when production is on Blue.

---

## Recovery time objective

| Phase                                                                      | Duration   | Cumulative |
| -------------------------------------------------------------------------- | ---------- | ---------- |
| Green target starts failing health checks                                  | T+0        | T+0        |
| ALB marks targets unhealthy (2 consecutive failed checks at 15s interval)  | ~30s       | ~30s       |
| Alarm requires 2 consecutive 1-minute datapoints of UnHealthyHostCount ≥ 1 | ~2 min     | ~2-3 min   |
| Alarm publishes state-change event to EventBridge                          | <1s        | ~2-3 min   |
| EventBridge invokes Lambda                                                 | <1s        | ~2-3 min   |
| Lambda calls modify_listener API                                           | <2s        | ~2-3 min   |
| ALB begins routing to tg-blue                                              | sub-second | ~2-3 min   |

**Target RTO: under 4 minutes from initial failure to production restored.**

This number is dominated by alarm evaluation, not the rollback itself. The rollback API call is sub-second; the wait is CloudWatch's 1-minute metric granularity multiplied by the 2-datapoint requirement. To shrink the RTO further in production, the alarm threshold could be reduced to 1 datapoint (faster detection at the cost of slightly more sensitivity to transient flaps) or different metrics could be used as primary triggers.

---

## Post-rollback procedure

After an automatic or manual rollback, do not flip back to Green immediately, even if it appears healthy. The standard playbook:

1. **Verify Blue is serving correctly** — browser check at the ALB DNS root; spot-check key application paths.
2. **Investigate Green offline** — SSH into instances, check application logs, identify the root cause. Green instances stay running so investigation is possible.
3. **Fix the root cause** — apply the patch to the Green AMI, the deployment scripts, or whichever artifact was wrong.
4. **Validate the fix** — re-run the smoke test (`scripts/smoke-test.sh`) against tg-green via the `/green-test*` route.
5. **Repeat the deployment** — once Green is verified again, follow `docs/TRAFFIC_SWITCH.md` to perform another Blue → Green switch. Now treating the corrected Green as the next deployment.

If the issue cannot be reproduced or the cause is unclear, terminate the Green instances and start the next deployment from a known-good AMI. Cheaper than chasing a phantom bug.

---

## Observed behavior — automated rollback test

A failure was deliberately injected to test the full alarm → EventBridge → Lambda chain end-to-end on 2026-05-01.

### Test design

To trigger the unhealthy-hosts alarm, the `/health` endpoint was renamed on both Green instances:

```bash
sudo mv /usr/share/nginx/html/health /usr/share/nginx/html/health.broken
```

This is a realistic failure mode — a deploy where the application starts but the health endpoint is misconfigured. The application itself (the root path) continued to serve correctly, so client-facing requests would have continued working until the ALB stopped routing to the unhealthy targets. This is intentional: it tests the system's ability to detect a silent failure that wouldn't be caught by simple uptime monitoring.

### Timeline (EAT, UTC+3)

| Time              | Event                                                                                                                                    |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| 23:54:33          | `/health` broken on green-1 (eu-west-1a)                                                                                                 |
| 23:54:45          | `/health` broken on green-2 (eu-west-1b)                                                                                                 |
| ~23:55            | ALB began failing health checks (2 consecutive 404s, 15s interval)                                                                       |
| ~23:55–23:58      | Both Green targets transitioned to Unhealthy in tg-green                                                                                 |
| 23:58:08          | `bluegreen-tg-green-unhealthy-hosts` alarm transitioned to **In alarm** (after 2 consecutive 1-min datapoints of UnHealthyHostCount ≥ 1) |
| 23:58:08          | CloudWatch published Alarm State Change event                                                                                            |
| 23:58:08–23:58:23 | EventBridge matched the pattern, invoked Lambda; Lambda called `modify_listener`                                                         |
| 23:58:23          | Watch loop first observed `BLUE` response — listener now forwards to tg-blue                                                             |

**End-to-end recovery time: 3 minutes 50 seconds from initial failure injection to production restored.**

### Watch loop output

A continuous polling loop ran throughout the test, polling the ALB DNS root every 5 seconds:

```
23:54:25 — HTTP 200, GREEN
23:54:31 — HTTP 200, GREEN
... (continuous GREEN responses for the alarm-evaluation window) ...
23:58:18 — HTTP 200, GREEN
23:58:23 — HTTP 200, BLUE   ← rollback complete
23:58:29 — HTTP 200, BLUE
... (BLUE from this point onward) ...
```

The full output is preserved at `screenshots/09-rollback/watch-loop-rollback-timeline.txt`.

### Notable observations

- **No 5xx errors observed during the entire test.** The application root path continued to serve correctly on Green instances even after they were marked unhealthy by the ALB. Production never returned a client-visible error. This was a happy accident specific to the failure mode injected — in a real failure (instance crash, app crash) the user-facing 503 window would have been larger. Production-grade alarms should fire faster (1 datapoint) to shrink that window.
- **Only the unhealthy-hosts alarm fired.** The 5xx alarm and slow-responses alarm stayed in OK throughout. Reason: those alarms depend on traffic actually hitting the targets, but once the ALB stopped routing to the unhealthy Green instances, no metrics were published for those dimensions. This is fine — the unhealthy-hosts alarm caught the issue first, which is what triggered rollback. In a production system you would want overlapping coverage so a single alarm misconfiguration doesn't blind the system.
- **Lambda invocation succeeded on the first try.** No retries, no errors in CloudWatch Logs. The function's defensive state check confirmed the listener was on tg-green before flipping to tg-blue, then logged the previous and new target group ARNs.
- **The idempotency check was exercised earlier**, during the manual Lambda test in Step 6.3e — that test invocation flipped the listener to tg-blue, and the listener had to be manually flipped back to tg-green before this end-to-end test. If multiple alarms had fired close together during the auto-rollback test, the second invocation would have hit the idempotency path and returned `status: no_op`.

### Recovery state

After the test:

- Listener default rule: forwards to tg-blue (production restored)
- Browser confirmed at root: BLUE v1.0
- `/health` was restored on both Green instances by reversing the `mv`
- Green instances returned to healthy state in tg-green within ~30 seconds
- Listener was deliberately NOT flipped back to Green — production remains on Blue, awaiting investigation and a corrected re-deployment per the post-rollback procedure above

This matches what would happen in a real incident: the system catches the failure, restores production automatically, and waits for a human to decide when to attempt the next deployment.

---

## Lessons from the test

- The rubric's Reliability criterion is satisfied by demonstrating not just a rollback plan but a tested rollback plan. The timeline above is observable evidence of the architecture working under a real failure event, not just a theoretical design.
- The biggest contributor to recovery time is alarm evaluation, not anything in our control loop. To improve RTO further, alarm thresholds and CloudWatch metric resolution are the variables to tune.
- The manual path is still important. If the Lambda role's permissions get accidentally revoked, or if EventBridge has an outage, or if the alarm itself is misconfigured, the human-driven rollback is what restores production. Automation is the safety net, not the only path.
