# Amazon Route53 DNS API Provider
# Requires: AWS CLI configured with appropriate credentials
#

# Provider information
dns_route53_info() {
    echo "Amazon Route53 DNS API Provider"
    echo "Website: https://aws.amazon.com/route53/"
    echo "Documentation: https://docs.aws.amazon.com/route53/latest/developerguide/"
    echo ""
    echo "Required Dependencies:"
    echo "  aws-cli              - Amazon Web Services CLI"
    echo ""
    echo "Required AWS Configuration:"
    echo "  AWS_ACCESS_KEY_ID    - AWS Access Key ID"
    echo "  AWS_SECRET_ACCESS_KEY - AWS Secret Access Key"
    echo "  AWS_DEFAULT_REGION   - AWS Region (default: us-east-1)"
    echo "  OR use aws configure / IAM roles"
    echo ""
    echo "Required Permissions:"
    echo "  route53:ListHostedZones"
    echo "  route53:GetChange"
    echo "  route53:ChangeResourceRecordSets"
    echo ""
    echo "Optional Settings:"
    echo "  R53_TTL              - TTL for DNS records (default: 60)"
    echo "  R53_WAIT_TIME        - Wait time for propagation (default: 120)"
}

# Default settings
R53_TTL=${R53_TTL:-60}
R53_WAIT_TIME=${R53_WAIT_TIME:-120}

# Check if AWS CLI is available and configured
_r53_check_aws_cli() {
    if ! command -v aws >/dev/null 2>&1; then
        dns_log_error "AWS CLI not found. Please install aws-cli package."
        return 1
    fi
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
        dns_log_error "AWS credentials not configured. Run 'aws configure' or set AWS environment variables."
        return 1
    fi
    dns_log_debug "AWS CLI is configured and working"
    return 0
}

# Helper: Extract base domain from FQDN (e.g., sub.domain.example.com -> example.com)
r53_get_base_domain() {
    fqdn="$1"
    echo "$fqdn" | awk -F. '{if (NF>=2) print $(NF-1)"."$NF; else print $0}'
}

# Get hosted zone ID for domain
_r53_get_zone_id() {
    domain="$1"
    base_domain="$(r53_get_base_domain "$domain")"
    dns_log_debug "[R53] Looking up zone for base domain: $base_domain"
    # Try exact match first
    zone_id=$(aws route53 list-hosted-zones-by-name --dns-name "$base_domain" --query "HostedZones[?Name=='${base_domain}.'].Id" --output text 2>/dev/null | cut -d'/' -f3)
    if [ -n "$zone_id" ] && [ "$zone_id" != "None" ]; then
        dns_log_debug "[R53] Found zone_id: $zone_id for $base_domain"
        echo "$zone_id"
        return 0
    fi
    # Try parent domains
    parent_domain="$base_domain"
    while [ "$(echo "$parent_domain" | awk -F'.' '{print NF}')" -gt 2 ]; do
        parent_domain=$(echo "$parent_domain" | cut -d. -f2-)
        dns_log_debug "[R53] Trying parent domain: $parent_domain"
        zone_id=$(aws route53 list-hosted-zones-by-name --dns-name "$parent_domain" --query "HostedZones[?Name=='${parent_domain}.'].Id" --output text 2>/dev/null | cut -d'/' -f3)
        if [ -n "$zone_id" ] && [ "$zone_id" != "None" ]; then
            dns_log_debug "[R53] Found parent zone_id: $zone_id for $parent_domain"
            echo "$zone_id"
            return 0
        fi
    done
    dns_log_error "Could not find Route53 hosted zone for domain: $base_domain"
    return 1
}

# Wait for Route53 change to propagate
_r53_wait_for_change() {
    change_id="$1"
    max_wait="${2:-$R53_WAIT_TIME}"
    if [ -z "$change_id" ] || [ "$change_id" = "None" ]; then
        dns_log_debug "No change ID provided, skipping wait"
        return 0
    fi
    dns_log_info "Waiting for Route53 change to propagate (Change ID: $change_id)"
    waited=0
    check_interval=10
    while [ $waited -lt $max_wait ]; do
        status=$(aws route53 get-change --id "$change_id" --query "ChangeInfo.Status" --output text 2>/dev/null)
        if [ "$status" = "INSYNC" ]; then
            dns_log_info "Route53 change propagated successfully"
            return 0
        fi
        dns_log_debug "Change status: $status, waiting $check_interval seconds..."
        sleep $check_interval
        waited=$((waited + check_interval))
    done
    dns_log_warn "Route53 change did not complete within $max_wait seconds"
    return 1
}

# Create change batch JSON
_r53_create_change_batch() {
    action="$1"
    record_name="$2"
    txt_value="$3"
    ttl="$4"
    cat << EOF
{
    "Changes": [{
        "Action": "$action",
        "ResourceRecordSet": {
            "Name": "$record_name",
            "Type": "TXT",
            "TTL": $ttl,
            "ResourceRecords": [{"Value": "\"$txt_value\""}]
        }
    }]
}
EOF
}

