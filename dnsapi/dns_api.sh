#!/bin/sh
#
# DNS API Framework - Core functionality for DNS providers
# Main entry point for ACME DNS-01 challenges
# Provides standardized interface and common utilities for all DNS providers
#
# Usage: dns_api.sh <command> <domain> [txt_value]
# Commands: add, rm, wait, info, list, test
#

# ESXi-compatible path resolution - fallback if readlink -f is not available
if readlink -f "$0" >/dev/null 2>&1; then
  DNSAPIDIR=$(dirname "$(readlink -f "$0")")
else
  # Fallback for BusyBox versions without readlink -f
  DNSAPIDIR=$(cd "$(dirname "$0")" && pwd)
fi
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

# Determine the wget TLS option once at script startup.  Priority order:
#   1. User-supplied SSL_CERT_FILE (validated readable)
#   2. Auto-detected CA bundle from well-known ESXi / Linux paths
#   3. Explicit opt-in via INSECURE_TLS=1  (hard failure otherwise)
#
# _WGET_TLS_WARN is stored here but emitted only on the first actual HTTPS
# call (in dns_http_get / dns_http_post), not at startup, so that cron runs
# that never reach the HTTP helpers are not spammed with warnings.
_WGET_TLS_OPT=""
_WGET_TLS_WARN=""

# Probe well-known ESXi and common Linux CA bundle paths.
_dns_find_ca_bundle() {
    for _dfcb_b in \
        /etc/ssl/certs/ca-bundle.crt \
        /etc/vmware/ssl/castore.pem \
        /etc/ssl/certs/ca-certificates.crt \
        /usr/lib/ssl/certs/ca-certificates.crt \
        /etc/pki/tls/certs/ca-bundle.crt \
        /etc/ssl/ca-bundle.pem; do
        if [ -r "$_dfcb_b" ]; then
            printf '%s' "$_dfcb_b"
            return 0
        fi
    done
    return 1
}

if wget --help 2>&1 | grep -q '\-\-ca-certificate'; then
    _ca_bundle=""
    if [ -n "${SSL_CERT_FILE:-}" ] && [ -r "${SSL_CERT_FILE}" ]; then
        _ca_bundle="$SSL_CERT_FILE"
        log "Debug: TLS: using SSL_CERT_FILE CA bundle: $_ca_bundle"
    else
        _ca_bundle=$(_dns_find_ca_bundle)
        [ -n "$_ca_bundle" ] && log "Debug: TLS: auto-detected CA bundle: $_ca_bundle"
    fi

    if [ -n "$_ca_bundle" ]; then
        _WGET_TLS_OPT="--ca-certificate=${_ca_bundle}"
    elif [ "${INSECURE_TLS:-0}" = "1" ]; then
        _WGET_TLS_OPT="--no-check-certificate"
        _WGET_TLS_WARN="INSECURE_TLS=1: TLS certificate verification is DISABLED. DNS provider and ACME API calls are vulnerable to MITM attacks."
    else
        log "Error: No CA bundle found for TLS verification and INSECURE_TLS is not set."
        log "Error: Fix options: (1) set SSL_CERT_FILE=/path/to/ca-bundle.crt in renew.cfg,"
        log "Error:              (2) set INSECURE_TLS=1 in renew.cfg to disable TLS verification (insecure)."
        exit 1
    fi
else
    # wget on this system lacks --ca-certificate; per-bundle TLS validation is impossible.
    if [ "${INSECURE_TLS:-0}" = "1" ]; then
        _WGET_TLS_OPT="--no-check-certificate"
        _WGET_TLS_WARN="INSECURE_TLS=1: wget lacks --ca-certificate support; TLS certificate verification is DISABLED. DNS provider and ACME API calls are vulnerable to MITM attacks."
    else
        log "Error: wget on this system lacks --ca-certificate support; TLS certificate verification is impossible."
        log "Error: Fix options: (1) upgrade wget, (2) set INSECURE_TLS=1 in renew.cfg to disable TLS verification (insecure)."
        exit 1
    fi
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

