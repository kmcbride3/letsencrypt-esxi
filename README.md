# Let's Encrypt for VMware ESXi

`w2c-letsencrypt-esxi` is a lightweight open-source solution to automatically obtain and renew Let's Encrypt certificates on standalone VMware ESXi servers. Packaged as a _VIB archive_ or _Offline Bundle_, install/upgrade/removal is possible directly via the web UI or, alternatively, with just a few SSH commands.

Features:

- **Fully-automated**: Requesting and renewing certificates without user interaction
- **Auto-renewal**: A cronjob runs once a week to check if a certificate is due for renewal
- **Persistent**: The certificate, private key and all settings are preserved over ESXi upgrades
- **Configurable**: Customizable parameters for challenge type, renewal interval, Let's Encrypt (ACME) backend, etc

_Successfully tested with ESXi 6.5, 6.7, 7.0, 8.0._

## Why?

Many ESXi servers are accessible over the Internet and use self-signed X.509 certificates for TLS connections. This situation not only leads to annoying warnings in the browser when calling the Web UI, but can also be the reason for serious security problems. Despite the enormous popularity of [Let's Encrypt](https://letsencrypt.org), there is no convenient way to automatically request, renew or remove certificates in ESXi.

## Prerequisites

Before installing `w2c-letsencrypt-esxi`, ensure the following preconditions are met.

- A _Fully Qualified Domain Name (FQDN)_ must be set in ESXi. Something like `localhost.localdomain` will not work.

Additional requirements depend on the challenge type you plan to use:

### HTTP-01 Challenges

- Your server is publicly reachable over the Internet
- The hostname you specified can be resolved via A and/or AAAA records in the corresponding DNS zone

### DNS-01 Challenges

- Your server _does not_ need to be publicly reachable over the Internet; this method also allows wildcard certificates
- You must be able to manage DNS records for your domain (API credentials for supported providers, or manual access)

**Note:** As soon as you install this software, any existing, non Let's Encrypt certificate gets replaced!

## Install

`w2c-letsencrypt-esxi` can be installed via SSH or the Web UI (= Embedded Host Client).

### SSH on ESXi

```bash
$ wget -O /tmp/w2c-letsencrypt-esxi.vib https://github.com/w2c/letsencrypt-esxi/releases/latest/download/w2c-letsencrypt-esxi.vib

$ esxcli software vib install -v /tmp/w2c-letsencrypt-esxi.vib -f
Installation Result
   Message: Operation finished successfully.
   Reboot Required: false
   VIBs Installed: web-wack-creations_bootbank_w2c-letsencrypt-esxi_1.0.0-836582
   VIBs Removed:
   VIBs Skipped:

$ esxcli software vib list | grep w2c
w2c-letsencrypt-esxi  1.0.0-836582  web-wack-creations  CommunitySupported  2022-05-29

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
4. While the VIB is installed, ESXi requests a certificate from Let's Encrypt. If you reload the Web UI afterwards, the newly requested certificate should already be active. If not, see the [Wiki](https://github.com/w2c/letsencrypt-esxi/wiki) for troubleshooting.

### Configuration

An optional `renew.cfg` allows for using DNS-01 challenges and/or modifying default renewal period during the renewal process. It is **not necessary when using HTTP-01 challenges** and renewing certificates every 30 days. It is required when using DNS-01 challenges to specify your DNS provider and the necessary credentials (API token, keys, etc.), test renewal in the staging environment, modify renewal frequency, and for other advanced configuration. See [`renew.cfg.example`](renew.cfg.example) for all available settings and DNS provider variables.

It is recommended that you copy the provided example config to a persistent datastore and edit it there:

```bash
cp /opt/w2c-letsencrypt/renew.cfg.example /vmfs/volumes/<YOUR DATASTORE>/<PATH TO CONFIG>/renew.cfg
vi /vmfs/volumes/<YOUR DATASTORE>/<PATH TO CONFIG>/renew.cfg
```

#### Common configuration examples

- **Use Let's Encrypt staging environment and change the renewal interval:**

    ```bash
    DIRECTORY_URL="https://acme-staging-v02.api.letsencrypt.org/directory"
    RENEW_DAYS=15
    ```

- **Enable DNS-01 challenge (Cloudflare):**

    ```bash
    CHALLENGE_TYPE="dns-01"
    DNS_PROVIDER="cloudflare"
    CF_API_TOKEN="your-cloudflare-api-token"
    ```

- **Enable DNS-01 challenge (manual):**

    ```bash
    CHALLENGE_TYPE="dns-01"
    DNS_PROVIDER="manual"
    ```

    You will be prompted to create and remove DNS TXT records interactively. Certificates obtained this way cannot be renewed automatically, as manual intervention is always required.

**Note:** Automated renewal is only supported for providers with API support (e.g., Cloudflare).

#### Persisting configuration

Once the configuration file has been updated, you will need to take additional steps to make it persist between reboots. There are two options provided to assist with doing so.

##### Option 1: Built-in `config` action (recommended)

Use the built-in `config` action with the full path to the config file to install and persist it (by copying it to `/opt/w2c-letsencrypt`, updating `/etc/rc.local.d/local.sh` (after creating a backup), and running `/sbin/auto-backup.sh`):

```bash
/etc/init.d/w2c-letsencrypt config /vmfs/volumes/<YOUR DATASTORE>/<PATH TO CONFIG>/renew.cfg
```

##### Option 2: Manage persistence manually

1. Copy it into place for the current boot and secure it:

    ```bash
    cp /vmfs/volumes/<YOUR DATASTORE>/<PATH TO CONFIG>/renew.cfg /opt/w2c-letsencrypt/renew.cfg
    chmod 600 /opt/w2c-letsencrypt/renew.cfg
    chown root:root /opt/w2c-letsencrypt/renew.cfg
    ```

2. Back up and modify `/etc/rc.local.d/local.sh` to copy the datastore config on boot (insert the cp line before the final `exit 0`):

    ```bash
    cp /etc/rc.local.d/local.sh /etc/rc.local.d/local.sh.bak.YYYYMMDD
    # add before exit 0
    mkdir -p /opt/w2c-letsencrypt && cp /vmfs/volumes/<YOUR DATASTORE>/<PATH TO CONFIG>/renew.cfg /opt/w2c-letsencrypt/ && chmod 600 /opt/w2c-letsencrypt/renew.cfg && chown root:root /opt/w2c-letsencrypt/renew.cfg
    ```

3. Persist the edited `local.sh` so ESXi will keep it across reboots:

    ```bash
    /sbin/auto-backup.sh
    ```

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

This action will purge `w2c-letsencrypt-esxi`, undo any changes to system files (cronjob, local.sh, and port redirection) edited during installation or made through the `config`, and finally call `/sbin/generate-certificates` to generate and install a new, self-signed certificate.

## Usage

For HTTP-01 and DNS-01 with a supported API provider, operation is fully automated and requires no user interaction. For manual DNS-01, as you must interactively create and remove DNS TXT records each time, certificates cannot be renewed automatically.

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

You already have a valid certificate from Let's Encrypt but nonetheless want to renew it now. A safe method is provided through the `force` action:

```bash
/etc/init.d/w2c-letsencrypt force
```

Alternatively, if you prefer, you can remove the certificate yourself and then start renewal:

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

Here is a sample output when invoking the script manually via SSH using the default settings and the HTTP-01 challenge method:

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
