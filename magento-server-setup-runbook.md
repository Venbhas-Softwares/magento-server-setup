# Server Setup Runbook (Ubuntu 26.04 LTS)

This runbook provisions a production PHP application server on Ubuntu 26.04 LTS: Nginx, PHP-FPM, MariaDB, OpenSearch, Valkey, Varnish, Composer, phpMyAdmin, HTTPS, and the security hardening around them. The server stays general-purpose, but every version and setting is chosen to meet the system requirements of Magento Open Source and Adobe Commerce 2.4.9, so a Magento store can be deployed onto it without changes. Part 6 then deploys an existing Magento store onto the app server from its Git repository, a database dump, and a media archive, and configures Nginx, Varnish, the indexers, and cron for it.

| Component | Version | Source | Magento 2.4.9 requirement |
|---|---|---|---|
| PHP | 8.5 | Ubuntu 26.04 | 8.5 |
| Nginx | 1.28 | Ubuntu 26.04 | 1.30 (see the **Nginx** section) |
| MariaDB | 12.3 | MariaDB repository | 12.3 (recommended) or 11.8 |
| OpenSearch | 3.x | OpenSearch repository | 3 |
| Valkey | 9.0 | Ubuntu 26.04 | 9 |
| Varnish | 7.7 | Ubuntu 26.04 | 8 (see the **Varnish** section) |
| Composer | 2.10 | getcomposer.org installer | 2.10 |

Nginx and Varnish are one minor or major version below Magento 2.4.9's list, and in both cases the version installed is the one Magento 2.4.8 lists. Nginx deliberately stays on Ubuntu's own package, so that it receives Ubuntu's security updates. Varnish 8 has no Ubuntu 26.04 package yet, so the runbook installs Ubuntu's Varnish 7.7, which runs Magento's exported VCL unchanged, and the **Varnish** section explains how to move to 8 once a 26.04 package exists.

Everything can run on one server, or the database and OpenSearch can run on servers of their own. For example, a three-server setup has an app server (Nginx, PHP, Varnish, Valkey, phpMyAdmin), a database server (MariaDB), and an OpenSearch server. You run this same runbook on each server, choose in the **Server role** block which services that server runs, and skip the sections for services it does not run. Provision the database and OpenSearch servers first, so that the app server's final checks can reach them.

How to use it:

- Each `bash` block has its own run button in Runme. Blocks labelled `text` are notes, not commands.
- The runbook is grouped by server. Part 1 runs on every server, Parts 2, 3, and 4 cover the database, OpenSearch, and app servers, Part 5 runs on every server again, and Part 6 deploys Magento on the app server. Part 7 stands on its own: it repairs drifted file permissions on an app server that is already running, including one set up before this runbook existed. On each server, run the parts that apply to it from top to bottom, because later blocks depend on values set by earlier ones. A single server that runs everything goes through every part.
- Each service section says which servers it applies to. The **Resource sizing** block also prints the list of sections to run on the current server.
- Every block in a section that applies only to some servers first checks this server's **Variables** values. If you run such a block on the wrong server by mistake, it stops with a "Skip this block" message before changing anything, and Runme keeps none of its values.
- Run the **Variables** blocks that apply to this server, then the **Resource sizing** block, first. Variables last only for the current Runme session, but the Variables blocks also save their values on the server. In every later session, for example after you restart VS Code or the Runme kernel, run the **Load saved settings** block and then the **Resource sizing** block before continuing. Blocks that need a variable stop with an error if it is missing, rather than running with an empty value.
- Blocks that generate a password print it once. Copy each one into your password manager straight away, then clear the cell output.

## Before you start (AWS)

1. Launch each instance from an Ubuntu 26.04 LTS (x86-64) image.
2. Take an EBS snapshot of each instance, so you can roll back if something goes wrong.
3. In each instance's security group, allow inbound traffic only on the ports for the services that instance runs:

```text
App server, or a single server that runs everything (SSL_MODE=letsencrypt or custom):
22/tcp    SSH         from your own IP address only
80/tcp    HTTP        from anywhere (needed for Let's Encrypt and the HTTP site)
443/tcp   HTTPS       from anywhere

App server behind a load balancer that handles HTTPS (SSL_MODE=off):
22/tcp    SSH         from your own IP address only
80/tcp    HTTP        from the load balancer's security group only

Database server:
22/tcp    SSH         from your own IP address only
3306/tcp  MariaDB     from the app server's security group only

OpenSearch server:
22/tcp    SSH         from your own IP address only
9200/tcp  OpenSearch  from the app server's security group only
```

On a single server, no other port needs to be open, because MariaDB, OpenSearch, Valkey, and phpMyAdmin all listen on `127.0.0.1` only. With separate servers, put them all in the same VPC and connect them through their private IP addresses. Database and OpenSearch traffic between the servers is not encrypted, which is acceptable only inside a private network that is closed to everything except the app servers.

## Part 1: Every server, first

Run this part on every server before anything else. It brings Ubuntu up to date, records what this server runs, and calculates the memory for each of its services. Every later part depends on it, which is why it comes first even though it is not specific to any one server.

### System update and base packages

Confirm that the server runs Ubuntu 26.04 LTS. Every repository and package name in this runbook is chosen for that release.

```bash
. /etc/os-release
echo "$PRETTY_NAME"
if [ "$VERSION_ID" != "26.04" ]; then echo "WARNING: this runbook is written for Ubuntu 26.04 LTS, not $VERSION_ID."; fi
```

```bash
sudo apt update
sudo apt full-upgrade -y
sudo apt install -y ca-certificates curl gnupg git unzip apache2-utils
sudo timedatectl set-timezone UTC
```

If the update installed a new kernel, reboot now, before any values are set. A reboot ends the Runme session and clears every variable, which is why this section comes first. Reconnect afterwards and continue with the **Variables** blocks.

```bash
if [ -f /var/run/reboot-required ]; then echo "Reboot required"; else echo "No reboot needed"; fi
```

```bash
sudo reboot
```

### Variables

The variables are split into three blocks, so that each server is asked only for the values it uses. Runme asks for each value when you run a block. Replace the defaults with the values for this server.

Each Variables block, and the **Deployment settings** block in Part 6, saves its values once they pass its checks. They go into hidden files in your home folder on the server, named `~/.server-setup-*.env`, which only your user can read. In a later Runme session, the **Load saved settings** block below restores them, so you do not have to type them again. Running a Variables block again replaces its saved values with the new ones, and a block that fails its checks saves nothing.

#### Server role

Run this block on every server. Each value is `yes` or `no` and chooses which of the main services this server runs. `INSTALL_APP` covers Nginx, PHP-FPM, and Composer.

Each block in this section checks its values when it runs. If a required value is missing or invalid, the block stops with an error and Runme keeps none of its values, so run the block again with corrected values.

```bash
export INSTALL_APP="yes"
export INSTALL_MARIADB="yes"
export INSTALL_OPENSEARCH="yes"

OK=yes
for PAIR in "INSTALL_APP=$INSTALL_APP" "INSTALL_MARIADB=$INSTALL_MARIADB" "INSTALL_OPENSEARCH=$INSTALL_OPENSEARCH"; do
  case "${PAIR#*=}" in
    yes|no) ;;
    *) echo "ERROR: ${PAIR%%=*} must be yes or no, not '${PAIR#*=}'."; OK=no ;;
  esac
done
if [ "$OK" = yes ] && [ "$INSTALL_APP$INSTALL_MARIADB$INSTALL_OPENSEARCH" = nonono ]; then
  echo "ERROR: At least one of INSTALL_APP, INSTALL_MARIADB, and INSTALL_OPENSEARCH must be yes."; OK=no
fi
if [ "$OK" = yes ]; then
  (umask 077; for NAME in INSTALL_APP INSTALL_MARIADB INSTALL_OPENSEARCH; do printf 'export %s=%q\n' "$NAME" "${!NAME}"; done > ~/.server-setup-role.env; chmod 600 ~/.server-setup-role.env)
  echo "Server role saved to ~/.server-setup-role.env."
else
  exit 1
fi
```

#### App server settings

Run this block only on a server with `INSTALL_APP=yes`. Skip it on a database or OpenSearch server.

Keep `PHP_VERSION` at `8.5`: it is the only PHP version that Ubuntu 26.04 ships and that Magento 2.4.9 supports. `ADMIN_EMAIL` is used only with `SSL_MODE=letsencrypt`, as the address Let's Encrypt writes to about expiring certificates. Valkey, Varnish, and phpMyAdmin run alongside Nginx and PHP, so they are chosen here (`yes` or `no`).

`DB_SERVER_IP` and `OPENSEARCH_SERVER_IP` take private IP addresses and are needed only when that service runs on a server of its own. Leave `DB_SERVER_IP` empty when MariaDB runs on this server, and leave `OPENSEARCH_SERVER_IP` empty when OpenSearch runs on this server or the application does not use it.

`SSL_MODE` chooses how the app server handles HTTPS:

- `letsencrypt` (the default) gets a free certificate from Let's Encrypt, which renews automatically. The certificate covers both the domain and its `www` name, so DNS for both must point to this server, and port 80 must be open to the internet.
- `custom` uses a certificate you supply, such as a Cloudflare Origin Certificate or one bought from a certificate authority. You set its file paths in the **HTTPS** section.
- `off` means this server does not handle HTTPS at all, because a load balancer (for example, an AWS Application Load Balancer with a certificate from AWS Certificate Manager) handles it and forwards plain HTTP to port 80. Use this when several app servers share a load balancer.

`TRUSTED_PROXY_CIDRS` is used only with `SSL_MODE=off`. It lists the address ranges the load balancer connects from, usually the VPC's range, such as `10.0.0.0/16`, separated by spaces. Nginx then records each visitor's real IP address rather than the load balancer's, and the firewall accepts port 80 from those ranges only.

```bash
[ "${INSTALL_APP:?Run the Server role block first}" = yes ] || { echo "Skip this block: it is for the app server, and this server has INSTALL_APP=$INSTALL_APP."; exit 1; }
export DOMAIN_NAME="example.com"
export WEB_USER="webuser"
export PHP_VERSION="8.5"
export ADMIN_EMAIL="admin@example.com"

export INSTALL_VALKEY="yes"
export INSTALL_VARNISH="yes"
export INSTALL_PHPMYADMIN="yes"

export DB_SERVER_IP=""
export OPENSEARCH_SERVER_IP=""

export SSL_MODE="letsencrypt"
export TRUSTED_PROXY_CIDRS=""

OK=yes
IPV4='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
fail() { echo "ERROR: $1"; OK=no; }
if [ -z "$DOMAIN_NAME" ] || [ "$DOMAIN_NAME" = example.com ]; then
  fail "DOMAIN_NAME is required. Enter this site's domain, not example.com."
elif ! [[ "$DOMAIN_NAME" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
  fail "DOMAIN_NAME '$DOMAIN_NAME' is not a valid domain name."
fi
[[ "$WEB_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || fail "WEB_USER '$WEB_USER' is not a valid Linux user name (lowercase letters, digits, - and _)."
[ "$PHP_VERSION" = 8.5 ] || fail "PHP_VERSION must be 8.5, not '$PHP_VERSION'."
for PAIR in "INSTALL_VALKEY=$INSTALL_VALKEY" "INSTALL_VARNISH=$INSTALL_VARNISH" "INSTALL_PHPMYADMIN=$INSTALL_PHPMYADMIN"; do
  case "${PAIR#*=}" in
    yes|no) ;;
    *) fail "${PAIR%%=*} must be yes or no, not '${PAIR#*=}'." ;;
  esac
done
case "$SSL_MODE" in
  letsencrypt)
    if ! [[ "$ADMIN_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[A-Za-z]{2,}$ ]] || [ "$ADMIN_EMAIL" = admin@example.com ]; then
      fail "ADMIN_EMAIL is required with SSL_MODE=letsencrypt. Enter a real address, not admin@example.com."
    fi ;;
  custom|off) ;;
  *) fail "SSL_MODE must be letsencrypt, custom, or off, not '$SSL_MODE'." ;;
esac
if [ "$INSTALL_MARIADB" = no ] && [ -z "$DB_SERVER_IP" ]; then
  fail "DB_SERVER_IP is required, because MariaDB runs on another server. Enter that server's private IP address."
fi
for PAIR in "DB_SERVER_IP=$DB_SERVER_IP" "OPENSEARCH_SERVER_IP=$OPENSEARCH_SERVER_IP"; do
  if [ -n "${PAIR#*=}" ] && ! [[ "${PAIR#*=}" =~ $IPV4 ]]; then fail "${PAIR%%=*} '${PAIR#*=}' is not an IPv4 address."; fi
done
for CIDR in $TRUSTED_PROXY_CIDRS; do
  [[ "$CIDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || fail "'$CIDR' in TRUSTED_PROXY_CIDRS is not an address range such as 10.0.0.0/16."
done
if [ "$OK" = yes ]; then
  (umask 077; for NAME in DOMAIN_NAME WEB_USER PHP_VERSION ADMIN_EMAIL INSTALL_VALKEY INSTALL_VARNISH INSTALL_PHPMYADMIN DB_SERVER_IP OPENSEARCH_SERVER_IP SSL_MODE TRUSTED_PROXY_CIDRS; do printf 'export %s=%q\n' "$NAME" "${!NAME}"; done > ~/.server-setup-app.env; chmod 600 ~/.server-setup-app.env)
  echo "App server settings saved to ~/.server-setup-app.env."
else
  exit 1
fi
```

#### Database and OpenSearch server settings

Run this block on a server that runs MariaDB or OpenSearch for app servers elsewhere. Skip it when everything runs on one server. `APP_SERVER_IPS` lists the private IP addresses of the app servers that may connect, separated by spaces, and it is required on a server that does not run the app. Only these addresses are let through the firewall to MariaDB (port 3306) or OpenSearch (port 9200). On a MariaDB server, they are also the only addresses given a database login. OpenSearch has no login of its own, so on an OpenSearch server the firewall and the AWS security group are what keep everyone else out.

```bash
[ "${INSTALL_MARIADB:?Run the Server role block first}" = yes ] || [ "$INSTALL_OPENSEARCH" = yes ] || { echo "Skip this block: this server runs neither MariaDB nor OpenSearch."; exit 1; }
export APP_SERVER_IPS=""

OK=yes
if [ "$INSTALL_APP" = no ] && [ -z "$APP_SERVER_IPS" ]; then
  echo "ERROR: APP_SERVER_IPS is required on a server that does not run the app. Enter the private IP address of each app server."; OK=no
fi
for IP in $APP_SERVER_IPS; do
  [[ "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "ERROR: '$IP' in APP_SERVER_IPS is not an IPv4 address."; OK=no; }
done
if [ "$OK" = yes ]; then
  (umask 077; printf 'export %s=%q\n' APP_SERVER_IPS "$APP_SERVER_IPS" > ~/.server-setup-db-opensearch.env; chmod 600 ~/.server-setup-db-opensearch.env)
  echo "Database and OpenSearch server settings saved to ~/.server-setup-db-opensearch.env."
else
  exit 1
fi
```

For example, with an app server at `10.0.1.10`, a database server at `10.0.1.20`, and an OpenSearch server at `10.0.1.30`, each server runs these blocks with these values (every value not shown keeps its default):

```text
App server:         Server role                 INSTALL_MARIADB=no  INSTALL_OPENSEARCH=no
                    App server settings         DB_SERVER_IP=10.0.1.20  OPENSEARCH_SERVER_IP=10.0.1.30

Database server:    Server role                 INSTALL_APP=no  INSTALL_OPENSEARCH=no
                    Database/OpenSearch         APP_SERVER_IPS=10.0.1.10

OpenSearch server:  Server role                 INSTALL_APP=no  INSTALL_MARIADB=no
                    Database/OpenSearch         APP_SERVER_IPS=10.0.1.10
```

#### Load saved settings

Run this block, instead of the Variables blocks, at the start of every later Runme session on this server, for example after you reload the window, reconnect after a reboot, or restart VS Code. It restores every value that the Variables blocks and the **Deployment settings** block saved on this server, without asking for any of them. It lists the names it loaded but not their values, because the saved files include the database password and Magento's encryption key. Run the **Resource sizing** block after it, which recalculates the memory settings from the server's current RAM.

```bash
FOUND=no
for FILE in ~/.server-setup-role.env ~/.server-setup-app.env ~/.server-setup-db-opensearch.env ~/.server-setup-deployment.env; do
  [ -f "$FILE" ] || continue
  source "$FILE"
  FOUND=yes
  echo "Loaded from $FILE: $(sed -E 's/^export ([A-Za-z_]+)=.*/\1/' "$FILE" | tr '\n' ' ')"
done
[ "$FOUND" = yes ] || { echo "No saved settings were found on this server. Run this server's Variables blocks instead."; exit 1; }
```

#### Delete saved settings

The saved files stay on the server until you delete them. Keeping them is useful while you are still setting up the server or deploying releases with Part 6. Delete them once the server is finished, before you create an image of the server or hand it to someone else, or whenever you want to start again with fresh values. This block deletes the files only. The values stay in the current Runme session until it ends, and the server's configuration does not change.

```bash
rm -f ~/.server-setup-role.env ~/.server-setup-app.env ~/.server-setup-db-opensearch.env ~/.server-setup-deployment.env
ls ~/.server-setup-*.env 2> /dev/null || echo "No saved settings remain on this server."
```

### Resource sizing

This block checks the choices made in the **Variables** blocks, reads the server's RAM, and calculates the memory for each service that this server runs, so that they all fit together. Services that run elsewhere get no memory here. Run it before the install sections.

When MariaDB or OpenSearch is the only main service on a server, it gets a dedicated server's share of RAM: 70% for the MariaDB buffer pool, or 50% for the OpenSearch heap (capped at 30 GB so that Java keeps its memory-efficient object pointers, with the rest of the RAM serving as file cache). When it shares the server with the application or with the other service, it gets a smaller share: the MariaDB buffer pool gets 25% of RAM on servers with up to 8 GB and 30% above that, and the OpenSearch heap gets 25% of RAM, capped at 8 GB (or 1 GB on servers with 6 GB of RAM or less).

