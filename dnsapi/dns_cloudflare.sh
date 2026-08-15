# Cloudflare DNS API Provider
# Requires: CF_API_TOKEN or CF_API_KEY + CF_EMAIL
#

# Provider information
dns_cloudflare_info() {
    log "Cloudflare DNS API Provider"
    log "Website: https://cloudflare.com"
    log "Documentation: https://developers.cloudflare.com/api/operations/dns-records-for-a-zone-create-dns-record"
    log ""
    log "Required Environment Variables:"
    log "  CF_API_TOKEN     - Cloudflare API Token (recommended)"
    log "  OR"
    log "  CF_API_KEY       - Cloudflare Global API Key"
    log "  CF_EMAIL         - Cloudflare account email"
    log ""
    log "Optional Settings:"
    log "  CF_TTL           - TTL for DNS records (default: 120)"
    log "  CF_PROXY         - Enable Cloudflare proxy (default: false)"
}

# Cloudflare API endpoints
CF_API_BASE="https://api.cloudflare.com/client/v4"

# Default settings
CF_TTL=${CF_TTL:-120}
CF_PROXY=${CF_PROXY:-false}

# Protected temp directory for cross-invocation state (record/zone IDs).
_CF_TMP_DIR="/tmp/acme_w2c"

_cf_ensure_tmp() {
    # 1. Remove the path unconditionally if it is a symlink.
    if [ -L "$_CF_TMP_DIR" ]; then
        log "Warning: Symlink found at $_CF_TMP_DIR — removing"
        rm -f "$_CF_TMP_DIR" \
            || { log "Error: Cannot remove symlink at $_CF_TMP_DIR; aborting"; return 1; }
    fi

    # 2. If a directory already exists, verify it is owned by root with mode 700.
    #    Any deviation is treated as a potential compromise indicator: destroy the
    #    directory and recreate it rather than continuing to use a suspect path.
    if [ -d "$_CF_TMP_DIR" ]; then
        _ct_ls=$(ls -ld "$_CF_TMP_DIR" 2>/dev/null)
        _ct_perm=$(printf '%s' "$_ct_ls" | cut -c1-10)
        _ct_owner=$(printf '%s' "$_ct_ls" | awk '{print $3}')
        if [ "$_ct_perm" != "drwx------" ] || [ "$_ct_owner" != "root" ]; then
            log "Warning: Temp dir unsafe (perm=$_ct_perm owner=$_ct_owner) — removing and recreating"
            rm -rf "$_CF_TMP_DIR" \
                || { log "Error: Cannot remove unsafe temp dir; aborting to prevent symlink-follow"; return 1; }
        fi
    fi

    # 3. (Re-)create when absent.  Use plain mkdir — not -p — so that a symlink
    #    or file raced into place between the check above and now causes a hard
    #    failure rather than being silently traversed.
    if [ ! -d "$_CF_TMP_DIR" ]; then
        mkdir "$_CF_TMP_DIR" \
            || { log "Error: Cannot create temp dir $_CF_TMP_DIR"; return 1; }
        chmod 700 "$_CF_TMP_DIR" \
            || { log "Error: Cannot set permissions on $_CF_TMP_DIR"; return 1; }
    fi
}

# State helpers: read/write/remove a value for ROLE ($1) / DOMAIN ($2) [/ VALUE ($3)].
# The directory is validated as root-owned 700 by _cf_ensure_tmp before any of these
# are called, so predictable filenames inside it are safe from unprivileged attackers.
_cf_state_write() { printf '%s\n' "$3" > "$_CF_TMP_DIR/cf_${1}_${2}.id"; }
_cf_state_read()  { cat "$_CF_TMP_DIR/cf_${1}_${2}.id" 2>/dev/null; }
_cf_state_rm()    { rm -f "$_CF_TMP_DIR/cf_${1}_${2}.id"; }

