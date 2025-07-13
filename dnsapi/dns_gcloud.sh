#!/bin/sh
#
# Google Cloud DNS API Provider
# Requires: gcloud authentication or service account key
#

# Provider information
dns_gcloud_info() {
    echo "Google Cloud DNS API Provider"
    echo "Website: https://cloud.google.com/dns"
    echo "Documentation: https://cloud.google.com/dns/docs/reference/v1"
    echo ""
    echo "Authentication Options:"
    echo "1. Service Account Key (Recommended for automation):"
    echo "   GCP_SERVICE_ACCOUNT_KEY - Base64 encoded service account JSON key"
    echo "   OR"
    echo "   GCP_SERVICE_ACCOUNT_FILE - Path to service account JSON file"
    echo ""
    echo "2. gcloud CLI (Interactive environments):"
    echo "   Run 'gcloud auth login' and 'gcloud config set project PROJECT_ID'"
    echo ""
    echo "Required Settings:"
    echo "  GCP_PROJECT_ID      - Google Cloud Project ID"
    echo ""
    echo "Optional Settings:"
    echo "  GCP_TTL             - TTL for DNS records (default: 120)"
    echo "  GCP_ZONE_NAME       - Managed zone name (auto-detected if not set)"
}

# Google Cloud API endpoints
GCP_API_BASE="https://dns.googleapis.com/dns/v1"

# Default settings
GCP_TTL=${GCP_TTL:-120}

# Authentication setup
_gcp_setup_auth() {
    if [ -z "$GCP_PROJECT_ID" ]; then
        dns_log_error "GCP_PROJECT_ID not set"
        return 1
    fi

    # Try service account authentication first
    if [ -n "$GCP_SERVICE_ACCOUNT_KEY" ]; then
        dns_log_debug "Using service account key authentication"

        # Decode base64 key and save to temp file
        local key_file="/tmp/gcp_key_$$.json"
        echo "$GCP_SERVICE_ACCOUNT_KEY" | base64 -d > "$key_file" 2>/dev/null

        if [ $? -ne 0 ]; then
            dns_log_error "Failed to decode GCP_SERVICE_ACCOUNT_KEY"
            return 1
        fi

        GCP_KEY_FILE="$key_file"
        GCP_CLEANUP_KEY=true

    elif [ -n "$GCP_SERVICE_ACCOUNT_FILE" ]; then
        dns_log_debug "Using service account file authentication"

        if [ ! -f "$GCP_SERVICE_ACCOUNT_FILE" ]; then
            dns_log_error "Service account file not found: $GCP_SERVICE_ACCOUNT_FILE"
            return 1
        fi

        GCP_KEY_FILE="$GCP_SERVICE_ACCOUNT_FILE"
        GCP_CLEANUP_KEY=false

    else
        dns_log_debug "Using gcloud CLI authentication"

        # Check if gcloud is available and authenticated
        if ! command -v gcloud >/dev/null 2>&1; then
            dns_log_error "gcloud CLI not found and no service account provided"
            return 1
        fi

        # Test gcloud authentication
        if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | head -1 >/dev/null 2>&1; then
            dns_log_error "gcloud not authenticated. Run 'gcloud auth login'"
            return 1
        fi

        GCP_USE_GCLOUD=true
    fi

    return 0
}

# Get OAuth2 access token
_gcp_get_access_token() {
    if [ "$GCP_USE_GCLOUD" = "true" ]; then
        # Use gcloud to get token
        gcloud auth print-access-token 2>/dev/null
        return $?
    else
        # Use service account key to get token
        local jwt_header='{"alg":"RS256","typ":"JWT"}'
        local jwt_header_b64=$(echo -n "$jwt_header" | base64 | tr -d '=' | tr '/+' '_-')

        local now=$(date +%s)
        local exp=$((now + 3600))

        # Extract client_email from service account key
        local client_email=$(grep -o '"client_email":"[^"]*"' "$GCP_KEY_FILE" | cut -d'"' -f4)

        local jwt_payload="{\"iss\":\"$client_email\",\"scope\":\"https://www.googleapis.com/auth/ndev.clouddns.readwrite\",\"aud\":\"https://oauth2.googleapis.com/token\",\"exp\":$exp,\"iat\":$now}"
        local jwt_payload_b64=$(echo -n "$jwt_payload" | base64 | tr -d '=' | tr '/+' '_-')

        local jwt_unsigned="${jwt_header_b64}.${jwt_payload_b64}"

        # This is a simplified approach - in production you'd need proper JWT signing
        # For now, we'll use gcloud as a fallback if available
        if command -v gcloud >/dev/null 2>&1; then
            GOOGLE_APPLICATION_CREDENTIALS="$GCP_KEY_FILE" gcloud auth print-access-token 2>/dev/null
        else
            dns_log_error "JWT signing not implemented for service account keys without gcloud"
            return 1
        fi
    fi
}

# Cleanup function
_gcp_cleanup() {
    if [ "$GCP_CLEANUP_KEY" = "true" ] && [ -n "$GCP_KEY_FILE" ]; then
        rm -f "$GCP_KEY_FILE" 2>/dev/null || true
    fi
}