# Add TXT record
dns_route53_add() {
    domain="$1"
    txt_value="$2"
    dns_log_debug "[R53] Starting dns_route53_add for $domain"
    _r53_check_aws_cli || return 1
    record_name="_acme-challenge.$domain"
    base_domain="$(r53_get_base_domain "$domain")"
    zone_id=$(_r53_get_zone_id "$base_domain")
    if [ -z "$zone_id" ]; then
        dns_log_error "[R53] No zone_id found for $base_domain"
        return 1
    fi
    dns_log_debug "[R53] Found Route53 zone ID: $zone_id"
    existing_value=$(aws route53 list-resource-record-sets --hosted-zone-id "$zone_id" --query "ResourceRecordSets[?Name=='${record_name}.'][ResourceRecords[0].Value]" --output text 2>/dev/null | sed 's/"//g')
    if [ "$existing_value" = "$txt_value" ]; then
        dns_log_info "TXT record already exists with correct value"
        echo "$zone_id" > "/tmp/acme_r53_zone_${domain}.id"
        return 0
    fi
    change_batch=$(_r53_create_change_batch "CREATE" "$record_name" "$txt_value" "$R53_TTL")
    change_id=$(aws route53 change-resource-record-sets --hosted-zone-id "$zone_id" --change-batch "$change_batch" --query "ChangeInfo.Id" --output text 2>/dev/null)
    if [ -n "$change_id" ] && [ "$change_id" != "None" ]; then
        dns_log_info "Created Route53 TXT record (Change ID: $change_id)"
        echo "$change_id" > "/tmp/acme_r53_change_${domain}.id"
        echo "$zone_id" > "/tmp/acme_r53_zone_${domain}.id"
        _r53_wait_for_change "$change_id"
        return 0
    else
        dns_log_error "Failed to create Route53 TXT record"
        return 1
    fi
}

# Remove TXT record
dns_route53_rm() {
    domain="$1"
    txt_value="$2"
    dns_log_debug "[R53] Starting dns_route53_rm for $domain"
    _r53_check_aws_cli || return 1
    record_name="_acme-challenge.$domain"
    zone_file="/tmp/acme_r53_zone_${domain}.id"
    change_file="/tmp/acme_r53_change_${domain}.id"
    zone_id=""
    if [ -f "$zone_file" ]; then
        zone_id=$(cat "$zone_file" 2>/dev/null)
    fi
    if [ -z "$zone_id" ]; then
        base_domain="$(r53_get_base_domain "$domain")"
        zone_id=$(_r53_get_zone_id "$base_domain")
        if [ -z "$zone_id" ]; then
            dns_log_warn "Could not find zone ID for cleanup"
            rm -f "$zone_file" "$change_file"
            return 0
        fi
    fi
    existing_value=""
    if [ -n "$txt_value" ]; then
        existing_value="$txt_value"
    else
        existing_value=$(aws route53 list-resource-record-sets --hosted-zone-id "$zone_id" --query "ResourceRecordSets[?Name=='${record_name}.'][ResourceRecords[0].Value]" --output text 2>/dev/null | sed 's/"//g')
    fi
    if [ -n "$existing_value" ]; then
        dns_log_debug "Deleting Route53 TXT record with value: $existing_value"
        change_batch=$(_r53_create_change_batch "DELETE" "$record_name" "$existing_value" "$R53_TTL")
        change_id=$(aws route53 change-resource-record-sets --hosted-zone-id "$zone_id" --change-batch "$change_batch" --query "ChangeInfo.Id" --output text 2>/dev/null)
        if [ -n "$change_id" ] && [ "$change_id" != "None" ]; then
            dns_log_info "Deleted Route53 TXT record (Change ID: $change_id)"
        else
            dns_log_warn "Failed to delete Route53 TXT record"
        fi
    else
        dns_log_warn "No TXT record found for deletion"
    fi
    rm -f "$zone_file" "$change_file"
    return 0
}

# Check if zone exists (override default implementation)
dns_zone_exists() {
    zone="$1"
    provider="$2"
    if [ "$provider" != "route53" ]; then
        return 1
    fi
    _r53_check_aws_cli || return 1
    base_domain="$(r53_get_base_domain "$zone")"
    zone_id=$(_r53_get_zone_id "$base_domain")
    [ -n "$zone_id" ]
}

# Get zone for domain (override default implementation)
dns_route53_get_zone() {
    domain="$1"
    _r53_check_aws_cli || return 1
    base_domain="$(r53_get_base_domain "$domain")"
    zone_name=$(aws route53 list-hosted-zones-by-name --dns-name "$base_domain" --query "HostedZones[?Name=='${base_domain}.'].Name" --output text 2>/dev/null | sed 's/\.$//')
    if [ -n "$zone_name" ] && [ "$zone_name" != "None" ]; then
        echo "$zone_name"
        return 0
    fi
    parent_domain="$base_domain"
    while [ "$(echo "$parent_domain" | awk -F'.' '{print NF}')" -gt 2 ]; do
        parent_domain=$(echo "$parent_domain" | cut -d. -f2-)
        zone_name=$(aws route53 list-hosted-zones-by-name --dns-name "$parent_domain" --query "HostedZones[?Name=='${parent_domain}.'].Name" --output text 2>/dev/null | sed 's/\.$//')
        if [ -n "$zone_name" ] && [ "$zone_name" != "None" ]; then
            echo "$zone_name"
            return 0
        fi
    done
    return 1
}
