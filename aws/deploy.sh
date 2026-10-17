#!/usr/bin/env bash
# Runs on the app host:  ./deploy.sh <image-tag>
# Pulls that tag from ECR, starts the stack, checks health, and rolls back to
# the previous tag if the new one does not become healthy.
set -euo pipefail

TAG="${1:?usage: deploy.sh <image-tag>}"
REGION="ap-south-1"
cd "$(dirname "$0")"
COMPOSE="docker compose -f docker-compose.prod.yml"

# Temporary docker config so the ECR login token never stays on disk
export DOCKER_CONFIG="$(mktemp -d)"
trap 'rm -rf "$DOCKER_CONFIG"' EXIT

ssm() {
  aws ssm get-parameter --region "$REGION" --name "/todo/$1" \
    --with-decryption --query Parameter.Value --output text
}

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
export ECR_REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"

# Secrets come from SSM Parameter Store through the instance role
DB_HOST="$(ssm db-host)"
DB_USERNAME="$(ssm db-username)"
DB_PASSWORD="$(ssm db-password)"
COHERE_API_KEY="$(ssm cohere-api-key)"
SLACK_WEBHOOK_URL="$(ssm slack-webhook-url)"
export DB_HOST DB_USERNAME DB_PASSWORD COHERE_API_KEY SLACK_WEBHOOK_URL

# Private IP of this host (IMDSv2). The backend port is published on it only, so the VPC can reach it but the internet cannot
IMDS_TOKEN="$(curl -fsS -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')"
METRICS_BIND_IP="$(curl -fsS -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" http://169.254.169.254/latest/meta-data/local-ipv4)"
export METRICS_BIND_IP

aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY" > /dev/null

# Healthy means: both containers report healthy AND the API answers through nginx
healthy() {
  local svc cid
  for svc in backend frontend; do
    cid="$($COMPOSE ps -q "$svc")"
    [ -n "$cid" ] || return 1
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$cid")" = "healthy" ] || return 1
  done
  curl -fsS -o /dev/null http://localhost/api/todos
}

wait_healthy() {
  local i
  for i in $(seq 1 40); do
    if healthy; then return 0; fi
    sleep 5
  done
  return 1
}

PREV=""
if [ -f .current_tag ]; then PREV="$(cat .current_tag)"; fi
echo "Deploying tag $TAG (previous: ${PREV:-none})"

export IMAGE_TAG="$TAG"
$COMPOSE pull
$COMPOSE up -d --remove-orphans || echo "compose up reported a problem, checking health" >&2

if wait_healthy; then
  echo "$TAG" > .current_tag
  echo "Deploy OK: $TAG"
  docker image prune -af --filter "until=72h" > /dev/null
  exit 0
fi

echo "Health check FAILED for $TAG" >&2
$COMPOSE logs --tail 40 backend >&2 || true

if [ -n "$PREV" ]; then
  echo "Rolling back to $PREV" >&2
  export IMAGE_TAG="$PREV"
  $COMPOSE up -d || true
  if wait_healthy; then
    echo "Rollback OK: $PREV is running again" >&2
  else
    echo "Rollback ALSO unhealthy, manual action needed" >&2
  fi
else
  echo "No previous version to roll back to" >&2
fi
exit 1
