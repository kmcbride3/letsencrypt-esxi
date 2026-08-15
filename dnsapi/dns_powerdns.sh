# PowerDNS Authoritative Server API Provider
# Supports PowerDNS Authoritative Server with API enabled
# Documentation: https://doc.powerdns.com/authoritative/http-api/
#

# Provider information
dns_powerdns_info() {
    echo "PowerDNS Authoritative Server API Provider"
    echo "Website: https://www.powerdns.com/"
    echo "Documentation: https://doc.powerdns.com/authoritative/http-api/"
    echo ""
    echo "Required Settings:"
    echo "   PDNS_URL       - PowerDNS API URL (e.g., http://localhost:8081)"
    echo "   PDNS_API_KEY   - PowerDNS API Key"
    echo ""
    echo "Optional Settings:"
    echo "   PDNS_TTL       - TTL for DNS records (default: 120)"
    echo "   PDNS_TIMEOUT   - API request timeout in seconds (default: 30)"
    echo ""
    echo "PowerDNS Configuration Requirements:"
    echo "- Authoritative server with api=yes"
    echo "- api-key configured in pdns.conf"
    echo "- webserver=yes and webserver-address configured"
    echo "- Appropriate firewall rules for API access"
    echo ""
    echo "Example pdns.conf snippet:"
    echo "  api=yes"
    echo "  api-key=your-secret-key-here"
    echo "  webserver=yes"
    echo "  webserver-address=0.0.0.0"
    echo "  webserver-port=8081"
}

PDNS_TTL=${PDNS_TTL:-120}
PDNS_TIMEOUT=${PDNS_TIMEOUT:-30}

# Setup and validation
_pdns_setup() {
    if [ -z "$PDNS_URL" ]; then
        dns_log_error "PDNS_URL not set"
        return 1
    fi
    if [ -z "$PDNS_API_KEY" ]; then
        dns_log_error "PDNS_API_KEY not set"
        return 1
    fi
    PDNS_URL=$(echo "$PDNS_URL" | sed 's|/$||')
    dns_log_debug "PowerDNS API setup complete for $PDNS_URL"
    return 0
}

# Find zone for domain
_pdns_find_zone() {
    domain="$1"
    zones_url="$PDNS_URL/api/v1/servers/localhost/zones"
    response=$(dns_http_get "$zones_url" "X-API-Key: $PDNS_API_KEY\nContent-Type: application/json")
    if [ $? -ne 0 ]; then
        dns_log_error "Failed to list PowerDNS zones"
        return 1
    fi
    best_zone=""
    best_length=0
    temp_file="/tmp/pdns_zones_$$"
    echo "$response" | awk -F',' '{for(i=1;i<=NF;i++) print $i}' | grep '"name"' | sed 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' > "$temp_file" 2>/dev/null || true
    while read -r zone_name; do
        if [ -n "$zone_name" ]; then
            zone_name=$(echo "$zone_name" | sed 's/\.$//')
            if echo "$domain" | grep -E "(^|\\.)${zone_name}$" > /dev/null; then
                zone_length=$(echo "$zone_name" | wc -c)
                if [ "$zone_length" -gt "$best_length" ]; then
                    best_zone="$zone_name"
                    best_length="$zone_length"
                fi
            fi
        fi
    done < "$temp_file"
    rm -f "$temp_file" 2>/dev/null || true
    if [ -n "$best_zone" ]; then
        echo "$best_zone"
        return 0
    else
        dns_log_error "Could not find PowerDNS zone for domain: $domain"
        return 1
    fi
}

# Get existing RRSets for record
_pdns_get_rrsets() {
    zone="$1"
    record_name="$2"
    record_type="$3"
    zone_url="$PDNS_URL/api/v1/servers/localhost/zones/$zone"
    response=$(dns_http_get "$zone_url" "X-API-Key: $PDNS_API_KEY\nContent-Type: application/json")
    if [ $? -eq 0 ]; then
        temp_file="/tmp/pdns_rrsets_$$"
        echo "$response" | awk -F'}' '{for(i=1;i<=NF;i++) print $i}' | grep -E "\"name\"[[:space:]]*:[[:space:]]*\"$record_name\\.?\"" | grep "\"type\"[[:space:]]*:[[:space:]]*\"$record_type\"" > "$temp_file" 2>/dev/null || true
        if [ -s "$temp_file" ]; then
            cat "$temp_file"
            rm -f "$temp_file" 2>/dev/null || true
            return 0
        else
            rm -f "$temp_file" 2>/dev/null || true
            return 1
        fi
    else
        return 1
    fi
}

