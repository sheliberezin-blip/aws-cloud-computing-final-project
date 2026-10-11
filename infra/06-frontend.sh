#!/usr/bin/env bash
# Stage 6 — Frontend: private S3 bucket + CloudFront (Origin Access Control), then
# inject the ALB address into index.html, upload it, and invalidate the CloudFront cache.
# Safe to run more than once: existing bucket / OAC / distribution are reused.
set -euo pipefail

export AWS_REGION=eu-north-1
cd "$(dirname "$0")/.."            # repo root

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
BUCKET=final-project-frontend-$ACCOUNT          # bucket names are global — account ID keeps it unique
COMMENT=final-project-frontend                  # how we find our distribution again
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# --- 1. Private S3 bucket ---
if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  aws s3api create-bucket --bucket "$BUCKET" \
    --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null
  echo "created bucket $BUCKET"
fi
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# --- 2. Origin Access Control: lets CloudFront (and only CloudFront) read the bucket ---
OAC_ID=$(aws cloudfront list-origin-access-controls \
  --query "OriginAccessControlList.Items[?Name=='final-project-oac'].Id | [0]" --output text)
if [ "$OAC_ID" = "None" ]; then
  OAC_ID=$(aws cloudfront create-origin-access-control --origin-access-control-config \
    Name=final-project-oac,SigningProtocol=sigv4,SigningBehavior=always,OriginAccessControlOriginType=s3 \
    --query OriginAccessControl.Id --output text)
  echo "created OAC $OAC_ID"
fi

# --- 3. CloudFront distribution ---
DIST_ID=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='$COMMENT'].Id | [0]" --output text)
if [ "$DIST_ID" = "None" ]; then
  # ViewerProtocolPolicy=allow-all ("HTTP and HTTPS"): the ALB is HTTP-only, so the page
  # must be loadable over http:// or the browser blocks its fetch() calls as mixed content.
  # 658327ea-... is AWS's managed "CachingOptimized" cache policy.
  cat > "$TMP/dist.json" <<EOF
{
  "CallerReference": "final-project-$(date +%s)",
  "Comment": "$COMMENT",
  "Enabled": true,
  "DefaultRootObject": "index.html",
  "PriceClass": "PriceClass_100",
  "Origins": { "Quantity": 1, "Items": [ {
    "Id": "s3-frontend",
    "DomainName": "$BUCKET.s3.$AWS_REGION.amazonaws.com",
    "OriginAccessControlId": "$OAC_ID",
    "S3OriginConfig": { "OriginAccessIdentity": "" }
  } ] },
  "DefaultCacheBehavior": {
    "TargetOriginId": "s3-frontend",
    "ViewerProtocolPolicy": "allow-all",
    "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6",
    "Compress": true,
    "AllowedMethods": { "Quantity": 2, "Items": ["GET", "HEAD"] }
  }
}
EOF
  DIST_ID=$(aws cloudfront create-distribution --distribution-config "file://$TMP/dist.json" \
    --query Distribution.Id --output text)
  echo "created CloudFront distribution $DIST_ID (takes ~5-15 min to deploy worldwide)"
fi
CF_DOMAIN=$(aws cloudfront get-distribution --id "$DIST_ID" --query Distribution.DomainName --output text)

# --- 4. Bucket policy: allow s3:GetObject only to THIS distribution ---
cat > "$TMP/policy.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [ {
    "Sid": "AllowCloudFrontOAC",
    "Effect": "Allow",
    "Principal": { "Service": "cloudfront.amazonaws.com" },
    "Action": "s3:GetObject",
    "Resource": "arn:aws:s3:::$BUCKET/*",
    "Condition": { "StringEquals": { "AWS:SourceArn": "arn:aws:cloudfront::$ACCOUNT:distribution/$DIST_ID" } }
  } ]
}
EOF
aws s3api put-bucket-policy --bucket "$BUCKET" --policy "file://$TMP/policy.json"

# --- 5. Build + upload the frontend ---
# Static hosting has no runtime env vars, so the ALB address is baked into the file here.
ALB_DNS=$(aws elbv2 describe-load-balancers --names final-project-alb \
  --query 'LoadBalancers[0].DNSName' --output text)
mkdir -p "$TMP/site"
cp -r workloads/frontend/. "$TMP/site/"
sed -i "s|__API_BASE_URL__|http://$ALB_DNS|g" "$TMP/site/index.html"
aws s3 sync "$TMP/site/" "s3://$BUCKET/" --delete

# --- 6. Invalidate the cache, otherwise CloudFront keeps serving the old index.html ---
INV_ID=$(aws cloudfront create-invalidation --distribution-id "$DIST_ID" --paths '/*' \
  --query Invalidation.Id --output text)

cat >> ~/fp.env <<EOF
export FRONTEND_BUCKET=$BUCKET
export CF_DIST_ID=$DIST_ID
export CF_DOMAIN=$CF_DOMAIN
EOF
sort -u -o ~/fp.env ~/fp.env

echo
echo "Stage 6 done."
echo "  bucket:        $BUCKET"
echo "  distribution:  $DIST_ID  (status: $(aws cloudfront get-distribution --id "$DIST_ID" --query Distribution.Status --output text))"
echo "  invalidation:  $INV_ID"
echo "  site:          http://$CF_DOMAIN      <- open with http://, not https://"
echo
echo "Next: re-run 07-deploy-services.sh so ALLOWED_ORIGIN = http://$CF_DOMAIN"
