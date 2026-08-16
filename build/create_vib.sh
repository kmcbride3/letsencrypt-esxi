#!/bin/sh
#
# Copyright (c) Johannes Feichtner <johannes@web-wack.at>
#
# Script to build VIB using VIB Author

LOCALDIR=$(dirname "$(readlink -f "$0")")
STAGING_DIR=/tmp/${GH_REPO_NAME:-letsencrypt-esxi}-$$

# Remove staging directory on exit, interrupt or termination
cleanup() {
  rm -rf "${STAGING_DIR}"
}
trap cleanup EXIT INT TERM

# Ensure prerequisites are installed
git version > /dev/null 2>&1
if [ $? -eq 1 ]; then
  echo "git not installed, exiting..."
  exit 1
fi

vibauthor --version > /dev/null 2>&1
if [ $? -eq 1 ]; then
  echo "vibauthor not installed, exiting .."
  exit 1
fi

# Define VIB metadata
cd "${LOCALDIR}" || exit

VIB_DATE=${COMMIT_DATE:-"$(git log -n1 --format="%cd" --date="format:%Y-%m-%dT%H:%M:%S")"}
VIB_TAG=${VIB_TAG:-"$(git describe --tags --abbrev=0 --match '[0-9]*.[0-9]*.[0-9]*' 2> /dev/null || echo 0.0.1)"}
VIB_BUILD=$(date +%s | cut -c5-) # VIB_BUILD: 6-digit truncated Unix timestamp

# Setting up VIB spec confs
VIB_NAME=${GH_REPO_OWNER:-w2c}-${GH_REPO_NAME:-letsencrypt-esxi}
PACKAGE_NAME=${VIB_NAME%-esxi}
VIB_DESC="Let's Encrypt for ESXi"
VENDOR="web-wack-creations"
VIB_DESC_FILE=${STAGING_DIR}/descriptor.xml
VIB_VERSION=${VIB_TAG}-${VIB_BUILD}
VIB_OUTPUT=${VIB_NAME}-${VIB_VERSION}.vib
OFFLINE_BUNDLE_NAME=${VIB_NAME}-${VIB_VERSION}-offline-bundle.zip
PAYLOAD_ARCHIVE=${STAGING_DIR}/payload1
VIB_PAYLOAD_DIR=${STAGING_DIR}/payloads/payload1

# Set GitHub Actions environment variables for build metadata
if [ -n "$GITHUB_OUTPUT" ]; then
  echo "vib_date=${VIB_DATE}" >> "$GITHUB_OUTPUT"
  echo "vib_tag=${VIB_TAG}" >> "$GITHUB_OUTPUT"
  echo "vib_build=${VIB_BUILD}" >> "$GITHUB_OUTPUT"
  echo "vib_name=${VIB_NAME}" >> "$GITHUB_OUTPUT"
  echo "vib_version=${VIB_VERSION}" >> "$GITHUB_OUTPUT"
  echo "vib_output=${VIB_OUTPUT}" >> "$GITHUB_OUTPUT"
  echo "offline_bundle_name=${OFFLINE_BUNDLE_NAME}" >> "$GITHUB_OUTPUT"
fi

# Create VIB spec payload directory (and all parent directories)
mkdir -p "${VIB_PAYLOAD_DIR}"

# Create target directory
BIN_DIR=${VIB_PAYLOAD_DIR}/opt/${PACKAGE_NAME}
INIT_DIR= ${VIB_PAYLOAD_DIR}/etc/init.d
mkdir -p "${BIN_DIR}" "${INIT_DIR}" || {
  echo "Error: failed to create payload directories"
  exit 1
}

# Copy only runtime files into payload
for f in acme_tiny.py renew.sh openssl.cnf ca-certificates.crt renew.cfg.example; do
  if [ ! -e "../${f}" ]; then
    echo "Error: required runtime file not found: ../${f}"
    exit 1
  fi
  cp "../${f}" "${BIN_DIR}/"
done

if [ ! -d "../dnsapi" ]; then
  echo "Error: required runtime directory not found: ../dnsapi"
  exit 1
fi
cp -r "../dnsapi" "${BIN_DIR}/"

if [ ! -f "../${PACKAGE_NAME}" ]; then
  echo "Error: init script not found: ../${PACKAGE_NAME}"
  exit 1
fi
cp "../${PACKAGE_NAME}" "${INIT_DIR}/"

# Ensure that config example is readable but not world-writable
chmod 0644 "${BIN_DIR}/renew.cfg.example"

# Only copy renew.cfg.example, do NOT create renew.cfg in the payload
rm -f ${BIN_DIR}/renew.cfg 2>/dev/null

