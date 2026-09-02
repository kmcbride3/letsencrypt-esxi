#!/bin/sh
#
# DNS API Framework - Core functionality for DNS providers
# Main entry point for ACME DNS-01 challenges
# Provides standardized interface and common utilities for all DNS providers
#
# Usage: dns_api.sh <command> <domain> [txt_value]
# Commands: add, rm, wait, info, list, test
#

# ESXi-compatible path resolution
DNSAPIDIR=$(dirname "$(readlink -f "$0")")
LOCALDIR="$DNSAPIDIR/.."

# Parse command line arguments
COMMAND="$1"
DOMAIN="$2"
TOKEN="$3"
KEY_AUTH="$4"

# Shared logging helper for DNS helper scripts
log() {
    message="$*"

    case "$message" in
        Debug:*)
            [ "${DEBUG:-0}" = "1" ] || return 0
            ;;
    esac

    echo "$message" >&2
    if command -v logger >/dev/null 2>&1; then
        logger -p daemon.info -t "$0" "$message"
    fi
}

# Calculate TXT value from key authorization for DNS-01 challenges
calculate_txt_value() {
    key_auth="$1"
    if [ -z "$key_auth" ]; then
        return 1
    fi

    # Use the same calculation as acme_tiny.py: base64(sha256(key_auth))
    if which python3 >/dev/null 2>&1; then
        echo -n "$key_auth" | python3 -c "
import sys, hashlib, base64
data = sys.stdin.read().encode('utf8')
hash_digest = hashlib.sha256(data).digest()
result = base64.urlsafe_b64encode(hash_digest).decode('utf8').replace('=', '')
print(result)
"
    elif which python >/dev/null 2>&1; then
        echo -n "$key_auth" | python -c "
import sys, hashlib, base64
data = sys.stdin.read().encode('utf8')
hash_digest = hashlib.sha256(data).digest()
result = base64.urlsafe_b64encode(hash_digest).decode('utf8').replace('=', '')
print(result)
"
    else
        # Fallback using openssl (ESXi compatible)
        echo -n "$key_auth" | openssl dgst -sha256 -binary | openssl base64 -A | \
            sed 's/=//g' | sed 'y/\/+/_-/'
    fi
}

# For DNS-01 challenges, calculate TXT value from key authorization
if [ "$COMMAND" = "add" ] || [ "$COMMAND" = "rm" ] || [ "$COMMAND" = "wait" ]; then
    if [ -n "$KEY_AUTH" ]; then
        TXT_VALUE=$(calculate_txt_value "$KEY_AUTH")
        if [ -z "$TXT_VALUE" ]; then
            log "Error: Failed to calculate TXT value from key authorization"
            exit 1
        fi
    elif [ -n "$ACME_KEY_AUTH" ]; then
        # Fallback to environment variable
        TXT_VALUE=$(calculate_txt_value "$ACME_KEY_AUTH")
        if [ -z "$TXT_VALUE" ]; then
            log "Error: Failed to calculate TXT value from ACME_KEY_AUTH"
            exit 1
        fi
    else
        # Legacy: assume third parameter is already the TXT value
        TXT_VALUE="$TOKEN"
    fi
fi

# Load configuration from renew.cfg
if [ -r "$LOCALDIR/renew.cfg" ]; then
    . "$LOCALDIR/renew.cfg"
elif [ -r "$DNSAPIDIR/../renew.cfg" ]; then
    . "$DNSAPIDIR/../renew.cfg"
fi

# DNS API version
DNS_API_VERSION="1.2.0"

# Default settings that providers can override (hardcoded for simplicity)
DEFAULT_DNS_TIMEOUT=30
DEFAULT_TTL=120
DEFAULT_PROPAGATION_WAIT=120
DEFAULT_MAX_RETRIES=3
DEFAULT_RETRY_DELAY=5

log "Debug: DNS_PROVIDER is '$DNS_PROVIDER'"
# Redact credential value so it doesn't appear in syslog when DEBUG=1
log "Debug: CF_API_TOKEN is '${CF_API_TOKEN:+[set]}'"


