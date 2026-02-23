# Module 11 — Write deployment summary and display completion message
# Uses: all variables set by the main script and earlier modules

INFO_FILE="${SCRIPT_DIR}/magento_deploy_info_${DOMAIN_NAME}.txt"

cat > "${INFO_FILE}" << EOF
============================================================================
Magento Deployment Complete
============================================================================

Date:           $(date)
Domain:         ${DOMAIN_NAME}
Magento Dir:    ${MAGENTO_DIR}
PHP Version:    ${PHP_VERSION}
App User:       ${RESTRICTED_USER}
Git Repo:       ${GIT_REPO_URL}

Database:
  Host:         ${DB_HOST}
  Name:         ${DB_NAME}
  User:         ${DB_USER}
  Root Pass:    [stored in magento-setup.conf]

Admin Panel:
  URL:          http://${DOMAIN_NAME}/admin
  Username:     ${ADMIN_USERNAME}
  Email:        ${ADMIN_EMAIL}
  Password:     [stored in magento-setup.conf]

Deployment Log: ${LOG_FILE}

Post-Deployment Steps:
  1. Deploy static content (required before going live):
       su - ${RESTRICTED_USER}
       cd ${MAGENTO_DIR}
       php bin/magento setup:static-content:deploy -f -l ${LANGUAGE}

  2. Compile dependency injection (recommended for performance):
       php bin/magento setup:di:compile

  3. Set up SSL:
       certbot --nginx -d ${DOMAIN_NAME} --email <your-email> --agree-tos --non-interactive
       php bin/magento config:set web/secure/use_in_frontend 1
       php bin/magento config:set web/secure/use_in_adminhtml 1
       php bin/magento cache:flush

  4. Switch to production mode when ready:
       php bin/magento deploy:mode:set production

Common Commands (run from ${MAGENTO_DIR} as ${RESTRICTED_USER}):
  php bin/magento cache:flush
  php bin/magento indexer:reindex
  php bin/magento setup:upgrade
  php bin/magento maintenance:enable / maintenance:disable

Service Restarts:
  systemctl restart php${PHP_VERSION}-fpm
  systemctl restart nginx
  systemctl restart varnish
  systemctl restart redis-server

Logs:
  Magento:  ${MAGENTO_DIR}/var/log/
  Nginx:    /var/log/nginx/
  PHP-FPM:  /var/log/php${PHP_VERSION}-fpm.log

============================================================================
EOF

# Append deployment record to the shared config file
cat >> "${CONFIG_FILE}" << EOF

# ============================================================
# DEPLOYMENT RECORD — written by install-magento.sh
# ============================================================
# Deployed: $(date)
MAGENTO_DIR="${MAGENTO_DIR}"
MAGENTO_DEPLOYED="yes"
MAGENTO_DEPLOY_DATE="$(date)"
EOF

clear
echo "============================================================================"
echo "          Magento Deployment Complete!"
echo "============================================================================"
echo ""
cat "${INFO_FILE}"
echo ""
print_message "Deployment summary saved to: ${INFO_FILE}"
print_warning "Run 'setup:static-content:deploy' before testing the storefront."
echo ""
