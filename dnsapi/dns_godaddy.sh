#!/bin/sh
#
# GoDaddy DNS API Provider
# Requires: GD_Key, GD_Secret
#

# Provider information
dns_godaddy_info() {
    echo "GoDaddy DNS API Provider"
    echo "Website: https://godaddy.com"
    echo "Documentation: https://developer.godaddy.com/doc/endpoint/domains"
    echo ""
    echo "Required Environment Variables:"
    echo "  GD_Key          - GoDaddy API Key"
    echo "  GD_Secret       - GoDaddy API Secret"
    echo ""
    echo "Optional Settings:"
    echo "  GD_TTL          - TTL for DNS records (default: 600)"
    echo ""
    echo "Note: GoDaddy API access requires 10+ domains or Discount Domain Club"
    echo "      subscription. Recommended dnssleep is 600 seconds."
}

# GoDaddy API endpoints
GD_API_BASE="https://api.godaddy.com/v1"

# Default settings
GD_TTL=${GD_TTL:-600}

# Authentication setup
_gd_setup_auth() {
    if [ -z "$GD_Key" ]; then
        dns_log_error "GD_Key not set"
        return 1
    fi

    if [ -z "$GD_Secret" ]; then
        dns_log_error "GD_Secret not set"
        return 1
    fi

    GD_AUTH_HEADER="Authorization: sso-key ${GD_Key}:${GD_Secret}"
    return 0
}