# BusyBox-only HTTP GET utility
dns_http_get() {
    url="$1"
    headers="$2"
    timeout="${3:-$DEFAULT_DNS_TIMEOUT}"
    max_redirects="${4:-5}"

    # Ensure timeout is a bare integer (BusyBox compatible)
    timeout="$(echo "$timeout" | sed 's/[a-zA-Z]//g')"

    log "Debug: HTTP GET: $url (timeout: ${timeout}s)"

    if ! which wget >/dev/null 2>&1; then
        log "Error: No HTTP client available (wget required)"
        return 127
    fi

    # Emit the deferred INSECURE_TLS warning on the first actual HTTPS call
    # rather than at startup, so cron runs that error before any HTTP call
    # are not spammed unnecessarily.  Clear after first emission.
    if [ -n "${_WGET_TLS_WARN:-}" ]; then
        log "Warning: $_WGET_TLS_WARN"
        _WGET_TLS_WARN=""
    fi

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
        response=$(timeout -t $timeout wget "$@" 2>&1)
        if [ "${DEBUG:-0}" = "1" ]; then
            echo "Debug: Raw HTTP GET response:" >&2
            echo "$response" >&2
        fi
        exit_code=$?
        if [ $exit_code -eq 124 ]; then
            log "Error: wget timed out after ${timeout}s"
            return 124
        fi
    else
        response=$(wget "$@" 2>&1)
        if [ "${DEBUG:-0}" = "1" ]; then
            echo "Debug: Raw HTTP GET response:" >&2
            echo "$response" >&2
        fi
        exit_code=$?
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

# BusyBox-only HTTP POST utility (not supported)
dns_http_post() {
    url="$1"
    data="$2"
    headers="$3"
    timeout="${4:-$DEFAULT_DNS_TIMEOUT}"

    # Ensure timeout is a bare integer (BusyBox compatible)
    timeout="$(echo "$timeout" | sed 's/[a-zA-Z]//g')"

    log "Debug: HTTP POST: $url (timeout: ${timeout}s)"

    if ! which wget >/dev/null 2>&1; then
        log "Error: No HTTP client available (wget required)"
        return 127
    fi

    # Emit the deferred INSECURE_TLS warning on the first actual HTTPS call.
    if [ -n "${_WGET_TLS_WARN:-}" ]; then
        log "Warning: $_WGET_TLS_WARN"
        _WGET_TLS_WARN=""
    fi

    # Compact JSON data: remove all newlines, carriage returns, tabs, and literal \n, \t; collapse spaces
    compact_data=$(echo "$data" \
        | sed 's/\\n//g; s/\\t//g' \
        | sed 's/[\r\n\t]//g' \
        | sed 's/  */ /g')

    set -- -qO- "$_WGET_TLS_OPT" --post-data="$compact_data"
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
        log "Debug: Final wget POST command: wget $*"
    fi
    if which timeout >/dev/null 2>&1; then
        response=$(timeout -t $timeout wget "$@" 2>&1)
        if [ "${DEBUG:-0}" = "1" ]; then
            echo "Debug: Raw HTTP POST response:" >&2
            echo "$response" >&2
        fi
        exit_code=$?
        if [ $exit_code -eq 124 ]; then
            log "Error: wget timed out after ${timeout}s"
            return 124
        fi
    else
        response=$(wget "$@" 2>&1)
        if [ "${DEBUG:-0}" = "1" ]; then
            echo "Debug: Raw HTTP POST response:" >&2
            echo "$response" >&2
        fi
        exit_code=$?
    fi
    if [ $exit_code -eq 0 ]; then
        log "Debug: HTTP POST response: $response"
        echo "$response"
        return 0
    else
        log "Debug: wget POST failed with exit code $exit_code: $response"
        return $exit_code
    fi
}

dns_http_delete() {
    url="$1"
    headers="$2"
    timeout="${3:-$DEFAULT_DNS_TIMEOUT}"

    # Ensure timeout is a bare integer (BusyBox compatible)
    timeout="$(echo "$timeout" | sed 's/[a-zA-Z]//g')"

    log "Debug: HTTP DELETE: $url (timeout: ${timeout}s)"

    # Emit the deferred INSECURE_TLS warning on the first actual HTTPS call.
    if [ -n "${_WGET_TLS_WARN:-}" ]; then
        log "Warning: $_WGET_TLS_WARN"
        _WGET_TLS_WARN=""
    fi

    ca_bundle=""
    case "$_WGET_TLS_OPT" in
        --ca-certificate=*) ca_bundle="${_WGET_TLS_OPT#--ca-certificate=}" ;;
    esac

    # acme_tiny.py already requires python3 (or python2 via its urllib2 fallback)
    # to run at all, so it is always available here.
    py=python3
    which python3 >/dev/null 2>&1 || py=python

    response=$(DNS_HTTP_URL="$url" DNS_HTTP_HEADERS="$headers" DNS_HTTP_TIMEOUT="$timeout" \
        DNS_HTTP_CA_BUNDLE="$ca_bundle" DNS_HTTP_INSECURE="${INSECURE_TLS:-0}" \
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

ctx = ssl.create_default_context()
if os.environ.get('DNS_HTTP_INSECURE') == '1':
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
elif os.environ.get('DNS_HTTP_CA_BUNDLE'):
    ctx.load_verify_locations(cafile=os.environ['DNS_HTTP_CA_BUNDLE'])

req = DeleteRequest(os.environ['DNS_HTTP_URL'], headers=headers)
timeout = float(os.environ.get('DNS_HTTP_TIMEOUT') or 30)
try:
    resp = urllib_request.urlopen(req, timeout=timeout, context=ctx)
    sys.stdout.write(resp.read().decode('utf-8'))
except urllib_error.HTTPError as e:
    sys.stdout.write(e.read().decode('utf-8'))
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

# URL encoding utility (ESXi-compatible)
dns_url_encode() {
    string="$1"
    encoded=""
    char=""

    # Process each character
    while [ -n "$string" ]; do
        char="${string%"${string#?}"}"  # Get first character
        string="${string#?}"            # Remove first character

        case "$char" in
            [a-zA-Z0-9._~-])
                encoded="$encoded$char"
                ;;
            *)
                # Convert to hex (ESXi compatible method)
                if which printf >/dev/null 2>&1; then
                    encoded="$encoded$(printf '%%%02X' "'$char")"
                else
                    # Fallback for limited environments
                    encoded="$encoded%$(echo -n "$char" | od -An -tx1 | sed 's/ //g')"
                fi
                ;;
        esac
    done

    echo "$encoded"
}

# Enhanced JSON utilities with better error handling
dns_json_get() {
    json="$1"
    path="$2"

    # Validate input
    if [ -z "$json" ] || [ -z "$path" ]; then
        log "Debug: Invalid JSON or path provided"
        return 1
    fi

    # Use python if available for robust JSON parsing
    if which python >/dev/null 2>&1; then
        echo "$json" | python -c "
import sys, json
try:
    data = json.load(sys.stdin)
    path = '$path'.split('.')
    result = data
    for key in path:
        if key.isdigit():
            result = result[int(key)]
        elif key in result:
            result = result[key]
        else:
            print('')
            sys.exit(0)
    if result is not None:
        if isinstance(result, (str, int, float, bool)):
            print(result)
        else:
            print(json.dumps(result))
    else:
        print('')
except (KeyError, IndexError, TypeError, ValueError) as e:
    print('')
except Exception as e:
    print('')
    sys.exit(1)
"
    elif which python3 >/dev/null 2>&1; then
        echo "$json" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    path = '$path'.split('.')
    result = data
    for key in path:
        if key.isdigit():
            result = result[int(key)]
        elif key in result:
            result = result[key]
        else:
            print('')
            sys.exit(0)
    if result is not None:
        if isinstance(result, (str, int, float, bool)):
            print(result)
        else:
            print(json.dumps(result))
    else:
        print('')
except (KeyError, IndexError, TypeError, ValueError) as e:
    print('')
except Exception as e:
    print('')
    sys.exit(1)
"
    else
        # Enhanced fallback using sed/awk for ESXi compatibility
        log "Debug: Using fallback JSON parser"

        # Handle simple cases with sed/grep
        case "$path" in
            *.*)
                # Complex path - not well supported in fallback
                echo "$json" | sed -n "s/.*\"$(echo "$path" | cut -d. -f1)\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
                ;;
            *)
                # Simple key lookup
                echo "$json" | sed -n "s/.*\"$path\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
                ;;
        esac
    fi
}

