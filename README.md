# Let's Encrypt for VMware ESXi

`w2c-letsencrypt-esxi` is a lightweight open-source solution to automatically obtain and renew Let's Encrypt certificates on standalone VMware ESXi servers. Packaged as a _VIB archive_ or _Offline Bundle_, install/upgrade/removal is possible directly via the web UI or, alternatively, with just a few SSH commands.

Features:

- **Fully-automated**: Requesting and renewing certificates without user interaction
- **Auto-renewal**: A cronjob runs once a week to check if a certificate is due for renewal
- **Persistent**: The certificate, private key and all settings are preserved over ESXi upgrades
- **Configurable**: Customizable parameters for renewal interval, Let's Encrypt (ACME) backend, etc
- **Flexible Challenge Types**: Supports both HTTP-01 and DNS-01 ACME challenges
- **DNS Provider Support**: Built-in support for popular DNS providers (Cloudflare, AWS Route53, manual)

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

### For HTTP-01 Challenge (Default)
- Your server is publicly reachable over the Internet
- A _Fully Qualified Domain Name (FQDN)_ is set in ESXi. Something like `localhost.localdomain` will not work
- The hostname you specified can be resolved via A and/or AAAA records in the corresponding DNS zone

### For DNS-01 Challenge
- A _Fully Qualified Domain Name (FQDN)_ is set in ESXi
- Access to your DNS provider's API (currently supports Cloudflare, AWS Route53, or manual)
- API credentials for your DNS provider

**Note:** As soon as you install this software, any existing, non Let's Encrypt certificate gets replaced!

## Configuration

For **HTTP-01 challenge**: No configuration is required - the system works out of the box with secure defaults.

For **DNS-01 challenge**: You must create a `renew.cfg` file to configure your DNS provider credentials.

### DNS-01 Configuration (Required)

Before using DNS-01 challenge, you need to configure your DNS provider:

1. Copy the configuration template:
   ```shellsession
   cp /opt/w2c-letsencrypt/renew.cfg.example /opt/w2c-letsencrypt/renew.cfg
   ```

2. Edit the configuration file:
   ```shellsession
   vi /opt/w2c-letsencrypt/renew.cfg
   ```

3. Set your challenge type and DNS provider:
   ```ini
   # Challenge type: "http-01" or "dns-01"
   CHALLENGE_TYPE="dns-01"
   
   # DNS Provider: "cloudflare", "route53", or "manual"
   DNS_PROVIDER="cloudflare"
   
   # Cloudflare API Token (for Cloudflare)
   CF_API_TOKEN="your-cloudflare-api-token"
   
   # AWS credentials (for Route53)
   AWS_ACCESS_KEY_ID="your-access-key"
   AWS_SECRET_ACCESS_KEY="your-secret-key"
   ```

### DNS Provider Setup

#### Cloudflare
1. Create an API token at https://dash.cloudflare.com/profile/api-tokens
2. Grant the token `Zone:Edit` permissions for your domain
3. Set `CF_API_TOKEN` in your configuration

#### AWS Route53
1. Create an IAM user with `Route53:ChangeResourceRecordSets` permissions
2. Set `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` in your configuration

#### Manual DNS
1. Set `DNS_PROVIDER="manual"`
2. The script will prompt you to manually create/remove DNS records

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

Example configuration for testing against the [staging environment](https://letsencrypt.org/docs/staging-environment/) of Let's Encrypt or adjusting renewal intervals:

```ini
# OPTIONAL SETTINGS (both HTTP-01 and DNS-01)
# Request a certificate from the staging environment (default: production)
DIRECTORY_URL="https://acme-staging-v02.api.letsencrypt.org/directory"

# Set the renewal interval to 15 days (default: 30)
RENEW_DAYS=15

# REQUIRED SETTINGS (DNS-01 only)
# Challenge type: "http-01" or "dns-01" (default: "http-01")
CHALLENGE_TYPE="dns-01"

# DNS Provider: "cloudflare", "route53", or "manual" (required for DNS-01)
DNS_PROVIDER="cloudflare"

# Cloudflare API Token (required for Cloudflare DNS-01)
CF_API_TOKEN="your-cloudflare-api-token"

# OPTIONAL SETTINGS (DNS-01 only)
# Adjust DNS propagation wait time (default: 30 seconds)
DNS_PROPAGATION_WAIT=60
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
# Test DNS record creation/deletion
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
* Checks if the current certificate is issued by Let's Encrypt and due for renewal (_default:_ 30d in advance)
* Generates a 4096-bit RSA keypair and CSR
* Configures ESXi firewall to allow required outgoing connections
* Uses an **enhanced version** of [acme-tiny](https://github.com/diafygi/acme-tiny) for all interactions with Let's Encrypt
  * Extended with DNS-01 challenge support while maintaining the same lightweight, auditable principles
  * Improved error handling and Python 3.5 compatibility for ESXi environments
  * DNS functionality implemented via external hooks to keep the core script clean
* Installs the retrieved certificate and gracefully restarts all services relying on it
* Adds a cronjob to check periodically if the certificate is due for renewal (_default:_ weekly on Sunday, 00:00)

### HTTP-01 Challenge Flow
* Instructs `rhttpproxy` to route all requests to `/.well-known/acme-challenge` to a custom port
* Temporarily enables `webAccess` and `vSphereClient` firewall rules if needed
* Starts an HTTP server on a non-privileged port to fulfill Let's Encrypt challenges
* Uses settings from `renew.cfg` for staging/production server and renewal intervals
* Let's Encrypt validates domain ownership by accessing the challenge file via HTTP

### DNS-01 Challenge Flow  
* Temporarily enables `httpClient` firewall rule to allow DNS API calls
* Uses the configured DNS provider (Cloudflare, Route53, or manual) to create TXT records
* Calls `dns_hook.sh` to manage DNS record creation and cleanup automatically
* Uses settings from `renew.cfg` for DNS provider, API credentials, and propagation timing
* Leverages enhanced acme-tiny with DNS-01 support, keeping the same lightweight philosophy
* Let's Encrypt validates domain ownership by checking DNS TXT records
* Works for private/internal servers and supports wildcard certificates

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
