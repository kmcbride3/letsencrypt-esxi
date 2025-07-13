#!/bin/sh
#
# NS1 DNS API Provider
# Documentation: https://ns1.com/api
#

# Provider information
dns_ns1_info() {
    echo "NS1 DNS API Provider"
    echo "Website: https://ns1.com/"
    echo "Documentation: https://ns1.com/api"
    echo ""
    echo "Required Settings:"
    echo "   NS1_API_KEY    - NS1 API Key"
    echo ""
    echo "Optional Settings:"
    echo "   NS1_TTL        - TTL for DNS records (default: 3600)"
    echo "   NS1_ZONE       - Force specific zone (auto-detected if not set)"
    echo ""
    echo "API Key Creation:"
    echo "1. Log into NS1 account"
    echo "2. Go to Account Settings > API Keys"
    echo "3. Create new API key with 'zones' permission"
    echo "4. Set permissions for required zones"
}

# Configuration
NS1_API_BASE="https://api.nsone.net/v1"
NS1_TTL=${NS1_TTL:-3600}

# Setup and validation
_ns1_setup() {
    if [ -z "$NS1_API_KEY" ]; then
        dns_log_error "NS1_API_KEY not set"
        return 1
    fi

    dns_log_debug "NS1 API setup complete"
    return 0
}

