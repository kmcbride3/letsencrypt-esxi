# DigitalOcean DNS API Provider
# Requires: DO_API_TOKEN
#

# Provider information
dns_digitalocean_info() {
    echo "DigitalOcean DNS API Provider"
    echo "Website: https://digitalocean.com"
    echo "Documentation: https://docs.digitalocean.com/reference/api/api-reference/#tag/Domains"
    echo ""
    echo "Required Environment Variables:"
    echo "  DO_API_TOKEN         - DigitalOcean API Token"
    echo ""
    echo "Optional Settings:"
    echo "  DO_TTL               - TTL for DNS records (default: 120)"
}

# DigitalOcean API endpoint
DO_API_BASE="https://api.digitalocean.com/v2"
DO_TTL=${DO_TTL:-120}

# Authentication setup
_do_setup_auth() {
    if [ -z "$DO_API_TOKEN" ]; then
        dns_log_error "DigitalOcean API token not found. Please set DO_API_TOKEN"
        return 1
    fi
    dns_log_debug "Using DigitalOcean API Token authentication"
    DO_AUTH_HEADER="Authorization: Bearer $DO_API_TOKEN"
    return 0
}

# Helper: Extract base domain from FQDN (e.g., sub.domain.example.com -> example.com)
do_get_base_domain() {
    fqdn="$1"
    echo "$fqdn" | awk -F. '{if (NF>=2) print $(NF-1)"."$NF; else print $0}'
}

