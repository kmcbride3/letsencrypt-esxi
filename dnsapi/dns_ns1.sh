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
    domain="$1"
    if [ -n "$NS1_ZONE" ]; then
        echo "$NS1_ZONE"
        return 0
    fi
    test_domain="$domain"
    while [ -n "$test_domain" ]; do
        dns_log_debug "Testing zone: $test_domain"
        zone_url="$NS1_API_BASE/zones/$test_domain"
        response=$(dns_http_get "$zone_url" "X-NSONE-Key: $NS1_API_KEY\nContent-Type: application/json")
        if [ $? -eq 0 ] && echo "$response" | grep -q '"zone"'; then
            echo "$test_domain"
            return 0
        fi
        if [ "$(echo "$test_domain" | awk -F'.' '{print NF}')" -le 2 ]; then
            break
        fi
        test_domain=$(echo "$test_domain" | sed 's/^[^.]*\.//')
    done
    dns_log_error "Could not find NS1 zone for domain: $domain"
    return 1
}

# Get existing TXT records for a domain
_ns1_get_txt_records() {
    zone="$1"
    record_name="$2"
    record_url="$NS1_API_BASE/zones/$zone/$record_name/TXT"
    response=$(dns_http_get "$record_url" "X-NSONE-Key: $NS1_API_KEY\nContent-Type: application/json")
    if [ $? -eq 0 ] && echo "$response" | grep -q '"answers"'; then
        echo "$response"
        return 0
    else
        return 1
    fi
}

# Add TXT record
dns_ns1_add() {
    domain="$1"
    txt_value="$2"
    dns_log_info "Adding TXT record for $domain"
    _ns1_setup || return 1
    zone=$(_ns1_find_zone "$domain") || return 1
    record_name=$(echo "$domain" | sed "s/\.${zone}$//")
    if [ -z "$record_name" ] || [ "$record_name" = "$domain" ]; then
        record_name="$zone"
    fi
    dns_log_debug "Zone: $zone, Record: $record_name"
    existing_records=$(_ns1_get_txt_records "$zone" "$record_name")
    if [ $? -eq 0 ]; then
        dns_log_debug "Record exists, adding to existing TXT records"
        answers=""
        temp_file="/tmp/ns1_answers_$$"
        echo "$existing_records" | awk -F',' '{for(i=1;i<=NF;i++) print $i}' | grep '"rdata"' | sed 's/.*"rdata"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' > "$temp_file" 2>/dev/null || true
        first=true
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
        if [ "$first" = "true" ]; then
            answers="\"$txt_value\""
        else
            answers="$answers, \"$txt_value\""
        fi
    else
        dns_log_debug "Creating new TXT record"
        answers="\"$txt_value\""
    fi
    record_data="{\n    \"zone\": \"$zone\",\n    \"domain\": \"$record_name\",\n    \"type\": \"TXT\",\n    \"ttl\": $NS1_TTL,\n    \"answers\": [\n        {\n            \"answer\": [$answers]\n        }\n    ]\n}"
    record_url="$NS1_API_BASE/zones/$zone/$record_name/TXT"
    response=$(dns_http_request "PUT" "$record_url" "$record_data" "X-NSONE-Key: $NS1_API_KEY\nContent-Type: application/json")
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
    domain="$1"
    txt_value="$2"
    dns_log_info "Removing TXT record for $domain"
    _ns1_setup || return 1
    zone=$(_ns1_find_zone "$domain") || return 1
    record_name=$(echo "$domain" | sed "s/\.${zone}$//")
    if [ -z "$record_name" ] || [ "$record_name" = "$domain" ]; then
        record_name="$zone"
    fi
    existing_records=$(_ns1_get_txt_records "$zone" "$record_name")
    if [ $? -ne 0 ]; then
        dns_log_warn "TXT record not found for $domain"
        return 0
    fi
    answers=""
    temp_file="/tmp/ns1_answers_$$"
    echo "$existing_records" | awk -F',' '{for(i=1;i<=NF;i++) print $i}' | grep '"rdata"' | sed 's/.*"rdata"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' > "$temp_file" 2>/dev/null || true
    first=true
    found=false
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
        dns_log_warn "Target TXT record value not found for $domain"
        return 0
    fi
    record_url="$NS1_API_BASE/zones/$zone/$record_name/TXT"
    if [ -z "$answers" ]; then
        dns_log_debug "Deleting entire TXT record"
        response=$(dns_http_request "DELETE" "$record_url" "" "X-NSONE-Key: $NS1_API_KEY\nContent-Type: application/json")
    else
        dns_log_debug "Updating TXT record with remaining values"
        record_data="{\n    \"zone\": \"$zone\",\n    \"domain\": \"$record_name\",\n    \"type\": \"TXT\",\n    \"ttl\": $NS1_TTL,\n    \"answers\": [\n        {\n            \"answer\": [$answers]\n        }\n    ]\n}"
        response=$(dns_http_request "PUT" "$record_url" "$record_data" "X-NSONE-Key: $NS1_API_KEY\nContent-Type: application/json")
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
    _ns1_setup || return 1
    response=$(dns_http_get "$NS1_API_BASE/zones" "X-NSONE-Key: $NS1_API_KEY\nContent-Type: application/json")
    if [ $? -ne 0 ]; then
        dns_log_error "Failed to connect to NS1 API"
        return 1
    fi
    if echo "$response" | grep -q '"message"'; then
        error_msg=$(echo "$response" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        dns_log_error "NS1 API error: $error_msg"
        return 1
    fi
    if ! echo "$response" | grep -q '\['; then
        dns_log_error "No zones found or insufficient permissions"
        return 1
    fi
    dns_log_info "NS1 API test successful"
    return 0
}