# Add TXT record
dns_powerdns_add() {
    domain="$1"
    txt_value="$2"
    dns_log_info "Adding TXT record for $domain"
    _pdns_setup || return 1
    zone=$(_pdns_find_zone "$domain") || return 1
    record_name="$domain"
    if ! echo "$record_name" | grep -q '\.$'; then
        record_name="$record_name."
    fi
    dns_log_debug "Zone: $zone, Record: $record_name"
    existing_rrset=$(_pdns_get_rrsets "$zone" "$domain" "TXT")
    records_json=""
    if [ $? -eq 0 ]; then
        dns_log_debug "Found existing TXT records, adding to them"
        temp_file="/tmp/pdns_records_$$"
        echo "$existing_rrset" | awk -F',' '{for(i=1;i<=NF;i++) print $i}' | grep '"content"' | sed 's/.*"content"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' > "$temp_file" 2>/dev/null || true
        first=true
        records_json=""
        while read -r existing_content; do
            if [ -n "$existing_content" ]; then
                if [ "$first" = "true" ]; then
                    records_json="{\"content\": \"$existing_content\", \"disabled\": false}"
                    first=false
                else
                    records_json="$records_json, {\"content\": \"$existing_content\", \"disabled\": false}"
                fi
            fi
        done < "$temp_file"
        rm -f "$temp_file" 2>/dev/null || true
        if [ "$first" = "true" ]; then
            records_json="{\"content\": \"\\\"$txt_value\\\"\", \"disabled\": false}"
        else
            records_json="$records_json, {\"content\": \"\\\"$txt_value\\\"\", \"disabled\": false}"
        fi
    else
        dns_log_debug "Creating new TXT record"
        records_json="{\"content\": \"\\\"$txt_value\\\"\", \"disabled\": false}"
    fi
    patch_data="{\n    \"rrsets\": [\n        {\n            \"name\": \"$record_name\",\n            \"type\": \"TXT\",\n            \"changetype\": \"REPLACE\",\n            \"records\": [$records_json],\n            \"ttl\": $PDNS_TTL\n        }\n    ]\n}"
    zone_url="$PDNS_URL/api/v1/servers/localhost/zones/$zone"
    response=$(dns_http_request "PATCH" "$zone_url" "$patch_data" "X-API-Key: $PDNS_API_KEY\nContent-Type: application/json")
    if [ $? -eq 0 ]; then
        dns_log_info "Successfully added TXT record for $domain"
        return 0
    else
        dns_log_error "Failed to add TXT record for $domain"
        return 1
    fi
}

# Remove TXT record
dns_powerdns_rm() {
    domain="$1"
    txt_value="$2"
    dns_log_info "Removing TXT record for $domain"
    _pdns_setup || return 1
    zone=$(_pdns_find_zone "$domain") || return 1
    record_name="$domain"
    if ! echo "$record_name" | grep -q '\.$'; then
        record_name="$record_name."
    fi
    existing_rrset=$(_pdns_get_rrsets "$zone" "$domain" "TXT")
    if [ $? -ne 0 ]; then
        dns_log_warn "TXT record not found for $domain"
        return 0
    fi
    temp_file="/tmp/pdns_records_$$"
    echo "$existing_rrset" | awk -F',' '{for(i=1;i<=NF;i++) print $i}' | grep '"content"' | sed 's/.*"content"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' > "$temp_file" 2>/dev/null || true
    records_json=""
    first=true
    found=false
    while read -r existing_content; do
        clean_content=$(echo "$existing_content" | sed 's/^"\|"$//g')
        if [ -n "$existing_content" ] && [ "$clean_content" != "$txt_value" ]; then
            if [ "$first" = "true" ]; then
                records_json="{\"content\": \"$existing_content\", \"disabled\": false}"
                first=false
            else
                records_json="$records_json, {\"content\": \"$existing_content\", \"disabled\": false}"
            fi
        elif [ "$clean_content" = "$txt_value" ]; then
            found=true
        fi
    done < "$temp_file"
    rm -f "$temp_file" 2>/dev/null || true
    if [ "$found" != "true" ]; then
        dns_log_warn "Target TXT record value not found for $domain"
        return 0
    fi
    zone_url="$PDNS_URL/api/v1/servers/localhost/zones/$zone"
    if [ -z "$records_json" ]; then
        dns_log_debug "Deleting entire TXT RRSet"
        patch_data="{\n    \"rrsets\": [\n        {\n            \"name\": \"$record_name\",\n            \"type\": \"TXT\",\n            \"changetype\": \"DELETE\"\n        }\n    ]\n}"
    else
        dns_log_debug "Updating TXT RRSet with remaining records"
        patch_data="{\n    \"rrsets\": [\n        {\n            \"name\": \"$record_name\",\n            \"type\": \"TXT\",\n            \"changetype\": \"REPLACE\",\n            \"records\": [$records_json],\n            \"ttl\": $PDNS_TTL\n        }\n    ]\n}"
    fi
    response=$(dns_http_request "PATCH" "$zone_url" "$patch_data" "X-API-Key: $PDNS_API_KEY\nContent-Type: application/json")
    if [ $? -eq 0 ]; then
        dns_log_info "Successfully removed TXT record for $domain"
        return 0
    else
        dns_log_error "Failed to remove TXT record for $domain"
        return 1
    fi
}

# Test provider connectivity
dns_powerdns_test() {
    dns_log_info "Testing PowerDNS API connectivity"
    _pdns_setup || return 1
    config_url="$PDNS_URL/api/v1/servers/localhost/config"
    response=$(dns_http_get "$config_url" "X-API-Key: $PDNS_API_KEY\nContent-Type: application/json")
    if [ $? -ne 0 ]; then
        dns_log_error "Failed to connect to PowerDNS API at $PDNS_URL"
        return 1
    fi
    if echo "$response" | grep -q '"error"'; then
        error_msg=$(echo "$response" | sed -n 's/.*"error"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        dns_log_error "PowerDNS API error: $error_msg"
        return 1
    fi
    zones_url="$PDNS_URL/api/v1/servers/localhost/zones"
    zones_response=$(dns_http_get "$zones_url" "X-API-Key: $PDNS_API_KEY\nContent-Type: application/json")
    if [ $? -ne 0 ]; then
        dns_log_error "Failed to list PowerDNS zones"
        return 1
    fi
    dns_log_info "PowerDNS API test successful"
    return 0
}
