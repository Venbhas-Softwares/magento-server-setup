# Module database — Database engine installation, hardening, and performance tuning
# Uses: DB_ENABLED, DB_ENGINE, DB_VERSION, DB_ROOT_PASSWORD,
#       MARIADB_BUFFER_POOL_MB (set by lib/functions.sh::calculate_resource_allocations)
# Sets: DB_CLI, DB_SERVICE, DB_BACKEND (used by modules phpmyadmin and finalize)

if [[ "${DB_ENABLED:-yes}" != "yes" ]]; then
    print_message "DB_ENABLED=no — skipping database installation"
    DB_CLI=""
    DB_SERVICE=""
    DB_BACKEND=""
    return 0
fi

DOCKER_MYSQL_CONTAINER="mysql-legacy"
DOCKER_MYSQL_DATA_DIR="/var/lib/docker-mysql-legacy/data"
DOCKER_MYSQL_CONF_DIR="/var/lib/docker-mysql-legacy/conf.d"

# Shared performance tuning file, used by every backend (native MariaDB, native
# MySQL, and the Dockerised legacy MySQL below). Query cache was removed
# entirely from MySQL in 8.0 (an unknown variable in the config file is fatal
# at startup, not just a warning) but still exists in MariaDB and in MySQL
# 5.6/5.7 — so it's included for those, and only those.
write_db_tuning_cnf() {
    local out_dir="$1"
    local include_query_cache="$2"
    local query_cache_block=""
    if [[ "$include_query_cache" == "yes" ]]; then
        query_cache_block="
# Query Cache (disabled)
query_cache_type = 0
query_cache_size = 0
"
    fi
    mkdir -p "$out_dir"
    cat > "${out_dir}/99-tuning.cnf" <<EOF
[mysqld]
# Performance tuning

# InnoDB Settings
innodb_buffer_pool_size = ${MARIADB_BUFFER_POOL_MB}M
innodb_buffer_pool_instances = 6
innodb_log_file_size = 1G
innodb_log_buffer_size = 32M
innodb_file_per_table = 1
innodb_flush_method = O_DIRECT
innodb_flush_log_at_trx_commit = 2

# Connection Settings
max_connections = 500
table_open_cache = 1024
join_buffer_size = 4M
tmp_table_size = 256M
max_heap_table_size = 256M
${query_cache_block}
# Character set
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

# Required by common PHP application frameworks (Magento, WordPress, etc.)
explicit_defaults_for_timestamp = ON
log_bin_trust_function_creators = 1

# Performance
skip-name-resolve
bind-address = 127.0.0.1

# Timeouts
wait_timeout = 300
interactive_timeout = 300

# Binary Log
binlog_expire_logs_seconds = 259200
EOF
}

# ── MySQL 5.6/5.7 — Docker, not apt ──────────────────────────────────────────
# Oracle's official apt repo for Ubuntu 24.04 (noble) only ships mysql-8.0 and
# mysql-8.4-lts — 5.6/5.7 were dropped years ago, and those old builds predate
# the OpenSSL/glibc this OS ships, so a native/manual install would be
# unreliable even if forced. The official mysql:5.6/mysql:5.7 Docker images
# still work fine, since a container brings its own userland instead of
# depending on the host's — that's the install path used here instead.
install_legacy_mysql_via_docker() {
    DB_BACKEND="docker"
    DB_SERVICE=""
    DB_CLI="/usr/local/bin/db-cli"

    if ! command -v docker &>/dev/null; then
        print_step "Installing Docker (required for MySQL ${DB_VERSION}, which Ubuntu 24.04 can't install natively)..."
        apt install -y docker.io
        systemctl enable --now docker
    fi

    mkdir -p "$DOCKER_MYSQL_DATA_DIR" "$DOCKER_MYSQL_CONF_DIR"
    write_db_tuning_cnf "$DOCKER_MYSQL_CONF_DIR" "yes"

    print_step "Pulling mysql:${DB_VERSION} (official image)..."
    docker pull "mysql:${DB_VERSION}"

    if docker ps -a --format '{{.Names}}' | grep -qx "$DOCKER_MYSQL_CONTAINER"; then
        print_message "Container ${DOCKER_MYSQL_CONTAINER} already exists — starting it."
        docker start "$DOCKER_MYSQL_CONTAINER" >/dev/null
    else
        print_step "Starting MySQL ${DB_VERSION} in Docker (127.0.0.1:3306 only)..."
        # Bound to 127.0.0.1 specifically, not 0.0.0.0: Docker manages its own
        # iptables/nftables rules and a wide publish can bypass UFW entirely.
        # A loopback-only publish isn't reachable from outside the host either
        # way, matching the native installs' bind-address=127.0.0.1 model.
        docker run -d \
            --name "$DOCKER_MYSQL_CONTAINER" \
            --restart unless-stopped \
            -p 127.0.0.1:3306:3306 \
            -e MYSQL_ROOT_PASSWORD="${DB_ROOT_PASSWORD}" \
            -v "${DOCKER_MYSQL_DATA_DIR}:/var/lib/mysql" \
            -v "${DOCKER_MYSQL_CONF_DIR}:/etc/mysql/conf.d:ro" \
            "mysql:${DB_VERSION}"
    fi

    print_message "Waiting for MySQL ${DB_VERSION} to become ready (first boot can take a minute)..."
    local ready=0
    for _ in $(seq 1 60); do
        # TCP-targeted, not the default socket: on first init the image runs a
        # temporary instance on a socket only, so this only succeeds once the
        # real, final instance is actually listening — avoids the classic
        # "ready for connections appears twice in the logs" false-positive.
        if docker exec "$DOCKER_MYSQL_CONTAINER" \
                mysqladmin ping -h127.0.0.1 -P3306 -uroot -p"${DB_ROOT_PASSWORD}" --silent &>/dev/null; then
            ready=1
            break
        fi
        sleep 2
    done
    if [[ $ready -ne 1 ]]; then
        print_error "MySQL ${DB_VERSION} container did not become ready within 120s"
        print_error "Check its logs: docker logs ${DOCKER_MYSQL_CONTAINER}"
        exit 1
    fi

    print_step "Securing MySQL ${DB_VERSION} installation..."
    # No ALTER USER/SET PASSWORD here: the image's entrypoint already applied
    # MYSQL_ROOT_PASSWORD at initialization (and ALTER USER doesn't exist in
    # MySQL 5.6 — it was added in 5.7.6 — so this also sidesteps that split).
    docker exec -i -e MYSQL_PWD="${DB_ROOT_PASSWORD}" "$DOCKER_MYSQL_CONTAINER" mysql -uroot <<SQLEOF
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQLEOF

    # Drop-in executable so phpmyadmin.sh and finalize.sh can call "$DB_CLI"
    # exactly like they would a native `mysql`/`mariadb` binary, including
    # MYSQL_PWD=... "$DB_CLI" ... — docker exec doesn't inherit the caller's
    # environment on its own, so forward MYSQL_PWD through explicitly.
    cat > /usr/local/bin/db-cli <<WRAP
#!/bin/bash
exec docker exec -i \${MYSQL_PWD:+-e MYSQL_PWD="\$MYSQL_PWD"} ${DOCKER_MYSQL_CONTAINER} mysql "\$@"
WRAP
    chmod +x /usr/local/bin/db-cli

    print_message "MySQL ${DB_VERSION} running in Docker container '${DOCKER_MYSQL_CONTAINER}', bound to 127.0.0.1:3306"
    print_message "Data persisted at ${DOCKER_MYSQL_DATA_DIR} — back this up the same way you would /var/lib/mysql"
}