# JSON validation utility
dns_json_validate() {
    json="$1"

    if which python >/dev/null 2>&1; then
        echo "$json" | python -c "
import sys, json
try:
    json.load(sys.stdin)
    sys.exit(0)
except:
    sys.exit(1)
" 2>/dev/null
    elif which python3 >/dev/null 2>&1; then
        echo "$json" | python3 -c "
import sys, json
try:
    json.load(sys.stdin)
    sys.exit(0)
except:
    sys.exit(1)
" 2>/dev/null
    else
        # Basic validation - check for balanced braces
        open_braces=""
        close_braces=""
        open_braces=$(echo "$json" | sed 's/[^\{]//g' | wc -c)
        close_braces=$(echo "$json" | sed 's/[^\}]//g' | wc -c)
        [ "$open_braces" -eq "$close_braces" ]
    fi
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
                [ -n "$error_msg" ] && echo "$error_msg" && return 0
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

    # Fallback to basic text extraction
    if echo "$response" | grep -qi "error\|failed\|invalid"; then
        echo "$response" | head -3 | awk '{printf "%s ", $0}'
        return 0
    fi

    echo "Unknown API error"
    return 1
}

# Enhanced DNS propagation checking with multiple strategies
dns_check_propagation() {
    domain="$1"
    expected_value="$2"
    max_wait="${3:-$DEFAULT_PROPAGATION_WAIT}"
    check_interval="${4:-10}"

    log "Checking DNS propagation for _acme-challenge.$domain"

    waited=0
    # Multiple resolver sets for comprehensive checking
    public_resolvers="8.8.8.8 1.1.1.1 208.67.222.222 9.9.9.9"
    backup_resolvers="8.8.4.4 1.0.0.1 208.67.220.220 149.112.112.112"

    # Start with authoritative nameserver check if available
    auth_ns=""
    if which dig >/dev/null 2>&1; then
        auth_ns=$(dig +short NS "$domain" 2>/dev/null | head -1)
        if [ -n "$auth_ns" ]; then
            # Remove trailing dot
            auth_ns=$(echo "$auth_ns" | sed 's/\.$//')
            log "Debug: Found authoritative nameserver: $auth_ns"
        fi
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

        # If not enough resolvers agree, try backup resolvers
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
    resolver="$1"
    domain="$2"
    expected_value="$3"

    result=""

    # Use dig if available, fallback to nslookup
    if which dig >/dev/null 2>&1; then
        result=$(dig @"$resolver" TXT "_acme-challenge.$domain" +short +timeout=5 +tries=1 2>/dev/null | sed 's/"//g' | head -1)
    elif which nslookup >/dev/null 2>&1; then
        # nslookup with timeout (ESXi compatible)
        result=$(timeout 10 nslookup -type=TXT "_acme-challenge.$domain" "$resolver" 2>/dev/null | grep -o '"[^\"]*"' | sed 's/"//g' | head -1)
    else
        log "Error: No DNS query tool available (dig or nslookup)"
        return 1
    fi

    [ "$result" = "$expected_value" ]
}

