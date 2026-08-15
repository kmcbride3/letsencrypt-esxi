# DuckDNS API Provider
# Documentation: https://www.duckdns.org/spec.jsp
#

# Provider information
dns_duckdns_info() {
    echo "DuckDNS API Provider"
    echo "Website: https://www.duckdns.org/"
    echo "Documentation: https://www.duckdns.org/spec.jsp"
    echo ""
    echo "Required Environment Variables:"
    echo "  DUCKDNS_TOKEN  - DuckDNS Account Token"
    echo ""
    echo "Optional Settings:"
    echo "  DUCKDNS_TTL    - TTL for DNS records (default: 60, min: 60)"
}

# Configuration
DUCKDNS_API_BASE="https://www.duckdns.org/update"
DUCKDNS_TTL=${DUCKDNS_TTL:-60}

# Minimum TTL validation
if [ "$DUCKDNS_TTL" -lt 60 ]; then
    DUCKDNS_TTL=60
fi

duckdns_setup() {
    if [ -z "$DUCKDNS_TOKEN" ]; then
        dns_log_error "DUCKDNS_TOKEN not set"
        return 1
    fi
    dns_log_debug "DuckDNS API setup complete"
    return 0
}

duckdns_validate_domain() {
    domain="$1"
    if ! echo "$domain" | grep -q '\.duckdns\.org$'; then
        dns_log_error "DuckDNS only supports *.duckdns.org domains"
        return 1
    fi
    subdomain=$(echo "$domain" | sed 's/\.duckdns\.org$//')
    if ! echo "$subdomain" | grep -E '^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$' > /dev/null; then
        dns_log_error "Invalid DuckDNS subdomain format: $subdomain"
        return 1
    fi
    echo "$subdomain"
    return 0
}

# Add TXT record
dns_duckdns_add() {
    domain="$1"
    txt_value="$2"
    dns_log_info "Adding TXT record for $domain"
    duckdns_setup || return 1
    subdomain=$(duckdns_validate_domain "$domain") || return 1
    dns_log_debug "Subdomain: $subdomain"
    api_url="$DUCKDNS_API_BASE?domains=$subdomain&token=$DUCKDNS_TOKEN&txt=$txt_value&verbose=true"
    response=$(dns_http_get "$api_url")
    if [ $? -eq 0 ]; then
        if echo "$response" | grep -q "^OK"; then
            dns_log_info "Successfully added TXT record for $domain"
            dns_log_debug "Waiting for propagation..."
            sleep 5
            return 0
        elif echo "$response" | grep -q "^KO"; then
            dns_log_error "DuckDNS API returned error for $domain"
            return 1
        else
            dns_log_error "Unexpected response from DuckDNS API: $response"
            return 1
        fi
    else
        dns_log_error "Failed to connect to DuckDNS API"
        return 1
    fi
}

# Remove TXT record
dns_duckdns_rm() {
    domain="$1"
    txt_value="$2"
    dns_log_info "Removing TXT record for $domain"
    duckdns_setup || return 1
    subdomain=$(duckdns_validate_domain "$domain") || return 1
    api_url="$DUCKDNS_API_BASE?domains=$subdomain&token=$DUCKDNS_TOKEN&txt=&clear=true&verbose=true"
    response=$(dns_http_get "$api_url")
    if [ $? -eq 0 ]; then
        if echo "$response" | grep -q "^OK"; then
            dns_log_info "Successfully removed TXT record for $domain"
            return 0
        elif echo "$response" | grep -q "^KO"; then
            dns_log_error "DuckDNS API returned error for $domain"
            return 1
        else
            dns_log_error "Unexpected response from DuckDNS API: $response"
            return 1
        fi
    else
        dns_log_error "Failed to connect to DuckDNS API"
        return 1
    fi
}

dns_duckdns_test() {
    dns_log_info "Testing DuckDNS API connectivity"
    duckdns_setup || return 1
    test_url="$DUCKDNS_API_BASE?domains=test&token=$DUCKDNS_TOKEN&verbose=true"
    response=$(dns_http_get "$test_url")
    if [ $? -ne 0 ]; then
        dns_log_error "Failed to connect to DuckDNS API"
        return 1
    fi
    if echo "$response" | grep -E '^(OK|KO)' > /dev/null; then
        dns_log_info "DuckDNS API test successful (token is valid)"
        return 0
    else
        dns_log_error "Unexpected response from DuckDNS API: $response"
        return 1
    fi
}

dns_duckdns_check_domain() {
    domain="$1"

    if ! _duckdns_setup; then
        return 1
    fi

    subdomain=$(_duckdns_validate_domain "$domain")
    if [ $? -ne 0 ]; then
        return 1
    fi

    # Try to get current IP for the subdomain
    api_url="$DUCKDNS_API_BASE?domains=$subdomain&token=$DUCKDNS_TOKEN&verbose=true"

    response=$(dns_http_get "$api_url")

    if [ $? -eq 0 ] && echo "$response" | grep -q "^OK"; then
        dns_log_info "DuckDNS subdomain $subdomain exists and is accessible"
        return 0
    else
        dns_log_error "DuckDNS subdomain $subdomain does not exist or is not accessible"
        dns_log_error "Please create the subdomain at https://www.duckdns.org/"
        return 1
    fi
}