if [[ "$DB_ENGINE" == "mysql" ]] && [[ "$DB_VERSION" == "5.6" || "$DB_VERSION" == "5.7" ]]; then
    install_legacy_mysql_via_docker
    return 0
fi

if [[ "$DB_ENGINE" == "mysql" ]]; then
    DB_BACKEND="native"
    DB_CLI="mysql"
    DB_SERVICE="mysql"
    DB_CONF_DIR="/etc/mysql/mysql.conf.d"

    case "$DB_VERSION" in
        8.0) DB_APT_COMPONENT="mysql-8.0" ;;
        8.4) DB_APT_COMPONENT="mysql-8.4-lts" ;;
        *)
            print_error "Unsupported DB_VERSION '${DB_VERSION}' for DB_ENGINE=mysql"
            exit 1
            ;;
    esac

    print_step "Adding official MySQL APT repository (${DB_VERSION})..."
    apt install -y apt-transport-https curl gnupg

    MYSQL_GPG_KEYRING="/usr/share/keyrings/mysql-apt.gpg"
    if ! gpg --no-default-keyring --keyring "$MYSQL_GPG_KEYRING" \
            --keyserver keyserver.ubuntu.com --recv-keys A8D3785C; then
        print_error "Failed to fetch the MySQL APT repository signing key"
        exit 1
    fi
    echo "deb [signed-by=${MYSQL_GPG_KEYRING}] http://repo.mysql.com/apt/ubuntu/ noble ${DB_APT_COMPONENT}" \
        > /etc/apt/sources.list.d/mysql.list
    apt update

    print_step "Installing MySQL ${DB_VERSION}..."
    debconf-set-selections <<< "mysql-community-server mysql-community-server/root-password password ${DB_ROOT_PASSWORD}"
    debconf-set-selections <<< "mysql-community-server mysql-community-server/re-root-password password ${DB_ROOT_PASSWORD}"
    DEBIAN_FRONTEND=noninteractive apt install -y mysql-server mysql-client
else
    DB_BACKEND="native"
    DB_CLI="mariadb"
    DB_SERVICE="mariadb"
    DB_CONF_DIR="/etc/mysql/mariadb.conf.d"

    print_step "Adding official MariaDB repository (${DB_VERSION})..."
    apt install -y apt-transport-https curl

    curl -fsSL "https://downloads.mariadb.com/MariaDB/mariadb_repo_setup" \
        | bash -s -- --mariadb-server-version="mariadb-${DB_VERSION}" --skip-maxscale

    print_step "Installing MariaDB ${DB_VERSION}..."
    apt install -y mariadb-server mariadb-client
fi

systemctl start  "$DB_SERVICE"
systemctl enable "$DB_SERVICE"

print_step "Securing ${DB_ENGINE} installation..."
DB_CREDS_FILE="/tmp/.my.cnf.tmp.$$"
add_temp_file "$DB_CREDS_FILE"
cat > "$DB_CREDS_FILE" <<MYCNF
[client]
user=root
password='${DB_ROOT_PASSWORD}'
MYCNF
chmod 600 "$DB_CREDS_FILE"

"$DB_CLI" --defaults-file="$DB_CREDS_FILE" <<SQLEOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQLEOF

print_step "Optimizing ${DB_ENGINE} configuration..."
write_db_tuning_cnf "$DB_CONF_DIR" "$([[ "$DB_ENGINE" == "mariadb" ]] && echo yes || echo no)"

systemctl restart "$DB_SERVICE"
