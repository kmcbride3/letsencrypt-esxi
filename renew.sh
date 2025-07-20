#!/bin/sh
#
# Copyright (c) Johannes Feichtner <johannes@web-wack.at>
# Released under the GNU GPLv3 License.

DOMAIN=$(hostname -f)
LOCALDIR=$(dirname "$(readlink -f "$0")")
LOCALSCRIPT=$(basename "$0")

ACMEDIR="$LOCALDIR/.well-known/acme-challenge"
SSL_CERT_FILE="$LOCALDIR/ca-certificates.crt"
RENEW_DAYS=30

ACCOUNTKEY="esxi_account.key"
VMWARE_CRT="/etc/vmware/ssl/rui.crt"
VMWARE_KEY="/etc/vmware/ssl/rui.key"

# Default to HTTP-01 challenge
CHALLENGE_TYPE="http-01"
DNS_PROVIDER=""
DNS_PROPAGATION_WAIT=30

if [ -r "$LOCALDIR/renew.cfg" ]; then
  . "$LOCALDIR/renew.cfg"
fi

export CHALLENGE_TYPE
export DNS_PROVIDER
export DNS_PROPAGATION_WAIT
# Export common provider variables (add more as needed)
export CF_API_TOKEN
export CF_API_KEY
export CF_EMAIL
export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION
export DIRECTORY_URL
export CONTACT_EMAIL
export ACCOUNTKEY
export KEY
export CSR
export CRT
export VMWARE_CRT
export VMWARE_KEY
export SSL_CERT_FILE

log() {
   echo "$@"
   logger -p daemon.info -t "$0" "$@"
}

log "Starting certificate renewal.";

# Preparation steps
if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "${DOMAIN/.}" ]; then
  log "Error: Hostname ${DOMAIN} is no FQDN."
  exit
fi

# Add a cronjob for auto renewal. The script is run once a week on Sunday at 00:00
if ! grep -q "$LOCALDIR/$LOCALSCRIPT" /var/spool/cron/crontabs/root; then
  kill -sighup "$(pidof crond)" 2>/dev/null
  echo "0    0    *   *   0   /bin/sh $LOCALDIR/$LOCALSCRIPT" >> /var/spool/cron/crontabs/root
  crond
fi

# Check issuer and expiration date of existing cert
if [ -e "$VMWARE_CRT" ]; then
  # If the cert is issued for a different hostname, request a new one
  SAN=$(openssl x509 -in "$VMWARE_CRT" -text -noout | grep DNS: | sed 's/DNS://g' | xargs)
  if [ "$SAN" != "$DOMAIN" ] ; then
    log "Existing cert issued for ${SAN} but current domain name is ${DOMAIN}. Requesting a new one!"
  # If the cert is issued by Let's Encrypt, check its expiration date, otherwise request a new one
  elif openssl x509 -in "$VMWARE_CRT" -issuer -noout | grep -q "O=Let's Encrypt"; then
    CERT_VALID=$(openssl x509 -enddate -noout -in "$VMWARE_CRT" | cut -d= -f2-)
    log "Existing Let's Encrypt cert valid until: ${CERT_VALID}"
    if openssl x509 -checkend $((RENEW_DAYS * 86400)) -noout -in "$VMWARE_CRT"; then
      log "=> Longer than ${RENEW_DAYS} days. Aborting."
      exit
    else
      log "=> Less than ${RENEW_DAYS} days. Renewing!"
    fi
  else
    log "Existing cert for ${DOMAIN} not issued by Let's Encrypt. Requesting a new one!"
  fi
fi

cd "$LOCALDIR" || exit