_WGET_TLS_OPT=""
# Proactively probe if the compiled BusyBox binary supports the bypass flag
if wget --help 2>&1 | grep -q '\-\-no-check-certificate'; then
    _WGET_TLS_OPT="--no-check-certificate"
fi

# Validation functions
dns_validate_domain() {
    domain="$1"
    if [ -z "$domain" ]; then
        log "Error: Domain cannot be empty"
        return 1
    fi

    # Basic domain validation
    if ! echo "$domain" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?)*$'; then
        log "Error: Invalid domain format: $domain"
        return 1
    fi

    return 0
}

dns_validate_txt_value() {
    txt_value="$1"
    if [ -z "$txt_value" ]; then
        log "Error: TXT value cannot be empty"
        return 1
    fi

    # Validate base64-like encoding (basic check)
    if [ ${#txt_value} -lt 40 ]; then
        log "Error: TXT value appears to be too short (${#txt_value} chars)"
        return 1
    fi

    return 0
}

# DNS zone detection utilities
dns_get_zone() {
    domain="$1"
    provider="$2"

    # Try different zone detection strategies

    # Strategy 1: Direct domain match
    if dns_zone_exists "$domain" "$provider"; then
        echo "$domain"
        return 0
    fi

    # Strategy 2: Parent domains
    parent_domain="$domain"
    while [ "$(echo "$parent_domain" | awk -F'.' '{print NF}')" -gt 2 ]; do
        parent_domain=$(echo "$parent_domain" | cut -d. -f2-)
        if dns_zone_exists "$parent_domain" "$provider"; then
            echo "$parent_domain"
            return 0
        fi
    done

    # Strategy 3: Common patterns
    base_domain=$(echo "$domain" | awk -F. '{if(NF>=2) print $(NF-1)"."$NF; else print $0}')
    if dns_zone_exists "$base_domain" "$provider"; then
        echo "$base_domain"
        return 0
    fi

    log "Error: Could not determine DNS zone for domain: $domain"
    return 1
}

dns_http_get() {
    url="$1"
    headers="$2"
    timeout="${3:-$DEFAULT_DNS_TIMEOUT}"
    timeout="${timeout%%[^0-9]*}"

    log "Debug: HTTP GET: $url (timeout: ${timeout}s)"

    if ! which wget >/dev/null 2>&1; then
        log "Error: No HTTP client available (wget required)"
        return 127
    fi

    # Initialize parameters using our forced ESXi flag
    set -- -qO- "$_WGET_TLS_OPT"

    if [ -n "$headers" ]; then
        OLD_IFS="$IFS"
        IFS='
'
        for header in $headers; do
            set -- "$@" --header="$header"
        done
        IFS="$OLD_IFS"
    fi
    set -- "$@" "$url"

    if [ "${DEBUG:-0}" = "1" ]; then
        log "Debug: Final wget command: wget $*"
    fi

    if which timeout >/dev/null 2>&1; then
        response=$(timeout -t "$timeout" wget "$@" 2>&1)
        exit_code=$?
        if [ "${DEBUG:-0}" = "1" ]; then
            echo "Debug: Raw HTTP GET response:" >&2
            echo "$response" >&2
        fi
        if [ $exit_code -eq 124 ]; then
            log "Error: wget timed out after ${timeout}s"
            return 124
        fi
    else
        response=$(wget "$@" 2>&1)
        exit_code=$?
        if [ "${DEBUG:-0}" = "1" ]; then
            echo "Debug: Raw HTTP GET response:" >&2
            echo "$response" >&2
        fi
    fi

    if [ $exit_code -eq 0 ]; then
        log "Debug: HTTP GET response: $response"
        echo "$response"
        return 0
    else
        log "Debug: wget failed with exit code $exit_code: $response"
        return $exit_code
    fi
}


dns_http_post() {
    url="$1"
    data="$2"
    headers="$3"
    timeout="${4:-$DEFAULT_DNS_TIMEOUT}"
    timeout="${timeout%%[^0-9]*}"

    log "Debug: HTTP POST: $url (timeout: ${timeout}s)"

    py=python3
    which python3 >/dev/null 2>&1 || py=python

    response=$(DNS_HTTP_URL="$url" DNS_HTTP_DATA="$data" DNS_HTTP_HEADERS="$headers" DNS_HTTP_TIMEOUT="$timeout" \
        "$py" -c "
import os, ssl, sys
try:
    import urllib.request as urllib_request
    import urllib.error as urllib_error
except ImportError:
    import urllib2 as urllib_request
    urllib_error = urllib_request

headers = {}
for line in os.environ.get('DNS_HTTP_HEADERS', '').splitlines():
    if ':' in line:
        k, v = line.split(':', 1)
        headers[k.strip()] = v.strip()

# Initialize strict, secure TLS validation context
ctx = ssl.create_default_context()
ctx.check_hostname = True
ctx.verify_mode = ssl.CERT_REQUIRED

# Securely load ESXi's native trusted root store path
esxi_store = '/etc/vmware/ssl/castore.pem'
if os.path.exists(esxi_store) and os.path.getsize(esxi_store) > 0:
    ctx.load_verify_locations(cafile=esxi_store)

# Force standard HTTP POST by encoding payload data to raw bytes
post_bytes = os.environ.get('DNS_HTTP_DATA', '').encode('utf-8')
req = urllib_request.Request(os.environ['DNS_HTTP_URL'], data=post_bytes, headers=headers)
timeout = float(os.environ.get('DNS_HTTP_TIMEOUT') or 30)

try:
    resp = urllib_request.urlopen(req, timeout=timeout, context=ctx)
    data = resp.read()
    sys.stdout.write(data.decode('utf-8') if isinstance(data, bytes) else data)
except urllib_error.HTTPError as e:
    data = e.read()
    sys.stdout.write(data.decode('utf-8') if isinstance(data, bytes) else data)
except Exception as e:
    sys.stderr.write(str(e) + chr(10))
    sys.exit(1)
" 2>&1)
    exit_code=$?

    if [ $exit_code -eq 0 ]; then
        log "Debug: HTTP POST response: $response"
        echo "$response"
        return 0
    fi
    log "Debug: python POST failed with exit code $exit_code: $response"
    return $exit_code
}

dns_http_delete() {
    url="$1"
    headers="$2"
    timeout="${3:-$DEFAULT_DNS_TIMEOUT}"
    timeout="${timeout%%[^0-9]*}"

    log "Debug: HTTP DELETE: $url (timeout: ${timeout}s)"

    py=python3
    which python3 >/dev/null 2>&1 || py=python

    response=$(DNS_HTTP_URL="$url" DNS_HTTP_HEADERS="$headers" DNS_HTTP_TIMEOUT="$timeout" \
        "$py" -c "
import os, ssl, sys
try:
    import urllib.request as urllib_request
    import urllib.error as urllib_error
except ImportError:
    import urllib2 as urllib_request
    urllib_error = urllib_request

class DeleteRequest(urllib_request.Request):
    def get_method(self):
        return 'DELETE'

headers = {}
for line in os.environ.get('DNS_HTTP_HEADERS', '').splitlines():
    if ':' in line:
        k, v = line.split(':', 1)
        headers[k.strip()] = v.strip()

# Initialize strict, secure TLS validation context
ctx = ssl.create_default_context()
ctx.check_hostname = True
ctx.verify_mode = ssl.CERT_REQUIRED

# Securely load ESXi's native trusted root store path
esxi_store = '/etc/vmware/ssl/castore.pem'
if os.path.exists(esxi_store) and os.path.getsize(esxi_store) > 0:
    ctx.load_verify_locations(cafile=esxi_store)

req = DeleteRequest(os.environ['DNS_HTTP_URL'], headers=headers)
timeout = float(os.environ.get('DNS_HTTP_TIMEOUT') or 30)

try:
    resp = urllib_request.urlopen(req, timeout=timeout, context=ctx)
    data = resp.read()
    sys.stdout.write(data.decode('utf-8') if isinstance(data, bytes) else data)
except urllib_error.HTTPError as e:
    data = e.read()
    sys.stdout.write(data.decode('utf-8') if isinstance(data, bytes) else data)
except Exception as e:
    sys.stderr.write(str(e) + chr(10))
    sys.exit(1)
" 2>&1)
    exit_code=$?

    if [ $exit_code -eq 0 ]; then
        log "Debug: HTTP DELETE response: $response"
        echo "$response"
        return 0
    fi
    log "Debug: python DELETE failed with exit code $exit_code: $response"
    return $exit_code
}

dns_url_encode() {
    string="$1"
    encoded=""

    while [ -n "$string" ]; do
        char="${string%"${string#?}"}"
        string="${string#?}"

        case "$char" in
            [a-zA-Z0-9._~-])
                encoded="$encoded$char"
                ;;
            " ") encoded="${encoded}%20" ;;
            "/") encoded="${encoded}%2F" ;;
            ":") encoded="${encoded}%3A" ;;
            "?") encoded="${encoded}%3F" ;;
            "=") encoded="${encoded}%3D" ;;
            "&") encoded="${encoded}%26" ;;
            "+") encoded="${encoded}%2B" ;;
            *)
                hex=$(printf '%02X' "'$char")
                encoded="$encoded%$hex"
                ;;
        esac
    done

    echo "$encoded"
}