```bash
: "${INSTALL_APP:?Run the Variables blocks first}"

# Check the choices from the Variables blocks
ROLE_OK=yes
for PAIR in "INSTALL_APP=$INSTALL_APP" "INSTALL_MARIADB=$INSTALL_MARIADB" "INSTALL_OPENSEARCH=$INSTALL_OPENSEARCH"; do
  case "${PAIR#*=}" in
    yes|no) ;;
    *) echo "ERROR: ${PAIR%%=*} must be yes or no, not '${PAIR#*=}'."; ROLE_OK=no ;;
  esac
done
if [ "$INSTALL_APP" = no ]; then
  # Valkey, Varnish, and phpMyAdmin run only alongside the application
  export INSTALL_VALKEY=no INSTALL_VARNISH=no INSTALL_PHPMYADMIN=no
  if [ "$INSTALL_MARIADB" != yes ] && [ "$INSTALL_OPENSEARCH" != yes ]; then
    echo "ERROR: No service is selected for this server."; ROLE_OK=no
  elif [ -z "$APP_SERVER_IPS" ]; then
    echo "ERROR: Run the Database and OpenSearch server settings block, with APP_SERVER_IPS set to the private IP address of each app server that connects to this server."; ROLE_OK=no
  fi
fi
if [ "$INSTALL_APP" = yes ] && [ -z "$DOMAIN_NAME" ]; then
  echo "ERROR: INSTALL_APP=yes, so run the App server settings block too."; ROLE_OK=no
elif [ "$INSTALL_APP" = yes ]; then
  for PAIR in "INSTALL_VALKEY=$INSTALL_VALKEY" "INSTALL_VARNISH=$INSTALL_VARNISH" "INSTALL_PHPMYADMIN=$INSTALL_PHPMYADMIN"; do
    case "${PAIR#*=}" in
      yes|no) ;;
      *) echo "ERROR: ${PAIR%%=*} must be yes or no, not '${PAIR#*=}'."; ROLE_OK=no ;;
    esac
  done
  if [ "$INSTALL_MARIADB" = no ] && [ -z "$DB_SERVER_IP" ]; then
    echo "ERROR: Set DB_SERVER_IP to the database server's private IP address."; ROLE_OK=no
  fi
  case "$SSL_MODE" in
    letsencrypt|custom) ;;
    off)
      if [ -z "$TRUSTED_PROXY_CIDRS" ]; then
        echo "WARNING: TRUSTED_PROXY_CIDRS is empty, so port 80 stays open to everyone and visitors' IP addresses will appear as the load balancer's."
      fi ;;
    *) echo "ERROR: SSL_MODE must be letsencrypt, custom, or off, not '$SSL_MODE'."; ROLE_OK=no ;;
  esac
fi

# This server's private IP address, which remote app servers connect to
PRIVATE_IP=$(ip -4 route get 1.1.1.1 | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')

# How many of the main services (application, MariaDB, OpenSearch) share this server
MAIN_SERVICES=0
for S in "$INSTALL_APP" "$INSTALL_MARIADB" "$INSTALL_OPENSEARCH"; do
  if [ "$S" = yes ]; then MAIN_SERVICES=$((MAIN_SERVICES + 1)); fi
done

# MariaDB buffer pool: 70% of RAM on a dedicated server; otherwise 25% up to 8 GB of RAM, 30% above that
DB_BUFFER_POOL_MB=0
if [ "$INSTALL_MARIADB" = yes ]; then
  if [ "$MAIN_SERVICES" -eq 1 ]; then
    DB_BUFFER_POOL_MB=$((TOTAL_RAM_MB * 70 / 100))
  elif [ "$TOTAL_RAM_MB" -le 8192 ]; then
    DB_BUFFER_POOL_MB=$((TOTAL_RAM_MB * 25 / 100))
  else
    DB_BUFFER_POOL_MB=$((TOTAL_RAM_MB * 30 / 100))
  fi
fi

# OpenSearch heap: 50% of RAM (at most 30 GB) on a dedicated server; otherwise 25% of RAM,
# capped at 8 GB (1 GB on servers with 6 GB of RAM or less)
OPENSEARCH_HEAP_MB=0
if [ "$INSTALL_OPENSEARCH" = yes ]; then
  if [ "$MAIN_SERVICES" -eq 1 ]; then
    OPENSEARCH_HEAP_MB=$((TOTAL_RAM_MB * 50 / 100))
    [ "$OPENSEARCH_HEAP_MB" -gt 30720 ] && OPENSEARCH_HEAP_MB=30720
  else
    OPENSEARCH_HEAP_MB=$((TOTAL_RAM_MB * 25 / 100))
    [ "$OPENSEARCH_HEAP_MB" -gt 8192 ] && OPENSEARCH_HEAP_MB=8192
    [ "$TOTAL_RAM_MB" -le 6144 ] && [ "$OPENSEARCH_HEAP_MB" -gt 1024 ] && OPENSEARCH_HEAP_MB=1024
  fi
fi

# Valkey: 10% of RAM, between 512 MB and 2 GB, split between two instances:
# a quarter (at least 128 MB) for sessions, and the rest for the cache
VALKEY_MEMORY_MB=0
VALKEY_CACHE_MB=0
VALKEY_SESSION_MB=0
if [ "$INSTALL_VALKEY" = yes ]; then
  VALKEY_MEMORY_MB=$((TOTAL_RAM_MB * 10 / 100))
  [ "$VALKEY_MEMORY_MB" -lt 512 ] && VALKEY_MEMORY_MB=512
  [ "$VALKEY_MEMORY_MB" -gt 2048 ] && VALKEY_MEMORY_MB=2048
  VALKEY_SESSION_MB=$((VALKEY_MEMORY_MB / 4))
  [ "$VALKEY_SESSION_MB" -lt 128 ] && VALKEY_SESSION_MB=128
  VALKEY_CACHE_MB=$((VALKEY_MEMORY_MB - VALKEY_SESSION_MB))
fi

# Varnish cache: 5% of RAM, between 256 MB and 2 GB
VARNISH_CACHE_MB=0
if [ "$INSTALL_VARNISH" = yes ]; then
  VARNISH_CACHE_MB=$((TOTAL_RAM_MB * 5 / 100))
  [ "$VARNISH_CACHE_MB" -lt 256 ] && VARNISH_CACHE_MB=256
  [ "$VARNISH_CACHE_MB" -gt 2048 ] && VARNISH_CACHE_MB=2048
fi

# Operating system reserve: 5% of RAM, at least 512 MB
RESERVE_MB=$((TOTAL_RAM_MB * 5 / 100))
[ "$RESERVE_MB" -lt 512 ] && RESERVE_MB=512

REMAINING_MB=$((TOTAL_RAM_MB - DB_BUFFER_POOL_MB - OPENSEARCH_HEAP_MB - VALKEY_MEMORY_MB - VARNISH_CACHE_MB - RESERVE_MB))

# PHP-FPM gets what is left. 768 MB covers the shared OPcache and JIT buffers,
# and each PHP worker is estimated at 120 MB on average.
if [ "$INSTALL_APP" = yes ]; then
  REMAINING_MB=$((REMAINING_MB - 768))
  PHP_MAX_CHILDREN=$((REMAINING_MB / 120))
  [ "$PHP_MAX_CHILDREN" -lt 5 ] && PHP_MAX_CHILDREN=5
  PHP_START_SERVERS=$((PHP_MAX_CHILDREN / 4)); [ "$PHP_START_SERVERS" -lt 2 ] && PHP_START_SERVERS=2
  PHP_MIN_SPARE=$((PHP_MAX_CHILDREN / 8));     [ "$PHP_MIN_SPARE" -lt 1 ] && PHP_MIN_SPARE=1
  PHP_MAX_SPARE=$((PHP_MAX_CHILDREN / 2));     [ "$PHP_MAX_SPARE" -lt "$PHP_START_SERVERS" ] && PHP_MAX_SPARE=$PHP_START_SERVERS
fi

if [ "$ROLE_OK" = yes ]; then
  export PRIVATE_IP TOTAL_RAM_MB DB_BUFFER_POOL_MB OPENSEARCH_HEAP_MB VALKEY_CACHE_MB VALKEY_SESSION_MB VARNISH_CACHE_MB
  if [ "$INSTALL_APP" = yes ]; then
    export PHP_MAX_CHILDREN PHP_START_SERVERS PHP_MIN_SPARE PHP_MAX_SPARE
  else
    unset PHP_MAX_CHILDREN PHP_START_SERVERS PHP_MIN_SPARE PHP_MAX_SPARE
  fi

  echo "Private IP address:   ${PRIVATE_IP}"
  echo "Total RAM:            ${TOTAL_RAM_MB} MB"
  [ "$INSTALL_MARIADB" = yes ]    && echo "MariaDB buffer pool:  ${DB_BUFFER_POOL_MB} MB"
  [ "$INSTALL_OPENSEARCH" = yes ] && echo "OpenSearch heap:      ${OPENSEARCH_HEAP_MB} MB"
  [ "$INSTALL_VALKEY" = yes ]     && echo "Valkey memory:        ${VALKEY_CACHE_MB} MB cache, ${VALKEY_SESSION_MB} MB sessions"
  [ "$INSTALL_VARNISH" = yes ]    && echo "Varnish cache:        ${VARNISH_CACHE_MB} MB"
  [ "$INSTALL_APP" = yes ]        && echo "PHP-FPM workers:      max ${PHP_MAX_CHILDREN}, start ${PHP_START_SERVERS}, spare ${PHP_MIN_SPARE} to ${PHP_MAX_SPARE}"
  if [ "$INSTALL_APP" = yes ] && [ "$REMAINING_MB" -lt 600 ]; then
    echo "WARNING: very little RAM is left for PHP. Use a larger instance."
  elif [ "$REMAINING_MB" -lt 0 ]; then
    echo "WARNING: the services need more RAM than this server has. Use a larger instance."
  fi

  echo
  echo "Sections still to run on this server:"
  [ "$INSTALL_MARIADB" = yes ]    && echo "  Part 2: MariaDB"
  [ "$INSTALL_OPENSEARCH" = yes ] && echo "  Part 3: OpenSearch"
  [ "$INSTALL_APP" = yes ]        && echo "  Part 4: Restricted user and web root, PHP, Nginx"
  [ "$INSTALL_VALKEY" = yes ]     && echo "  Part 4: Valkey"
  [ "$INSTALL_VARNISH" = yes ]    && echo "  Part 4: Varnish"
  [ "$INSTALL_APP" = yes ]        && echo "  Part 4: Composer"
  [ "$INSTALL_PHPMYADMIN" = yes ] && echo "  Part 4: phpMyAdmin"
  if [ "$INSTALL_APP" = yes ] && [ "$SSL_MODE" = letsencrypt ]; then echo "  Part 4: HTTPS (Let's Encrypt certificate)"; fi
  if [ "$INSTALL_APP" = yes ] && [ "$SSL_MODE" = custom ]; then echo "  Part 4: HTTPS (your own certificate)"; fi
  echo "  Part 5: Security hardening, Final verification"
  if [ "$INSTALL_APP" = yes ]; then echo "  Part 6: Deploy Magento"; fi
else
  unset PRIVATE_IP TOTAL_RAM_MB DB_BUFFER_POOL_MB OPENSEARCH_HEAP_MB VALKEY_CACHE_MB VALKEY_SESSION_MB VARNISH_CACHE_MB
  unset PHP_MAX_CHILDREN PHP_START_SERVERS PHP_MIN_SPARE PHP_MAX_SPARE
  echo "Fix the values above in the Variables blocks, then run those blocks and the Resource sizing block again."
fi
```

## Part 2: Database server

Run this part on the server with `INSTALL_MARIADB=yes`: the database server in a multi-server setup, or the only server in a single-server setup. Skip it on every other server.

### MariaDB

Run this section on the server with `INSTALL_MARIADB=yes`. If the app runs on other servers, this section also opens MariaDB to the addresses in `APP_SERVER_IPS`.

Magento 2.4.9 supports MariaDB 12.3 (recommended) and 11.8. Ubuntu 26.04 ships 11.8, so this block adds MariaDB's official repository to install 12.3. To stay on Ubuntu's 11.8 instead, skip this block. The `--skip-maxscale` flag is required because the setup script otherwise also adds the MaxScale repository, which MariaDB does not publish for Ubuntu 26.04; its missing Release file makes `apt update` fail and aborts the script before the signing keys are installed. Magento does not use MaxScale.

```bash
[ "${INSTALL_MARIADB:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: this server has INSTALL_MARIADB=$INSTALL_MARIADB."; exit 1; }
curl -LsS https://r.mariadb.com/downloads/mariadb_repo_setup | sudo bash -s -- --mariadb-server-version=12.3 --skip-maxscale
sudo apt update
apt-cache policy mariadb-server
```

The Candidate line above shows the version that will be installed. If it is correct, continue.

The MariaDB package asks during installation whether to enable its Feedback plugin, which sends anonymous usage statistics to mariadb.org. Runme cells cannot answer that prompt, so this block answers it in advance with "no" and installs non-interactively.

```bash
[ "${INSTALL_MARIADB:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: this server has INSTALL_MARIADB=$INSTALL_MARIADB."; exit 1; }
echo "mariadb-server mariadb-server/feedback_optin boolean false" | sudo debconf-set-selections
sudo DEBIAN_FRONTEND=noninteractive apt install -y mariadb-server
sudo systemctl enable --now mariadb
```

This command is interactive. Answer **Y** to removing anonymous users, disallowing remote root login, and removing the test database. The root account already uses Unix socket authentication, so you do not need to set a root password.

```bash
[ "${INSTALL_MARIADB:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: this server has INSTALL_MARIADB=$INSTALL_MARIADB."; exit 1; }
sudo mariadb-secure-installation
```

#### MariaDB production settings

MariaDB always listens on `127.0.0.1`. When `APP_SERVER_IPS` is set, it also listens on this server's private IP address, so the app servers can connect. Only the app servers' addresses get through the firewall and receive a database login, both of which are set up later in this runbook. Listening on two addresses requires MariaDB 10.11 or later, which both supported versions are.

The settings follow Adobe's recommendations for Magento. `utf8mb4_general_ci` is the collation Magento's own tables use; MariaDB 11.5 and later default to `utf8mb4_uca1400_ai_ci`, and mixing the two causes "Illegal mix of collations" errors, so the server and its client connections are pinned to `utf8mb4_general_ci`. `max_allowed_packet` is raised for large catalog imports, the temporary table sizes are well above the 64 MB that Adobe suggests for indexers, and the two optimizer settings are Adobe's recommendation for faster reindexing on MariaDB.

```bash
[ "${INSTALL_MARIADB:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: this server has INSTALL_MARIADB=$INSTALL_MARIADB."; exit 1; }
: "${DB_BUFFER_POOL_MB:?Run the Resource sizing block first}"
DB_BIND="127.0.0.1"
[ -n "$APP_SERVER_IPS" ] && DB_BIND="127.0.0.1,$PRIVATE_IP"
sudo tee /etc/mysql/mariadb.conf.d/99-tuning.cnf > /dev/null <<EOF
[mysqld]
# Network: this server, plus the private IP address when app servers connect remotely
bind-address = $DB_BIND
skip-name-resolve

# Character set: Magento's tables use utf8mb4_general_ci
character-set-server = utf8mb4
collation-server = utf8mb4_general_ci
character_set_collations = utf8mb4=utf8mb4_general_ci

# InnoDB
innodb_buffer_pool_size = ${DB_BUFFER_POOL_MB}M
innodb_log_file_size = 1G
innodb_log_buffer_size = 32M
innodb_file_per_table = 1
innodb_flush_method = O_DIRECT

# Connections, packets, and temporary tables
max_connections = 200
max_allowed_packet = 256M
table_open_cache = 4000
join_buffer_size = 4M
tmp_table_size = 256M
max_heap_table_size = 256M

# Settings required or recommended by Magento
explicit_defaults_for_timestamp = ON
log_bin_trust_function_creators = 1
optimizer_switch = 'rowid_filter=off'
optimizer_use_condition_selectivity = 1

# Slow query log for performance troubleshooting
slow_query_log = 1
slow_query_log_file = /var/log/mysql/mariadb-slow.log
long_query_time = 2

# Remove binary logs older than 3 days, if binary logging is enabled
binlog_expire_logs_seconds = 259200
EOF
sudo systemctl restart mariadb
sudo mariadb -e "SELECT VERSION(); SHOW VARIABLES WHERE Variable_name IN ('innodb_buffer_pool_size', 'bind_address', 'collation_server', 'max_allowed_packet');"
```

`innodb_buffer_pool_instances` is deliberately absent. MariaDB 10.6 and later removed that option, and MariaDB 12 refuses to start if it is present.

#### Application database and user

Set the database and user names when Runme asks, then run the second block. When the app runs on this server, the block creates the user for both `localhost` (Unix socket) and `127.0.0.1` (TCP), because `skip-name-resolve` treats these as different hosts. It also creates the user for each address in `APP_SERVER_IPS`, so remote app servers can log in, and no other address can.

```bash
[ "${INSTALL_MARIADB:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: this server has INSTALL_MARIADB=$INSTALL_MARIADB."; exit 1; }
export DB_NAME="appdb"
export DB_USER="appuser"
```

```bash
[ "${INSTALL_MARIADB:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: this server has INSTALL_MARIADB=$INSTALL_MARIADB."; exit 1; }
: "${DB_NAME:?Run the previous block first}"
: "${TOTAL_RAM_MB:?Run the Resource sizing block first}"
DB_PASSWORD="$(openssl rand -hex 24)"
DB_HOSTS="$APP_SERVER_IPS"
[ "$INSTALL_APP" = yes ] && DB_HOSTS="localhost 127.0.0.1 $DB_HOSTS"
{
  echo "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
  for H in $DB_HOSTS; do
    echo "CREATE USER IF NOT EXISTS '$DB_USER'@'$H' IDENTIFIED BY '$DB_PASSWORD';"
    echo "ALTER USER '$DB_USER'@'$H' IDENTIFIED BY '$DB_PASSWORD';"
    echo "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'$H';"
  done
  echo "FLUSH PRIVILEGES;"
} | sudo mariadb
sudo mariadb -e "SELECT User, Host FROM mysql.user WHERE User = '$DB_USER';"
echo "Database: $DB_NAME"
echo "User:     $DB_USER"
echo "Password: $DB_PASSWORD"
if [ -n "$APP_SERVER_IPS" ]; then echo "Host for remote app servers: $PRIVATE_IP (port 3306)"; fi
```

Running the block again generates and sets a new password, so you can also use it to rotate the password.

## Part 3: OpenSearch server

Run this part on the server with `INSTALL_OPENSEARCH=yes`, and skip it on every other server.

### OpenSearch

Run this section on the server with `INSTALL_OPENSEARCH=yes`. If the app runs on other servers, this section also opens OpenSearch to them.

Add OpenSearch's official repository. Magento 2.4.9 supports OpenSearch 3, so the block uses the `3.x` repository.

```bash
[ "${INSTALL_OPENSEARCH:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: this server has INSTALL_OPENSEARCH=$INSTALL_OPENSEARCH."; exit 1; }
curl -o- https://artifacts.opensearch.org/publickeys/opensearch-release.pgp | sudo gpg --dearmor --batch --yes -o /usr/share/keyrings/opensearch-release-keyring
echo "deb [signed-by=/usr/share/keyrings/opensearch-release-keyring] https://artifacts.opensearch.org/releases/bundle/opensearch/3.x/apt stable main" | sudo tee /etc/apt/sources.list.d/opensearch-3.x.list
sudo apt update
apt-cache madison opensearch
```

Set the version you want from the list above when Runme asks. 3.9.0 was the newest 3.x release when this runbook was written.

```bash
[ "${INSTALL_OPENSEARCH:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: this server has INSTALL_OPENSEARCH=$INSTALL_OPENSEARCH."; exit 1; }
export OPENSEARCH_VERSION="3.9.0"
```

