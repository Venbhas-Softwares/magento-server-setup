# Module 11 — Nginx final test/restart, config persistence, info file, summary
# Uses: all variables set by main script and earlier modules

nginx -t
systemctl restart nginx
systemctl enable  nginx

# Persist generated values back to the config file so install-magento.sh can read them
print_step "Saving generated values to configuration file..."
cat >> "$CONFIG_FILE" <<EOF

# ============================================================
# GENERATED VALUES - Do NOT edit these manually
# ============================================================
# Generated on: $(date)
PMA_PATH="${PMA_PATH}"
MAGENTO_DIR="${MAGENTO_DIR}"
EOF

# ── Server info file ──────────────────────────────────────────────────────────

INFO_FILE="/root/server_setup_info.txt"
cat > "$INFO_FILE" <<EOF
============================================================================
Magento Server Setup Complete!
============================================================================

Installation Date: $(date)
Architecture: $ARCH
System Resources: ${TOTAL_RAM_GB}GB RAM, ${CPU_CORES} CPU cores

Domain: $DOMAIN_NAME
Magento Directory: $MAGENTO_DIR

Restricted User (Application User):
- Username: $RESTRICTED_USER
- Home Directory: /home/${RESTRICTED_USER}
- SSH Access: NONE (no direct SSH login)
- Access Method: su - ${RESTRICTED_USER} (from root session)
- Permissions: NO sudo access (truly restricted for application use only)
- Purpose: Running Magento application and managing application files

Root User (Administrative Access):
- SSH Key: Configured (key-based authentication only)
- Password Authentication: DISABLED
- Purpose: Administrative server management tasks

Software Versions:
- PHP: ${PHP_VERSION}
- MariaDB: $(mysql --version | awk '{print $5}' | cut -d- -f1)
- OpenSearch: ${OPENSEARCH_VERSION}
- Composer: ${COMPOSER_VERSION}
- Nginx: $(nginx -v 2>&1 | cut -d/ -f2)
- Valkey: $(valkey-server --version | awk '{print $3}' | cut -d= -f2)
- Varnish: $(varnishd -V 2>&1 | head -1 | awk '{print $2}')

PHP Configuration:
- Memory Limit: ${PHP_MEMORY_LIMIT}
- Max Children: ${PHP_MAX_CHILDREN}
- Start Servers: ${PHP_START_SERVERS}
- Min Spare: ${PHP_MIN_SPARE}
- Max Spare: ${PHP_MAX_SPARE}

Database Information:
- MariaDB Root Password: [STORED SECURELY IN CONFIG]
- Connection: mysql -uroot -p

phpMyAdmin Access:
- URL: http://YOUR_SERVER_IP:${PMA_PORT}/${PMA_PATH}
- Username: ${PMA_USERNAME}
- Password: [STORED SECURELY IN CONFIG]
- Note: Protected with HTTP Basic Authentication

Services Status:
- Nginx: Installed and Running (Port 8080, behind Varnish)
- PHP ${PHP_VERSION}-FPM: Installed and Running
- MariaDB: Installed and Running
- OpenSearch ${OPENSEARCH_VERSION}: Installed and Running
- Valkey: Installed and Running
- Varnish Cache: Installed and Running (Port 80)

Service Ports:
- HTTP (Varnish Cache): 80
- HTTPS: 443
- Nginx Backend: 8080 (behind Varnish)
- phpMyAdmin: ${PMA_PORT}
- Varnish Admin Console: 6082 (localhost only)
- OpenSearch: 9200 (localhost only)
- Valkey: 6379 (localhost only)
- MariaDB: 3306 (localhost only)

Important Paths:
- Magento Root: ${MAGENTO_DIR}
- PHP Config: /etc/php/${PHP_VERSION}/fpm/php.ini
- Nginx Config: /etc/nginx/
- Varnish Config: /etc/varnish/default.vcl
- MariaDB Config: /etc/mysql/
- OpenSearch: /opt/opensearch/
- phpMyAdmin: ${PMA_INSTALL_DIR}
- Logs: /var/log/

Varnish Cache Information:
- Config File: /etc/varnish/default.vcl
- Cache Memory: 256MB
- Status: Listening on port 80, Nginx backend on port 8080
- After Magento install: export VCL from admin panel and review default.vcl

Next Steps:
1. Run install-magento.sh as the ${RESTRICTED_USER} user:
   ssh root@YOUR_SERVER_IP -i /path/to/your/private/key
   su - ${RESTRICTED_USER}
   bash install-magento.sh
2. After Magento installation:
   a. Configure Varnish as caching backend in Magento admin
   b. Export and review /etc/varnish/default.vcl
   c. Test cache hit rate: varnishstat
3. Access phpMyAdmin at the URL above
4. Configure DNS to point your domain to this server

Security Notes:
- Password authentication is COMPLETELY DISABLED (SSH key only)
- Root SSH login: ALLOWED via SSH key authentication only
- Restricted user has NO direct SSH access (su - only)
- Restricted user has ZERO sudo access (true privilege separation)
- phpMyAdmin is on a non-standard port with randomised URL path
- All sensitive services are bound to localhost only
- Firewall is configured with UFW
- Varnish PURGE requests restricted to localhost only
- Nginx is behind Varnish and not directly exposed
- Keep this file secure and delete after noting information

Login Instructions:
- Root/Admin Access (use your SSH private key):
  ssh root@YOUR_SERVER_IP -i /path/to/your/private/key

- Application User Access (switch from root):
  su - ${RESTRICTED_USER}

============================================================================
EOF

# ── Completion message ────────────────────────────────────────────────────────

clear
echo "============================================================================"
echo "          Server Setup Complete!"
echo "============================================================================"
echo ""
cat "$INFO_FILE"
echo ""
print_message "Setup information saved to: $INFO_FILE"
print_message "Please save this information securely and delete the file when done."
echo ""
print_warning "IMPORTANT SECURITY CONFIGURATION:"
print_warning "✓ Password authentication is DISABLED for all users"
print_warning "✓ Root login is ONLY allowed via SSH key (from config)"
print_warning "✓ Restricted user has NO direct SSH access (su - only)"
print_warning "✓ Restricted user has ZERO sudo access (true privilege separation)"
echo ""
print_message "You can now run install-magento.sh as the ${RESTRICTED_USER} user."
echo ""
print_message "Next Steps:"
print_message "1. SSH in as root: ssh root@YOUR_SERVER_IP -i /path/to/your/private/key"
print_message "2. Switch to app user: su - ${RESTRICTED_USER}"
print_message "3. Run install-magento.sh as the ${RESTRICTED_USER} user"
echo ""
