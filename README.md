# PHP Application Server Setup — Ubuntu 24.04 LTS

![Platform](https://img.shields.io/badge/platform-Ubuntu%2024.04%20LTS-E95420?logo=ubuntu&logoColor=white)
![Shell](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white)
![PHP](https://img.shields.io/badge/PHP-7.0%E2%80%937.4%20%7C%208.0%E2%80%938.5-777BB4?logo=php&logoColor=white)
![License](https://img.shields.io/badge/license-GPL--3.0-blue)

An automated shell script to provision a production-ready PHP application **server** from scratch on Ubuntu 24.04 LTS — Nginx, PHP-FPM, a database (MariaDB or MySQL), and a set of optional services (OpenSearch, Valkey, Varnish, Composer, phpMyAdmin), each individually switchable, plus security hardening. It's framework-agnostic: the web root it creates can be populated with Magento, WordPress, Drupal, or any other PHP application.

> [!NOTE]
> This repo provisions the **server infrastructure only**. Deploying the application itself (Composer install, framework setup command, database import, admin account) is out of scope — bring your own deployment process and point it at the web root this script creates.

> [!WARNING]
> **Do not use this script for production deployments without thorough review and validation.**
> The script is provided as a starting point and has not been independently audited for security or reliability. Before running on any production system you must review every module, verify all generated configurations against your organisation's standards, test on a staging environment, and confirm that security hardening meets your requirements. You assume full responsibility for any production use.

---

## Table of Contents

- [Overview](#overview)
- [Stack](#stack)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Configuration Reference](#configuration-reference)
- [What the Script Does](#what-the-script-does)
- [Resource Sizing](#resource-sizing)
- [Security Model](#security-model)
- [Production Checklist](#production-checklist)
- [Deploying Your Application](#deploying-your-application)
- [Logs](#logs)
- [File Structure](#file-structure)
- [Known Constraints](#known-constraints)
- [Contributing](#contributing)
- [License](#license)

---

## Overview

`setup-ubuntu24.sh` is the single entry point. It validates a config file, detects hardware, then sources each module in `server-setup/` in order.

| Script | Run as | Purpose |
|---|---|---|
| `setup-ubuntu24.sh` | `root` | Provisions the full server stack |

It reads from `server-setup.conf`, which you create once before running it.

> [!IMPORTANT]
> `server-setup.conf` contains credentials and must **never** be committed to version control. It's already listed in `.gitignore`.

---

## Stack

| Component | Role | Switch |
|---|---|---|
| **Nginx** | Web server / reverse proxy (port 8080 behind Varnish, or port 80 directly if Varnish is disabled) | always on |
| **PHP-FPM** | Application runtime (7.0–7.4 or 8.0–8.5, configurable) | always on |
| **Database — MariaDB or MySQL** | Relational database. MariaDB: 10.6+ or 11.x. MySQL: 8.0/8.4 via apt, or 5.6/5.7 via an auto-installed Docker container (Oracle no longer ships those for Ubuntu 24.04 — see [Configuration Reference](#configuration-reference)) | `DB_ENABLED` |
| **OpenSearch** | Search engine (used by Magento 2.4+ in place of Elasticsearch; skip it for apps that don't need one) | `OPENSEARCH_ENABLED` |
| **Valkey (Redis-compatible)** | Sessions, application cache, full-page cache (separate DBs) | `VALKEY_ENABLED` |
| **Varnish Cache** | Full-page HTTP cache (port 80), version selectable via Varnish's official apt repo | `VARNISH_ENABLED` |
| **Composer** | PHP dependency manager (installs version 1 or 2) | `COMPOSER_ENABLED` |
| **phpMyAdmin** | Database GUI (secured on a non-standard port with random URL path; requires the database to be enabled) | `PHPMYADMIN_ENABLED` |
| **UFW** | Host firewall | always on |
| **Nginx SSL termination** | TLS on :443 → port 80 (self-signed origin cert by default; optional — skip if TLS is already terminated upstream) | `ENABLE_SSL_TERMINATION` |

---

## Prerequisites

- Ubuntu 24.04 LTS (fresh install recommended)
- Root SSH access with a public/private key pair
- A public/private key pair for the restricted (application) user's SSH login
- Domain name with DNS pointing to the server (required if using Nginx SSL termination — see below)

**Recommended minimum hardware:** 4 GB RAM, 2 CPU cores. 8 GB+ RAM is recommended for production.

---

## Quick Start

### 1. Clone the repository

```bash
git clone <repo-url> magento-server-setup
cd magento-server-setup
```

### 2. Create your configuration file

```bash
cp server-setup.conf.example server-setup.conf
nano server-setup.conf
```

Fill in **all** values — see the [Configuration Reference](#configuration-reference) below. Alternatively, open
[`tools/config-generator.html`](tools/config-generator.html) in a browser for an interactive form that validates
each value as you type and produces a ready-to-download `server-setup.conf`. It's a static page — nothing you
type leaves your browser.

### 3. Run the server setup (as root)

```bash
sudo bash setup-ubuntu24.sh
```

This provisions the entire server stack. A timestamped log file is saved in the current directory, and a summary is written to `server_setup_info.txt`.

### Running individual modules

Use `--modules` to (re)run specific modules instead of the full sequence — useful when iterating on one piece of the stack. Modules can be selected by name or by their position in the run order (see [What the Script Does](#what-the-script-does)):

```bash
sudo bash setup-ubuntu24.sh --modules=php,database,phpmyadmin
sudo bash setup-ubuntu24.sh --modules=3,4,9
```

---

## Configuration Reference

Copy `server-setup.conf.example` to `server-setup.conf` and fill in all values.

| Variable | Example | Description |
|---|---|---|
| `DOMAIN_NAME` | `example.com` | Domain name the server will host |
| `PHP_VERSION` | `8.4` | PHP version: `7.0`–`7.4` or `8.0`–`8.5` |
| `DB_ENABLED` | `yes` | `yes`/`no` — set `no` to skip installing a database entirely |
| `DB_ENGINE` | `mariadb` | Required if `DB_ENABLED=yes`: `mariadb` or `mysql` |
| `DB_VERSION` | `11.4` | MariaDB: `10.6`+ or `11.x` (e.g. `10.11`, `11.4`, `11.8`). MySQL: `5.6`, `5.7`, `8.0`, or `8.4` — `8.0`/`8.4` install via apt; `5.6`/`5.7` are EOL and no longer in Oracle's apt repo for Ubuntu 24.04, so those two install via an auto-provisioned Docker container running the official image instead |
| `DB_ROOT_PASSWORD` | — | Strong password for the database root user (required if `DB_ENABLED=yes`) |
| `OPENSEARCH_ENABLED` | `yes` | `yes`/`no` |
| `OPENSEARCH_VERSION` | `3.5.0` | OpenSearch version, e.g. `2.15`, `3.5.0` (required if `OPENSEARCH_ENABLED=yes`) |
| `VALKEY_ENABLED` | `yes` | `yes`/`no` |
| `VARNISH_ENABLED` | `yes` | `yes`/`no` — when `no`, Nginx becomes the sole HTTP-facing service on port 80 instead of sitting behind Varnish on 8080 |
| `VARNISH_VERSION` | `7.5` | Required if `VARNISH_ENABLED=yes`: `6.0`, `7.0`, `7.4`, or `7.5` — installed from Varnish's own official packagecloud.io repo, pinned so it wins over Ubuntu's own default `varnish` package. Not every series is guaranteed to have Ubuntu 24.04 packages published at all times; `apt` errors clearly if one doesn't. `7.5` is the current series, `6.0` is the LTS branch |
| `COMPOSER_ENABLED` | `yes` | `yes`/`no` |
| `COMPOSER_VERSION` | `2` | Composer major version: `1` or `2` (required if `COMPOSER_ENABLED=yes`) |
| `PHPMYADMIN_ENABLED` | `yes` | `yes`/`no` — requires `DB_ENABLED=yes` |
| `RESTRICTED_USERNAME` | `webuser` | Linux username for the application user |
| `SSH_PASSWORD_AUTH_ENABLED` | `no` | `yes`/`no` — the restricted (application) user's auth method, and whether sshd password authentication is on server-wide (required for either account to use a password). `no` (default): the restricted user is key-only, `RESTRICTED_USER_SSH_PUBLIC_KEY` required. `yes`: the restricted user logs in with a password instead, `RESTRICTED_USER_PASSWORD` required |
| `ROOT_PASSWORD_AUTH_ENABLED` | `no` | `yes`/`no` — root specifically, independent of the restricted user's setting above. Requires `SSH_PASSWORD_AUTH_ENABLED=yes`. `no` (default): root stays key-only, `ROOT_USER_SSH_PUBLIC_KEY` required — this script never resets root's password unless you opt in here. `yes`: `ROOT_USER_PASSWORD` required |
| `ROOT_USER_SSH_PUBLIC_KEY` | `ssh-ed25519 AAAA…` | Your full SSH public key for root login (required unless `ROOT_PASSWORD_AUTH_ENABLED=yes`) |
| `RESTRICTED_USER_SSH_PUBLIC_KEY` | `ssh-ed25519 AAAA…` | SSH public key for the restricted user's login (required unless `SSH_PASSWORD_AUTH_ENABLED=yes`) |
| `ROOT_USER_PASSWORD` | *(optional)* | Root account password, min 12 characters (required if `ROOT_PASSWORD_AUTH_ENABLED=yes`) |
| `RESTRICTED_USER_PASSWORD` | *(optional)* | Restricted user account password, min 12 characters (required if `SSH_PASSWORD_AUTH_ENABLED=yes`) |
| `PMA_PORT` | `61098` | Non-standard port for phpMyAdmin (1–65535, required if `PHPMYADMIN_ENABLED=yes`) |
| `PMA_USERNAME` | `pma_admin` | phpMyAdmin login username (required if `PHPMYADMIN_ENABLED=yes`) |
| `PMA_PASSWORD` | — | Strong password for phpMyAdmin (required if `PHPMYADMIN_ENABLED=yes`) |
| `ENABLE_SSL_TERMINATION` | `yes` | `yes`/`no` — whether the ssl-termination module sets up Nginx TLS termination on :443. Set `no` if TLS is already terminated upstream (Cloudflare Flexible mode, an external load balancer, another CDN) |
| `SSL_CERT_PATH` | *(optional)* | Absolute path to a certificate to use instead of the auto-generated self-signed one. Must be set together with `SSL_KEY_PATH`, or left blank |
| `SSL_KEY_PATH` | *(optional)* | Absolute path to the matching private key. Must be set together with `SSL_CERT_PATH`, or left blank |

Prefer a form over hand-editing the file? [`tools/config-generator.html`](tools/config-generator.html) has a dropdown for every version/toggle above and validates as you type.

<details>
<summary><strong>Generated values (auto-populated — do not edit)</strong></summary>

The script appends these to `server-setup.conf` automatically after running:

| Variable | Description |
|---|---|
| `PMA_PATH` | Randomly generated phpMyAdmin URL path |
| `WEB_ROOT` | Web root path (`/var/www/<DOMAIN_NAME>`) |

</details>

---

## What the Script Does

`setup-ubuntu24.sh` validates the configuration and detected hardware, then sources each module in `server-setup/` in this order (module filenames carry no numeric prefix — this table's position column is what `--modules=<position>` refers to):

| # | Module | What it does |
|---|---|---|
| 1 | `system.sh` | System update, essential packages, restricted user, web root |
| 2 | `nginx.sh` | Nginx installation; when `VARNISH_ENABLED=yes`, also moves the default site to port 8080 immediately after install (before anything else can bind :80) |
| 3 | `php.sh` | PHP-FPM installation, `php.ini`, and pool configuration |
| 4 | `database.sh` | Database installation (MariaDB or MySQL, per `DB_ENGINE`), hardening, and tuned `my.cnf` — skipped when `DB_ENABLED=no` |
| 5 | `opensearch.sh` | OpenSearch installation and JVM heap configuration — skipped when `OPENSEARCH_ENABLED=no` |
| 6 | `valkey.sh` | Valkey (Redis-compatible) installation and memory limits — skipped when `VALKEY_ENABLED=no` |
| 7 | `varnish.sh` | Varnish Cache installation (version-pinned via the official packagecloud repo) and a systemd drop-in (listen address, cache size); no VCL is written — skipped when `VARNISH_ENABLED=no` |
| 8 | `composer.sh` | Composer installation (version 1 or 2) — skipped when `COMPOSER_ENABLED=no` |
| 9 | `phpmyadmin.sh` | phpMyAdmin secured with HTTP Basic Auth, random port, and random URL path — skipped when `PHPMYADMIN_ENABLED=no` |
| 10 | `security.sh` | UFW firewall rules (allow rules queued before `ufw enable`), SSH hardening via an authoritative drop-in verified with `sshd -T` before restart, Git deploy key for the restricted user |
| 11 | `ssl-termination.sh` | Nginx SSL termination on :443 (self-signed or operator-supplied cert, proxies to port 80) — optional, skipped when `ENABLE_SSL_TERMINATION=no` |
| 12 | `vhost.sh` | Placeholder Nginx virtual host for the web root — binds port 80 directly when Varnish is disabled, otherwise 8080 |
| 13 | `finalize.sh` | Nginx test/restart, config persistence, `server_setup_info.txt` summary |

---

## Resource Sizing

Service allocations are calculated dynamically from detected hardware at runtime.

| Service | Sizing rule |
|---|---|
| PHP memory limit | 2 GB minimum, scales to 6 GB+ on systems with 16 GB+ RAM |
| PHP-FPM workers | `max_children` derived from whatever RAM remains after the fixed-size services above, floored at 5; start/spare counts based on CPU cores |
| Database `innodb_buffer_pool_size` (MariaDB or MySQL) | 25% of RAM (≤8 GB systems) or 30% (>8 GB) — not the 50% dedicated-DB-server rule, since this is a shared single-box stack |
| OpenSearch heap (`-Xms` / `-Xmx`), if enabled | 25% of RAM, capped at 8 GB (1 GB cap on ≤6 GB systems) |
| Valkey `maxmemory`, if enabled | 10% of RAM, capped at 2 GB, minimum 256 MB |
| Varnish cache, if enabled | 5% of RAM, capped at 2 GB, minimum 256 MB |

> [!NOTE]
> The setup script validates total allocations before proceeding and will warn or abort if they would exceed available memory.

---

## Security Model

- **SSH**: Root and the restricted (application) user each pick key-only or password-only login independently via `ROOT_PASSWORD_AUTH_ENABLED` and `SSH_PASSWORD_AUTH_ENABLED` (both default `no`) — enabling one doesn't force the other to switch, and resetting root's password specifically is opt-in (`ROOT_PASSWORD_AUTH_ENABLED=yes` requires `SSH_PASSWORD_AUTH_ENABLED=yes`, since sshd's `PasswordAuthentication` is a single server-wide switch; `PermitRootLogin` is what actually gates root once that's on). By default both are key-only: `PasswordAuthentication no` and `PermitRootLogin prohibit-password`, written to an authoritative drop-in (`/etc/ssh/sshd_config.d/40-hardening.conf`, sorted to win over any distro/cloud-init drop-in like `50-cloud-init.conf`). The effective config is verified with `sshd -T` before sshd restarts — the module hard-fails rather than proceeding on an unverified claim. When a key is used, it's deployed to `authorized_keys` — if a different key already exists there (e.g. from cloud-init), the write is refused rather than silently overwritten, since combined with password auth being disabled that would be a permanent lockout.
- **Restricted user**: The application user has no `sudo` rights but does have direct SSH login — key-based via `RESTRICTED_USER_SSH_PUBLIC_KEY`, or password-based via `RESTRICTED_USER_PASSWORD` when `SSH_PASSWORD_AUTH_ENABLED=yes` — a full but unprivileged shell either way. It's also reachable via `su - <RESTRICTED_USERNAME>` from a root session. A separate Git deploy key is generated for it so you can pull a private repo when deploying manually.
- **phpMyAdmin**: When enabled, served on a non-standard port behind HTTP Basic Authentication with a randomly generated URL path.
- **Service binding**: The database, OpenSearch, and Valkey (whichever are enabled) all bind to `127.0.0.1` only. MySQL 5.6/5.7's Docker container publishes to `127.0.0.1:3306` specifically (not `0.0.0.0`) for the same reason — Docker manages its own iptables/nftables rules and a wider publish can bypass UFW entirely, so the loopback-only bind is what actually keeps it unreachable from outside the host.
- **Varnish/Nginx**: When Varnish is enabled it owns port 80; Nginx listens on port 8080 and is not directly exposed. No VCL is written by this repo — the package default forwards the real client IP via `X-Forwarded-For` through to PHP-FPM automatically, so the application's maintenance-mode IP allowlists and request logs see the actual visitor IP rather than Varnish's own address. When Varnish is disabled, Nginx binds port 80 directly.
- **Firewall (UFW)**: Only port 80, the phpMyAdmin port, and — when `ENABLE_SSL_TERMINATION=yes` — port 443 are open externally.
- **Nginx headers**: `X-Frame-Options`, `X-XSS-Protection`, `X-Content-Type-Options`, `Referrer-Policy` are set on all responses.
- **Config file loader**: `lib/functions.sh` uses a strict allowlist-based parser that rejects unknown variables and blocks shell injection patterns in `server-setup.conf`.

---

## Production Checklist

> [!WARNING]
> This script must not be treated as production-ready without completing the validations below.

<details>
<summary><strong>Expand checklist</strong></summary>

- [ ] Review every generated configuration file (Nginx, PHP-FPM, the database, OpenSearch, Varnish — whichever are enabled) against your organisation's hardening standards
- [ ] Test the full setup end-to-end on a staging environment before deploying to production
- [ ] Confirm firewall rules allow only the ports your environment requires
- [ ] Implement automated database and file backups with off-site storage
- [ ] Set up centralised log monitoring and alerting
- [ ] Establish a patch management process for OS, PHP, and MariaDB
- [ ] Validate SSL/TLS configuration with an external tool (e.g. SSL Labs)
- [ ] Confirm `server-setup.conf` is not committed to version control and has restricted file permissions (`chmod 600 server-setup.conf`)

</details>

---

## Deploying Your Application

This repo stops at server provisioning. It doesn't assume Magento — the same server works for WordPress, Drupal, or a plain PHP app; adjust the steps below accordingly. Once the script finishes:

1. `su - <RESTRICTED_USERNAME>` and deploy your application into `${WEB_ROOT}` (`/var/www/<DOMAIN_NAME>`) however you normally do — Composer install, the framework's setup command, database import, etc. The restricted user's public Git deploy key (printed at the end of the run, and saved in `server_setup_info.txt`) can be added to your repository host for a private `git clone`.
2. If your application ships its own Nginx rules (Magento does; most others don't), add `include ${WEB_ROOT}/nginx.conf;` to the server block in `/etc/nginx/sites-available/<DOMAIN_NAME>` once that file exists, then `nginx -t && systemctl reload nginx`.
3. If Varnish is enabled, it's running with Ubuntu's package-default VCL (no Full Page Cache — it passes anything with cookies) until you install your application's own VCL: configure Varnish as the caching backend in your application's admin (if it has one), export its VCL, and replace `/etc/varnish/default.vcl` with it, then `systemctl reload varnish`.
4. If using the auto-generated self-signed certificate, replace it at `/etc/nginx/ssl/` with a real one (e.g. a Cloudflare Origin Certificate or Let's Encrypt) for production use — or set `SSL_CERT_PATH`/`SSL_KEY_PATH` in the config and re-run `sudo bash setup-ubuntu24.sh --modules=ssl-termination`.

---

## Logs

| Log | Location |
|---|---|
| Server setup | `./setup-server-<timestamp>.log` |
| Nginx | `/var/log/nginx/` |
| PHP-FPM | `/var/log/php<version>-fpm.log` |

---

## File Structure

```
magento-server-setup/
├── setup-ubuntu24.sh           # Main server provisioning script (run as root) — defines module run order
├── server-setup.conf.example  # Configuration template
├── server-setup.conf          # Your configuration — NOT committed (gitignored)
├── tools/
│   └── config-generator.html   # Interactive, browser-only server-setup.conf generator
├── lib/
│   └── functions.sh            # Shared helpers: output, config loader, validators, module resolution
└── server-setup/
    ├── system.sh               # System packages, restricted user, web root
    ├── nginx.sh                # Nginx
    ├── php.sh                  # PHP-FPM
    ├── database.sh             # MariaDB or MySQL, per DB_ENGINE
    ├── opensearch.sh           # OpenSearch (optional)
    ├── valkey.sh               # Valkey — Redis-compatible cache (optional)
    ├── varnish.sh              # Varnish Cache (optional)
    ├── composer.sh             # Composer (optional)
    ├── phpmyadmin.sh           # phpMyAdmin (optional)
    ├── security.sh             # UFW firewall + SSH hardening + deploy key
    ├── ssl-termination.sh      # Nginx SSL termination (optional)
    ├── vhost.sh                # Placeholder Nginx virtual host
    └── finalize.sh             # Final checks, info file, summary
```

---

## Known Constraints

- **Ubuntu 24.04 LTS only** — package sources (e.g. `ondrej/php` PPA, MariaDB's/Oracle's official apt repos) are version-specific to this release.
- **MySQL 5.6/5.7 run in Docker, not natively** — Oracle's apt repository no longer carries them for Ubuntu 24.04, so the `database` module runs the official `mysql:5.6`/`mysql:5.7` image in a Docker container instead (installing Docker itself if it isn't already present). It's bound to `127.0.0.1:3306` with a persistent volume at `/var/lib/docker-mysql-legacy/data` — back that up the same way you would `/var/lib/mysql`. This is the only place in the toolchain that depends on Docker.
- **Single-node OpenSearch** — configured as `discovery.type: single-node`; not suitable for clustering.
- **Local services only** — all backend services bind to `127.0.0.1`; modify the relevant module if a distributed setup is needed.
- **No automated backups** — implement an external backup strategy before going to production.
- **No application deployment** — installing/deploying the application itself is intentionally out of scope; bring your own process.
- **Varnish has no Full Page Cache until the app is deployed** — this repo installs Varnish but writes no VCL, so Ubuntu's package default (conservative — passes anything with cookies) is what's running. Install the application's own VCL post-deploy to get real FPC behavior; see [Deploying Your Application](#deploying-your-application).
- **Valkey has no version selector** — unlike PHP/the database/OpenSearch/Varnish, Valkey has no official apt repo with version selection (checked directly against Valkey's own packaging discussion); the only way to pin an exact version would be compiling from source, which this repo doesn't do. `valkey.sh` installs whatever version Ubuntu's own default repo ships (currently 7.2.x on 24.04).

---

## Contributing

Bug reports and pull requests are welcome. Please [open an issue](../../issues) first to discuss any significant changes before submitting a PR.

---

## License

[GPL-3.0](LICENSE)
