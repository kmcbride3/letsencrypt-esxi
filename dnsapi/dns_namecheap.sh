# Namecheap DNS API Provider
# Requires: NAMECHEAP_USERNAME, NAMECHEAP_API_KEY, NAMECHEAP_SOURCEIP
#

# Provider information
dns_namecheap_info() {
    echo "Namecheap DNS API Provider"
    echo "Website: https://namecheap.com"
    echo "Documentation: https://www.namecheap.com/support/api/intro/"
    echo ""
    echo "Required Environment Variables:"
    echo "  NAMECHEAP_USERNAME  - Namecheap account username"
    echo "  NAMECHEAP_API_KEY   - Namecheap API key"
    echo "  NAMECHEAP_SOURCEIP  - Your external IP address or URL to get it"
    echo ""
    echo "Optional Settings:"
    echo "  NAMECHEAP_TTL       - TTL for DNS records (default: 1800)"
    echo ""
    echo "Note: Due to Namecheap API limitations, all domain records will be read and reapplied. Ensure you have backups of your DNS records."
}

# Namecheap API endpoints
NC_API_BASE="https://api.namecheap.com/xml.response"

# Default settings
NAMECHEAP_TTL=${NAMECHEAP_TTL:-1800}

nc_setup_auth() {
    if [ -z "$NAMECHEAP_USERNAME" ]; then
        dns_log_error "NAMECHEAP_USERNAME not set"
        return 1
    fi
    if [ -z "$NAMECHEAP_API_KEY" ]; then
        dns_log_error "NAMECHEAP_API_KEY not set"
        return 1
    fi
    if [ -z "$NAMECHEAP_SOURCEIP" ]; then
        dns_log_error "NAMECHEAP_SOURCEIP not set"
        return 1
    fi
    if echo "$NAMECHEAP_SOURCEIP" | grep -q "^https\?://"; then
        dns_log_debug "Fetching source IP from URL: $NAMECHEAP_SOURCEIP"
        SOURCEIP=$(dns_http_get "$NAMECHEAP_SOURCEIP" | sed 's/[\r\n ]//g')
        if [ -z "$SOURCEIP" ]; then
            dns_log_error "Failed to get source IP from $NAMECHEAP_SOURCEIP"
            return 1
        fi
    else
        SOURCEIP="$NAMECHEAP_SOURCEIP"
    fi
    dns_log_debug "Using source IP: $SOURCEIP"
    return 0
}

nc_get_domain_parts() {
    domain="$1"
    test_domain="$domain"
    tld=""
    sld=""
    common_tlds="com net org info biz us uk co.uk me io"
    for tld_test in $common_tlds; do
        if echo "$domain" | grep -q "\.${tld_test}$"; then
            tld="$tld_test"
            sld=$(echo "$domain" | sed "s/\.${tld_test}$//")
            sld=$(echo "$sld" | sed 's/.*\.//g')
            break
        fi
    done
    if [ -z "$tld" ] || [ -z "$sld" ]; then
        tld=$(echo "$domain" | sed 's/.*\.//g')
        sld=$(echo "$domain" | sed 's/.*\.\([^.]*\)\.[^.]*$/\1/')
    fi
    echo "$sld $tld"
}

nc_get_host_records() {
    sld="$1"
    tld="$2"
    response=$(dns_http_get "${NC_API_BASE}?ApiUser=${NAMECHEAP_USERNAME}&ApiKey=${NAMECHEAP_API_KEY}&UserName=${NAMECHEAP_USERNAME}&Command=namecheap.domains.dns.getHosts&ClientIp=${SOURCEIP}&SLD=${sld}&TLD=${tld}")
    if [ $? -ne 0 ]; then
        dns_log_error "Failed to get DNS records for ${sld}.${tld}"
        return 1
    fi
    echo "$response"
}

nc_set_host_records() {
    sld="$1"
    tld="$2"
    host_records="$3"
    url="${NC_API_BASE}?ApiUser=${NAMECHEAP_USERNAME}&ApiKey=${NAMECHEAP_API_KEY}&UserName=${NAMECHEAP_USERNAME}&Command=namecheap.domains.dns.setHosts&ClientIp=${SOURCEIP}&SLD=${sld}&TLD=${tld}${host_records}"
    response=$(dns_http_get "$url")
    if [ $? -ne 0 ]; then
        dns_log_error "Failed to set DNS records for ${sld}.${tld}"
        return 1
    fi
    if echo "$response" | grep -q 'Status="ERROR"'; then
        error_msg=$(echo "$response" | sed -n 's/.*<Error Number="[^"]*">\([^<]*\).*/\1/p')
        dns_log_error "Namecheap API error: $error_msg"
        return 1
    fi
    return 0
}