# Enhanced JSON utilities with better error handling
dns_json_get() {
    json="$1"
    path="$2"

    if [ -z "$json" ] || [ -z "$path" ]; then
        log "Debug: Invalid JSON or path provided"
        return 1
    fi

    # Grab the last key segment natively (e.g., "result.id" -> "id")
    # This allows flat string parsing to find nested values safely
    target_key="${path##*.}"

    case "$json" in
        *\""$target_key"\"*)
            # Step 1: Chop everything off before the key
            tmp="${json#*\"$target_key\"}"
            # Step 2: Chop up to the opening value context (skip colon and optional spaces/quotes)
            tmp="${tmp#*:}"
            tmp="${tmp#*[[:space:]]}"

            # Check if the value is a string (starts with a quote) or a bare number/bool
            case "$tmp" in
                \"*)
                    # Isolate string value up to closing quote
                    tmp="${tmp#\"}"
                    echo "${tmp%%\"*}"
                    ;;
                *)
                    # Isolate raw number/boolean up to the next comma or closing bracket
                    tmp="${tmp%%,*}"
                    tmp="${tmp%%\}*}"

                    # Clean up internal/trailing whitespaces entirely in memory
                    clean_val=""
                    while [ -n "$tmp" ]; do
                        case "$tmp" in
                            *[$\'\r\'$\'\n\'$\'\t\'\ ]*)
                                # Snip out everything before the whitespace char
                                part="${tmp%%[$\'\r\'$\'\n\'$\'\t\'\ ]*}"
                                clean_val="$clean_val$part"
                                # Shrink the string past the whitespace character
                                tmp="${tmp#*[$\'\r\'$\'\n\'$\'\t\'\ ]}"
                                ;;
                            *)
                                clean_val="$clean_val$tmp"
                                break
                                ;;
                            esac
                    done
                    echo "$clean_val"
                    ;;
            esac
            ;;
        *)
            echo ""
            ;;
    esac
}

