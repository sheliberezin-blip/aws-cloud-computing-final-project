#!/usr/bin/env bash
# Read-only status report: shows what already exists for every stage of the project.
# Changes nothing in AWS.
export AWS_REGION=eu-north-1
source ~/fp.env 2>/dev/null

section() { echo; echo "===== $1"; }

section "Stage 2 — Security group inbound rules"
for sg in $(aws ec2 describe-security-groups --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values='final-project-*' \
    --query 'SecurityGroups[].GroupId' --output text); do
  aws ec2 describe-security-groups --group-ids "$sg" \
    --query 'SecurityGroups[0].[GroupName,GroupId]' --output text
  aws ec2 describe-security-groups --group-ids "$sg" \
    --query 'SecurityGroups[0].IpPermissions[].[FromPort,ToPort,join(`,`,IpRanges[].CidrIp),join(`,`,UserIdGroupPairs[].GroupId)]' \
    --output text | sed 's/^/    in: /'
done

section "Stage 3 — RDS + password in Parameter Store"
aws rds describe-db-instances \
  --query 'DBInstances[].[DBInstanceIdentifier,Engine,DBInstanceStatus,PubliclyAccessible,Endpoint.Address,DBName,MasterUsername,DBSubnetGroup.VpcId]' \
  --output text
aws ssm describe-parameters --query 'Parameters[].[Name,Type]' --output text

section "Stage 4 — ECR repositories"
aws ecr describe-repositories --query 'repositories[].repositoryName' --output text
for r in final-project-visits-service final-project-stats-service; do
  echo "  $r images: $(aws ecr list-images --repository-name $r --query 'imageIds[].imageTag' --output text 2>/dev/null)"
done

section "Stage 4 — IAM roles / instance profiles"
aws iam list-roles --query 'Roles[?contains(RoleName,`final`) || contains(RoleName,`ec2`) || contains(RoleName,`github`)].RoleName' --output text
aws iam list-instance-profiles --query 'InstanceProfiles[].[InstanceProfileName,Roles[0].RoleName]' --output text

section "Stage 4 — EC2 instances (any state)"
aws ec2 describe-instances --filters Name=vpc-id,Values="$VPC_ID" \
  --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,InstanceId,State.Name,PrivateIpAddress]' --output text

section "Stage 5 — ALB, listeners, rules, target groups"
ALB_ARN=$(aws elbv2 describe-load-balancers --names final-project-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)
aws elbv2 describe-load-balancers --names final-project-alb --query 'LoadBalancers[0].[DNSName,Scheme,State.Code]' --output text
for l in $(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --query 'Listeners[].ListenerArn' --output text); do
  aws elbv2 describe-listeners --listener-arns "$l" --query 'Listeners[0].[Protocol,Port]' --output text | sed 's/^/  listener: /'
  aws elbv2 describe-rules --listener-arn "$l" \
    --query 'Rules[].[Priority,join(`,`,Conditions[].Values[] || `[]`),Actions[0].TargetGroupArn]' --output text \
    | sed 's#arn:.*:targetgroup/##; s/^/    rule: /'
done
for tg in $(aws elbv2 describe-target-groups --query 'TargetGroups[].TargetGroupArn' --output text); do
  aws elbv2 describe-target-groups --target-group-arns "$tg" \
    --query 'TargetGroups[0].[TargetGroupName,Port,HealthCheckPath]' --output text | sed 's/^/  tg: /'
  aws elbv2 describe-target-health --target-group-arn "$tg" \
    --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output text | sed 's/^/      target: /'
done

section "Stage 6 — S3 + CloudFront"
aws s3api list-buckets --query 'Buckets[].Name' --output text
aws cloudfront list-distributions --query 'DistributionList.Items[].[Id,DomainName,Status,Origins.Items[0].DomainName]' --output text

section "Stage 8 — GitHub OIDC provider"
aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text

echo
echo "===== done"
