# Server Setup Runbook (Ubuntu 24.04)

This runbook provisions a production PHP application server: Nginx, PHP-FPM, MariaDB, OpenSearch, Valkey, Varnish, Composer, phpMyAdmin, HTTPS, and the security hardening around them. It does not install any application.

How to use it:

- Each `bash` block has its own run button in Runme. Blocks labelled `text` are notes, not commands.
- Run the blocks from top to bottom. Later blocks depend on values set by earlier ones.
- Run the **Variables** and **Resource sizing** blocks first in every new Runme session. Variables last only for the current session, so if you restart VS Code or the Runme kernel, run those two blocks again before continuing. Blocks that need a variable stop with an error if it is missing, rather than running with an empty value.
- Blocks that generate a password print it once. Copy each one into your password manager straight away, then clear the cell output.

## Before you start (AWS)

1. Take an EBS snapshot of the instance, so you can roll back if something goes wrong.
2. In the instance's security group, allow inbound traffic only on these ports:

```text
22/tcp   SSH     from your own IP address only
80/tcp   HTTP    from anywhere (needed for Let's Encrypt and the HTTP site)
443/tcp  HTTPS   from anywhere
```

No other port needs to be open. MariaDB, OpenSearch, Valkey, and phpMyAdmin all listen on `127.0.0.1` only.

## Variables

Runme asks for each value when you run this block. Replace the defaults with the values for this server.

```bash
export DOMAIN_NAME="example.com"
export WEB_USER="webuser"
export PHP_VERSION="8.5"
export ADMIN_EMAIL="admin@example.com"
```

## Resource sizing

This block reads the server's RAM and calculates the memory for every service, so that they all fit together on one machine. It uses the same rules as `setup-ubuntu24.sh`. Run it before the install sections.

```bash
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')

# MariaDB buffer pool: 25% of RAM up to 8 GB of RAM, 30% above that
if [ "$TOTAL_RAM_MB" -le 8192 ]; then
  DB_BUFFER_POOL_MB=$((TOTAL_RAM_MB * 25 / 100))
else
  DB_BUFFER_POOL_MB=$((TOTAL_RAM_MB * 30 / 100))
fi

# OpenSearch heap: 25% of RAM, capped at 8 GB (1 GB on servers with 6 GB of RAM or less)
OPENSEARCH_HEAP_MB=$((TOTAL_RAM_MB * 25 / 100))
[ "$OPENSEARCH_HEAP_MB" -gt 8192 ] && OPENSEARCH_HEAP_MB=8192
[ "$TOTAL_RAM_MB" -le 6144 ] && [ "$OPENSEARCH_HEAP_MB" -gt 1024 ] && OPENSEARCH_HEAP_MB=1024

# Valkey: 10% of RAM, between 256 MB and 2 GB
VALKEY_MEMORY_MB=$((TOTAL_RAM_MB * 10 / 100))
[ "$VALKEY_MEMORY_MB" -lt 256 ] && VALKEY_MEMORY_MB=256
[ "$VALKEY_MEMORY_MB" -gt 2048 ] && VALKEY_MEMORY_MB=2048

# Varnish cache: 5% of RAM, between 256 MB and 2 GB
VARNISH_CACHE_MB=$((TOTAL_RAM_MB * 5 / 100))
[ "$VARNISH_CACHE_MB" -lt 256 ] && VARNISH_CACHE_MB=256
[ "$VARNISH_CACHE_MB" -gt 2048 ] && VARNISH_CACHE_MB=2048

# Operating system reserve: 5% of RAM, at least 512 MB
RESERVE_MB=$((TOTAL_RAM_MB * 5 / 100))
[ "$RESERVE_MB" -lt 512 ] && RESERVE_MB=512

# PHP-FPM gets what is left. 768 MB covers the shared OPcache and JIT buffers,
# and each PHP worker is estimated at 120 MB on average.
PHP_REMAINING_MB=$((TOTAL_RAM_MB - DB_BUFFER_POOL_MB - OPENSEARCH_HEAP_MB - VALKEY_MEMORY_MB - VARNISH_CACHE_MB - RESERVE_MB - 768))
PHP_MAX_CHILDREN=$((PHP_REMAINING_MB / 120))
[ "$PHP_MAX_CHILDREN" -lt 5 ] && PHP_MAX_CHILDREN=5
PHP_START_SERVERS=$((PHP_MAX_CHILDREN / 4)); [ "$PHP_START_SERVERS" -lt 2 ] && PHP_START_SERVERS=2
PHP_MIN_SPARE=$((PHP_MAX_CHILDREN / 8));     [ "$PHP_MIN_SPARE" -lt 1 ] && PHP_MIN_SPARE=1
PHP_MAX_SPARE=$((PHP_MAX_CHILDREN / 2));     [ "$PHP_MAX_SPARE" -lt "$PHP_START_SERVERS" ] && PHP_MAX_SPARE=$PHP_START_SERVERS

export TOTAL_RAM_MB DB_BUFFER_POOL_MB OPENSEARCH_HEAP_MB VALKEY_MEMORY_MB VARNISH_CACHE_MB
export PHP_MAX_CHILDREN PHP_START_SERVERS PHP_MIN_SPARE PHP_MAX_SPARE

echo "Total RAM:            ${TOTAL_RAM_MB} MB"
echo "MariaDB buffer pool:  ${DB_BUFFER_POOL_MB} MB"
echo "OpenSearch heap:      ${OPENSEARCH_HEAP_MB} MB"
echo "Valkey memory:        ${VALKEY_MEMORY_MB} MB"
echo "Varnish cache:        ${VARNISH_CACHE_MB} MB"
echo "PHP-FPM workers:      max ${PHP_MAX_CHILDREN}, start ${PHP_START_SERVERS}, spare ${PHP_MIN_SPARE} to ${PHP_MAX_SPARE}"
[ "$PHP_REMAINING_MB" -lt 600 ] && echo "WARNING: very little RAM is left for PHP. Use a larger instance."
```

