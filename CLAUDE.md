# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository contains a shell script for provisioning a production-ready Magento 2 **server** environment on Ubuntu 24.04 LTS. It is a server provisioning project, not a typical code repository.

**Scope note:** This repo provisions server infrastructure only. It does not install or deploy the Magento application itself — that is intentionally out of scope. The web root it creates is meant to be populated by whatever deployment process you use separately.

## Architecture

`setup-ubuntu24.sh` is the single entry point (run as root). It:
1. Parses `--modules=<tokens>` (optional — run a subset of modules by number, filename, or path)
2. Loads `lib/functions.sh` for shared helpers (`print_*`, config loader, validators, `resolve_module`)
3. Validates `server-setup.conf` and the SSH public key
4. Detects system resources (RAM, CPU cores)
5. Sources each numbered module in `server-setup/` in order (or just the selected ones)

Modules are **sourced**, not executed, so they share variables with the main script and with each other.

## Common Commands

```bash
# Full server infrastructure setup (requires root/sudo)
sudo bash setup-ubuntu24.sh

# Run only specific modules (by number, filename, or path)
sudo bash setup-ubuntu24.sh --modules=03,05,09
sudo bash setup-ubuntu24.sh --modules=03-php.sh

# Follow prompts for values normally supplied via server-setup.conf:
# - Domain name, PHP version (8.1–8.4), OpenSearch version
# - MariaDB root password, restricted user credentials, phpMyAdmin credentials
```

### After setup

```bash
# Service management
sudo systemctl restart php8.4-fpm
sudo systemctl restart nginx
sudo systemctl restart valkey-server
sudo systemctl status opensearch
sudo systemctl status varnish
```

## Server Infrastructure (setup-ubuntu24.sh + server-setup/)

**Modules, in run order:**
| Module | Purpose |
|---|---|
| `01-system.sh` | System update, packages, restricted user, web root (`MAGENTO_DIR`) |
| `02-nginx.sh` | Nginx install |
| `03-php.sh` | PHP-FPM install + tuned `php.ini`/pool config |
| `04-mariadb.sh` | MariaDB install, hardening, Magento-optimised `my.cnf` |
| `05-opensearch.sh` | OpenSearch install + JVM heap config |
| `06-valkey.sh` | Valkey (Redis-compatible) install + memory limits |
| `07-varnish.sh` | Varnish Cache install, VCL, systemd unit |
| `08-composer.sh` | Composer install (verified via signature) |
| `09-phpmyadmin.sh` | phpMyAdmin behind HTTP Basic Auth, random port + URL path |
| `10-security.sh` | UFW firewall, SSH hardening, restricted-user Git deploy key |
| `11-ssl-termination.sh` | Nginx TLS termination on :443 → Varnish :80 (optional — gated by `ENABLE_SSL_TERMINATION`; skipped if TLS is terminated upstream, e.g. Cloudflare Flexible mode) |
| `12-vhost.sh` | Placeholder Nginx vhost for the web root (no app-specific rules) |
| `13-finalize.sh` | `nginx -t`/restart, persists generated values to config, writes `server_setup_info.txt` |

**Key Configuration Details:**
- PHP memory limits and FPM process counts are calculated dynamically based on available system resources
- MariaDB `innodb_buffer_pool_size` is 50% of available RAM
- OpenSearch heap defaults to 50% of RAM (max 8GB)
- Valkey `maxmemory` defaults to 10% of RAM (max 2GB)
- phpMyAdmin is secured behind HTTP Basic Auth on a random port with a randomized URL path
- Root SSH login is key-only; password authentication is disabled entirely
- SSL termination (module 11) is optional: `ENABLE_SSL_TERMINATION=yes` (default) generates a self-signed cert unless `SSL_CERT_PATH`/`SSL_KEY_PATH` point to an operator-supplied cert/key; `no` skips the module and leaves Varnish as the sole HTTP-facing service on :80
- Varnish forwards the real client IP via `X-Forwarded-For` (set explicitly in `vcl_recv`, since Varnish's builtin logic is bypassed by the module's explicit `return`s) and module 07 maps `HTTP_X_FORWARDED_FOR` into `/etc/nginx/fastcgi_params` so PHP-FPM/Magento see it regardless of whether SSL termination is enabled

