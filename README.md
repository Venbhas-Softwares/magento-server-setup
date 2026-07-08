# Magento 2 Server Setup — Ubuntu 24.04 LTS

![Platform](https://img.shields.io/badge/platform-Ubuntu%2024.04%20LTS-E95420?logo=ubuntu&logoColor=white)
![Shell](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white)
![PHP](https://img.shields.io/badge/PHP-8.1%20%7C%208.2%20%7C%208.3%20%7C%208.4-777BB4?logo=php&logoColor=white)
![License](https://img.shields.io/badge/license-GPL--3.0-blue)

An automated shell script to provision a production-ready Magento 2 **server** from scratch on Ubuntu 24.04 LTS — Nginx, PHP-FPM, MariaDB, OpenSearch, Valkey, Varnish, Composer, phpMyAdmin, and security hardening.

> [!NOTE]
> This repo provisions the **server infrastructure only**. Deploying the Magento application itself (Composer install, `setup:install`, database import, admin account) is out of scope — bring your own deployment process and point it at the web root this script creates.

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

`setup-ubuntu24.sh` is the single entry point. It validates a config file, detects hardware, then sources each numbered module in `server-setup/` in order.

| Script | Run as | Purpose |
|---|---|---|
| `setup-ubuntu24.sh` | `root` | Provisions the full server stack |

It reads from `server-setup.conf`, which you create once before running it.

> [!IMPORTANT]
> `server-setup.conf` contains credentials and must **never** be committed to version control. It's already listed in `.gitignore`.

---

## Stack

| Component | Role |
|---|---|
| **Nginx** | Web server / reverse proxy (port 8080, behind Varnish) |
| **Varnish Cache** | Full-page cache (port 80) |
| **PHP-FPM** | Application runtime (8.1–8.4 configurable) |
| **MariaDB** | Relational database |
| **OpenSearch** | Search engine (replaces Elasticsearch in Magento 2.4+) |
| **Valkey (Redis-compatible)** | Sessions, application cache, full-page cache (separate DBs) |
| **Composer** | PHP dependency manager |
| **phpMyAdmin** | Database GUI (secured on a non-standard port with random URL path) |
| **UFW** | Host firewall |
| **Nginx SSL termination** | TLS on :443 → Varnish on :80 (self-signed origin cert by default; optional — skip if TLS is already terminated upstream) |

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

Fill in **all** values — see the [Configuration Reference](#configuration-reference) below.

### 3. Run the server setup (as root)

```bash
sudo bash setup-ubuntu24.sh
```

This provisions the entire server stack. A timestamped log file is saved in the current directory, and a summary is written to `server_setup_info.txt`.

### Running individual modules

Use `--modules` to (re)run specific modules instead of the full sequence — useful when iterating on one piece of the stack:

```bash
sudo bash setup-ubuntu24.sh --modules=03,05,09
sudo bash setup-ubuntu24.sh --modules=03-php.sh
```

---

## Configuration Reference

Copy `server-setup.conf.example` to `server-setup.conf` and fill in all values.

| Variable | Example | Description |
|---|---|---|
| `DOMAIN_NAME` | `example.com` | Domain name the server will host |
| `PHP_VERSION` | `8.4` | PHP version: `8.1`, `8.2`, `8.3`, or `8.4` |
| `OPENSEARCH_VERSION` | `3.5.0` | OpenSearch version, e.g. `2.15`, `3.5.0` |
| `COMPOSER_VERSION` | `2` | Composer major version: `2` |
| `MARIADB_VERSION` | `11.4` | MariaDB version, e.g. `10.11`, `11.4`, `11.8` |
| `MARIADB_ROOT_PASSWORD` | — | Strong password for the MariaDB root user |
| `RESTRICTED_USERNAME` | `magento` | Linux username for the application user |
| `ROOT_USER_SSH_PUBLIC_KEY` | `ssh-ed25519 AAAA…` | Your full SSH public key for root login (key-based auth only) |
| `RESTRICTED_USER_SSH_PUBLIC_KEY` | `ssh-ed25519 AAAA…` | SSH public key for the restricted user's login (key-based auth only) |
| `PMA_PORT` | `61098` | Non-standard port for phpMyAdmin (1–65535) |
| `PMA_USERNAME` | `pma_admin` | phpMyAdmin login username |
| `PMA_PASSWORD` | — | Strong password for phpMyAdmin |
| `ENABLE_SSL_TERMINATION` | `yes` | `yes`/`no` — whether module 11 sets up Nginx TLS termination on :443. Set `no` if TLS is already terminated upstream (Cloudflare Flexible mode, an external load balancer, another CDN) |
| `SSL_CERT_PATH` | *(optional)* | Absolute path to a certificate to use instead of the auto-generated self-signed one. Must be set together with `SSL_KEY_PATH`, or left blank |
| `SSL_KEY_PATH` | *(optional)* | Absolute path to the matching private key. Must be set together with `SSL_CERT_PATH`, or left blank |

<details>
<summary><strong>Generated values (auto-populated — do not edit)</strong></summary>

The script appends these to `server-setup.conf` automatically after running:

| Variable | Description |
|---|---|
| `PMA_PATH` | Randomly generated phpMyAdmin URL path |
| `MAGENTO_DIR` | Web root path (`/var/www/<DOMAIN_NAME>`) |

</details>

---

## What the Script Does

`setup-ubuntu24.sh` validates the configuration and detected hardware, then sources each numbered module in `server-setup/` in order:

| Module | What it does |
|---|---|
| `01-system.sh` | System update, essential packages, restricted user, web root |
| `02-nginx.sh` | Nginx installation and base configuration |
| `03-php.sh` | PHP-FPM installation, `php.ini`, and pool configuration |
| `04-mariadb.sh` | MariaDB installation, hardening, and Magento-optimised `my.cnf` |
| `05-opensearch.sh` | OpenSearch installation and JVM heap configuration |
| `06-valkey.sh` | Valkey (Redis-compatible) installation and memory limits |
| `07-varnish.sh` | Varnish Cache installation, VCL configuration, and systemd unit |
| `08-composer.sh` | Composer installation |
| `09-phpmyadmin.sh` | phpMyAdmin secured with HTTP Basic Auth, random port, and random URL path |
| `10-security.sh` | UFW firewall rules, SSH hardening (key-only, password auth disabled), Git deploy key for the restricted user |
| `11-ssl-termination.sh` | Nginx SSL termination on :443 (self-signed or operator-supplied cert, proxies to Varnish) — optional, skipped when `ENABLE_SSL_TERMINATION=no` |
| `12-vhost.sh` | Placeholder Nginx virtual host for the web root |
| `13-finalize.sh` | Nginx test/restart, config persistence, `server_setup_info.txt` summary |

---

## Resource Sizing

Service allocations are calculated dynamically from detected hardware at runtime.

| Service | Sizing rule |
|---|---|
| PHP memory limit | 2 GB minimum, scales to 6 GB+ on systems with 16 GB+ RAM |
| PHP-FPM workers | 20–150 children based on RAM; start/spare counts based on CPU cores |
| MariaDB `innodb_buffer_pool_size` | 50% of system RAM |
| OpenSearch heap (`-Xms` / `-Xmx`) | 50% of RAM, capped at 8 GB |
| Valkey `maxmemory` | 10% of RAM, capped at 2 GB |
| Varnish cache | 256 MB (fixed) |

> [!NOTE]
> The setup script validates total allocations before proceeding and will warn or abort if they would exceed available memory.

---

## Security Model

- **SSH**: Password authentication is disabled. Only key-based login is permitted. The key from `ROOT_USER_SSH_PUBLIC_KEY` is deployed to `root`'s `authorized_keys`.
- **Restricted user**: The application user has no `sudo` rights but does have direct, key-based SSH login (the key from `RESTRICTED_USER_SSH_PUBLIC_KEY` is deployed to its `authorized_keys`) — a full but unprivileged shell. It's also reachable via `su - <RESTRICTED_USERNAME>` from a root session. A separate Git deploy key is generated for it so you can pull a private repo when deploying manually.
- **phpMyAdmin**: Served on a non-standard port behind HTTP Basic Authentication with a randomly generated URL path.
- **Service binding**: MariaDB, OpenSearch, and Valkey all bind to `127.0.0.1` only.
- **Varnish/Nginx**: Varnish owns port 80; Nginx listens on port 8080 and is not directly exposed. Varnish forwards the real client IP via `X-Forwarded-For` through to PHP-FPM, so Magento's maintenance-mode IP allowlist and request logs see the actual visitor IP rather than Varnish's own address.
- **Firewall (UFW)**: Only port 80, the phpMyAdmin port, and — when `ENABLE_SSL_TERMINATION=yes` — port 443 are open externally.
- **Nginx headers**: `X-Frame-Options`, `X-XSS-Protection`, `X-Content-Type-Options`, `Referrer-Policy` are set on all responses.
- **Config file loader**: `lib/functions.sh` uses a strict allowlist-based parser that rejects unknown variables and blocks shell injection patterns in `server-setup.conf`.

---

## Production Checklist

> [!WARNING]
> This script must not be treated as production-ready without completing the validations below.

<details>
<summary><strong>Expand checklist</strong></summary>

- [ ] Review every generated configuration file (Nginx, PHP-FPM, MariaDB, OpenSearch, Varnish) against your organisation's hardening standards
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

This repo stops at server provisioning. Once it finishes:

1. `su - <RESTRICTED_USERNAME>` and deploy Magento into `${MAGENTO_DIR}` (`/var/www/<DOMAIN_NAME>`) however you normally do — Composer install, `bin/magento setup:install`, database import, etc. The restricted user's public Git deploy key (printed at the end of the run, and saved in `server_setup_info.txt`) can be added to your repository host for a private `git clone`.
2. Add `include ${MAGENTO_DIR}/nginx.conf;` to the server block in `/etc/nginx/sites-available/<DOMAIN_NAME>` once Magento's `nginx.conf` exists, then `nginx -t && systemctl reload nginx`.
3. Configure Varnish as the caching backend in the Magento admin, export its VCL, and review it against `/etc/varnish/default.vcl`.
4. If using the auto-generated self-signed certificate, replace it at `/etc/nginx/ssl/` with a real one (e.g. a Cloudflare Origin Certificate or Let's Encrypt) for production use — or set `SSL_CERT_PATH`/`SSL_KEY_PATH` in the config and re-run `sudo bash setup-ubuntu24.sh --modules=11`.

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
├── setup-ubuntu24.sh           # Main server provisioning script (run as root)
├── server-setup.conf.example  # Configuration template
├── server-setup.conf          # Your configuration — NOT committed (gitignored)
├── lib/
│   └── functions.sh            # Shared helpers: output, config loader, validators
└── server-setup/
    ├── 01-system.sh            # System packages, restricted user, web root
    ├── 02-nginx.sh             # Nginx
    ├── 03-php.sh               # PHP-FPM
    ├── 04-mariadb.sh           # MariaDB
    ├── 05-opensearch.sh        # OpenSearch
    ├── 06-valkey.sh            # Valkey (Redis-compatible cache)
    ├── 07-varnish.sh           # Varnish Cache
    ├── 08-composer.sh          # Composer
    ├── 09-phpmyadmin.sh        # phpMyAdmin
    ├── 10-security.sh          # UFW firewall + SSH hardening + deploy key
    ├── 11-ssl-termination.sh   # Nginx SSL termination
    ├── 12-vhost.sh             # Placeholder Nginx virtual host
    └── 13-finalize.sh          # Final checks, info file, summary
```

---

## Known Constraints

- **Ubuntu 24.04 LTS only** — package sources (e.g. `ondrej/php` PPA) are version-specific to this release.
- **Single-node OpenSearch** — configured as `discovery.type: single-node`; not suitable for clustering.
- **Local services only** — all backend services bind to `127.0.0.1`; modify the relevant module if a distributed setup is needed.
- **No automated backups** — implement an external backup strategy before going to production.
- **No application deployment** — Magento installation/deployment is intentionally out of scope; bring your own process.

---

## Contributing

Bug reports and pull requests are welcome. Please [open an issue](../../issues) first to discuss any significant changes before submitting a PR.

---

## License

[GPL-3.0](LICENSE)