## System update and base packages

```bash
sudo apt update
sudo apt full-upgrade -y
sudo apt install -y software-properties-common ca-certificates curl gnupg git unzip apache2-utils
sudo timedatectl set-timezone UTC
```

Kernel settings: OpenSearch needs a higher memory map limit, and Valkey needs memory overcommit enabled to save its data safely.

```bash
printf 'vm.max_map_count = 262144\nvm.overcommit_memory = 1\n' | sudo tee /etc/sysctl.d/99-server.conf
sudo sysctl --system > /dev/null
sysctl vm.max_map_count vm.overcommit_memory
```

If the update installed a new kernel, reboot now. Reconnect afterwards and run the **Variables** and **Resource sizing** blocks again.

```bash
if [ -f /var/run/reboot-required ]; then echo "Reboot required"; else echo "No reboot needed"; fi
```

```bash
sudo reboot
```

## Restricted user and web root

The restricted user owns the application files. It has no sudo access, logs in with an SSH key only, and shares the `www-data` group with PHP-FPM and Nginx.

```bash
: "${WEB_USER:?Run the Variables block first}"
sudo adduser --disabled-password --gecos "" "$WEB_USER"
sudo usermod -aG www-data "$WEB_USER"
sudo usermod -aG "$WEB_USER" www-data
```

Replace the key below with the public key (from your Mac) that should log in as this user.

```bash
: "${WEB_USER:?Run the Variables block first}"
PUBKEY="ssh-ed25519 AAAA_REPLACE_WITH_YOUR_PUBLIC_KEY you@your-mac"
sudo install -d -m 700 -o "$WEB_USER" -g "$WEB_USER" "/home/$WEB_USER/.ssh"
sudo touch "/home/$WEB_USER/.ssh/authorized_keys"
sudo grep -qxF "$PUBKEY" "/home/$WEB_USER/.ssh/authorized_keys" || echo "$PUBKEY" | sudo tee -a "/home/$WEB_USER/.ssh/authorized_keys" > /dev/null
sudo chown "$WEB_USER:$WEB_USER" "/home/$WEB_USER/.ssh/authorized_keys"
sudo chmod 600 "/home/$WEB_USER/.ssh/authorized_keys"
```

Generate a Git deploy key for the restricted user. Add the printed public key to your Git repository as a read-only deploy key.

```bash
: "${WEB_USER:?Run the Variables block first}"
sudo -u "$WEB_USER" ssh-keygen -t ed25519 -N "" -C "$WEB_USER@$DOMAIN_NAME" -f "/home/$WEB_USER/.ssh/id_ed25519"
sudo cat "/home/$WEB_USER/.ssh/id_ed25519.pub"
```

Create the web root. The setgid bit (`2775`) makes new files and folders inherit the `www-data` group automatically.

```bash
: "${DOMAIN_NAME:?Run the Variables block first}"
sudo mkdir -p "/var/www/$DOMAIN_NAME"
sudo chown -R "$WEB_USER:www-data" "/var/www/$DOMAIN_NAME"
sudo chmod 2775 "/var/www/$DOMAIN_NAME"
ls -ld "/var/www/$DOMAIN_NAME"
```

## PHP

```bash
sudo add-apt-repository -y ppa:ondrej/php
sudo apt update
apt-cache policy "php${PHP_VERSION:?Run the Variables block first}-fpm"
```

OPCache is built into PHP from version 8.5 onwards, so the separate `opcache` package is added only for older versions.

```bash
: "${PHP_VERSION:?Run the Variables block first}"
V="$PHP_VERSION"
EXTRA=""
dpkg --compare-versions "$V" lt 8.5 && EXTRA="php$V-opcache"
sudo apt install -y php$V-fpm php$V-cli php$V-common php$V-mysql php$V-bcmath php$V-curl \
  php$V-gd php$V-intl php$V-mbstring php$V-soap php$V-xml php$V-xsl php$V-zip php$V-gmp php$V-redis $EXTRA
php -v
```

### php.ini production settings

The settings go into separate override files, so a PHP package update never overwrites them. The web (FPM) settings are stricter than the command-line (CLI) settings.

```bash
: "${PHP_VERSION:?Run the Variables block first}"
sudo tee "/etc/php/$PHP_VERSION/fpm/conf.d/99-production.ini" > /dev/null <<'EOF'
memory_limit = 756M
max_execution_time = 300
max_input_time = 300
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
expose_php = Off
realpath_cache_size = 10M
realpath_cache_ttl = 7200
EOF
```

`opcache.validate_timestamps = 0` means PHP never checks whether code files have changed. This is the correct production setting, but after every deployment you must restart PHP-FPM (`sudo systemctl restart php8.5-fpm`), or the old code keeps running.

### PHP-FPM pool

```bash
: "${PHP_VERSION:?Run the Variables block first}"
: "${PHP_MAX_CHILDREN:?Run the Resource sizing block first}"
POOL="/etc/php/$PHP_VERSION/fpm/pool.d/www.conf"
sudo sed -i -E "s/^;?pm = .*/pm = dynamic/" "$POOL"
sudo sed -i -E "s/^;?pm\.max_children = .*/pm.max_children = $PHP_MAX_CHILDREN/" "$POOL"
sudo sed -i -E "s/^;?pm\.start_servers = .*/pm.start_servers = $PHP_START_SERVERS/" "$POOL"
sudo sed -i -E "s/^;?pm\.min_spare_servers = .*/pm.min_spare_servers = $PHP_MIN_SPARE/" "$POOL"
sudo sed -i -E "s/^;?pm\.max_spare_servers = .*/pm.max_spare_servers = $PHP_MAX_SPARE/" "$POOL"
sudo sed -i -E "s/^;?pm\.max_requests = .*/pm.max_requests = 500/" "$POOL"
sudo sed -i -E "s/^;?request_terminate_timeout = .*/request_terminate_timeout = 300/" "$POOL"
grep -E "^(pm|request_terminate_timeout)" "$POOL"

sudo "php-fpm$PHP_VERSION" -t
sudo systemctl enable --now "php$PHP_VERSION-fpm"
sudo systemctl restart "php$PHP_VERSION-fpm"
```

`pm.max_requests = 500` recycles each worker after 500 requests, which protects the server from slow memory leaks in application code.

## Nginx

```bash
sudo apt install -y nginx
nginx -v
```

Global settings: hide the Nginx version, allow 64 MB uploads, and trust the visitor IP address forwarded by Varnish and the HTTPS proxy. The `map` lets PHP know when the original request used HTTPS.