# Find zone for domain
_ns1_find_zone() {
    local domain="$1"

    # If zone is explicitly set, use it
    if [ -n "$NS1_ZONE" ]; then
        echo "$NS1_ZONE"
        return 0
    fi

    # Try domain and parent domains
    local test_domain="$domain"

    while [ -n "$test_domain" ]; do
        dns_log_debug "Testing zone: $test_domain"

        local zone_url="$NS1_API_BASE/zones/$test_domain"
        local response=$(dns_http_get "$zone_url" "X-NSONE-Key: $NS1_API_KEY
Content-Type: application/json")

        if [ $? -eq 0 ] && echo "$response" | grep -q '"zone"'; then
            echo "$test_domain"
            return 0
        fi

        # Try parent domain
        if [ "$(echo "$test_domain" | tr '.' '\n' | wc -l)" -le 2 ]; then
            break
        fi
        test_domain=$(echo "$test_domain" | cut -d. -f2-)
    done

    dns_log_error "Could not find NS1 zone for domain: $domain"
    return 1
}

# Get existing TXT records for a domain
_ns1_get_txt_records() {
    local zone="$1"
    local record_name="$2"

    local record_url="$NS1_API_BASE/zones/$zone/$record_name/TXT"
    local response=$(dns_http_get "$record_url" "X-NSONE-Key: $NS1_API_KEY
Content-Type: application/json")

    if [ $? -eq 0 ] && echo "$response" | grep -q '"answers"'; then
        echo "$response"
        return 0
    else
        # Record doesn't exist
        return 1
    fi
}

# Add TXT record
dns_ns1_add() {
    local domain="$1"
    local txt_value="$2"

    dns_log_info "Adding TXT record for $domain"

    if ! _ns1_setup; then
        return 1
    fi

    # Find zone
    local zone=$(_ns1_find_zone "$domain")
    if [ $? -ne 0 ]; then
        return 1
    fi

    # Calculate record name
    local record_name=$(echo "$domain" | sed "s/\\.${zone}$//")
    if [ -z "$record_name" ] || [ "$record_name" = "$domain" ]; then
        record_name="$zone"
    fi

    dns_log_debug "Zone: $zone, Record: $record_name"

    # Check if record exists
    local existing_records=$(_ns1_get_txt_records "$zone" "$record_name")

    if [ $? -eq 0 ]; then
        # Record exists, need to add to existing answers
        dns_log_debug "Record exists, adding to existing TXT records"

        # Extract existing answers and add new one
        local answers=""
        local temp_file="/tmp/ns1_answers_$$"
        echo "$existing_records" | tr ',' '\n' | grep '"rdata"' | sed 's/.*"rdata"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/' > "$temp_file" 2>/dev/null || true

        # Build answers array
        local first=true
        while read -r existing_txt; do
            if [ -n "$existing_txt" ]; then
                if [ "$first" = "true" ]; then
                    answers="\"$existing_txt\""
                    first=false
                else
                    answers="$answers, \"$existing_txt\""
                fi
            fi
        done < "$temp_file"
        rm -f "$temp_file" 2>/dev/null || true

        # Add new record
        if [ "$first" = "true" ]; then
            answers="\"$txt_value\""
        else
            answers="$answers, \"$txt_value\""
        fi
    else
        # New record
        dns_log_debug "Creating new TXT record"
        answers="\"$txt_value\""
    fi

    # Create record data
    local record_data="{
        \"zone\": \"$zone\",
        \"domain\": \"$record_name\",
        \"type\": \"TXT\",
        \"ttl\": $NS1_TTL,
        \"answers\": [
            {
                \"answer\": [$answers]
            }
        ]
    }"

    local record_url="$NS1_API_BASE/zones/$zone/$record_name/TXT"
    local response=$(dns_http_request "PUT" "$record_url" "$record_data" "X-NSONE-Key: $NS1_API_KEY
Content-Type: application/json")

    if [ $? -eq 0 ]; then
        dns_log_info "Successfully added TXT record for $domain"
        return 0
    else
        dns_log_error "Failed to add TXT record for $domain"
        return 1
    fi
}

# Remove TXT record
dns_ns1_rm() {
    local domain="$1"
    local txt_value="$2"

    dns_log_info "Removing TXT record for $domain"

    if ! _ns1_setup; then
        return 1
    fi

    # Find zone
    local zone=$(_ns1_find_zone "$domain")
    if [ $? -ne 0 ]; then
        return 1
    fi

    # Calculate record name
    local record_name=$(echo "$domain" | sed "s/\\.${zone}$//")
    if [ -z "$record_name" ] || [ "$record_name" = "$domain" ]; then
        record_name="$zone"
    fi

    # Get existing records
    local existing_records=$(_ns1_get_txt_records "$zone" "$record_name")

    if [ $? -ne 0 ]; then
        dns_log_warning "TXT record not found for $domain"
        return 0
    fi

    # Parse existing answers and remove the target value
    local answers=""
    local temp_file="/tmp/ns1_answers_$$"
    echo "$existing_records" | tr ',' '\n' | grep '"rdata"' | sed 's/.*"rdata"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/' > "$temp_file" 2>/dev/null || true

    local first=true
    local found=false
    while read -r existing_txt; do
        if [ -n "$existing_txt" ] && [ "$existing_txt" != "$txt_value" ]; then
            if [ "$first" = "true" ]; then
                answers="\"$existing_txt\""
                first=false
            else
                answers="$answers, \"$existing_txt\""
            fi
        elif [ "$existing_txt" = "$txt_value" ]; then
            found=true
        fi
    done < "$temp_file"
    rm -f "$temp_file" 2>/dev/null || true

    if [ "$found" != "true" ]; then
        dns_log_warning "Target TXT record value not found for $domain"
        return 0
    fi

    local record_url="$NS1_API_BASE/zones/$zone/$record_name/TXT"

    if [ -z "$answers" ]; then
        # No more records, delete the entire record
        dns_log_debug "Deleting entire TXT record"
        local response=$(dns_http_request "DELETE" "$record_url" "" "X-NSONE-Key: $NS1_API_KEY
Content-Type: application/json")
    else
        # Update with remaining records
        dns_log_debug "Updating TXT record with remaining values"
        local record_data="{
            \"zone\": \"$zone\",
            \"domain\": \"$record_name\",
            \"type\": \"TXT\",
            \"ttl\": $NS1_TTL,
            \"answers\": [
                {
                    \"answer\": [$answers]
                }
            ]
        }"

        local response=$(dns_http_request "PUT" "$record_url" "$record_data" "X-NSONE-Key: $NS1_API_KEY
Content-Type: application/json")
    fi

    if [ $? -eq 0 ]; then
        dns_log_info "Successfully removed TXT record for $domain"
        return 0
    else
        dns_log_error "Failed to remove TXT record for $domain"
        return 1
    fi
}

# Test provider connectivity
dns_ns1_test() {
    dns_log_info "Testing NS1 API connectivity"

    if ! _ns1_setup; then
        return 1
    fi

    # Test API connectivity by listing zones
    local response=$(dns_http_get "$NS1_API_BASE/zones" "X-NSONE-Key: $NS1_API_KEY
Content-Type: application/json")

    if [ $? -ne 0 ]; then
        dns_log_error "Failed to connect to NS1 API"
        return 1
    fi

    # Check for API errors
    if echo "$response" | grep -q '"message"'; then
        local error_msg=$(echo "$response" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p')
        dns_log_error "NS1 API error: $error_msg"
        return 1
    fi

    # Verify we can see zones
    if ! echo "$response" | grep -q '\['; then
        dns_log_error "No zones found or insufficient permissions"
        return 1
    fi

    dns_log_info "NS1 API test successful"
    return 0
}