# DNS cache busting - force fresh queries
dns_flush_cache() {
    domain="$1"

    log "Debug: Attempting to flush DNS cache for $domain"

    # Try various cache-busting techniques
    if which systemd-resolve >/dev/null 2>&1; then
        systemd-resolve --flush-caches 2>/dev/null || true
    elif which resolvectl >/dev/null 2>&1; then
        resolvectl flush-caches 2>/dev/null || true
    elif [ -f /etc/init.d/nscd ]; then
        /etc/init.d/nscd restart 2>/dev/null || true
    fi

    # Add random query to bust caches
    random_subdomain="cache-bust-$(date +%s)"
    if which dig >/dev/null 2>&1; then
        dig "$random_subdomain.$domain" +short >/dev/null 2>&1 || true
    fi
}

# ESXi Environment Initialization (ESXi 6.5+ Only)
# This project is designed exclusively for ESXi environments
dns_init_esxi_environment() {
    log "Debug: Initializing ESXi 6.5+ environment"

    # ESXi-optimized defaults (memory-based caching only)
    DNS_CACHE_TTL=120                         # 2 minutes - conservative for ESXi
    DNS_USE_FILE_CACHE=0                      # Always disabled for ESXi read-only filesystem

    # Check memory constraints specific to ESXi
    free_mem=""
    if which free >/dev/null 2>&1; then
        free_mem=$(free 2>/dev/null | awk '/^Mem:/ {print $4}' 2>/dev/null)
        if [ -n "$free_mem" ] && [ "$free_mem" -lt 100000 ]; then  # Less than ~100MB
            log "Debug: ESXi memory constrained (${free_mem}K) - using shorter cache TTL"
            DNS_CACHE_TTL=60  # 1 minute for memory-constrained ESXi hosts
        fi
    fi

    log "Debug: ESXi environment initialized: TTL=${DNS_CACHE_TTL}s, Memory cache only"
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

    # Check if provider is supported
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

    # Load provider script
    provider_script="$DNSAPIDIR/dns_${provider}.sh"

    # Debug: Check provider script permissions and type
    ls -l "$provider_script" >&2
    if [ -x "$provider_script" ]; then
        log "Warning: Provider script $provider_script is executable. It should NOT be executable; it is meant to be sourced, not run directly."
    fi

    log "Debug: Checking for provider script: $provider_script"
    if [ ! -f "$provider_script" ]; then
        log "Error: Provider script not found: $provider_script"
        ls -l "$DNSAPIDIR" >&2
        return 1
    fi
    if [ ! -r "$provider_script" ]; then
        log "Error: Provider script is not readable: $provider_script"
        ls -l "$provider_script" >&2
        return 1
    fi

    log "Debug: Loading DNS provider: $provider from $provider_script"
    . "$provider_script"
    source_status=$?
    if [ $source_status -ne 0 ]; then
        log "Error: Failed to source provider script: $provider_script (exit code $source_status)"
        return 1
    fi

    log "Debug: Provider $provider loaded (function checks skipped)."
    return 0
}