dns_json_validate() {
    json="$1"

    case "$json" in
        *'{'*'}'*) ;;
        *'['*']'*) ;;
        *) return 1 ;;
    esac

    # Count open braces by measuring how much the string shrinks when they are stripped
    no_open="${json#*\{}"
    open_count=0
    while [ "$json" != "$no_open" ]; do
        open_count=$((open_count + 1))
        json="$no_open"
        no_open="${json#*\{}"
    done

    working_json="$1"
    no_close="${working_json#*\}}"
    close_count=0
    while [ "$working_json" != "$no_close" ]; do
        close_count=$((close_count + 1))
        working_json="$no_close"
        no_close="${working_json#*\}}"
    done

    [ "$open_count" -eq "$close_count" ]
}

# Extract error messages from API responses
dns_extract_error() {
    response="$1"
    provider="$2"

    if [ -z "$response" ]; then
        echo "Empty response from API"
        return 1
    fi

    # Try to validate and parse JSON response
    if dns_json_validate "$response"; then
        # Provider-specific error extraction
        case "$provider" in
            "cloudflare")
                error_msg=$(dns_json_get "$response" "errors.0.message")
                if [ -n "$error_msg" ]; then
                    echo "$error_msg"
                    return 0
                fi
                ;;
        esac

        # Generic error field extraction
        for field in "error" "message" "error_description" "detail"; do
            error_msg=$(dns_json_get "$response" "$field")
            if [ -n "$error_msg" ]; then
                echo "$error_msg"
                return 0
            fi
        done
    fi

    case "$response" in
        *[Ee][Rr][Rr][Oo][Rr]*|*[Ff][Aa][Ii][Ll][Ee][Dd]*|*[Ii][Nn][Vv][Aa][Ll][Ii][Dd]*)
            echo "$response" | head -n 3 | sed 's/[\r\n\t]/ /g'
            echo "" # Clean trailing newline for stdout
            return 0
            ;;
    esac

    echo "Unknown API error"
    return 1
}


