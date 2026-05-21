#!/bin/sh
#
# Copyright (c) Johannes Feichtner <johannes@web-wack.at>
# Released under the GNU GPLv3 License.

# ESXi-compatible path resolution - fallback if readlink -f is not available
if readlink -f "$0" >/dev/null 2>&1; then
  LOCALDIR=$(dirname "$(readlink -f "$0")")
else
  # Fallback for BusyBox versions without readlink -f
  LOCALDIR=$(cd "$(dirname "$0")" && pwd)
fi
LOCALSCRIPT=$(basename "$0")

# Define log function early so it can be used throughout the script
log() {
   echo "$@" >&2
   logger -p daemon.info -t "$0" "$@"
}

# Load user configuration from the install directory if present.
CONFIG="$LOCALDIR/renew.cfg"
if [ -r "${CONFIG}" ]; then
  . "${CONFIG}"
  log "Loaded configuration from ${CONFIG}"
elif [ -f "${CONFIG}" ]; then
  log "Warning: ${CONFIG} exists but is not readable (check permissions)"
fi

# Ensure defaults are present even if renew.cfg leaves values unset/empty.
DOMAIN="${DOMAIN:-$(hostname -f)}"
ACMEDIR="${ACMEDIR:-$LOCALDIR/.well-known/acme-challenge}"
DIRECTORY_URL="${DIRECTORY_URL:-https://acme-v02.api.letsencrypt.org/directory}"
SSL_CERT_FILE="${SSL_CERT_FILE:-$LOCALDIR/ca-certificates.crt}"
RENEW_DAYS="${RENEW_DAYS:-30}"
ACCOUNTKEY="${ACCOUNTKEY:-esxi_account.key}"
KEY="${KEY:-esxi.key}"
CSR="${CSR:-esxi.csr}"
CRT="${CRT:-esxi.crt}"
VMWARE_CRT="${VMWARE_CRT:-/etc/vmware/ssl/rui.crt}"
VMWARE_KEY="${VMWARE_KEY:-/etc/vmware/ssl/rui.key}"
CHALLENGE_TYPE="${CHALLENGE_TYPE:-http-01}"
DNS_PROVIDER="${DNS_PROVIDER:-}"
DNS_MAX_WAIT="${DNS_MAX_WAIT:-300}"
DEBUG="${DEBUG:-0}"

# Validate and cap DNS max wait to prevent excessive waits
if [ "$CHALLENGE_TYPE" = "dns-01" ] && [ "$DNS_MAX_WAIT" -gt 600 ]; then
  log "Warning: DNS_MAX_WAIT is set to $DNS_MAX_WAIT seconds (>10 minutes), capping at 600 seconds"
  DNS_MAX_WAIT=600
fi

# Export configuration variables (excluding credentials which will be passed inline to subprocesses)
export CHALLENGE_TYPE DNS_PROVIDER DNS_MAX_WAIT \
  DIRECTORY_URL CONTACT_EMAIL DEBUG \
  KEY CSR CRT VMWARE_CRT VMWARE_KEY SSL_CERT_FILE

# Lockfile for preventing concurrent runs
LOCKFILE="/var/lock/w2c-letsencrypt.lock"

# Create lockfile atomically using mkdir (POSIX; avoids TOCTOU race)
LOCKDIR="${LOCKFILE}.lk"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  if [ -d "$LOCKDIR" ]; then
    log "Another renewal is already in progress (lock: $LOCKDIR). Exiting."
  else
    log "Error: Failed to create lock directory: $LOCKDIR"
    log "Possible causes: permission denied, read-only filesystem, or missing parent directory."
  fi
  exit 1
fi
trap "rmdir '$LOCKDIR' 2>/dev/null" EXIT INT TERM
log "Starting certificate renewal."

# Preparation steps
if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "${DOMAIN/.}" ]; then
  log "Error: Hostname ${DOMAIN} is no FQDN."
  exit
fi

