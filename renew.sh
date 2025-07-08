#!/bin/sh
#
# Copyright (c) Johannes Feichtner <johannes@web-wack.at>
# Released under the GNU GPLv3 License.

DOMAIN=$(hostname -f)
LOCALDIR=$(dirname "$(readlink -f "$0")")
LOCALSCRIPT=$(basename "$0")

ACMEDIR="$LOCALDIR/.well-known/acme-challenge"
DIRECTORY_URL="https://acme-v02.api.letsencrypt.org/directory"
SSL_CERT_FILE="$LOCALDIR/ca-certificates.crt"
RENEW_DAYS=30

# Default to HTTP-01 challenge
CHALLENGE_TYPE="http-01"
DNS_PROVIDER=""
DNS_PROPAGATION_WAIT=30

ACCOUNTKEY="esxi_account.key"
KEY="esxi.key"
CSR="esxi.csr"
CRT="esxi.crt"
VMWARE_CRT="/etc/vmware/ssl/rui.crt"
VMWARE_KEY="/etc/vmware/ssl/rui.key"

if [ -r "$LOCALDIR/renew.cfg" ]; then
  . "$LOCALDIR/renew.cfg"
fi

log() {
   echo "$@"
   logger -p daemon.info -t "$0" "$@"
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
    
  elif [ "$CHALLENGE_TYPE" = "dns-01" ]; then
    # Restore original httpClient state
    if [ -n "$ORIGINAL_HTTPCLIENT_STATE" ] && [ "$ORIGINAL_HTTPCLIENT_STATE" = "false" ]; then
      esxcli network firewall ruleset set -e false -r httpClient 2>/dev/null || true
      log "Restored httpClient firewall rule to disabled"
    fi
  fi
}

# Set trap to ensure cleanup on exit
trap cleanup_firewall EXIT INT TERM

log "Starting certificate renewal using $CHALLENGE_TYPE challenge.";

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
  
  # Firewall management for HTTP-01 (needs inbound access on port 80/443)
  log "Configuring firewall for HTTP-01 challenge..."
  
  # Check current firewall state
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
  
  # Enable outbound HTTP client for ACME communication
  esxcli network firewall ruleset set -e true -r httpClient
  
  # Start HTTP server on port 8120 for HTTP validation
  python -m "http.server" 8120 &
  HTTP_SERVER_PID=$!
  
elif [ "$CHALLENGE_TYPE" = "dns-01" ]; then
  # Validate DNS provider configuration
  if [ -z "$DNS_PROVIDER" ]; then
    log "Error: DNS_PROVIDER must be set for dns-01 challenge"
    exit 1
  fi
  
  # Check if DNS hook script exists
  if [ ! -x "$LOCALDIR/dns_hook.sh" ]; then
    log "Error: DNS hook script not found or not executable: $LOCALDIR/dns_hook.sh"
    exit 1
  fi
  
  # Firewall management for DNS-01 (only needs outbound access)
  log "Configuring firewall for DNS-01 challenge..."
  
  # Store current httpClient state for restoration
  httpclient_enabled=$(esxcli network firewall ruleset list | grep "httpClient" | awk '{print $NF}')
  ORIGINAL_HTTPCLIENT_STATE="$httpclient_enabled"
  
  # Enable outbound HTTP client for ACME communication (if not already enabled)
  if [ "$httpclient_enabled" = "false" ]; then
    esxcli network firewall ruleset set -e true -r httpClient
    log "Enabled httpClient firewall rule for DNS-01"
  fi
  
  log "Using DNS provider: $DNS_PROVIDER"
fi

# Cert Request
[ ! -r "$ACCOUNTKEY" ] && openssl genrsa 4096 > "$ACCOUNTKEY"

openssl genrsa -out "$KEY" 4096
openssl req -new -sha256 -key "$KEY" -subj "/CN=$DOMAIN" -config "./openssl.cnf" > "$CSR"
chmod 0400 "$ACCOUNTKEY" "$KEY"

# Retrieve the certificate
export SSL_CERT_FILE

if [ "$CHALLENGE_TYPE" = "http-01" ]; then
  CERT=$(python ./acme_tiny.py --account-key "$ACCOUNTKEY" --csr "$CSR" --acme-dir "$ACMEDIR" --directory-url "$DIRECTORY_URL" --challenge-type "$CHALLENGE_TYPE")
elif [ "$CHALLENGE_TYPE" = "dns-01" ]; then
  CERT=$(python ./acme_tiny.py --account-key "$ACCOUNTKEY" --csr "$CSR" --directory-url "$DIRECTORY_URL" --challenge-type "$CHALLENGE_TYPE")
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

# Cleanup firewall rules (also handled by trap, but explicit cleanup for clarity)
cleanup_firewall

# Restart services that need to reload SSL certificates
log "Restarting ESXi services to reload certificates..."

# Function to safely restart a service
restart_service_safely() {
    local service_path="$1"
    local service_name=$(basename "$service_path")
    
    # Skip problematic files and services
    case "$service_name" in
        README*|*.md|*.txt|*.conf|*.bak|*.orig|*.log)
            return 0
            ;;
        ibm_pciinfo_provider_autorun.sh)
            # This service has known output issues, skip it
            return 0
            ;;
    esac
    
    # Check if file is executable
    if [ ! -x "$service_path" ]; then
        return 0
    fi
    
    # Try to restart the service, suppressing common error messages
    if "$service_path" ssl_reset 2>/dev/null; then
        log "Restarted $service_name successfully"
        return 0
    fi
    
    return 1
}

# Find and restart services that support ssl_reset
restarted_count=0
for service in /etc/init.d/*; do
    # Only process if it's a file (not a directory)
    if [ -f "$service" ]; then
        if restart_service_safely "$service"; then
            restarted_count=$((restarted_count + 1))
        fi
    fi
done

# If no services were restarted via ssl_reset, try critical services manually
if [ "$restarted_count" -eq 0 ]; then
    log "No ssl_reset services found, restarting critical services manually..."
    
    # Critical ESXi services that need certificate reload
    for service_name in hostd vpxa rhttpproxy; do
        service_path="/etc/init.d/$service_name"
        if [ -x "$service_path" ]; then
            log "Restarting $service_name..."
            if "$service_path" restart >/dev/null 2>&1; then
                log "Successfully restarted $service_name"
                restarted_count=$((restarted_count + 1))
            else
                log "Warning: Failed to restart $service_name (non-critical)"
            fi
        fi
    done
fi

log "Service restart complete. Restarted $restarted_count services."