# Provider wrapper functions with retry logic
dns_provider_add() {
    provider="$1"
    domain="$2"
    txt_value="\"$3\""
    retries=0
    func="dns_${provider}_add"

    while [ $retries -lt $DEFAULT_MAX_RETRIES ]; do
        if $func "$domain" "$txt_value"; then
            return 0
        fi
        retries=$((retries + 1))
        if [ $retries -lt $DEFAULT_MAX_RETRIES ]; then
            log "Warning: DNS add attempt $retries failed, retrying in $DEFAULT_RETRY_DELAY seconds..."
            sleep $DEFAULT_RETRY_DELAY
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

    while [ $retries -lt $DEFAULT_MAX_RETRIES ]; do
        if $func "$domain" "$txt_value"; then
            return 0
        fi
        retries=$((retries + 1))
        if [ $retries -lt $DEFAULT_MAX_RETRIES ]; then
            log "Warning: DNS remove attempt $retries failed, retrying in $DEFAULT_RETRY_DELAY seconds..."
            sleep $DEFAULT_RETRY_DELAY
        fi
    done
    log "Error: Failed to remove DNS record after $DEFAULT_MAX_RETRIES attempts"
    return 1
}

dns_provider_test() {
    provider="$1"
    func="dns_${provider}_test"
    # Call the function and handle if not defined
    if type "$func" 2>/dev/null | grep -q 'function'; then
        $func
    else
        log "Warning: Provider $provider does not support testing"
        return 0
    fi
}