# Add TXT record
dns_namecheap_add() {
    domain="$1"
    txt_value="$2"
    dns_log_info "Adding TXT record for $domain"
    nc_setup_auth || return 1
    domain_parts=$(nc_get_domain_parts "$domain")
    sld=$(echo "$domain_parts" | cut -d' ' -f1)
    tld=$(echo "$domain_parts" | cut -d' ' -f2)
    dns_log_debug "Domain parts - SLD: $sld, TLD: $tld"
    current_records=$(nc_get_host_records "$sld" "$tld")
    if [ $? -ne 0 ]; then
        return 1
    fi
    host_params=""
    record_count=1
    temp_file="/tmp/nc_records_$$"
    echo "$current_records" | grep '<host ' > "$temp_file" 2>/dev/null || true
    while read -r line; do
        if [ -n "$line" ]; then
            name=$(echo "$line" | sed -n 's/.*Name="\([^"]*\)".*/\1/p')
            type=$(echo "$line" | sed -n 's/.*Type="\([^"]*\)".*/\1/p')
            address=$(echo "$line" | sed -n 's/.*Address="\([^"]*\)".*/\1/p')
            ttl=$(echo "$line" | sed -n 's/.*TTL="\([^"]*\)".*/\1/p')
            if [ -n "$name" ] && [ -n "$type" ] && [ -n "$address" ]; then
                host_params="${host_params}&HostName${record_count}=${name}&RecordType${record_count}=${type}&Address${record_count}=${address}&TTL${record_count}=${ttl:-1800}"
                record_count=$((record_count + 1))
            fi
        fi
    done < "$temp_file"
    rm -f "$temp_file" 2>/dev/null || true
    record_name=$(echo "$domain" | sed "s/\.${sld}\.${tld}$//")
    if [ "$record_name" = "$domain" ]; then
        record_name="@"
    fi
    host_params="${host_params}&HostName${record_count}=${record_name}&RecordType${record_count}=TXT&Address${record_count}=${txt_value}&TTL${record_count}=${NAMECHEAP_TTL}"
    nc_set_host_records "$sld" "$tld" "$host_params" && dns_log_info "Successfully added TXT record for $domain" && return 0
    return 1
}

# Remove TXT record
dns_namecheap_rm() {
    domain="$1"
    txt_value="$2"
    dns_log_info "Removing TXT record for $domain"
    nc_setup_auth || return 1
    domain_parts=$(nc_get_domain_parts "$domain")
    sld=$(echo "$domain_parts" | cut -d' ' -f1)
    tld=$(echo "$domain_parts" | cut -d' ' -f2)
    current_records=$(nc_get_host_records "$sld" "$tld")
    if [ $? -ne 0 ]; then
        return 1
    fi
    host_params=""
    record_count=1
    record_name=$(echo "$domain" | sed "s/\.${sld}\.${tld}$//")
    if [ "$record_name" = "$domain" ]; then
        record_name="@"
    fi
    temp_file="/tmp/nc_records_$$"
    echo "$current_records" | grep '<host ' > "$temp_file" 2>/dev/null || true
    while read -r line; do
        if [ -n "$line" ]; then
            name=$(echo "$line" | sed -n 's/.*Name="\([^"]*\)".*/\1/p')
            type=$(echo "$line" | sed -n 's/.*Type="\([^"]*\)".*/\1/p')
            address=$(echo "$line" | sed -n 's/.*Address="\([^"]*\)".*/\1/p')
            ttl=$(echo "$line" | sed -n 's/.*TTL="\([^"]*\)".*/\1/p')
            if [ "$name" = "$record_name" ] && [ "$type" = "TXT" ] && [ "$address" = "$txt_value" ]; then
                dns_log_debug "Skipping TXT record to be removed: $name"
                continue
            fi
            if [ -n "$name" ] && [ -n "$type" ] && [ -n "$address" ]; then
                host_params="${host_params}&HostName${record_count}=${name}&RecordType${record_count}=${type}&Address${record_count}=${address}&TTL${record_count}=${ttl:-1800}"
                record_count=$((record_count + 1))
            fi
        fi
    done < "$temp_file"
    rm -f "$temp_file" 2>/dev/null || true
    nc_set_host_records "$sld" "$tld" "$host_params" && dns_log_info "Successfully removed TXT record for $domain" && return 0
    return 1
}

# Test provider connectivity
dns_namecheap_test() {
    dns_log_info "Testing Namecheap DNS API connectivity"
    nc_setup_auth || return 1
    response=$(dns_http_get "${NC_API_BASE}?ApiUser=${NAMECHEAP_USERNAME}&ApiKey=${NAMECHEAP_API_KEY}&UserName=${NAMECHEAP_USERNAME}&Command=namecheap.users.getAccountBalance&ClientIp=${SOURCEIP}")
    if [ $? -ne 0 ]; then
        dns_log_error "Failed to connect to Namecheap API"
        return 1
    fi
    if echo "$response" | grep -q 'Status="ERROR"'; then
        error_msg=$(echo "$response" | sed -n 's/.*<Error Number="[^"]*">\([^<]*\).*/\1/p')
        dns_log_error "Namecheap API error: $error_msg"
        return 1
    fi
    dns_log_info "Namecheap DNS API test successful"
    return 0
}