# Authentication setup
_cf_setup_auth() {
    if [ -n "${CF_API_TOKEN:-}" ]; then
        log "Debug: Using Cloudflare API Token authentication"
        CF_AUTH_HEADER="Authorization: Bearer $CF_API_TOKEN"
        return 0
    elif [ -n "${CF_API_KEY:-}" ] && [ -n "${CF_EMAIL:-}" ]; then
        log "Debug: Using Cloudflare Global API Key authentication"
        CF_AUTH_HEADER="X-Auth-Key: $CF_API_KEY"
        CF_EMAIL_HEADER="X-Auth-Email: $CF_EMAIL"
        return 0
    else
        log "Error: Cloudflare credentials not found. Please set CF_API_TOKEN or (CF_API_KEY + CF_EMAIL)"
        return 1
    fi
}

# Helper: Extract base domain from FQDN (e.g., sub.domain.example.com -> example.com)
cf_get_base_domain() {
    fqdn="$1"
    # Use awk to get the last two labels (handles most cases)
    echo "$fqdn" | awk -F. '{if (NF>=2) print $(NF-1)"."$NF; else print $0}'
}

# Get zone ID for domain
_cf_get_zone_id() {
    domain="$1"
    base_domain="$(cf_get_base_domain "$domain")"

    log "Debug: [CF] Looking up zone for base domain: $base_domain"
    # Try exact match first
    zone_response=""
    headers="$CF_AUTH_HEADER"
    [ -n "$CF_EMAIL_HEADER" ] && headers="$headers
$CF_EMAIL_HEADER"
    headers="$headers
Content-Type: application/json"
    zone_response=$(dns_http_get "$CF_API_BASE/zones?name=$base_domain" "$headers")
    log "Debug: [CF] Zone lookup response: $zone_response"

    zone_id=$(dns_json_get "$zone_response" "result.0.id")

    if [ -n "$zone_id" ] && [ "$zone_id" != "null" ]; then
        log "Debug: [CF] Found zone_id: $zone_id for $base_domain"
        echo "$zone_id"
        return 0
    fi

    # Try parent domains (should rarely be needed)
    parent_domain="$base_domain"
    while [ "$(echo "$parent_domain" | awk -F'.' '{print NF}')" -gt 2 ]; do
        parent_domain=$(echo "$parent_domain" | cut -d. -f2-)
        log "Debug: [CF] Trying parent domain: $parent_domain"
        if [ -n "$CF_EMAIL_HEADER" ]; then
            headers="$CF_AUTH_HEADER
$CF_EMAIL_HEADER
Content-Type: application/json"
        else
            headers="$CF_AUTH_HEADER
Content-Type: application/json"
        fi
        zone_response=$(dns_http_get "$CF_API_BASE/zones?name=$parent_domain" "$headers")
        log "Debug: [CF] Parent zone lookup response: $zone_response"
        zone_id=$(dns_json_get "$zone_response" "result.0.id")
        if [ -n "$zone_id" ] && [ "$zone_id" != "null" ]; then
            log "Debug: [CF] Found parent zone_id: $zone_id for $parent_domain"
            echo "$zone_id"
            return 0
        fi
    done

    log "Error: Could not find Cloudflare zone for domain: $base_domain"
    return 1
}

# Get existing TXT record ID
_cf_get_txt_record_id() {
    zone_id="$1"
    record_name="$2"
    txt_value="$3"

    log "Debug: [CF] Looking for TXT record in zone $zone_id with name $record_name and value $txt_value"
    records_response=""
    headers="$CF_AUTH_HEADER"
    [ -n "$CF_EMAIL_HEADER" ] && headers="$headers
$CF_EMAIL_HEADER"
    headers="$headers
Content-Type: application/json"
    records_response=$(dns_http_get "$CF_API_BASE/zones/$zone_id/dns_records?type=TXT&name=$record_name" "$headers")
    log "Debug: [CF] TXT record lookup response: $records_response"

    i=0
    max_iter=20
    while [ $i -lt $max_iter ]; do
        record_id=$(dns_json_get "$records_response" "result.$i.id")
        record_content=$(dns_json_get "$records_response" "result.$i.content")

        if [ -z "$record_id" ] || [ "$record_id" = "null" ]; then
            break
        fi

        if [ "$record_content" = "$txt_value" ]; then
            log "Debug: [CF] Found matching TXT record id: $record_id"
            echo "$record_id"
            return 0
        fi

        i=$((i + 1))
    done

    if [ $i -ge $max_iter ]; then
        log "Warning: [CF] TXT record search exceeded $max_iter iterations, possible malformed API response."
    fi

    return 1
}

