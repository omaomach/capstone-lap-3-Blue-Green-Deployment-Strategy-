"""
lambda-rollback.py — Auto-rollback Green to Blue on alarm.

Triggered by EventBridge when any of the bluegreen-tg-green-* alarms enters
ALARM state. Modifies the ALB listener default rule to forward to tg-blue.

Idempotent: if the listener already forwards to tg-blue (rollback already
happened, or alarm fired before switch), this is a no-op.

Configuration via environment variables:
    LISTENER_ARN   ARN of the ALB listener whose default rule we modify
    TG_BLUE_ARN    ARN of the Blue target group (rollback destination)
    TG_GREEN_ARN   ARN of the Green target group (current production)
"""

import os
import json
import logging
import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

LISTENER_ARN = os.environ['LISTENER_ARN']
TG_BLUE_ARN = os.environ['TG_BLUE_ARN']
TG_GREEN_ARN = os.environ['TG_GREEN_ARN']

elbv2 = boto3.client('elbv2')


def get_current_default_target_group(listener_arn: str) -> str:
    """Return the ARN of the target group the listener default rule currently forwards to."""
    response = elbv2.describe_listeners(ListenerArns=[listener_arn])
    listener = response['Listeners'][0]
    for action in listener['DefaultActions']:
        if action['Type'] == 'forward':
            if 'TargetGroupArn' in action:
                return action['TargetGroupArn']
            if 'ForwardConfig' in action:
                return action['ForwardConfig']['TargetGroups'][0]['TargetGroupArn']
    raise RuntimeError("Listener has no forward action in default rule")


def rollback_to_blue(listener_arn: str, tg_blue_arn: str) -> None:
    """Modify the listener default action to forward to tg-blue."""
    elbv2.modify_listener(
        ListenerArn=listener_arn,
        DefaultActions=[{
            'Type': 'forward',
            'TargetGroupArn': tg_blue_arn,
        }],
    )


def lambda_handler(event, context):
    logger.info("Received event: %s", json.dumps(event))

    # Defensive: only act on ALARM state. EventBridge rule should already
    # filter for this, but double-check in case the rule is misconfigured.
    detail = event.get('detail', {})
    state = detail.get('state', {}).get('value')
    alarm_name = detail.get('alarmName', 'unknown')

    if state != 'ALARM':
        logger.info("Ignoring event with state=%s (alarm: %s)", state, alarm_name)
        return {'status': 'ignored', 'reason': f'state was {state}, not ALARM'}

    # Idempotency check: if we're already on Blue, do nothing
    try:
        current_tg = get_current_default_target_group(LISTENER_ARN)
    except (ClientError, RuntimeError) as e:
        logger.error("Failed to read current listener state: %s", e)
        raise

    if current_tg == TG_BLUE_ARN:
        logger.info(
            "Rollback skipped — listener already forwards to tg-blue. "
            "Alarm: %s. Current TG: %s",
            alarm_name, current_tg,
        )
        return {
            'status': 'no_op',
            'reason': 'listener already on tg-blue',
            'alarm': alarm_name,
        }

    if current_tg != TG_GREEN_ARN:
        logger.warning(
            "Listener is on an unexpected target group (%s). "
            "Rolling back to tg-blue anyway. Alarm: %s",
            current_tg, alarm_name,
        )

    try:
        rollback_to_blue(LISTENER_ARN, TG_BLUE_ARN)
    except ClientError as e:
        logger.error("Rollback failed: %s", e)
        raise

    logger.info(
        "Rollback executed. Alarm: %s. Listener default: %s -> %s",
        alarm_name, current_tg, TG_BLUE_ARN,
    )
    return {
        'status': 'rolled_back',
        'alarm': alarm_name,
        'previous_target_group': current_tg,
        'new_target_group': TG_BLUE_ARN,
    }