dns_provider_info() {
    provider="$1"
    func="dns_${provider}_info"
    # Call the function and handle if not defined
    if type "$func" 2>/dev/null | grep -q 'function'; then
        $func
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

    # Always run in current shell for function scope
    start_time=$(date +%s)
    log "Creating TXT record _acme-challenge.$domain..."
    dns_provider_add "$DNS_PROVIDER" "$domain" "$txt_value"
    add_exit_code=$?
    end_time=$(date +%s)
    elapsed=$((end_time - start_time))
    if [ $elapsed -gt "$DNS_ADD_TIMEOUT" ]; then
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
    log "Supported DNS Providers:"
    log "========================"
    log ""

    for provider in $SUPPORTED_PROVIDERS; do
        log "- $provider"
        if [ -f "$DNSAPIDIR/dns_${provider}.sh" ]; then
            log "  Status: Available"
        else
            log "  Status: Missing provider script"
        fi
        log ""
    done

    log "Current Configuration:"
    log "- DNS_PROVIDER: ${DNS_PROVIDER:-not set}"
    log "- DNS_MAX_WAIT: ${DNS_MAX_WAIT:-300}s (maximum propagation wait)"
    log "- DNS_TIMEOUT: ${DEFAULT_DNS_TIMEOUT}s (hardcoded)"
    log "- MAX_RETRIES: ${DEFAULT_MAX_RETRIES} (hardcoded)"
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

    # Always use active DNS propagation checking with a reasonable maximum wait
    max_wait=${DNS_MAX_WAIT:-300}  # 5 minute safety limit
    check_interval=15  # Check every 15 seconds

    log "DNS propagation wait for $domain (TXT: $(printf '%.20s' "$txt_value")...)"
    log "Active DNS propagation checking enabled. Maximum wait: ${max_wait} seconds"

    # Use the existing comprehensive dns_check_propagation function
    if dns_check_propagation "$domain" "$txt_value" "$max_wait" "$check_interval"; then
        log "DNS propagation confirmed!"
        return 0
    else
        log "Warning: DNS propagation check timed out after ${max_wait} seconds, but continuing anyway"
        return 0  # Don't fail the entire process
    fi
}

# Main function
main() {
    command="$1"
    domain="$2"
    token="$3"
    key_auth="$4"

    # Show usage if no command provided
    if [ -z "$command" ]; then
        log "DNS API Framework v$DNS_API_VERSION"
        log "Usage: dns_api.sh <command> <domain> [token] [key_auth]"
        log ""
        log "Commands:"
        log "  add <domain> <token> <key_auth>  - Add TXT record for ACME challenge"
        log "  rm <domain> <token> <key_auth>   - Remove TXT record"
        log "  wait <domain> <token> <key_auth> - Wait for DNS propagation"
        log "  test                             - Test DNS provider connectivity"
        log "  info [provider]                  - Show provider information"
        log "  list                             - List all supported providers"
        log ""
        log "Configuration is loaded from renew.cfg"
        log "Set DNS_PROVIDER to specify which provider to use"
        log ""
        log "ACME Integration:"
        log "This script is called by acme_tiny.py during DNS-01 challenges"
        log "The TXT value is calculated from the key_auth parameter"
        return 1
    fi

    # Handle commands
    case "$command" in
        "add")
            if [ -z "$domain" ]; then
                log "Error: Usage: dns_api.sh add <domain> <token> <key_auth>"
                return 1
            fi
            if [ -z "$TXT_VALUE" ]; then
                log "Error: Failed to calculate TXT value - key authorization required"
                return 1
            fi
            dns_cmd_add "$domain" "$TXT_VALUE"
            ;;
        "rm"|"remove")
            if [ -z "$domain" ]; then
                log "Error: Usage: dns_api.sh rm <domain> <token> <key_auth>"
                return 1
            fi
            # For remove, TXT_VALUE is optional as some providers can remove by domain only
            dns_cmd_rm "$domain" "$TXT_VALUE"
            ;;
        "test")
            dns_cmd_test
            ;;
        "info")
            dns_cmd_info "$domain"
            ;;
        "list")
            dns_cmd_list
            ;;
        "wait")
            if [ -z "$domain" ]; then
                log "Error: Usage: dns_api.sh wait <domain> <token> <key_auth>"
                return 1
            fi
            if [ -z "$TXT_VALUE" ]; then
                log "Error: Failed to calculate TXT value - key authorization required"
                return 1
            fi
            dns_cmd_wait "$domain" "$TXT_VALUE"
            ;;
        *)
            log "Error: Unknown command: $command"
            log "Run 'dns_api.sh' without arguments to see usage"
            return 1
            ;;
    esac
}

# Initialize ESXi environment
dns_init_esxi_environment

# Run main function if script is executed directly
if [ "${0##*/}" = "dns_api.sh" ]; then
    main "$COMMAND" "$DOMAIN" "$TOKEN" "$KEY_AUTH"
fi