# Copy DNS API framework and providers
if [ -d "../dnsapi" ]; then
    mkdir -p ${BIN_DIR}/dnsapi
    cp ../dnsapi/* ${BIN_DIR}/dnsapi/
fi

# Fix line endings for shell scripts (convert Windows CRLF to Unix LF)
for script in renew.sh; do
    if [ -f "${BIN_DIR}/${script}" ]; then
        sed -i 's/\r$//' "${BIN_DIR}/${script}" 2>/dev/null || true
    fi
done

# Fix line endings for DNS API framework and providers
if [ -f "${BIN_DIR}/dnsapi/dns_api.sh" ]; then
    sed -i 's/\r$//' "${BIN_DIR}/dnsapi/dns_api.sh" 2>/dev/null || true
fi
for dns_script in ${BIN_DIR}/dnsapi/dns_*.sh; do
    if [ -f "${dns_script}" ]; then
        sed -i 's/\r$//' "${dns_script}" 2>/dev/null || true
    fi
done

if [ -f "${INIT_DIR}/${PACKAGE_NAME}" ]; then
    sed -i 's/\r$//' "${INIT_DIR}/${PACKAGE_NAME}" 2>/dev/null || true
fi

# Ensure that shell scripts are executable
chmod +x "${INIT_DIR}/${PACKAGE_NAME}" "${BIN_DIR}/renew.sh" "${BIN_DIR}/dnsapi/dns_api.sh"

# Create tgz with payload
tar czf "${PAYLOAD_ARCHIVE}" -C "${VIB_PAYLOAD_DIR}" etc opt

# Create letsencrypt-esxi VIB descriptor.xml
PAYLOAD_FILES=$(tar tf "${PAYLOAD_ARCHIVE}" | grep -v -E '/$' | sed -e 's/^/    <file>/' -e 's/$/<\/file>/')
PAYLOAD_SIZE=$(stat -c %s "${PAYLOAD_ARCHIVE}")
PAYLOAD_SHA256=$(sha256sum "${PAYLOAD_ARCHIVE}" | awk '{print $1}')
PAYLOAD_SHA256_ZCAT=$(zcat "${PAYLOAD_ARCHIVE}" | sha256sum | awk '{print $1}')
PAYLOAD_SHA1_ZCAT=$(zcat "${PAYLOAD_ARCHIVE}" | sha1sum | awk '{print $1}')

cat > "${VIB_DESC_FILE}" << __${GH_REPO_OWNER:-W2C}__
<vib version="5.0">
  <type>bootbank</type>
  <name>${VIB_NAME}</name>
  <version>${VIB_VERSION}</version>
  <vendor>${VENDOR}</vendor>
  <summary>${VIB_DESC}</summary>
  <description>${VIB_DESC}</description>
  <release-date>${VIB_DATE}</release-date>
  <urls>
    <url key="${GH_REPO_NAME:-letsencrypt-esxi}">https://github.com/${GH_REPOSITORY:-w2c/letsencrypt-esxi}</url>
  </urls>
  <relationships>
    <depends/>
    <conflicts/>
    <replaces/>
    <provides/>
    <compatibleWith/>
  </relationships>
  <software-tags/>
  <system-requires>
    <maintenance-mode>false</maintenance-mode>
  </system-requires>
  <file-list>
${PAYLOAD_FILES}
  </file-list>
  <acceptance-level>community</acceptance-level>
  <live-install-allowed>true</live-install-allowed>
  <live-remove-allowed>true</live-remove-allowed>
  <cimom-restart>false</cimom-restart>
  <stateless-ready>true</stateless-ready>
  <overlay>false</overlay>
  <payloads>
    <payload name="payload1" type="tgz" size="${PAYLOAD_SIZE}">
        <checksum checksum-type="sha-256">${PAYLOAD_SHA256}</checksum>
        <checksum checksum-type="sha-256" verify-process="gunzip">${PAYLOAD_SHA256_ZCAT}</checksum>
        <checksum checksum-type="sha-1" verify-process="gunzip">${PAYLOAD_SHA1_ZCAT}</checksum>
    </payload>
  </payloads>
</vib>
__${GH_REPO_OWNER:-W2C}__

# Create VIB
touch "${STAGING_DIR}/sig.pkcs7"
ar r "${VIB_OUTPUT}" "${VIB_DESC_FILE}" "${STAGING_DIR}/sig.pkcs7" "${PAYLOAD_ARCHIVE}"

# Create the offline bundle
PYTHONPATH=/opt/vmware/vibtools-6.0.0-847598/bin python -c "import vibauthorImpl; vibauthorImpl.CreateOfflineBundle('${VIB_OUTPUT}', '${OFFLINE_BUNDLE_NAME}', True)"

# Show some details about what we have just created
vibauthor -i -v "${VIB_OUTPUT}"

# Staging cleanup handled by trap
