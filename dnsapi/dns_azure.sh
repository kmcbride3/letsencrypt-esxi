# Azure DNS API Provider
# Supports Service Principal, Managed Identity, and Bearer Token authentication
#

# Provider information
dns_azure_info() {
    echo "Azure DNS API Provider"
    echo "Website: https://azure.microsoft.com/services/dns/"
    echo "Documentation: https://docs.microsoft.com/en-us/rest/api/dns/"
    echo ""
    echo "Authentication Options:"
    echo ""
    echo "1. Service Principal (Recommended for automation):"
    echo "   AZUREDNS_SUBSCRIPTIONID - Azure Subscription ID"
    echo "   AZUREDNS_TENANTID       - Azure Tenant ID"
    echo "   AZUREDNS_APPID          - Azure App ID"
    echo "   AZUREDNS_CLIENTSECRET   - Azure Client Secret"
    echo ""
    echo "2. Managed Identity (For Azure resources):"
    echo "   AZUREDNS_SUBSCRIPTIONID - Azure Subscription ID"
    echo "   AZUREDNS_MANAGEDIDENTITY=true"
    echo ""
    echo "3. Bearer Token (Advanced scenarios):"
    echo "   AZUREDNS_SUBSCRIPTIONID - Azure Subscription ID"
    echo "   AZUREDNS_TENANTID       - Azure Tenant ID"
    echo "   AZUREDNS_BEARERTOKEN    - Pre-obtained Bearer Token"
    echo ""
    echo "Optional Settings:"
    echo "   AZURE_TTL               - TTL for DNS records (default: 3600)"
}

AZURE_API_BASE="https://management.azure.com"
AZURE_LOGIN_BASE="https://login.microsoftonline.com"
AZURE_TTL=${AZURE_TTL:-3600}

# Authentication setup
_azure_setup_auth() {
    if [ -z "$AZUREDNS_SUBSCRIPTIONID" ]; then
        dns_log_error "AZUREDNS_SUBSCRIPTIONID not set"
        return 1
    fi
    if [ -n "$AZUREDNS_BEARERTOKEN" ]; then
        dns_log_debug "Using Bearer Token authentication"
        AZURE_AUTH_METHOD="bearer"
        return 0
    elif [ "$AZUREDNS_MANAGEDIDENTITY" = "true" ]; then
        dns_log_debug "Using Managed Identity authentication"
        AZURE_AUTH_METHOD="managed"
        return 0
    elif [ -n "$AZUREDNS_APPID" ] && [ -n "$AZUREDNS_CLIENTSECRET" ] && [ -n "$AZUREDNS_TENANTID" ]; then
        dns_log_debug "Using Service Principal authentication"
        AZURE_AUTH_METHOD="service_principal"
        return 0
    else
        dns_log_error "No valid Azure authentication method configured"
        return 1
    fi
}

# Get OAuth2 access token
_azure_get_access_token() {
    case "$AZURE_AUTH_METHOD" in
        bearer)
            echo "$AZUREDNS_BEARERTOKEN"
            return 0
            ;;
        managed)
            if [ -n "$IDENTITY_ENDPOINT" ] && [ -n "$IDENTITY_HEADER" ]; then
                response=$(dns_http_get "$IDENTITY_ENDPOINT?resource=https://management.azure.com/&api-version=2019-08-01" "X-IDENTITY-HEADER: $IDENTITY_HEADER\nMetadata: true")
            else
                response=$(dns_http_get "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com/" "Metadata: true")
            fi
            token=$(echo "$response" | sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
            if [ -n "$token" ]; then
                echo "$token"
                return 0
            fi
            dns_log_error "Failed to get managed identity token"
            return 1
            ;;
        service_principal)
            token_url="$AZURE_LOGIN_BASE/$AZUREDNS_TENANTID/oauth2/token"
            post_data="grant_type=client_credentials&client_id=$AZUREDNS_APPID&client_secret=$AZUREDNS_CLIENTSECRET&resource=https://management.azure.com/"
            response=$(dns_http_post "$token_url" "$post_data" "Content-Type: application/x-www-form-urlencoded")
            token=$(echo "$response" | sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
            if [ -n "$token" ]; then
                echo "$token"
                return 0
            fi
            dns_log_error "Failed to get service principal token"
            return 1
            ;;
        *)
            dns_log_error "Unknown authentication method: $AZURE_AUTH_METHOD"
            return 1
            ;;
    esac
}

# Find DNS zone for domain (tries parent domains)
_azure_find_zone() {
    domain="$1"
    access_token="$2"
    test_domain="$domain"
    while [ -n "$test_domain" ]; do
        zone_url="$AZURE_API_BASE/subscriptions/$AZUREDNS_SUBSCRIPTIONID/providers/Microsoft.Network/dnszones/$test_domain?api-version=2018-05-01"
        headers="Authorization: Bearer $access_token\nContent-Type: application/json"
        response=$(dns_http_get "$zone_url" "$headers")
        if echo "$response" | grep -q '"name"'; then
            echo "$test_domain"
            return 0
        fi
        if [ "$(echo "$test_domain" | awk -F'.' '{print NF}')" -le 2 ]; then
            break
        fi
        test_domain=$(echo "$test_domain" | cut -d. -f2-)
    done
    dns_log_error "Could not find Azure DNS zone for domain: $domain"
    return 1
}