# Add a cronjob for auto renewal. The script is run once a week on Sunday at 00:00
if ! grep -q "$LOCALDIR/$LOCALSCRIPT" /var/spool/cron/crontabs/root; then
  crond_pid=$(pidof crond 2>/dev/null)
  if [ -n "$crond_pid" ]; then
    kill -sighup "$crond_pid" 2>/dev/null || true
  fi
  echo "0    0    *   *   0   /bin/sh $LOCALDIR/$LOCALSCRIPT" >> /var/spool/cron/crontabs/root
  crond 2>/dev/null || true
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
      exit 0
    else
      log "=> Less than ${RENEW_DAYS} days. Renewing!"
    fi
  else
    log "Existing cert for ${DOMAIN} not issued by Let's Encrypt. Requesting a new one!"
  fi
fi

cd "$LOCALDIR" || exit

# Detect if we're running in an automated context (cron, etc.)
is_automated_run() {
    if [ ! -t 0 ]; then return 0; fi
    if [ -z "$TERM" ] || [ "$TERM" = "dumb" ]; then return 0; fi
    if [ -n "$CRON" ]; then return 0; fi
    if ps -o comm= -p $PPID 2>/dev/null | grep -q "crond"; then return 0; fi
    return 1
}

# Cleanup function to restore firewall rules
cleanup_firewall() {
  if [ "$CHALLENGE_TYPE" = "http-01" ]; then
    # Kill HTTP server if still running
    if [ -n "$HTTP_SERVER_PID" ]; then
      kill -9 "$HTTP_SERVER_PID" 2>/dev/null || true
    fi
    # Restore original firewall states
    if [ -n "$ORIGINAL_WEBACCESS_STATE" ] && [ "$ORIGINAL_WEBACCESS_STATE" = "false" ]; then
      esxcli network firewall ruleset set -e false -r webAccess 2>/dev/null || true
      log "Restored webAccess firewall rule to disabled"
    fi
    if [ -n "$ORIGINAL_VSPHERE_STATE" ] && [ "$ORIGINAL_VSPHERE_STATE" = "false" ]; then
      esxcli network firewall ruleset set -e false -r vSphereClient 2>/dev/null || true
      log "Restored vSphereClient firewall rule to disabled"
    fi
  fi
  # Both challenge types use httpClient for ACME communication
  if [ -n "$ORIGINAL_HTTPCLIENT_STATE" ] && [ "$ORIGINAL_HTTPCLIENT_STATE" = "false" ]; then
    esxcli network firewall ruleset set -e false -r httpClient 2>/dev/null || true
    log "Restored httpClient firewall rule to disabled"
  fi
}

trap cleanup_firewall EXIT INT TERM

# Helper to enable outbound ACME firewall rule and store state
enable_httpclient_firewall() {
  httpclient_enabled=$(esxcli network firewall ruleset list | grep "httpClient" | awk '{print $NF}')
  ORIGINAL_HTTPCLIENT_STATE="$httpclient_enabled"
  if [ "$httpclient_enabled" = "false" ]; then
    esxcli network firewall ruleset set -e true -r httpClient
    log "Enabled httpClient firewall rule for ACME communication"
  fi
}

# Setup based on challenge type
if [ "$CHALLENGE_TYPE" = "http-01" ]; then
  mkdir -p "$ACMEDIR"

  # Route /.well-known/acme-challenge to port 8120
  if ! grep -q "acme-challenge" /etc/vmware/rhttpproxy/endpoints.conf; then
    echo "/.well-known/acme-challenge local 8120 redirect allow" >> /etc/vmware/rhttpproxy/endpoints.conf
    /etc/init.d/rhttpproxy restart
  fi

  # Firewall management for HTTP-01 (needs inbound access on port 80/443)
  log "Configuring firewall for HTTP-01 challenge..."
  firewall_enabled=$(esxcli network firewall get | grep "Enabled:" | awk '{print $NF}')
  webaccess_enabled=$(esxcli network firewall ruleset list | grep "webAccess" | awk '{print $NF}')
  vsphere_enabled=$(esxcli network firewall ruleset list | grep "vSphereClient" | awk '{print $NF}')
  # Store original states for restoration
  ORIGINAL_FIREWALL_STATE="$firewall_enabled"
  ORIGINAL_WEBACCESS_STATE="$webaccess_enabled"
  ORIGINAL_VSPHERE_STATE="$vsphere_enabled"
  # Enable required rulesets for HTTP-01
  if [ "$webaccess_enabled" = "false" ]; then
    esxcli network firewall ruleset set -e true -r webAccess
    log "Enabled webAccess firewall rule for HTTP-01"
  fi
  if [ "$vsphere_enabled" = "false" ]; then
    esxcli network firewall ruleset set -e true -r vSphereClient
    log "Enabled vSphereClient firewall rule for HTTP-01"
  fi
  # Enable outbound HTTP client for ACME communication (consolidated)
  enable_httpclient_firewall
  # Start HTTP server serving ONLY the acme-challenge subdirectory.
  # Scoping to ACMEDIR prevents exposure of private keys and renew.cfg in LOCALDIR.
  # exec inside the subshell ensures kill -9 hits the python process directly.
  if which python3 >/dev/null 2>&1; then
    ( cd "$ACMEDIR" && exec python3 -m http.server 8120 ) &
  elif which python >/dev/null 2>&1; then
    ( cd "$ACMEDIR" && exec python -m SimpleHTTPServer 8120 ) &
  else
    log "Error: No Python interpreter available for HTTP server"
    exit 1
  fi
  HTTP_SERVER_PID=$!