```bash
sudo tee /etc/nginx/conf.d/00-server.conf > /dev/null <<'EOF'
server_tokens off;
client_max_body_size 64m;

# Real visitor IP: requests reach the application through Varnish on 127.0.0.1
set_real_ip_from 127.0.0.1;
real_ip_header X-Forwarded-For;
real_ip_recursive on;

# Tell PHP when the visitor connected over HTTPS (TLS ends at the :443 proxy)
map $http_x_forwarded_proto $fe_https {
    default off;
    https   on;
}
EOF
```

Remove the default site. It listens on port 80, which Varnish will take over.

```bash
sudo rm -f /etc/nginx/sites-enabled/default
```

### Application vhost

The application vhost listens on `127.0.0.1:8080` only, so all public traffic must pass through Varnish. It serves the web root with PHP and is deliberately generic; replace it with your application's own Nginx configuration when you deploy the application.

```bash
: "${DOMAIN_NAME:?Run the Variables block first}"
: "${PHP_VERSION:?Run the Variables block first}"
sudo mkdir -p /var/www/letsencrypt
sudo tee "/etc/nginx/sites-available/$DOMAIN_NAME" > /dev/null <<EOF
server {
    listen 127.0.0.1:8080;
    server_name $DOMAIN_NAME www.$DOMAIN_NAME;

    root /var/www/$DOMAIN_NAME;
    index index.php index.html;

    # Let's Encrypt HTTP challenge
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
    }

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_param HTTPS \$fe_https;
        fastcgi_pass unix:/run/php/php$PHP_VERSION-fpm.sock;
        fastcgi_read_timeout 300s;
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

## MariaDB

Check which version Ubuntu provides by default (10.11 on Ubuntu 24.04):

```bash
sudo apt update
apt-cache policy mariadb-server
```

To install a different version, add MariaDB's official repository. Change `12.3` to the version you need, and check that your application supports it.

```bash
curl -LsS https://r.mariadb.com/downloads/mariadb_repo_setup | sudo bash -s -- --mariadb-server-version=12.3
sudo apt update
apt-cache policy mariadb-server
```

The Candidate line above shows the version that will be installed. If it is correct, continue.

```bash
sudo apt install -y mariadb-server
sudo systemctl enable --now mariadb
```

This command is interactive. Answer **Y** to removing anonymous users, disallowing remote root login, and removing the test database. The root account already uses Unix socket authentication, so you do not need to set a root password.

```bash
sudo mariadb-secure-installation
```

### MariaDB production settings

```bash
: "${DB_BUFFER_POOL_MB:?Run the Resource sizing block first}"
sudo tee /etc/mysql/mariadb.conf.d/99-tuning.cnf > /dev/null <<EOF
[mysqld]
# Network: local connections only
bind-address = 127.0.0.1
skip-name-resolve

# Character set
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

# InnoDB
innodb_buffer_pool_size = ${DB_BUFFER_POOL_MB}M
innodb_log_file_size = 1G
innodb_log_buffer_size = 32M
innodb_file_per_table = 1
innodb_flush_method = O_DIRECT

# Connections and temporary tables
max_connections = 200
table_open_cache = 4000
join_buffer_size = 4M
tmp_table_size = 256M
max_heap_table_size = 256M

# Compatibility settings required by common PHP applications
explicit_defaults_for_timestamp = ON
log_bin_trust_function_creators = 1

# Slow query log for performance troubleshooting
slow_query_log = 1
slow_query_log_file = /var/log/mysql/mariadb-slow.log
long_query_time = 2

# Remove binary logs older than 3 days, if binary logging is enabled
binlog_expire_logs_seconds = 259200
EOF
sudo systemctl restart mariadb
sudo mariadb -e "SELECT VERSION(); SHOW VARIABLES LIKE 'innodb_buffer_pool_size';"
```

`innodb_buffer_pool_instances` is deliberately absent. MariaDB 10.6 and later removed that option, and MariaDB 12 refuses to start if it is present.

### Application database and user

Set the database and user names when Runme asks, then run the second block. It creates the user for both `localhost` (Unix socket) and `127.0.0.1` (TCP), because `skip-name-resolve` treats these as different hosts.

```bash
export DB_NAME="appdb"
export DB_USER="appuser"
```

```bash
: "${DB_NAME:?Run the previous block first}"
DB_PASSWORD="$(openssl rand -hex 24)"
sudo mariadb <<EOF
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
CREATE USER IF NOT EXISTS '$DB_USER'@'127.0.0.1' IDENTIFIED BY '$DB_PASSWORD';
ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD';
ALTER USER '$DB_USER'@'127.0.0.1' IDENTIFIED BY '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'127.0.0.1';
FLUSH PRIVILEGES;
EOF
echo "Database: $DB_NAME"
echo "User:     $DB_USER"
echo "Password: $DB_PASSWORD"
```

Running the block again generates and sets a new password, so you can also use it to rotate the password.

## OpenSearch

Add OpenSearch's official repository. Use `3.x` or `2.x` depending on what your application supports.

```bash
curl -o- https://artifacts.opensearch.org/publickeys/opensearch-release.pgp | sudo gpg --dearmor --batch --yes -o /usr/share/keyrings/opensearch-release-keyring
echo "deb [signed-by=/usr/share/keyrings/opensearch-release-keyring] https://artifacts.opensearch.org/releases/bundle/opensearch/3.x/apt stable main" | sudo tee /etc/apt/sources.list.d/opensearch-3.x.list
sudo apt update
apt list -a opensearch
```

Set the version you want from the list above when Runme asks:

```bash
export OPENSEARCH_VERSION="3.9.0"
```

The installer requires a strong initial admin password. This block generates one, installs OpenSearch, and prevents automatic upgrades to a version your application may not support.

```bash
: "${OPENSEARCH_VERSION:?Run the previous block first}"
OPENSEARCH_PASSWORD="Os-$(openssl rand -hex 12)-A1"
sudo env OPENSEARCH_INITIAL_ADMIN_PASSWORD="$OPENSEARCH_PASSWORD" apt install -y "opensearch=$OPENSEARCH_VERSION"
sudo apt-mark hold opensearch
echo "OpenSearch admin password: $OPENSEARCH_PASSWORD"
```

### OpenSearch production settings

This block configures OpenSearch before its first start. It listens on `127.0.0.1` only, runs as a single node, uses the heap size from the sizing block, and has the security plugin disabled. Applications on this server connect over plain HTTP on localhost, which is safe only because port 9200 is never exposed. Each setting is replaced if it already exists and added if it does not, so the block is safe to run more than once.

```bash
: "${OPENSEARCH_HEAP_MB:?Run the Resource sizing block first}"
CONF=/etc/opensearch/opensearch.yml
for SETTING in "network.host: 127.0.0.1" "discovery.type: single-node" "plugins.security.disabled: true"; do
  KEY="${SETTING%%:*}"
  if sudo grep -q "^$KEY:" "$CONF"; then
    sudo sed -i "s|^$KEY:.*|$SETTING|" "$CONF"
  else
    echo "$SETTING" | sudo tee -a "$CONF" > /dev/null
  fi
done
sudo grep -E "^(network.host|discovery.type|plugins.security.disabled):" "$CONF"

printf -- "-Xms%sm\n-Xmx%sm\n" "$OPENSEARCH_HEAP_MB" "$OPENSEARCH_HEAP_MB" | sudo tee /etc/opensearch/jvm.options.d/heap.options

sudo systemctl daemon-reload
sudo systemctl enable opensearch.service
sudo systemctl restart opensearch.service
```

OpenSearch takes up to a minute to start. This block waits for it and then shows the cluster information. A JSON response with the version number means OpenSearch is running correctly.

```bash
for i in $(seq 1 30); do
  if curl -s http://127.0.0.1:9200 > /dev/null; then break; fi
  sleep 2
done
curl -s http://127.0.0.1:9200 || echo "OpenSearch is not responding. Check: sudo journalctl -u opensearch -n 50"
```

## Docker

Docker runs Valkey 9, which has no official Ubuntu package. It comes from Docker's official repository.

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io
sudo systemctl enable --now docker
sudo docker version --format 'Docker {{.Server.Version}}'
```

Docker manages its own firewall rules, and a port published as `-p 6379:6379` would be reachable from the internet even with UFW enabled. Always publish container ports as `-p 127.0.0.1:PORT:PORT`, as the blocks below do.

