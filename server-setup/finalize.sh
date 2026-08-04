# Module finalize — Nginx final test/restart, config persistence, info file, summary
# Uses: all variables set by main script and earlier modules

nginx -t
systemctl restart nginx
systemctl enable  nginx

# Persist generated values back to the config file for reference
print_step "Saving generated values to configuration file..."
{
    echo ""
    echo "# ============================================================"
    echo "# GENERATED VALUES - Do NOT edit these manually"
    echo "# ============================================================"
    echo "# Generated on: $(date)"
    [[ "${PHPMYADMIN_ENABLED:-yes}" == "yes" ]] && echo "PMA_PATH=\"${PMA_PATH}\""
    echo "WEB_ROOT=\"${WEB_ROOT}\""
} >> "$CONFIG_FILE"

# ── Resolve actual installed versions/status for the summary ─────────────────

if [[ "${DB_ENABLED:-yes}" == "yes" ]]; then
    # $DB_CLI is a real callable in both cases — a native mysql/mariadb binary,
    # or the db-cli wrapper proxying into the Docker container — so one
    # --version call works uniformly instead of branching per engine/backend.
    DB_VERSION_ACTUAL=$("$DB_CLI" --version | grep -oP '\d+\.\d+\.\d+' | head -1)
    DB_BACKEND_NOTE=""
    DB_PATH_LINE="- Database Config: /etc/mysql/"
    if [[ "$DB_BACKEND" == "docker" ]]; then
        DB_BACKEND_NOTE=" (via Docker — ${DB_ENGINE} ${DB_VERSION} isn't available natively on Ubuntu 24.04)"
        DB_PATH_LINE="- Database Data: ${DOCKER_MYSQL_DATA_DIR} (Docker volume, container: ${DOCKER_MYSQL_CONTAINER})"
    fi
    DB_SOFTWARE_LINE="- Database: ${DB_ENGINE} ${DB_VERSION_ACTUAL}${DB_BACKEND_NOTE}"
    DB_INFO_BLOCK="Database Information:
- Engine: ${DB_ENGINE}${DB_BACKEND_NOTE}
- Root Password: [STORED SECURELY IN CONFIG]
- Connection: ${DB_CLI} -uroot -p"
    DB_STATUS_LINE="- Database (${DB_ENGINE}): Installed and Running${DB_BACKEND_NOTE}"
    DB_PORT_LINE="- Database: 3306 (localhost only)"
else
    DB_SOFTWARE_LINE="- Database: Disabled (DB_ENABLED=no)"
    DB_INFO_BLOCK="Database Information:
- Disabled (DB_ENABLED=no)"
    DB_STATUS_LINE="- Database: Disabled (DB_ENABLED=no)"
    DB_PORT_LINE=""
    DB_PATH_LINE=""
fi

if [[ "${OPENSEARCH_ENABLED:-yes}" == "yes" ]]; then
    OPENSEARCH_SOFTWARE_LINE="- OpenSearch: ${OPENSEARCH_VERSION}"
    OPENSEARCH_STATUS_LINE="- OpenSearch ${OPENSEARCH_VERSION}: Installed and Running"
    OPENSEARCH_PORT_LINE="- OpenSearch: 9200 (localhost only)"
    OPENSEARCH_PATH_LINE="- OpenSearch: /opt/opensearch/"
else
    OPENSEARCH_SOFTWARE_LINE="- OpenSearch: Disabled (OPENSEARCH_ENABLED=no)"
    OPENSEARCH_STATUS_LINE="- OpenSearch: Disabled (OPENSEARCH_ENABLED=no)"
    OPENSEARCH_PORT_LINE=""
    OPENSEARCH_PATH_LINE=""
fi

if [[ "${VALKEY_ENABLED:-yes}" == "yes" ]]; then
    VALKEY_SOFTWARE_LINE="- Valkey: $(valkey-server --version | awk '{print $3}' | cut -d= -f2)"
    VALKEY_STATUS_LINE="- Valkey: Installed and Running"
    VALKEY_PORT_LINE="- Valkey: 6379 (localhost only)"