elif [ "$CHALLENGE_TYPE" = "dns-01" ]; then
  # Validate DNS provider configuration for DNS-01 challenge
  if [ -z "$DNS_PROVIDER" ]; then
    log "Error: DNS_PROVIDER must be set for dns-01 challenge"
    exit 1
  fi
  # Prevent automated renewal with manual DNS provider
  if [ "$DNS_PROVIDER" = "manual" ]; then
    if is_automated_run; then
      log "Manual DNS provider detected in automated context. Skipping renewal."
      log "Run manually: $LOCALDIR/$LOCALSCRIPT"
      exit 0
    else
      log "Manual DNS provider detected. This will require interactive input."
      sleep 3
    fi
  fi
  # Ensure DNS API script is present and executable
  if [ ! -x "$LOCALDIR/dnsapi/dns_api.sh" ]; then
    log "Error: DNS API script not found or not executable: $LOCALDIR/dnsapi/dns_api.sh"
    exit 1
  fi
  # Only outbound firewall access is needed for DNS-01
  log "Configuring firewall for DNS-01 challenge..."
  enable_httpclient_firewall
  log "Using DNS provider: $DNS_PROVIDER"
fi

# Generate required keys and CSR if they don't exist
log "Checking for required keys and CSR..."

# Generate account key if it doesn't exist
if [ ! -r "$ACCOUNTKEY" ]; then
  # If the file (or a dangling symlink) already exists we cannot read it —
  # abort instead of silently overwriting it.  The operator should inspect
  # and remove it manually before re-running.
  if [ -e "$ACCOUNTKEY" ] || [ -L "$ACCOUNTKEY" ]; then
    log "Error: Account key exists but is not readable: $ACCOUNTKEY"
    log "Check permissions or remove it manually to generate a new one."
    exit 1
  fi
  log "Generating account key: $ACCOUNTKEY"
  # Generate directly to the target path inside a restricted-umask subshell so
  # the file is created with mode 0600 in a single openssl operation.  This
  # eliminates the empty-file window that existed with the pre-create ':>' then
  # '>>' append pattern when the process was interrupted between the two steps.
  if ! ( umask 0177 && openssl genrsa -out "$ACCOUNTKEY" 4096 2>/dev/null ); then
    log "Error: Failed to generate account key"
    rm -f "$ACCOUNTKEY"
    exit 1
  fi
  chmod 0400 "$ACCOUNTKEY"
  log "Successfully generated account key"
fi

# Generate domain private key if it doesn't exist
if [ ! -r "$KEY" ]; then
  # Abort if the file exists but is unreadable rather than silently overwriting.
  if [ -e "$KEY" ] || [ -L "$KEY" ]; then
    log "Error: Domain key file exists but is not readable: $KEY"
    log "Check permissions or remove it manually to generate a new one."
    exit 1
  fi
  log "Generating domain private key: $KEY"
  if ! ( umask 0177 && openssl genrsa -out "$KEY" 4096 2>/dev/null ); then
    log "Error: Failed to generate domain private key"
    rm -f "$KEY"
    exit 1
  fi
  chmod 0400 "$KEY"
  log "Successfully generated domain private key"
fi

