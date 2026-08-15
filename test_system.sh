#!/bin/sh
#
# Comprehensive test script for Let's Encrypt ESXi DNS-01 implementation
#

LOCALDIR=$(dirname "$(readlink -f "$0")")
TEST_DOMAIN="test-$(date +%s).example.com"
FAILED_TESTS=0
TOTAL_TESTS=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_test() {
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    echo "Test $TOTAL_TESTS: $1"
}

log_pass() {
    echo "${GREEN}✓ PASS${NC}: $1"
}

log_fail() {
    echo "${RED}✗ FAIL${NC}: $1"
    FAILED_TESTS=$((FAILED_TESTS + 1))
}

log_warn() {
    echo "${YELLOW}⚠ WARN${NC}: $1"
}

# Test 1: Check required files exist
log_test "Checking required files exist"
for file in "acme_tiny.py" "dnsapi/dns_api.sh" "renew.sh" "renew.cfg.example"; do
    if [ -f "$LOCALDIR/$file" ]; then
        log_pass "$file exists"
    else
        log_fail "$file missing"
    fi
done

# Check DNS API providers
log_test "Checking DNS API providers"
for provider in "dns_cloudflare.sh" "dns_route53.sh" "dns_digitalocean.sh" "dns_manual.sh"; do
    if [ -f "$LOCALDIR/dnsapi/$provider" ]; then
        log_pass "dnsapi/$provider exists"
    else
        log_fail "dnsapi/$provider missing"
    fi
done

# Test 2: Check file permissions
log_test "Checking file permissions"
for script in "dnsapi/dns_api.sh" "renew.sh"; do
    if [ -x "$LOCALDIR/$script" ]; then
        log_pass "$script is executable"
    else
        log_fail "$script is not executable"
    fi
done

# Check DNS provider scripts
for provider in "dnsapi/dns_cloudflare.sh" "dnsapi/dns_route53.sh" "dnsapi/dns_digitalocean.sh" "dnsapi/dns_manual.sh"; do
    if [ -x "$LOCALDIR/$provider" ]; then
        log_pass "$provider is executable"
    else
        log_warn "$provider is not executable (may not be critical)"
    fi
done

# Test 3: Python syntax check
log_test "Checking Python syntax"
if python -m py_compile "$LOCALDIR/acme_tiny.py" 2>/dev/null; then
    log_pass "acme_tiny.py syntax is valid"
else
    log_fail "acme_tiny.py has syntax errors"
fi

# Test 4: Configuration file
log_test "Checking configuration"
if [ -f "$LOCALDIR/renew.cfg" ]; then
    log_pass "renew.cfg exists"

    # Check for required DNS settings
    if grep -q "CHALLENGE_TYPE.*dns-01" "$LOCALDIR/renew.cfg"; then
        log_pass "DNS-01 challenge type configured"
    else
        log_warn "DNS-01 challenge type not configured"
    fi

    if grep -q "DNS_PROVIDER.*=" "$LOCALDIR/renew.cfg" && ! grep -q "DNS_PROVIDER=\"\"" "$LOCALDIR/renew.cfg"; then
        log_pass "DNS provider configured"
    else
        log_warn "DNS provider not configured"
    fi
else
    log_warn "renew.cfg not found - copy from renew.cfg.example"
fi

# Test 5: OpenSSL availability
log_test "Checking OpenSSL"
if command -v openssl >/dev/null 2>&1; then
    log_pass "OpenSSL is available"
    openssl version
else
    log_fail "OpenSSL not found"
fi

# Test 6: Python availability
log_test "Checking Python"
if command -v python >/dev/null 2>&1; then
    log_pass "Python is available"
    python --version
else
    log_fail "Python not found"
fi

# Test 7: DNS API framework
log_test "Testing DNS API framework"
if "$LOCALDIR/dnsapi/dns_api.sh" help 2>&1 | grep -q "Usage:"; then
    log_pass "DNS API framework responds correctly"
else
    log_fail "DNS API framework doesn't respond correctly"
fi

# Test provider listing
log_test "Testing DNS provider listing"
if "$LOCALDIR/dnsapi/dns_api.sh" list 2>/dev/null | grep -q "Available DNS providers:"; then
    log_pass "DNS provider listing works"
else
    log_fail "DNS provider listing failed"
fi

# Test 8: ACME tiny help
log_test "Testing acme_tiny.py"
if python "$LOCALDIR/acme_tiny.py" --help >/dev/null 2>&1; then
    log_pass "acme_tiny.py responds to --help"
else
    log_fail "acme_tiny.py doesn't respond to --help"
fi

# Test 9: Network connectivity
log_test "Testing network connectivity"
if curl -s --connect-timeout 5 "https://acme-v02.api.letsencrypt.org/directory" >/dev/null; then
    log_pass "Can reach Let's Encrypt ACME endpoint"
else
    log_fail "Cannot reach Let's Encrypt ACME endpoint"
fi

# Test 10: ESXi specific checks
log_test "Checking ESXi environment"
if [ -d "/etc/vmware" ]; then
    log_pass "ESXi environment detected"

    if [ -f "/etc/vmware/ssl/rui.crt" ]; then
        log_pass "Current ESXi certificate found"
        echo "Current certificate expires: $(openssl x509 -enddate -noout -in /etc/vmware/ssl/rui.crt | cut -d= -f2)"
    else
        log_warn "No current ESXi certificate found"
    fi
else
    log_warn "Not running on ESXi (testing environment?)"
fi

# Summary
echo ""
echo "=========================================="
echo "TEST SUMMARY"
echo "=========================================="
echo "Total tests: $TOTAL_TESTS"
echo "Passed: $((TOTAL_TESTS - FAILED_TESTS))"
echo "Failed: $FAILED_TESTS"

if [ $FAILED_TESTS -eq 0 ]; then
    echo "${GREEN}All tests passed! Ready for certificate renewal.${NC}"
    echo ""
    echo "Next steps:"
    echo "1. Configure your DNS provider in renew.cfg"
    echo "2. Test with staging: ./test_dns.sh"
    echo "3. Run renewal: ./renew.sh"
    exit 0
else
    echo "${RED}Some tests failed. Please fix issues before proceeding.${NC}"
    exit 1
fi
