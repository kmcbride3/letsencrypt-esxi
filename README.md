# Let's Encrypt for VMware ESXi

`w2c-letsencrypt-esxi` is a lightweight open-source solution to automatically obtain and renew Let's Encrypt certificates on standalone VMware ESXi servers. Packaged as a _VIB archive_ or _Offline Bundle_, install/upgrade/removal is possible directly via the web UI or, alternatively, with just a few SSH commands.

## Key Features

- **Fully-automated**: Requesting and renewing certificates without user interaction
- **Auto-renewal**: A cronjob runs once a week to check if a certificate is due for renewal
- **Persistent**: The certificate, private key and all settings are preserved over ESXi upgrades
- **Configurable**: Customizable parameters for renewal interval, Let's Encrypt (ACME) backend, etc
- **Flexible Challenge Types**: Supports both HTTP-01 and DNS-01 ACME challenges
- **DNS-01 Support**: Multiple DNS providers supported (Cloudflare, Route53, DigitalOcean, Namecheap, GoDaddy, PowerDNS, DuckDNS, NS1, Google Cloud DNS, Azure DNS, Manual)
- **Robust Error Handling**: Exponential backoff retry logic with permanent vs. transient error detection
- **Advanced DNS Features**: Multi-resolver propagation checking, authoritative nameserver validation
- **Performance Optimized**: Intelligent caching system and rate limiting protection
- **ESXi Optimized**: Designed specifically for ESXi 6.5+ BusyBox shell environment

_Successfully tested with ESXi 6.5, 6.7, 7.0, 8.0._

## Why?