# Generate Certificate Signing Request if it doesn't exist or if domain changed
if [ ! -r "$CSR" ] || ! openssl req -in "$CSR" -noout -text 2>/dev/null | grep -q "CN.*$DOMAIN"; then
  log "Generating Certificate Signing Request: $CSR"
  # Use absolute path for config file and add SAN extension for modern compatibility
  if [ -f "$LOCALDIR/openssl.cnf" ]; then
    openssl req -new -sha256 -key "$KEY" -subj "/CN=$DOMAIN" -config "$LOCALDIR/openssl.cnf" -out "$CSR"
  else
    # Fallback: generate CSR without config file (simpler but should work)
    log "Warning: openssl.cnf not found, generating basic CSR"
    openssl req -new -sha256 -key "$KEY" -subj "/CN=$DOMAIN" -out "$CSR"
  fi

  # Verify CSR was created successfully
  if [ ! -f "$CSR" ] || [ ! -s "$CSR" ]; then
    log "Error: Failed to generate Certificate Signing Request"
    exit 1
  fi
  log "Successfully generated CSR for domain: $DOMAIN"
fi

# Retrieve the certificate - check for python3 first, fallback to python
export SSL_CERT_FILE
if which python3 >/dev/null 2>&1; then
  PYTHON_CMD="python3"
elif which python >/dev/null 2>&1; then
  PYTHON_CMD="python"
else
  log "Error: No Python interpreter available"
  exit 1
fi

if [ "$CHALLENGE_TYPE" = "http-01" ]; then
  # Pass account key only to this subprocess via env
  CERT=$(env ACCOUNTKEY="$ACCOUNTKEY" \
    "$PYTHON_CMD" ./acme_tiny.py --account-key "$ACCOUNTKEY" --csr "$CSR" --acme-dir "$ACMEDIR" --directory-url "$DIRECTORY_URL")
  ACME_EXIT=$?
elif [ "$CHALLENGE_TYPE" = "dns-01" ]; then
  # Pass account key and DNS provider credentials only to this subprocess via env
  CERT=$(env ACCOUNTKEY="$ACCOUNTKEY" CF_API_TOKEN="$CF_API_TOKEN" CF_API_KEY="$CF_API_KEY" CF_EMAIL="$CF_EMAIL" \
    "$PYTHON_CMD" ./acme_tiny.py --account-key "$ACCOUNTKEY" --csr "$CSR" --acme-dir "$ACMEDIR" --directory-url "$DIRECTORY_URL" --challenge-type "$CHALLENGE_TYPE")
  ACME_EXIT=$?
else
  log "Error: Invalid challenge type: $CHALLENGE_TYPE"
  exit 1
fi

if [ $ACME_EXIT -ne 0 ]; then
  log "Error: ACME certificate retrieval failed with exit code $ACME_EXIT"
fi

# Kill HTTP server if it was started for HTTP-01
[ "$CHALLENGE_TYPE" = "http-01" ] && [ -n "$HTTP_SERVER_PID" ] && kill -9 "$HTTP_SERVER_PID"

# If an error occurred during certificate issuance, $CERT will be empty
if [ -n "$CERT" ]; then
  echo "$CERT" > "$CRT" || { log "Error: Failed to write certificate to $CRT"; exit 1; }
  # Provide the certificate to ESXi
  cp -p "$LOCALDIR/$KEY" "$VMWARE_KEY" || { log "Error: Failed to copy private key to $VMWARE_KEY"; exit 1; }
  cp -p "$LOCALDIR/$CRT" "$VMWARE_CRT" || { log "Error: Failed to install certificate to $VMWARE_CRT"; exit 1; }
  log "Success: Obtained and installed a certificate from Let's Encrypt."
elif openssl x509 -checkend 86400 -noout -in "$VMWARE_CRT" 2>/dev/null; then
  log "Warning: No cert obtained from Let's Encrypt. Keeping the existing one as it is still valid."
else
  log "Error: No cert obtained from Let's Encrypt. Generating a self-signed certificate."
  /sbin/generate-certificates 2>/dev/null || { log "Error: Failed to generate self-signed certificate"; exit 1; }
fi

for s in /etc/init.d/*; do
  # Skip our own script to avoid recursion
  case "$(basename "$s")" in
    w2c-letsencrypt) continue ;;
  esac
  if [ -x "$s" ] && grep -q "ssl_reset" "$s" 2>/dev/null; then
    "$s" ssl_reset 2>/dev/null || true
  fi
done
