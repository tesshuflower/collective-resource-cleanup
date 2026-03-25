#!/usr/bin/env bash
# AWS query functions for clusterpool-cleanup skills.

# List all AWS regions.
# Usage: get_aws_regions <profile>
# Prints one region name per line.
get_aws_regions() {
  local profile="$1"
  aws ec2 describe-regions --profile "$profile" --output json 2>/dev/null \
    | python3 -c "import sys,json; [print(r['RegionName']) for r in json.load(sys.stdin).get('Regions',[])]"
}

# Get all kubernetes.io/cluster/* tag keys in a region.
# Usage: get_cluster_tag_keys <profile> <region>
# Prints infra IDs (the part after kubernetes.io/cluster/) one per line.
get_cluster_tag_keys() {
  local profile="$1"
  local region="$2"
  aws resourcegroupstaggingapi get-tag-keys \
    --region "$region" --profile "$profile" --output json 2>/dev/null \
    | python3 -c "
import sys, json
keys = json.load(sys.stdin).get('TagKeys', [])
for k in keys:
    if k.startswith('kubernetes.io/cluster/'):
        print(k.replace('kubernetes.io/cluster/', '', 1))
"
}

# Check if an infra ID still has tagged AWS resources in a region.
# Usage: infra_id_has_ec2_resources <profile> <region> <infra_id>
# Returns: 0 if resources found, 1 if not
infra_id_has_ec2_resources() {
  local profile="$1"
  local region="$2"
  local infra_id="$3"
  local count
  count=$(aws resourcegroupstaggingapi get-resources \
    --region "$region" --profile "$profile" \
    --tag-filters "Key=kubernetes.io/cluster/${infra_id},Values=owned" \
    --output json 2>/dev/null \
    | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('ResourceTagMappingList', [])))")
  [[ "${count:-0}" -gt 0 ]]
}

# Get all tagged resource ARNs for an infra ID in a region.
# Usage: get_infra_resources <profile> <region> <infra_id>
# Prints JSON array of resource ARNs.
get_infra_resources() {
  local profile="$1"
  local region="$2"
  local infra_id="$3"
  aws resourcegroupstaggingapi get-resources \
    --region "$region" --profile "$profile" \
    --tag-filters "Key=kubernetes.io/cluster/${infra_id},Values=owned" \
    --output json 2>/dev/null \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
arns = [r['ResourceARN'] for r in data.get('ResourceTagMappingList', [])]
print(json.dumps(arns))
"
}

# List all S3 buckets matching a name prefix.
# Usage: list_s3_buckets_matching <profile> <prefix>
# Prints one bucket name per line.
list_s3_buckets_matching() {
  local profile="$1"
  local prefix="$2"
  aws s3 ls --profile "$profile" 2>/dev/null \
    | awk '{print $NF}' \
    | grep "^${prefix}"
}

# Get the velero.io/infrastructureName tag from a bucket.
# Usage: get_velero_bucket_infra_id <profile> <bucket>
# Prints infra ID to stdout, or empty string if not found.
get_velero_bucket_infra_id() {
  local profile="$1"
  local bucket="$2"
  aws s3api get-bucket-tagging --bucket "$bucket" --profile "$profile" 2>/dev/null \
    | python3 -c "
import sys, json
try:
    tags = {t['Key']: t['Value'] for t in json.load(sys.stdin).get('TagSet', [])}
    print(tags.get('velero.io/infrastructureName', ''))
except Exception:
    print('')
"
}

# Get bucket creation date from s3 ls output.
# Usage: get_bucket_creation_date <profile> <bucket>
# Prints date string (YYYY-MM-DD) or empty string.
get_bucket_creation_date() {
  local profile="$1"
  local bucket="$2"
  aws s3 ls --profile "$profile" 2>/dev/null \
    | awk -v b="$bucket" '$NF == b {print $1}'
}

# Check if a Route53 hosted zone exists for an infra ID.
# Usage: route53_zone_exists_for_infra <profile> <infra_id>
# Returns: 0 if zone found, 1 if not
route53_zone_exists_for_infra() {
  local profile="$1"
  local infra_id="$2"
  local found
  found=$(aws route53 list-hosted-zones --profile "$profile" --output json 2>/dev/null \
    | INFRA_ID="$infra_id" python3 -c "
import sys, json, os
infra_id = os.environ.get('INFRA_ID', '')
zones = json.load(sys.stdin).get('HostedZones', [])
found = any(infra_id in z.get('Name', '') for z in zones)
print('true' if found else 'false')
")
  [[ "$found" == "true" ]]
}

# List all S3 buckets (name only).
# Usage: list_all_s3_buckets <profile>
# Prints one bucket name per line.
list_all_s3_buckets() {
  local profile="$1"
  aws s3 ls --profile "$profile" 2>/dev/null \
    | awk '{print $NF}'
}
