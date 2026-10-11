#!/usr/bin/env bash
# Demo helper (read-only): shows when each microservice container was started, and
# what heading CloudFront is currently serving. Run it before and after a push to
# prove the pipeline redeployed only what changed.
set -euo pipefail
export AWS_REGION=eu-north-1

started_at() { # instance-name container-name
  local id cmd_id
  id=$(aws ec2 describe-instances --filters Name=tag:Name,Values="$1" Name=instance-state-name,Values=running \
    --query 'Reservations[0].Instances[0].InstanceId' --output text)
  cmd_id=$(aws ssm send-command --instance-ids "$id" --document-name AWS-RunShellScript \
    --parameters "{\"commands\":[\"docker inspect -f '{{.State.StartedAt}} {{.Config.Image}}' $2\"]}" \
    --query Command.CommandId --output text)
  sleep 3
  until aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$id" --query Status --output text \
      2>/dev/null | grep -qvE 'Pending|InProgress|Delayed'; do sleep 2; done
  printf '  %-15s started %s\n' "$2" "$(aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$id" \
    --query StandardOutputContent --output text | sed 's#[^ ]*/##')"
}

echo "Containers:"
started_at final-project-visits-service visits-service
started_at final-project-stats-service  stats-service

CF_DOMAIN=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='final-project-frontend'].DomainName | [0]" --output text)
echo "Frontend heading served by CloudFront:"
echo "  $(curl -s "https://$CF_DOMAIN/" | grep -o '<h1>.*</h1>')"