This block installs OpenSearch and prevents automatic upgrades to a version your application may not support. `DISABLE_INSTALL_DEMO_CONFIG=true` (available from OpenSearch 3.7) stops the installer from generating demo certificates and writing the security plugin's demo settings into `opensearch.yml`. That keeps the package's `opensearch.yml` exactly as shipped, which the next section relies on, and it also means no initial admin password is needed, because the security plugin is disabled below.

```bash
[ "${INSTALL_OPENSEARCH:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: this server has INSTALL_OPENSEARCH=$INSTALL_OPENSEARCH."; exit 1; }
: "${OPENSEARCH_VERSION:?Run the previous block first}"
sudo env DISABLE_INSTALL_DEMO_CONFIG=true apt install -y "opensearch=$OPENSEARCH_VERSION"
sudo apt-mark hold opensearch
```

Install the ICU and phonetic analysis plugins. Adobe enables both for OpenSearch on Adobe Commerce Cloud, and they improve search for accented and non-English text. The plugin installer fetches the build that matches the installed OpenSearch version. If you upgrade OpenSearch later, remove and reinstall both plugins, because a plugin built for another version stops OpenSearch from starting.

```bash
[ "${INSTALL_OPENSEARCH:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: this server has INSTALL_OPENSEARCH=$INSTALL_OPENSEARCH."; exit 1; }
sudo /usr/share/opensearch/bin/opensearch-plugin install --batch analysis-icu analysis-phonetic
sudo /usr/share/opensearch/bin/opensearch-plugin list
```

OpenSearch maps its index files into memory and refuses to start in production mode when the kernel's memory map limit is below 262144. This block raises the limit in a file of its own under `/etc/sysctl.d/`, so it applies now and after every reboot, and it prints the value the kernel is using.

```bash
[ "${INSTALL_OPENSEARCH:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: this server has INSTALL_OPENSEARCH=$INSTALL_OPENSEARCH."; exit 1; }
echo 'vm.max_map_count = 262144' | sudo tee /etc/sysctl.d/99-opensearch.conf
sudo sysctl -p /etc/sysctl.d/99-opensearch.conf > /dev/null
sysctl vm.max_map_count
```

#### OpenSearch production settings

This block configures OpenSearch before its first start. It runs as a single node, uses the heap size from the sizing block, and has the security plugin disabled. Its HTTP port (9200) listens on `127.0.0.1`, and also on this server's private IP address when `APP_SERVER_IPS` is set. The internal node-to-node port (9300) stays on `127.0.0.1`, because a single node has no other nodes to talk to. Applications connect over plain HTTP without a password, which is safe only because port 9200 is never exposed beyond this server and the app servers: the security group and the firewall rules later in this runbook let no other address reach it.

None of the package's files are edited, so an OpenSearch upgrade never stops to ask which version of a configuration file to keep, and the settings survive it:

- The settings are passed to OpenSearch as `-E` options in a systemd drop-in file, which take precedence over `opensearch.yml`. The block takes the package's own start command and only appends the options, the same approach as the Varnish section.
- The heap size goes into `jvm.options.d/`, the folder OpenSearch provides for local JVM settings.

The block is safe to run more than once, and running it again after an upgrade rebuilds the drop-in from the new package's start command.

```bash
[ "${INSTALL_OPENSEARCH:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: this server has INSTALL_OPENSEARCH=$INSTALL_OPENSEARCH."; exit 1; }
: "${OPENSEARCH_HEAP_MB:?Run the Resource sizing block first}"
OS_BIND="127.0.0.1"
[ -n "$APP_SERVER_IPS" ] && OS_BIND="127.0.0.1,$PRIVATE_IP"
EXEC=$(systemctl cat opensearch.service | grep -m1 '^ExecStart=/')
EXEC="$EXEC -Enetwork.host=$OS_BIND -Etransport.host=127.0.0.1 -Ediscovery.type=single-node -Eplugins.security.disabled=true"
sudo mkdir -p /etc/systemd/system/opensearch.service.d
printf "[Service]\nExecStart=\n%s\n" "$EXEC" | sudo tee /etc/systemd/system/opensearch.service.d/override.conf

printf -- "-Xms%sm\n-Xmx%sm\n" "$OPENSEARCH_HEAP_MB" "$OPENSEARCH_HEAP_MB" | sudo tee /etc/opensearch/jvm.options.d/heap.options

sudo systemctl daemon-reload
sudo systemctl enable opensearch.service
sudo systemctl restart opensearch.service
```

OpenSearch takes up to a minute to start. This block waits for it, then shows the cluster information and the settings OpenSearch is actually using. A JSON response with the version number means OpenSearch is running, and the second response should show the `network.host`, `transport.host`, `discovery.type`, and `plugins.security.disabled` values from the drop-in.

```bash
[ "${INSTALL_OPENSEARCH:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: this server has INSTALL_OPENSEARCH=$INSTALL_OPENSEARCH."; exit 1; }
for i in $(seq 1 30); do
  if curl -s http://127.0.0.1:9200 > /dev/null; then break; fi
  sleep 2
done
curl -s http://127.0.0.1:9200 || echo "OpenSearch is not responding. Check: sudo journalctl -u opensearch -n 50"
curl -s "http://127.0.0.1:9200/_nodes/_local/settings?pretty&filter_path=nodes.*.settings.network,nodes.*.settings.transport,nodes.*.settings.discovery,nodes.*.settings.plugins.security"
if [ -n "$APP_SERVER_IPS" ]; then echo "Address for remote app servers: http://$PRIVATE_IP:9200"; fi
```

## Part 4: App server

Run this part on the server with `INSTALL_APP=yes`. Valkey, Varnish, phpMyAdmin, and HTTPS also have settings of their own, so skip any of those sections that this server does not use.

### Restricted user and web root

Run this section on the app server only (`INSTALL_APP=yes`).

The restricted user owns the application files. It has no sudo access, logs in with an SSH key only, and shares the `www-data` group with PHP-FPM and Nginx. The **File permissions** block at the end of this section keeps the files that it and PHP-FPM create writable by both.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: it is for the app server, and this server has INSTALL_APP=$INSTALL_APP."; exit 1; }
: "${WEB_USER:?Run the Variables blocks first}"
sudo adduser --disabled-password --gecos "" "$WEB_USER"
sudo usermod -aG www-data "$WEB_USER"
sudo usermod -aG "$WEB_USER" www-data
```

When Runme asks for `PUBKEY`, paste the public key of the computer that should log in as this user: the whole single line from your `.pub` file, such as `~/.ssh/id_ed25519.pub`. The block refuses anything that is not a valid public key, including the placeholder, and it adds the key only once, so you can run it again with each developer's key. It ends by listing the fingerprints of every key the restricted user accepts. Compare them with the output of `ssh-keygen -lf ~/.ssh/id_ed25519.pub` on your computer to confirm that the right key is installed.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: it is for the app server, and this server has INSTALL_APP=$INSTALL_APP."; exit 1; }
: "${WEB_USER:?Run the Variables blocks first}"
export PUBKEY="ssh-ed25519 AAAA_REPLACE_WITH_YOUR_PUBLIC_KEY you@your-computer"
echo "$PUBKEY" | ssh-keygen -lf - > /dev/null 2>&1 || { echo "PUBKEY is not a valid SSH public key. Paste the whole line from your .pub file."; exit 1; }
sudo install -d -m 700 -o "$WEB_USER" -g "$WEB_USER" "/home/$WEB_USER/.ssh"
sudo touch "/home/$WEB_USER/.ssh/authorized_keys"
sudo grep -qxF "$PUBKEY" "/home/$WEB_USER/.ssh/authorized_keys" || echo "$PUBKEY" | sudo tee -a "/home/$WEB_USER/.ssh/authorized_keys" > /dev/null
sudo chown "$WEB_USER:$WEB_USER" "/home/$WEB_USER/.ssh/authorized_keys"
sudo chmod 600 "/home/$WEB_USER/.ssh/authorized_keys"
sudo ssh-keygen -lf "/home/$WEB_USER/.ssh/authorized_keys"
```

Generate a Git deploy key for the restricted user. Add the printed public key to your Git repository as a read-only deploy key, because Part 6 clones the store's code with it.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: it is for the app server, and this server has INSTALL_APP=$INSTALL_APP."; exit 1; }
: "${WEB_USER:?Run the Variables blocks first}"
sudo -u "$WEB_USER" ssh-keygen -t ed25519 -N "" -C "$WEB_USER@$DOMAIN_NAME" -f "/home/$WEB_USER/.ssh/id_ed25519"
sudo cat "/home/$WEB_USER/.ssh/id_ed25519.pub"
```

Create the web root. The setgid bit (`2775`) makes new files and folders inherit the `www-data` group automatically.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: it is for the app server, and this server has INSTALL_APP=$INSTALL_APP."; exit 1; }
: "${DOMAIN_NAME:?Run the Variables blocks first}"
sudo mkdir -p "/var/www/$DOMAIN_NAME"
sudo chown -R "$WEB_USER:www-data" "/var/www/$DOMAIN_NAME"
sudo chmod 2775 "/var/www/$DOMAIN_NAME"
ls -ld "/var/www/$DOMAIN_NAME"
```

#### File permissions

Everything in the web root follows one permission model. Every file and folder is owned by the restricted user or by `www-data` and belongs to the `www-data` group. Folders are `2775`, ordinary files are `664`, and executables (`bin/` and `*.sh`) are `775`. Under this model the restricted user and PHP-FPM can each change everything the other creates.

The setgid bit on the web root takes care of the group, but the umask of whichever process creates a file decides whether that file is group-writable. With Ubuntu's default umask of `022`, new files are created as `644` and new folders as `755`, and the other account cannot change them. This is how permissions drift on a running server. Magento sets a umask of `002` for its own PHP code, but Composer, Git, `rsync`, `tar`, and other tools do not, so this runbook sets `002` for every way that code reaches the web root:

- The restricted user's SSH logins and `su -` sessions get `umask 002` at the top of `~/.profile` and `~/.bashrc`. In `~/.bashrc` it sits above the line that stops non-interactive shells, so commands run as `ssh webuser@server 'command'` get it as well.
- Commands run with `sudo -u webuser` get it from a sudoers rule. Without that rule, sudo combines the caller's umask with its own default of `022`. Every block in this runbook that runs a command as the restricted user uses `sudo -u`.
- PHP-FPM gets it from a systemd setting in the **PHP-FPM pool** section.

The following rules keep the model intact when you deploy code:

- Run Composer, Git, and `bin/magento` in the web root as the restricted user, either logged in as that user or with `sudo -u webuser`. Never run them as root or as `ubuntu`, because the files they create would belong to the wrong account.
- Copy files with `rsync -rlt` rather than `rsync -a`. The `-a` option also copies each file's owner, group, and mode from the source machine, which replaces the `www-data` group and the setgid bit. With `-rlt`, the destination's umask and setgid bit decide them.
- Extract archives as the restricted user, without `--same-owner` or `--same-permissions`.
- For Magento, do not create a `magento_umask` file in the web root, because Magento uses its contents in place of its default umask of `002`.

If permissions have already drifted on a server, the **Reset file permissions** part at the end of this runbook repairs them.

This block sets the restricted user's umask. The sudoers rule is checked with `visudo` before it is installed, because a broken file in `/etc/sudoers.d/` would disable `sudo` for every account. The last two lines must both print `0002`.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: it is for the app server, and this server has INSTALL_APP=$INSTALL_APP."; exit 1; }
: "${WEB_USER:?Run the Variables blocks first}"
for F in .profile .bashrc; do
  P="/home/$WEB_USER/$F"
  if ! sudo grep -qx 'umask 002' "$P" 2>/dev/null; then
    if sudo test -s "$P"; then sudo sed -i '1i umask 002' "$P"; else echo 'umask 002' | sudo tee "$P" > /dev/null; fi
  fi
  sudo chown "$WEB_USER:$WEB_USER" "$P"
  sudo chmod 644 "$P"
done
echo "Defaults>$WEB_USER umask=0002, umask_override" > /tmp/web-user-umask
if sudo visudo -cf /tmp/web-user-umask; then
  sudo install -m 440 -o root -g root /tmp/web-user-umask /etc/sudoers.d/50-web-user-umask
else
  echo "ERROR: the sudoers rule did not pass visudo, so it was not installed."
fi
rm -f /tmp/web-user-umask
echo "Login umask:   $(sudo su - "$WEB_USER" -c umask)"
echo "sudo -u umask: $(sudo -u "$WEB_USER" sh -c umask)"
```

### PHP

Run this section on the app server only (`INSTALL_APP=yes`).

Ubuntu 26.04 ships PHP 8.5, which is the only PHP version Magento 2.4.9 supports, so no third-party repository is needed and PHP receives Ubuntu's security updates. OPcache is built into PHP 8.5, so there is no separate `opcache` package.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: it is for the app server, and this server has INSTALL_APP=$INSTALL_APP."; exit 1; }
: "${PHP_VERSION:?Run the Variables blocks first}"
V="$PHP_VERSION"
sudo apt install -y php$V-fpm php$V-cli php$V-common php$V-mysql php$V-bcmath php$V-curl \
  php$V-gd php$V-intl php$V-mbstring php$V-soap php$V-xml php$V-xsl php$V-zip php$V-gmp php$V-redis
php -v
```

Check that every PHP extension Magento 2.4.9 requires is loaded. The block prints `All required extensions are loaded`, or lists the missing ones.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: it is for the app server, and this server has INSTALL_APP=$INSTALL_APP."; exit 1; }
MISSING=""
for EXT in bcmath ctype curl dom fileinfo filter ftp gd hash iconv intl json libxml mbstring openssl \
           pcre pdo_mysql Reflection SimpleXML soap sockets sodium SPL tokenizer xmlwriter xsl zip zlib; do
  php -m | grep -qix "$EXT" || MISSING="$MISSING $EXT"
done
if [ -z "$MISSING" ]; then echo "All required extensions are loaded"; else echo "Missing:$MISSING"; fi
```

#### php.ini production settings

The settings go into separate override files, so a PHP package update never overwrites them. The web (FPM) settings are stricter than the command-line (CLI) settings. They follow Adobe's recommendations for Magento: `opcache.save_comments = 1` is required, because Magento generates code from PHP comments, and the realpath cache and OPcache sizes match a full Magento codebase. Timeouts are 600 seconds, matching the `fastcgi_read_timeout` in Magento's own Nginx configuration, so that long admin actions such as imports are not cut off. The CLI memory limit is 2 GB, which Magento's compilation and static content deployment commands need.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: it is for the app server, and this server has INSTALL_APP=$INSTALL_APP."; exit 1; }
: "${PHP_VERSION:?Run the Variables blocks first}"
sudo tee "/etc/php/$PHP_VERSION/fpm/conf.d/99-production.ini" > /dev/null <<'EOF'
memory_limit = 756M
max_execution_time = 600
max_input_time = 600
max_input_vars = 5000
upload_max_filesize = 64M
post_max_size = 64M
date.timezone = UTC

; Security
expose_php = Off
display_errors = Off
display_startup_errors = Off
log_errors = On
error_reporting = E_ALL & ~E_DEPRECATED
session.cookie_httponly = 1
session.use_strict_mode = 1
zend.assertions = -1

; Performance
realpath_cache_size = 10M
realpath_cache_ttl = 7200
opcache.enable = 1
opcache.memory_consumption = 512
opcache.interned_strings_buffer = 64
opcache.max_accelerated_files = 60000
opcache.validate_timestamps = 0
opcache.save_comments = 1
opcache.jit_buffer_size = 256M
opcache.jit = tracing
EOF

sudo tee "/etc/php/$PHP_VERSION/cli/conf.d/99-production.ini" > /dev/null <<'EOF'
memory_limit = 2G
max_input_vars = 5000
date.timezone = UTC
zend.assertions = -1
opcache.save_comments = 1
expose_php = Off
realpath_cache_size = 10M
realpath_cache_ttl = 7200
EOF
```

`opcache.validate_timestamps = 0` means PHP never checks whether code files have changed. This is the correct production setting, but after every deployment you must restart PHP-FPM (`sudo systemctl restart php8.5-fpm`), or the old code keeps running.

#### PHP-FPM pool

The pool settings go into a separate file, `zz-tuning.conf`, and the package's own `www.conf` is left untouched. Both files define the same `[www]` pool, and PHP-FPM reads them in alphabetical order, so the values in `zz-tuning.conf` win. Because `www.conf` is never edited, a PHP package upgrade can update it without stopping to ask which version to keep, and the tuning survives the upgrade.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: it is for the app server, and this server has INSTALL_APP=$INSTALL_APP."; exit 1; }
: "${PHP_VERSION:?Run the Variables blocks first}"
: "${PHP_MAX_CHILDREN:?Run the Resource sizing block first}"
sudo tee "/etc/php/$PHP_VERSION/fpm/pool.d/zz-tuning.conf" > /dev/null <<EOF
; Overrides for the [www] pool defined in www.conf
[www]
pm = dynamic
pm.max_children = $PHP_MAX_CHILDREN
pm.start_servers = $PHP_START_SERVERS
pm.min_spare_servers = $PHP_MIN_SPARE
pm.max_spare_servers = $PHP_MAX_SPARE
pm.max_requests = 500
request_terminate_timeout = 600
EOF

# -tt prints the effective configuration, which confirms the overrides are in use
sudo "php-fpm$PHP_VERSION" -tt 2>&1 | grep -E "(pm(\.(max_children|start_servers|min_spare_servers|max_spare_servers|max_requests))?|request_terminate_timeout) = "

# Files that PHP creates are group-writable (see File permissions in the Restricted user section)
sudo mkdir -p "/etc/systemd/system/php$PHP_VERSION-fpm.service.d"
printf '[Service]\nUMask=0002\n' | sudo tee "/etc/systemd/system/php$PHP_VERSION-fpm.service.d/umask.conf" > /dev/null
sudo systemctl daemon-reload
sudo systemctl enable --now "php$PHP_VERSION-fpm"
sudo systemctl restart "php$PHP_VERSION-fpm"
sleep 1
echo "PHP-FPM worker umask: $(awk '/^Umask/{print $2}' "/proc/$(pgrep -f 'php-fpm: pool' | head -1)/status")"
```

`pm.max_requests = 500` recycles each worker after 500 requests, which protects the server from slow memory leaks in application code.

The `UMask=0002` setting lives in a systemd drop-in file, so a PHP package upgrade leaves it in place. The last line of the block must print `0002`.

### Nginx

Run this section on the app server only (`INSTALL_APP=yes`).

Nginx comes from Ubuntu 26.04's own repository (version 1.28), so it receives Ubuntu's security updates. Magento 2.4.9 lists Nginx 1.30, and 1.28 is the version Magento 2.4.8 lists. If Magento's `nginx.conf.sample` ever fails `nginx -t` on 1.28, that is the point to revisit this choice.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: it is for the app server, and this server has INSTALL_APP=$INSTALL_APP."; exit 1; }
sudo apt install -y nginx
sudo systemctl enable --now nginx
nginx -v
```

