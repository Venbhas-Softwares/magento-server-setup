# Module 13 — Nginx final test/restart, config persistence, info file, summary
# Uses: all variables set by main script and earlier modules

nginx -t
systemctl restart nginx
systemctl enable  nginx

# Persist generated values back to the config file for reference
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

if [[ "$ENABLE_SSL_TERMINATION" == "yes" ]]; then
    SSL_PORT_LINE="443 (Nginx SSL terminator → Varnish :80)"
    if [[ -n "$SSL_CERT_PATH" ]]; then
        SSL_INFO_BLOCK="SSL Configuration:
- Mode:        Operator-supplied certificate
- Certificate: /etc/nginx/ssl/cloudflare.crt (installed from ${SSL_CERT_PATH})
- Key:         /etc/nginx/ssl/cloudflare.key"
    else
        SSL_INFO_BLOCK="SSL Configuration (Cloudflare):
- Mode:        Full (self-signed origin certificate)
- Certificate: /etc/nginx/ssl/cloudflare.crt
- Key:         /etc/nginx/ssl/cloudflare.key
- Upgrade:     Replace cert/key with a Cloudflare Origin Certificate for Full (Strict),
               or set SSL_CERT_PATH/SSL_KEY_PATH in the config and re-run: --modules=11"
    fi
else
    SSL_PORT_LINE="Not configured on this server (ENABLE_SSL_TERMINATION=no)"
    SSL_INFO_BLOCK="SSL Configuration:
- Nginx SSL termination is DISABLED (ENABLE_SSL_TERMINATION=no)
- Varnish is the sole HTTP-facing service, on port 80
- TLS must be terminated upstream of this server (e.g. Cloudflare Flexible mode,
  an external load balancer, or another CDN)"
fi

INFO_FILE="${SCRIPT_DIR}/server_setup_info.txt"
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
- Username: $RESTRICTED_USERNAME
- Home Directory: /home/${RESTRICTED_USERNAME}
- SSH Access: Enabled (key-based authentication only, via RESTRICTED_USER_SSH_PUBLIC_KEY)
- Access Method: ssh ${RESTRICTED_USERNAME}@YOUR_SERVER_IP -i /path/to/your/private/key (or su - ${RESTRICTED_USERNAME} from root)
- Permissions: NO sudo access (truly restricted for application use only)
- Purpose: Running Magento application and managing application files
- Git Deploy Key (public): ${RESTRICTED_USER_SSH_PUBKEY}

Root User (Administrative Access):
- SSH Key: Configured (key-based authentication only)
- Password Authentication: DISABLED
- Purpose: Administrative server management tasks

Software Versions:
- PHP: ${PHP_VERSION}
- MariaDB: $(mariadb --version | awk '{print $5}' | cut -d- -f1)
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
- Connection: mariadb -uroot -p

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
- HTTPS: ${SSL_PORT_LINE}
- Nginx Backend: 8080 (behind Varnish)
- phpMyAdmin: ${PMA_PORT}
- Varnish Admin Console: 6082 (localhost only)
- OpenSearch: 9200 (localhost only)
- Valkey: 6379 (localhost only)
- MariaDB: 3306 (localhost only)

${SSL_INFO_BLOCK}

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
- After deploying your application: export VCL from its admin panel and review default.vcl

Next Steps:
1. Point your domain's DNS through Cloudflare (orange cloud icon enabled).
   In Cloudflare Dashboard → SSL/TLS → set mode to "Full".
   (Use "Full (Strict)" after replacing the cert with a Cloudflare Origin Certificate.)
2. Deploy your application to ${MAGENTO_DIR} as the restricted user, then add
   its `include ${MAGENTO_DIR}/nginx.conf;` line to the vhost and reload Nginx:
   ssh root@YOUR_SERVER_IP -i /path/to/your/private/key
   su - ${RESTRICTED_USERNAME}
3. After deployment:
   a. Configure Varnish as the caching backend in your application
   b. Export and review /etc/varnish/default.vcl
   c. Test cache hit rate: varnishstat
4. Access phpMyAdmin at the URL above

Security Notes:
- Password authentication is COMPLETELY DISABLED (SSH key only)
- Root SSH login: ALLOWED via SSH key authentication only
- Restricted user SSH login: ALLOWED via SSH key authentication only (full shell, no sudo)
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

- Application User Access (direct SSH, or switch from root):
  ssh ${RESTRICTED_USERNAME}@YOUR_SERVER_IP -i /path/to/your/private/key
  su - ${RESTRICTED_USERNAME}

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
print_warning "✓ Restricted user SSH login is ONLY allowed via SSH key (from config)"
print_warning "✓ Restricted user has ZERO sudo access (true privilege separation)"
echo ""
