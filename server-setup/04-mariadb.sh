# Module 04 — MariaDB installation, hardening, and Magento optimisation
# Uses: MARIADB_VERSION, MARIADB_ROOT_PASSWORD, TOTAL_RAM_GB

print_step "Adding official MariaDB repository (${MARIADB_VERSION})..."
apt install -y apt-transport-https curl

curl -fsSL "https://downloads.mariadb.com/MariaDB/mariadb_repo_setup" \
    | bash -s -- --mariadb-server-version="mariadb-${MARIADB_VERSION}" --skip-maxscale

print_step "Installing MariaDB ${MARIADB_VERSION}..."
apt install -y mariadb-server mariadb-client

systemctl start  mariadb
systemctl enable mariadb

print_step "Securing MariaDB installation..."
MYSQL_CREDS="/tmp/.my.cnf.tmp.$$"
add_temp_file "$MYSQL_CREDS"
cat > "$MYSQL_CREDS" <<MYCNF
[client]
user=root
password='${MARIADB_ROOT_PASSWORD}'
MYCNF
chmod 600 "$MYSQL_CREDS"

mysql --defaults-file="$MYSQL_CREDS" <<MYSQLEOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MARIADB_ROOT_PASSWORD}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
MYSQLEOF

print_step "Optimizing MariaDB configuration..."
cat > /etc/mysql/mariadb.conf.d/99-magento.cnf <<EOF
[mysqld]
# Magento Optimizations

# InnoDB Settings
innodb_buffer_pool_size = $((TOTAL_RAM_GB * 512))M
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

# Query Cache (disabled)
query_cache_type = 0
query_cache_size = 0

# Character set
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

# Magento Required Settings
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

systemctl restart mariadb
