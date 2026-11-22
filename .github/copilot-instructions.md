# Copilot Instructions for letsencrypt-esxi

## Project Overview
This is a VMware ESXi VIB (vSphere Installation Bundle) that automates Let's Encrypt certificate management on standalone ESXi servers. The solution handles both HTTP-01 and DNS-01 ACME challenges with automatic renewal via cron jobs.

**Critical Compatibility Requirement**: All code must be fully compatible with ESXi 6.5 and above. Scripts and Python code must only use functionality available in the limited ESXi shell environment - no external dependencies or modern shell features that aren't present in the minimal ESXi BusyBox environment.

## Design Philosophy

### Minimal Changes to Upstream
- **acme_tiny.py**: Stay as close as possible to the original diafygi/acme-tiny implementation
- Add only essential DNS-01 support while preserving original HTTP-01 interface and behavior
- Maintain original parameter requirements (e.g., `--acme-dir` always required) for consistency
- Ensure full backward compatibility - enhanced version should be a drop-in replacement for original
- Use environment variables and external scripts for ESXi-specific logic rather than modifying core ACME client

### Clear Separation of Concerns
- **acme_tiny.py**: Generic ACME protocol client with minimal modifications for DNS-01 challenge support
- **renew.sh**: ESXi-specific orchestration, firewall management, and environment setup
- **dns_api.sh**: DNS provider abstraction layer with standardized interface
- **Provider scripts**: Individual DNS provider implementations following common patterns

### Configuration Simplification
- Minimize user-configurable options to essential settings only
- Use sensible hardcoded defaults for technical parameters (timeouts, retries, cache TTL)
- Single essential DNS setting: `DNS_MAX_WAIT` for maximum propagation wait time
- Always use active DNS propagation checking for optimal speed and reliability

### ESXi Environment Optimization
- Automatic detection and adaptation to ESXi memory constraints
- Read-only filesystem compatibility with persistent configuration backup
- BusyBox shell compatibility with POSIX-compliant syntax throughout

## Architecture & Key Components

### Core Scripts
- **`renew.sh`** - Main certificate lifecycle manager with config backup/restore logic, firewall management, and ACME integration
- **`w2c-letsencrypt`** - ESXi service init script that handles VIB installation/removal and calls `renew.sh`
- **`acme_tiny.py`** - Enhanced ACME client with DNS-01 challenge support while maintaining minimal changes from original diafygi/acme-tiny

### Configuration System
- **`renew.cfg.example`** - Simplified template with essential settings and comprehensive provider examples
- **`renew.cfg`** - User config file with backup persistence across ESXi upgrades at `/etc/w2c-letsencrypt/`
- Config backup rotation: `.bak` (latest) → `.bak.old` (previous) with timestamp-based updates
- Single DNS timeout setting: `DNS_MAX_WAIT` (hardcoded defaults for DNS_TIMEOUT, MAX_RETRIES, RETRY_DELAY, DNS_CACHE_TTL)

### DNS Provider Framework
- **`dnsapi/dns_api.sh`** - Universal DNS provider interface with standardized command structure: `<command> <domain> [txt_value]`
- **`dnsapi/dns_*.sh`** - Provider-specific implementations (Cloudflare, manual, etc.)
- TXT value calculation uses same SHA256+base64 encoding as `acme_tiny.py`
- Always uses active DNS propagation checking for optimal speed and reliability

### VIB Packaging
- **`build/`** - Docker-based VIB creation using `lamw/vibauthor` container
- **`build/build.sh`** - Orchestrates Docker build and artifact extraction
- Output: `.vib` file and offline bundle for ESXi installation

## Critical Development Patterns

### ESXi-Specific Integrations
```sh
# HTTP proxy routing for ACME challenges
echo "/.well-known/acme-challenge local 8120 redirect allow" >> /etc/vmware/rhttpproxy/endpoints.conf

# Firewall ruleset management with state restoration
esxcli network firewall ruleset set -e true -r webAccess
trap cleanup_firewall EXIT INT TERM

# Certificate installation and service restart
cp -p "$LOCALDIR/$KEY" "$VMWARE_KEY"
for s in /etc/init.d/*; do
  if [ -x "$s" ] && grep -q "ssl_reset" "$s" 2>/dev/null; then
    "$s" ssl_reset 2>/dev/null || true
  fi
done
```

### Challenge Type Detection & Automation
- **HTTP-01**: Requires inbound firewall access, starts Python HTTP server on port 8120
- **DNS-01**: Requires outbound firewall access for ACME and DNS provider APIs, prevents automated renewal with manual providers in cron context
- Automated run detection: checks TTY, TERM, PPID for cron/background execution
- Both challenge types always pass `--acme-dir` parameter to maintain consistency with original acme-tiny interface
- Both challenge types require `ssl_reset` service restart after certificate installation

### Configuration Persistence Logic
Uses sophisticated backup rotation to survive VIB upgrades:
- Main config: `/opt/w2c-letsencrypt/renew.cfg` (ephemeral)
- Persistent backup: `/etc/w2c-letsencrypt/renew.cfg.bak` (survives upgrades)
- ESXi-compatible timestamp comparison using `ls -l` instead of `-nt` operator (BusyBox limitation)