# Enhanced DNS propagation checking
dns_check_propagation() {
    domain="$1"
    expected_value="$2"
    max_wait="${3:-$DEFAULT_PROPAGATION_WAIT}"
    check_interval="${4:-10}"

    log "Checking DNS propagation for _acme-challenge.$domain"

    waited=0
    public_resolvers="8.8.8.8 1.1.1.1 208.67.222.222 9.9.9.9"
    backup_resolvers="8.8.4.4 1.0.0.1 208.67.220.220 149.112.112.112"

    # Fetch Authoritative Name Server using native BusyBox nslookup parsing
    auth_ns=""
    _ns_raw=$(nslookup -type=ns "$domain" 2>/dev/null)

    case "$_ns_raw" in
        *nameserver\ =*)
            # Extract everything after the 'nameserver = ' marker using standard POSIX chops
            auth_ns="${_ns_raw#*nameserver\ =\ }"
            auth_ns="${auth_ns%%[[:space:]]*}"
            ;;
    esac

    if [ -n "$auth_ns" ]; then
        # Native POSIX trailing-dot suffix trimming (Zero-process overhead)
        auth_ns="${auth_ns%.}"
        log "Debug: Found authoritative nameserver: $auth_ns"
    fi

    while [ $waited -lt $max_wait ]; do
        found=0
        total_resolvers=0
        resolvers_to_check="$public_resolvers"

        # Check authoritative nameserver first if available
        if [ -n "$auth_ns" ]; then
            total_resolvers=$((total_resolvers + 1))
            if dns_query_resolver "$auth_ns" "$domain" "$expected_value"; then
                found=$((found + 1))
                log "Debug: Found expected value on authoritative NS: $auth_ns"
            fi
        fi

        # Check public resolvers
        for resolver in $resolvers_to_check; do
            total_resolvers=$((total_resolvers + 1))
            if dns_query_resolver "$resolver" "$domain" "$expected_value"; then
                found=$((found + 1))
                log "Debug: Found expected value on resolver: $resolver"
            fi
        done

        # Handle backup transitions if consensus isn't reached midway
        required=$((total_resolvers / 2 + 1))
        if [ $found -lt $required ] && [ $waited -gt $((max_wait / 2)) ]; then
            log "Debug: Trying backup resolvers for additional confirmation"
            for resolver in $backup_resolvers; do
                total_resolvers=$((total_resolvers + 1))
                if dns_query_resolver "$resolver" "$domain" "$expected_value"; then
                    found=$((found + 1))
                    log "Debug: Found expected value on backup resolver: $resolver"
                fi
            done
            required=$((total_resolvers / 2 + 1))
        fi

        if [ $found -ge $required ]; then
            log "DNS propagation confirmed ($found/$total_resolvers resolvers)"
            return 0
        fi

        log "Debug: DNS propagation incomplete ($found/$total_resolvers), waiting $check_interval seconds..."
        sleep $check_interval
        waited=$((waited + check_interval))
    done

    log "Error: DNS propagation check failed after $waited seconds"
    return 1
}

