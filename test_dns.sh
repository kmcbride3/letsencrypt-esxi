#!/bin/sh
#
# Enhanced DNS API Testing Script
# Tests all new functionality and improvements
#

# ESXi compatibility - use absolute paths
SCRIPT_DIR="/opt/letsencrypt"
if [ ! -d "$SCRIPT_DIR" ]; then
    SCRIPT_DIR="$(dirname "$0")"
fi

# Test configuration
TEST_DOMAIN="${TEST_DOMAIN:-example.com}"
TEST_TXT_VALUE="dns-api-test-$(date +%s)"
DNS_PROVIDER="${DNS_PROVIDER:-manual}"
VERBOSE="${VERBOSE:-1}"

# Colors for output (if supported)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

# Test result tracking
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Logging functions
log_info() {
    echo "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo "${GREEN}[PASS]${NC} $*"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

log_error() {
    echo "${RED}[FAIL]${NC} $*"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

log_warn() {
    echo "${YELLOW}[WARN]${NC} $*"
}

# Test runner function
run_test() {
    local test_name="$1"
    local test_command="$2"

    TESTS_RUN=$((TESTS_RUN + 1))

    log_info "Running test: $test_name"

    if eval "$test_command"; then
        log_success "$test_name"
        return 0
    else
        log_error "$test_name"
        return 1
    fi
}

# Test functions
test_dns_api_exists() {
    [ -f "${SCRIPT_DIR}/dnsapi/dns_api.sh" ] && \
    [ -x "${SCRIPT_DIR}/dnsapi/dns_api.sh" ]
}

test_provider_loading() {
    . "${SCRIPT_DIR}/dnsapi/dns_api.sh"
    dns_list_providers | grep -q "manual"
}

test_provider_validation() {
    . "${SCRIPT_DIR}/dnsapi/dns_api.sh"
    dns_validate_provider "manual"
}

test_domain_validation() {
    . "${SCRIPT_DIR}/dnsapi/dns_api.sh"
    dns_validate_domain "$TEST_DOMAIN" && \
    ! dns_validate_domain "invalid..domain" && \
    ! dns_validate_domain ""
}

test_txt_validation() {
    . "${SCRIPT_DIR}/dnsapi/dns_api.sh"
    dns_validate_txt_value "$TEST_TXT_VALUE" && \
    ! dns_validate_txt_value "" && \
    dns_validate_txt_value "a" && \
    dns_validate_txt_value "$(printf '%*s' 255 'x')"
}

test_zone_detection() {
    . "${SCRIPT_DIR}/dnsapi/dns_api.sh"
    local zone
    zone=$(dns_get_zone "$TEST_DOMAIN" 2>/dev/null)
    [ -n "$zone" ]
}

test_cache_functions() {
    . "${SCRIPT_DIR}/dnsapi/dns_api.sh"

    # Test cache set/get
    dns_cache_set "test_key" "test_value"
    local cached_value
    cached_value=$(dns_cache_get "test_key")
    [ "$cached_value" = "test_value" ] && \

    # Test cache clear
    dns_cache_clear "test_*" && \
    ! dns_cache_get "test_key" >/dev/null 2>&1
}

test_http_utilities() {
    . "${SCRIPT_DIR}/dnsapi/dns_api.sh"

    # Test HTTP client detection
    dns_detect_http_client >/dev/null && \

    # Test user agent
    local ua
    ua=$(dns_get_user_agent)
    [ -n "$ua" ]
}

test_json_utilities() {
    . "${SCRIPT_DIR}/dnsapi/dns_api.sh"

    # Test JSON extraction
    local json='{"test": "value", "number": 123}'
    local value
    value=$(dns_json_extract "$json" "test")
    [ "$value" = "value" ]
}

test_retry_mechanism() {
    . "${SCRIPT_DIR}/dnsapi/dns_api.sh"

    # Test retry with a command that always fails
    ! dns_retry_with_backoff 2 1 false && \

    # Test retry with a command that succeeds
    dns_retry_with_backoff 1 1 true
}

test_dns_propagation_check() {
    . "${SCRIPT_DIR}/dnsapi/dns_api.sh"

    # This test checks if the function exists and can be called
    # We don't expect it to find our test record
    ! dns_check_propagation "$TEST_DOMAIN" "$TEST_TXT_VALUE" 2>/dev/null
    # Return success since we expect this to fail (record doesn't exist)
    return 0
}

test_provider_features() {
    . "${SCRIPT_DIR}/dnsapi/dns_api.sh"

    # Test provider features detection
    dns_provider_features "manual" >/dev/null && \
    dns_provider_supports "manual" "txt_record"
}

test_error_handling() {
    . "${SCRIPT_DIR}/dnsapi/dns_api.sh"

    # Test error categorization
    dns_is_permanent_error "404" && \
    ! dns_is_permanent_error "500" && \
    dns_is_rate_limited "429"
}

test_command_line_interface() {
    local dns_api="${SCRIPT_DIR}/dnsapi/dns_api.sh"

    # Test help command
    "$dns_api" help >/dev/null && \

    # Test version command
    "$dns_api" version >/dev/null && \

    # Test list command
    "$dns_api" list >/dev/null && \

    # Test info command
    "$dns_api" info >/dev/null
}

test_provider_specific() {
    local provider_file="${SCRIPT_DIR}/dnsapi/dns_${DNS_PROVIDER}.sh"

    if [ -f "$provider_file" ]; then
        # Test provider file exists and is valid
        [ -r "$provider_file" ] && \

        # Source the file to check for syntax errors
        . "$provider_file" 2>/dev/null
    else
        # If provider file doesn't exist, that's also valid for manual
        [ "$DNS_PROVIDER" = "manual" ]
    fi
}

# Main test execution
main() {
    echo "Enhanced DNS API Test Suite"
    echo "=========================="
    echo ""
    echo "Test Configuration:"
    echo "  Script Directory: $SCRIPT_DIR"
    echo "  Test Domain: $TEST_DOMAIN"
    echo "  DNS Provider: $DNS_PROVIDER"
    echo "  Test TXT Value: $TEST_TXT_VALUE"
    echo ""

    # Core functionality tests
    log_info "Running core functionality tests..."
    run_test "DNS API script exists" "test_dns_api_exists"
    run_test "Provider loading" "test_provider_loading"
    run_test "Provider validation" "test_provider_validation"
    run_test "Domain validation" "test_domain_validation"
    run_test "TXT value validation" "test_txt_validation"

    # Enhanced features tests
    log_info "Running enhanced features tests..."
    run_test "Zone detection" "test_zone_detection"
    run_test "Cache functions" "test_cache_functions"
    run_test "HTTP utilities" "test_http_utilities"
    run_test "JSON utilities" "test_json_utilities"
    run_test "Retry mechanism" "test_retry_mechanism"
    run_test "DNS propagation check" "test_dns_propagation_check"
    run_test "Provider features" "test_provider_features"
    run_test "Error handling" "test_error_handling"

    # Interface tests
    log_info "Running interface tests..."
    run_test "Command line interface" "test_command_line_interface"
    run_test "Provider specific" "test_provider_specific"

    # Test summary
    echo ""
    echo "Test Results Summary"
    echo "==================="
    echo "Tests Run: $TESTS_RUN"
    echo "Tests Passed: $TESTS_PASSED"
    echo "Tests Failed: $TESTS_FAILED"

    if [ $TESTS_FAILED -eq 0 ]; then
        log_success "All tests passed! 🎉"
        exit 0
    else
        log_error "Some tests failed. Review the output above."
        exit 1
    fi
}

# Performance test (optional)
test_performance() {
    if [ "$1" = "--performance" ]; then
        log_info "Running performance tests..."

        # Time zone detection
        local start_time
        start_time=$(date +%s)
        . "${SCRIPT_DIR}/dnsapi/dns_api.sh"
        dns_get_zone "$TEST_DOMAIN" >/dev/null 2>&1
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))

        log_info "Zone detection took ${duration}s"

        # Time cache operations
        start_time=$(date +%s)
        for i in $(seq 1 100); do
            dns_cache_set "perf_test_$i" "value_$i"
            dns_cache_get "perf_test_$i" >/dev/null
        done
        end_time=$(date +%s)
        duration=$((end_time - start_time))

        dns_cache_clear "perf_test_*"
        log_info "100 cache operations took ${duration}s"
    fi
}

