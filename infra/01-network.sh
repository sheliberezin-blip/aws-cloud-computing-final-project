#!/usr/bin/env bash
# Stage 1 — Network: VPC, 2 public + 2 private subnets (2 AZs), IGW, NAT, route tables.
# Safe to run more than once: every resource is looked up by its Name tag first and
# only created if it doesn't exist yet. All IDs are written to ~/fp.env for later stages.
set -euo pipefail

export AWS_REGION=eu-north-1
ENV_FILE=~/fp.env

# Returns the ID of the single resource with this Name tag, "" if none, fails if more than one.
find_one() {
  local ids
  ids=$("$@" --output text)
  [ "$ids" = "None" ] && ids=""
  if [ "$(wc -w <<<"$ids")" -gt 1 ]; then
    echo "ERROR: more than one resource found: $ids — clean up duplicates first" >&2
    exit 1
  fi
  echo "$ids"
}

tags() { echo "ResourceType=$1,Tags=[{Key=Name,Value=$2}]"; }

# --- VPC ---
VPC_ID=$(find_one aws ec2 describe-vpcs --filters Name=tag:Name,Values=final-project-vpc --query 'Vpcs[].VpcId')
if [ -z "$VPC_ID" ]; then
  VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 \
    --tag-specifications "$(tags vpc final-project-vpc)" --query Vpc.VpcId --output text)
  echo "created VPC $VPC_ID"
fi
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames

# --- Subnets ---
subnet() { # name cidr az
  local id
  id=$(find_one aws ec2 describe-subnets \
    --filters Name=vpc-id,Values="$VPC_ID" Name=tag:Name,Values="$1" --query 'Subnets[].SubnetId')
  if [ -z "$id" ]; then
    id=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$2" --availability-zone "$3" \
      --tag-specifications "$(tags subnet "$1")" --query Subnet.SubnetId --output text)
    echo "created subnet $1 $id" >&2
  fi
  echo "$id"
}
PUB_A=$(subnet final-project-public-1 10.0.1.0/24  eu-north-1a)
PUB_B=$(subnet final-project-public-2 10.0.2.0/24  eu-north-1b)
PRIV_A=$(subnet final-project-private-1 10.0.11.0/24 eu-north-1a)
PRIV_B=$(subnet final-project-private-2 10.0.12.0/24 eu-north-1b)

# --- Internet Gateway ---
IGW_ID=$(find_one aws ec2 describe-internet-gateways \
  --filters Name=attachment.vpc-id,Values="$VPC_ID" --query 'InternetGateways[].InternetGatewayId')
if [ -z "$IGW_ID" ]; then
  IGW_ID=$(aws ec2 create-internet-gateway --tag-specifications "$(tags internet-gateway final-project-igw)" \
    --query InternetGateway.InternetGatewayId --output text)
  aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
  echo "created IGW $IGW_ID"
fi

# --- Route tables ---
route_table() { # name
  local id
  id=$(find_one aws ec2 describe-route-tables \
    --filters Name=vpc-id,Values="$VPC_ID" Name=tag:Name,Values="$1" --query 'RouteTables[].RouteTableId')
  if [ -z "$id" ]; then
    id=$(aws ec2 create-route-table --vpc-id "$VPC_ID" --tag-specifications "$(tags route-table "$1")" \
      --query RouteTable.RouteTableId --output text)
    echo "created route table $1 $id" >&2
  fi
  echo "$id"
}
associate() { # rt subnet — skipped if the subnet is already on this table
  local current
  current=$(aws ec2 describe-route-tables --route-table-ids "$1" \
    --query "RouteTables[].Associations[?SubnetId=='$2'].SubnetId" --output text)
  [ -n "$current" ] || aws ec2 associate-route-table --route-table-id "$1" --subnet-id "$2" >/dev/null
}

PUB_RT=$(route_table final-project-public-rt)
aws ec2 replace-route --route-table-id "$PUB_RT" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" 2>/dev/null \
  || aws ec2 create-route --route-table-id "$PUB_RT" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null
associate "$PUB_RT" "$PUB_A"
associate "$PUB_RT" "$PUB_B"

# --- NAT Gateway (costs money every hour it exists) ---
NAT_ID=$(find_one aws ec2 describe-nat-gateways \
  --filter Name=vpc-id,Values="$VPC_ID" Name=state,Values=pending,available --query 'NatGateways[].NatGatewayId')
if [ -z "$NAT_ID" ]; then
  EIP_ALLOC=$(aws ec2 allocate-address --domain vpc --query AllocationId --output text)
  NAT_ID=$(aws ec2 create-nat-gateway --subnet-id "$PUB_A" --allocation-id "$EIP_ALLOC" \
    --tag-specifications "$(tags natgateway final-project-nat)" --query NatGateway.NatGatewayId --output text)
  echo "created NAT $NAT_ID — waiting for it to become available (1-2 min)..."
fi
aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT_ID"
EIP_ALLOC=$(aws ec2 describe-nat-gateways --nat-gateway-ids "$NAT_ID" \
  --query 'NatGateways[0].NatGatewayAddresses[0].AllocationId' --output text)

PRIV_RT=$(route_table final-project-private-rt)
aws ec2 replace-route --route-table-id "$PRIV_RT" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_ID" 2>/dev/null \
  || aws ec2 create-route --route-table-id "$PRIV_RT" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_ID" >/dev/null
associate "$PRIV_RT" "$PRIV_A"
associate "$PRIV_RT" "$PRIV_B"

# --- Save IDs for the next stages ---
cat > "$ENV_FILE" <<EOF
export AWS_REGION=$AWS_REGION
export VPC_ID=$VPC_ID
export PUB_A=$PUB_A
export PUB_B=$PUB_B
export PRIV_A=$PRIV_A
export PRIV_B=$PRIV_B
export IGW_ID=$IGW_ID
export NAT_ID=$NAT_ID
export EIP_ALLOC=$EIP_ALLOC
export PUB_RT=$PUB_RT
export PRIV_RT=$PRIV_RT
EOF

echo
echo "Stage 1 done. Saved to $ENV_FILE:"
cat "$ENV_FILE"
