# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository contains a shell script for provisioning a production-ready **PHP application server** environment on Ubuntu 24.04 LTS. It is a server provisioning project, not a typical code repository. It is framework-agnostic — the web root it creates can be populated with Magento, WordPress, Drupal, or any other PHP application afterward.

**Scope note:** This repo provisions server infrastructure only. It does not install or deploy the application itself — that is intentionally out of scope. The web root it creates is meant to be populated by whatever deployment process you use separately.

## Architecture

`setup-ubuntu24.sh` is the single entry point (run as root). It:
1. Parses `--modules=<tokens>` (optional — run a subset of modules by name, position, or path)
2. Loads `lib/functions.sh` for shared helpers (`print_*`, config loader, validators, `resolve_module`)
3. Validates `server-setup.conf` and the SSH public key
4. Detects system resources (RAM, CPU cores)
5. Sources each module in `server-setup/` in the order defined by the `MODULE_ORDER` array (or just the selected ones)

Modules are **sourced**, not executed, so they share variables with the main script and with each other. Module filenames carry no numeric prefix — `MODULE_ORDER` in `setup-ubuntu24.sh` is the single source of truth for run order, and is also what numeric `--modules=` tokens resolve against (1-indexed position).

Most components are individually switchable via `*_ENABLED` config variables (default `yes`); a disabled module's script checks its own toggle at the top and returns early. PHP and Nginx are the only non-toggleable components — they're the irreducible core of "a PHP application server".

## Common Commands

```bash
# Full server infrastructure setup (requires root/sudo)
sudo bash setup-ubuntu24.sh

# Run only specific modules (by name or position)
sudo bash setup-ubuntu24.sh --modules=php,database,phpmyadmin
sudo bash setup-ubuntu24.sh --modules=3,4,9

# Follow prompts for values normally supplied via server-setup.conf:
# - Domain name, PHP version (7.0-7.4 or 8.0-8.5)
# - Database engine (MariaDB or MySQL) and version
# - MariaDB/MySQL root password, restricted user credentials, phpMyAdmin credentials
```

### After setup

```bash
# Service management
sudo systemctl restart php8.4-fpm
sudo systemctl restart nginx
sudo systemctl restart valkey-server      # if VALKEY_ENABLED=yes
sudo systemctl status opensearch          # if OPENSEARCH_ENABLED=yes
sudo systemctl status varnish             # if VARNISH_ENABLED=yes
sudo systemctl status mariadb             # or 'mysql', per DB_ENGINE — if DB_ENABLED=yes
```

## Server Infrastructure (setup-ubuntu24.sh + server-setup/)

**Modules, in run order (position = what numeric `--modules=` tokens refer to):**
| # | Module | Purpose |
|---|---|---|
| 1 | `system.sh` | System update, packages, restricted user, web root (`WEB_ROOT`) |
| 2 | `nginx.sh` | Nginx install; when `VARNISH_ENABLED=yes`, also moves the default site to port 8080 immediately (before anything else can bind :80) |
| 3 | `php.sh` | PHP-FPM install + tuned `php.ini`/pool config |
| 4 | `database.sh` | MariaDB or MySQL install (per `DB_ENGINE`), hardening, tuned `my.cnf` — skipped when `DB_ENABLED=no` |
| 5 | `opensearch.sh` | OpenSearch install + JVM heap config — skipped when `OPENSEARCH_ENABLED=no` |
| 6 | `valkey.sh` | Valkey (Redis-compatible) install + memory limits — skipped when `VALKEY_ENABLED=no` |
| 7 | `varnish.sh` | Varnish Cache install (version-pinned via the official packagecloud.io repo) + systemd drop-in (listen address, cache size); no VCL is written — skipped when `VARNISH_ENABLED=no` |
| 8 | `composer.sh` | Composer install (version 1 or 2, verified via signature) — skipped when `COMPOSER_ENABLED=no` |
| 9 | `phpmyadmin.sh` | phpMyAdmin behind HTTP Basic Auth, random port + URL path — skipped when `PHPMYADMIN_ENABLED=no` |
| 10 | `security.sh` | UFW firewall (allow rules queued before `ufw enable`), SSH hardening via an authoritative drop-in (key-only by default for both accounts; `SSH_PASSWORD_AUTH_ENABLED`/`ROOT_PASSWORD_AUTH_ENABLED` independently switch the restricted user/root to password auth — verified with `sshd -T` before restart), restricted-user Git deploy key |
| 11 | `ssl-termination.sh` | Nginx TLS termination on :443 → port 80 (optional — gated by `ENABLE_SSL_TERMINATION`; skipped if TLS is terminated upstream, e.g. Cloudflare Flexible mode) |
| 12 | `vhost.sh` | Placeholder Nginx vhost for the web root (no app-specific rules); binds port 80 directly when Varnish is disabled, otherwise 8080 |
| 13 | `finalize.sh` | `nginx -t`/restart, persists generated values to config, writes `server_setup_info.txt` |