Ubuntu's Nginx runs as `www-data`, the same account as PHP-FPM, and already ships the `snippets/fastcgi-php.conf` file that the PHP blocks below include. Each site (vhost) follows Ubuntu's convention: its file goes in `/etc/nginx/sites-available/`, and a link in `/etc/nginx/sites-enabled/` turns it on, so you can disable a site by removing its link without deleting its configuration. Settings that apply to every site, such as the two blocks below, go in `/etc/nginx/conf.d/`. Ubuntu's `nginx.conf` loads both folders, so the package's own files are never edited.

Global settings: hide the Nginx version, allow 64 MB uploads, and trust the visitor IP address forwarded by Varnish, the HTTPS proxy, and (with `SSL_MODE=off`) the load balancer ranges in `TRUSTED_PROXY_CIDRS`. The `map` lets PHP know when the original request used HTTPS. Ubuntu 26.04's `nginx.conf` already turns `server_tokens` off, and Nginx refuses to start when the directive appears twice, so the block adds it only when the package's file does not set it. The last lines print the trusted addresses and the `server_tokens` value Nginx actually uses.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: it is for the app server, and this server has INSTALL_APP=$INSTALL_APP."; exit 1; }
: "${SSL_MODE:?Run the Variables blocks first}"
sudo tee /etc/nginx/conf.d/00-server.conf > /dev/null <<'EOF'
client_max_body_size 64m;

# Real visitor IP: requests reach the application through Varnish on 127.0.0.1
set_real_ip_from 127.0.0.1;
real_ip_header X-Forwarded-For;
real_ip_recursive on;

# Tell PHP when the visitor connected over HTTPS (TLS ends at the :443 proxy or the load balancer)
map $http_x_forwarded_proto $fe_https {
    default off;
    https   on;
}
EOF
if [ "$SSL_MODE" = off ]; then
  for CIDR in $TRUSTED_PROXY_CIDRS; do
    echo "set_real_ip_from $CIDR;" | sudo tee -a /etc/nginx/conf.d/00-server.conf > /dev/null
  done
fi
if ! grep -qE '^\s*server_tokens\s' /etc/nginx/nginx.conf; then
  echo "server_tokens off;" | sudo tee -a /etc/nginx/conf.d/00-server.conf > /dev/null
fi
grep set_real_ip_from /etc/nginx/conf.d/00-server.conf
sudo nginx -t && sudo nginx -T 2>/dev/null | grep -E '^\s*server_tokens\s'
```

Define the PHP-FPM upstream under the name `fastcgi_backend`. Magento's own Nginx configuration (`nginx.conf.sample`) sends PHP requests to an upstream with exactly that name, so defining it here lets you switch to Magento's configuration later without further changes.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: it is for the app server, and this server has INSTALL_APP=$INSTALL_APP."; exit 1; }
: "${PHP_VERSION:?Run the Variables blocks first}"
sudo tee /etc/nginx/conf.d/01-php-fpm.conf > /dev/null <<EOF
upstream fastcgi_backend {
    server unix:/run/php/php$PHP_VERSION-fpm.sock;
}
EOF
```

Disable the default site. It listens on port 80, which the HTTPS redirect, Varnish, or the application vhost will take over, depending on `SSL_MODE`. This removes only the link in `sites-enabled`; the package's file in `sites-available` stays in place.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: it is for the app server, and this server has INSTALL_APP=$INSTALL_APP."; exit 1; }
sudo rm -f /etc/nginx/sites-enabled/default
```

#### Application vhost

The application vhost listens on `127.0.0.1:8080` only, so no visitor reaches it directly. Requests arrive through Varnish, or, without Varnish, through the HTTPS vhost on port 443. The one exception is `SSL_MODE=off` without Varnish (`INSTALL_VARNISH=no`), where nothing else on this server listens on port 80, so the vhost listens there itself and the load balancer connects to it. The traffic paths are:

```text
SSL_MODE=letsencrypt or custom:  visitor -> Nginx :443 -> Varnish 127.0.0.1:6081 -> Nginx 127.0.0.1:8080 -> PHP-FPM
                                 visitor -> Nginx :80  -> redirect to HTTPS (and the Let's Encrypt challenge)
SSL_MODE=off:                    load balancer -> Varnish :80 -> Nginx 127.0.0.1:8080 -> PHP-FPM
```

Without Varnish, Nginx's port 443 (or, with `SSL_MODE=off`, port 80) connects to the application directly. Because Varnish is never reachable from the internet when this server handles HTTPS, a visitor cannot bypass HTTPS or send a forged `X-Forwarded-Proto` header to make plain HTTP look like HTTPS.

The vhost is the `default_server` for its address. Nginx picks the site that answers a request by its `Host` header, and requests that name no known site go to the default one. Varnish's health probe sends `Host: 127.0.0.1`, and an AWS load balancer's health check sends the server's IP address, so without this setting both would reach whichever site happens to come first, such as a vhost left over from an earlier domain name, and Varnish would mark the store as unhealthy. If another site already claims to be the default on the same address, `nginx -t` reports a duplicate default server, and that site's link in `/etc/nginx/sites-enabled/` must be removed first.

The vhost serves the web root with PHP and is deliberately generic; replace it with your application's own Nginx configuration when you deploy the application. For Magento, Part 6 switches it to the project's `nginx.conf`, or to Magento's `nginx.conf.sample` when the project has none.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: it is for the app server, and this server has INSTALL_APP=$INSTALL_APP."; exit 1; }
: "${DOMAIN_NAME:?Run the Variables blocks first}"
: "${PHP_VERSION:?Run the Variables blocks first}"
: "${SSL_MODE:?Run the Variables blocks first}"
VHOST_LISTEN="127.0.0.1:8080"
[ "$SSL_MODE" = off ] && [ "$INSTALL_VARNISH" = no ] && VHOST_LISTEN="80"
sudo tee "/etc/nginx/sites-available/$DOMAIN_NAME" > /dev/null <<EOF
server {
    listen $VHOST_LISTEN default_server;
    server_name $DOMAIN_NAME www.$DOMAIN_NAME;

    root /var/www/$DOMAIN_NAME;
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_param HTTPS \$fe_https;
        fastcgi_pass fastcgi_backend;
        fastcgi_read_timeout 600s;
        fastcgi_buffers 16 16k;
        fastcgi_buffer_size 32k;
    }

    # Block hidden files such as .git and .env
    location ~ /\.(?!well-known) {
        deny all;
    }

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
}
EOF
sudo ln -sf "/etc/nginx/sites-available/$DOMAIN_NAME" "/etc/nginx/sites-enabled/$DOMAIN_NAME"
sudo nginx -t && sudo systemctl reload nginx
```

### Valkey

Run this section on the app server when `INSTALL_VALKEY=yes`.

Ubuntu 26.04 ships Valkey 9, the version Magento 2.4.9 supports, so Valkey comes straight from Ubuntu with its security updates. This section runs two separate Valkey instances, because the cache and the sessions need opposite behaviour when memory runs out:

- **Cache** on port 6379: when it is full, Valkey deletes the least recently used keys (`allkeys-lru`) and nothing is saved to disk, because Magento can always rebuild its cache. Magento uses database 0 here for its cache, and database 1 for the full-page cache when Varnish is not installed.
- **Sessions** on port 6380: Valkey never deletes keys (`noeviction`) and saves its data to disk, so customers stay logged in and keep their carts across restarts.

In a single instance, the cache's eviction policy would also delete active sessions under memory pressure, logging customers out. Both instances use the package's `valkey-server@` service template with configuration files of their own, so the package's default instance is disabled and its `valkey.conf` is left untouched.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] && [ "$INSTALL_VALKEY" = yes ] || { echo "Skip this block: this server does not run Valkey."; exit 1; }
sudo apt install -y valkey-server
sudo systemctl disable --now valkey-server
valkey-server --version
```

The sessions instance saves its data to disk from a forked child process. Without memory overcommit, the kernel can refuse that fork when free memory is low, and the save fails, which is why Valkey warns about this setting at startup. This block enables overcommit in a file of its own under `/etc/sysctl.d/`, so it applies now and after every reboot, and it prints the value the kernel is using.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] && [ "$INSTALL_VALKEY" = yes ] || { echo "Skip this block: this server does not run Valkey."; exit 1; }
echo 'vm.overcommit_memory = 1' | sudo tee /etc/sysctl.d/99-valkey.conf
sudo sysctl -p /etc/sysctl.d/99-valkey.conf > /dev/null
sysctl vm.overcommit_memory
```

This block writes both configuration files with one generated password and the memory sizes from the sizing block, then starts both instances. Both listen on `127.0.0.1` only. The files belong to the `valkey` user with mode `640`, so no other unprivileged account can read the password. Running the block again sets a new password.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] && [ "$INSTALL_VALKEY" = yes ] || { echo "Skip this block: this server does not run Valkey."; exit 1; }
: "${VALKEY_CACHE_MB:?Run the Resource sizing block first}"
VALKEY_PASSWORD="$(openssl rand -hex 32)"
write_valkey_conf() {
  # Arguments: instance name, port, memory in MB, eviction policy, save rule
  sudo tee "/etc/valkey/valkey-$1.conf" > /dev/null <<EOF
bind 127.0.0.1 -::1
protected-mode yes
port $2
supervised systemd
daemonize no
pidfile /run/valkey-$1/valkey-server.pid
logfile /var/log/valkey/valkey-server-$1.log
dir /var/lib/valkey
dbfilename dump-$1.rdb
requirepass $VALKEY_PASSWORD
maxmemory ${3}mb
maxmemory-policy $4
save $5
appendonly no
EOF
  sudo chown valkey:valkey "/etc/valkey/valkey-$1.conf"
  sudo chmod 640 "/etc/valkey/valkey-$1.conf"
}
write_valkey_conf cache 6379 "$VALKEY_CACHE_MB" allkeys-lru '""'
write_valkey_conf session 6380 "$VALKEY_SESSION_MB" noeviction "300 10"
sudo systemctl enable valkey-server@cache valkey-server@session
sudo systemctl restart valkey-server@cache valkey-server@session
echo "Valkey password: $VALKEY_PASSWORD"
```

Verify both instances. The first command should fail with `NOAUTH Authentication required`. Each instance should then report its port, Valkey version 9, and its eviction policy.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] && [ "$INSTALL_VALKEY" = yes ] || { echo "Skip this block: this server does not run Valkey."; exit 1; }
VALKEY_PASSWORD="$(sudo awk '/^requirepass/{print $2}' /etc/valkey/valkey-cache.conf)"
valkey-cli -p 6379 ping
for PORT in 6379 6380; do
  valkey-cli -p "$PORT" --no-auth-warning -a "$VALKEY_PASSWORD" info server | grep -E '^(valkey_version|tcp_port)'
  valkey-cli -p "$PORT" --no-auth-warning -a "$VALKEY_PASSWORD" config get maxmemory-policy | tail -1
done
```

Both instances read only their own configuration files, so a Valkey package upgrade leaves the settings alone. A package upgrade may not restart instances started from the template, so restart both afterwards to make sure they run the new version: `sudo systemctl restart valkey-server@cache valkey-server@session`.

### Varnish

Run this section on the app server when `INSTALL_VARNISH=yes`.

Magento 2.4.9 lists Varnish 8, but Varnish's official repository has no Ubuntu 26.04 build of Varnish 8 yet, and Ubuntu 26.04 ships Varnish 7.7. This section therefore installs Ubuntu's 7.7, which is the version Magento 2.4.8 lists. Magento exports the same VCL for Varnish 7.x and 8, so nothing else changes, and **Moving to Varnish 8** below covers the upgrade once a 26.04 package exists.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] && [ "$INSTALL_VARNISH" = yes ] || { echo "Skip this block: this server does not run Varnish."; exit 1; }
sudo apt install -y varnish
varnishd -V
```

#### Varnish listening address

This block takes the package's own start command and changes only the listening address and the cache size, so every other packaged option stays intact. When this server handles HTTPS (`SSL_MODE` is `letsencrypt` or `custom`), Varnish listens on `127.0.0.1:6081`, where only the HTTPS vhost on port 443 can reach it, and Nginx's port 80 redirects visitors to HTTPS. With `SSL_MODE=off`, Varnish listens on port 80, where the load balancer connects to it. It also raises three limits, following Adobe's guidance: Magento sends long `X-Magento-Tags` headers on category pages, and with Varnish's defaults (8 KB of headers) these pages fail with "503 Backend fetch failed". The package's default VCL already forwards requests to Nginx on `127.0.0.1:8080`. Once Magento's VCL has been installed as `/etc/varnish/magento.vcl` (see the **Varnish** section of Part 6), this block points Varnish at that file instead, so running it again never switches Varnish back to the default VCL. The settings live in a systemd drop-in file, and the package's own `default.vcl` is never edited, so both survive package upgrades.

The block reads the start command from the package's unit file rather than from an earlier drop-in, so running it again never stacks options twice. When the unit file splits the command across several lines with trailing backslashes, the block joins them first, and it replaces the listening address in whatever form the package writes it (`:6081` or `localhost:6081`). If any of the three substitutions does not take effect, the block stops before changing anything and prints the package's start command. Otherwise it ends by showing the start command systemd now uses and whether Varnish is running.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] && [ "$INSTALL_VARNISH" = yes ] || { echo "Skip this block: this server does not run Varnish."; exit 1; }
: "${VARNISH_CACHE_MB:?Run the Resource sizing block first}"
: "${SSL_MODE:?Run the Variables blocks first}"
VARNISH_LISTEN="127.0.0.1:6081"
[ "$SSL_MODE" = off ] && VARNISH_LISTEN=":80"
VCL=/etc/varnish/default.vcl
[ -f /etc/varnish/magento.vcl ] && VCL=/etc/varnish/magento.vcl
UNIT_FILE=$(systemctl show -P FragmentPath varnish.service)
EXEC=$(awk '{ if (sub(/\\$/, "")) printf "%s ", $0; else print }' "$UNIT_FILE" | grep -m1 '^ExecStart=/' | tr -s ' \t' ' ')
NEW=$(echo "$EXEC" | sed -E "s/ -a [^ ]+/ -a $VARNISH_LISTEN/; s/ -s [^ ]+/ -s malloc,${VARNISH_CACHE_MB}m/; s# -f [^ ]+# -f $VCL#")
for OPT in "-a $VARNISH_LISTEN" "-s malloc,${VARNISH_CACHE_MB}m" "-f $VCL"; do
  case "$NEW " in
    *" $OPT "*) ;;
    *) echo "Could not set '$OPT'. The start command in $UNIT_FILE is:"; echo "$EXEC"; exit 1 ;;
  esac
done
NEW="$NEW -p http_resp_hdr_len=65536 -p http_resp_size=98304 -p workspace_backend=131072"
sudo mkdir -p /etc/systemd/system/varnish.service.d
printf "[Service]\nExecStart=\n%s\n" "$NEW" | sudo tee /etc/systemd/system/varnish.service.d/override.conf
sudo systemctl daemon-reload
sudo systemctl enable varnish
sudo systemctl restart varnish
systemctl show -P ExecStart varnish.service | grep -o 'argv\[\]=[^;]*'
echo "varnish: $(systemctl is-active varnish)"
```

Confirm that Varnish is answering on its address (`127.0.0.1:6081`, or port 80 with `SSL_MODE=off`). The response code may be 403 or 404 because the web root is still empty, which is fine; the important part is that the headers include `Via` with `varnish`.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] && [ "$INSTALL_VARNISH" = yes ] || { echo "Skip this block: this server does not run Varnish."; exit 1; }
: "${SSL_MODE:?Run the Variables blocks first}"
VARNISH_PORT=6081
[ "$SSL_MODE" = off ] && VARNISH_PORT=80
sleep 2
sudo ss -tlnp | grep -E ":($VARNISH_PORT|8080)\b"
curl -sI -H "Host: ${DOMAIN_NAME:-localhost}" "http://127.0.0.1:$VARNISH_PORT/" | grep -iE '^(HTTP|via|x-varnish)'
```

The packaged VCL is conservative and does not cache pages for visitors with cookies, so Varnish behaves almost like a pass-through proxy until you install your application's own VCL (for Magento, see Part 6). Never add an HTTP-to-HTTPS redirect behind Varnish, in the application vhost or in the VCL, because a cached redirect would also be served to HTTPS visitors and cause a redirect loop. The redirect belongs in front of Varnish: when this server handles HTTPS, Nginx's port 80 sends visitors to HTTPS before they reach Varnish (see the **HTTPS** section), and with `SSL_MODE=off`, configure the redirect on the load balancer (on an AWS Application Load Balancer, a port 80 listener with a redirect action).

#### Moving to Varnish 8

This command checks whether Varnish's official repository has added Ubuntu 26.04 (`resolute`). It prints `200` once it has, and `404` until then.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] && [ "$INSTALL_VARNISH" = yes ] || { echo "Skip this block: this server does not run Varnish."; exit 1; }
curl -s -o /dev/null -w '%{http_code}\n' https://packagecloud.io/varnishcache/varnish80/ubuntu/dists/resolute/Release
```

Once it prints `200`, this block adds the repository, pins Varnish to it so that Ubuntu's 7.7 is never chosen again, and upgrades. Afterwards, run the **Varnish listening address** block again, so the drop-in is rebuilt from the new package's start command. It keeps using Magento's VCL if that is installed.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] && [ "$INSTALL_VARNISH" = yes ] || { echo "Skip this block: this server does not run Varnish."; exit 1; }
curl -s https://packagecloud.io/install/repositories/varnishcache/varnish80/script.deb.sh | sudo bash
sudo tee /etc/apt/preferences.d/varnish-pin > /dev/null <<'EOF'
Package: varnish varnish-*
Pin: release o=packagecloud.io/varnishcache/varnish80
Pin-Priority: 1000
EOF
sudo apt update
apt-cache policy varnish
sudo apt install -y varnish
varnishd -V
```

### Composer

Run this section on the app server only (`INSTALL_APP=yes`). It uses Composer's official installer, which verifies the download's signature before installing. `--2` installs the latest stable 2.x release, which is 2.10 or later, as Magento 2.4.9 requires. (Ubuntu 26.04's own `composer` package is 2.9, which is too old.)

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: it is for the app server, and this server has INSTALL_APP=$INSTALL_APP."; exit 1; }
cd /tmp
EXPECTED="$(curl -fsSL https://composer.github.io/installer.sig)"
curl -fsSL https://getcomposer.org/installer -o composer-setup.php
ACTUAL="$(sha384sum composer-setup.php | cut -d' ' -f1)"
if [ "$EXPECTED" = "$ACTUAL" ]; then
  sudo php composer-setup.php --2 --quiet --install-dir=/usr/local/bin --filename=composer
  composer --version
else
  echo "Installer checksum mismatch. Composer was NOT installed."
fi
rm -f composer-setup.php
```

To pin an exact version instead, replace `--2` with `--version=2.10.3` (or the version you need).

Composer is installed system-wide, but you should always run it in the web root as the restricted user, so that the files it writes keep the permission model described in the **Restricted user and web root** section.

### phpMyAdmin

Run this section on the app server when `INSTALL_PHPMYADMIN=yes`. It manages the local MariaDB or, when the database runs on its own server, the MariaDB at `DB_SERVER_IP`.

