# Traffic Switch Procedure: Blue → Green

This runbook documents the planned procedure for switching production traffic from the Blue environment (v1.0) to the Green environment (v2.0), and the rollback path if Green fails after the switch.

The procedure is split into two clearly labeled sections:

- **Planned steps** — written *before* execution, defining intent
- **Observed behavior** — filled in *during and after* execution, recording what actually happened

This separation matches real-world site reliability practice: a change has a runbook, the runbook is followed, and deviations are logged for post-incident review.

---

## State before switch

| Item | Value |
|---|---|
| Region | eu-west-1 (Ireland) |
| AWS Account | 574128098399 (comraid student lab) |
| Load balancer | `bluegreen-alb` |
| ALB DNS | `bluegreen-alb-1629631294.eu-west-1.elb.amazonaws.com` |
| Current production target group | `tg-blue` (default rule) |
| Standby target group | `tg-green` (priority 10 rule, path `/green-test*`) |
| Blue version | v1.0 |
| Green version | v2.0 |

### Validation status of Green (pre-switch)

- [x] Both Green instances Running, 2/2 status checks passed
- [x] Environment parity confirmed (same AMI, instance type, security group, AZ pattern as Blue)
- [x] tg-green target health: 2/2 Healthy
- [x] Smoke test passed (16/16 checks, see `screenshots/06-smoke-tests/`)
- [x] Both Green instances served traffic during smoke test (no single point of failure)
- [x] CloudWatch alarms armed on tg-green (5xx, latency, unhealthy hosts)

---

## Planned steps

### Step 1: Final pre-flight verification

1. Re-run `./scripts/smoke-test.sh` — confirm 0 failures
2. Confirm all three CloudWatch alarms are in **OK** state (not Insufficient data, not In alarm)
3. Confirm Blue is currently serving the root path: `curl -s http://<alb-dns>/ | grep -E 'BLUE|GREEN'` returns `BLUE`

If any pre-flight check fails, **abort and investigate** before continuing.

### Step 2: Execute the switch

Single change: edit the listener's default rule action from `forward to tg-blue` to `forward to tg-green`.

**Console path:**

1. EC2 → Load Balancers → `bluegreen-alb`
2. Listeners and rules tab → click `HTTP:80`
3. Locate the **Default** rule (priority is "Last")
4. Actions menu (⋮) on that rule → **Edit rule**
5. Change forward target group from `tg-blue` to `tg-green`
6. Save

**What changes:**
- Listener default action: `forward → tg-blue` becomes `forward → tg-green`
- The path-based test rule (priority 10, `/green-test*` → `tg-green`) is left in place — harmless, can be cleaned up after the switch is stable

**What does NOT change:**
- ALB DNS name
- ALB security group
- Any target group's instance registrations
- Any EC2 instance state
- Any DNS record outside AWS

The switch is a single config change at a single layer — that minimal blast radius is what makes blue-green safe.

### Step 3: Immediate verification (T+0 to T+30 seconds)

Within 30 seconds of saving the listener change:

1. Browser: open the ALB DNS root in a new incognito tab. Expected: Green page (green background, "GREEN", "Application v2.0").
2. Refresh 5+ times. Expected: instance ID alternates between green-1 (eu-west-1a) and green-2 (eu-west-1b).
3. Terminal: run `curl -s http://<alb-dns>/ | grep -oP 'Instance: \K[^<]+'` ten times. Expected: both green instance IDs appear.

### Step 4: Watch window (T+0 to T+5 minutes)

Open the CloudWatch alarms page in one tab and the metrics dashboard in another. Watch for 5 minutes.

**Expected metric signatures:**
- `RequestCount` for `tg-blue` drops to ~0 (no traffic)
- `RequestCount` for `tg-green` rises to match what `tg-blue` was previously
- `HTTPCode_Target_2XX_Count` on tg-green stays ≈ RequestCount (all 200 OK)
- `TargetResponseTime` on tg-green stays comparable to what tg-blue was serving
- All three CloudWatch alarms remain in **OK** state

**If any alarm transitions to In alarm during this window, execute Rollback (next section).**

### Step 5: Confirm stable (T+5 minutes onward)

If 5 minutes pass with all alarms OK and no user-reported issues:

- The switch is considered successful
- Update `docs/ROLLBACK_PLAN.md` and this file with observed behavior
- Capture screenshots: post-switch listener config, alarms in OK, metrics dashboard

Blue remains intact and registered to its target group as the rollback environment for ~24 hours, after which it can be decommissioned (or kept as the Green-of-the-next-deployment).

---

## Rollback procedure

### When to roll back

Roll back immediately if **any** of the following is true within the watch window:

- Any CloudWatch alarm transitions to **In alarm**
- Browser test shows the wrong page or errors
- `curl` to the ALB DNS returns non-200 status codes
- User reports of errors or visible degradation

There is no threshold for "wait and see" — the entire point of blue-green is that rollback is cheap and safe. When in doubt, roll back, then investigate Green offline.

### How to roll back (manual)

The rollback is the inverse of the switch. Same listener, same rule, change the target group dropdown back from `tg-green` to `tg-blue`. Save.

Recovery is immediate (sub-second once the rule is saved).

The full automated rollback path is documented separately in `docs/ROLLBACK_PLAN.md` and the `automation/lambda-rollback.py` Lambda function.

---

## Observed behavior

> *To be filled in during and after execution. Record actual times, metric values, any deviations from the plan.*

### Pre-flight verification

- Smoke test result:
- Alarm states at T-0:
- Pre-switch root path response:

### Switch execution

- Time of switch (UTC):
- Listener change confirmed in console:
- Old default action:
- New default action:

### T+0 to T+30 seconds

- Browser test result:
- Instance IDs observed in responses:
- Any errors observed:

### T+0 to T+5 minutes (watch window)

- Alarm states at T+1:
- Alarm states at T+3:
- Alarm states at T+5:
- Notable metric values:
- Deviations from expected behavior:

### Outcome

- Final result (success / rolled back):
- Any follow-ups required: