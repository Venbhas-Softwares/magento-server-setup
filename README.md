# Magento 2 Server Setup — Ubuntu 24.04 LTS

![Platform](https://img.shields.io/badge/platform-Ubuntu%2024.04%20LTS-E95420?logo=ubuntu&logoColor=white)
![Shell](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white)
![PHP](https://img.shields.io/badge/PHP-8.1%20%7C%208.2%20%7C%208.3-777BB4?logo=php&logoColor=white)
![License](https://img.shields.io/badge/license-GPL--3.0-blue)

Automated shell scripts to provision a production-ready Magento 2 server from scratch on Ubuntu 24.04 LTS, then install Magento 2 as a second step.

> [!WARNING]
> **Do not use these scripts for production deployments without thorough review and validation.**
> The scripts are provided as a starting point and have not been independently audited for security or reliability. Before running on any production system you must review every module, verify all generated configurations against your organisation's standards, test on a staging environment, and confirm that security hardening meets your requirements. You assume full responsibility for any production use.

---

## Table of Contents

- [Overview](#overview)
- [Stack](#stack)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Configuration Reference](#configuration-reference)
- [What Each Script Does](#what-each-script-does)
- [Resource Sizing](#resource-sizing)
- [Security Model](#security-model)
- [Production Checklist](#production-checklist)
- [Post-Installation](#post-installation)
- [Logs](#logs)
- [File Structure](#file-structure)
- [Known Constraints](#known-constraints)
- [Contributing](#contributing)
- [License](#license)

---

## Overview

The setup is split into two sequential scripts that share a single configuration file:

| Script | Run as | Purpose |
|---|---|---|
| `setup-ubuntu24.sh` | `root` | Provisions the full server stack |
| `install-magento.sh` | Restricted user | Downloads and installs Magento 2 |

Both scripts read from `magento-setup.conf`, which you create once before running either script.

> [!IMPORTANT]
> `magento-setup.conf` contains credentials and must **never** be committed to version control. Add it to `.gitignore` immediately after creating it.

---

## Stack

| Component | Role |
|---|---|
| **Nginx** | Web server / reverse proxy (port 8080, behind Varnish) |
| **Varnish Cache** | Full-page cache (port 80) |
| **PHP-FPM** | Application runtime (8.1–8.3 configurable) |
| **MariaDB** | Relational database |
| **OpenSearch** | Search engine (replaces Elasticsearch in Magento 2.4+) |
| **Valkey (Redis-compatible)** | Sessions, application cache, full-page cache (separate DBs) |
| **Composer** | PHP dependency manager |
| **phpMyAdmin** | Database GUI (secured on a non-standard port with random URL path) |
| **UFW** | Host firewall |
| **Let's Encrypt / Certbot** | TLS certificate (optional, installed by `install-magento.sh`) |

---

## Prerequisites

- Ubuntu 24.04 LTS (fresh install recommended)
- Root SSH access with a public/private key pair
- Domain name with DNS pointing to the server (required for SSL)
- Magento Marketplace account with API keys ([marketplace.magento.com](https://marketplace.magento.com))

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
cp magento-setup.conf.example magento-setup.conf
nano magento-setup.conf
```

Fill in **all** values — see the [Configuration Reference](#configuration-reference) below.

> [!IMPORTANT]
> Add `magento-setup.conf` to your `.gitignore` before making any commits:
> ```bash
> echo "magento-setup.conf" >> .gitignore
> ```

### 3. Run the server setup (as root)

```bash
sudo bash setup-ubuntu24.sh
```

This provisions the entire server stack. A timestamped log file is saved in the current directory.

### 4. Run the Magento installer (as the restricted user)

```bash
ssh root@YOUR_SERVER_IP -i /path/to/your/private/key
su - magento
bash /path/to/install-magento.sh
```

This downloads Magento via Composer, installs it, configures Nginx, and optionally installs the SSL certificate.

---

## Configuration Reference

Copy `magento-setup.conf.example` to `magento-setup.conf` and fill in all values. Both scripts read from this single file.

<details>
<summary><strong>Shared settings</strong></summary>

| Variable | Example | Description |
|---|---|---|
| `DOMAIN_NAME` | `example.com` | Your store's domain name |

</details>

<details>
<summary><strong>Server setup — <code>setup-ubuntu24.sh</code></strong></summary>

| Variable | Example | Description |
|---|---|---|
| `PHP_VERSION` | `8.3` | PHP version: `8.1`, `8.2`, or `8.3` |
| `OPENSEARCH_VERSION` | `2.15` | OpenSearch version, e.g. `2.11`, `2.13`, `2.15` |
| `COMPOSER_VERSION` | `2` | Composer major version: `1` or `2` |
| `MARIADB_ROOT_PASSWORD` | — | Strong password for the MariaDB root user |
| `RESTRICTED_USER` | `magento` | Linux username for the Magento application user |
| `SSH_PUBLIC_KEY` | `ssh-ed25519 AAAA…` | Your full SSH public key (key-based auth only) |
| `PMA_PORT` | `61098` | Non-standard port for phpMyAdmin (1–65535) |
| `PMA_USERNAME` | `pma_admin` | phpMyAdmin login username |
| `PMA_PASSWORD` | — | Strong password for phpMyAdmin |

</details>

<details>
<summary><strong>Magento installation — <code>install-magento.sh</code></strong></summary>

| Variable | Example | Description |
|---|---|---|
| `DB_NAME` | `magento2` | Database name to create |
| `DB_USER` | `magento_user` | Database user |
| `DB_PASSWORD` | — | Strong database password |
| `DB_HOST` | `localhost` | Database host |
| `ADMIN_FIRSTNAME` | `Admin` | Magento admin first name |
| `ADMIN_LASTNAME` | `User` | Magento admin last name |
| `ADMIN_EMAIL` | `admin@example.com` | Magento admin email |
| `ADMIN_USERNAME` | `admin` | Magento admin username |
| `ADMIN_PASSWORD` | `Admin123!` | Magento admin password (must meet complexity rules) |
| `CURRENCY` | `USD` | Store default currency |
| `TIMEZONE` | `America/Chicago` | Store timezone |
| `LANGUAGE` | `en_US` | Store locale |
| `MAGENTO_PUBLIC_KEY` | — | Public key from Magento Marketplace |
| `MAGENTO_PRIVATE_KEY` | — | Private key from Magento Marketplace |
| `INSTALL_SSL` | `y` | Install Let's Encrypt SSL: `y` or `n` |
| `SSL_EMAIL` | `ssl@example.com` | Email for SSL certificate notifications (required if `INSTALL_SSL=y`) |

</details>

<details>
<summary><strong>Generated values (auto-populated — do not edit)</strong></summary>

The scripts append these to `magento-setup.conf` automatically after running:

| Variable | Set by | Description |
|---|---|---|
| `PMA_PATH` | `setup-ubuntu24.sh` | Randomly generated phpMyAdmin URL path |
| `MAGENTO_DIR` | `setup-ubuntu24.sh` | Magento installation path (`/var/www/<DOMAIN_NAME>`) |
| `MAGENTO_INSTALLED` | `install-magento.sh` | Installation status flag |
| `MAGENTO_BASE_URL` | `install-magento.sh` | Store base URL |
| `MAGENTO_ADMIN_URL` | `install-magento.sh` | Admin panel URL |

</details>

---

## What Each Script Does

### `setup-ubuntu24.sh` — Server provisioning

The main script validates the configuration and detected hardware, then sources each numbered module in `modules/` in order:

<details>
<summary><strong>View all modules</strong></summary>

| Module | What it does |
|---|---|
| `01-system.sh` | System update, essential packages, restricted user, Magento web root |
| `02-nginx.sh` | Nginx installation and base configuration |
| `03-php.sh` | PHP-FPM installation, `php.ini`, and pool configuration |
| `04-mariadb.sh` | MariaDB installation, hardening, and Magento-optimised `my.cnf` |
| `05-opensearch.sh` | OpenSearch installation and JVM heap configuration |
| `06-valkey.sh` | Valkey (Redis-compatible) installation and memory limits |
| `07-varnish.sh` | Varnish Cache installation, VCL configuration, and systemd unit |
| `08-composer.sh` | Composer installation |
| `09-phpmyadmin.sh` | phpMyAdmin secured with HTTP Basic Auth, random port, and random URL path |
| `10-security.sh` | UFW firewall rules, SSH hardening (key-only, password auth disabled) |
| `11-finalize.sh` | Nginx test and restart, config persistence, info file at `./server_setup_info.txt` (same directory as the script) |

</details>

### `install-magento.sh` — Magento installation

1. Validates the user is **not** root
2. Detects the installed PHP version
3. Validates all required config values
4. Configures Composer authentication against `repo.magento.com`
5. Downloads Magento 2 Community Edition via Composer (skipped if already present)
6. Creates the database
7. Sets directory permissions
8. Runs `php bin/magento setup:install` with:
   - OpenSearch as the search engine
   - Valkey for sessions (DB 0), application cache (DB 1), and full-page cache (DB 2)
9. Sets Magento to production mode
10. Generates and installs the Nginx virtual host configuration
11. Optionally installs a Let's Encrypt SSL certificate via Certbot
12. Sets up three Magento cron jobs
13. Runs final reindex and cache flush
14. Saves an info file to `~/magento_install_info_<domain>.txt`

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

- **SSH**: Password authentication is disabled. Only key-based login is permitted. The key from `SSH_PUBLIC_KEY` is deployed to `root`'s `authorized_keys`.
- **Restricted user**: The Magento application user has no `sudo` rights and no direct SSH access. It is reachable only via `su - <RESTRICTED_USER>` from a root session.
- **phpMyAdmin**: Served on a non-standard port behind HTTP Basic Authentication with a randomly generated URL path.
- **Service binding**: MariaDB, OpenSearch, and Valkey all bind to `127.0.0.1` only.
- **Varnish/Nginx**: Varnish owns port 80; Nginx listens on port 8080 and is not directly exposed.
- **Firewall (UFW)**: Only ports 80, 443, and the phpMyAdmin port are open externally.
- **Nginx headers**: `X-Frame-Options`, `X-XSS-Protection`, `X-Content-Type-Options`, `Referrer-Policy` are set on all responses.
- **Config file loader**: `lib/functions.sh` uses a strict allowlist-based parser that rejects unknown variables and blocks shell injection patterns in `magento-setup.conf`.

---

## Production Checklist

> [!WARNING]
> These scripts must not be treated as production-ready without completing the validations below.

<details>
<summary><strong>Expand checklist</strong></summary>

- [ ] Review every generated configuration file (Nginx, PHP-FPM, MariaDB, OpenSearch, Varnish) against your organisation's hardening standards
- [ ] Test the full setup end-to-end on a staging environment before deploying to production
- [ ] Replace the default Varnish VCL with one exported from your Magento admin panel (**Stores → Configuration → Advanced → System → Full Page Cache**)
- [ ] Change the Magento admin URL from the default `/admin` to a custom path
- [ ] Enable Magento Two-Factor Authentication (2FA) for all admin accounts
- [ ] Confirm firewall rules allow only the ports your environment requires
- [ ] Implement automated database and file backups with off-site storage
- [ ] Set up centralised log monitoring and alerting
- [ ] Establish a patch management process for OS, PHP, MariaDB, and Magento
- [ ] Perform a security scan (e.g. Magento Security Scan Tool) before going live
- [ ] Validate SSL/TLS configuration with an external tool (e.g. SSL Labs)
- [ ] Confirm `magento-setup.conf` is not committed to version control and has restricted file permissions (`chmod 600 magento-setup.conf`)

</details>

---

## Post-Installation

### Common Magento commands

Run these from the Magento root directory (`/var/www/<domain>`):

```bash
php bin/magento cache:flush
php bin/magento indexer:reindex
php bin/magento setup:static-content:deploy -f
php bin/magento setup:di:compile
php bin/magento maintenance:enable
php bin/magento maintenance:disable
php bin/magento setup:upgrade
php bin/magento module:status
```

### Service management

```bash
sudo systemctl restart php8.3-fpm
sudo systemctl restart nginx
sudo systemctl restart varnish
sudo systemctl restart valkey-server
sudo systemctl status opensearch
```

### Monitor Varnish cache

```bash
varnishstat
```

---

## Logs

| Log | Location |
|---|---|
| Server setup | `./setup-server-<timestamp>.log` |
| Magento install | `./install-magento-<timestamp>.log` |
| Magento application | `/var/www/<domain>/var/log/` |
| Nginx | `/var/log/nginx/` |
| PHP-FPM | `/var/log/php<version>-fpm.log` |

---

## File Structure

```
magento-server-setup/
├── setup-ubuntu24.sh           # Main server provisioning script (run as root)
├── install-magento.sh          # Magento application installer (run as restricted user)
├── magento-setup.conf.example  # Configuration template
├── magento-setup.conf          # Your configuration — NOT committed (add to .gitignore)
├── lib/
│   └── functions.sh            # Shared helpers: output, config loader, validators
└── modules/
    ├── 01-system.sh            # System packages, restricted user, web root
    ├── 02-nginx.sh             # Nginx
    ├── 03-php.sh               # PHP-FPM
    ├── 04-mariadb.sh           # MariaDB
    ├── 05-opensearch.sh        # OpenSearch
    ├── 06-valkey.sh            # Valkey (Redis-compatible cache)
    ├── 07-varnish.sh           # Varnish Cache
    ├── 08-composer.sh          # Composer
    ├── 09-phpmyadmin.sh        # phpMyAdmin
    ├── 10-security.sh          # UFW firewall + SSH hardening
    └── 11-finalize.sh          # Final checks, info file, summary
```

---

## Known Constraints

- **Ubuntu 24.04 LTS only** — package sources (e.g. `ondrej/php` PPA) are version-specific to this release.
- **Single-node OpenSearch** — configured as `discovery.type: single-node`; not suitable for clustering.
- **Local services only** — all backend services bind to `127.0.0.1`; modify the relevant module if a distributed setup is needed.
- **No automated backups** — implement an external backup strategy before going to production.

---

## Contributing

Bug reports and pull requests are welcome. Please [open an issue](../../issues) first to discuss any significant changes before submitting a PR.

---

## License

[GPL-3.0](LICENSE)