phpMyAdmin is installed on `127.0.0.1:8090`, which is not reachable from the internet. You access it through an SSH tunnel, so the database login never travels over the network unencrypted, and HTTP Basic Auth adds a second password in front of it.

Change the version below to the latest release from [phpmyadmin.net](https://www.phpmyadmin.net/downloads/). phpMyAdmin 5.2.3 is officially tested only up to PHP 8.3, but it is the same version Ubuntu 26.04 packages for its PHP 8.5, and it works there, though it may log deprecation notices. Move to a newer release once one supports PHP 8.5 officially.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] && [ "$INSTALL_PHPMYADMIN" = yes ] || { echo "Skip this block: this server does not run phpMyAdmin."; exit 1; }
export PMA_VERSION="5.2.3"
```

The download is verified against phpMyAdmin's published SHA-256 checksum before anything is installed. To upgrade phpMyAdmin later, change the version above and run this block again. It keeps the existing `config.inc.php`, so the configuration and login secret survive the upgrade.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] && [ "$INSTALL_PHPMYADMIN" = yes ] || { echo "Skip this block: this server does not run phpMyAdmin."; exit 1; }
: "${PMA_VERSION:?Run the previous block first}"
cd /tmp
F="phpMyAdmin-$PMA_VERSION-english"
curl -fsSLO "https://files.phpmyadmin.net/phpMyAdmin/$PMA_VERSION/$F.tar.gz"
curl -fsSLO "https://files.phpmyadmin.net/phpMyAdmin/$PMA_VERSION/$F.tar.gz.sha256"
if sha256sum -c "$F.tar.gz.sha256"; then
  tar -xzf "$F.tar.gz"
  if [ -f /usr/share/phpmyadmin/config.inc.php ]; then
    sudo cp -p /usr/share/phpmyadmin/config.inc.php "$F/config.inc.php"
  fi
  sudo rm -rf /usr/share/phpmyadmin
  sudo mv "$F" /usr/share/phpmyadmin
  sudo chown -R root:root /usr/share/phpmyadmin
  if [ -f /usr/share/phpmyadmin/config.inc.php ]; then
    sudo chown root:www-data /usr/share/phpmyadmin/config.inc.php
  fi
  sudo install -d -m 700 -o www-data -g www-data /usr/share/phpmyadmin/tmp
else
  echo "Checksum mismatch. phpMyAdmin was NOT installed."
fi
rm -f "$F.tar.gz" "$F.tar.gz.sha256"
```

Write the configuration with a generated encryption secret. It connects to the local MariaDB, or to `DB_SERVER_IP` when the database runs on its own server.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] && [ "$INSTALL_PHPMYADMIN" = yes ] || { echo "Skip this block: this server does not run phpMyAdmin."; exit 1; }
: "${INSTALL_MARIADB:?Run the Variables blocks first}"
PMA_DB_HOST="localhost"
[ "$INSTALL_MARIADB" = no ] && PMA_DB_HOST="$DB_SERVER_IP"
SECRET="$(openssl rand -hex 32)"
sudo tee /usr/share/phpmyadmin/config.inc.php > /dev/null <<EOF
<?php
\$cfg['blowfish_secret'] = sodium_hex2bin('$SECRET');

\$i = 0;
\$i++;
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
\$cfg['Servers'][\$i]['host'] = '$PMA_DB_HOST';
\$cfg['Servers'][\$i]['compress'] = false;
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;

\$cfg['TempDir'] = '/usr/share/phpmyadmin/tmp';
\$cfg['UploadDir'] = '';
\$cfg['SaveDir'] = '';
EOF
sudo chown root:www-data /usr/share/phpmyadmin/config.inc.php
sudo chmod 640 /usr/share/phpmyadmin/config.inc.php
```

Create the HTTP Basic Auth user with a generated password:

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] && [ "$INSTALL_PHPMYADMIN" = yes ] || { echo "Skip this block: this server does not run phpMyAdmin."; exit 1; }
PMA_AUTH_PASSWORD="$(openssl rand -hex 16)"
sudo mkdir -p /etc/nginx/htpasswds
echo "$PMA_AUTH_PASSWORD" | sudo htpasswd -ciB /etc/nginx/htpasswds/.phpmyadmin dbadmin
sudo chown root:www-data /etc/nginx/htpasswds/.phpmyadmin
sudo chmod 640 /etc/nginx/htpasswds/.phpmyadmin
echo "phpMyAdmin Basic Auth user: dbadmin"
echo "phpMyAdmin Basic Auth password: $PMA_AUTH_PASSWORD"
```

Create the Nginx site for phpMyAdmin:

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] && [ "$INSTALL_PHPMYADMIN" = yes ] || { echo "Skip this block: this server does not run phpMyAdmin."; exit 1; }
: "${PHP_VERSION:?Run the Variables blocks first}"
sudo tee /etc/nginx/sites-available/phpmyadmin > /dev/null <<EOF
server {
    listen 127.0.0.1:8090;
    server_name _;

    root /usr/share/phpmyadmin;
    index index.php;

    auth_basic "Restricted";
    auth_basic_user_file /etc/nginx/htpasswds/.phpmyadmin;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass fastcgi_backend;
    }

    location ~ ^/(setup|libraries|sql)/ {
        deny all;
    }

    location ~ /\. {
        deny all;
    }

    add_header X-Frame-Options "DENY" always;
    add_header X-Content-Type-Options "nosniff" always;
}
EOF
sudo ln -sf /etc/nginx/sites-available/phpmyadmin /etc/nginx/sites-enabled/phpmyadmin
sudo nginx -t && sudo systemctl reload nginx
```

To open phpMyAdmin, run this on your own computer, keep the terminal open, and browse to `http://localhost:8090`. It logs in as the restricted user with your own SSH key, so nobody needs the `ubuntu` account's key, which has full sudo access. The tunnel only needs an account that can log in over SSH, and it gives no more access than an ordinary login as that user. To let another developer open the tunnel, add their public key to the restricted user's `authorized_keys`, as the **Restricted user and web root** section does for yours. Replace `webuser` with the value of `WEB_USER` if you changed it.

```text
ssh -i ~/.ssh/id_ed25519 -N -L 8090:127.0.0.1:8090 webuser@SERVER_IP
```

The command is the same on macOS, Linux, and Windows 10 or 11, which include the OpenSSH client. Only the key path differs: in Windows PowerShell, write it as `$HOME\.ssh\id_ed25519`, and in Command Prompt as `%USERPROFILE%\.ssh\id_ed25519`. In VS Code, you can open the same tunnel without a terminal: connect to the server as the restricted user with Remote - SSH, then add port `8090` in the **Ports** panel.

Log in with the application database user created in the MariaDB section. The MariaDB root account uses Unix socket authentication and cannot log in through phpMyAdmin, which is intentional. When the database runs on its own server, the login works because the MariaDB section created the user for this app server's address.

### HTTPS

Run this section on the app server when `SSL_MODE` is `letsencrypt` or `custom`. Nginx answers on port 80 only to redirect visitors to HTTPS, terminates HTTPS on port 443, and passes requests to Varnish on `127.0.0.1:6081` (or to the application vhost on `127.0.0.1:8080` when Varnish is not installed). First set up the port 80 redirect, then get the certificate with option A or B, and finally set up the HTTPS vhost.

The site serves both `$DOMAIN_NAME` and `www.$DOMAIN_NAME`, so the certificate must cover both names, and DNS for both must point to this server.

Skip this whole section when `SSL_MODE=off`. The load balancer then handles HTTPS and must forward the `X-Forwarded-Proto` header, so that the application knows the visitor used HTTPS. An AWS Application Load Balancer does this automatically.

#### HTTP to HTTPS redirect

Nginx's port 80 sends every visitor to the same address over HTTPS with a permanent (301) redirect. The only exception is the Let's Encrypt HTTP challenge, which must be answered over plain HTTP, so it is served from `/var/www/letsencrypt`. Because the redirect happens here, before Varnish, it is never cached, and the `X-Forwarded-Proto` header that tells the application a request used HTTPS can only come from the HTTPS vhost.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] && [ "$SSL_MODE" != off ] || { echo "Skip this block: it is for an app server that handles HTTPS, and this server has INSTALL_APP=$INSTALL_APP, SSL_MODE=$SSL_MODE."; exit 1; }
: "${DOMAIN_NAME:?Run the Variables blocks first}"
sudo mkdir -p /var/www/letsencrypt
sudo tee "/etc/nginx/sites-available/$DOMAIN_NAME-http" > /dev/null <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN_NAME www.$DOMAIN_NAME;

    # Let's Encrypt HTTP challenge
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
sudo ln -sf "/etc/nginx/sites-available/$DOMAIN_NAME-http" "/etc/nginx/sites-enabled/$DOMAIN_NAME-http"
sudo nginx -t && sudo systemctl reload nginx
curl -sI -H "Host: $DOMAIN_NAME" http://127.0.0.1/ | grep -iE '^(HTTP|location)'
```

The last line must show a `301` status and a `Location` header that starts with `https://`.

#### Option A: Let's Encrypt certificate (`SSL_MODE=letsencrypt`)

Run this only after DNS for both the domain and its `www` name points to this server, and port 80 is open in the security group.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] && [ "$SSL_MODE" = letsencrypt ] || { echo "Skip this block: it is for SSL_MODE=letsencrypt, and this server has SSL_MODE=$SSL_MODE."; exit 1; }
: "${DOMAIN_NAME:?Run the Variables blocks first}"
printf "%-40s %s\n" "This server" "$(curl -s https://checkip.amazonaws.com)"
for NAME in "$DOMAIN_NAME" "www.$DOMAIN_NAME"; do
  printf "%-40s %s\n" "$NAME" "$(dig +short "$NAME" | tail -1)"
done
```

All three addresses above must match. If they do, request the certificate. It covers both names, and `--expand` lets the same command add `www` to a certificate that an earlier run issued for the bare domain only.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] && [ "$SSL_MODE" = letsencrypt ] || { echo "Skip this block: it is for SSL_MODE=letsencrypt, and this server has SSL_MODE=$SSL_MODE."; exit 1; }
: "${DOMAIN_NAME:?Run the Variables blocks first}"
sudo apt install -y certbot
sudo certbot certonly --webroot -w /var/www/letsencrypt \
  --cert-name "$DOMAIN_NAME" -d "$DOMAIN_NAME" -d "www.$DOMAIN_NAME" --expand \
  --email "$ADMIN_EMAIL" --agree-tos --no-eff-email --non-interactive \
  --deploy-hook "systemctl reload nginx"
sudo openssl x509 -noout -ext subjectAltName -in "/etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem"
```

The last line lists the names the certificate covers, and it must show both.

Certificates renew automatically through the `certbot.timer` service. After the HTTPS vhost below is in place, this command tests renewal without changing anything:

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] && [ "$SSL_MODE" = letsencrypt ] || { echo "Skip this block: it is for SSL_MODE=letsencrypt, and this server has SSL_MODE=$SSL_MODE."; exit 1; }
sudo certbot renew --dry-run
```

#### Option B: your own certificate (`SSL_MODE=custom`)

Copy the certificate and its private key to the server first. The certificate file must contain the full chain (your certificate followed by any intermediate certificates); a Cloudflare Origin Certificate is a single certificate and needs no chain. Then set the two paths when Runme asks:

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] && [ "$SSL_MODE" = custom ] || { echo "Skip this block: it is for SSL_MODE=custom, and this server has SSL_MODE=$SSL_MODE."; exit 1; }
export SSL_CERT_PATH="/etc/ssl/certs/example.com.pem"
export SSL_KEY_PATH="/etc/ssl/private/example.com.key"
```

This block locks down the private key, so that only root can read it, and checks that the key belongs to the certificate. The two fingerprints it prints must be identical.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] && [ "$SSL_MODE" = custom ] || { echo "Skip this block: it is for SSL_MODE=custom, and this server has SSL_MODE=$SSL_MODE."; exit 1; }
: "${SSL_CERT_PATH:?Run the previous block first}"
sudo chown root:root "$SSL_CERT_PATH" "$SSL_KEY_PATH"
sudo chmod 644 "$SSL_CERT_PATH"
sudo chmod 600 "$SSL_KEY_PATH"
echo "Certificate: $(sudo openssl x509 -noout -pubkey -in "$SSL_CERT_PATH" | sha256sum)"
echo "Private key: $(sudo openssl pkey -pubout -in "$SSL_KEY_PATH" | sha256sum)"
sudo openssl x509 -noout -subject -enddate -in "$SSL_CERT_PATH"
sudo openssl x509 -noout -ext subjectAltName -in "$SSL_CERT_PATH"
```

The last line lists the names the certificate covers. It must include both `$DOMAIN_NAME` and `www.$DOMAIN_NAME` (a wildcard such as `*.example.com` covers `www`, but not the bare domain). The line before it shows the certificate's expiry date. A custom certificate does not renew itself, so note the date and replace the files (then run `sudo systemctl reload nginx`) before it expires.

#### HTTPS vhost

This block uses the Let's Encrypt certificate with option A, or the paths from option B. It passes requests to Varnish on `127.0.0.1:6081`, or straight to the application vhost on `127.0.0.1:8080` when Varnish is not installed.

It also adds a default HTTPS server, which answers any connection that asks for a name other than `$DOMAIN_NAME` or `www.$DOMAIN_NAME`, such as scanners that connect by IP address. That server needs no certificate, because `ssl_reject_handshake` refuses the connection before any certificate is sent, so the store is never shown under a name it does not own and the certificate does not reveal the domain to whoever probes the IP address.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] && [ "$SSL_MODE" != off ] || { echo "Skip this block: it is for an app server that handles HTTPS, and this server has INSTALL_APP=$INSTALL_APP, SSL_MODE=$SSL_MODE."; exit 1; }
: "${DOMAIN_NAME:?Run the Variables blocks first}"
HTTPS_BACKEND="127.0.0.1:6081"
[ "$INSTALL_VARNISH" = no ] && HTTPS_BACKEND="127.0.0.1:8080"
if [ "$SSL_MODE" = letsencrypt ]; then
  SSL_CERT_PATH="/etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem"
  SSL_KEY_PATH="/etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem"
fi
: "${SSL_CERT_PATH:?Set SSL_MODE to letsencrypt, or run the option B blocks first}"
sudo tee "/etc/nginx/sites-available/$DOMAIN_NAME-ssl" > /dev/null <<EOF
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name $DOMAIN_NAME www.$DOMAIN_NAME;

    ssl_certificate     $SSL_CERT_PATH;
    ssl_certificate_key $SSL_KEY_PATH;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    add_header Strict-Transport-Security "max-age=31536000" always;

    location / {
        proxy_pass http://$HTTPS_BACKEND;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Port 443;
        proxy_read_timeout 600s;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
    }
}
EOF
sudo tee /etc/nginx/sites-available/default-ssl-reject > /dev/null <<'EOF'
# Refuses HTTPS connections for any name that no other server block serves
server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    ssl_reject_handshake on;
}
EOF
sudo ln -sf "/etc/nginx/sites-available/$DOMAIN_NAME-ssl" "/etc/nginx/sites-enabled/$DOMAIN_NAME-ssl"
sudo ln -sf /etc/nginx/sites-available/default-ssl-reject /etc/nginx/sites-enabled/default-ssl-reject
sudo nginx -t && sudo systemctl reload nginx
sleep 1
for NAME in "$DOMAIN_NAME" "www.$DOMAIN_NAME"; do
  if CODE=$(curl -s -o /dev/null -w '%{http_code}' --resolve "$NAME:443:127.0.0.1" "https://$NAME/"); then
    printf "%-40s HTTP %s\n" "$NAME" "$CODE"
  else
    printf "%-40s FAILED\n" "$NAME"
  fi
done
if curl -sk -o /dev/null --resolve "unknown.invalid:443:127.0.0.1" https://unknown.invalid/; then
  echo "WARNING: an unknown name was answered. Check: ls -l /etc/nginx/sites-enabled"
else
  echo "Unknown names are refused"
fi
```

Each name must show an HTTP status code, not `FAILED`. A failure means the certificate does not cover that name or its chain is incomplete, because `curl` checks the certificate exactly as a browser would. Any status code, including 403 or 404 while the web root is still empty, shows that HTTPS works. A Cloudflare Origin Certificate is the exception: only Cloudflare trusts it, so both names show `FAILED` even when the certificate is correct, and the option B fingerprints and names are the check that matters. The last line must read `Unknown names are refused`.

If you use Cloudflare in front of the server, set Cloudflare's SSL mode to **Full (strict)**, and use either option A or a Cloudflare Origin Certificate with option B. Avoid Cloudflare's **Flexible** mode with `SSL_MODE=off`: in that mode, traffic between Cloudflare and this server crosses the internet unencrypted.

## Part 5: Every server, to finish

Run this part on every server once the earlier parts that apply to it are done. It locks the server down and then checks that each of its services is running.

### Security hardening

#### Firewall (UFW)

This block runs on every server and opens only what the server's services need. SSH is allowed before the firewall is enabled, so the current session is not cut off. The app server opens HTTP and HTTPS to everyone, except with `SSL_MODE=off`: it then keeps 443 closed and, when `TRUSTED_PROXY_CIDRS` is set, accepts port 80 from those ranges only. A database or OpenSearch server opens its port only to the addresses in `APP_SERVER_IPS`.

```bash
: "${INSTALL_APP:?Run the Variables blocks first}"
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
if [ "$INSTALL_APP" = yes ]; then
  if [ "$SSL_MODE" = off ] && [ -n "$TRUSTED_PROXY_CIDRS" ]; then
    for CIDR in $TRUSTED_PROXY_CIDRS; do
      sudo ufw allow from "$CIDR" to any port 80 proto tcp comment "HTTP from load balancer"
    done
  else
    sudo ufw allow 80/tcp
  fi
  if [ "$SSL_MODE" != off ]; then sudo ufw allow 443/tcp; fi
fi
for IP in $APP_SERVER_IPS; do
  if [ "$INSTALL_MARIADB" = yes ]; then sudo ufw allow from "$IP" to any port 3306 proto tcp comment "MariaDB from app server"; fi
  if [ "$INSTALL_OPENSEARCH" = yes ]; then sudo ufw allow from "$IP" to any port 9200 proto tcp comment "OpenSearch from app server"; fi
done
sudo ufw --force enable
sudo ufw status verbose
```

Never open 6081 (Varnish behind the HTTPS vhost), 8080 (Nginx behind Varnish), 8090 (phpMyAdmin), or 6379 and 6380 (Valkey), which listen on `127.0.0.1` only. Never open 3306 (MariaDB) or 9200 (OpenSearch) to anything other than the app servers.

#### SSH hardening

This block disables password logins and root logins, so every account must use an SSH key. Keep your current SSH session open while you run it, and test a new login from a second terminal before you close the first one.

```bash
sudo tee /etc/ssh/sshd_config.d/40-hardening.conf > /dev/null <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 30
EOF
sudo chmod 644 /etc/ssh/sshd_config.d/40-hardening.conf
sudo sshd -T | grep -iE '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|x11forwarding|maxauthtries)'
```