# Get domain for zone
do_get_domain() {
    domain="$1"
    base_domain="$(do_get_base_domain "$domain")"
    headers="$DO_AUTH_HEADER\nContent-Type: application/json"
    dns_log_debug "[DO] Looking up domain for base domain: $base_domain"
    domain_response=$(dns_http_get "$DO_API_BASE/domains/$base_domain" "$headers")
    domain_name=$(echo "$domain_response" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')
    if [ -n "$domain_name" ]; then
        dns_log_debug "[DO] Found domain_name: $domain_name for $base_domain"
        echo "$domain_name"
        return 0
    fi
    # Try parent domains
    parent_domain="$base_domain"
    while [ "$(echo "$parent_domain" | awk -F'.' '{print NF}')" -gt 2 ]; do
        parent_domain=$(echo "$parent_domain" | sed 's/^[^.]*\.//')
        dns_log_debug "[DO] Trying parent domain: $parent_domain"
        domain_response=$(dns_http_get "$DO_API_BASE/domains/$parent_domain" "$headers")
        domain_name=$(echo "$domain_response" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')
        if [ -n "$domain_name" ]; then
            dns_log_debug "[DO] Found parent domain_name: $domain_name for $parent_domain"
            echo "$domain_name"
            return 0
        fi
    done
    dns_log_error "Could not find DigitalOcean domain for: $base_domain"
    return 1
}

# Get existing TXT record ID
do_get_txt_record_id() {
    domain_name="$1"
    record_name="$2"
    txt_value="$3"
    headers="$DO_AUTH_HEADER\nContent-Type: application/json"
    records_response=$(dns_http_get "$DO_API_BASE/domains/$domain_name/records?type=TXT&name=$record_name" "$headers")
    i=0
    while :; do
        record_id=$(echo "$records_response" | sed -n "s/.*'id':\([0-9]*\).*/\1/p" | sed -n "$((i+1))p")
        record_data=$(echo "$records_response" | sed -n 's/.*"data":"\([^"]*\)".*/\1/p' | sed -n "$((i+1))p")
        if [ -z "$record_id" ]; then
            break
        fi
        if [ "$record_data" = "$txt_value" ]; then
            dns_log_debug "[DO] Found matching TXT record id: $record_id"
            echo "$record_id"
            return 0
        fi
        i=$((i + 1))
        if [ $i -ge 20 ]; then
            dns_log_warn "[DO] TXT record search exceeded 20 iterations, possible malformed API response."
            break
        fi
    done
    return 1
}

# Add TXT record
dns_digitalocean_add() {
    domain="$1"
    txt_value="$2"
    dns_log_debug "[DO] Starting dns_digitalocean_add for $domain"
    _do_setup_auth || return 1
    base_domain="$(do_get_base_domain "$domain")"
    domain_name=$(do_get_domain "$domain")
    if [ -z "$domain_name" ]; then
        dns_log_error "[DO] No domain_name found for $base_domain"
        return 1
    fi
    dns_log_debug "[DO] Found DigitalOcean domain: $domain_name"
    # Calculate full record name relative to domain
    if [ "$domain" = "$domain_name" ]; then
        record_name="_acme-challenge"
    else
        subdomain_part=$(echo "$domain" | sed "s/\.$domain_name$//" | sed "s/$domain_name$//")
        if [ -n "$subdomain_part" ]; then
            record_name="_acme-challenge.$subdomain_part"
        else
            record_name="_acme-challenge"
        fi
    fi
    existing_record_id=$(do_get_txt_record_id "$domain_name" "$record_name" "$txt_value")
    if [ -n "$existing_record_id" ]; then
        dns_log_info "TXT record already exists with ID: $existing_record_id"
        echo "$existing_record_id" > "/tmp/acme_do_record_${domain}.id"
        echo "$domain_name" > "/tmp/acme_do_domain_${domain}.name"
        return 0
    fi
    record_data="{\"type\":\"TXT\",\"name\":\"$record_name\",\"data\":\"$txt_value\",\"ttl\":$DO_TTL}"
    headers="$DO_AUTH_HEADER\nContent-Type: application/json"
    create_response=$(dns_http_post "$DO_API_BASE/domains/$domain_name/records" "$record_data" "$headers")
    record_id=$(echo "$create_response" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
    if [ -n "$record_id" ]; then
        dns_log_info "Created DigitalOcean TXT record: $record_id"
        echo "$record_id" > "/tmp/acme_do_record_${domain}.id"
        echo "$domain_name" > "/tmp/acme_do_domain_${domain}.name"
        return 0
    else
        error_msg=$(echo "$create_response" | sed -n 's/.*"message":"\([^"]*\)".*/\1/p')
        dns_log_error "Failed to create DigitalOcean TXT record: $error_msg"
        return 1
    fi
}

# Remove TXT record
dns_digitalocean_rm() {
    domain="$1"
    txt_value="$2"
    dns_log_debug "[DO] Starting dns_digitalocean_rm for $domain"
    _do_setup_auth || return 1
    record_file="/tmp/acme_do_record_${domain}.id"
    domain_file="/tmp/acme_do_domain_${domain}.name"
    record_id=""
    domain_name=""
    if [ -f "$record_file" ]; then
        record_id=$(cat "$record_file" 2>/dev/null)
    fi
    if [ -f "$domain_file" ]; then
        domain_name=$(cat "$domain_file" 2>/dev/null)
    fi
    if [ -z "$domain_name" ]; then
        domain_name=$(do_get_domain "$domain")
        if [ -z "$domain_name" ]; then
            dns_log_warn "Could not find domain for cleanup"
            rm -f "$record_file" "$domain_file"
            return 0
        fi
    fi
    if [ -z "$record_id" ] && [ -n "$txt_value" ]; then
        if [ "$domain" = "$domain_name" ]; then
            record_name="_acme-challenge"
        else
            subdomain_part=$(echo "$domain" | sed "s/\.$domain_name$//" | sed "s/$domain_name$//")
            if [ -n "$subdomain_part" ]; then
                record_name="_acme-challenge.$subdomain_part"
            else
                record_name="_acme-challenge"
            fi
        fi
        record_id=$(do_get_txt_record_id "$domain_name" "$record_name" "$txt_value")
    fi
    if [ -n "$record_id" ]; then
        dns_log_debug "Deleting DigitalOcean record ID: $record_id"
        headers="$DO_AUTH_HEADER\nContent-Type: application/json"
        delete_response=$(dns_http_delete "$DO_API_BASE/domains/$domain_name/records/$record_id" "$headers")
        dns_log_info "Deleted DigitalOcean TXT record"
    else
        dns_log_warn "No record ID found for cleanup (record may have already been deleted)"
    fi
    rm -f "$record_file" "$domain_file"
    return 0
}

# Check if zone exists (override default implementation)
dns_zone_exists() {
    zone="$1"
    provider="$2"
    if [ "$provider" != "digitalocean" ]; then
        return 1
    fi
    _do_setup_auth || return 1
    domain_name=$(do_get_domain "$zone")
    [ -n "$domain_name" ]
}

# Get zone for domain (override default implementation)
dns_digitalocean_get_zone() {
    domain="$1"
    _do_setup_auth || return 1
    do_get_domain "$domain"
}