### Error Handling & Validation
- Certificate domain mismatch detection via SAN comparison
- Let's Encrypt issuer validation before renewal checks
- Fallback to self-signed certificates on ACME failures
- DNS propagation wait with active checking and configurable maximum timeout
- Automatic key generation for fresh installs (account key, domain key, CSR)
- ESXi-compatible SSL service restart using static file analysis instead of service execution
- Simplified configuration reduces user error potential

## Development Workflows

### Local Testing
```sh
# Build VIB locally
./build/build.sh

# Test certificate renewal (dry run with staging)
DIRECTORY_URL="https://acme-staging-v02.api.letsencrypt.org/directory" ./renew.sh

# Force renewal for testing
rm /etc/vmware/ssl/rui.crt && /etc/init.d/w2c-letsencrypt start
```

### DNS Provider Development
1. Implement in `dnsapi/dns_<provider>.sh` following the standardized interface
2. Support commands: `add`, `rm`, `info`, `list`, `test`
3. Use environment variables for credentials (exported from `renew.cfg`)
4. Calculate TXT values via `calculate_txt_value()` in `dns_api.sh`

### Configuration Updates
- Always update `renew.cfg.example` as the canonical reference
- Include validation patterns and comprehensive provider examples
- Test config persistence across VIB upgrade/removal cycles

## Key Files for Common Tasks
- **Certificate logic**: `renew.sh` lines 110-130 (renewal checks), 290-320 (certificate installation and service restart)
- **Firewall management**: `renew.sh` lines 145-180 (challenge-specific rules), cleanup function
- **DNS provider interface**: `dnsapi/dns_api.sh` lines 1-100 (core framework)
- **VIB packaging**: `build/create_vib.sh` and `build/Dockerfile`
- **ESXi service integration**: `w2c-letsencrypt` (init script patterns)
- **Key generation**: `renew.sh` lines 258-275 (automatic key/CSR generation)
- **ACME client enhancements**: `acme_tiny.py` with minimal DNS-01 additions to original HTTP-01 logic

## Testing Considerations
- **ESXi Compatibility**: Must work on ESXi 6.5+ with limited BusyBox shell - avoid bash-specific syntax, modern utilities, or Python features not in ESXi's minimal environment
- ESXi-specific: hostname FQDN requirements, firewall ruleset names, service restart patterns
- ACME staging environment for certificate testing without rate limits
- DNS propagation timing varies by provider (default 30s, configurable)
- VIB acceptance level must be "community" for installation

## ESXi Environment Constraints
- **Shell**: Use POSIX-compliant `/bin/sh` syntax only (no bash arrays, `[[`, process substitution)
- **BusyBox Limitations**: Avoid `-nt`/`-ot` file test operators - use `ls -l` timestamp comparison instead
- **Python**: Limited to Python 2.7/3.x features available in ESXi - no pip packages, minimal standard library
- **Utilities**: BusyBox versions of common tools with reduced feature sets (grep, sed, awk, etc.)
- **Paths**: Use absolute paths and verify tool availability before use (`which`, `command -v`)
- **OpenSSL**: Core ESXi OpenSSL for cryptographic operations (certificate parsing, key generation)
- **Command Availability**: Check for `readlink -f`, `pidof`, `python3` availability and provide fallbacks
- **SSL Reset Syntax**: Use static file analysis for service detection: `grep -q "ssl_reset" "$s"` instead of executing services

## Current Implementation Status

### ACME Client Enhancement
- **Original Fidelity**: `acme_tiny.py` maintains minimal changes from original diafygi/acme-tiny (268 lines vs 198 original)
- **Drop-in Compatibility**: Enhanced version functions as a direct replacement for original acme-tiny in any environment
- **DNS-01 Support**: Added via external DNS API framework rather than modifying core ACME logic
- **Interface Consistency**: Always requires `--acme-dir` parameter for both HTTP-01 and DNS-01 to match original behavior
- **Error Handling**: Preserves original IndexError behavior for missing challenge types
- **Environment Integration**: Uses environment variables for configuration without breaking original usage patterns

### Configuration Architecture
- **Simplified DNS Settings**: Single user-configurable `DNS_MAX_WAIT` option (300s default)
- **Hardcoded Defaults**: DNS_TIMEOUT=30, MAX_RETRIES=3, RETRY_DELAY=5, DNS_CACHE_TTL=120 (auto-adjusted for memory constraints)
- **Active Propagation**: Always uses real-time DNS propagation checking instead of fixed waits
- **Provider Abstraction**: Standardized interface for all DNS providers with consistent command patterns

### Performance Optimizations
- **Memory-Aware**: Automatically detects ESXi memory constraints and adjusts cache settings
- **Efficient Challenge Handling**: Unified challenge selection and variable setup before branching
- **Minimal API Calls**: Reduced redundant DNS API invocations and parameter processing
- **Progress Monitoring**: Multi-layer logging architecture across shell and Python components