## Valkey 9

This block writes the Valkey configuration with a generated password and the memory limit from the sizing block. The file belongs to the container's `valkey` user (UID 999) with mode `600`, so no other account on the server can read the password.

```bash
: "${VALKEY_MEMORY_MB:?Run the Resource sizing block first}"
VALKEY_PASSWORD="$(openssl rand -hex 32)"
sudo mkdir -p /etc/valkey-docker
sudo tee /etc/valkey-docker/valkey.conf > /dev/null <<EOF
bind 0.0.0.0
protected-mode yes
port 6379
requirepass $VALKEY_PASSWORD
maxmemory ${VALKEY_MEMORY_MB}mb
maxmemory-policy allkeys-lru
EOF
sudo chown 999:999 /etc/valkey-docker/valkey.conf
sudo chmod 600 /etc/valkey-docker/valkey.conf
export VALKEY_PASSWORD
echo "Valkey password: $VALKEY_PASSWORD"
```

`bind 0.0.0.0` applies inside the container only. The `docker run` command below publishes the port on `127.0.0.1`, so Valkey is reachable from this server and nowhere else.

```bash
sudo docker run -d --name valkey --restart unless-stopped \
  -p 127.0.0.1:6379:6379 \
  -v /etc/valkey-docker/valkey.conf:/usr/local/etc/valkey/valkey.conf:ro \
  -v valkey-data:/data \
  valkey/valkey:9 valkey-server /usr/local/etc/valkey/valkey.conf
sleep 3
sudo docker logs --tail 20 valkey
```

Verify the password. The first command should fail with `NOAUTH Authentication required`, and the second should reply `PONG`.

```bash
sudo docker exec valkey valkey-cli ping
sudo docker exec valkey valkey-cli --no-auth-warning -a "${VALKEY_PASSWORD:?Run the Valkey configuration block first}" ping
sudo docker exec valkey valkey-cli --no-auth-warning -a "$VALKEY_PASSWORD" info server | grep valkey_version
```

To upgrade Valkey later, run `sudo docker pull valkey/valkey:9`, then `sudo docker rm -f valkey`, and run the `docker run` block again. The data is kept in the `valkey-data` volume.

## Varnish

Check which version Ubuntu provides by default (7.1 on Ubuntu 24.04):

```bash
apt-cache policy varnish
```

To install a newer version, add Varnish's official repository. Each release series has its own repository (for example `varnish77` for 7.7). Check [packagecloud.io/varnishcache](https://packagecloud.io/varnishcache) for the series that supports Ubuntu 24.04 (noble), then set it here:

```bash
export VARNISH_SERIES="varnish77"
```

```bash
: "${VARNISH_SERIES:?Run the previous block first}"
curl -s "https://packagecloud.io/install/repositories/varnishcache/$VARNISH_SERIES/script.deb.sh" | sudo bash
sudo tee /etc/apt/preferences.d/varnish-pin > /dev/null <<EOF
Package: varnish varnish-*
Pin: release o=packagecloud.io/varnishcache/$VARNISH_SERIES
Pin-Priority: 1000
EOF
sudo apt update
apt-cache policy varnish
```

If the Candidate version above is correct, install Varnish:

```bash
sudo apt install -y varnish
varnishd -V
```

### Varnish on port 80

This block takes the package's own start command and changes only the listening port (to 80) and the cache size, so every other packaged option stays intact. The package's default VCL already forwards requests to Nginx on `127.0.0.1:8080`.

```bash
: "${VARNISH_CACHE_MB:?Run the Resource sizing block first}"
EXEC=$(systemctl cat varnish.service | grep -m1 '^ExecStart=/' \
  | sed -E "s/-a :?[0-9]+/-a :80/; s/malloc,[0-9]+[kKmMgG]?/malloc,${VARNISH_CACHE_MB}m/")
echo "$EXEC" | grep -q -- "-a :80" || { echo "Could not set port 80. Check: systemctl cat varnish"; false; } && {
  sudo mkdir -p /etc/systemd/system/varnish.service.d
  printf "[Service]\nExecStart=\n%s\n" "$EXEC" | sudo tee /etc/systemd/system/varnish.service.d/override.conf
  sudo systemctl daemon-reload
  sudo systemctl enable varnish
  sudo systemctl restart varnish
}
```

