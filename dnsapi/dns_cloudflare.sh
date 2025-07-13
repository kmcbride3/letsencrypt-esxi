#!/bin/sh
#
# Cloudflare DNS API Provider
# Requires: CF_API_TOKEN or CF_API_KEY + CF_EMAIL
#

# Provider information
dns_cloudflare_info() {
    echo "Cloudflare DNS API Provider"
    echo "Website: https://cloudflare.com"
    echo "Documentation: https://developers.cloudflare.com/api/operations/dns-records-for-a-zone-create-dns-record"
    echo ""
    echo "Required Environment Variables:"
    echo "  CF_API_TOKEN     - Cloudflare API Token (recommended)"
    echo "  OR"
    echo "  CF_API_KEY       - Cloudflare Global API Key"
    echo "  CF_EMAIL         - Cloudflare account email"
    echo ""
    echo "Optional Settings:"
    echo "  CF_TTL           - TTL for DNS records (default: 120)"
    echo "  CF_PROXY         - Enable Cloudflare proxy (default: false)"
}

# Cloudflare API endpoints
CF_API_BASE="https://api.cloudflare.com/client/v4"

# Default settings
CF_TTL=${CF_TTL:-120}
CF_PROXY=${CF_PROXY:-false}

# Authentication setup
_cf_setup_auth() {
    if [ -n "$CF_API_TOKEN" ]; then
        dns_log_debug "Using Cloudflare API Token authentication"
        CF_AUTH_HEADER="Authorization: Bearer $CF_API_TOKEN"
        return 0
    elif [ -n "$CF_API_KEY" ] && [ -n "$CF_EMAIL" ]; then
        dns_log_debug "Using Cloudflare Global API Key authentication"
        CF_AUTH_HEADER="X-Auth-Key: $CF_API_KEY"
        CF_EMAIL_HEADER="X-Auth-Email: $CF_EMAIL"
        return 0
    else
        dns_log_error "Cloudflare credentials not found. Please set CF_API_TOKEN or (CF_API_KEY + CF_EMAIL)"
        return 1
    fi
}

