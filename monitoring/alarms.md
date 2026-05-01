# CloudWatch Alarms

Three alarms watch the Green target group during and after the traffic switch. Each catches a different failure mode and is wired to the auto-rollback Lambda via EventBridge.

## Alarm definitions

### `bluegreen-tg-green-5xx-errors`

Catches application-level errors — crashes, broken endpoints, runtime exceptions returning 5xx.

| Setting | Value |
|---|---|
| Metric | `HTTPCode_Target_5XX_Count` |
| Namespace | `AWS/ApplicationELB` |
| Dimensions | TargetGroup: `tg-green`, LoadBalancer: `bluegreen-alb` |
| Statistic | Sum |
| Period | 1 minute |
| Threshold | ≥ 5 |
| Datapoints to alarm | 1 out of 1 |
| Missing data | Treat as good |

**Why these values:** Errors are unambiguous — a single minute of 5+ errors is bad. Fast threshold (1 datapoint) gives fastest response. Missing data treated as good because tg-green has no traffic before the switch and we don't want false alarms during the validation window.

### `bluegreen-tg-green-slow-responses`

Catches performance regressions — the new version is functionally correct but slow.

| Setting | Value |
|---|---|
| Metric | `TargetResponseTime` |
| Namespace | `AWS/ApplicationELB` |
| Dimensions | TargetGroup: `tg-green`, LoadBalancer: `bluegreen-alb` |
| Statistic | Average |
| Period | 1 minute |
| Threshold | > 1 second |
| Datapoints to alarm | 2 out of 2 |
| Missing data | Treat as good |

**Why these values:** Latency naturally fluctuates more than error rate, so we require sustained slowness (2 consecutive minutes) rather than a single spike. Average statistic captures typical user experience; max would be too sensitive to outliers.

### `bluegreen-tg-green-unhealthy-hosts`

Catches infrastructure failures — instances stopped, health endpoint broken, processes crashed.

| Setting | Value |
|---|---|
| Metric | `UnHealthyHostCount` |
| Namespace | `AWS/ApplicationELB` |
| Dimensions | TargetGroup: `tg-green`, LoadBalancer: `bluegreen-alb` |
| Statistic | Maximum |
| Period | 1 minute |
| Threshold | ≥ 1 |
| Datapoints to alarm | 2 out of 2 |
| Missing data | Treat as good |

**Why these values:** Maximum (not Sum or Average) tells us "did we ever have an unhealthy host during this minute" — most useful for catching the issue. The 2-datapoint threshold gives a brief health-check flap (e.g. a target restarting) a chance to recover before triggering rollback.

## Why per-target-group, not per-ALB?

The metrics we watch are exposed at both ALB and target-group dimensions. Per-target-group scoping is deliberate:

- During the validation window, tg-blue is serving production and tg-green is on standby. ALB-level metrics aggregate both and would mask Green-specific regressions.
- After the switch, tg-green is what's serving production, so the same alarms continue to monitor live traffic — no reconfiguration needed.

## Wiring to auto-rollback

All three alarms are matched by a single EventBridge rule (`bluegreen-alarm-to-rollback`) that invokes the `bluegreen-rollback` Lambda function on any ALARM transition. Filter pattern is in `automation/lambda-rollback.py` documentation and `docs/ROLLBACK_PLAN.md`.

## Tuning these for production

For a real production deployment, these thresholds would be tuned based on:

- **Traffic volume.** A site doing 1000 RPS shouldn't alarm at 5 errors/minute — that's a 0.008% error rate, well within normal noise. The threshold should scale with baseline traffic.
- **Application latency baseline.** A 1-second threshold is fine for a content site, too generous for a transactional API where 200ms is the baseline.
- **Acceptable detection time.** Faster detection (1 datapoint instead of 2) means smaller user-impact window during a real failure, at the cost of more sensitivity to transient flaps.

For this lab the thresholds are tuned for demonstration: sensitive enough to fire reliably during a deliberate failure injection, conservative enough not to false-alarm during normal smoke testing.
