#!/bin/sh
#
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

# Azure API endpoints
AZURE_API_BASE="https://management.azure.com"
AZURE_LOGIN_BASE="https://login.microsoftonline.com"

# Default settings
AZURE_TTL=${AZURE_TTL:-3600}

# Authentication setup
_azure_setup_auth() {
    if [ -z "$AZUREDNS_SUBSCRIPTIONID" ]; then
        dns_log_error "AZUREDNS_SUBSCRIPTIONID not set"
        return 1
    fi

    # Check authentication method
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
            # Try Azure App Service/Function first
            if [ -n "$IDENTITY_ENDPOINT" ] && [ -n "$IDENTITY_HEADER" ]; then
                local response=$(dns_http_get "$IDENTITY_ENDPOINT?resource=https://management.azure.com/&api-version=2019-08-01" "X-IDENTITY-HEADER: $IDENTITY_HEADER
Metadata: true")
            else
                # Standard Azure VM Managed Identity
                local response=$(dns_http_get "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com/" "Metadata: true")
            fi

            if [ $? -eq 0 ]; then
                local token=$(echo "$response" | sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p')
                if [ -n "$token" ]; then
                    echo "$token"
                    return 0
                fi
            fi

            dns_log_error "Failed to get managed identity token"
            return 1
            ;;
        service_principal)
            local token_url="$AZURE_LOGIN_BASE/$AZUREDNS_TENANTID/oauth2/token"
            local post_data="grant_type=client_credentials&client_id=$AZUREDNS_APPID&client_secret=$AZUREDNS_CLIENTSECRET&resource=https://management.azure.com/"

            local response=$(dns_http_request "POST" "$token_url" "$post_data" "Content-Type: application/x-www-form-urlencoded")

            if [ $? -eq 0 ]; then
                local token=$(echo "$response" | sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p')
                if [ -n "$token" ]; then
                    echo "$token"
                    return 0
                fi
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

# Find DNS zone for domain
_azure_find_zone() {
    local domain="$1"
    local access_token="$2"

    # Try exact match first, then parent domains
    local test_domain="$domain"

    while [ -n "$test_domain" ]; do
        local zone_url="$AZURE_API_BASE/subscriptions/$AZUREDNS_SUBSCRIPTIONID/providers/Microsoft.Network/dnszones/$test_domain?api-version=2018-05-01"
        local response=$(dns_http_get "$zone_url" "Authorization: Bearer $access_token
Content-Type: application/json")

        if [ $? -eq 0 ] && echo "$response" | grep -q '"name"'; then
            echo "$test_domain"
            return 0
        fi

        # Try parent domain
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
    local zone_name="$1"
    local access_token="$2"

    local zones_url="$AZURE_API_BASE/subscriptions/$AZUREDNS_SUBSCRIPTIONID/providers/Microsoft.Network/dnszones?api-version=2018-05-01"
    local response=$(dns_http_get "$zones_url" "Authorization: Bearer $access_token
Content-Type: application/json")

    if [ $? -eq 0 ]; then
        # Parse response to find the resource group
        # Simplified JSON parsing for ESXi compatibility
        local temp_file="/tmp/azure_zones_$$"
        echo "$response" | awk -F',' '{for(i=1;i<=NF;i++) print $i}' > "$temp_file" 2>/dev/null || true

        local found_zone=false
        while read -r line; do
            if echo "$line" | grep -q "\"name\":\"$zone_name\""; then
                found_zone=true
            elif [ "$found_zone" = "true" ] && echo "$line" | grep -q '"id"'; then
                local resource_group=$(echo "$line" | sed -n 's|.*/resourceGroups/\\([^/]*\\)/.*|\\1|p')
                if [ -n "$resource_group" ]; then
                    echo "$resource_group"
                    rm -f "$temp_file" 2>/dev/null || true
                    return 0
                fi
            fi
        done < "$temp_file"
        rm -f "$temp_file" 2>/dev/null || true
    fi

    dns_log_error "Could not find resource group for zone: $zone_name"
    return 1
}

# Add TXT record
dns_azure_add() {
    local domain="$1"
    local txt_value="$2"

    dns_log_info "Adding TXT record for $domain"

    if ! _azure_setup_auth; then
        return 1
    fi

    local access_token=$(_azure_get_access_token)
    if [ $? -ne 0 ] || [ -z "$access_token" ]; then
        dns_log_error "Failed to get Azure access token"
        return 1
    fi

    # Find the DNS zone
    local zone_name=$(_azure_find_zone "$domain" "$access_token")
    if [ $? -ne 0 ]; then
        return 1
    fi

    # Get resource group
    local resource_group=$(_azure_get_resource_group "$zone_name" "$access_token")
    if [ $? -ne 0 ]; then
        return 1
    fi

    # Calculate record name
    local record_name=$(echo "$domain" | sed "s/\\.${zone_name}$//")
    if [ -z "$record_name" ] || [ "$record_name" = "$domain" ]; then
        record_name="@"
    fi

    dns_log_debug "Zone: $zone_name, Resource Group: $resource_group, Record: $record_name"

    # Create record set
    local record_data="{
        \"properties\": {
            \"TTL\": $AZURE_TTL,
            \"TXTRecords\": [
                {
                    \"value\": [\"$txt_value\"]
                }
            ]
        }
    }"

    local record_url="$AZURE_API_BASE/subscriptions/$AZUREDNS_SUBSCRIPTIONID/resourceGroups/$resource_group/providers/Microsoft.Network/dnszones/$zone_name/TXT/$record_name?api-version=2018-05-01"

    local response=$(dns_http_request "PUT" "$record_url" "$record_data" "Authorization: Bearer $access_token
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
dns_azure_rm() {
    local domain="$1"
    local txt_value="$2"

    dns_log_info "Removing TXT record for $domain"

    if ! _azure_setup_auth; then
        return 1
    fi

    local access_token=$(_azure_get_access_token)
    if [ $? -ne 0 ] || [ -z "$access_token" ]; then
        dns_log_error "Failed to get Azure access token"
        return 1
    fi

    # Find the DNS zone
    local zone_name=$(_azure_find_zone "$domain" "$access_token")
    if [ $? -ne 0 ]; then
        return 1
    fi

    # Get resource group
    local resource_group=$(_azure_get_resource_group "$zone_name" "$access_token")
    if [ $? -ne 0 ]; then
        return 1
    fi

    # Calculate record name
    local record_name=$(echo "$domain" | sed "s/\\.${zone_name}$//")
    if [ -z "$record_name" ] || [ "$record_name" = "$domain" ]; then
        record_name="@"
    fi

    # Delete the record set
    local record_url="$AZURE_API_BASE/subscriptions/$AZUREDNS_SUBSCRIPTIONID/resourceGroups/$resource_group/providers/Microsoft.Network/dnszones/$zone_name/TXT/$record_name?api-version=2018-05-01"

    local response=$(dns_http_request "DELETE" "$record_url" "" "Authorization: Bearer $access_token
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
dns_azure_test() {
    dns_log_info "Testing Azure DNS API connectivity"

    if ! _azure_setup_auth; then
        return 1
    fi

    local access_token=$(_azure_get_access_token)
    if [ $? -ne 0 ] || [ -z "$access_token" ]; then
        dns_log_error "Failed to get Azure access token"
        return 1
    fi

    # Test API connectivity
    local zones_url="$AZURE_API_BASE/subscriptions/$AZUREDNS_SUBSCRIPTIONID/providers/Microsoft.Network/dnszones?api-version=2018-05-01"
    local response=$(dns_http_get "$zones_url" "Authorization: Bearer $access_token
Content-Type: application/json")

    if [ $? -ne 0 ]; then
        dns_log_error "Failed to connect to Azure DNS API"
        return 1
    fi

    # Check for API errors
    if echo "$response" | grep -q '"error"'; then
        local error_msg=$(echo "$response" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p')
        dns_log_error "Azure DNS API error: $error_msg"
        return 1
    fi

    dns_log_info "Azure DNS API test successful"
    return 0
}
