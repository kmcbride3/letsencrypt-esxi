#!/bin/sh
#
# DNS Configuration Test Script
# This script tests your DNS provider configuration before running the actual certificate renewal
#

LOCALDIR=$(dirname "$(readlink -f "$0")")
TEST_DOMAIN="test-$(date +%s).example.com"
TEST_VALUE="test-value-$(date +%s)"

# Load configuration
if [ -r "$LOCALDIR/renew.cfg" ]; then
    . "$LOCALDIR/renew.cfg"
else
    echo "Error: Configuration file not found. Please copy renew.cfg.example to renew.cfg and configure it."
    exit 1
fi

# Check if DNS challenge is configured
if [ "$CHALLENGE_TYPE" != "dns-01" ]; then
    echo "Challenge type is set to $CHALLENGE_TYPE. This test is only for DNS-01 challenges."
    exit 0
fi

if [ -z "$DNS_PROVIDER" ]; then
    echo "Error: DNS_PROVIDER not set in configuration"
    exit 1
fi

echo "Testing DNS provider configuration..."
echo "Provider: $DNS_PROVIDER"
echo "Test domain: $TEST_DOMAIN"
echo "Test value: $TEST_VALUE"
echo ""

# Set environment variables for the hook script
export ACME_CHALLENGE_TYPE="dns-01"
export ACME_DOMAIN="$TEST_DOMAIN"
export ACME_TOKEN="test-token"
export ACME_KEY_AUTH="test-key-auth"
export ACME_TXT_VALUE="$TEST_VALUE"

# Test DNS hook script
if [ ! -x "$LOCALDIR/dns_hook.sh" ]; then
    echo "Error: DNS hook script not found or not executable: $LOCALDIR/dns_hook.sh"
    exit 1
fi

echo "Step 1: Testing DNS record creation..."
if "$LOCALDIR/dns_hook.sh" setup "$TEST_DOMAIN" "test-token" "test-key-auth"; then
    echo "✓ DNS record creation test passed"
else
    echo "✗ DNS record creation test failed"
    exit 1
fi

echo ""
echo "Step 2: Waiting for DNS propagation..."
sleep 10

echo ""
echo "Step 3: Testing DNS record cleanup..."
if "$LOCALDIR/dns_hook.sh" cleanup "$TEST_DOMAIN" "test-token" "test-key-auth"; then
    echo "✓ DNS record cleanup test passed"
else
    echo "✗ DNS record cleanup test failed"
    exit 1
fi

echo ""
echo "✓ All DNS configuration tests passed!"
echo "Your DNS provider configuration appears to be working correctly."
echo "You can now run the certificate renewal with: /opt/w2c-letsencrypt/renew.sh"
