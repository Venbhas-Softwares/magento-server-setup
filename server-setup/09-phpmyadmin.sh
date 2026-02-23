# Module 09 — phpMyAdmin tarball installation and Nginx configuration
# Uses: PMA_PORT, PMA_USERNAME, PMA_PASSWORD, PHP_VERSION, MARIADB_ROOT_PASSWORD
# Sets: PMA_PATH, PMA_INSTALL_DIR (both used by module 11-finalize)

# ── Random URL path ───────────────────────────────────────────────────────────

PMA_PATH=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 32)
print_message "phpMyAdmin URL path: /${PMA_PATH}"

# ── Installation ──────────────────────────────────────────────────────────────

PMA_VERSION="5.2.3"
PMA_INSTALL_DIR="/usr/share/phpmyadmin${PMA_PATH}"
PMA_TARBALL="phpMyAdmin-${PMA_VERSION}-english.tar.gz"
PMA_TARBALL_PATH="/tmp/${PMA_TARBALL}"
PMA_CHECKSUM_PATH="/tmp/${PMA_TARBALL}.sha256"

add_temp_file "$PMA_TARBALL_PATH"
add_temp_file "$PMA_CHECKSUM_PATH"

print_step "Downloading phpMyAdmin ${PMA_VERSION}..."
if ! wget -q "https://files.phpmyadmin.net/phpMyAdmin/${PMA_VERSION}/${PMA_TARBALL}" \
        -O "$PMA_TARBALL_PATH"; then
    print_error "Failed to download phpMyAdmin"
    exit 1
fi

print_message "Verifying phpMyAdmin integrity..."
if ! wget -q "https://files.phpmyadmin.net/phpMyAdmin/${PMA_VERSION}/${PMA_TARBALL}.sha256" \
        -O "$PMA_CHECKSUM_PATH"; then
    print_error "Failed to download phpMyAdmin checksum"
    exit 1
fi

EXPECTED_HASH=$(awk '{print $1}' "$PMA_CHECKSUM_PATH")
ACTUAL_HASH=$(sha256sum "$PMA_TARBALL_PATH" | awk '{print $1}')
if [ -z "$EXPECTED_HASH" ] || [ "$EXPECTED_HASH" != "$ACTUAL_HASH" ]; then
    print_error "phpMyAdmin checksum verification FAILED — possible corruption or tampering"
    exit 1
fi
print_message "phpMyAdmin integrity verified successfully"

print_message "Installing phpMyAdmin to ${PMA_INSTALL_DIR}..."
tar -xzf "$PMA_TARBALL_PATH" -C /tmp
mv "/tmp/phpMyAdmin-${PMA_VERSION}-english" "$PMA_INSTALL_DIR"

# Required writable cache directory
mkdir -p "${PMA_INSTALL_DIR}/tmp"
chmod 777 "${PMA_INSTALL_DIR}/tmp"

print_message "Creating phpMyAdmin configuration tables..."
MYSQL_PWD="${MARIADB_ROOT_PASSWORD}" mariadb -uroot < "${PMA_INSTALL_DIR}/sql/create_tables.sql"

print_message "Configuring phpMyAdmin..."
PMA_BLOWFISH=$(openssl rand -base64 24)
cat > "${PMA_INSTALL_DIR}/config.inc.php" <<PMAEOF
<?php
\$cfg['blowfish_secret'] = '${PMA_BLOWFISH}';
\$i = 0;
\$i++;
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
\$cfg['Servers'][\$i]['host'] = 'localhost';
\$cfg['Servers'][\$i]['compress'] = false;
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;
\$cfg['UploadDir'] = '';
\$cfg['SaveDir'] = '';
\$cfg['TempDir'] = '${PMA_INSTALL_DIR}/tmp';
?>
PMAEOF

chown -R www-data:www-data "$PMA_INSTALL_DIR"
chmod -R 755 "$PMA_INSTALL_DIR"
chmod 660 "${PMA_INSTALL_DIR}/config.inc.php"
chmod 777 "${PMA_INSTALL_DIR}/tmp"

# apache2-utils provides htpasswd; php-gettext provides phpMyAdmin translations
apt install -y apache2-utils php${PHP_VERSION}-gettext
htpasswd -cb /etc/nginx/.htpasswd_pma "${PMA_USERNAME}" "${PMA_PASSWORD}"

print_step "Configuring phpMyAdmin Nginx virtual host on port ${PMA_PORT}..."
cat > /etc/nginx/sites-available/phpmyadmin <<EOF
server {
    listen ${PMA_PORT};
    server_name _;

    root ${PMA_INSTALL_DIR};
    index index.php;

    # Randomised URL path for security — direct access to / is denied
    location /${PMA_PATH} {
        alias ${PMA_INSTALL_DIR};
        index index.php;

        auth_basic "Restricted Access";
        auth_basic_user_file /etc/nginx/.htpasswd_pma;

        location ~ ^/${PMA_PATH}/(.+\.php)$ {
            alias ${PMA_INSTALL_DIR}/\$1;
            fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
            fastcgi_index index.php;
            fastcgi_param SCRIPT_FILENAME ${PMA_INSTALL_DIR}/\$1;
            include fastcgi_params;
        }

        location ~* ^/${PMA_PATH}/(.+\.(jpg|jpeg|gif|css|png|js|ico|html|xml|txt))$ {
            alias ${PMA_INSTALL_DIR}/\$1;
        }
    }

    location / {
        deny all;
    }

    add_header X-Frame-Options "DENY" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
}
EOF

ln -sf /etc/nginx/sites-available/phpmyadmin /etc/nginx/sites-enabled/