Check the output above. It must show `permitrootlogin no` and `passwordauthentication no`. If it shows anything else, another file in `/etc/ssh/sshd_config.d/` is overriding these settings; fix that before continuing. When the output is correct, apply the change:

```bash
sudo systemctl restart ssh
```

#### Fail2ban

Fail2ban temporarily blocks IP addresses that repeatedly fail to log in over SSH.

```bash
sudo apt install -y fail2ban python3-systemd
sudo tee /etc/fail2ban/jail.local > /dev/null <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled = true
EOF
sudo systemctl enable fail2ban
sudo systemctl restart fail2ban
# Fail2ban takes a few seconds to open its control socket after a restart
for i in $(seq 1 30); do sudo fail2ban-client ping > /dev/null 2>&1 && break; sleep 1; done
if sudo fail2ban-client ping > /dev/null 2>&1; then
  sudo fail2ban-client status sshd
else
  echo "ERROR: fail2ban did not start. Its recent log follows."
  sudo journalctl -u fail2ban -n 30 --no-pager
  false
fi
```

#### Automatic security updates

This enables Ubuntu's unattended security updates on every server. By default, they cover Ubuntu's own packages only. PHP, Nginx, Valkey, and Varnish come from Ubuntu and therefore receive security fixes automatically, while MariaDB and OpenSearch come from their vendors' repositories and are never upgraded behind your back.

```bash
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -f noninteractive unattended-upgrades
systemctl is-enabled unattended-upgrades
```

### Final verification

Every service on this server should report `active`:

```bash
: "${INSTALL_APP:?Run the Variables blocks first}"
SERVICES="fail2ban"
[ "$INSTALL_APP" = yes ]        && SERVICES="$SERVICES nginx php$PHP_VERSION-fpm"
[ "$INSTALL_MARIADB" = yes ]    && SERVICES="$SERVICES mariadb"
[ "$INSTALL_OPENSEARCH" = yes ] && SERVICES="$SERVICES opensearch"
[ "$INSTALL_VALKEY" = yes ]     && SERVICES="$SERVICES valkey-server@cache valkey-server@session"
[ "$INSTALL_VARNISH" = yes ]    && SERVICES="$SERVICES varnish"
for S in $SERVICES; do
  printf "%-24s %s\n" "$S" "$(systemctl is-active "$S")"
done
```

On an app server whose database or OpenSearch runs elsewhere, check that those servers are reachable. Each line should report `reachable`. If one does not, check the other server's security group, its firewall rules, and its `APP_SERVER_IPS` value.

```bash
: "${INSTALL_APP:?Run the Variables blocks first}"
if [ "$INSTALL_MARIADB" = no ] && [ -n "$DB_SERVER_IP" ]; then
  if timeout 5 bash -c "</dev/tcp/$DB_SERVER_IP/3306" 2>/dev/null; then
    echo "MariaDB at $DB_SERVER_IP:3306 is reachable"
  else
    echo "MariaDB at $DB_SERVER_IP:3306 is NOT reachable"
  fi
fi
if [ "$INSTALL_OPENSEARCH" = no ] && [ -n "$OPENSEARCH_SERVER_IP" ]; then
  if curl -s --max-time 5 "http://$OPENSEARCH_SERVER_IP:9200" > /dev/null; then
    echo "OpenSearch at $OPENSEARCH_SERVER_IP:9200 is reachable"
  else
    echo "OpenSearch at $OPENSEARCH_SERVER_IP:9200 is NOT reachable"
  fi
fi
```

Check the listening ports. On the app server, only 22, 80, and 443 (443 only when `SSL_MODE` is not `off`) should be bound to `0.0.0.0` or `[::]`, and everything else must show `127.0.0.1`. On a database or OpenSearch server, only 22 should be bound to `0.0.0.0` or `[::]`, and 3306 or 9200 should show `127.0.0.1` and the server's private IP address.

```bash
sudo ss -tlnp | awk 'NR==1 || /LISTEN/' | awk '{print $4, $6}' | column -t
```

On the app server, check the file permission model. The three umask lines must each print `0002`, and every count must be `0`. If a count is not `0`, the **Reset file permissions** part lists the affected files and repairs them.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: it is for the app server, and this server has INSTALL_APP=$INSTALL_APP."; exit 1; }
: "${DOMAIN_NAME:?Run the Variables blocks first}"
R="/var/www/$DOMAIN_NAME"
echo "Restricted user login umask:   $(sudo su - "$WEB_USER" -c umask)"
echo "Restricted user sudo -u umask: $(sudo -u "$WEB_USER" sh -c umask)"
echo "PHP-FPM worker umask:          $(awk '/^Umask/{print $2}' "/proc/$(pgrep -f 'php-fpm: pool' | head -1)/status")"
echo "Wrong owner or group:          $(sudo find -H "$R" \( \( ! -user "$WEB_USER" ! -user www-data \) -o ! -group www-data \) -printf . | wc -c)"
echo "Folders that are not 2775:     $(sudo find -H "$R" -type d ! -perm 2775 -printf . | wc -c)"
echo "Files that are not 664:        $(sudo find -H "$R" -type f ! -name '*.sh' ! -path '*/bin/*' ! -perm 664 -printf . | wc -c)"
echo "Executables that are not 775:  $(sudo find -H "$R" -type f \( -name '*.sh' -o -path '*/bin/*' \) ! -perm 775 -printf . | wc -c)"
```

## Part 6: Deploy Magento (app server)

Run this part on the app server once Parts 1 to 5 are complete on every server. It deploys an existing Magento 2.4.9 store from three sources: the store's Git repository, a database dump, and an archive of its `pub/media` folder. Run the sections in order, because each one depends on the one before it:

```text
1. Before you start          upload the database dump and media archive, add the deploy key
2. Deployment settings       repository, branch, database login, file names, admin path
3. Code                      git clone (or update), then composer install
4. Data                      import the database, then the media files
5. Configuration             Magento's Nginx rules, app/etc/env.php, URLs, search, caches
6. Build                     maintenance mode, setup:upgrade, production mode, compile, static files
7. Varnish                   Magento's VCL
8. Indexers                  reinstall every trigger, reset, and reindex
9. Cron                      Magento's cron jobs
10. File permissions         repair anything the deployment left outside the model
11. Go live                  restart PHP-FPM, flush caches, leave maintenance mode, check the site
```

Every command in the web root runs as the restricted user, with `sudo -u`, so the files it creates follow the permission model from the start. The store stays in maintenance mode from the **Build** section until **Go live**.

### Before you start

The code comes from Git with the deploy key that the **Restricted user and web root** section generated. Make sure that key is added to the repository as a read-only deploy key, otherwise the clone fails with `Permission denied (publickey)`. This command prints the key again:

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: it is for the app server, and this server has INSTALL_APP=$INSTALL_APP."; exit 1; }
: "${WEB_USER:?Run the Variables blocks first}"
sudo cat "/home/$WEB_USER/.ssh/id_ed25519.pub"
```

The repository must hold the Magento project itself, with `composer.json`, `composer.lock`, `app/etc/config.php`, and the `auth.json` that holds the Magento Marketplace keys at its root. It must not hold `app/etc/env.php`, `vendor/`, `generated/`, `pub/static/`, or `pub/media/`, which this part creates or imports.

On Magento 2.4.9, the project must also patch `pub/health_check.php` with Magento's fix AC-17400 (commit `586726b` in the `magento/magento2` repository), applied to the `magento/magento2-base` package as a Composer patch. Without it, Varnish answers every request with "503 Backend fetch failed". When the igbinary PHP extension is installed, as it is on this server, `setup:install` writes an igbinary serializer setting into the `page_cache` entry of `env.php` even though that entry has no cache backend. The health check in 2.4.9 rejects that entry with "Cache configuration is invalid" and returns 500, and Magento's VCL then marks the store as unhealthy. The fix makes the health check skip any cache entry that has no backend of its own. It is in Magento's development branch but not in 2.4.9, so remove the patch once the store runs a release that includes it. The **Varnish** block in the **Configuration** section stops before it installs Magento's VCL when the health check fails, so a missing patch shows up there rather than as an outage.

Create the database dump and the media archive on the server the store currently runs on. The dump keeps triggers and is taken in one transaction, so the store can stay online while it runs. The archive leaves out everything Magento recreates or never needs again: the resized product images in `catalog/product/cache`, which are often larger than everything else together, CAPTCHA images, temporary uploads, import files, the admin image browser's `.thumbs` thumbnails, and the Adobe Commerce Analytics export. It also leaves out `.sql` files anywhere, and `.gz` and `.tgz` files lying directly in `media/`, which are usually old dumps and backups. The `.gz` and `.tgz` rule comes after `--no-wildcards-match-slash`, so it applies to the top level only and never drops a compressed file sold as a downloadable product from `media/downloadable/`. Any dump or backup found in `pub/media` on the old server should be moved out or deleted, because anyone who guesses its URL can download it. Replace the placeholders with that server's values:

```text
mysqldump --single-transaction --quick --triggers --no-tablespaces -h DB_HOST -u DB_USER -p DB_NAME | gzip > database.sql.gz
tar --exclude="media/captcha" --exclude="media/import" --exclude="media/tmp" \
    --exclude="media/catalog/tmp" --exclude="media/catalog/product/cache" \
    --exclude="media/downloadable/tmp" --exclude="media/analytics" --exclude=".thumbs" \
    --exclude="*.sql" \
    --no-wildcards-match-slash --exclude="media/*.gz" --exclude="media/*.tgz" \
    -czf media.tar.gz -C /path/to/magento/pub media/
```

Then copy both files from your computer to the app server's `ubuntu` home folder:

```text
scp -i ~/.ssh/YOUR_KEY.pem database.sql.gz media.tar.gz ubuntu@APP_SERVER_IP_OR_DNS:/home/ubuntu/
```

Two more values come from the current store. The encryption key is `crypt` > `key` in its `app/etc/env.php`. Magento encrypts payment credentials, API keys, and other secrets in the database with it, so without the same key those settings can no longer be read and must be entered again. If the old store rotated its key, the value holds several keys on separate lines, and in that case copy the old `env.php` file's `crypt` section into the new one after the **Configuration** section instead. The admin path is `backend` > `frontName` in the same file.

### Deployment settings

Run this block on the app server. Enter the same `DB_NAME` and `DB_USER` as in the **Application database and user** section, and the password that section printed. `DB_DUMP_FILE` and `MEDIA_ARCHIVE_FILE` are the full paths of the uploaded files: the dump may be `.sql` or `.sql.gz`, and the archive `.tar.gz`, `.tgz`, or `.tar`. Leave `MEDIA_ARCHIVE_FILE` empty for a store that has no media files yet, and leave both empty when you deploy a later release (see **Deploying later releases**).

`GIT_REPO_URL` takes an SSH address such as `git@github.com:your-org/your-store.git`, which uses the deploy key. An `https://` address also works for a public repository. `BACKEND_FRONTNAME` is the path of the admin panel, such as `office_7k2p`, so the admin is at `https://DOMAIN_NAME/office_7k2p`. A path that is hard to guess keeps automated login attacks away from the admin panel, so the block warns when it is `admin`. `CRYPT_KEY` is the encryption key described above; when it is empty, Magento generates a new one. `REPLACE_EXISTING_DB` must be `yes` only when you mean to replace a database that already holds tables, because the import then deletes everything in it.

The block checks every value and that both files exist, and it works out where MariaDB and OpenSearch run from the **App server settings** block.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: it is for the app server, and this server has INSTALL_APP=$INSTALL_APP."; exit 1; }
: "${DOMAIN_NAME:?Run the Variables blocks first}"
export GIT_REPO_URL="git@github.com:your-org/your-store.git"
export GIT_BRANCH="main"

export DB_NAME="appdb"
export DB_USER="appuser"
export DB_PASSWORD=""

export DB_DUMP_FILE="/home/ubuntu/database.sql.gz"
export MEDIA_ARCHIVE_FILE="/home/ubuntu/media.tar.gz"

export BACKEND_FRONTNAME=""
export CRYPT_KEY=""
export REPLACE_EXISTING_DB="no"

