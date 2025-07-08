#!/bin/sh
#
# DNS Hook Script for ACME DNS-01 Challenge
# This script handles DNS record manipulation for various providers
#

# Configuration - Load from renew.cfg
LOCALDIR=$(dirname "$(readlink -f "$0")")
if [ -r "$LOCALDIR/renew.cfg" ]; then
    . "$LOCALDIR/renew.cfg"
fi

# DNS Provider functions
cloudflare_setup() {
    local domain="$1"
    local txt_value="$2"
    
    # Extract base domain for zone lookup
    # For esxi.offlinenode.net -> offlinenode.net
    # For *.offlinenode.net -> offlinenode.net  
    local base_domain=$(echo "$domain" | sed 's/^\*\.//')
    # Get the last two parts of the domain (assumes .com/.net/.org etc)
    base_domain=$(echo "$base_domain" | awk -F. '{if(NF>=2) print $(NF-1)"."$NF; else print $0}')
    
    # Validate API token is set
    if [ -z "$CF_API_TOKEN" ]; then
        echo "Error: CF_API_TOKEN not set in configuration"
        return 1
    fi
    
    # Get zone ID - Use hostname directly instead of IP resolution
    local zone_response=$(wget -qO- --no-check-certificate --header="Authorization: Bearer $CF_API_TOKEN" \
        --header="Content-Type: application/json" \
        "https://api.cloudflare.com/client/v4/zones?name=$base_domain" 2>/dev/null)
    
    local zone_id=$(echo "$zone_response" | python -c "import sys, json; data=json.load(sys.stdin); print(data['result'][0]['id'] if data['result'] else '')" 2>/dev/null)
    
    if [ -z "$zone_id" ]; then
        echo "Error: Could not get zone ID for $base_domain. Check API token permissions and domain access."
        return 1
    fi
    
    # Add TXT record - Use hostname directly  
    local record_response=$(wget -qO- --no-check-certificate --header="Authorization: Bearer $CF_API_TOKEN" \
        --header="Content-Type: application/json" \
        --post-data="{\"type\":\"TXT\",\"name\":\"_acme-challenge.$domain\",\"content\":\"$txt_value\",\"ttl\":120}" \
        "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" 2>/dev/null)
    
    local record_id=$(echo "$record_response" | python -c "import sys, json; data=json.load(sys.stdin); print(data['result']['id'] if data['success'] else '')" 2>/dev/null)
    
    if [ -z "$record_id" ]; then
        echo "Error: Could not create TXT record for $domain. Check API token permissions for DNS edit."
        return 1
    fi
    
    # Store record ID for cleanup
    echo "$record_id" > "/tmp/acme_dns_record_${domain}"
    echo "DNS TXT record created for $domain (ID: $record_id)"
}

cloudflare_cleanup() {
    local domain="$1"
    local record_file="/tmp/acme_dns_record_${domain}"
    
    if [ -f "$record_file" ]; then
        local record_id=$(cat "$record_file")
        # Extract base domain for zone lookup  
        local base_domain=$(echo "$domain" | sed 's/^\*\.//')
        # Get the last two parts of the domain (assumes .com/.net/.org etc)
        base_domain=$(echo "$base_domain" | awk -F. '{if(NF>=2) print $(NF-1)"."$NF; else print $0}')
        
        # Get zone ID - Use hostname directly for cleanup
        local zone_id=$(wget -qO- --no-check-certificate --header="Authorization: Bearer $CF_API_TOKEN" \
            --header="Content-Type: application/json" \
            "https://api.cloudflare.com/client/v4/zones?name=$base_domain" | \
            python -c "import sys, json; data=json.load(sys.stdin); print(data['result'][0]['id'] if data['result'] else '')" 2>/dev/null)
        
        if [ -n "$zone_id" ] && [ -n "$record_id" ]; then
            # Note: BusyBox wget doesn't support DELETE method
            # The TXT record has TTL=120 seconds and will auto-expire quickly
            echo "DNS TXT record cleanup skipped (record will auto-expire) for $domain"
        fi
        
        rm -f "$record_file"
    fi
}