Confirm that Varnish is answering on port 80. The response code may be 403 or 404 because the web root is still empty, which is fine; the important part is that the headers include `Via` with `varnish`.

```bash
sleep 2
sudo ss -tlnp | grep -E ':(80|8080)\b'
curl -sI -H "Host: ${DOMAIN_NAME:-localhost}" http://127.0.0.1/ | grep -iE '^(HTTP|via|x-varnish)'
```

The packaged VCL is conservative and does not cache pages for visitors with cookies, so Varnish behaves almost like a pass-through proxy until you install your application's own VCL. Do not add an HTTP-to-HTTPS redirect in Nginx while this VCL is active, because the default VCL does not include the scheme in its cache key and would serve the cached redirect to HTTPS visitors too, causing a redirect loop. Handle that redirect in the application's VCL instead.

## Composer

This uses Composer's official installer, which verifies the download's signature before installing. `--2` installs the latest stable 2.x release.

```bash
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

To pin an exact version instead, replace `--2` with `--version=2.10.0` (or the version you need).

## phpMyAdmin

phpMyAdmin is installed on `127.0.0.1:8090`, which is not reachable from the internet. You access it through an SSH tunnel, so the database login never travels over the network unencrypted, and HTTP Basic Auth adds a second password in front of it.

Change the version below to the latest release from [phpmyadmin.net](https://www.phpmyadmin.net/downloads/), and check that it supports your PHP version.

```bash
export PMA_VERSION="5.2.3"
```

The download is verified against phpMyAdmin's published SHA-256 checksum before anything is installed.

```bash
: "${PMA_VERSION:?Run the previous block first}"
cd /tmp
F="phpMyAdmin-$PMA_VERSION-english"
curl -fsSLO "https://files.phpmyadmin.net/phpMyAdmin/$PMA_VERSION/$F.tar.gz"
curl -fsSLO "https://files.phpmyadmin.net/phpMyAdmin/$PMA_VERSION/$F.tar.gz.sha256"
if sha256sum -c "$F.tar.gz.sha256"; then
  tar -xzf "$F.tar.gz"
  sudo rm -rf /usr/share/phpmyadmin
  sudo mv "$F" /usr/share/phpmyadmin
  sudo chown -R root:root /usr/share/phpmyadmin
  sudo install -d -m 700 -o www-data -g www-data /usr/share/phpmyadmin/tmp
else
  echo "Checksum mismatch. phpMyAdmin was NOT installed."
fi
rm -f "$F.tar.gz" "$F.tar.gz.sha256"
```

Write the configuration with a generated encryption secret:

```bash
SECRET="$(openssl rand -hex 32)"
sudo tee /usr/share/phpmyadmin/config.inc.php > /dev/null <<EOF
<?php
\$cfg['blowfish_secret'] = sodium_hex2bin('$SECRET');

\$i = 0;
\$i++;
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
\$cfg['Servers'][\$i]['host'] = 'localhost';
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
: "${PHP_VERSION:?Run the Variables block first}"
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
        fastcgi_pass unix:/run/php/php$PHP_VERSION-fpm.sock;
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

To open phpMyAdmin, run this on your Mac (with your own key and server address), keep the terminal open, and browse to `http://localhost:8090`:

```text
ssh -i ~/.ssh/YOUR_KEY.pem -N -L 8090:127.0.0.1:8090 ubuntu@SERVER_IP
```

Log in with the application database user created in the MariaDB section. The MariaDB root account uses Unix socket authentication and cannot log in through phpMyAdmin, which is intentional.

## HTTPS with Let's Encrypt

Run this section only after the domain's DNS points to this server and port 80 is open in the security group. Nginx terminates HTTPS on port 443 and passes requests to Varnish on port 80.

```bash
dig +short "${DOMAIN_NAME:?Run the Variables block first}"
curl -s https://checkip.amazonaws.com
```

The two addresses above must match. If they do, request the certificate:

```bash
: "${DOMAIN_NAME:?Run the Variables block first}"
sudo apt install -y certbot
sudo certbot certonly --webroot -w /var/www/letsencrypt \
  -d "$DOMAIN_NAME" \
  --email "$ADMIN_EMAIL" --agree-tos --no-eff-email \
  --deploy-hook "systemctl reload nginx"
```