# Setup based on challenge type
if [ "$CHALLENGE_TYPE" = "http-01" ]; then
  mkdir -p "$ACMEDIR"

  # Route /.well-known/acme-challenge to port 8120
  if ! grep -q "acme-challenge" /etc/vmware/rhttpproxy/endpoints.conf; then
    echo "/.well-known/acme-challenge local 8120 redirect allow" >> /etc/vmware/rhttpproxy/endpoints.conf
    /etc/init.d/rhttpproxy restart
  fi

  # Enable outbound HTTP client for ACME communication
  esxcli network firewall ruleset set -e true -r httpClient

  # Start HTTP server on port 8120 for HTTP validation
  python3 -m "http.server" 8120 &
  HTTP_SERVER_PID=$!

elif [ "$CHALLENGE_TYPE" = "dns-01" ]; then
  # Validate DNS provider configuration
  if [ -z "$DNS_PROVIDER" ]; then
    log "Error: DNS_PROVIDER must be set for dns-01 challenge"
    exit 1
  fi

  # Check for manual DNS provider - prevent automated renewal
  if [ "$DNS_PROVIDER" = "manual" ]; then
    # Detect if running in automated context (cron, etc.)
    if [ ! -t 0 ] || [ -z "$TERM" ] || [ "$TERM" = "dumb" ] || [ -n "$CRON" ]; then
      log "Manual DNS provider detected in automated context (likely cron job)."
      log "Skipping renewal to prevent user interaction requirements."
      log "Manual DNS certificates should be renewed manually by running:"
      log "  $LOCALDIR/$LOCALSCRIPT"
      log "Or change DNS_PROVIDER to an automated provider in renew.cfg"
      exit 0
    else
      log "Manual DNS provider detected. This will require interactive input."
      log "Press Ctrl+C now if you want to cancel and switch to an automated provider."
      sleep 3
    fi
  fi

  # Check if DNS API script exists
  if [ ! -x "$LOCALDIR/dnsapi/dns_api.sh" ]; then
    log "Error: DNS API script not found or not executable: $LOCALDIR/dnsapi/dns_api.sh"
    exit 1
  fi

  # Enable outbound HTTP client for ACME communication (if not already enabled)
  httpclient_enabled=$(esxcli network.firewall.ruleset list | grep "httpClient" | awk '{print $NF}')
  if [ "$httpclient_enabled" = "false" ]; then
    esxcli network firewall ruleset set -e true -r httpClient
    log "Enabled httpClient firewall rule for DNS-01"
  fi

  log "Using DNS provider: $DNS_PROVIDER"
fi

# Cert Request
if [ "$CHALLENGE_TYPE" = "http-01" ]; then
  CERT=$(python3 ./acme_tiny.py --account-key "$ACCOUNTKEY" --csr "$CSR" --acme-dir "$ACMEDIR" --directory-url "$DIRECTORY_URL" --challenge-type "$CHALLENGE_TYPE" 2>acme_error.log)
  [ -n "$HTTP_SERVER_PID" ] && kill -9 "$HTTP_SERVER_PID"
elif [ "$CHALLENGE_TYPE" = "dns-01" ]; then
  CERT=$(python3 ./acme_tiny.py --account-key "$ACCOUNTKEY" --csr "$CSR" --directory-url "$DIRECTORY_URL" --challenge-type "$CHALLENGE_TYPE" 2>acme_error.log)
fi

# If an error occurred during certificate issuance, $CERT will be empty
if [ -n "$CERT" ] ; then
  echo "$CERT" > "$CRT"
  # Provide the certificate to ESXi
  cp -p "$LOCALDIR/$KEY" "$VMWARE_KEY"
  cp -p "$LOCALDIR/$CRT" "$VMWARE_CRT"
  log "Success: Obtained and installed a certificate from Let's Encrypt."
elif openssl x509 -checkend 86400 -noout -in "$VMWARE_CRT"; then
  log "Warning: No cert obtained from Let's Encrypt. Keeping the existing one as it is still valid."
else
  log "Error: No cert obtained from Let's Encrypt. Generating a self-signed certificate."
  /sbin/generate-certificates
fi

for s in /etc/init.d/*; do if $s | grep ssl_reset > /dev/null; then $s ssl_reset; fi; done