# Get zone ID for domain
_cf_get_zone_id() {
    local domain="$1"

    # Try exact match first
    local zone_response
    if [ -n "$CF_EMAIL_HEADER" ]; then
        zone_response=$(dns_http_get "$CF_API_BASE/zones?name=$domain" "$CF_AUTH_HEADER
$CF_EMAIL_HEADER
Content-Type: application/json")
    else
        zone_response=$(dns_http_get "$CF_API_BASE/zones?name=$domain" "$CF_AUTH_HEADER
Content-Type: application/json")
    fi

    local zone_id=$(dns_json_get "$zone_response" "result.0.id")

    if [ -n "$zone_id" ] && [ "$zone_id" != "null" ]; then
        echo "$zone_id"
        return 0
    fi

    # Try parent domains
    local parent_domain="$domain"
    while [ "$(echo "$parent_domain" | tr '.' '\n' | wc -l)" -gt 2 ]; do
        parent_domain=$(echo "$parent_domain" | cut -d. -f2-)

        if [ -n "$CF_EMAIL_HEADER" ]; then
            zone_response=$(dns_http_get "$CF_API_BASE/zones?name=$parent_domain" "$CF_AUTH_HEADER
$CF_EMAIL_HEADER
Content-Type: application/json")
        else
            zone_response=$(dns_http_get "$CF_API_BASE/zones?name=$parent_domain" "$CF_AUTH_HEADER
Content-Type: application/json")
        fi

        zone_id=$(dns_json_get "$zone_response" "result.0.id")

        if [ -n "$zone_id" ] && [ "$zone_id" != "null" ]; then
            echo "$zone_id"
            return 0
        fi
    done

    dns_log_error "Could not find Cloudflare zone for domain: $domain"
    return 1
}

# Get existing TXT record ID
_cf_get_txt_record_id() {
    local zone_id="$1"
    local record_name="$2"
    local txt_value="$3"

    local records_response
    if [ -n "$CF_EMAIL_HEADER" ]; then
        records_response=$(dns_http_get "$CF_API_BASE/zones/$zone_id/dns_records?type=TXT&name=$record_name" "$CF_AUTH_HEADER
$CF_EMAIL_HEADER
Content-Type: application/json")
    else
        records_response=$(dns_http_get "$CF_API_BASE/zones/$zone_id/dns_records?type=TXT&name=$record_name" "$CF_AUTH_HEADER
Content-Type: application/json")
    fi

    # Find record with matching content
    local i=0
    while true; do
        local record_id=$(dns_json_get "$records_response" "result.$i.id")
        local record_content=$(dns_json_get "$records_response" "result.$i.content")

        if [ -z "$record_id" ] || [ "$record_id" = "null" ]; then
            break
        fi

        if [ "$record_content" = "$txt_value" ]; then
            echo "$record_id"
            return 0
        fi

        i=$((i + 1))
    done

    return 1
}

# Add TXT record
dns_cloudflare_add() {
    local domain="$1"
    local txt_value="$2"

    _cf_setup_auth || return 1

    local record_name="_acme-challenge.$domain"
    local zone_id

    # Get zone ID
    zone_id=$(_cf_get_zone_id "$domain")
    if [ -z "$zone_id" ]; then
        return 1
    fi

    dns_log_debug "Found Cloudflare zone ID: $zone_id"

    # Check if record already exists
    local existing_record_id
    existing_record_id=$(_cf_get_txt_record_id "$zone_id" "$record_name" "$txt_value")

    if [ -n "$existing_record_id" ]; then
        dns_log_info "TXT record already exists with ID: $existing_record_id"
        echo "$existing_record_id" > "/tmp/acme_cf_record_${domain}.id"
        return 0
    fi

    # Create new TXT record
    local record_data="{
        \"type\": \"TXT\",
        \"name\": \"$record_name\",
        \"content\": \"$txt_value\",
        \"ttl\": $CF_TTL,
        \"proxied\": $CF_PROXY
    }"

    local create_response
    if [ -n "$CF_EMAIL_HEADER" ]; then
        create_response=$(dns_http_post "$CF_API_BASE/zones/$zone_id/dns_records" "$record_data" "$CF_AUTH_HEADER
$CF_EMAIL_HEADER
Content-Type: application/json")
    else
        create_response=$(dns_http_post "$CF_API_BASE/zones/$zone_id/dns_records" "$record_data" "$CF_AUTH_HEADER
Content-Type: application/json")
    fi

    local record_id=$(dns_json_get "$create_response" "result.id")
    local success=$(dns_json_get "$create_response" "success")

    if [ "$success" = "true" ] && [ -n "$record_id" ]; then
        dns_log_info "Created Cloudflare TXT record: $record_id"
        echo "$record_id" > "/tmp/acme_cf_record_${domain}.id"
        echo "$zone_id" > "/tmp/acme_cf_zone_${domain}.id"
        return 0
    else
        local error_msg=$(dns_json_get "$create_response" "errors.0.message")
        dns_log_error "Failed to create Cloudflare TXT record: $error_msg"
        return 1
    fi
}

# Remove TXT record
dns_cloudflare_rm() {
    local domain="$1"
    local txt_value="$2"

    _cf_setup_auth || return 1

    local record_file="/tmp/acme_cf_record_${domain}.id"
    local zone_file="/tmp/acme_cf_zone_${domain}.id"

    # Try to get record ID from file first
    local record_id=""
    local zone_id=""

    if [ -f "$record_file" ]; then
        record_id=$(cat "$record_file" 2>/dev/null)
    fi

    if [ -f "$zone_file" ]; then
        zone_id=$(cat "$zone_file" 2>/dev/null)
    fi

    # If we don't have the IDs, try to find them
    if [ -z "$zone_id" ]; then
        zone_id=$(_cf_get_zone_id "$domain")
        if [ -z "$zone_id" ]; then
            dns_log_warn "Could not find zone ID for cleanup"
            rm -f "$record_file" "$zone_file"
            return 0
        fi
    fi

    if [ -z "$record_id" ] && [ -n "$txt_value" ]; then
        record_id=$(_cf_get_txt_record_id "$zone_id" "_acme-challenge.$domain" "$txt_value")
    fi

    if [ -n "$record_id" ] && [ "$record_id" != "null" ]; then
        dns_log_debug "Deleting Cloudflare record ID: $record_id"

        local delete_response
        if [ -n "$CF_EMAIL_HEADER" ]; then
            delete_response=$(dns_http_delete "$CF_API_BASE/zones/$zone_id/dns_records/$record_id" "$CF_AUTH_HEADER
$CF_EMAIL_HEADER
Content-Type: application/json")
        else
            delete_response=$(dns_http_delete "$CF_API_BASE/zones/$zone_id/dns_records/$record_id" "$CF_AUTH_HEADER
Content-Type: application/json")
        fi

        local success=$(dns_json_get "$delete_response" "success")

        if [ "$success" = "true" ]; then
            dns_log_info "Deleted Cloudflare TXT record"
        else
            local error_msg=$(dns_json_get "$delete_response" "errors.0.message")
            dns_log_warn "Failed to delete Cloudflare TXT record: $error_msg"
        fi
    else
        dns_log_warn "No record ID found for cleanup (record may have already been deleted)"
    fi

    # Clean up temporary files
    rm -f "$record_file" "$zone_file"
    return 0
}

# Check if zone exists (override default implementation)
dns_zone_exists() {
    local zone="$1"
    local provider="$2"

    if [ "$provider" != "cloudflare" ]; then
        return 1
    fi

    _cf_setup_auth || return 1

    local zone_id
    zone_id=$(_cf_get_zone_id "$zone")

    [ -n "$zone_id" ]
}

# Get zone for domain (override default implementation)
dns_cloudflare_get_zone() {
    local domain="$1"

    _cf_setup_auth || return 1

    # Try exact match first
    local zone_response
    if [ -n "$CF_EMAIL_HEADER" ]; then
        zone_response=$(dns_http_get "$CF_API_BASE/zones?name=$domain" "$CF_AUTH_HEADER
$CF_EMAIL_HEADER
Content-Type: application/json")
    else
        zone_response=$(dns_http_get "$CF_API_BASE/zones?name=$domain" "$CF_AUTH_HEADER
Content-Type: application/json")
    fi

    local zone_name=$(dns_json_get "$zone_response" "result.0.name")

    if [ -n "$zone_name" ] && [ "$zone_name" != "null" ]; then
        echo "$zone_name"
        return 0
    fi

    # Try parent domains
    local parent_domain="$domain"
    while [ "$(echo "$parent_domain" | tr '.' '\n' | wc -l)" -gt 2 ]; do
        parent_domain=$(echo "$parent_domain" | cut -d. -f2-)

        if [ -n "$CF_EMAIL_HEADER" ]; then
            zone_response=$(dns_http_get "$CF_API_BASE/zones?name=$parent_domain" "$CF_AUTH_HEADER
$CF_EMAIL_HEADER
Content-Type: application/json")
        else
            zone_response=$(dns_http_get "$CF_API_BASE/zones?name=$parent_domain" "$CF_AUTH_HEADER
Content-Type: application/json")
        fi

        zone_name=$(dns_json_get "$zone_response" "result.0.name")

        if [ -n "$zone_name" ] && [ "$zone_name" != "null" ]; then
            echo "$zone_name"
            return 0
        fi
    done

    return 1
}