To include `www`, add `-d "www.$DOMAIN_NAME"` to the command, but only once DNS for `www` also points to this server.

```bash
: "${DOMAIN_NAME:?Run the Variables block first}"
sudo tee "/etc/nginx/sites-available/$DOMAIN_NAME-ssl" > /dev/null <<EOF
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN_NAME www.$DOMAIN_NAME;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    add_header Strict-Transport-Security "max-age=31536000" always;

    location / {
        proxy_pass http://127.0.0.1:80;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Port 443;
        proxy_read_timeout 300s;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
    }
}
EOF
sudo ln -sf "/etc/nginx/sites-available/$DOMAIN_NAME-ssl" "/etc/nginx/sites-enabled/$DOMAIN_NAME-ssl"
sudo nginx -t && sudo systemctl reload nginx
```

Certificates renew automatically through the `certbot.timer` service. This command tests renewal without changing anything:

```bash
sudo certbot renew --dry-run
```

If you use Cloudflare in front of the server instead, set Cloudflare's SSL mode to **Full (strict)**. That mode still needs a valid certificate on the server, either from this section or a Cloudflare Origin Certificate.

## Security hardening

### Firewall (UFW)

SSH is allowed before the firewall is enabled, so the current session is not cut off.

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable
sudo ufw status verbose
```

Do not open 8080 (Nginx behind Varnish), 8090 (phpMyAdmin), 3306 (MariaDB), 6379 (Valkey), or 9200 (OpenSearch). They all listen on `127.0.0.1` only.

### SSH hardening

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

### Fail2ban

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
sudo systemctl enable --now fail2ban
sudo systemctl restart fail2ban
sudo fail2ban-client status sshd
```

### Automatic security updates

This enables Ubuntu's unattended security updates. By default, they cover Ubuntu's own packages only, so MariaDB, OpenSearch, Varnish, and Docker are never upgraded behind your back.

```bash
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -f noninteractive unattended-upgrades
systemctl is-enabled unattended-upgrades
```

## Final verification

Every service should report `active`:

```bash
for S in nginx "php${PHP_VERSION:?Run the Variables block first}-fpm" mariadb opensearch docker varnish fail2ban; do
  printf "%-16s %s\n" "$S" "$(systemctl is-active "$S")"
done
printf "%-16s %s\n" "valkey" "$(sudo docker inspect -f '{{.State.Status}}' valkey)"
```

Check the listening ports. Only 22, 80, and 443 should be bound to `0.0.0.0` or `[::]`; everything else must show `127.0.0.1`.

```bash
sudo ss -tlnp | awk 'NR==1 || /LISTEN/' | awk '{print $4, $6}' | column -t
```

## Optional: an old MySQL version in Docker

Use this only if an application needs a MySQL version that is no longer packaged for Ubuntu 24.04. The container listens on `127.0.0.1:3307` and keeps its data in a named volume. With `--restart unless-stopped`, it starts again automatically after a reboot.

```bash
OLD_MYSQL_PASSWORD="$(openssl rand -hex 24)"
sudo docker run -d --name oldmysql --restart unless-stopped \
  -p 127.0.0.1:3307:3306 \
  -e MYSQL_ROOT_PASSWORD="$OLD_MYSQL_PASSWORD" \
  -v oldmysql-data:/var/lib/mysql \
  mysql:5.7
echo "MySQL 5.7 root password: $OLD_MYSQL_PASSWORD"
```

To manage it in phpMyAdmin, add this second server to `/usr/share/phpmyadmin/config.inc.php`, just above the `TempDir` line:

```bash
sudo nano /usr/share/phpmyadmin/config.inc.php
```

```text
$i++;
$cfg['Servers'][$i]['auth_type'] = 'cookie';
$cfg['Servers'][$i]['host'] = '127.0.0.1';
$cfg['Servers'][$i]['port'] = '3307';
$cfg['Servers'][$i]['compress'] = false;
$cfg['Servers'][$i]['AllowNoPassword'] = false;
$cfg['Servers'][$i]['verbose'] = 'MySQL 5.7';
```