# Helper function to query a specific resolver
dns_query_resolver() {
    _dqr_resolver="$1"
    _dqr_domain="$2"
    _dqr_expected="$3"

    # Query the TXT records directly through BusyBox nslookup
    # We pass the domain name and target resolver IP explicitly
    _dqr_out=$(nslookup -type=txt "_acme-challenge.${_dqr_domain}" "$_dqr_resolver" 2>/dev/null)

    # Clean up line endings or quotes inside the text via sed to verify the match cleanly
    case "$_dqr_out" in
        *"$_dqr_expected"*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Supported DNS providers
SUPPORTED_PROVIDERS="cloudflare manual"

# Provider loading and validation
dns_load_provider() {
    provider="$1"

    if [ -z "$provider" ]; then
        log "Error: No DNS provider specified"
        return 1
    fi

    # 1. Direct validation check without intermediate variables
    supported=false
    for p in $SUPPORTED_PROVIDERS; do
        if [ "$p" = "$provider" ]; then
            supported=true
            break
        fi
    done

    if [ "$supported" != "true" ]; then
        log "Error: Unsupported DNS provider: $provider"
        log "Supported providers: $SUPPORTED_PROVIDERS"
        return 1
    fi

    provider_script="$DNSAPIDIR/dns_${provider}.sh"

    # 2. FIXED: Verify file existence BEFORE running 'ls' to prevent unhandled raw shell errors
    if [ ! -f "$provider_script" ]; then
        log "Error: Provider script not found: $provider_script"
        if [ -d "$DNSAPIDIR" ]; then
            ls -l "$DNSAPIDIR" >&2
        fi
        return 1
    fi

    if [ ! -r "$provider_script" ]; then
        log "Error: Provider script is not readable: $provider_script"
        ls -l "$provider_script" >&2
        return 1
    fi

    # 3. Safe executable warning boundary
    if [ -x "$provider_script" ]; then
        log "Warning: Provider script $provider_script is executable. It should NOT be executable; it is meant to be sourced, not run directly."
    fi

    log "Debug: Loading DNS provider: $provider from $provider_script"

    # Source the context natively using the POSIX dot utility
    . "$provider_script"
    source_status=$?

    if [ $source_status -ne 0 ]; then
        log "Error: Failed to source provider script: $provider_script (exit code $source_status)"
        return 1
    fi

    log "Debug: Provider $provider loaded safely."
    return 0
}

# Provider wrapper functions with retry logic
dns_provider_add() {
    provider="$1"
    domain="$2"
    txt_value="\"$3\""
    retries=0
    func="dns_${provider}_add"

    while [ $retries -lt "$DEFAULT_MAX_RETRIES" ]; do
        # Dynamically execute the loaded provider's add function securely
        if "$func" "$domain" "$txt_value"; then
            return 0
        fi
        retries=$((retries + 1))
        if [ $retries -lt "$DEFAULT_MAX_RETRIES" ]; then
            log "Warning: DNS add attempt $retries failed, retrying in $DEFAULT_RETRY_DELAY seconds..."
            sleep "$DEFAULT_RETRY_DELAY"
        fi
    done
    log "Error: Failed to add DNS record after $DEFAULT_MAX_RETRIES attempts"
    return 1
}

dns_provider_rm() {
    provider="$1"
    domain="$2"
    txt_value="\"$3\""
    retries=0
    func="dns_${provider}_rm"

    while [ $retries -lt "$DEFAULT_MAX_RETRIES" ]; do
        # Dynamically execute the loaded provider's remove function securely
        if "$func" "$domain" "$txt_value"; then
            return 0
        fi
        retries=$((retries + 1))
        if [ $retries -lt "$DEFAULT_MAX_RETRIES" ]; then
            log "Warning: DNS remove attempt $retries failed, retrying in $DEFAULT_RETRY_DELAY seconds..."
            sleep "$DEFAULT_RETRY_DELAY"
        fi
    done
    log "Error: Failed to remove DNS record after $DEFAULT_MAX_RETRIES attempts"
    return 1
}

dns_provider_test() {
    provider="$1"
    func="dns_${provider}_test"

    if command -v "$func" >/dev/null 2>&1; then
        "$func"
    else
        log "Warning: Provider $provider does not support testing"
        return 0
    fi
}

dns_provider_info() {
    provider="$1"
    func="dns_${provider}_info"

    if command -v "$func" >/dev/null 2>&1; then
        "$func"
    else
        echo "DNS Provider: $provider"
        echo "No additional information available"
    fi
}

# Command handlers
dns_cmd_add() {
    domain="$1"
    txt_value="$2"

    if ! dns_validate_domain "$domain"; then
        return 1
    fi

    if ! dns_validate_txt_value "$txt_value"; then
        return 1
    fi

    if [ -z "$DNS_PROVIDER" ]; then
        log "Error: DNS_PROVIDER not set in configuration"
        return 1
    fi

    if ! dns_load_provider "$DNS_PROVIDER"; then
        return 1
    fi

    log "Adding DNS TXT record for $domain using $DNS_PROVIDER"
    log "Debug: [GLOBAL] Entering provider add logic for $domain"

    DNS_ADD_TIMEOUT="${DNS_ADD_TIMEOUT:-120}"
    add_exit_code=1

    start_time=$(date +%s)
    log "Creating TXT record _acme-challenge.$domain..."
    dns_provider_add "$DNS_PROVIDER" "$domain" "$txt_value"
    add_exit_code=$?
    end_time=$(date +%s)

    elapsed=$((end_time - start_time))
    if [ "$elapsed" -gt "$DNS_ADD_TIMEOUT" ]; then
        log "Warning: Provider add operation exceeded timeout of ${DNS_ADD_TIMEOUT}s (ran ${elapsed}s)"
    fi

    log "Debug: [GLOBAL] Exited provider add logic for $domain with exit code $add_exit_code"

    if [ $add_exit_code -eq 0 ]; then
        log "DNS record added successfully"
        return 0
    else
        log "Error: Failed to add DNS record"
        return 1
    fi
}

dns_cmd_rm() {
    domain="$1"
    txt_value="$2"

    if ! dns_validate_domain "$domain"; then
        return 1
    fi

    if [ -z "$DNS_PROVIDER" ]; then
        log "Error: DNS_PROVIDER not set in configuration"
        return 1
    fi

    if ! dns_load_provider "$DNS_PROVIDER"; then
        return 1
    fi

    log "Removing DNS TXT record for $domain using $DNS_PROVIDER"
    log "Cleaning up TXT record _acme-challenge.$domain..."

    if dns_provider_rm "$DNS_PROVIDER" "$domain" "$txt_value"; then
        log "DNS record removed successfully"
        return 0
    else
        log "Error: Failed to remove DNS record"
        return 1
    fi
}

dns_cmd_test() {
    if [ -z "$DNS_PROVIDER" ]; then
        log "Error: DNS_PROVIDER not set in configuration"
        return 1
    fi

    if ! dns_load_provider "$DNS_PROVIDER"; then
        return 1
    fi

    log "Testing DNS provider: $DNS_PROVIDER"

    if dns_provider_test "$DNS_PROVIDER"; then
        log "DNS provider test successful"
        return 0
    else
        log "Error: DNS provider test failed"
        return 1
    fi
}

dns_cmd_info() {
    provider="${1:-$DNS_PROVIDER}"

    if [ -z "$provider" ]; then
        log "Error: No DNS provider specified"
        return 1
    fi

    if ! dns_load_provider "$provider"; then
        return 1
    fi

    dns_provider_info "$provider"
    return 0
}

dns_cmd_list() {
    cat <<EOF
Supported DNS Providers:
========================
EOF

    for provider in $SUPPORTED_PROVIDERS; do
        if [ -f "$DNSAPIDIR/dns_${provider}.sh" ]; then
            echo "- $provider (Status: Available)"
        else
            echo "- $provider (Status: Missing provider script)"
        fi
    done

    cat <<EOF

Current Configuration:
- DNS_PROVIDER: ${DNS_PROVIDER:-not set}
- DNS_MAX_WAIT: ${DNS_MAX_WAIT:-300}s (maximum propagation wait)
- DNS_TIMEOUT: ${DEFAULT_DNS_TIMEOUT}s (hardcoded)
- MAX_RETRIES: ${DEFAULT_MAX_RETRIES} (hardcoded)
EOF
}

dns_cmd_wait() {
    domain="$1"
    txt_value="$2"

    if ! dns_validate_domain "$domain"; then
        return 1
    fi

    if ! dns_validate_txt_value "$txt_value"; then
        return 1
    fi

    max_wait=${DNS_MAX_WAIT:-300}
    check_interval=15

    short_txt="${txt_value:0:22}"

    log "DNS propagation wait for $domain (TXT: ${short_txt}...)"
    log "Active DNS propagation checking enabled. Maximum wait: ${max_wait} seconds"

    if dns_check_propagation "$domain" "$txt_value" "$max_wait" "$check_interval"; then
        log "DNS propagation confirmed!"
        return 0
    else
        log "Warning: DNS propagation check timed out after ${max_wait} seconds, but continuing anyway"
        return 0
    fi
}


main() {
    # Show usage if no command was provided globally
    if [ -z "$COMMAND" ]; then
        cat <<EOF
DNS API Framework v$DNS_API_VERSION
Usage: dns_api.sh <command> <domain> [token] [key_auth]

Commands:
  add <domain> <token> <key_auth>  - Add TXT record for ACME challenge
  rm <domain> <token> <key_auth>   - Remove TXT record
  wait <domain> <token> <key_auth> - Wait for DNS propagation
  test                             - Test DNS provider connectivity
  info [provider]                  - Show provider information
  list                             - List all supported providers

Configuration is loaded from renew.cfg
Set DNS_PROVIDER to specify which provider to use

ACME Integration:
This script is called by acme_tiny.py during DNS-01 challenges
The TXT value is calculated from the key_auth parameter
EOF
        return 1
    fi

    # Safeguard fallback sequence using global variables
    TXT_VALUE="${TXT_VALUE:-$KEY_AUTH}"
    TXT_VALUE="${TXT_VALUE:-$TOKEN}"

    case "$COMMAND" in
        "add")
            if [ -z "$DOMAIN" ]; then
                log "Error: Usage: dns_api.sh add <domain> <token> <key_auth>"
                return 1
            fi
            if [ -z "$TXT_VALUE" ]; then
                log "Error: Failed to calculate TXT value - key authorization or token required"
                return 1
            fi
            dns_cmd_add "$DOMAIN" "$TXT_VALUE"
            ;;
        "rm"|"remove")
            if [ -z "$DOMAIN" ]; then
                log "Error: Usage: dns_api.sh rm <domain> <token> <key_auth>"
                return 1
            fi
            dns_cmd_rm "$DOMAIN" "$TXT_VALUE"
            ;;
        "test")
            dns_cmd_test
            ;;
        "info")
            dns_cmd_info "$DOMAIN"
            ;;
        "list")
            dns_cmd_list
            ;;
        "wait")
            if [ -z "$DOMAIN" ]; then
                log "Error: Usage: dns_api.sh wait <domain> <token> <key_auth>"
                return 1
            fi
            if [ -z "$TXT_VALUE" ]; then
                log "Error: Failed to calculate TXT value - key authorization or token required"
                return 1
            fi
            dns_cmd_wait "$DOMAIN" "$TXT_VALUE"
            ;;
        *)
            log "Error: Unknown command: $COMMAND"
            log "Run 'dns_api.sh' without arguments to see usage"
            return 1
            ;;
    esac
}

# Run main function if script is executed directly
if [ "${0##*/}" = "dns_api.sh" ]; then
    main
fi
