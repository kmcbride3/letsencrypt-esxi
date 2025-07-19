#!/bin/sh
#
# DNS API Framework - Core functionality for DNS providers
# Main entry point for ACME DNS-01 challenges
# Provides standardized interface and common utilities for all DNS providers
#
# Usage: dns_api.sh <command> <domain> [txt_value]
# Commands: add, rm, info, list, test
#

# Parse command line arguments
COMMAND="$1"
DOMAIN="$2"
TOKEN="$3"
KEY_AUTH="$4"

# Calculate TXT value from key authorization for DNS-01 challenges
calculate_txt_value() {
    local key_auth="$1"
    if [ -z "$key_auth" ]; then
        return 1
    fi

    # Use the same calculation as acme_tiny.py: base64(sha256(key_auth))
    if command -v python3 >/dev/null 2>&1; then
        echo -n "$key_auth" | python3 -c "
import sys, hashlib, base64
data = sys.stdin.read().encode('utf8')
hash_digest = hashlib.sha256(data).digest()
result = base64.urlsafe_b64encode(hash_digest).decode('utf8').replace('=', '')
print(result)
"
    elif command -v python >/dev/null 2>&1; then
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
if [ "$COMMAND" = "add" ] || [ "$COMMAND" = "rm" ]; then
    if [ -n "$KEY_AUTH" ]; then
        TXT_VALUE=$(calculate_txt_value "$KEY_AUTH")
        if [ -z "$TXT_VALUE" ]; then
            echo "Error: Failed to calculate TXT value from key authorization" >&2
            exit 1
        fi
    elif [ -n "$ACME_KEY_AUTH" ]; then
        # Fallback to environment variable
        TXT_VALUE=$(calculate_txt_value "$ACME_KEY_AUTH")
        if [ -z "$TXT_VALUE" ]; then
            echo "Error: Failed to calculate TXT value from ACME_KEY_AUTH" >&2
            exit 1
        fi
    else
        # Legacy: assume third parameter is already the TXT value
        TXT_VALUE="$TOKEN"
    fi
fi

# Configuration loading - check both local directory and parent
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
LOCALDIR="$(dirname "$SCRIPT_DIR")"

# Load configuration from renew.cfg
if [ -r "$LOCALDIR/renew.cfg" ]; then
    . "$LOCALDIR/renew.cfg"
elif [ -r "$SCRIPT_DIR/../renew.cfg" ]; then
    . "$SCRIPT_DIR/../renew.cfg"
fi

# DNS API version
DNS_API_VERSION="2.0.0"

# Default settings that providers can override
DEFAULT_DNS_TIMEOUT=${DNS_TIMEOUT:-30}
DEFAULT_TTL=${DNS_TTL:-120}
DEFAULT_PROPAGATION_WAIT=${DNS_PROPAGATION_WAIT:-120}
DEFAULT_MAX_RETRIES=${MAX_RETRIES:-3}
DEFAULT_RETRY_DELAY=${RETRY_DELAY:-5}

# Logging functions
dns_log_debug() {
    if [ "${DEBUG:-0}" = "1" ]; then
        echo "[DNS-DEBUG] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
    fi
}

dns_log_info() {
    echo "[DNS-INFO] $(date '+%Y-%m-%d %H:%M:%S') $*"
}

dns_log_warn() {
    echo "[DNS-WARN] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}

dns_log_error() {
    echo "[DNS-ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}

# Validation functions
dns_validate_domain() {
    local domain="$1"
    if [ -z "$domain" ]; then
        dns_log_error "Domain cannot be empty"
        return 1
    fi

    # Basic domain validation
    if ! echo "$domain" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?)*$'; then
        dns_log_error "Invalid domain format: $domain"
        return 1
    fi

    return 0
}

dns_validate_txt_value() {
    local txt_value="$1"
    if [ -z "$txt_value" ]; then
        dns_log_error "TXT value cannot be empty"
        return 1
    fi

    # Validate base64-like encoding (basic check)
    if [ ${#txt_value} -lt 40 ]; then
        dns_log_error "TXT value seems too short (${#txt_value} chars)"
        return 1
    fi

    return 0
}

# DNS zone detection utilities
dns_get_zone() {
    local domain="$1"
    local provider="$2"

    # Try different zone detection strategies

    # Strategy 1: Direct domain match
    if dns_zone_exists "$domain" "$provider"; then
        echo "$domain"
        return 0
    fi

    # Strategy 2: Parent domains
    local parent_domain="$domain"
    while [ "$(echo "$parent_domain" | awk -F'.' '{print NF}')" -gt 2 ]; do
        parent_domain=$(echo "$parent_domain" | cut -d. -f2-)
        if dns_zone_exists "$parent_domain" "$provider"; then
            echo "$parent_domain"
            return 0
        fi
    done

    # Strategy 3: Common patterns
    local base_domain=$(echo "$domain" | awk -F. '{if(NF>=2) print $(NF-1)"."$NF; else print $0}')
    if dns_zone_exists "$base_domain" "$provider"; then
        echo "$base_domain"
        return 0
    fi

    dns_log_error "Could not determine DNS zone for domain: $domain"
    return 1
}

# Enhanced HTTP utilities with better error handling and timeout management
dns_http_get() {
    local url="$1"
    local headers="$2"
    local timeout="${3:-$DEFAULT_DNS_TIMEOUT}"
    local max_redirects="${4:-5}"

    dns_log_debug "HTTP GET: $url (timeout: ${timeout}s)"

    # Use curl if available, fallback to wget
    if command -v curl >/dev/null 2>&1; then
        local curl_args="-s --max-time $timeout --max-redirs $max_redirects"

        # Add headers if provided
        if [ -n "$headers" ]; then
            while IFS= read -r header; do
                [ -n "$header" ] && curl_args="$curl_args -H \"$header\""
            done << EOF
$headers
EOF
        fi

        # Execute curl with error handling
        local response
        local exit_code
        response=$(eval "curl $curl_args \"$url\"" 2>&1)
        exit_code=$?

        if [ $exit_code -eq 0 ]; then
            echo "$response"
            return 0
        else
            dns_log_debug "curl failed with exit code $exit_code: $response"
            return $exit_code
        fi

    elif command -v wget >/dev/null 2>&1; then
        local wget_args="-qO- --timeout=$timeout --max-redirect=$max_redirects --no-check-certificate"

        # Add headers if provided
        if [ -n "$headers" ]; then
            while IFS= read -r header; do
                [ -n "$header" ] && wget_args="$wget_args --header=\"$header\""
            done << EOF
$headers
EOF
        fi

        # Execute wget with error handling
        local response
        local exit_code
        response=$(eval "wget $wget_args \"$url\"" 2>&1)
        exit_code=$?

        if [ $exit_code -eq 0 ]; then
            echo "$response"
            return 0
        else
            dns_log_debug "wget failed with exit code $exit_code: $response"
            return $exit_code
        fi
    else
        dns_log_error "No HTTP client available (curl or wget required)"
        return 127
    fi
}

dns_http_post() {
    local url="$1"
    local data="$2"
    local headers="$3"
    local timeout="${4:-$DEFAULT_DNS_TIMEOUT}"
    local content_type="${5:-application/json}"

    dns_log_debug "HTTP POST: $url (timeout: ${timeout}s)"
    dns_log_debug "POST data: $data"

    # Use curl if available, fallback to wget
    if command -v curl >/dev/null 2>&1; then
        local curl_args="-s --max-time $timeout"

        # Add content type
        curl_args="$curl_args -H \"Content-Type: $content_type\""

        # Add custom headers if provided
        if [ -n "$headers" ]; then
            while IFS= read -r header; do
                [ -n "$header" ] && curl_args="$curl_args -H \"$header\""
            done << EOF
$headers
EOF
        fi

        # Execute curl with data
        local response
        local exit_code
        response=$(eval "curl $curl_args -d \"$data\" \"$url\"" 2>&1)
        exit_code=$?

        # Check for rate limiting in response
        if [ $exit_code -eq 0 ]; then
            echo "$response"
            return 0
        else
            dns_log_debug "curl POST failed with exit code $exit_code: $response"
            return $exit_code
        fi

    elif command -v wget >/dev/null 2>&1; then
        local wget_args="-qO- --timeout=$timeout --no-check-certificate"
        wget_args="$wget_args --header=\"Content-Type: $content_type\""

        # Add custom headers if provided
        if [ -n "$headers" ]; then
            while IFS= read -r header; do
                [ -n "$header" ] && wget_args="$wget_args --header=\"$header\""
            done << EOF
$headers
EOF
        fi

        # Execute wget with post data
        local response
        local exit_code
        response=$(eval "wget $wget_args --post-data=\"$data\" \"$url\"" 2>&1)
        exit_code=$?

        if [ $exit_code -eq 0 ]; then
            echo "$response"
            return 0
        else
            dns_log_debug "wget POST failed with exit code $exit_code: $response"
            return $exit_code
        fi
    else
        dns_log_error "No HTTP client available (curl or wget required)"
        return 127
    fi
}

dns_http_delete() {
    local url="$1"
    local headers="$2"
    local timeout="${3:-$DEFAULT_DNS_TIMEOUT}"

    dns_log_debug "HTTP DELETE: $url (timeout: ${timeout}s)"

    # Only curl supports DELETE method reliably
    if command -v curl >/dev/null 2>&1; then
        local curl_args="-s --max-time $timeout -X DELETE"

        # Add headers if provided
        if [ -n "$headers" ]; then
            while IFS= read -r header; do
                [ -n "$header" ] && curl_args="$curl_args -H \"$header\""
            done << EOF
$headers
EOF
        fi

        # Execute curl DELETE
        local response
        local exit_code
        response=$(eval "curl $curl_args \"$url\"" 2>&1)
        exit_code=$?

        if [ $exit_code -eq 0 ]; then
            echo "$response"
            return 0
        else
            dns_log_debug "curl DELETE failed with exit code $exit_code: $response"
            return $exit_code
        fi
    else
        dns_log_warn "DELETE method not supported with wget, record may not be cleaned up"
        return 1
    fi
}

# URL encoding utility (ESXi-compatible)
dns_url_encode() {
    local string="$1"
    local encoded=""
    local char

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
                if command -v printf >/dev/null 2>&1; then
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
    local json="$1"
    local path="$2"

    # Validate input
    if [ -z "$json" ] || [ -z "$path" ]; then
        dns_log_debug "Invalid JSON or path provided"
        return 1
    fi

    # Use python if available for robust JSON parsing
    if command -v python >/dev/null 2>&1; then
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
    elif command -v python3 >/dev/null 2>&1; then
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
        dns_log_debug "Using fallback JSON parser"

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
    local json="$1"

    if command -v python >/dev/null 2>&1; then
        echo "$json" | python -c "
import sys, json
try:
    json.load(sys.stdin)
    sys.exit(0)
except:
    sys.exit(1)
" 2>/dev/null
    elif command -v python3 >/dev/null 2>&1; then
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
        local open_braces
        local close_braces
        open_braces=$(echo "$json" | sed 's/[^\{]//g' | wc -c)
        close_braces=$(echo "$json" | sed 's/[^\}]//g' | wc -c)
        [ "$open_braces" -eq "$close_braces" ]
    fi
}

# Extract error messages from API responses
dns_extract_error() {
    local response="$1"
    local provider="$2"

    if [ -z "$response" ]; then
        echo "Empty response from API"
        return 1
    fi

    # Try to validate and parse JSON response
    if dns_json_validate "$response"; then
        # Provider-specific error extraction
        case "$provider" in
            "cloudflare")
                local error_msg
                error_msg=$(dns_json_get "$response" "errors.0.message")
                [ -n "$error_msg" ] && echo "$error_msg" && return 0
                ;;
            "route53")
                local error_msg
                error_msg=$(dns_json_get "$response" "Error.Message")
                [ -n "$error_msg" ] && echo "$error_msg" && return 0
                ;;
            "digitalocean")
                local error_msg
                error_msg=$(dns_json_get "$response" "message")
                [ -n "$error_msg" ] && echo "$error_msg" && return 0
                ;;
        esac

        # Generic error field extraction
        for field in "error" "message" "error_description" "detail"; do
            local error_msg
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
    local domain="$1"
    local expected_value="$2"
    local max_wait="${3:-$DEFAULT_PROPAGATION_WAIT}"
    local check_interval="${4:-10}"

    dns_log_info "Checking DNS propagation for _acme-challenge.$domain"

    local waited=0
    # Multiple resolver sets for comprehensive checking
    local public_resolvers="8.8.8.8 1.1.1.1 208.67.222.222 9.9.9.9"
    local backup_resolvers="8.8.4.4 1.0.0.1 208.67.220.220 149.112.112.112"

    # Start with authoritative nameserver check if available
    local auth_ns=""
    if command -v dig >/dev/null 2>&1; then
        auth_ns=$(dig +short NS "$domain" 2>/dev/null | head -1)
        if [ -n "$auth_ns" ]; then
            # Remove trailing dot
            auth_ns=$(echo "$auth_ns" | sed 's/\.$//')
            dns_log_debug "Found authoritative nameserver: $auth_ns"
        fi
    fi

    while [ $waited -lt $max_wait ]; do
        local found=0
        local total_resolvers=0
        local resolvers_to_check="$public_resolvers"

        # Check authoritative nameserver first if available
        if [ -n "$auth_ns" ]; then
            total_resolvers=$((total_resolvers + 1))
            if dns_query_resolver "$auth_ns" "$domain" "$expected_value"; then
                found=$((found + 1))
                dns_log_debug "Found expected value on authoritative NS: $auth_ns"
            fi
        fi

        # Check public resolvers
        for resolver in $resolvers_to_check; do
            total_resolvers=$((total_resolvers + 1))
            if dns_query_resolver "$resolver" "$domain" "$expected_value"; then
                found=$((found + 1))
                dns_log_debug "Found expected value on resolver: $resolver"
            fi
        done

        # If not enough resolvers agree, try backup resolvers
        local required=$((total_resolvers / 2 + 1))
        if [ $found -lt $required ] && [ $waited -gt $((max_wait / 2)) ]; then
            dns_log_debug "Trying backup resolvers for additional confirmation"
            for resolver in $backup_resolvers; do
                total_resolvers=$((total_resolvers + 1))
                if dns_query_resolver "$resolver" "$domain" "$expected_value"; then
                    found=$((found + 1))
                    dns_log_debug "Found expected value on backup resolver: $resolver"
                fi
            done
            required=$((total_resolvers / 2 + 1))
        fi

        if [ $found -ge $required ]; then
            dns_log_info "DNS propagation confirmed ($found/$total_resolvers resolvers)"
            return 0
        fi

        dns_log_debug "DNS propagation incomplete ($found/$total_resolvers), waiting $check_interval seconds..."
        sleep $check_interval
        waited=$((waited + check_interval))
    done

    dns_log_error "DNS propagation check failed after $waited seconds"
    return 1
}

# Helper function to query a specific resolver
dns_query_resolver() {
    local resolver="$1"
    local domain="$2"
    local expected_value="$3"

    local result=""

    # Use dig if available, fallback to nslookup
    if command -v dig >/dev/null 2>&1; then
        result=$(dig @"$resolver" TXT "_acme-challenge.$domain" +short +timeout=5 +tries=1 2>/dev/null | sed 's/"//g' | head -1)
    elif command -v nslookup >/dev/null 2>&1; then
        # nslookup with timeout (ESXi compatible)
        result=$(timeout 10 nslookup -type=TXT "_acme-challenge.$domain" "$resolver" 2>/dev/null | grep -o '"[^\"]*"' | sed 's/"//g' | head -1)
    else
        dns_log_error "No DNS query tool available (dig or nslookup)"
        return 1
    fi

    [ "$result" = "$expected_value" ]
}

# DNS cache busting - force fresh queries
dns_flush_cache() {
    local domain="$1"

    dns_log_debug "Attempting to flush DNS cache for $domain"

    # Try various cache-busting techniques
    if command -v systemd-resolve >/dev/null 2>&1; then
        systemd-resolve --flush-caches 2>/dev/null || true
    elif command -v resolvectl >/dev/null 2>&1; then
        resolvectl flush-caches 2>/dev/null || true
    elif [ -f /etc/init.d/nscd ]; then
        /etc/init.d/nscd restart 2>/dev/null || true
    fi

    # Add random query to bust caches
    local random_subdomain="cache-bust-$(date +%s)"
    if command -v dig >/dev/null 2>&1; then
        dig "$random_subdomain.$domain" +short >/dev/null 2>&1 || true
    fi
}

# ESXi Environment Initialization (ESXi 6.5+ Only)
# This project is designed exclusively for ESXi environments
dns_init_esxi_environment() {
    dns_log_debug "Initializing ESXi 6.5+ environment"

    # ESXi-optimized defaults (memory-based caching only)
    DNS_CACHE_TTL=${DNS_CACHE_TTL:-120}      # 2 minutes - conservative for ESXi
    DNS_USE_FILE_CACHE=0                      # Always disabled for ESXi read-only filesystem

    # Check memory constraints specific to ESXi
    local free_mem
    if command -v free >/dev/null 2>&1; then
        free_mem=$(free 2>/dev/null | awk '/^Mem:/ {print $4}' 2>/dev/null)
        if [ -n "$free_mem" ] && [ "$free_mem" -lt 100000 ]; then  # Less than ~100MB
            dns_log_debug "ESXi memory constrained (${free_mem}K) - using shorter cache TTL"
            DNS_CACHE_TTL=60  # 1 minute for memory-constrained ESXi hosts
        fi
    fi

    dns_log_debug "ESXi environment initialized: TTL=${DNS_CACHE_TTL}s, Memory cache only"
}

# Supported DNS providers
SUPPORTED_PROVIDERS="cloudflare route53 digitalocean namecheap godaddy powerdns duckdns ns1 gcloud azure manual"

# Provider loading and validation
dns_load_provider() {
    local provider="$1"

    if [ -z "$provider" ]; then
        dns_log_error "No DNS provider specified"
        return 1
    fi

    # Check if provider is supported
    local supported=false
    for p in $SUPPORTED_PROVIDERS; do
        if [ "$p" = "$provider" ]; then
            supported=true
            break
        fi
    done

    if [ "$supported" != "true" ]; then
        dns_log_error "Unsupported DNS provider: $provider"
        dns_log_info "Supported providers: $SUPPORTED_PROVIDERS"
        return 1
    fi

    # Load provider script
    local provider_script="$SCRIPT_DIR/dns_${provider}.sh"

    if [ ! -f "$provider_script" ]; then
        dns_log_error "Provider script not found: $provider_script"
        return 1
    fi

    dns_log_debug "Loading DNS provider: $provider"
    . "$provider_script"

    # Validate required functions exist
    if ! command -v "dns_${provider}_add" >/dev/null 2>&1; then
        dns_log_error "Provider $provider missing dns_${provider}_add function"
        return 1
    fi

    if ! command -v "dns_${provider}_rm" >/dev/null 2>&1; then
        dns_log_error "Provider $provider missing dns_${provider}_rm function"
        return 1
    fi

    return 0
}

# Provider wrapper functions with retry logic
dns_provider_add() {
    local provider="$1"
    local domain="$2"
    local txt_value="$3"
    local retries=0

    while [ $retries -lt $DEFAULT_MAX_RETRIES ]; do
        if "dns_${provider}_add" "$domain" "$txt_value"; then
            return 0
        fi

        retries=$((retries + 1))
        if [ $retries -lt $DEFAULT_MAX_RETRIES ]; then
            dns_log_warn "DNS add attempt $retries failed, retrying in $DEFAULT_RETRY_DELAY seconds..."
            sleep $DEFAULT_RETRY_DELAY
        fi
    done

    dns_log_error "Failed to add DNS record after $DEFAULT_MAX_RETRIES attempts"
    return 1
}

dns_provider_rm() {
    local provider="$1"
    local domain="$2"
    local txt_value="$3"
    local retries=0

    while [ $retries -lt $DEFAULT_MAX_RETRIES ]; do
        if "dns_${provider}_rm" "$domain" "$txt_value"; then
            return 0
        fi

        retries=$((retries + 1))
        if [ $retries -lt $DEFAULT_MAX_RETRIES ]; then
            dns_log_warn "DNS remove attempt $retries failed, retrying in $DEFAULT_RETRY_DELAY seconds..."
            sleep $DEFAULT_RETRY_DELAY
        fi
    done

    dns_log_error "Failed to remove DNS record after $DEFAULT_MAX_RETRIES attempts"
    return 1
}

dns_provider_test() {
    local provider="$1"

    if command -v "dns_${provider}_test" >/dev/null 2>&1; then
        "dns_${provider}_test"
    else
        dns_log_warn "Provider $provider does not support testing"
        return 0
    fi
}

dns_provider_info() {
    local provider="$1"

    if command -v "dns_${provider}_info" >/dev/null 2>&1; then
        "dns_${provider}_info"
    else
        echo "DNS Provider: $provider"
        echo "No additional information available"
    fi
}

# Command handlers
dns_cmd_add() {
    local domain="$1"
    local txt_value="$2"

    if ! dns_validate_domain "$domain"; then
        return 1
    fi

    if ! dns_validate_txt_value "$txt_value"; then
        return 1
    fi

    if [ -z "$DNS_PROVIDER" ]; then
        dns_log_error "DNS_PROVIDER not set in configuration"
        return 1
    fi

    if ! dns_load_provider "$DNS_PROVIDER"; then
        return 1
    fi

    dns_log_info "Adding DNS TXT record for $domain using $DNS_PROVIDER"

    if dns_provider_add "$DNS_PROVIDER" "$domain" "$txt_value"; then
        dns_log_info "DNS record added successfully"

        # Wait for propagation if configured
        if [ "${DNS_PROPAGATION_WAIT:-0}" -gt 0 ]; then
            dns_log_info "Waiting ${DNS_PROPAGATION_WAIT}s for DNS propagation..."
            if dns_check_propagation "$domain" "$txt_value" "$DNS_PROPAGATION_WAIT"; then
                dns_log_info "DNS propagation verified"
            else
                dns_log_warn "DNS propagation could not be verified, but record was added"
            fi
        fi

        return 0
    else
        dns_log_error "Failed to add DNS record"
        return 1
    fi
}

dns_cmd_rm() {
    local domain="$1"
    local txt_value="$2"

    if ! dns_validate_domain "$domain"; then
        return 1
    fi

    if [ -z "$DNS_PROVIDER" ]; then
        dns_log_error "DNS_PROVIDER not set in configuration"
        return 1
    fi

    if ! dns_load_provider "$DNS_PROVIDER"; then
        return 1
    fi

    dns_log_info "Removing DNS TXT record for $domain using $DNS_PROVIDER"

    if dns_provider_rm "$DNS_PROVIDER" "$domain" "$txt_value"; then
        dns_log_info "DNS record removed successfully"
        return 0
    else
        dns_log_error "Failed to remove DNS record"
        return 1
    fi
}

dns_cmd_test() {
    if [ -z "$DNS_PROVIDER" ]; then
        dns_log_error "DNS_PROVIDER not set in configuration"
        return 1
    fi

    if ! dns_load_provider "$DNS_PROVIDER"; then
        return 1
    fi

    dns_log_info "Testing DNS provider: $DNS_PROVIDER"

    if dns_provider_test "$DNS_PROVIDER"; then
        dns_log_info "DNS provider test successful"
        return 0
    else
        dns_log_error "DNS provider test failed"
        return 1
    fi
}

dns_cmd_info() {
    local provider="${1:-$DNS_PROVIDER}"

    if [ -z "$provider" ]; then
        dns_log_error "No DNS provider specified"
        return 1
    fi

    if ! dns_load_provider "$provider"; then
        return 1
    fi

    dns_provider_info "$provider"
    return 0
}

dns_cmd_list() {
    echo "Supported DNS Providers:"
    echo "========================"
    echo ""

    for provider in $SUPPORTED_PROVIDERS; do
        echo "- $provider"
        if [ -f "$SCRIPT_DIR/dns_${provider}.sh" ]; then
            echo "  Status: Available"
        else
            echo "  Status: Missing provider script"
        fi
        echo ""
    done

    echo "Current Configuration:"
    echo "- DNS_PROVIDER: ${DNS_PROVIDER:-not set}"
    echo "- DNS_PROPAGATION_WAIT: ${DNS_PROPAGATION_WAIT:-120}s"
    echo "- DNS_TIMEOUT: ${DNS_TIMEOUT:-30}s"
    echo "- MAX_RETRIES: ${MAX_RETRIES:-3}"
}

# Main function
main() {
    local command="$1"
    local domain="$2"
    local token="$3"
    local key_auth="$4"

    # Show usage if no command provided
    if [ -z "$command" ]; then
        echo "DNS API Framework v$DNS_API_VERSION"
        echo "Usage: dns_api.sh <command> <domain> [token] [key_auth]"
        echo ""
        echo "Commands:"
        echo "  add <domain> <token> <key_auth>  - Add TXT record for ACME challenge"
        echo "  rm <domain> <token> <key_auth>   - Remove TXT record"
        echo "  test                             - Test DNS provider connectivity"
        echo "  info [provider]                  - Show provider information"
        echo "  list                             - List all supported providers"
        echo ""
        echo "Configuration is loaded from renew.cfg"
        echo "Set DNS_PROVIDER to specify which provider to use"
        echo ""
        echo "ACME Integration:"
        echo "This script is called by acme_tiny.py during DNS-01 challenges"
        echo "The TXT value is calculated from the key_auth parameter"
        return 1
    fi

    # Handle commands
    case "$command" in
        "add")
            if [ -z "$domain" ]; then
                dns_log_error "Usage: dns_api.sh add <domain> <token> <key_auth>"
                return 1
            fi
            if [ -z "$TXT_VALUE" ]; then
                dns_log_error "Failed to calculate TXT value - key authorization required"
                return 1
            fi
            dns_cmd_add "$domain" "$TXT_VALUE"
            ;;
        "rm"|"remove")
            if [ -z "$domain" ]; then
                dns_log_error "Usage: dns_api.sh rm <domain> <token> <key_auth>"
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
        *)
            dns_log_error "Unknown command: $command"
            dns_log_info "Run 'dns_api.sh' without arguments to see usage"
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