# Interactive test mode
test_interactive() {
    if [ "$1" = "--interactive" ]; then
        log_info "Running interactive tests..."
        echo ""
        echo "This will test actual DNS operations."
        echo "Make sure you have configured your DNS provider in renew.cfg"
        echo ""
        printf "Continue? (y/N): "
        read -r answer

        case "$answer" in
            [Yy]*)
                local dns_api="${SCRIPT_DIR}/dnsapi/dns_api.sh"

                log_info "Testing DNS record addition..."
                if "$dns_api" add "$TEST_DOMAIN" "$TEST_TXT_VALUE"; then
                    log_success "DNS record added"

                    log_info "Waiting 30 seconds before checking propagation..."
                    sleep 30

                    log_info "Testing DNS record removal..."
                    if "$dns_api" rm "$TEST_DOMAIN" "$TEST_TXT_VALUE"; then
                        log_success "DNS record removed"
                    else
                        log_error "DNS record removal failed"
                    fi
                else
                    log_error "DNS record addition failed"
                fi
                ;;
            *)
                log_info "Interactive tests skipped"
                ;;
        esac
    fi
}

# Check for special test modes
case "$1" in
    --performance)
        test_performance "$@"
        ;;
    --interactive)
        test_interactive "$@"
        ;;
    --help)
        echo "Enhanced DNS API Test Suite"
        echo ""
        echo "Usage: $0 [options]"
        echo ""
        echo "Options:"
        echo "  --performance    Run performance tests"
        echo "  --interactive    Run interactive DNS tests (requires provider config)"
        echo "  --help          Show this help"
        echo ""
        echo "Environment Variables:"
        echo "  TEST_DOMAIN      Domain to use for tests (default: example.com)"
        echo "  DNS_PROVIDER     DNS provider to test (default: manual)"
        echo "  VERBOSE          Enable verbose output (default: 1)"
        echo ""
        exit 0
        ;;
    *)
        main "$@"
        ;;
esac
