#!/bin/sh
#
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

# Default settings
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

# Get domain for zone
_do_get_domain() {
    local domain="$1"

    # Try exact match first
    local domain_response=$(dns_http_get "$DO_API_BASE/domains/$domain" "$DO_AUTH_HEADER
Content-Type: application/json")

    local domain_name=$(dns_json_get "$domain_response" "domain.name")

    if [ -n "$domain_name" ] && [ "$domain_name" != "null" ]; then
        echo "$domain_name"
        return 0
    fi

    # Try parent domains
    local parent_domain="$domain"
    while [ "$(echo "$parent_domain" | tr '.' '\n' | wc -l)" -gt 2 ]; do
        parent_domain=$(echo "$parent_domain" | cut -d. -f2-)

        domain_response=$(dns_http_get "$DO_API_BASE/domains/$parent_domain" "$DO_AUTH_HEADER
Content-Type: application/json")

        domain_name=$(dns_json_get "$domain_response" "domain.name")

        if [ -n "$domain_name" ] && [ "$domain_name" != "null" ]; then
            echo "$domain_name"
            return 0
        fi
    done

    dns_log_error "Could not find DigitalOcean domain for: $domain"
    return 1
}

# Get existing TXT record ID
_do_get_txt_record_id() {
    local domain_name="$1"
    local record_name="$2"
    local txt_value="$3"

    local records_response=$(dns_http_get "$DO_API_BASE/domains/$domain_name/records?type=TXT&name=$record_name" "$DO_AUTH_HEADER
Content-Type: application/json")

    # Find record with matching data
    local i=0
    while true; do
        local record_id=$(dns_json_get "$records_response" "domain_records.$i.id")
        local record_data=$(dns_json_get "$records_response" "domain_records.$i.data")

        if [ -z "$record_id" ] || [ "$record_id" = "null" ]; then
            break
        fi

        if [ "$record_data" = "$txt_value" ]; then
            echo "$record_id"
            return 0
        fi

        i=$((i + 1))
    done

    return 1
}

# Add TXT record
dns_digitalocean_add() {
    local domain="$1"
    local txt_value="$2"

    _do_setup_auth || return 1

    local record_name="_acme-challenge"
    local domain_name

    # Get domain name
    domain_name=$(_do_get_domain "$domain")
    if [ -z "$domain_name" ]; then
        return 1
    fi

    dns_log_debug "Found DigitalOcean domain: $domain_name"

    # Calculate full record name relative to domain
    if [ "$domain" = "$domain_name" ]; then
        record_name="_acme-challenge"
    else
        # For subdomains, include the subdomain part
        local subdomain_part=$(echo "$domain" | sed "s/\.$domain_name$//" | sed "s/$domain_name$//")
        if [ -n "$subdomain_part" ]; then
            record_name="_acme-challenge.$subdomain_part"
        else
            record_name="_acme-challenge"
        fi
    fi

    # Check if record already exists
    local existing_record_id
    existing_record_id=$(_do_get_txt_record_id "$domain_name" "$record_name" "$txt_value")

    if [ -n "$existing_record_id" ]; then
        dns_log_info "TXT record already exists with ID: $existing_record_id"
        echo "$existing_record_id" > "/tmp/acme_do_record_${domain}.id"
        echo "$domain_name" > "/tmp/acme_do_domain_${domain}.name"
        return 0
    fi

    # Create new TXT record
    local record_data="{
        \"type\": \"TXT\",
        \"name\": \"$record_name\",
        \"data\": \"$txt_value\",
        \"ttl\": $DO_TTL
    }"

    local create_response=$(dns_http_post "$DO_API_BASE/domains/$domain_name/records" "$record_data" "$DO_AUTH_HEADER
Content-Type: application/json")

    local record_id=$(dns_json_get "$create_response" "domain_record.id")

    if [ -n "$record_id" ] && [ "$record_id" != "null" ]; then
        dns_log_info "Created DigitalOcean TXT record: $record_id"
        echo "$record_id" > "/tmp/acme_do_record_${domain}.id"
        echo "$domain_name" > "/tmp/acme_do_domain_${domain}.name"
        return 0
    else
        local error_msg=$(dns_json_get "$create_response" "message")
        dns_log_error "Failed to create DigitalOcean TXT record: $error_msg"
        return 1
    fi
}

# Remove TXT record
dns_digitalocean_rm() {
    local domain="$1"
    local txt_value="$2"

    _do_setup_auth || return 1

    local record_file="/tmp/acme_do_record_${domain}.id"
    local domain_file="/tmp/acme_do_domain_${domain}.name"

    # Try to get record ID and domain name from files first
    local record_id=""
    local domain_name=""

    if [ -f "$record_file" ]; then
        record_id=$(cat "$record_file" 2>/dev/null)
    fi

    if [ -f "$domain_file" ]; then
        domain_name=$(cat "$domain_file" 2>/dev/null)
    fi

    # If we don't have the domain name, try to find it
    if [ -z "$domain_name" ]; then
        domain_name=$(_do_get_domain "$domain")
        if [ -z "$domain_name" ]; then
            dns_log_warn "Could not find domain for cleanup"
            rm -f "$record_file" "$domain_file"
            return 0
        fi
    fi

    # If we don't have the record ID, try to find it
    if [ -z "$record_id" ] && [ -n "$txt_value" ]; then
        local record_name="_acme-challenge"

        # Calculate full record name relative to domain
        if [ "$domain" != "$domain_name" ]; then
            local subdomain_part=$(echo "$domain" | sed "s/\.$domain_name$//" | sed "s/$domain_name$//")
            if [ -n "$subdomain_part" ]; then
                record_name="_acme-challenge.$subdomain_part"
            fi
        fi

        record_id=$(_do_get_txt_record_id "$domain_name" "$record_name" "$txt_value")
    fi

    if [ -n "$record_id" ] && [ "$record_id" != "null" ]; then
        dns_log_debug "Deleting DigitalOcean record ID: $record_id"

        local delete_response=$(dns_http_delete "$DO_API_BASE/domains/$domain_name/records/$record_id" "$DO_AUTH_HEADER
Content-Type: application/json")

        # DigitalOcean returns empty response on successful deletion
        dns_log_info "Deleted DigitalOcean TXT record"
    else
        dns_log_warn "No record ID found for cleanup (record may have already been deleted)"
    fi

    # Clean up temporary files
    rm -f "$record_file" "$domain_file"
    return 0
}

# Check if zone exists (override default implementation)
dns_zone_exists() {
    local zone="$1"
    local provider="$2"

    if [ "$provider" != "digitalocean" ]; then
        return 1
    fi

    _do_setup_auth || return 1

    local domain_name
    domain_name=$(_do_get_domain "$zone")

    [ -n "$domain_name" ]
}

# Get zone for domain (override default implementation)
dns_digitalocean_get_zone() {
    local domain="$1"

    _do_setup_auth || return 1
    _do_get_domain "$domain"
}
