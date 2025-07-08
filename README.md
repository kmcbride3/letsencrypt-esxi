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

Before using DNS-01 challenge, you need to configure your DNS provider:

1. Copy the configuration template:
   ```bash
   cp /opt/w2c-letsencrypt/renew.cfg.example /opt/w2c-letsencrypt/renew.cfg
   ```

2. Edit the configuration file:
   ```bash
   vi /opt/w2c-letsencrypt/renew.cfg
   ```

3. Set your challenge type and DNS provider:
   ```bash
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

```bash
$ wget -O /tmp/w2c-letsencrypt-esxi.vib https://github.com/kmcbride3/letsencrypt-esxi/releases/latest/download/w2c-letsencrypt-esxi.vib

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

1. _Storage -> Datastores:_ Use the Datastore browser to upload the [VIB file](https://github.com/kmcbride3/letsencrypt-esxi/releases/latest/download/w2c-letsencrypt-esxi.vib) to a datastore path of your choice.
2. _Manage -> Security & users:_ Set the acceptance level of your host to _Community_.
3. _Manage -> Packages:_ Switch to the list of installed packages, click on _Install update_ and enter the absolute path on the datastore where your just uploaded VIB file resides.
4. While the VIB is installed, ESXi requests a certificate from Let's Encrypt. If you reload the Web UI afterwards, the newly requested certificate should already be active. If not, see the [Wiki](https://github.com/kmcbride3/letsencrypt-esxi/wiki) for troubleshooting.

### Optional Configuration

If you want to try out the script before putting it into production, you may want to test against the [staging environment](https://letsencrypt.org/docs/staging-environment/) of Let's Encrypt. Probably, you also do not wish to renew certificates once in 30 days but in longer or shorter intervals. Most variables of `renew.sh` can be adjusted by creating a `renew.cfg` file with your overwritten values.

`vi /opt/w2c-letsencrypt/renew.cfg`

```bash
# Request a certificate from the staging environment
DIRECTORY_URL="https://acme-staging-v02.api.letsencrypt.org/directory"
# Set the renewal interval to 15 days
RENEW_DAYS=15
```

To apply your modifications, run `/etc/init.d/w2c-letsencrypt start`

## Uninstall

Remove the installed `w2c-letsencrypt-esxi` package via SSH:

```bash
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

```bash
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
```bash
rm /etc/vmware/ssl/rui.crt
/etc/init.d/w2c-letsencrypt start
```

## How does it work?

* Checks if the current certificate is issued by Let's Encrypt and due for renewal (_default:_ 30d in advance)
* Generates a 4096-bit RSA keypair and CSR
* Instructs `rhttpproxy` to route all requests to `/.well-known/acme-challenge` to a custom port
* Configures ESXi firewall to allow outgoing HTTP connections
* Uses [acme-tiny](https://github.com/diafygi/acme-tiny) for all interactions with Let's Encrypt
* Starts an HTTP server on a non-privileged port to fulfill Let's Encrypt challenges
* Installs the retrieved certificate and restarts all services relying on it
* Adds a cronjob to check periodically if the certificate is due for renewal (_default:_ weekly on Sunday, 00:00)

## Demo

Here is a sample output when invoking the script manually via SSH:

```bash
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

## Troubleshooting

See the [Wiki](https://github.com/kmcbride3/letsencrypt-esxi/wiki) for possible pitfalls and solutions.

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