else
    VALKEY_SOFTWARE_LINE="- Valkey: Disabled (VALKEY_ENABLED=no)"
    VALKEY_STATUS_LINE="- Valkey: Disabled (VALKEY_ENABLED=no)"
    VALKEY_PORT_LINE=""
fi

if [[ "${VARNISH_ENABLED:-yes}" == "yes" ]]; then
    VARNISH_SOFTWARE_LINE="- Varnish: $(varnishd -V 2>&1 | head -1 | awk '{print $2}')"
    VARNISH_STATUS_LINE="- Varnish Cache: Installed and Running (Port 80)"
    VARNISH_HTTP_LINE="80"
    VARNISH_ADMIN_PORT_LINE="- Varnish Admin Console: 6082 (localhost only)"
    VARNISH_PATH_LINE="- Varnish Config: /etc/varnish/default.vcl"
    VARNISH_INFO_BLOCK="Varnish Cache Information:
- Config File: /etc/varnish/default.vcl
- Cache Memory: 256MB
- Status: Listening on port 80, Nginx backend on port 8080
- After deploying your application: export VCL from its admin panel (if it has one) and review default.vcl"
else
    VARNISH_SOFTWARE_LINE="- Varnish: Disabled (VARNISH_ENABLED=no)"
    VARNISH_STATUS_LINE="- Varnish Cache: Disabled (VARNISH_ENABLED=no) — Nginx is the sole HTTP-facing service on port 80"
    VARNISH_HTTP_LINE="80 (Nginx, direct — Varnish disabled)"
    VARNISH_ADMIN_PORT_LINE=""
    VARNISH_PATH_LINE=""
    VARNISH_INFO_BLOCK="Varnish Cache Information:
- Disabled (VARNISH_ENABLED=no) — Nginx serves the application vhost directly on port 80"
fi

if [[ "${COMPOSER_ENABLED:-yes}" == "yes" ]]; then
    COMPOSER_SOFTWARE_LINE="- Composer: ${COMPOSER_VERSION}"
else
    COMPOSER_SOFTWARE_LINE="- Composer: Disabled (COMPOSER_ENABLED=no)"
fi

if [[ "${PHPMYADMIN_ENABLED:-yes}" == "yes" ]]; then
    PMA_INFO_BLOCK="phpMyAdmin Access:
- URL: http://YOUR_SERVER_IP:${PMA_PORT}/${PMA_PATH}
- Username: ${PMA_USERNAME}
- Password: [STORED SECURELY IN CONFIG]
- Note: Protected with HTTP Basic Authentication"
    PMA_PORT_LINE="- phpMyAdmin: ${PMA_PORT}"
    PMA_PATH_LINE="- phpMyAdmin: ${PMA_INSTALL_DIR}"
else
    PMA_INFO_BLOCK="phpMyAdmin Access:
- Disabled (PHPMYADMIN_ENABLED=no)"
    PMA_PORT_LINE=""
    PMA_PATH_LINE=""
fi

# ── Server info file ──────────────────────────────────────────────────────────

if [[ "$ENABLE_SSL_TERMINATION" == "yes" ]]; then
    SSL_PORT_LINE="443 (Nginx SSL terminator → port 80)"
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
               or set SSL_CERT_PATH/SSL_KEY_PATH in the config and re-run: --modules=ssl-termination"
    fi
else
    SSL_PORT_LINE="Not configured on this server (ENABLE_SSL_TERMINATION=no)"
    SSL_INFO_BLOCK="SSL Configuration:
- Nginx SSL termination is DISABLED (ENABLE_SSL_TERMINATION=no)
- Port 80 is the sole HTTP-facing entry point
- TLS must be terminated upstream of this server (e.g. Cloudflare Flexible mode,
  an external load balancer, or another CDN)"
fi

INFO_FILE="${SCRIPT_DIR}/server_setup_info.txt"
cat > "$INFO_FILE" <<EOF
============================================================================
Server Setup Complete!
============================================================================

Installation Date: $(date)
Architecture: $ARCH
System Resources: ${TOTAL_RAM_GB}GB RAM, ${CPU_CORES} CPU cores

Domain: $DOMAIN_NAME
Web Root: $WEB_ROOT

