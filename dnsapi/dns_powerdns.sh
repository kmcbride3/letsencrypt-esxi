#!/bin/sh
#
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

# Configuration
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

    # Clean up URL (remove trailing slash)
    PDNS_URL=$(echo "$PDNS_URL" | sed 's|/$||')

    dns_log_debug "PowerDNS API setup complete for $PDNS_URL"
    return 0
}

# Find zone for domain
_pdns_find_zone() {
    local domain="$1"

    # List all zones and find the best match
    local zones_url="$PDNS_URL/api/v1/servers/localhost/zones"
    local response=$(dns_http_get "$zones_url" "X-API-Key: $PDNS_API_KEY
Content-Type: application/json")

    if [ $? -ne 0 ]; then
        dns_log_error "Failed to list PowerDNS zones"
        return 1
    fi

    # Find the longest matching zone
    local best_zone=""
    local best_length=0

    # Parse zones from JSON response
    local temp_file="/tmp/pdns_zones_$$"
    echo "$response" | tr ',' '\n' | grep '"name"' | sed 's/.*"name"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/' > "$temp_file" 2>/dev/null || true

    while read -r zone_name; do
        if [ -n "$zone_name" ]; then
            # Remove trailing dot if present
            zone_name=$(echo "$zone_name" | sed 's/\.$//')

            # Check if domain ends with this zone
            if echo "$domain" | grep -E "(^|\\.)${zone_name}$" > /dev/null; then
                local zone_length=$(echo "$zone_name" | wc -c)
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
    local zone="$1"
    local record_name="$2"
    local record_type="$3"

    local zone_url="$PDNS_URL/api/v1/servers/localhost/zones/$zone"
    local response=$(dns_http_get "$zone_url" "X-API-Key: $PDNS_API_KEY
Content-Type: application/json")

    if [ $? -eq 0 ]; then
        # Look for existing TXT records for this name
        local temp_file="/tmp/pdns_rrsets_$$"
        echo "$response" | tr '}' '\n' | grep -E "\"name\"[[:space:]]*:[[:space:]]*\"$record_name\\.?\"" | grep "\"type\"[[:space:]]*:[[:space:]]*\"$record_type\"" > "$temp_file" 2>/dev/null || true

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
    local domain="$1"
    local txt_value="$2"

    dns_log_info "Adding TXT record for $domain"

    if ! _pdns_setup; then
        return 1
    fi

    # Find zone
    local zone=$(_pdns_find_zone "$domain")
    if [ $? -ne 0 ]; then
        return 1
    fi

    # Calculate record name (must be FQDN for PowerDNS)
    local record_name="$domain"
    if ! echo "$record_name" | grep -q '\.$'; then
        record_name="$record_name."
    fi

    dns_log_debug "Zone: $zone, Record: $record_name"

    # Check for existing TXT records
    local existing_rrset=$(_pdns_get_rrsets "$zone" "$domain" "TXT")
    local records_json=""

    if [ $? -eq 0 ]; then
        # Extract existing records
        dns_log_debug "Found existing TXT records, adding to them"

        # Parse existing records and build new record set
        local temp_file="/tmp/pdns_records_$$"
        echo "$existing_rrset" | tr ',' '\n' | grep '"content"' | sed 's/.*"content"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/' > "$temp_file" 2>/dev/null || true

        local first=true
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

        # Add new record
        if [ "$first" = "true" ]; then
            records_json="{\"content\": \"\\\"$txt_value\\\"\", \"disabled\": false}"
        else
            records_json="$records_json, {\"content\": \"\\\"$txt_value\\\"\", \"disabled\": false}"
        fi
    else
        # New record
        dns_log_debug "Creating new TXT record"
        records_json="{\"content\": \"\\\"$txt_value\\\"\", \"disabled\": false}"
    fi

    # Prepare PATCH data
    local patch_data="{
        \"rrsets\": [
            {
                \"name\": \"$record_name\",
                \"type\": \"TXT\",
                \"changetype\": \"REPLACE\",
                \"records\": [$records_json],
                \"ttl\": $PDNS_TTL
            }
        ]
    }"

    # Apply changes
    local zone_url="$PDNS_URL/api/v1/servers/localhost/zones/$zone"
    local response=$(dns_http_request "PATCH" "$zone_url" "$patch_data" "X-API-Key: $PDNS_API_KEY
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
dns_powerdns_rm() {
    local domain="$1"
    local txt_value="$2"

    dns_log_info "Removing TXT record for $domain"

    if ! _pdns_setup; then
        return 1
    fi

    # Find zone
    local zone=$(_pdns_find_zone "$domain")
    if [ $? -ne 0 ]; then
        return 1
    fi

    # Calculate record name
    local record_name="$domain"
    if ! echo "$record_name" | grep -q '\.$'; then
        record_name="$record_name."
    fi

    # Get existing records
    local existing_rrset=$(_pdns_get_rrsets "$zone" "$domain" "TXT")

    if [ $? -ne 0 ]; then
        dns_log_warning "TXT record not found for $domain"
        return 0
    fi

    # Parse existing records and filter out the target value
    local temp_file="/tmp/pdns_records_$$"
    echo "$existing_rrset" | tr ',' '\n' | grep '"content"' | sed 's/.*"content"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/' > "$temp_file" 2>/dev/null || true

    local records_json=""
    local first=true
    local found=false

    while read -r existing_content; do
        # Remove quotes and check if it matches our target
        local clean_content=$(echo "$existing_content" | sed 's/^"\\|"$//g')

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
        dns_log_warning "Target TXT record value not found for $domain"
        return 0
    fi

    local zone_url="$PDNS_URL/api/v1/servers/localhost/zones/$zone"

    if [ -z "$records_json" ]; then
        # No more records, delete the RRSet
        dns_log_debug "Deleting entire TXT RRSet"
        local patch_data="{
            \"rrsets\": [
                {
                    \"name\": \"$record_name\",
                    \"type\": \"TXT\",
                    \"changetype\": \"DELETE\"
                }
            ]
        }"
    else
        # Update with remaining records
        dns_log_debug "Updating TXT RRSet with remaining records"
        local patch_data="{
            \"rrsets\": [
                {
                    \"name\": \"$record_name\",
                    \"type\": \"TXT\",
                    \"changetype\": \"REPLACE\",
                    \"records\": [$records_json],
                    \"ttl\": $PDNS_TTL
                }
            ]
        }"
    fi

    local response=$(dns_http_request "PATCH" "$zone_url" "$patch_data" "X-API-Key: $PDNS_API_KEY
Content-Type: application/json")

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

    if ! _pdns_setup; then
        return 1
    fi

    # Test API connectivity
    local config_url="$PDNS_URL/api/v1/servers/localhost/config"
    local response=$(dns_http_get "$config_url" "X-API-Key: $PDNS_API_KEY
Content-Type: application/json")

    if [ $? -ne 0 ]; then
        dns_log_error "Failed to connect to PowerDNS API at $PDNS_URL"
        return 1
    fi

    # Check for API errors
    if echo "$response" | grep -q '"error"'; then
        local error_msg=$(echo "$response" | sed -n 's/.*"error"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p')
        dns_log_error "PowerDNS API error: $error_msg"
        return 1
    fi

    # Test zone listing
    local zones_url="$PDNS_URL/api/v1/servers/localhost/zones"
    local zones_response=$(dns_http_get "$zones_url" "X-API-Key: $PDNS_API_KEY
Content-Type: application/json")

    if [ $? -ne 0 ]; then
        dns_log_error "Failed to list PowerDNS zones"
        return 1
    fi

    dns_log_info "PowerDNS API test successful"
    return 0
}