OK=yes
fail() { echo "ERROR: $1"; OK=no; }
case "$GIT_REPO_URL" in
  git@github.com:your-org/*) fail "GIT_REPO_URL is required. Enter your store's repository, not the example." ;;
  git@*:*|ssh://*|https://*) ;;
  *) fail "GIT_REPO_URL must look like git@github.com:org/repo.git, ssh://..., or https://..., not '$GIT_REPO_URL'." ;;
esac
git check-ref-format --branch "$GIT_BRANCH" > /dev/null 2>&1 || fail "GIT_BRANCH '$GIT_BRANCH' is not a valid branch name."
for PAIR in "DB_NAME=$DB_NAME" "DB_USER=$DB_USER"; do
  [[ "${PAIR#*=}" =~ ^[A-Za-z0-9_]{1,64}$ ]] || fail "${PAIR%%=*} '${PAIR#*=}' may contain only letters, digits, and _."
done
if [ -z "$DB_PASSWORD" ]; then
  fail "DB_PASSWORD is required. Enter the password that the MariaDB section printed for $DB_USER."
elif [[ "$DB_PASSWORD" =~ [[:space:]\"\\] ]]; then
  fail "DB_PASSWORD must not contain spaces, double quotes, or backslashes. Rotate it with the MariaDB section's block."
fi
case "$DB_DUMP_FILE" in
  "") echo "DB_DUMP_FILE is empty, so no database will be imported." ;;
  *.sql|*.sql.gz) sudo test -f "$DB_DUMP_FILE" || fail "DB_DUMP_FILE $DB_DUMP_FILE does not exist. Upload it first." ;;
  *) fail "DB_DUMP_FILE must end in .sql or .sql.gz, not '$DB_DUMP_FILE'." ;;
esac
case "$MEDIA_ARCHIVE_FILE" in
  "") echo "MEDIA_ARCHIVE_FILE is empty, so no media files will be imported." ;;
  *.tar.gz|*.tgz|*.tar) sudo test -f "$MEDIA_ARCHIVE_FILE" || fail "MEDIA_ARCHIVE_FILE $MEDIA_ARCHIVE_FILE does not exist. Upload it first." ;;
  *) fail "MEDIA_ARCHIVE_FILE must end in .tar.gz, .tgz, or .tar, not '$MEDIA_ARCHIVE_FILE'." ;;
esac
if ! [[ "$BACKEND_FRONTNAME" =~ ^[A-Za-z0-9_]+$ ]]; then
  fail "BACKEND_FRONTNAME is required and may contain only letters, digits, and _."
elif [ "$BACKEND_FRONTNAME" = admin ]; then
  echo "WARNING: BACKEND_FRONTNAME is 'admin', the first path that automated attacks try."
fi
[ -z "$CRYPT_KEY" ] || [[ "$CRYPT_KEY" =~ ^[^[:space:]]+$ ]] || fail "CRYPT_KEY must be a single key without spaces."
case "$REPLACE_EXISTING_DB" in
  yes|no) ;;
  *) fail "REPLACE_EXISTING_DB must be yes or no, not '$REPLACE_EXISTING_DB'." ;;
esac

DB_HOST="localhost"
[ "$INSTALL_MARIADB" = no ] && DB_HOST="$DB_SERVER_IP"
OPENSEARCH_HOST="127.0.0.1"
[ "$INSTALL_OPENSEARCH" = no ] && OPENSEARCH_HOST="$OPENSEARCH_SERVER_IP"
[ -n "$OPENSEARCH_HOST" ] || fail "Magento needs OpenSearch. Set OPENSEARCH_SERVER_IP in the App server settings block and run it again."
if [ "$OK" = yes ]; then
  export DB_HOST OPENSEARCH_HOST
  (umask 077; for NAME in GIT_REPO_URL GIT_BRANCH DB_NAME DB_USER DB_PASSWORD DB_DUMP_FILE MEDIA_ARCHIVE_FILE BACKEND_FRONTNAME CRYPT_KEY REPLACE_EXISTING_DB DB_HOST OPENSEARCH_HOST; do printf 'export %s=%q\n' "$NAME" "${!NAME}"; done > ~/.server-setup-deployment.env; chmod 600 ~/.server-setup-deployment.env)
  echo "Deployment settings saved to ~/.server-setup-deployment.env. MariaDB: $DB_HOST, OpenSearch: $OPENSEARCH_HOST"
else
  exit 1
fi
```

### Code

#### Get the code

This block clones the branch into the web root as the restricted user. The first connection to the Git host records its host key in the restricted user's `known_hosts` file, and the block prints that key's fingerprint, so you can compare it with the fingerprints the Git host publishes (for GitHub, in its documentation under "GitHub's SSH key fingerprints"). It also sets `core.fileMode false`, so that the permission repair later in this part, which makes files in `bin/` folders executable, never shows up in Git as a local change.

Running the block again on a web root that already holds the repository fetches the branch and fast-forwards to its latest commit, which is how later releases are deployed. It refuses to merge when the server's copy has diverged from the branch, and it refuses to clone into a web root that holds other files.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: it is for the app server, and this server has INSTALL_APP=$INSTALL_APP."; exit 1; }
: "${GIT_REPO_URL:?Run the Deployment settings block first}"
R="/var/www/$DOMAIN_NAME"
G() { sudo -u "$WEB_USER" -H env GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new" git "$@"; }
if sudo test -d "$R/.git"; then
  G -C "$R" fetch origin "$GIT_BRANCH" || exit 1
  G -C "$R" checkout "$GIT_BRANCH" || exit 1
  G -C "$R" merge --ff-only "origin/$GIT_BRANCH" || { echo "ERROR: the server's copy has diverged from origin/$GIT_BRANCH. Check: sudo -u $WEB_USER git -C $R status"; exit 1; }
elif [ -z "$(sudo ls -A "$R")" ]; then
  G clone --branch "$GIT_BRANCH" "$GIT_REPO_URL" "$R" || { echo "ERROR: the clone failed. Check that the deploy key is added to the repository and that GIT_REPO_URL and GIT_BRANCH are right."; exit 1; }
else
  echo "ERROR: $R is not empty and is not a Git checkout, so nothing was cloned. Its contents are:"; sudo ls -A "$R"; exit 1
fi
G -C "$R" config core.fileMode false
if [[ "$GIT_REPO_URL" =~ ^[^@/]+@([^:/]+): ]]; then
  echo "Host key of ${BASH_REMATCH[1]}:"
  sudo -u "$WEB_USER" -H ssh-keygen -lF "${BASH_REMATCH[1]}" | grep -v '^#'
fi
echo "Deployed commit: $(G -C "$R" log -1 --format='%h %s (%an, %ad)' --date=short)"
for F in composer.json composer.lock app/etc/config.php auth.json; do
  sudo test -f "$R/$F" || echo "WARNING: $F is missing from the repository."
done
```

#### Composer

This block installs the PHP packages exactly as `composer.lock` lists them, without development packages, and with an optimized class autoloader, which is what Adobe recommends for production. Composer reads the Magento Marketplace keys from the `auth.json` file in the project root.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: it is for the app server, and this server has INSTALL_APP=$INSTALL_APP."; exit 1; }
: "${GIT_REPO_URL:?Run the Deployment settings block first}"
R="/var/www/$DOMAIN_NAME"
sudo -u "$WEB_USER" -H composer --working-dir="$R" install --no-dev --optimize-autoloader --no-interaction --no-progress || exit 1
sudo -u "$WEB_USER" php "$R/bin/magento" --version
```

### Data

#### Import the database

This block imports the dump into the application database as the application database user, through the MariaDB client, which it installs when this server has none. `pv` shows the progress of the import.

On its way into MariaDB, the dump is adjusted for this server in three ways:

- `DEFINER` clauses are removed from triggers and views. They name the database account of the old server, and MariaDB refuses to create an object for another account unless the importing user has extra privileges.
- MySQL 8's `utf8mb4_0900_ai_ci` collation, which MariaDB does not have, becomes `utf8mb4_general_ci`, the collation Magento's tables use.
- `CREATE DATABASE` and `USE` statements are removed, so a dump made with `--databases` still lands in `DB_NAME` rather than in a database named after the old server's.

The block stops before changing anything when `DB_NAME` already holds tables, unless `REPLACE_EXISTING_DB` is `yes`. In that case it drops and recreates the database first, so that no tables are left over from an earlier import.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: it is for the app server, and this server has INSTALL_APP=$INSTALL_APP."; exit 1; }
: "${DB_HOST:?Run the Deployment settings block first}"
[ -n "$DB_DUMP_FILE" ] || { echo "Skip this block: DB_DUMP_FILE is empty."; exit 1; }
set -o pipefail
command -v mariadb > /dev/null || sudo apt install -y mariadb-client
command -v pv > /dev/null || sudo apt install -y pv
DB() { mariadb -h "$DB_HOST" -u "$DB_USER" --password="$DB_PASSWORD" --default-character-set=utf8mb4 --max-allowed-packet=256M "$@"; }

TABLES=$(DB -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$DB_NAME'") \
  || { echo "ERROR: could not log in to MariaDB at $DB_HOST as $DB_USER. Check DB_USER and DB_PASSWORD."; exit 1; }
if [ "$TABLES" -gt 0 ]; then
  if [ "$REPLACE_EXISTING_DB" != yes ]; then
    echo "ERROR: $DB_NAME already holds $TABLES tables, so nothing was imported. Set REPLACE_EXISTING_DB=yes in the Deployment settings block to replace them."
    exit 1
  fi
  echo "Dropping and recreating $DB_NAME, which holds $TABLES tables."
  DB -e "DROP DATABASE \`$DB_NAME\`; CREATE DATABASE \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;" || exit 1
fi

DECOMPRESS="cat"
case "$DB_DUMP_FILE" in *.gz) DECOMPRESS="gunzip -c" ;; esac
sudo pv "$DB_DUMP_FILE" | $DECOMPRESS \
  | sed -E -e 's/DEFINER=`[^`]*`@`[^`]*`//g' -e 's/utf8mb4_0900_ai_ci/utf8mb4_general_ci/g' -e '/^USE `/d' -e '/^CREATE DATABASE /d' \
  | DB "$DB_NAME" || { echo "ERROR: the import failed. The error above names the line of the dump that MariaDB rejected."; exit 1; }
echo "Tables imported: $(DB -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$DB_NAME'")"
DB -N -e "SELECT CONCAT('Magento tables found with prefix \'', LEFT(table_name, LENGTH(table_name) - 16), '\'') FROM information_schema.tables WHERE table_schema = '$DB_NAME' AND table_name LIKE '%core\\_config\\_data'"
```

The last line must report that Magento's tables were found. The prefix it shows is usually empty, and the **Configuration** section picks it up automatically.

#### Import the media files

This block extracts the archive as the restricted user straight into `pub/media`, so it needs disk space for only one copy of the media files. It accepts an archive whose top level is `pub/media`, `media`, or the contents of the media folder itself: it reads the first entry of the archive and strips the leading folders to match. Resized product images in `catalog/product/cache` are skipped, because Magento recreates them on demand. Files already in `pub/media` are kept, files of the same name are replaced, and existing folders keep their owner and mode, so running the block again is safe. The extracted files keep the modes they had in the archive, minus the umask, and the **File permissions** block later in this part brings them into line with the permission model.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: it is for the app server, and this server has INSTALL_APP=$INSTALL_APP."; exit 1; }
: "${GIT_REPO_URL:?Run the Deployment settings block first}"
[ -n "$MEDIA_ARCHIVE_FILE" ] || { echo "Skip this block: MEDIA_ARCHIVE_FILE is empty."; exit 1; }
command -v pv > /dev/null || sudo apt install -y pv
R="/var/www/$DOMAIN_NAME"
sudo -u "$WEB_USER" mkdir -p "$R/pub/media"

ENTRY=$(sudo tar -tf "$MEDIA_ARCHIVE_FILE" 2> /dev/null | head -n 1 || true)
FIRST="${ENTRY#./}"
[ -n "$FIRST" ] || { echo "ERROR: $MEDIA_ARCHIVE_FILE is empty or is not a tar archive."; exit 1; }
case "$FIRST" in
  pub|pub/*) STRIP=2 ;;
  media|media/*) STRIP=1 ;;
  *) STRIP=0 ;;
esac
[ "$FIRST" = "$ENTRY" ] || STRIP=$((STRIP + 1))
Z=""
case "$MEDIA_ARCHIVE_FILE" in *.gz|*.tgz) Z="-z" ;; esac
echo "First entry: $FIRST. Stripping $STRIP leading folder(s)."

set -o pipefail
sudo pv "$MEDIA_ARCHIVE_FILE" | sudo -u "$WEB_USER" tar -x $Z -f - -C "$R/pub/media" \
    --strip-components="$STRIP" --no-overwrite-dir --exclude="catalog/product/cache" \
  || { echo "ERROR: the archive could not be extracted into pub/media."; exit 1; }
echo "pub/media now holds $(sudo find "$R/pub/media" -type f | wc -l) files ($(sudo du -sh "$R/pub/media" | cut -f1))."
```

### Configuration

#### Magento's Nginx configuration

Magento ships its own Nginx rules in `nginx.conf.sample`, which serve the store from the `pub` folder and block access to Magento's internal files. Many projects keep their own adjusted copy as `nginx.conf` in the project root, so this block uses that file when it exists and falls back to `nginx.conf.sample` otherwise. Like the sample, a project's `nginx.conf` must hold only the rules that go inside a `server` block, without a `server` or `upstream` block of its own. The block copies the chosen file to `/etc/nginx/snippets/magento.conf`, owned by root, rather than including it from the web root, so that the account that deploys code cannot change Nginx's configuration. It then replaces the generic vhost from Part 4 with one that uses Magento's rules, on the same address and again as its `default_server`. Magento's rules send PHP requests to the `fastcgi_backend` upstream that Part 4 defined, and they serve `/health_check.php`, which Magento's VCL uses to check that the backend is healthy. If `nginx -t` rejects the new rules, the block puts the previous snippet and vhost back, so Nginx keeps serving the old configuration. Run the block again after every Magento upgrade, and whenever the project's `nginx.conf` changes.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: it is for the app server, and this server has INSTALL_APP=$INSTALL_APP."; exit 1; }
: "${DOMAIN_NAME:?Run the Variables blocks first}"
: "${SSL_MODE:?Run the Variables blocks first}"
WEB_ROOT="/var/www/$DOMAIN_NAME"
VHOST_LISTEN="127.0.0.1:8080"
[ "$SSL_MODE" = off ] && [ "$INSTALL_VARNISH" = no ] && VHOST_LISTEN="80"
RULES="$WEB_ROOT/nginx.conf"
[ -f "$RULES" ] || RULES="$WEB_ROOT/nginx.conf.sample"
[ -f "$RULES" ] || { echo "Neither nginx.conf nor nginx.conf.sample is in $WEB_ROOT. Run the Get the code block first."; exit 1; }
echo "Using Magento's Nginx rules from $RULES."

SNIPPET=/etc/nginx/snippets/magento.conf
VHOST="/etc/nginx/sites-available/$DOMAIN_NAME"
sudo rm -f "$SNIPPET.bak" "$VHOST.bak"
[ -f "$SNIPPET" ] && sudo cp -p "$SNIPPET" "$SNIPPET.bak"
[ -f "$VHOST" ] && sudo cp -p "$VHOST" "$VHOST.bak"
sudo install -m 644 -o root -g root "$RULES" "$SNIPPET"
sudo tee "$VHOST" > /dev/null <<EOF
server {
    listen $VHOST_LISTEN default_server;
    server_name $DOMAIN_NAME www.$DOMAIN_NAME;

    set \$MAGE_ROOT $WEB_ROOT;
    set \$MAGE_DEBUG_SHOW_ARGS 0;

    include $SNIPPET;
}
EOF
sudo ln -sf "$VHOST" "/etc/nginx/sites-enabled/$DOMAIN_NAME"
if sudo nginx -t; then
  sudo systemctl reload nginx
  sudo rm -f "$SNIPPET.bak" "$VHOST.bak"
else
  echo "ERROR: Nginx rejected the rules from $RULES. Restoring the previous configuration."
  if [ -f "$SNIPPET.bak" ]; then sudo mv "$SNIPPET.bak" "$SNIPPET"; else sudo rm -f "$SNIPPET"; fi
  [ -f "$VHOST.bak" ] && sudo mv "$VHOST.bak" "$VHOST"
  sudo nginx -t
  exit 1
fi
```

Magento learns that a visitor used HTTPS from the `X-Forwarded-Proto` header, which only the HTTPS vhost (or, with `SSL_MODE=off`, the load balancer) sets, so its rules need no `HTTPS` parameter of their own.

#### Magento's environment and store settings

This block connects the code to the imported database and to this server's services with `bin/magento setup:install`. Run against a database that already holds the store, it writes `app/etc/env.php` and marks the deployment as installed, while the schema and data patches that the store has already applied are skipped. It passes only the settings that differ on this server: the database and its table prefix (read from the imported tables), the admin path, the base URLs, OpenSearch, Valkey for the cache and sessions, and Varnish for cache purges (or Valkey's database 1 as the page cache when Varnish is not installed). Both base URLs are `https://DOMAIN_NAME/`, because visitors always reach the store over HTTPS, either through this server's HTTPS vhost or through the load balancer with `SSL_MODE=off`. The encryption key is passed only when `CRYPT_KEY` is set; otherwise Magento keeps the key already in `env.php`, or generates a new one, which the block prints once so you can keep it in your password manager. No admin account is created, because the imported database already has its admin users, and the store's locale, currency, and time zone are not passed, so they keep their values from the database. Take a fresh copy of the imported database before you run the block, so that you can restore it if the installation stops part of the way through. The block first repairs the web root's permissions, as the **File permissions** block does, because `setup:install` refuses to start when the restricted user cannot write to a folder under `var/`, `generated/`, `pub/static/`, or `pub/media/`. This happens when a module running under PHP-FPM creates a folder with an explicit mode such as `0755`, which the `002` umask cannot widen, so the folder belongs to `www-data` without group write access.

It then changes the settings that the imported database carries over from the old server:

- The link URLs are reset to Magento's defaults, which follow the base URLs.
- Requests for any other name, such as `www.DOMAIN_NAME`, are redirected to the base URL with a permanent (301) redirect, so that search engines index one address only.
- The cookie domain is removed, so cookies belong to whichever name the store answers on. A cookie domain left over from a staging server would stop customers and admins from logging in.
- The full-page cache uses Varnish with Nginx on `127.0.0.1:8080` as its backend, or Magento's built-in cache without Varnish.

The block ends by listing every URL setting in the database. Settings for a single website or store view (`scope` other than `default`) override the defaults above, so check that each one belongs to this server.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: it is for the app server, and this server has INSTALL_APP=$INSTALL_APP."; exit 1; }
: "${DB_HOST:?Run the Deployment settings block first}"
R="/var/www/$DOMAIN_NAME"
cd "$R" || exit 1
J="$(nproc)"
sudo find -H "$R" \( \( ! -user "$WEB_USER" ! -user www-data \) -o ! -group www-data \) -print0 \
  | sudo xargs -0 -r -P "$J" -n 500 chown -h "$WEB_USER:www-data"
sudo find -H "$R" -type d ! -perm 2775 -print0 | sudo xargs -0 -r -P "$J" -n 500 chmod 2775
sudo find -H "$R" -type f ! -name '*.sh' ! -path '*/bin/*' ! -perm 664 -print0 | sudo xargs -0 -r -P "$J" -n 500 chmod 664
sudo find -H "$R" -type f \( -name '*.sh' -o -path '*/bin/*' \) ! -perm 775 -print0 | sudo xargs -0 -r -P "$J" -n 500 chmod 775
M() { sudo -u "$WEB_USER" php bin/magento "$@" || { echo "ERROR: bin/magento $1 failed."; exit 1; }; }
DB() { mariadb -h "$DB_HOST" -u "$DB_USER" --password="$DB_PASSWORD" --default-character-set=utf8mb4 "$DB_NAME" "$@"; }

T=$(DB -N -e "SELECT table_name FROM information_schema.tables WHERE table_schema = '$DB_NAME' AND table_name LIKE '%core\\_config\\_data' ORDER BY LENGTH(table_name) LIMIT 1")
[ -n "$T" ] || { echo "ERROR: $DB_NAME has no core_config_data table. Run the Import the database block first."; exit 1; }
PREFIX="${T%core_config_data}"

ARGS=(--db-host="$DB_HOST" --db-name="$DB_NAME" --db-user="$DB_USER" --db-password="$DB_PASSWORD" --db-prefix="$PREFIX"
      --backend-frontname="$BACKEND_FRONTNAME"
      --base-url="https://$DOMAIN_NAME/" --base-url-secure="https://$DOMAIN_NAME/"
      --search-engine=opensearch --opensearch-host="$OPENSEARCH_HOST" --opensearch-port=9200 --opensearch-enable-auth=0)
NEW_KEY=no
if [ -n "$CRYPT_KEY" ]; then
  ARGS+=(--key="$CRYPT_KEY")
elif ! sudo grep -q "'crypt'" app/etc/env.php 2>/dev/null; then
  NEW_KEY=yes
fi
if [ "$INSTALL_VALKEY" = yes ]; then
  VP="$(sudo awk '/^requirepass/{print $2}' /etc/valkey/valkey-cache.conf)"
  ARGS+=(--cache-backend=redis --cache-backend-redis-server=127.0.0.1 --cache-backend-redis-port=6379 --cache-backend-redis-db=0 --cache-backend-redis-password="$VP"
         --session-save=redis --session-save-redis-host=127.0.0.1 --session-save-redis-port=6380 --session-save-redis-db=0 --session-save-redis-password="$VP")
  if [ "$INSTALL_VARNISH" = no ]; then
    ARGS+=(--page-cache=redis --page-cache-redis-server=127.0.0.1 --page-cache-redis-port=6379 --page-cache-redis-db=1 --page-cache-redis-password="$VP")
  fi
fi
if [ "$INSTALL_VARNISH" = yes ]; then
  VARNISH_PORT=6081
  [ "$SSL_MODE" = off ] && VARNISH_PORT=80
  ARGS+=(--http-cache-hosts="127.0.0.1:$VARNISH_PORT")
fi
M setup:install "${ARGS[@]}" --no-interaction

M config:set web/unsecure/base_link_url "{{unsecure_base_url}}"
M config:set web/secure/base_link_url "{{secure_base_url}}"
M config:set web/url/redirect_to_base 301
DB -e "DELETE FROM \`${PREFIX}core_config_data\` WHERE path = 'web/cookie/cookie_domain';"

if [ "$INSTALL_VARNISH" = yes ]; then
  M config:set system/full_page_cache/caching_application 2
  M config:set system/full_page_cache/varnish/backend_host 127.0.0.1
  M config:set system/full_page_cache/varnish/backend_port 8080
  M config:set system/full_page_cache/varnish/access_list 127.0.0.1
else
  M config:set system/full_page_cache/caching_application 1
fi

if [ "$NEW_KEY" = yes ]; then
  echo "New encryption key: $(sudo -u "$WEB_USER" php -r 'echo (include "app/etc/env.php")["crypt"]["key"];')"
fi
echo "Table prefix: '${PREFIX}'"
echo "URL settings in the database:"
DB -t -e "SELECT scope, scope_id, path, value FROM \`${PREFIX}core_config_data\` WHERE path LIKE 'web/%url' ORDER BY scope, scope_id, path;"
```

`env.php` now holds the database and Valkey passwords. Magento creates it with mode `660` or `664`, readable only by the restricted user and the `www-data` group, and the web server never serves it, because Nginx serves only the `pub` folder.

### Build

This block puts the store into maintenance mode and builds it for production, in the order Adobe documents:

1. `setup:upgrade` updates the database schema and data for the deployed code, and checks that OpenSearch is reachable.
2. `deploy:mode:set production --skip-compilation` switches to production mode, in which Magento hides errors from visitors and serves only pre-built files, without building anything yet.
3. `setup:di:compile` generates the dependency injection code.
4. `setup:static-content:deploy` builds the static files for every locale the store uses (read from the database, plus `en_US` and the admin users' interface locales) on every CPU core.

Before these steps, the block repairs the web root's permissions in the same way as **Magento's environment and store settings**, because `setup:upgrade` stops on a folder that the restricted user cannot write to. The block stops at the first command that fails, and the store then stays in maintenance mode while you fix the problem and run the block again. Compilation and static content deployment take several minutes on a typical store.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: it is for the app server, and this server has INSTALL_APP=$INSTALL_APP."; exit 1; }
: "${DB_HOST:?Run the Deployment settings block first}"
R="/var/www/$DOMAIN_NAME"
cd "$R" || exit 1
J="$(nproc)"
sudo find -H "$R" \( \( ! -user "$WEB_USER" ! -user www-data \) -o ! -group www-data \) -print0 \
  | sudo xargs -0 -r -P "$J" -n 500 chown -h "$WEB_USER:www-data"
sudo find -H "$R" -type d ! -perm 2775 -print0 | sudo xargs -0 -r -P "$J" -n 500 chmod 2775
sudo find -H "$R" -type f ! -name '*.sh' ! -path '*/bin/*' ! -perm 664 -print0 | sudo xargs -0 -r -P "$J" -n 500 chmod 664
sudo find -H "$R" -type f \( -name '*.sh' -o -path '*/bin/*' \) ! -perm 775 -print0 | sudo xargs -0 -r -P "$J" -n 500 chmod 775
M() { sudo -u "$WEB_USER" php bin/magento "$@" || { echo "ERROR: bin/magento $1 failed. The store stays in maintenance mode."; exit 1; }; }
PREFIX="$(sudo -u "$WEB_USER" php -r 'echo (include "app/etc/env.php")["db"]["table_prefix"] ?? "";')"

M maintenance:enable
M setup:upgrade
M deploy:mode:set production --skip-compilation
M setup:di:compile
LOCALES=$( { echo en_US
  mariadb -h "$DB_HOST" -u "$DB_USER" --password="$DB_PASSWORD" "$DB_NAME" -N -e "SELECT value FROM \`${PREFIX}core_config_data\` WHERE path = 'general/locale/code'; SELECT interface_locale FROM \`${PREFIX}admin_user\`;"
} | grep -E '^[a-z]{2,3}(_[A-Za-z]+)+$' | sort -u | tr '\n' ' ')
echo "Deploying static content for: $LOCALES"
M setup:static-content:deploy $LOCALES --jobs "$(nproc)"
M deploy:mode:show
```

### Varnish

Run this block when `INSTALL_VARNISH=yes`. Magento's VCL checks the store every 5 seconds by requesting `/health_check.php` from Nginx on `127.0.0.1:8080`, and when that check fails, Varnish answers every visitor with "503 Backend fetch failed" without passing the request on. The block therefore first requests the same URL, without a `Host` header, exactly as the probe does. If the answer is not `200`, it keeps the current VCL and prints Magento's last log messages, which name the reason, such as a database or cache that cannot be reached, or, on Magento 2.4.9 without the AC-17400 patch described in **Before you start**, the `page_cache` entry in `env.php`, which the health check rejects with "Cache configuration is invalid". A `404` means that the request reached a site other than the store's vhost.

It then exports Magento's VCL for Varnish 7 (which also runs on Varnish 8), pointed at Nginx on `127.0.0.1:8080` and allowing cache purges only from this server. The VCL is saved as `/etc/varnish/magento.vcl`, leaving the package's own `default.vcl` untouched, so a Varnish upgrade never asks which version to keep. It is checked by compiling it first, so a faulty VCL never reaches the running Varnish. The temporary copy is made readable by everyone for that check, because `varnishd -C` reads the file as Varnish's own unprivileged user, and the VCL holds no secrets. Only then does the block install the VCL and point the systemd drop-in at it. Varnish restarts to load it, which empties the cache once. Run the block again after a Magento upgrade, because a new release can change the VCL.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] && [ "$INSTALL_VARNISH" = yes ] || { echo "Skip this block: this server does not run Varnish."; exit 1; }
: "${DOMAIN_NAME:?Run the Variables blocks first}"
cd "/var/www/$DOMAIN_NAME" || exit 1
HEALTH=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/health_check.php || true)
if [ "$HEALTH" != 200 ]; then
  echo "ERROR: http://127.0.0.1:8080/health_check.php returned $HEALTH instead of 200, so Varnish would answer every request with 503. The current VCL was kept."
  echo "Magento's last log messages:"
  sudo tail -n 5 var/log/system.log 2>/dev/null || true
  exit 1
fi
echo "Health check: $HEALTH"
NEW_VCL="$(mktemp)"
sudo -u "$WEB_USER" php bin/magento varnish:vcl:generate --export-version=7 \
  --backend-host=127.0.0.1 --backend-port=8080 --access-list=127.0.0.1 > "$NEW_VCL"
chmod 644 "$NEW_VCL"
if [ -s "$NEW_VCL" ] && sudo varnishd -C -f "$NEW_VCL" > /dev/null; then
  sudo install -m 644 -o root -g root "$NEW_VCL" /etc/varnish/magento.vcl
  sudo sed -i -E 's#-f [^ ]+#-f /etc/varnish/magento.vcl#' /etc/systemd/system/varnish.service.d/override.conf
  sudo systemctl daemon-reload
  sudo systemctl restart varnish
  systemctl cat varnish.service | grep -o -- '-f [^ ]*' | tail -1
  echo "varnish: $(systemctl is-active varnish)"
else
  echo "The VCL did not compile, so the current VCL was kept."
  rm -f "$NEW_VCL"
  exit 1
fi
rm -f "$NEW_VCL"
```

### Indexers

Magento's indexers in "Update by Schedule" mode rely on database triggers, which record every change in a changelog table that cron then processes. An imported database often has triggers missing, left over from another version, or created for a different table prefix, and indexes that were built on the old server. This block therefore rebuilds both from scratch:

1. Switching every indexer to "Update on Save" removes all of Magento's triggers.
2. Switching them back to "Update by Schedule" creates a complete, current set of triggers. This is Adobe's recommended mode for production, because saving a product no longer waits for the indexers. The customer grid is included deliberately, even though Adobe documents it as supported only in "Update on Save" mode. If new customers stop appearing in the admin's customer grid, run `sudo -u webuser php bin/magento indexer:reindex customer_grid` in the web root, or switch that one indexer back with `indexer:set-mode realtime customer_grid`.
3. `indexer:reset` marks every index as invalid, and `indexer:reindex` rebuilds them all, including the OpenSearch catalog index.

The block ends by showing each indexer's mode and status, which must all be `Ready`, and the number of triggers in the database, which must be well above zero. A full reindex can take a long time on a large catalog.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: it is for the app server, and this server has INSTALL_APP=$INSTALL_APP."; exit 1; }
: "${DB_HOST:?Run the Deployment settings block first}"
cd "/var/www/$DOMAIN_NAME" || exit 1
M() { sudo -u "$WEB_USER" php bin/magento "$@" || { echo "ERROR: bin/magento $1 failed."; exit 1; }; }
M indexer:set-mode realtime
M indexer:set-mode schedule
M indexer:reset
M indexer:reindex
M indexer:show-mode
M indexer:status
echo "Database triggers: $(mariadb -h "$DB_HOST" -u "$DB_USER" --password="$DB_PASSWORD" -N -e "SELECT COUNT(*) FROM information_schema.triggers WHERE trigger_schema = '$DB_NAME'")"
```

### Cron

Magento needs its cron jobs for indexing in "Update by Schedule" mode, emails, the message queue, and scheduled tasks. This installs them in the restricted user's crontab, so they run with the same permissions as the code. `--force` replaces Magento's own section of the crontab when it already exists, so running the block again is safe.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: it is for the app server, and this server has INSTALL_APP=$INSTALL_APP."; exit 1; }
: "${DOMAIN_NAME:?Run the Variables blocks first}"
cd "/var/www/$DOMAIN_NAME" || exit 1
sudo -u "$WEB_USER" php bin/magento cron:install --force
sudo crontab -u "$WEB_USER" -l
```

### File permissions

Every command in this part ran as the restricted user with a umask of `002`, so almost everything already follows the permission model. The exceptions are files in `bin/` folders and `*.sh` files that the repository or a Composer package stores without the executable bit. This block applies the same repair as Part 7 to the web root, changing only the items that are wrong, and then shows the same counts as Part 5's final verification, which must all be `0`.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: it is for the app server, and this server has INSTALL_APP=$INSTALL_APP."; exit 1; }
: "${DOMAIN_NAME:?Run the Variables blocks first}"
R="/var/www/$DOMAIN_NAME"
J="$(nproc)"
sudo find -H "$R" \( \( ! -user "$WEB_USER" ! -user www-data \) -o ! -group www-data \) -print0 \
  | sudo xargs -0 -r -P "$J" -n 500 chown -h "$WEB_USER:www-data"
sudo find -H "$R" -type d ! -perm 2775 -print0 | sudo xargs -0 -r -P "$J" -n 500 chmod 2775
sudo find -H "$R" -type f ! -name '*.sh' ! -path '*/bin/*' ! -perm 664 -print0 | sudo xargs -0 -r -P "$J" -n 500 chmod 664
sudo find -H "$R" -type f \( -name '*.sh' -o -path '*/bin/*' \) ! -perm 775 -print0 | sudo xargs -0 -r -P "$J" -n 500 chmod 775
echo "Wrong owner or group:          $(sudo find -H "$R" \( \( ! -user "$WEB_USER" ! -user www-data \) -o ! -group www-data \) -printf . | wc -c)"
echo "Folders that are not 2775:     $(sudo find -H "$R" -type d ! -perm 2775 -printf . | wc -c)"
echo "Files that are not 664:        $(sudo find -H "$R" -type f ! -name '*.sh' ! -path '*/bin/*' ! -perm 664 -printf . | wc -c)"
echo "Executables that are not 775:  $(sudo find -H "$R" -type f \( -name '*.sh' -o -path '*/bin/*' \) ! -perm 775 -printf . | wc -c)"
```

### Go live

This block restarts PHP-FPM, which is required after every deployment because OPcache never checks for changed files in production. It then flushes Magento's caches, which also purges Varnish, and takes the store out of maintenance mode. Finally, it requests the home page and the admin login page the way a visitor would, through HTTPS (or through the load balancer's path with `SSL_MODE=off`), and with Varnish it requests the home page a second time to confirm that Varnish served it from its cache.

```bash
[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: it is for the app server, and this server has INSTALL_APP=$INSTALL_APP."; exit 1; }
: "${BACKEND_FRONTNAME:?Run the Deployment settings block first}"
cd "/var/www/$DOMAIN_NAME" || exit 1
M() { sudo -u "$WEB_USER" php bin/magento "$@" || { echo "ERROR: bin/magento $1 failed."; exit 1; }; }
sudo systemctl restart "php$PHP_VERSION-fpm"
M cache:flush
M maintenance:disable
sleep 2
fetch() {
  if [ "$SSL_MODE" = off ]; then
    curl -s -o /dev/null -w '%{http_code}' -H "Host: $DOMAIN_NAME" -H "X-Forwarded-Proto: https" "http://127.0.0.1$1"
  else
    curl -sk -o /dev/null -w '%{http_code}' --resolve "$DOMAIN_NAME:443:127.0.0.1" "https://$DOMAIN_NAME$1"
  fi
}
printf "%-48s HTTP %s\n" "https://$DOMAIN_NAME/" "$(fetch /)"
printf "%-48s HTTP %s\n" "https://$DOMAIN_NAME/$BACKEND_FRONTNAME/" "$(fetch "/$BACKEND_FRONTNAME/")"
if [ "$INSTALL_VARNISH" = yes ]; then
  HITS=$(sudo varnishstat -1 -f MAIN.cache_hit | awk '{print $2}')
  fetch / > /dev/null
  if [ "$(sudo varnishstat -1 -f MAIN.cache_hit | awk '{print $2}')" -gt "$HITS" ]; then
    echo "Varnish served the home page from its cache"
  else
    echo "WARNING: Varnish did not cache the home page. Check: sudo varnishlog -g request -q 'ReqURL eq \"/\"'"
  fi
fi
```

The home page must return `200`, and the admin login page `200` as well. A `500` or `503` means an error, which Magento records in `var/log/exception.log` and `var/log/system.log` in the web root, and a `404` on the admin page means `BACKEND_FRONTNAME` differs from the path in `env.php`. Log in to the admin panel with an admin account from the imported database. If you need a new one, run `sudo -u webuser php bin/magento admin:user:create` in the web root, replacing `webuser` with the value of `WEB_USER` if you changed it.

Once the store works, delete the uploaded dump and archive from the `ubuntu` home folder, because the dump holds customer data:

```text
sudo rm /home/ubuntu/database.sql.gz /home/ubuntu/media.tar.gz
```

### Deploying later releases

A later release of the code needs only some of the blocks above. Run the **Variables** blocks, the **Resource sizing** block, and the **Deployment settings** block with `DB_DUMP_FILE` and `MEDIA_ARCHIVE_FILE` left empty, then **File permissions**, **Get the code**, **Composer**, **Build**, **File permissions** again, and **Go live**. The first run of **File permissions** gives the restricted user write access to any folder that a module created under PHP-FPM since the last deployment, so Git and Composer never stop on one. Also run **Magento's Nginx configuration** and the **Varnish** block after a Magento upgrade, and the **Indexers** block when a release adds or changes indexers. The database and media are imported only once: never run the **Data** blocks against a live store, because they replace its orders, customers, and images.

## Part 7: Reset file permissions

Run this part on an app server whose web root permissions have drifted, for example a server that was set up before this runbook set the umask, or one where code was deployed as root or copied with `rsync -a`. It works on any server with the same layout: a web root under `/var/www/`, a restricted user that owns the code, and PHP-FPM running as `www-data`. It does not depend on the earlier parts or their variables, so you can run it on its own in a new Runme session, and it is safe to run as often as you like.

The part first stops the drift from coming back, then repairs the web root to the model described in **File permissions** in the **Restricted user and web root** section: owner the restricted user or `www-data`, group `www-data`, folders `2775`, ordinary files `664`, and files named `*.sh` or inside a `bin/` folder `775`.

### Web root and restricted user

Set the web root and the restricted user when Runme asks. The block checks that the folder is under `/var/www/` and that the user exists, so that a mistyped value cannot change permissions anywhere else on the server.

```bash
export WEB_ROOT="/var/www/example.com"
export WEB_USER="webuser"

OK=yes
WEB_ROOT="${WEB_ROOT%/}"
if ! [[ "$WEB_ROOT" =~ ^/var/www/[^/]+ ]] || [[ "$WEB_ROOT" == *..* ]]; then
  echo "ERROR: WEB_ROOT must be a folder under /var/www/, such as /var/www/example.com, not '$WEB_ROOT'."; OK=no
elif [ ! -d "$WEB_ROOT" ]; then
  echo "ERROR: $WEB_ROOT does not exist."; OK=no
fi
id -u "$WEB_USER" > /dev/null 2>&1 || { echo "ERROR: the user '$WEB_USER' does not exist on this server."; OK=no; }
getent group www-data > /dev/null || { echo "ERROR: the www-data group does not exist on this server."; OK=no; }
if [ "$OK" = yes ]; then export WEB_ROOT; echo "Web root and restricted user saved."; else exit 1; fi
```

### Check the current permissions

This block changes nothing. It counts the items that do not follow the model and lists up to 20 of them with their current mode, owner, and group. Run it again after the repair below, when every count should be `0`.

```bash
: "${WEB_ROOT:?Run the Web root and restricted user block first}"
R="$WEB_ROOT"
echo "Wrong owner or group:         $(sudo find -H "$R" \( \( ! -user "$WEB_USER" ! -user www-data \) -o ! -group www-data \) -printf . | wc -c)"
echo "Folders that are not 2775:    $(sudo find -H "$R" -type d ! -perm 2775 -printf . | wc -c)"
echo "Files that are not 664:       $(sudo find -H "$R" -type f ! -name '*.sh' ! -path '*/bin/*' ! -perm 664 -printf . | wc -c)"
echo "Executables that are not 775: $(sudo find -H "$R" -type f \( -name '*.sh' -o -path '*/bin/*' \) ! -perm 775 -printf . | wc -c)"
echo
echo "Examples:"
sudo find -H "$R" \( \( ! -user "$WEB_USER" ! -user www-data \) -o ! -group www-data \
  -o \( -type d ! -perm 2775 \) \
  -o \( -type f ! -name '*.sh' ! -path '*/bin/*' ! -perm 664 \) \
  -o \( -type f \( -name '*.sh' -o -path '*/bin/*' \) ! -perm 775 \) \) \
  -printf '%M %u:%g %p\n' | head -20 || true
```

### Stop the drift from coming back

This block applies the same settings that a new server gets in Part 4, so that files created after the repair keep the right permissions:

- It adds the restricted user to the `www-data` group, and `www-data` to the restricted user's group, if either membership is missing.
- It sets `umask 002` for the restricted user's logins and for `sudo -u`, as described in **File permissions**.
- It sets `UMask=0002` for every PHP-FPM version installed on the server, and restarts each one, which interrupts PHP requests for a moment.

It also warns about a `magento_umask` file in the web root, because Magento would use that file's value instead of `002`. The umask lines at the end must each print `0002`.

```bash
: "${WEB_ROOT:?Run the Web root and restricted user block first}"
sudo usermod -aG www-data "$WEB_USER"
sudo usermod -aG "$WEB_USER" www-data

for F in .profile .bashrc; do
  P="$(getent passwd "$WEB_USER" | cut -d: -f6)/$F"
  if ! sudo grep -qx 'umask 002' "$P" 2>/dev/null; then
    if sudo test -s "$P"; then sudo sed -i '1i umask 002' "$P"; else echo 'umask 002' | sudo tee "$P" > /dev/null; fi
  fi
  sudo chown "$WEB_USER:$(id -gn "$WEB_USER")" "$P"
  sudo chmod 644 "$P"
done
echo "Defaults>$WEB_USER umask=0002, umask_override" > /tmp/web-user-umask
if sudo visudo -cf /tmp/web-user-umask; then
  sudo install -m 440 -o root -g root /tmp/web-user-umask /etc/sudoers.d/50-web-user-umask
else
  echo "ERROR: the sudoers rule did not pass visudo, so it was not installed."
fi
rm -f /tmp/web-user-umask

for UNIT in $(systemctl list-unit-files 'php*-fpm.service' --no-legend | awk '{print $1}'); do
  sudo mkdir -p "/etc/systemd/system/$UNIT.d"
  printf '[Service]\nUMask=0002\n' | sudo tee "/etc/systemd/system/$UNIT.d/umask.conf" > /dev/null
  sudo systemctl daemon-reload
  if systemctl is-active --quiet "$UNIT"; then sudo systemctl restart "$UNIT"; fi
done
sleep 1

if [ -f "$WEB_ROOT/magento_umask" ]; then
  echo "WARNING: $WEB_ROOT/magento_umask contains '$(cat "$WEB_ROOT/magento_umask")'. Delete it, or change it to 002."
fi
echo "Restricted user login umask:   $(sudo su - "$WEB_USER" -c umask)"
echo "Restricted user sudo -u umask: $(sudo -u "$WEB_USER" sh -c umask)"
for PID in $(pgrep -f 'php-fpm: pool' | head -1); do
  echo "PHP-FPM worker umask:          $(awk '/^Umask/{print $2}' "/proc/$PID/status")"
done
```

### Repair the web root

This block changes only the items that do not follow the model, so on a large store it takes far less time than resetting every file, and it spreads the work across all CPU cores. Files owned by `www-data` keep that owner, because the shared group already lets the restricted user change them. Every other file with the wrong owner or group is given to the restricted user and the `www-data` group. Symbolic links are never followed, so nothing outside the web root is touched.

The store keeps running while the block works. On a store with a very large `pub/media` folder, run it at a quiet time, because it reads every file's metadata.

```bash
: "${WEB_ROOT:?Run the Web root and restricted user block first}"
R="$WEB_ROOT"
J="$(nproc)"
sudo find -H "$R" \( \( ! -user "$WEB_USER" ! -user www-data \) -o ! -group www-data \) -print0 \
  | sudo xargs -0 -r -P "$J" -n 500 chown -h "$WEB_USER:www-data"
sudo find -H "$R" -type d ! -perm 2775 -print0 | sudo xargs -0 -r -P "$J" -n 500 chmod 2775
sudo find -H "$R" -type f ! -name '*.sh' ! -path '*/bin/*' ! -perm 664 -print0 | sudo xargs -0 -r -P "$J" -n 500 chmod 664
sudo find -H "$R" -type f \( -name '*.sh' -o -path '*/bin/*' \) ! -perm 775 -print0 | sudo xargs -0 -r -P "$J" -n 500 chmod 775
echo "Repair finished. Run the Check the current permissions block again to confirm that every count is 0."
```