Many ESXi servers are accessible over the Internet and use self-signed X.509 certificates for TLS connections. This situation not only leads to annoying warnings in the browser when calling the Web UI, but can also be the reason for serious security problems. Despite the enormous popularity of [Let's Encrypt](https://letsencrypt.org), there is no convenient way to automatically request, renew or remove certificates in ESXi.

## Challenge Types

This solution supports two ACME challenge types:

### HTTP-01 Challenge (Default)

- **Use case**: ESXi servers that are publicly accessible over the Internet
- **Requirements**: Port 80 must be reachable from the Internet
- **Pros**: Simple setup, no DNS configuration required
- **Cons**: Requires public accessibility

### DNS-01 Challenge

- **Use case**: ESXi servers that are NOT publicly accessible (behind firewalls, private networks)
- **Requirements**: API access to your DNS provider
- **Pros**: Works for private/internal servers, supports wildcard certificates
- **Cons**: Requires DNS provider configuration

## Prerequisites

**Important Note**: ESXi servers use self-signed certificates by default (often using a non-FQDN hostname, such as `localhost.localdomain`). The requirement for a real domain name is a Let's Encrypt policy limitation, not a technical ESXi requirement. Let's Encrypt does not currently support certificates for localhost or IP addresses, though [RFC 8738](https://www.rfc-editor.org/rfc/rfc8738) support was planned but has been indefinitely shelved.

### For HTTP-01 Challenge (Default)

- Your server is publicly reachable over the Internet
- A _Fully Qualified Domain Name (FQDN)_ is set in ESXi
- The hostname you specified can be resolved via A and/or AAAA records in the corresponding DNS zone

### For DNS-01 Challenge

- A _Fully Qualified Domain Name (FQDN)_ is set in ESXi (does not need to be publicly accessible)
- Access to your DNS provider's API (see supported providers above)
- API credentials for your DNS provider

**Note:** As soon as you install this software, any existing, non Let's Encrypt certificate gets replaced!

For **HTTP-01 challenge**: No configuration is required - the system works out of the box with secure defaults.

For **DNS-01 challenge**: You must create a `renew.cfg` file to configure your DNS provider credentials.

### DNS-01 Configuration (Required)

Before using DNS-01 challenge, you need to configure your DNS provider:

1. **Set up your DNS provider credentials:**

   **Cloudflare:** Create an API token at <https://dash.cloudflare.com/profile/api-tokens> with `Zone:Edit` permissions

   **AWS Route53:** Create an IAM user with `Route53:ChangeResourceRecordSets` permissions

   **DigitalOcean:** Create an API token at <https://cloud.digitalocean.com/account/api/tokens> with read/write permissions

   **Namecheap:** Enable API access in account settings and whitelist your ESXi server's IP address

   **GoDaddy:** Create API credentials at <https://developer.godaddy.com/keys>

   **PowerDNS:** Enable the PowerDNS API on your authoritative server

   **DuckDNS:** Create a free account at <https://www.duckdns.org> (only works for `*.duckdns.org` domains)

   **NS1:** Create an API key at <https://my.nsone.net/#/account/settings> with DNS record management permissions

   **Google Cloud DNS:** Create a service account with DNS Administrator role and download the key file

   **Azure DNS:** Create a service principal with DNS Zone Contributor role

2. **Copy the configuration template:**

   ```shellsession
   cp /opt/w2c-letsencrypt/renew.cfg.example /opt/w2c-letsencrypt/renew.cfg
   ```

3. **Edit the configuration file:**

   ```shellsession
   vi /opt/w2c-letsencrypt/renew.cfg
   ```

4. **Set your challenge type and DNS provider credentials:** Example below shows minimum required configuration for Cloudflare

   ```ini
   CHALLENGE_TYPE="dns-01"

   DNS_PROVIDER="cloudflare"

   CF_API_TOKEN="your-cloudflare-api-token"
   ```

## Install

`w2c-letsencrypt-esxi` can be installed via SSH or the Web UI (= Embedded Host Client).

### SSH on ESXi

```shellsession
$ wget -O /tmp/w2c-letsencrypt-esxi.vib https://github.com/w2c/letsencrypt-esxi/releases/latest/download/w2c-letsencrypt-esxi.vib

$ esxcli software vib install -v /tmp/w2c-letsencrypt-esxi.vib -f
Installation Result
   Message: Operation finished successfully.
   Reboot Required: false
   VIBs Installed: web-wack-creations_bootbank_w2c-letsencrypt-esxi_1.0.0-0.0.0
   VIBs Removed:
   VIBs Skipped:

$ esxcli software vib list | grep w2c
w2c-letsencrypt-esxi  1.0.0-0.0.0  web-wack-creations  CommunitySupported  2022-05-29

$ cat /var/log/syslog.log | grep w2c
2022-05-29T20:01:46Z /etc/init.d/w2c-letsencrypt: Running 'start' action
2022-05-29T20:01:46Z /opt/w2c-letsencrypt/renew.sh: Starting certificate renewal.
2022-05-29T20:01:46Z /opt/w2c-letsencrypt/renew.sh: Existing cert for example.com not issued by Let's Encrypt. Requesting a new one!
2022-05-29T20:02:02Z /opt/w2c-letsencrypt/renew.sh: Success: Obtained and installed a certificate from Let's Encrypt.
```

### Web UI (= Embedded Host Client)

1. _Storage -> Datastores:_ Use the Datastore browser to upload the [VIB file](https://github.com/w2c/letsencrypt-esxi/releases/latest/download/w2c-letsencrypt-esxi.vib) to a datastore path of your choice.
2. _Manage -> Security & users:_ Set the acceptance level of your host to _Community_.
3. _Manage -> Packages:_ Switch to the list of installed packages, click on _Install update_ and enter the absolute path on the datastore where your just uploaded VIB file resides.
4. While the VIB is installed, ESXi requests a certificate from Let's Encrypt using HTTP-01 challenge (default). If you want to use DNS-01, configure your DNS provider first (see Configuration section above) and then run `/etc/init.d/w2c-letsencrypt start` via SSH.
5. If you reload the Web UI afterwards, the newly requested certificate should already be active. If not, see the [Wiki](https://github.com/w2c/letsencrypt-esxi/wiki) for troubleshooting.

### Configuration (Optional for HTTP-01)

DNS-01 challenges require configuration of the DNS provider by creating a `renew.cfg` file. You have the option of customizing the behavior for either challenge type through this file as well. A comprehensive template (`renew.cfg.example`) is included for reference - copy it as your starting point:

```shellsession
cp /opt/w2c-letsencrypt/renew.cfg.example /opt/w2c-letsencrypt/renew.cfg
vi /opt/w2c-letsencrypt/renew.cfg
```

Example configuration showing key settings you can customize. All settings are commented out (using `#`) to match the template - uncomment and modify as needed:

```ini
# Let's Encrypt ESXi Configuration Template
#
# USAGE:
# 1. Copy this file: cp renew.cfg.example renew.cfg
# 2. Edit renew.cfg and uncomment/configure settings as needed
# 3. For HTTP-01 (default): No configuration required - works out of the box
# 4. For DNS-01: Uncomment CHALLENGE_TYPE, DNS_PROVIDER, and provider credentials
#
# This file is safe to use as-is with default HTTP-01 behavior.
# All non-default settings are commented out to prevent configuration errors.

# =============================================================================
# LET'S ENCRYPT SETTINGS
# =============================================================================
# Let's Encrypt server URL (default: production)
# Uncomment below line for staging/testing (issues test certificates)
#DIRECTORY_URL="https://acme-staging-v02.api.letsencrypt.org/directory"

# Certificate renewal interval in days (default: 30)
# Certificates are renewed this many days before expiration
#RENEW_DAYS=14

# Domain name for certificate (default: uses ESXi hostname)
# Override only if hostname doesn't match desired certificate domain
#DOMAIN=$(hostname -f)

# Challenge type: "http-01" or "dns-01" (default: "http-01")
#CHALLENGE_TYPE="dns-01"

# =============================================================================
# DNS PROVIDER CONFIGURATION (Required for DNS-01)
# =============================================================================
# Primary DNS provider - choose one:
# Supported: cloudflare, route53, digitalocean, namecheap, godaddy, powerdns,
#           duckdns, ns1, gcloud, azure, manual
#DNS_PROVIDER="cloudflare"

# ⚠️  WARNING: The "manual" provider requires user interaction and will NOT work
#    with automated renewals (cron jobs). Use only for testing or one-time
#    certificate generation. For production ESXi deployments, use an automated
#    provider like cloudflare, route53, gcloud, azure, etc.

# DNS challenge settings
#DNS_PROPAGATION_WAIT=120        # Seconds to wait for DNS propagation
#DNS_PROPAGATION_CHECK=1         # Enable active DNS propagation checking (1) or use fixed wait (0)
#DNS_TIMEOUT=30                  # API request timeout in seconds
#MAX_RETRIES=3                   # Maximum retry attempts for failed API calls
#RETRY_DELAY=5                   # Base delay between retries (exponential backoff)
#DEBUG=0                         # Enable debug logging (0=off, 1=on)
#DNS_CACHE_TTL=120               # Cache TTL in seconds (2 minutes for ESXi)

# DNS provider-specific settings
# Uncomment and configure the provider you want to use

# Cloudflare
# Create an API token at https://dash.cloudflare.com/profile/api-tokens with Zone:Edit permissions
#CF_API_TOKEN="your-cloudflare-api-token"

# OR use Global API Key (legacy method)
# #CF_API_KEY="your-cloudflare-api-key"
# #CF_EMAIL="your-cloudflare-account-email"

# Cloudflare-specific settings
#CF_TTL=120                      # TTL for DNS records (seconds)
#CF_PROXY=false                  # Enable Cloudflare proxy for records (true/false)

# Amazon Route53
# Create an IAM user on AWS with Route53:ChangeResourceRecordSets permissions
#AWS_ACCESS_KEY_ID="your-access-key"
#AWS_SECRET_ACCESS_KEY="your-secret-key"
#AWS_DEFAULT_REGION="us-east-1"

# Route53-specific settings
#R53_TTL=120                     # TTL for DNS records (seconds)
#R53_HOSTED_ZONE_ID=""          # Optional: specify zone ID directly

# Google Cloud DNS
# Create a service account with DNS Administrator role and download the key file
#GCLOUD_SERVICE_ACCOUNT_FILE="/path/to/service-account-key.json"

# Azure DNS
# Create a service principal with DNS Zone Contributor role
#AZURE_CLIENT_ID="your-azure-client-id"
#AZURE_CLIENT_SECRET="your-azure-client-secret"
#AZURE_TENANT_ID="your-azure-tenant-id"
#AZURE_SUBSCRIPTION_ID="your-azure-subscription-id"

# DigitalOcean
# Create an API token at https://cloud.digitalocean.com/account/api/tokens
#DO_API_TOKEN="your-digitalocean-api-token"

# DigitalOcean-specific settings
#DO_TTL=120                      # TTL for DNS records (seconds)

# Namecheap
# Enable API access in account settings and whitelist your ESXi server's IP address
#NAMECHEAP_API_USER="your-namecheap-api-user"
#NAMECHEAP_API_KEY="your-namecheap-api-key"
#NAMECHEAP_USERNAME="your-namecheap-username"

# GoDaddy
# Create API credentials at https://developer.godaddy.com/keys
#GODADDY_API_KEY="your-godaddy-api-key"
#GODADDY_API_SECRET="your-godaddy-api-secret"

# PowerDNS
# Enable the PowerDNS API on your authoritative server
#POWERDNS_API_URL="https://your-powerdns-server:8081"
#POWERDNS_API_KEY="your-powerdns-api-key"

# DuckDNS
# Create a free account at https://www.duckdns.org (only works for *.duckdns.org domains)
#DUCKDNS_TOKEN="your-duckdns-token"

# NS1
# Create an API key at https://my.nsone.net/#/account/settings with DNS record management permissions
#NS1_API_KEY="your-ns1-api-key"

# =============================================================================
# ADVANCED SETTINGS (rarely need to change)
# =============================================================================
# File paths for certificates and keys
# Override only if you need custom file locations
#ACCOUNTKEY="esxi_account.key"
#KEY="esxi.key"
#CSR="esxi.csr"
#CRT="esxi.crt"
#VMWARE_CRT="/etc/vmware/ssl/rui.crt"
#VMWARE_KEY="/etc/vmware/ssl/rui.key"

# =============================================================================
```

To apply your modifications, run `/etc/init.d/w2c-letsencrypt start`

## Uninstall

Remove the installed `w2c-letsencrypt-esxi` package via SSH:

```shellsession
$ esxcli software vib remove -n w2c-letsencrypt-esxi
Removal Result
   Message: Operation finished successfully.
   Reboot Required: false
   VIBs Installed:
   VIBs Removed: web-wack-creations_bootbank_w2c-letsencrypt-esxi_1.0.0-0.0.0
   VIBs Skipped:
```

This action will purge `w2c-letsencrypt-esxi`, undo any changes to system files (cronjob and port redirection) and finally call `/sbin/generate-certificates` to generate and install a new, self-signed certificate.

## Usage

Usually, fully-automated. No interaction required.

### Hostname Change

If you change the hostname on our ESXi instance, the domain the certificate is issued for will mismatch. In that case, either re-install `w2c-letsencrypt-esxi` or simply run `/etc/init.d/w2c-letsencrypt start`, e.g.:

```shellsession
$ esxcfg-advcfg -s new-example.com /Misc/hostname
Value of HostName is new-example.com

$ /etc/init.d/w2c-letsencrypt start
Running 'start' action
Starting certificate renewal.
Existing cert issued for example.com but current domain name is new-example.com. Requesting a new one!
Generating RSA private key, 4096 bit long modulus
...
```

### Force Renewal

You already have a valid certificate from Let's Encrypt but nonetheless want to renew it now:

```shellsession
rm /etc/vmware/ssl/rui.crt
/etc/init.d/w2c-letsencrypt start
```

## Testing Your Configuration

Before running the certificate renewal, you can test your setup:

### Test DNS Provider Configuration (DNS-01 only)

```shellsession
# Test DNS record creation/deletion with the modular DNS API framework
/opt/w2c-letsencrypt/test_dns.sh
```

### Test System Prerequisites

```shellsession
# Check system compatibility and network connectivity
/opt/w2c-letsencrypt/test_system.sh
```

### Dry Run Certificate Renewal

```shellsession
# Remove existing certificate to force renewal (if needed)
rm /etc/vmware/ssl/rui.crt

# Run the renewal process
/etc/init.d/w2c-letsencrypt start
```

## How does it work?

The renewal process works differently depending on the challenge type you choose:

### Common Steps

- Checks if the current certificate is issued by Let's Encrypt and due for renewal (_default:_ 30d in advance)
- Generates a 4096-bit RSA keypair and CSR
- Configures ESXi firewall to allow required outgoing connections
- Uses an **enhanced version** of [acme-tiny](https://github.com/diafygi/acme-tiny) for all interactions with Let's Encrypt
  - Extended with DNS-01 challenge support while maintaining the same lightweight, auditable principles
  - Improved error handling and Python 3.5 compatibility for ESXi environments
  - DNS functionality implemented via modular provider framework to keep the core script clean
- Installs the retrieved certificate and gracefully restarts all services relying on it
- Adds a cronjob to check periodically if the certificate is due for renewal (_default:_ weekly on Sunday, 00:00)

### HTTP-01 Challenge Flow

- Instructs `rhttpproxy` to route all requests to `/.well-known/acme-challenge` to a custom port
- Temporarily enables `webAccess` and `vSphereClient` firewall rules if needed
- Starts an HTTP server on a non-privileged port to fulfill Let's Encrypt challenges
- Uses settings from `renew.cfg` for staging/production server and renewal intervals
- Let's Encrypt validates domain ownership by accessing the challenge file via HTTP

### DNS-01 Challenge Flow

- Temporarily enables `httpClient` firewall rule to allow DNS API calls
- Uses the configured DNS provider (Cloudflare, Route53, DigitalOcean, Namecheap, GoDaddy, PowerDNS, DuckDNS, NS1, Google Cloud DNS, Azure DNS, and manual) to create TXT records
- Calls `dns_api.sh` framework to manage DNS record creation and cleanup through modular provider plugins
- Uses settings from `renew.cfg` for DNS provider, API credentials, and propagation timing
- Leverages enhanced acme-tiny with DNS-01 support, keeping the same lightweight philosophy
- Let's Encrypt validates domain ownership by checking DNS TXT records
- Works for private/internal servers and supports wildcard certificates

## Demo

Here are sample outputs when invoking the script manually via SSH:

### HTTP-01 Challenge Example

```shellsession
$ /etc/init.d/w2c-letsencrypt start

Running 'start' action
Starting certificate renewal.
Existing cert for example.com not issued by Let's Encrypt. Requesting a new one!
Generating RSA private key, 4096 bit long modulus
***************************************************************************++++
e is 65537 (0x10001)
Serving HTTP on 0.0.0.0 port 8120 ...
Parsing account key...
Parsing CSR...
Found domains: example.com
Getting directory...
Directory found!
Registering account...
Already registered!
Creating new order...
Order created!
Verifying example.com...
127.0.0.1 - - [29/May/2022 13:14:14] "GET /.well-known/acme-challenge/Ps8VO0v9YzohqfHgnW1xQkHuOKnY0nDakmV9QnrVnVE HTTP/1.1" 200 -
127.0.0.1 - - [29/May/2022 13:14:16] "GET /.well-known/acme-challenge/Ps8VO0v9YzohqfHgnW1xQkHuOKnY0nDakmV9QnrVnVE HTTP/1.1" 200 -
127.0.0.1 - - [29/May/2022 13:14:17] "GET /.well-known/acme-challenge/Ps8VO0v9YzohqfHgnW1xQkHuOKnY0nDakmV9QnrVnVE HTTP/1.1" 200 -
127.0.0.1 - - [29/May/2022 13:14:17] "GET /.well-known/acme-challenge/Ps8VO0v9YzohqfHgnW1xQkHuOKnY0nDakmV9QnrVnVE HTTP/1.1" 200 -
127.0.0.1 - - [29/May/2022 13:14:21] "GET /.well-known/acme-challenge/Ps8VO0v9YzohqfHgnW1xQkHuOKnY0nDakmV9QnrVnVE HTTP/1.1" 200 -
example.com verified!
Signing certificate...
Certificate signed!
Success: Obtained and installed a certificate from Let's Encrypt.
hostd signalled.
rabbitmqproxy is not running
VMware HTTP reverse proxy signalled.
sfcbd-init: Getting Exclusive access, please wait...
sfcbd-init: Exclusive access granted.
vpxa signalled.
vsanperfsvc is not running.
/etc/init.d/vvold ssl_reset, PID 2129283
vvold is not running.
```

### DNS-01 Challenge Example

```shellsession
$ /etc/init.d/w2c-letsencrypt start

Running 'start' action
Starting certificate renewal.
Existing cert for example.com not issued by Let's Encrypt. Requesting a new one!
Generating RSA private key, 4096 bit long modulus
***************************************************************************++++
e is 65537 (0x10001)
Parsing account key...
Parsing CSR...
Found domains: example.com
Getting directory...
Directory found!
Registering account...
Already registered!
Creating new order...
Order created!
Verifying example.com...
DNS-01 challenge: Creating TXT record _acme-challenge.example.com
DNS challenge deployed successfully
Waiting 30 seconds for DNS propagation...
example.com verified!
DNS-01 challenge: Removing TXT record _acme-challenge.example.com
DNS challenge cleanup completed
Signing certificate...
Certificate signed!
Success: Obtained and installed a certificate from Let's Encrypt.
hostd signalled.
rabbitmqproxy is not running
VMware HTTP reverse proxy signalled.
sfcbd-init: Getting Exclusive access, please wait...
sfcbd-init: Exclusive access granted.
vpxa signalled.
vsanperfsvc is not running.
/etc/init.d/vvold ssl_reset, PID 2129283
vvold is not running.
```

## Troubleshooting

See the [Wiki](https://github.com/w2c/letsencrypt-esxi/wiki) for possible pitfalls and solutions.

## License

```text
w2c-letsencrypt-esxi is free software;
you can redistribute it and/or modify it under the terms of the
GNU General Public License as published by the Free Software Foundation,
either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
```
