#!/usr/bin/env bash
# AWS commands for the todo project, kept in the order they were run.
# Sections are appended as they are done. No IDs or account numbers are stored here;
# they come from an env file kept outside the repo (see TODO_ENV below).
set -euo pipefail

REGION="ap-south-1"
PROFILE="${AWS_PROFILE:-bharath}"
source "${TODO_ENV:-$HOME/todo-aws.env}"

# ---- Monitoring ports on the app security group (source: ops security group only) ----
allow_from_group() {
  local port="$1" out
  if out="$(aws ec2 authorize-security-group-ingress \
    --profile "$PROFILE" --region "$REGION" --group-id "$APP_SG" \
    --protocol tcp --port "$port" --source-group "$OPS_SG" \
    --query Return --output text 2>&1)"; then
    echo "port $port: $out"
  elif [[ "$out" == *InvalidPermission.Duplicate* ]]; then
    echo "port $port: rule already exists"
  else
    echo "$out" >&2
    return 1
  fi
}

allow_from_group 8080   # backend /actuator/prometheus
allow_from_group 9100   # node exporter
allow_from_group 8081   # cadvisor