# Find managed zone for domain
_gcp_find_zone() {
    local domain="$1"
    local access_token="$2"

    # Try exact match first, then parent domains
    local test_domain="$domain"

    while [ -n "$test_domain" ]; do
        local zone_response=$(dns_http_get "$GCP_API_BASE/projects/$GCP_PROJECT_ID/managedZones" "Authorization: Bearer $access_token
Content-Type: application/json")

        if [ $? -eq 0 ]; then
            # Parse response to find matching zone
            # Simplified JSON parsing for ESXi compatibility
            local temp_file="/tmp/gcp_zones_$$"
            echo "$zone_response" | tr ',' '\n' | grep -E '"name"|"dnsName"' > "$temp_file" 2>/dev/null || true

            local zone_name=""
            local dns_name=""

            while read -r line; do
                if echo "$line" | grep -q '"name"'; then
                    zone_name=$(echo "$line" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p')
                elif echo "$line" | grep -q '"dnsName"'; then
                    dns_name=$(echo "$line" | sed -n 's/.*"dnsName"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p')

                    # Remove trailing dot and check if domain matches
                    local clean_dns_name=$(echo "$dns_name" | sed 's/\\.$//')
                    if [ "$test_domain" = "$clean_dns_name" ] || echo "$domain" | grep -q "\\.${clean_dns_name}$"; then
                        echo "$zone_name"
                        rm -f "$temp_file" 2>/dev/null || true
                        return 0
                    fi
                fi
            done < "$temp_file"
            rm -f "$temp_file" 2>/dev/null || true
        fi

        # Try parent domain
        if [ "$(echo "$test_domain" | tr '.' '\n' | wc -l)" -le 2 ]; then
            break
        fi
        test_domain=$(echo "$test_domain" | cut -d. -f2-)
    done

    dns_log_error "Could not find Google Cloud DNS zone for domain: $domain"
    return 1
}

# Add TXT record
dns_gcloud_add() {
    local domain="$1"
    local txt_value="$2"

    dns_log_info "Adding TXT record for $domain"

    if ! _gcp_setup_auth; then
        _gcp_cleanup
        return 1
    fi

    local access_token=$(_gcp_get_access_token)
    if [ $? -ne 0 ] || [ -z "$access_token" ]; then
        dns_log_error "Failed to get Google Cloud access token"
        _gcp_cleanup
        return 1
    fi

    # Find the managed zone
    local zone_name=""
    if [ -n "$GCP_ZONE_NAME" ]; then
        zone_name="$GCP_ZONE_NAME"
    else
        zone_name=$(_gcp_find_zone "$domain" "$access_token")
        if [ $? -ne 0 ]; then
            _gcp_cleanup
            return 1
        fi
    fi

    dns_log_debug "Using zone: $zone_name"

    # Create change request
    local change_request="{
        \"additions\": [
            {
                \"name\": \"${domain}.\",
                \"type\": \"TXT\",
                \"ttl\": ${GCP_TTL},
                \"rrdatas\": [\"\\\"${txt_value}\\\"\"]
            }
        ]
    }"

    # Submit change request
    local response=$(dns_http_request "POST" "$GCP_API_BASE/projects/$GCP_PROJECT_ID/managedZones/$zone_name/changes" "$change_request" "Authorization: Bearer $access_token
Content-Type: application/json")

    if [ $? -eq 0 ]; then
        dns_log_info "Successfully added TXT record for $domain"
        _gcp_cleanup
        return 0
    else
        dns_log_error "Failed to add TXT record for $domain"
        _gcp_cleanup
        return 1
    fi
}

# Remove TXT record
dns_gcloud_rm() {
    local domain="$1"
    local txt_value="$2"

    dns_log_info "Removing TXT record for $domain"

    if ! _gcp_setup_auth; then
        _gcp_cleanup
        return 1
    fi

    local access_token=$(_gcp_get_access_token)
    if [ $? -ne 0 ] || [ -z "$access_token" ]; then
        dns_log_error "Failed to get Google Cloud access token"
        _gcp_cleanup
        return 1
    fi

    # Find the managed zone
    local zone_name=""
    if [ -n "$GCP_ZONE_NAME" ]; then
        zone_name="$GCP_ZONE_NAME"
    else
        zone_name=$(_gcp_find_zone "$domain" "$access_token")
        if [ $? -ne 0 ]; then
            _gcp_cleanup
            return 1
        fi
    fi

    # Create change request to remove the record
    local change_request="{
        \"deletions\": [
            {
                \"name\": \"${domain}.\",
                \"type\": \"TXT\",
                \"ttl\": ${GCP_TTL},
                \"rrdatas\": [\"\\\"${txt_value}\\\"\"]
            }
        ]
    }"

    # Submit change request
    local response=$(dns_http_request "POST" "$GCP_API_BASE/projects/$GCP_PROJECT_ID/managedZones/$zone_name/changes" "$change_request" "Authorization: Bearer $access_token
Content-Type: application/json")

    if [ $? -eq 0 ]; then
        dns_log_info "Successfully removed TXT record for $domain"
        _gcp_cleanup
        return 0
    else
        dns_log_error "Failed to remove TXT record for $domain"
        _gcp_cleanup
        return 1
    fi
}

# Test provider connectivity
dns_gcloud_test() {
    dns_log_info "Testing Google Cloud DNS API connectivity"

    if ! _gcp_setup_auth; then
        _gcp_cleanup
        return 1
    fi

    local access_token=$(_gcp_get_access_token)
    if [ $? -ne 0 ] || [ -z "$access_token" ]; then
        dns_log_error "Failed to get Google Cloud access token"
        _gcp_cleanup
        return 1
    fi

    # Test API connectivity
    local response=$(dns_http_get "$GCP_API_BASE/projects/$GCP_PROJECT_ID/managedZones" "Authorization: Bearer $access_token
Content-Type: application/json")

    if [ $? -ne 0 ]; then
        dns_log_error "Failed to connect to Google Cloud DNS API"
        _gcp_cleanup
        return 1
    fi

    # Check for API errors
    if echo "$response" | grep -q '"error"'; then
        local error_msg=$(echo "$response" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p')
        dns_log_error "Google Cloud DNS API error: $error_msg"
        _gcp_cleanup
        return 1
    fi

    dns_log_info "Google Cloud DNS API test successful"
    _gcp_cleanup
    return 0
}