Restricted User (Application User):
- Username: $RESTRICTED_USERNAME
- Home Directory: /home/${RESTRICTED_USERNAME}
- SSH Access: Enabled (key-based authentication only, via RESTRICTED_USER_SSH_PUBLIC_KEY)
- Access Method: ssh ${RESTRICTED_USERNAME}@YOUR_SERVER_IP -i /path/to/your/private/key (or su - ${RESTRICTED_USERNAME} from root)
- Permissions: NO sudo access (truly restricted for application use only)
- Purpose: Running the application and managing application files
- Git Deploy Key (public): ${RESTRICTED_USER_SSH_PUBKEY}

Root User (Administrative Access):
- SSH Key: Configured (key-based authentication only)
- Password Authentication: DISABLED
- Purpose: Administrative server management tasks

Software Versions:
- PHP: ${PHP_VERSION}
${DB_SOFTWARE_LINE}
${OPENSEARCH_SOFTWARE_LINE}
${COMPOSER_SOFTWARE_LINE}
- Nginx: $(nginx -v 2>&1 | cut -d/ -f2)
${VALKEY_SOFTWARE_LINE}
${VARNISH_SOFTWARE_LINE}

PHP Configuration:
- Memory Limit: ${PHP_MEMORY_LIMIT}
- Max Children: ${PHP_MAX_CHILDREN}
- Start Servers: ${PHP_START_SERVERS}
- Min Spare: ${PHP_MIN_SPARE}
- Max Spare: ${PHP_MAX_SPARE}

${DB_INFO_BLOCK}

${PMA_INFO_BLOCK}

Services Status:
- Nginx: Installed and Running (behind Varnish on 8080 if enabled, otherwise directly on 80)
- PHP ${PHP_VERSION}-FPM: Installed and Running
${DB_STATUS_LINE}
${OPENSEARCH_STATUS_LINE}
${VALKEY_STATUS_LINE}
${VARNISH_STATUS_LINE}

Service Ports:
- HTTP: ${VARNISH_HTTP_LINE}
- HTTPS: ${SSL_PORT_LINE}
${PMA_PORT_LINE}
${VARNISH_ADMIN_PORT_LINE}
${OPENSEARCH_PORT_LINE}
${VALKEY_PORT_LINE}
${DB_PORT_LINE}

${SSL_INFO_BLOCK}

Important Paths:
- Web Root: ${WEB_ROOT}
- PHP Config: /etc/php/${PHP_VERSION}/fpm/php.ini
- Nginx Config: /etc/nginx/
${VARNISH_PATH_LINE}
${DB_PATH_LINE}
${OPENSEARCH_PATH_LINE}
${PMA_PATH_LINE}
- Logs: /var/log/

${VARNISH_INFO_BLOCK}

Next Steps:
1. Point your domain's DNS through Cloudflare (orange cloud icon enabled), if you use it.
   In Cloudflare Dashboard → SSL/TLS → set mode to "Full".
   (Use "Full (Strict)" after replacing the cert with a Cloudflare Origin Certificate.)
2. Deploy your application (Magento, WordPress, Drupal, or any PHP app) to ${WEB_ROOT}
   as the restricted user, then add any application-specific Nginx include it needs to
   the vhost and reload Nginx:
   ssh root@YOUR_SERVER_IP -i /path/to/your/private/key
   su - ${RESTRICTED_USERNAME}
3. After deployment, if Varnish is enabled:
   a. Configure Varnish as the caching backend in your application, if it supports one
   b. Export and review /etc/varnish/default.vcl
   c. Test cache hit rate: varnishstat
4. If phpMyAdmin is enabled, access it at the URL above.

Security Notes:
- Password authentication is COMPLETELY DISABLED (SSH key only)
- Root SSH login: ALLOWED via SSH key authentication only
- Restricted user SSH login: ALLOWED via SSH key authentication only (full shell, no sudo)
- Restricted user has ZERO sudo access (true privilege separation)
- phpMyAdmin, when enabled, is on a non-standard port with randomised URL path
- All sensitive services are bound to localhost only
- Firewall is configured with UFW
- Varnish PURGE requests, when enabled, are restricted to localhost only
- Nginx is behind Varnish (when enabled) and not directly exposed
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