route53_setup() {
    local domain="$1"
    local txt_value="$2"
    
    # Extract base domain for hosted zone lookup
    local base_domain=$(echo "$domain" | sed 's/^\*\.//')
    
    # Get hosted zone ID
    local zone_id=$(aws route53 list-hosted-zones-by-name --dns-name "$base_domain" --query "HostedZones[0].Id" --output text 2>/dev/null | cut -d'/' -f3)
    
    if [ -z "$zone_id" ] || [ "$zone_id" = "None" ]; then
        echo "Error: Could not get hosted zone ID for $base_domain"
        return 1
    fi
    
    # Create change batch
    local change_batch=$(cat << EOF
{
    "Changes": [{
        "Action": "CREATE",
        "ResourceRecordSet": {
            "Name": "_acme-challenge.$domain",
            "Type": "TXT",
            "TTL": 60,
            "ResourceRecords": [{"Value": "\"$txt_value\""}]
        }
    }]
}
EOF
)
    
    # Apply change
    local change_id=$(aws route53 change-resource-record-sets --hosted-zone-id "$zone_id" --change-batch "$change_batch" --query "ChangeInfo.Id" --output text 2>/dev/null)
    
    if [ -z "$change_id" ]; then
        echo "Error: Could not create TXT record for $domain"
        return 1
    fi
    
    echo "$change_id" > "/tmp/acme_dns_change_${domain}"
    echo "DNS TXT record created for $domain (Change ID: $change_id)"
}

route53_cleanup() {
    local domain="$1"
    local txt_value="$2"
    
    # Extract base domain for hosted zone lookup
    local base_domain=$(echo "$domain" | sed 's/^\*\.//')
    
    # Get hosted zone ID
    local zone_id=$(aws route53 list-hosted-zones-by-name --dns-name "$base_domain" --query "HostedZones[0].Id" --output text 2>/dev/null | cut -d'/' -f3)
    
    if [ -n "$zone_id" ] && [ "$zone_id" != "None" ]; then
        # Create change batch for deletion
        local change_batch=$(cat << EOF
{
    "Changes": [{
        "Action": "DELETE",
        "ResourceRecordSet": {
            "Name": "_acme-challenge.$domain",
            "Type": "TXT",
            "TTL": 60,
            "ResourceRecords": [{"Value": "\"$txt_value\""}]
        }
    }]
}
EOF
)
        
        aws route53 change-resource-record-sets --hosted-zone-id "$zone_id" --change-batch "$change_batch" >/dev/null 2>&1
        echo "DNS TXT record deleted for $domain"
    fi
    
    rm -f "/tmp/acme_dns_change_${domain}"
}

# Manual DNS provider (for testing or manual DNS management)
manual_setup() {
    local domain="$1"
    local txt_value="$2"
    
    echo "============================================"
    echo "Manual DNS Challenge Setup Required"
    echo "============================================"
    echo "Domain: $domain"
    echo "TXT Record Name: _acme-challenge.$domain"
    echo "TXT Record Value: $txt_value"
    echo ""
    echo "Please create the above TXT record in your DNS provider."
    echo "Press Enter when the record is created and has propagated..."
    read -r
}

manual_cleanup() {
    local domain="$1"
    
    echo "============================================"
    echo "Manual DNS Challenge Cleanup"
    echo "============================================"
    echo "Domain: $domain"
    echo "TXT Record Name: _acme-challenge.$domain"
    echo ""
    echo "You can now remove the TXT record from your DNS provider."
    echo "Press Enter to continue..."
    read -r
}

# Main script logic
ACTION="$1"
DOMAIN="$2"
TOKEN="$3"
KEY_AUTH="$4"

# Calculate TXT record value from environment variable set by acme_tiny.py
TXT_VALUE="$ACME_TXT_VALUE"

case "$ACTION" in
    "setup")
        echo "Setting up DNS challenge for $DOMAIN..."
        case "$DNS_PROVIDER" in
            "cloudflare")
                cloudflare_setup "$DOMAIN" "$TXT_VALUE"
                ;;
            "route53")
                route53_setup "$DOMAIN" "$TXT_VALUE"
                ;;
            "manual")
                manual_setup "$DOMAIN" "$TXT_VALUE"
                ;;
            *)
                echo "Error: Unsupported DNS provider: $DNS_PROVIDER"
                echo "Supported providers: cloudflare, route53, manual"
                exit 1
                ;;
        esac
        ;;
    "cleanup")
        echo "Cleaning up DNS challenge for $DOMAIN..."
        case "$DNS_PROVIDER" in
            "cloudflare")
                cloudflare_cleanup "$DOMAIN"
                ;;
            "route53")
                route53_cleanup "$DOMAIN" "$TXT_VALUE"
                ;;
            "manual")
                manual_cleanup "$DOMAIN"
                ;;
            *)
                echo "Error: Unsupported DNS provider: $DNS_PROVIDER"
                exit 1
                ;;
        esac
        ;;
    *)
        echo "Usage: $0 {setup|cleanup} domain token [key_auth]"
        exit 1
        ;;
esac