**Key Configuration Details:**
- All RAM-based sizing (PHP memory/FPM process counts, database buffer pool, OpenSearch heap, Valkey memory, Varnish cache) is computed up front by `calculate_resource_allocations` in `lib/functions.sh`, then checked by `validate_resource_allocations` — both run in `setup-ubuntu24.sh` right after resource detection, before any module installs anything. See [Dynamic Sizing](#dynamic-sizing).
- Database `innodb_buffer_pool_size` is 25% of available RAM (systems ≤8GB) or 30% (>8GB) — not the dedicated-DB-server rule of 50%, since this is a shared single-box stack (applies to both MariaDB and MySQL)
- OpenSearch heap defaults to 25% of RAM (max 8GB), when enabled
- Valkey `maxmemory` defaults to 10% of RAM (max 2GB), when enabled
- phpMyAdmin is secured behind HTTP Basic Auth on a random port with a randomized URL path, when enabled
- SSH auth mode is two independent switches, both default `no` (key-only): `SSH_PASSWORD_AUTH_ENABLED` governs the restricted (application) user and sshd's `PasswordAuthentication` server-wide; `ROOT_PASSWORD_AUTH_ENABLED` governs `PermitRootLogin` for root specifically and requires `SSH_PASSWORD_AUTH_ENABLED=yes` (validated in `lib/functions.sh::validate_server_config`) since `PasswordAuthentication` can't be scoped per-account. Root's credential isn't reset just because the restricted user's is — each account is strictly key-only or password-only (`ROOT_USER_PASSWORD`/`RESTRICTED_USER_PASSWORD`, min 12 chars, set via `chpasswd` in `security.sh`/`system.sh` respectively), never both. Default state writes `PasswordAuthentication no` + `PermitRootLogin prohibit-password` to an authoritative drop-in (`/etc/ssh/sshd_config.d/40-hardening.conf`, sorted to win over any distro/cloud-init drop-in); the effective config is verified with `sshd -T` before sshd is restarted — module `security` hard-fails rather than proceeding on an unverified claim
- `authorized_keys` writes (root in `security.sh`, restricted user in `system.sh`) go through `write_authorized_key_safely` in `lib/functions.sh`, which refuses to overwrite a pre-existing key (e.g. from cloud-init) that doesn't match what's configured, rather than silently clobbering it
- SSL termination (module `ssl-termination`) is optional: `ENABLE_SSL_TERMINATION=yes` (default) generates a self-signed cert unless `SSL_CERT_PATH`/`SSL_KEY_PATH` point to an operator-supplied cert/key; `no` skips the module and leaves port 80 as the sole HTTP-facing port
- Varnish ships no VCL from this repo — Ubuntu's package default (`/etc/varnish/default.vcl`, pointed at `127.0.0.1:8080`) is left in place and applies until the application's own VCL is installed post-deploy; it already forwards `X-Forwarded-For` via its builtin `vcl_recv`. Module `varnish` still maps `HTTP_X_FORWARDED_FOR` into `/etc/nginx/fastcgi_params` so PHP-FPM/the application see it regardless of whether SSL termination is enabled
- Port 80 is always the sole public HTTP entry point: Varnish owns it when `VARNISH_ENABLED=yes`; otherwise the `vhost` module's Nginx vhost binds it directly. SSL termination, when enabled, always proxies :443 to `127.0.0.1:80` regardless of which of the two is behind it.
- Varnish installs from its own official packagecloud.io repo (one per major/minor series, e.g. `varnish75` for `VARNISH_VERSION=7.5`), added via the same "curl the vendor's setup script" pattern as MariaDB. Since Ubuntu's own default repo also ships an unversioned `varnish` package, an `/etc/apt/preferences.d/` pin forces the packagecloud-sourced package to win regardless of raw version-number comparison. Valkey has no equivalent official repo (verified directly, not assumed) — `VALKEY_ENABLED` exists but there's no `VALKEY_VERSION`.
- MySQL `8.0`/`8.4` install via Oracle's official apt repository (`mysql-8.0` / `mysql-8.4-lts` components for noble). MySQL `5.6`/`5.7` are EOL and no longer in that repo for Ubuntu 24.04, so the `database` module installs them differently: it runs the official `mysql:5.6`/`mysql:5.7` Docker image instead (installing Docker itself first if needed), bound to `127.0.0.1:3306` with a persistent volume. A `/usr/local/bin/db-cli` wrapper is generated so downstream modules (`phpmyadmin`, `finalize`) can call `$DB_CLI` the same way regardless of backend.

**Security Hardening:**
- Nginx security headers (X-Frame-Options, X-XSS-Protection, etc.)
- UFW firewall with minimal rule set (80, phpMyAdmin port when enabled, plus 443 only when `ENABLE_SSL_TERMINATION=yes`)
- All database/search/cache services bound to localhost only, when enabled
- Restricted user has no sudo access, but has direct SSH login (key via `RESTRICTED_USER_SSH_PUBLIC_KEY`, or password via `RESTRICTED_USER_PASSWORD` when `SSH_PASSWORD_AUTH_ENABLED=yes` — a full but unprivileged shell either way) as well as `su -` from root, and gets a generated Git deploy key for pulling a private application repo later

## File Descriptions

- **setup-ubuntu24.sh** (~170 lines) — orchestrator; defines `MODULE_ORDER`, validates config/resources, dispatches to `server-setup/` modules
- **lib/functions.sh** — shared helpers: `print_*` output functions, `load_config_safely` (allowlist-based config parser that rejects unknown vars and blocks shell injection), `validate_server_config`, `validate_ssh_public_key`, `validate_system_resources`, `calculate_resource_allocations`, `validate_resource_allocations`, `write_authorized_key_safely`, `resolve_module`
- **server-setup/*.sh** — one file per infrastructure component, sourced in the order defined by `MODULE_ORDER` (see table above)
- **tools/config-generator.html** — standalone, browser-only interactive form that produces a `server-setup.conf`; every version/toggle is a dropdown, mirroring the validation rules below

## Important Implementation Details

### Configuration Generation
Modules use **heredocs with variable substitution** for generating configuration files (nginx configs, PHP configs, systemd units). When modifying these sections:
- Ensure proper escaping of `$` characters that shouldn't be substituted (use `\$`)
- Be careful with embedded quotes when using single vs double quotes
- Test generated configs thoroughly (modules include tests like `nginx -t`)

### Config file allowlist
`lib/functions.sh::load_config_safely` only accepts a fixed set of variable names from `server-setup.conf` and rejects anything else, plus common shell-injection patterns (`$(...)`, backticks, `&&`, `||`, `;`, `|`, `eval`, `exec`, `source`, `./`). If you add a new config variable, add it to the `allowed_vars` array or config loading will fail with "Unknown config variable."

### Dynamic Sizing
`calculate_resource_allocations` in `lib/functions.sh` is the single source of truth for every RAM-based sizing decision — it runs once in `setup-ubuntu24.sh`, right after resource detection and before any module runs, and sets the variables that `php.sh`, `database.sh`, `opensearch.sh`, `valkey.sh`, and `varnish.sh` merely consume. Immediately after, `validate_resource_allocations` checks the total against available RAM and hard-aborts *before installation starts* if it doesn't fit — checking after modules had already installed (the previous behavior) made aborting pointless.

Fixed-size services are allocated first (each is fully resident once running); PHP-FPM gets whatever's left:
- **MariaDB/MySQL buffer pool**: 25% of RAM (≤8GB systems) or 30% (>8GB) — not the 50% dedicated-DB-server rule, since this is a shared single-box stack
- **OpenSearch Heap**: 25% of RAM, capped at 8GB, capped at 1GB on ≤6GB systems (when enabled)
- **Valkey Memory**: 10% of RAM, capped at 2GB, minimum 256MB (when enabled)
- **Varnish Cache**: 5% of RAM, capped at 2GB, minimum 256MB (when enabled)
- **OS/overhead reserve**: 5% of RAM, floor 512MB
- **PHP Memory Limit**: 2G (≤6GB RAM), 4G (≤16GB), 6G (>16GB)
- **PHP-FPM `max_children`**: derived from whatever RAM remains after the above, divided by 15% of the PHP memory limit (the average-RSS-per-child heuristic), floored at 5 — not a hardcoded 20/100/150 per RAM bracket, so it adapts to whichever other services are actually enabled

### Installation Paths
- Web root created at `/var/www/{DOMAIN_NAME}` (`WEB_ROOT`) — populated later by whatever deploys the application
- OpenSearch installed to `/opt/opensearch`, when enabled
- Configuration files follow standard Ubuntu paths (`/etc/nginx`, `/etc/php`, etc.); database config lives under `/etc/mysql/mariadb.conf.d/` or `/etc/mysql/mysql.conf.d/` depending on `DB_ENGINE`

## Modification Guidelines

1. **Always validate**: Use dry-run flags where available (`-n` for apt, `-t` for nginx)
2. **Test configuration generation**: Check any heredoc-generated files for proper variable substitution
3. **Update documentation**: Keep README.md and this file in sync with actual module behavior
4. **Security-first**: Any changes to security settings should maintain the principle of least privilege
5. **Resource awareness**: Test on systems with different RAM/CPU profiles, not just typical development machines
6. **Stay in scope**: Do not reintroduce application deployment logic (framework install, Composer app setup, DB/media import) into this repo — that was deliberately removed to keep this a server-provisioning-only tool. The repo is intentionally framework-agnostic (not Magento-specific); avoid re-coupling modules to any one application's assumptions. Do not reintroduce a hand-rolled application-specific VCL into module `varnish` — a custom VCL was previously shipped there with Magento-flavored cache-bypass rules and caused two critical bugs (caching `Set-Cookie` responses, no scheme-aware cache hashing); the module now ships no VCL at all and relies on the package default until the application installs its own post-deploy.

## Known Constraints

- **Ubuntu 24.04 LTS only**: Version detection for packages like `ondrej/php` PPA, and the specific apt repo components used for MariaDB/MySQL
- **MySQL 5.6/5.7 run via Docker, not apt**: Oracle's apt repo no longer carries them for Ubuntu 24.04, so the `database` module installs the official `mysql:5.6`/`mysql:5.7` Docker image instead (installing Docker itself on demand). This is the one place the toolchain depends on Docker — it's otherwise unused
- **Single-node OpenSearch**: Configured as `discovery.type: single-node` (not suitable for clustering), when enabled
- **Local services only**: All search/cache/database bound to 127.0.0.1 (modify if distributed setup needed)
- **Interactive setup**: The script requires a filled-in config file; not suitable for fully automated CI/CD without modifications
- **No backup automation**: Operator must implement external backup strategy for production
- **No application deployment**: Out of scope by design — see Overview above
- **Varnish runs with no Full Page Cache until the app is deployed**: this repo installs Varnish but writes no VCL, so the package default (conservative — passes anything with cookies) is what's active. The operator must export/install the application's own VCL after deployment to get real FPC behavior; see `server_setup_info.txt`'s "Next Steps".