**Security Hardening:**
- Nginx security headers (X-Frame-Options, X-XSS-Protection, etc.)
- UFW firewall with minimal rule set (80, phpMyAdmin port, plus 443 only when `ENABLE_SSL_TERMINATION=yes`)
- All database/search/cache services bound to localhost only
- Restricted user has no sudo access, but has key-based SSH login (via `RESTRICTED_USER_SSH_PUBLIC_KEY`, a full but unprivileged shell) as well as `su -` from root, and gets a generated Git deploy key for pulling a private application repo later

## File Descriptions

- **setup-ubuntu24.sh** (~140 lines) — orchestrator; validates config/resources, dispatches to `server-setup/` modules
- **lib/functions.sh** — shared helpers: `print_*` output functions, `load_config_safely` (allowlist-based config parser that rejects unknown vars and blocks shell injection), `validate_server_config`, `validate_ssh_public_key`, `validate_system_resources`, `validate_resource_allocations`, `resolve_module`
- **server-setup/*.sh** — one file per infrastructure component, numbered for run order (see table above)

## Important Implementation Details

### Configuration Generation
Modules use **heredocs with variable substitution** for generating configuration files (nginx configs, PHP configs, systemd units). When modifying these sections:
- Ensure proper escaping of `$` characters that shouldn't be substituted (use `\$`)
- Be careful with embedded quotes when using single vs double quotes
- Test generated configs thoroughly (modules include tests like `nginx -t`)

### Config file allowlist
`lib/functions.sh::load_config_safely` only accepts a fixed set of variable names from `server-setup.conf` and rejects anything else, plus common shell-injection patterns (`$(...)`, backticks, `&&`, `||`, `;`, `|`, `eval`, `exec`, `source`, `./`). If you add a new config variable, add it to the `allowed_vars` array or config loading will fail with "Unknown config variable."

### Dynamic Sizing
Resource-based calculations drive critical tuning (see `validate_resource_allocations` in `lib/functions.sh` and `03-php.sh`, `04-mariadb.sh`, `05-opensearch.sh`, `06-valkey.sh`):
- **PHP Memory Limit**: 2G minimum, scales to 6G+ for systems with 16GB+ RAM
- **PHP-FPM Processes**: Ranges from 20-150 based on RAM, with server/spare counts based on CPU cores
- **MariaDB Buffer Pool**: 50% of system RAM
- **OpenSearch Heap**: 50% of RAM, capped at 8GB
- **Valkey Memory**: 10% of RAM, capped at 2GB

### Installation Paths
- Web root created at `/var/www/{DOMAIN_NAME}` (`MAGENTO_DIR`) — populated later by whatever deploys the application
- OpenSearch installed to `/opt/opensearch`
- Configuration files follow standard Ubuntu paths (`/etc/nginx`, `/etc/php`, etc.)

## Modification Guidelines

1. **Always validate**: Use dry-run flags where available (`-n` for apt, `-t` for nginx)
2. **Test configuration generation**: Check any heredoc-generated files for proper variable substitution
3. **Update documentation**: Keep README.md and this file in sync with actual module behavior
4. **Security-first**: Any changes to security settings should maintain the principle of least privilege
5. **Resource awareness**: Test on systems with different RAM/CPU profiles, not just typical development machines
6. **Stay in scope**: Do not reintroduce application deployment logic (Magento install, Composer app setup, DB/media import) into this repo — that was deliberately removed to keep this a server-provisioning-only tool.

## Known Constraints

- **Ubuntu 24.04 LTS only**: Version detection for packages like `ondrej/php` PPA
- **Single-node OpenSearch**: Configured as `discovery.type: single-node` (not suitable for clustering)
- **Local services only**: All search/cache/database bound to 127.0.0.1 (modify if distributed setup needed)
- **Interactive setup**: The script requires a filled-in config file; not suitable for fully automated CI/CD without modifications
- **No backup automation**: Operator must implement external backup strategy for production
- **No application deployment**: Out of scope by design — see Overview above