# Extract domain from subdomain
_gd_get_domain() {
    local full_domain="$1"

    # Try to find the registrable domain
    # Start with the full domain and work backwards
    local test_domain="$full_domain"

    while [ "$(echo "$test_domain" | awk -F'.' '{print NF}')" -gt 1 ]; do
        # Test if this is a valid domain by checking with GoDaddy API
        local response=$(dns_http_get "$GD_API_BASE/domains/$test_domain" "$GD_AUTH_HEADER
Content-Type: application/json" 2>/dev/null)

        if [ $? -eq 0 ] && echo "$response" | grep -q '"domain"'; then
            echo "$test_domain"
            return 0
        fi

        # Remove the leftmost subdomain and try again
        test_domain=$(echo "$test_domain" | cut -d. -f2-)
    done

    dns_log_error "Could not find GoDaddy domain for: $full_domain"
    return 1
}

# Get record name from full domain
_gd_get_record_name() {
    local full_domain="$1"
    local domain="$2"

    if [ "$full_domain" = "$domain" ]; then
        echo "@"
    else
        echo "$full_domain" | sed "s/\\.${domain}$//"
    fi
}

# Get existing TXT records
_gd_get_txt_records() {
    local domain="$1"
    local record_name="$2"

    local response=$(dns_http_get "$GD_API_BASE/domains/$domain/records/TXT/$record_name" "$GD_AUTH_HEADER
Content-Type: application/json")

    if [ $? -ne 0 ]; then
        dns_log_debug "No existing TXT records found for $record_name.$domain"
        echo "[]"
        return 0
    fi

    echo "$response"
}

# Add TXT record
dns_godaddy_add() {
    local full_domain="$1"
    local txt_value="$2"

    dns_log_info "Adding TXT record for $full_domain"

    if ! _gd_setup_auth; then
        return 1
    fi

    # Get the registrable domain
    local domain=$(_gd_get_domain "$full_domain")
    if [ $? -ne 0 ]; then
        return 1
    fi

    # Get the record name
    local record_name=$(_gd_get_record_name "$full_domain" "$domain")

    dns_log_debug "Domain: $domain, Record: $record_name"

    # Get existing TXT records
    local existing_records=$(_gd_get_txt_records "$domain" "$record_name")

    # Build new record set including existing records
    local new_records="["
    local first_record=true

    # Add existing records (if any)
    if [ "$existing_records" != "[]" ] && [ -n "$existing_records" ]; then
        # Parse existing records and add them to the new set
        # This is a simplified JSON parser for ESXi compatibility
        local temp_file="/tmp/gd_records_$$"
        echo "$existing_records" | awk -F',' '{for(i=1;i<=NF;i++) print $i}' | grep '"data"' > "$temp_file" 2>/dev/null || true

        while read -r line; do
            if [ -n "$line" ]; then
                local existing_value=$(echo "$line" | sed -n 's/.*"data"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p')
                if [ -n "$existing_value" ] && [ "$existing_value" != "$txt_value" ]; then
                    if [ "$first_record" = "false" ]; then
                        new_records="${new_records},"
                    fi
                    new_records="${new_records}{\"data\":\"${existing_value}\",\"ttl\":${GD_TTL}}"
                    first_record=false
                fi
            fi
        done < "$temp_file"
        rm -f "$temp_file" 2>/dev/null || true
    fi

    # Add the new TXT record
    if [ "$first_record" = "false" ]; then
        new_records="${new_records},"
    fi
    new_records="${new_records}{\"data\":\"${txt_value}\",\"ttl\":${GD_TTL}}"
    new_records="${new_records}]"

    # Send the update request
    local response=$(dns_http_request "PUT" "$GD_API_BASE/domains/$domain/records/TXT/$record_name" "$new_records" "$GD_AUTH_HEADER
Content-Type: application/json")

    if [ $? -eq 0 ]; then
        dns_log_info "Successfully added TXT record for $full_domain"
        return 0
    else
        dns_log_error "Failed to add TXT record for $full_domain"
        return 1
    fi
}

# Remove TXT record
dns_godaddy_rm() {
    local full_domain="$1"
    local txt_value="$2"

    dns_log_info "Removing TXT record for $full_domain"

    if ! _gd_setup_auth; then
        return 1
    fi

    # Get the registrable domain
    local domain=$(_gd_get_domain "$full_domain")
    if [ $? -ne 0 ]; then
        return 1
    fi

    # Get the record name
    local record_name=$(_gd_get_record_name "$full_domain" "$domain")

    # Get existing TXT records
    local existing_records=$(_gd_get_txt_records "$domain" "$record_name")

    # Build new record set excluding the record to remove
    local new_records="["
    local first_record=true
    local found_record=false

    if [ "$existing_records" != "[]" ] && [ -n "$existing_records" ]; then
        # Parse existing records and add them to the new set (except the one to remove)
        local temp_file="/tmp/gd_records_$$"
        echo "$existing_records" | awk -F',' '{for(i=1;i<=NF;i++) print $i}' | grep '"data"' > "$temp_file" 2>/dev/null || true

        while read -r line; do
            if [ -n "$line" ]; then
                local existing_value=$(echo "$line" | sed -n 's/.*"data"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p')
                if [ -n "$existing_value" ]; then
                    if [ "$existing_value" = "$txt_value" ]; then
                        found_record=true
                        dns_log_debug "Found TXT record to remove: $existing_value"
                    else
                        if [ "$first_record" = "false" ]; then
                            new_records="${new_records},"
                        fi
                        new_records="${new_records}{\"data\":\"${existing_value}\",\"ttl\":${GD_TTL}}"
                        first_record=false
                    fi
                fi
            fi
        done < "$temp_file"
        rm -f "$temp_file" 2>/dev/null || true
    fi

    new_records="${new_records}]"

    if [ "$found_record" = "false" ]; then
        dns_log_warn "TXT record not found for removal: $txt_value"
        return 0
    fi

    # Send the update request
    local response=$(dns_http_request "PUT" "$GD_API_BASE/domains/$domain/records/TXT/$record_name" "$new_records" "$GD_AUTH_HEADER
Content-Type: application/json")

    if [ $? -eq 0 ]; then
        dns_log_info "Successfully removed TXT record for $full_domain"
        return 0
    else
        dns_log_error "Failed to remove TXT record for $full_domain"
        return 1
    fi
}

# Test provider connectivity
dns_godaddy_test() {
    dns_log_info "Testing GoDaddy DNS API connectivity"

    if ! _gd_setup_auth; then
        return 1
    fi

    # Test API connectivity
    local response=$(dns_http_get "$GD_API_BASE/domains" "$GD_AUTH_HEADER
Content-Type: application/json")

    if [ $? -ne 0 ]; then
        dns_log_error "Failed to connect to GoDaddy API"
        return 1
    fi

    # Check for API errors
    if echo "$response" | grep -q '"code"'; then
        local error_msg=$(echo "$response" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p')
        dns_log_error "GoDaddy API error: $error_msg"
        return 1
    fi

    dns_log_info "GoDaddy DNS API test successful"
    return 0
}
