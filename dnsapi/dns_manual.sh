#!/bin/sh
#
# Manual DNS API Provider
# For testing or when automatic DNS management is not available
#

# Provider information
dns_manual_info() {
    log "Manual DNS API Provider"
    log "Description: Interactive manual DNS record management"
    log ""
    log "Warning: This provider requires manual interaction and is NOT suitable for automated certificate renewals (cron jobs, etc.)"
    log ""
    log "This provider requires manual intervention to:"
    log "1. Create TXT records in your DNS provider's control panel"
    log "2. Verify DNS propagation"
    log "3. Clean up records after certificate issuance"
    log ""
    log "Use Cases:"
    log "- Testing certificate issuance process"
    log "- One-time certificate generation"
    log "- DNS providers not yet supported by automated providers"
    log "- Learning how DNS-01 challenges work"
    log ""
    log "For automated renewals, use providers like:"
    log "- cloudflare (Cloudflare DNS)"
    log ""
    log "Additional providers can be added by implementing the DNS API provider interface in this directory."
    log ""
    log "Optional Settings:"
    log "  MANUAL_AUTO_CONTINUE - Skip manual prompts (default: false)"
    log "  MANUAL_TTL          - Recommended TTL value (default: 120)"
}

# Default settings
MANUAL_TTL=${MANUAL_TTL:-120}
MANUAL_AUTO_CONTINUE=${MANUAL_AUTO_CONTINUE:-false}

# Add TXT record
# Usage: dns_manual_add <domain> <txt_value>
dns_manual_add() {
    domain="$1"
    txt_value="$2"
    record_name="_acme-challenge.$domain"

    log "Manual DNS challenge setup required for $domain"
    log "============================================"
    log "Manual DNS Challenge Setup Required"
    log "============================================"
    log "Domain: $domain"
    log "Record Type: TXT"
    log "Record Name: $record_name"
    log "Record Value: $txt_value"
    log "TTL: $MANUAL_TTL (seconds)"
    log ""
    log "Please create the above TXT record in your DNS provider's control panel."
    log ""
    log "Steps:"
    log "1. Log into your DNS provider's management interface"
    log "2. Navigate to DNS settings for your domain"
    log "3. Add a new TXT record with the details above"
    log "4. Save the changes"
    log "5. Wait for DNS propagation (usually 1-5 minutes)"
    log ""

    if [ "$MANUAL_AUTO_CONTINUE" = "true" ]; then
        log "Auto-continue mode enabled, proceeding without confirmation"
        return 0
    fi

    log "Press Enter when the record is created and has propagated..."
    read dummy

    log "Verifying DNS propagation..."
    if dns_check_propagation "$domain" "$txt_value" 180 15; then
        log "DNS propagation verified successfully"
        return 0
    else
        log "Warning: DNS propagation verification failed, but continuing anyway"
        log ""
        log "The verification failed, but this might be due to:"
        log "- DNS propagation delays"
        log "- Firewall blocking DNS queries"
        log "- Different DNS resolvers"
        log ""
        log "Press Enter to continue anyway, or Ctrl+C to abort..."
        read dummy
        return 0
    fi
}

# Remove TXT record
# Usage: dns_manual_rm <domain> <txt_value>
dns_manual_rm() {
    domain="$1"
    txt_value="$2"
    record_name="_acme-challenge.$domain"

    log "Manual DNS challenge cleanup for $domain"
    log "============================================"
    log "Manual DNS Challenge Cleanup"
    log "============================================"
    log "Domain: $domain"
    log "Record Type: TXT"
    log "Record Name: $record_name"
    if [ -n "$txt_value" ]; then
        log "Record Value: $txt_value"
    fi
    log ""
    log "You can now remove the TXT record from your DNS provider."
    log "This is optional as the record is no longer needed."
    log ""
    if [ "$MANUAL_AUTO_CONTINUE" = "true" ]; then
        log "Auto-continue mode enabled, cleanup message displayed"
        return 0
    fi
    log "Press Enter to continue..."
    read dummy
    return 0
}
