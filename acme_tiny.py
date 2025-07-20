#!/usr/bin/env python3
# Copyright Daniel Roesler, under MIT license, see LICENSE at github.com/diafygi/acme-tiny
import argparse, subprocess, json, os, sys, base64, binascii, time, hashlib, re, logging, socket
from urllib.request import urlopen, Request
from urllib.error import URLError

DEFAULT_DIRECTORY_URL = "https://acme-v02.api.letsencrypt.org/directory"

LOGGER = logging.getLogger(__name__)
LOGGER.addHandler(logging.StreamHandler())
LOGGER.setLevel(logging.INFO)

def get_crt(account_key, csr, acme_dir, log=LOGGER, disable_check=False, directory_url=DEFAULT_DIRECTORY_URL, contact=None, check_port=None, challenge_type="http-01", timeout=30):
    directory, acct_headers, alg, jwk = None, None, None, None # global variables

    def _b64_encode_jose(b):
        return base64.urlsafe_b64encode(b).decode('utf8').replace("=", "")

    # helper function - run external commands
    def _run_external_cmd(cmd_list, stdin=None, cmd_input=None, err_msg="Command Line Error"):
        proc = subprocess.Popen(cmd_list, stdin=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        out, err = proc.communicate(cmd_input)
        if proc.returncode != 0:
            try:
                error_msg = err.decode('utf8')
            except UnicodeDecodeError:
                error_msg = err.decode('utf8', errors='replace')
            raise IOError("{0}\n{1}".format(err_msg, error_msg))
        return out

    # helper function - make request and automatically parse json response
    def _do_request(url, data=None, err_msg="Error", depth=0):
        try:
            resp = urlopen(Request(url, data=data, headers={"Content-Type": "application/jose+json", "User-Agent": "acme-tiny"}), timeout=timeout)
            resp_data, code, headers = resp.read().decode("utf8"), resp.getcode(), resp.headers
        except socket.timeout:
            raise ValueError("{0}: Request timed out after {1} seconds".format(err_msg, timeout))
        except URLError as e:
            if hasattr(e, 'reason') and 'timed out' in str(e.reason):
                raise ValueError("{0}: Request timed out after {1} seconds".format(err_msg, timeout))
            raise ValueError("{0}: Network error: {1}".format(err_msg, str(e)))
        except IOError as e:
            resp_data = e.read().decode("utf8") if hasattr(e, "read") else str(e)
            code, headers = getattr(e, "code", None), {}
        try:
            resp_data = json.loads(resp_data) # try to parse json results
        except ValueError:
            pass # ignore json parsing errors
        if depth < 100 and code == 400 and resp_data['type'] == "urn:ietf:params:acme:error:badNonce":
            raise IndexError(resp_data) # allow 100 retrys for bad nonces
        if code not in [200, 201, 204]:
            raise ValueError("{0}:\nUrl: {1}\nData: {2}\nResponse Code: {3}\nResponse: {4}".format(err_msg, url, data, code, resp_data))
        return resp_data, code, headers

    # helper function - make signed requests
    def _send_signed_request(url, payload, err_msg, depth=0):
        payload64 = "" if payload is None else _b64_encode_jose(json.dumps(payload).encode('utf8'))
        new_nonce = _do_request(directory['newNonce'])[2]['Replay-Nonce']
        protected = {"url": url, "alg": alg, "nonce": new_nonce}
        protected.update({"jwk": jwk} if acct_headers is None else {"kid": acct_headers['Location']})
        protected64 = _b64_encode_jose(json.dumps(protected).encode('utf8'))
        protected_input = "{0}.{1}".format(protected64, payload64).encode('utf8')
        out = _run_external_cmd(["openssl", "dgst", "-sha256", "-sign", account_key], stdin=subprocess.PIPE, cmd_input=protected_input, err_msg="OpenSSL Error")
        data = json.dumps({"protected": protected64, "payload": payload64, "signature": _b64_encode_jose(out)})
        try:
            return _do_request(url, data=data.encode('utf8'), err_msg=err_msg, depth=depth)
        except IndexError: # retry bad nonces (they raise IndexError)
            return _send_signed_request(url, payload, err_msg, depth=(depth + 1))

    # helper function - poll until complete
    def _poll_until_complete(url, pending_statuses, err_msg):
        result, t0 = None, time.time()
        while result is None or result['status'] in pending_statuses:
            assert (time.time() - t0 < 3600), "Polling timeout" # 1 hour timeout
            time.sleep(0 if result is None else 2)
            result, _, _ = _send_signed_request(url, None, err_msg)
        return result

    # helper function - execute DNS API script for DNS-01 challenges
    def _execute_dns_api(action, domain, token, key_auth=None):
        api_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dnsapi")
        api_script = os.path.join(api_dir, "dns_api.sh")
        if not os.path.exists(api_script) or not os.access(api_script, os.X_OK):
            raise ValueError("DNS API script not found or not executable: {0}".format(api_script))

        env = os.environ.copy()
        env.update({
            'ACME_CHALLENGE_TYPE': challenge_type,
            'ACME_DOMAIN': domain,
            'ACME_TOKEN': token,
            'ACME_KEY_AUTH': key_auth or '',
            'DNS_PROVIDER': os.environ.get('DNS_PROVIDER', '')
        })

        cmd = ["/bin/sh",api_script, action, domain, token, key_auth or '']
        proc = subprocess.Popen(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        stdout, stderr = proc.communicate()

        if proc.returncode != 0:
            error_msg = stderr.decode('utf8', errors='replace')
            raise IOError("DNS API failed: {0}".format(error_msg))
        return stdout.decode('utf8', errors='replace')

    log.info("Parsing account key to get public key...")
    out = _run_external_cmd(["openssl", "rsa", "-in", account_key, "-noout", "-text"], err_msg="OpenSSL Error")
    pub_pattern = r"modulus:[\s]+?00:([a-f0-9\:\s]+?)\npublicExponent: ([0-9]+)"
    pub_hex, pub_exp = re.search(pub_pattern, out.decode('utf8'), re.MULTILINE|re.DOTALL).groups()
    pub_exp = "{0:x}".format(int(pub_exp))
    pub_exp = "0{0}".format(pub_exp) if len(pub_exp) % 2 else pub_exp
    alg, jwk = "RS256", {
        "e": _b64_encode_jose(binascii.unhexlify(pub_exp.encode("utf-8"))),
        "kty": "RSA",
        "n": _b64_encode_jose(binascii.unhexlify(re.sub(r"(\s|:)", "", pub_hex).encode("utf-8"))),
    }
    accountkey_json = json.dumps(jwk, sort_keys=True, separators=(',', ':'))
    thumbprint = _b64_encode_jose(hashlib.sha256(accountkey_json.encode('utf8')).digest())

    log.info("Parsing CSR to find domains...")
    out = _run_external_cmd(["openssl", "req", "-in", csr, "-noout", "-text"], err_msg="Error loading {0}".format(csr))
    domains = set([])
    common_name = re.search(r"Subject:.*? CN\s?=\s?([^\s,;/]+)", out.decode('utf8'))
    if common_name is not None:
        domains.add(common_name.group(1))
    subject_alt_names = re.search(r"X509v3 Subject Alternative Name: (?:critical)?\n +([^\n]+)\n", out.decode('utf8'), re.MULTILINE|re.DOTALL)
    if subject_alt_names is not None:
        for san in subject_alt_names.group(1).split(", "):
            if san.startswith("DNS:"):
                domains.add(san[4:])
    log.info(u"Found domains: {0}".format(", ".join(domains)))

    log.info("Getting ACME directory of urls...")
    directory, _, _ = _do_request(directory_url, err_msg="Error getting directory")
    log.info("Directory found!")

    # create account, update contact details (if any), and set the global key identifier
    log.info("Registering account...")
    reg_payload = {"termsOfServiceAgreed": True} if contact is None else {"termsOfServiceAgreed": True, "contact": contact}
    account, code, acct_headers = _send_signed_request(directory['newAccount'], reg_payload, "Error registering")
    log.info("{0} Account ID: {1}".format("Registered!" if code == 201 else "Already registered!", acct_headers['Location']))
    if contact is not None:
        account, _, _ = _send_signed_request(acct_headers['Location'], {"contact": contact}, "Error updating contact details")
        log.info("Updated contact details:\n{0}".format("\n".join(account.get('contact') or [])))

    # create a new order
    log.info("Creating new order...")
    order_payload = {"identifiers": [{"type": "dns", "value": d} for d in domains]}
    order, _, order_headers = _send_signed_request(directory['newOrder'], order_payload, "Error creating new order")
    log.info("Order created!")

    # get the authorizations that need to be completed
    for auth_url in order['authorizations']:
        authorization, _, _ = _send_signed_request(auth_url, None, "Error getting challenges")
        domain = authorization['identifier']['value']

        if authorization['status'] == "valid": # skip if already valid
            log.info("Already verified: {0}, skipping...".format(domain))
            continue
        log.info("Verifying {0}...".format(domain))

        # find the appropriate challenge
        challenge = None
        for c in authorization['challenges']:
            if c['type'] == challenge_type:
                challenge = c
                break

        if challenge is None:
            raise ValueError("Challenge type {0} not available for domain {1}".format(challenge_type, domain))

        token = re.sub(r"[^A-Za-z0-9_\-]", "_", challenge['token'])
        keyauthorization = "{0}.{1}".format(token, thumbprint)

        if challenge_type == "http-01":
            # HTTP-01 challenge (existing logic)
            wellknown_path = os.path.join(acme_dir, token)
            with open(wellknown_path, "w") as wellknown_file:
                wellknown_file.write(keyauthorization)

            # check that the file is in place
            try:
                wellknown_url = "http://{0}{1}/.well-known/acme-challenge/{2}".format(domain, "" if check_port is None else ":{0}".format(check_port), token)
                assert (disable_check or _do_request(wellknown_url)[0] == keyauthorization)
            except (AssertionError, ValueError) as e:
                raise ValueError("Wrote file to {0}, but couldn't download {1}: {2}".format(wellknown_path, wellknown_url, e))

        elif challenge_type == "dns-01":
            # DNS-01 challenge
            log.info("Setting up DNS challenge for {0}...".format(domain))
            _execute_dns_api("add", domain, token, keyauthorization)
            log.info("DNS challenge setup complete. Waiting for propagation...")
            # Wait for DNS propagation
            wait_time = int(os.getenv('DNS_PROPAGATION_WAIT', '30'))
            time.sleep(wait_time)

        # say the challenge is done
        _send_signed_request(challenge['url'], {}, "Error submitting challenges: {0}".format(domain))
        authorization = _poll_until_complete(auth_url, ["pending"], "Error checking challenge status for {0}".format(domain))

        # cleanup
        if challenge_type == "http-01":
            os.remove(wellknown_path)
        elif challenge_type == "dns-01":
            log.info("Cleaning up DNS challenge for {0}...".format(domain))
            _execute_dns_api("rm", domain, token, keyauthorization)

        if authorization['status'] != "valid":
            raise ValueError("Challenge did not pass for {0}: {1}".format(domain, authorization))
        log.info("{0} verified!".format(domain))

    # finalize the order with the csr
    log.info("Signing certificate...")
    csr_der = _run_external_cmd(["openssl", "req", "-in", csr, "-outform", "DER"], err_msg="DER Export Error")
    _send_signed_request(order['finalize'], {"csr": _b64_encode_jose(csr_der)}, "Error finalizing order")

    # poll the order to monitor when it's done
    order = _poll_until_complete(order_headers['Location'], ["pending", "processing"], "Error checking order status")
    if order['status'] != "valid":
        raise ValueError("Order failed: {0}".format(order))

    # download the certificate
    certificate_pem, _, _ = _send_signed_request(order['certificate'], None, "Certificate download failed")
    log.info("Certificate signed!")
    return certificate_pem

def main(argv=None):
    parser = argparse.ArgumentParser(
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description="Get a signed TLS certificate from Let's Encrypt using ACME protocol. Supports HTTP-01 and DNS-01 challenges."
    )

    parser.add_argument("--account-key", required=True, help="path to your Let's Encrypt account private key")
    parser.add_argument("--csr", required=True, help="path to your certificate signing request")
    parser.add_argument("--acme-dir", help="path to the .well-known/acme-challenge/ directory (required for http-01)")
    parser.add_argument("--challenge-type", default="http-01", choices=["http-01", "dns-01"], help="challenge type to use (dns-01 requires dnsapi/dns_api.sh)")
    parser.add_argument("--quiet", action="store_const", const=logging.ERROR, help="suppress output except for errors")
    parser.add_argument("--disable-check", default=False, action="store_true", help="disable checking if the challenge file is hosted correctly before telling the CA")
    parser.add_argument("--directory-url", default=DEFAULT_DIRECTORY_URL, help="certificate authority directory url, default is Let's Encrypt")
    parser.add_argument("--contact", metavar="CONTACT", default=None, nargs="*", help="Contact details (e.g. mailto:aaa@bbb.com) for your account-key")
    parser.add_argument("--check-port", metavar="PORT", default=None, help="what port to use when self-checking the challenge file, default is port 80")
    parser.add_argument("--timeout", metavar="SECONDS", type=int, default=30, help="timeout in seconds for HTTP requests, default is 30")

    args = parser.parse_args(argv)
    if args.challenge_type == "http-01" and not args.acme_dir:
        parser.error("--acme-dir is required for http-01 challenge")
    LOGGER.setLevel(args.quiet or LOGGER.level)
    try:
        signed_crt = get_crt(args.account_key, args.csr, args.acme_dir, log=LOGGER,
                            disable_check=args.disable_check, directory_url=args.directory_url,
                            contact=args.contact, check_port=args.check_port,
                            challenge_type=args.challenge_type, timeout=args.timeout)
        sys.stdout.write(signed_crt)
    except ValueError as e:
        msg = str(e)
        # Try to extract ACME error detail if present
        detail = None
        # Look for 'Response:' in the error string and try to parse JSON
        import re
        import json
        match = re.search(r'Response: (\{.*\})', msg, re.DOTALL)
        if match:
            try:
                err_json = json.loads(match.group(1))
                if 'detail' in err_json:
                    detail = err_json['detail']
                elif 'error' in err_json:
                    detail = err_json['error']
                elif 'type' in err_json:
                    detail = err_json['type']
                else:
                    detail = str(err_json)
            except Exception:
                pass
        if "HTTP Error 429" in msg or "429" in msg:
            print("Error: Let's Encrypt rate limit reached (HTTP 429: Too Many Requests). Please wait before retrying.", file=sys.stderr)
        elif "Network error" in msg:
            print("Error: Network error communicating with Let's Encrypt or DNS provider. Details: {}".format(msg), file=sys.stderr)
        elif "Challenge did not pass" in msg:
            print("Error: DNS or HTTP challenge failed. Please check your DNS provider/API credentials and domain configuration.", file=sys.stderr)
        elif "Order failed" in msg:
            print("Error: Let's Encrypt order failed. Details: {}".format(msg), file=sys.stderr)
        else:
            print("Error: {}".format(msg), file=sys.stderr)
        if detail:
            print("ACME server response detail: {}".format(detail), file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print("Unexpected error: {}".format(e), file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__": # pragma: no cover
    main(sys.argv[1:])