# Get resource group for DNS zone
_azure_get_resource_group() {
    zone_name="$1"
    access_token="$2"
    zones_url="$AZURE_API_BASE/subscriptions/$AZUREDNS_SUBSCRIPTIONID/providers/Microsoft.Network/dnszones?api-version=2018-05-01"
    headers="Authorization: Bearer $access_token\nContent-Type: application/json"
    response=$(dns_http_get "$zones_url" "$headers")
    temp_file="/tmp/azure_zones_$$"
    echo "$response" | awk -F',' '{for(i=1;i<=NF;i++) print $i}' > "$temp_file" 2>/dev/null || true
    found_zone=false
    while read -r line; do
        if echo "$line" | grep -q "\"name\":\"$zone_name\""; then
            found_zone=true
        elif [ "$found_zone" = "true" ] && echo "$line" | grep -q '"id"'; then
            resource_group=$(echo "$line" | sed -n 's|.*/resourceGroups/\([^/]*\)/.*|\1|p')
            if [ -n "$resource_group" ]; then
                echo "$resource_group"
                rm -f "$temp_file" 2>/dev/null || true
                return 0
            fi
        fi
    done < "$temp_file"
    rm -f "$temp_file" 2>/dev/null || true
    dns_log_error "Could not find resource group for zone: $zone_name"
    return 1
}

# Add TXT record
dns_azure_add() {
    domain="$1"
    txt_value="$2"
    dns_log_debug "[AZURE] Starting dns_azure_add for $domain"
    _azure_setup_auth || return 1
    access_token=$(_azure_get_access_token)
    [ -z "$access_token" ] && return 1
    zone_name=$(_azure_find_zone "$domain" "$access_token")
    [ -z "$zone_name" ] && return 1
    resource_group=$(_azure_get_resource_group "$zone_name" "$access_token")
    [ -z "$resource_group" ] && return 1
    record_name=$(echo "$domain" | sed "s/\\.${zone_name}\$//")
    [ -z "$record_name" ] || [ "$record_name" = "$domain" ] && record_name="@"
    dns_log_debug "[AZURE] Zone: $zone_name, Resource Group: $resource_group, Record: $record_name"
    record_data="{\n  \"properties\": {\n    \"TTL\": $AZURE_TTL,\n    \"TXTRecords\": [ { \"value\": [\"$txt_value\"] } ]\n  }\n}"
    record_url="$AZURE_API_BASE/subscriptions/$AZUREDNS_SUBSCRIPTIONID/resourceGroups/$resource_group/providers/Microsoft.Network/dnszones/$zone_name/TXT/$record_name?api-version=2018-05-01"
    headers="Authorization: Bearer $access_token\nContent-Type: application/json"
    response=$(dns_http_request "PUT" "$record_url" "$record_data" "$headers")
    if echo "$response" | grep -q '"id"'; then
        dns_log_info "Created Azure TXT record for $domain"
        return 0
    else
        error_msg=$(echo "$response" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        dns_log_error "Failed to create Azure TXT record: $error_msg"
        return 1
    fi
}

# Remove TXT record
dns_azure_rm() {
    domain="$1"
    txt_value="$2"
    dns_log_debug "[AZURE] Starting dns_azure_rm for $domain"
    _azure_setup_auth || return 1
    access_token=$(_azure_get_access_token)
    [ -z "$access_token" ] && return 1
    zone_name=$(_azure_find_zone "$domain" "$access_token")
    [ -z "$zone_name" ] && return 1
    resource_group=$(_azure_get_resource_group "$zone_name" "$access_token")
    [ -z "$resource_group" ] && return 1
    record_name=$(echo "$domain" | sed "s/\\.${zone_name}\$//")
    [ -z "$record_name" ] || [ "$record_name" = "$domain" ] && record_name="@"
    record_url="$AZURE_API_BASE/subscriptions/$AZUREDNS_SUBSCRIPTIONID/resourceGroups/$resource_group/providers/Microsoft.Network/dnszones/$zone_name/TXT/$record_name?api-version=2018-05-01"
    headers="Authorization: Bearer $access_token\nContent-Type: application/json"
    response=$(dns_http_request "DELETE" "$record_url" "" "$headers")
    if echo "$response" | grep -q '"id"'; then
        dns_log_info "Deleted Azure TXT record for $domain"
        return 0
    else
        error_msg=$(echo "$response" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        dns_log_warn "Failed to delete Azure TXT record: $error_msg"
        return 1
    fi
}

# Test provider connectivity
dns_azure_test() {
    dns_log_info "Testing Azure DNS API connectivity"
    _azure_setup_auth || return 1
    access_token=$(_azure_get_access_token)
    [ -z "$access_token" ] && return 1
    zones_url="$AZURE_API_BASE/subscriptions/$AZUREDNS_SUBSCRIPTIONID/providers/Microsoft.Network/dnszones?api-version=2018-05-01"
    headers="Authorization: Bearer $access_token\nContent-Type: application/json"
    response=$(dns_http_get "$zones_url" "$headers")
    if echo "$response" | grep -q '"value"'; then
        dns_log_info "Azure DNS API test successful"
        return 0
    else
        error_msg=$(echo "$response" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        dns_log_error "Azure DNS API error: $error_msg"
        return 1
    fi
}