# Add TXT record
dns_cloudflare_add() {
    domain="$1"
    txt_value="$2"

    log "Debug: [CF] Starting dns_cloudflare_add for $domain"
    _cf_setup_auth || return 1

    record_name="_acme-challenge.$domain"
    zone_id=""

    # Always use base domain for zone lookup
    base_domain="$(cf_get_base_domain "$domain")"
    log "Debug: [CF] Using base domain for zone lookup: $base_domain"
    zone_id=$(_cf_get_zone_id "$base_domain")
    if [ -z "$zone_id" ]; then
        log "Error: [CF] No zone_id found for $base_domain"
        return 1
    fi

    log "Debug: [CF] Found Cloudflare zone ID: $zone_id"

    # Check if record already exists
    existing_record_id=""
    existing_record_id=$(_cf_get_txt_record_id "$zone_id" "$record_name" "$txt_value")

    if [ -n "$existing_record_id" ]; then
        log "Cloudflare TXT record already exists: $existing_record_id"
        _cf_ensure_tmp || return 1
        _cf_state_write "record" "$domain" "$existing_record_id"
        return 0
    fi

    # Create new TXT record
    record_data="{\n        \"type\": \"TXT\",\n        \"name\": \"$record_name\",\n        \"content\": \"$txt_value\",\n        \"ttl\": $CF_TTL,\n        \"proxied\": $CF_PROXY\n    }"

    log "Debug: [CF] Creating new TXT record: $record_data"
    create_response=""
    headers="$CF_AUTH_HEADER"
    [ -n "$CF_EMAIL_HEADER" ] && headers="$headers
$CF_EMAIL_HEADER"
    headers="$headers
Content-Type: application/json"
    create_response=$(dns_http_post "$CF_API_BASE/zones/$zone_id/dns_records" "$record_data" "$headers")
    log "Debug: [CF] TXT record create response: $create_response"

    record_id=$(dns_json_get "$create_response" "result.id")
    success=$(dns_json_get "$create_response" "success")
    # Normalize success to lowercase for comparison (BusyBox/ESXi compatible)
    success_lc=$(echo "$success" | sed 'y/ABCDEFGHIJKLMNOPQRSTUVWXYZ/abcdefghijklmnopqrstuvwxyz/')

    if { [ "$success_lc" = "true" ] || [ "$success" = "1" ]; } && [ -n "$record_id" ] && [ "$record_id" != "null" ]; then
        log "Created Cloudflare TXT record: $record_id"
        _cf_ensure_tmp || return 1
        _cf_state_write "record" "$domain" "$record_id"
        _cf_state_write "zone" "$domain" "$zone_id"
        return 0
    else
        error_msg=$(dns_json_get "$create_response" "errors.0.message")
        # Fallback: if no error message but record_id exists, treat as success
        if [ -z "$error_msg" ] && [ -n "$record_id" ] && [ "$record_id" != "null" ]; then
            log "Created Cloudflare TXT record (fallback): $record_id"
            _cf_ensure_tmp || return 1
            _cf_state_write "record" "$domain" "$record_id"
            _cf_state_write "zone" "$domain" "$zone_id"
            return 0
        fi
        log "Error: Failed to create Cloudflare TXT record: $error_msg"
        return 1
    fi
}

