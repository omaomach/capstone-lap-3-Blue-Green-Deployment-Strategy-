#!/bin/bash
# smoke-test.sh — Validates the Green environment before traffic switch
#
# Run from your laptop. Exits 0 if Green is safe to switch to, 1 otherwise.
# Designed to be wired into automation later (Makefile, CI, EventBridge gate).
#
# Requires: curl, jq, bc, awscli (configured for account 574128098399)

set -uo pipefail

# ---------- Configuration ----------
ALB_DNS="bluegreen-alb-1629631294.eu-west-1.elb.amazonaws.com"
TEST_PATH="/green-test.html"
TG_GREEN_NAME="tg-green"
AWS_REGION="eu-west-1"

EXPECTED_VERSION="Application v2.0"
EXPECTED_HEADER="GREEN"
MAX_RESPONSE_TIME_MS=2000
NUM_REQUESTS=10

# ---------- Helpers ----------
PASS=0
FAIL=0
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

check() {
  local name="$1"
  local result="$2"
  if [[ "$result" == "PASS" ]]; then
    echo -e "  ${GREEN}OK${NC} $name"
    PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC} $name  ${RED}— $result${NC}"
    FAIL=$((FAIL+1))
  fi
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo -e "${RED}Missing required command: $1${NC}" >&2
    exit 2
  fi
}

require_cmd curl
require_cmd jq
require_cmd bc
require_cmd aws

echo "================================================================"
echo "Smoke test: Green environment"
echo "ALB:  http://$ALB_DNS"
echo "Path: $TEST_PATH"
echo "Time: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
echo "================================================================"

# ---------- Test 1: Reachability + status codes + latency ----------
echo ""
echo "[1/3] Reachability, status codes, and latency"
seen_instances=""
for i in $(seq 1 $NUM_REQUESTS); do
  response=$(curl -s -w "\n%{http_code}\n%{time_total}" "http://${ALB_DNS}${TEST_PATH}" || echo "")
  body=$(echo "$response" | head -n -2)
  code=$(echo "$response" | tail -n 2 | head -n 1)
  time_s=$(echo "$response" | tail -n 1)
  time_ms=$(echo "$time_s * 1000" | bc | cut -d. -f1)

  if [[ "$code" != "200" ]]; then
    check "Request $i status code" "got $code, expected 200"
    continue
  fi
  if [[ "${time_ms:-0}" -gt "$MAX_RESPONSE_TIME_MS" ]]; then
    check "Request $i response time" "${time_ms}ms > ${MAX_RESPONSE_TIME_MS}ms"
  else
    check "Request $i: 200 OK in ${time_ms}ms" "PASS"
  fi

  inst=$(echo "$body" | grep -oP 'Instance: \Ki-[a-f0-9]+' || echo "unknown")
  if [[ -n "$inst" && "$seen_instances" != *"$inst"* ]]; then
    seen_instances="$seen_instances $inst"
  fi
done
echo "  Instances that responded:${seen_instances:- none}"
inst_count=$(echo "$seen_instances" | wc -w)
if [[ "$inst_count" -ge 2 ]]; then
  check "Both Green instances served traffic" "PASS"
else
  check "Both Green instances served traffic" "only $inst_count distinct instance(s) seen — possible single point of failure"
fi

# ---------- Test 2: Content matches expected version ----------
echo ""
echo "[2/3] Content matches expected v2.0"
body=$(curl -s "http://${ALB_DNS}${TEST_PATH}")
if echo "$body" | grep -q "$EXPECTED_HEADER"; then
  check "Page contains '$EXPECTED_HEADER'" "PASS"
else
  check "Page contains '$EXPECTED_HEADER'" "missing — wrong content served"
fi
if echo "$body" | grep -q "$EXPECTED_VERSION"; then
  check "Page contains '$EXPECTED_VERSION'" "PASS"
else
  check "Page contains '$EXPECTED_VERSION'" "missing — old version still deployed?"
fi
if echo "$body" | grep -q "BLUE"; then
  check "Page does NOT contain 'BLUE'" "Blue content leaking into Green path — routing bug"
else
  check "Page does NOT contain 'BLUE'" "PASS"
fi

# ---------- Test 3: tg-green health from AWS API ----------
echo ""
echo "[3/3] tg-green target health (AWS API)"
tg_arn=$(aws elbv2 describe-target-groups \
  --region "$AWS_REGION" \
  --names "$TG_GREEN_NAME" \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text 2>/dev/null)

if [[ -z "$tg_arn" || "$tg_arn" == "None" ]]; then
  check "Resolve $TG_GREEN_NAME ARN" "could not find target group — check AWS credentials and region"
else
  check "Resolve $TG_GREEN_NAME ARN" "PASS"
  health_json=$(aws elbv2 describe-target-health \
    --region "$AWS_REGION" \
    --target-group-arn "$tg_arn" 2>/dev/null)
  total=$(echo "$health_json" | jq '.TargetHealthDescriptions | length')
  healthy=$(echo "$health_json" | jq '[.TargetHealthDescriptions[] | select(.TargetHealth.State == "healthy")] | length')
  echo "  $healthy of $total targets healthy"
  if [[ "$healthy" -eq "$total" && "$total" -gt 0 ]]; then
    check "All Green targets healthy" "PASS"
  else
    check "All Green targets healthy" "$healthy/$total healthy — investigate before switching"
    echo "  Per-target detail:"
    echo "$health_json" | jq -r '.TargetHealthDescriptions[] | "    \(.Target.Id) (\(.Target.AvailabilityZone)): \(.TargetHealth.State) — \(.TargetHealth.Description // "no detail")"'
  fi
fi

# ---------- Summary ----------
echo ""
echo "================================================================"
echo -e "Result:  ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
echo "================================================================"
if [[ $FAIL -eq 0 ]]; then
  echo -e "${GREEN}Green environment is ready for traffic switch.${NC}"
  exit 0
else
  echo -e "${RED}Green environment failed validation. Do NOT switch traffic.${NC}"
  exit 1
fi