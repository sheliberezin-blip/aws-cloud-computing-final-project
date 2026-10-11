#!/usr/bin/env bash
# Stage 7 — build both microservice images, push them to ECR, and run them on their
# EC2 instances via SSM Run Command (no SSH).
#
# Usage:  07-deploy-services.sh            -> deploy both
#         07-deploy-services.sh visits     -> deploy only visits-service
#         07-deploy-services.sh stats      -> deploy only stats-service
#
# ALLOWED_ORIGIN: the CloudFront domain (stage 6). If CloudFront doesn't exist yet, a
# placeholder is used — /health works without it; re-run this script after stage 6.
set -euo pipefail

export AWS_REGION=eu-north-1
cd "$(dirname "$0")/.."            # repo root, so workloads/ paths work from anywhere

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGISTRY=$ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com
TAG=$(git rev-parse --short HEAD 2>/dev/null || date +%s)
DB_PARAM=/final-project/db/password

CF_DOMAIN=$(aws cloudfront list-distributions \
  --query 'DistributionList.Items[0].DomainName' --output text 2>/dev/null || true)
if [ -n "$CF_DOMAIN" ] && [ "$CF_DOMAIN" != "None" ]; then
  # https: current Chrome/Edge always upgrade the page to https, so that is the origin the
  # browser actually sends. Override with ORIGIN_SCHEME=http if you load the page over http.
  ALLOWED_ORIGIN=${ORIGIN_SCHEME:-https}://$CF_DOMAIN
else
  ALLOWED_ORIGIN=http://cloudfront-not-created-yet.invalid
  echo "NOTE: no CloudFront yet — using placeholder ALLOWED_ORIGIN, re-run after stage 6"
fi

instance_id() { # Name tag -> running instance ID
  aws ec2 describe-instances --filters Name=tag:Name,Values="$1" Name=instance-state-name,Values=running \
    --query 'Reservations[0].Instances[0].InstanceId' --output text
}

build_and_push() { # service
  local image=$REGISTRY/final-project-$1:$TAG
  echo "--- building $1 -> $image"
  docker build -t "$image" "workloads/$1"
  docker push "$image"
  # Also tag as latest so a manual "docker pull ...:latest" always gets the newest build
  docker tag "$image" "$REGISTRY/final-project-$1:latest"
  docker push "$REGISTRY/final-project-$1:latest"
}

# Sends a bash script to an instance through SSM and prints its output.
# The script travels base64-encoded so no quoting survives into the SSM parameters.
run_on() { # instance-id script-text
  local b64 cmd_id status
  b64=$(printf '%s' "$2" | base64 -w0)
  cmd_id=$(aws ssm send-command --instance-ids "$1" --document-name AWS-RunShellScript \
    --parameters "{\"commands\":[\"echo $b64 | base64 -d | bash\"]}" \
    --query Command.CommandId --output text)
  echo "    SSM command $cmd_id sent to $1, waiting..."
  # Poll instead of "aws ssm wait" — that gives up after ~100s, and a first docker
  # install + image pull can take longer.
  for _ in $(seq 120); do
    sleep 5
    status=$(aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$1" \
      --query Status --output text 2>/dev/null || echo Pending)
    case $status in Pending|InProgress|Delayed) ;; *) break ;; esac
  done
  aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$1" \
    --query '[StandardOutputContent,StandardErrorContent]' --output text | sed 's/^/    | /'
  [ "$status" = "Success" ] || { echo "ERROR: SSM command finished with status $status"; exit 1; }
}

# Common prefix for every remote script: make sure Docker is there (t3.micro sometimes
# gets its first-boot install OOM-killed) and log in to ECR.
REMOTE_PREP="set -e
command -v docker >/dev/null || dnf install -y docker
systemctl enable --now docker
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $REGISTRY"

deploy_visits() {
  local id db_host db_name db_user
  id=$(instance_id final-project-visits-service)
  read -r db_host db_name db_user < <(aws rds describe-db-instances --db-instance-identifier final-project-db \
    --query 'DBInstances[0].[Endpoint.Address,DBName,MasterUsername]' --output text)
  echo "--- deploying visits-service to $id"
  # \$DB_PASSWORD is escaped: it is fetched ON the instance at runtime, so the
  # plaintext password never appears in the SSM command or CloudTrail.
  run_on "$id" "$REMOTE_PREP
DB_PASSWORD=\$(aws ssm get-parameter --region $AWS_REGION --name $DB_PARAM --with-decryption --query Parameter.Value --output text)
docker pull $REGISTRY/final-project-visits-service:$TAG
docker rm -f visits-service 2>/dev/null || true
docker run -d --name visits-service --restart unless-stopped -p 8080:8080 \
  -e DB_HOST=$db_host -e DB_NAME=$db_name -e DB_USER=$db_user -e DB_PASSWORD=\"\$DB_PASSWORD\" \
  -e PGSSLMODE=require -e ALLOWED_ORIGIN=$ALLOWED_ORIGIN \
  $REGISTRY/final-project-visits-service:$TAG
sleep 5
docker ps --filter name=visits-service --format '{{.Names}} {{.Status}}'
curl -s localhost:8080/health"
}

deploy_stats() {
  local id visits_ip
  id=$(instance_id final-project-stats-service)
  visits_ip=$(aws ec2 describe-instances --instance-ids "$(instance_id final-project-visits-service)" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
  echo "--- deploying stats-service to $id (visits-service at $visits_ip)"
  run_on "$id" "$REMOTE_PREP
docker pull $REGISTRY/final-project-stats-service:$TAG
docker rm -f stats-service 2>/dev/null || true
docker run -d --name stats-service --restart unless-stopped -p 8081:8081 \
  -e VISITS_SERVICE_URL=http://$visits_ip:8080 -e ALLOWED_ORIGIN=$ALLOWED_ORIGIN \
  $REGISTRY/final-project-stats-service:$TAG
sleep 5
docker ps --filter name=stats-service --format '{{.Names}} {{.Status}}'
curl -s localhost:8081/health"
}

TARGETS=${1:-both}
aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"

case $TARGETS in
  visits) build_and_push visits-service; deploy_visits ;;
  stats)  build_and_push stats-service;  deploy_stats ;;
  both)   build_and_push visits-service; build_and_push stats-service; deploy_visits; deploy_stats ;;
  *) echo "usage: $0 [visits|stats|both]"; exit 1 ;;
esac

echo
echo "--- ALB target health (can take ~30s to turn healthy)"
sleep 30
for tg in final-project-visits-tg final-project-stats-tg; do
  arn=$(aws elbv2 describe-target-groups --names "$tg" --query 'TargetGroups[0].TargetGroupArn' --output text)
  echo "$tg: $(aws elbv2 describe-target-health --target-group-arn "$arn" \
    --query 'TargetHealthDescriptions[].TargetHealth.State' --output text)"
done
ALB_DNS=$(aws elbv2 describe-load-balancers --names final-project-alb --query 'LoadBalancers[0].DNSName' --output text)
echo
echo "Try it:  curl -X POST http://$ALB_DNS/visits   and   curl http://$ALB_DNS/stats"