# Remove TXT record
dns_cloudflare_rm() {
    domain="$1"
    txt_value="$2"

    _cf_setup_auth || return 1

    _cf_ensure_tmp || return 1

    # Retrieve cached IDs written by dns_cloudflare_add.
    # State files have unpredictable names; pointer files record where to find them.
    record_id=""
    zone_id=""
    record_id=$(_cf_state_read "record" "$domain")
    zone_id=$(_cf_state_read "zone" "$domain")

    # If we don't have the IDs, try to find them
    if [ -z "$zone_id" ]; then
        base_domain="$(cf_get_base_domain "$domain")"
        zone_id=$(_cf_get_zone_id "$base_domain")
        if [ -z "$zone_id" ]; then
            log "Warning: Could not find zone ID for cleanup"
            _cf_state_rm "record" "$domain"
            _cf_state_rm "zone" "$domain"
            return 0
        fi
    fi

    if [ -z "$record_id" ] && [ -n "$txt_value" ]; then
        record_id=$(_cf_get_txt_record_id "$zone_id" "_acme-challenge.$domain" "$txt_value")
    fi

    if [ -n "$record_id" ] && [ "$record_id" != "null" ]; then
        log "Debug: Deleting Cloudflare record ID: $record_id"

        delete_response=""
        if [ -n "$CF_EMAIL_HEADER" ]; then
            delete_response=$(dns_http_delete "$CF_API_BASE/zones/$zone_id/dns_records/$record_id" "$CF_AUTH_HEADER" "$CF_EMAIL_HEADER" "Content-Type: application/json")
        else
            delete_response=$(dns_http_delete "$CF_API_BASE/zones/$zone_id/dns_records/$record_id" "$CF_AUTH_HEADER" "Content-Type: application/json")
        fi

        success=$(dns_json_get "$delete_response" "success")

        if [ "$success" = "true" ]; then
            log "Deleted Cloudflare TXT record."
        else
            error_msg=$(dns_json_get "$delete_response" "errors.0.message")
            log "Warning: Failed to delete Cloudflare TXT record: $error_msg"
        fi
    else
        log "Warning: No Cloudflare record ID was found during cleanup; the record may already have been deleted."
    fi

    # Clean up per-invocation state files and their pointer files.
    _cf_state_rm "record" "$domain"
    _cf_state_rm "zone" "$domain"
    return 0
}

# Check if zone exists (override default implementation)
dns_zone_exists() {
    zone="$1"
    provider="$2"

    if [ "$provider" != "cloudflare" ]; then
        return 1
    fi

    _cf_setup_auth || return 1

    base_domain="$(cf_get_base_domain "$zone")"
    zone_id=$(_cf_get_zone_id "$base_domain")

    [ -n "$zone_id" ]
}

# Get zone for domain (override default implementation)
dns_cloudflare_get_zone() {
    domain="$1"

    _cf_setup_auth || return 1

    base_domain="$(cf_get_base_domain "$domain")"
    # Try exact match first
    zone_response=""
    # Fix: Pass all headers as a single string, not as multiple arguments
    headers="$CF_AUTH_HEADER"
    [ -n "$CF_EMAIL_HEADER" ] && headers="$headers
$CF_EMAIL_HEADER"
    headers="$headers
Content-Type: application/json"
    zone_response=$(dns_http_get "$CF_API_BASE/zones?name=$base_domain" "$headers")

    zone_name=$(dns_json_get "$zone_response" "result.0.name")

    if [ -n "$zone_name" ] && [ "$zone_name" != "null" ]; then
        echo "$zone_name"
        return 0
    fi

    # Try parent domains (should rarely be needed)
    parent_domain="$base_domain"
    while [ "$(echo "$parent_domain" | awk -F'.' '{print NF}')" -gt 2 ]; do
        parent_domain=$(echo "$parent_domain" | cut -d. -f2-)
        if [ -n "$CF_EMAIL_HEADER" ]; then
            headers="$CF_AUTH_HEADER
$CF_EMAIL_HEADER
Content-Type: application/json"
        else
            headers="$CF_AUTH_HEADER
Content-Type: application/json"
        fi
        zone_response=$(dns_http_get "$CF_API_BASE/zones?name=$parent_domain" "$headers")
        zone_name=$(dns_json_get "$zone_response" "result.0.name")
        if [ -n "$zone_name" ] && [ "$zone_name" != "null" ]; then
            echo "$zone_name"
            return 0
        fi
    done

    return 1
}
