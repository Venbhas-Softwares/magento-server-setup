# Module 08 — Run Magento setup:install
#
# Generates app/etc/env.php and applies configuration by running setup:install
# against the already-imported database, then flushes the cache.
#
# Uses: DOMAIN_NAME, DB_HOST, DB_NAME, DB_USER, DB_PASSWORD, ADMIN_FRONTNAME,
#       MAGENTO_DIR

print_step "Running setup:install..."

php "${MAGENTO_DIR}/bin/magento" setup:install \
    --base-url="http://${DOMAIN_NAME}/" \
    --db-host="${DB_HOST}" \
    --db-name="${DB_NAME}" \
    --db-user="${DB_USER}" \
    --db-password="${DB_PASSWORD}" \
    --backend-frontname="${ADMIN_FRONTNAME}" \
    --search-engine=opensearch \
    --opensearch-host=127.0.0.1 \
    --opensearch-port=9200 \
    --opensearch-index-prefix=magento2 \
    --opensearch-timeout=15 \
    --session-save=redis \
    --session-save-redis-host=127.0.0.1 \
    --session-save-redis-port=6379 \
    --session-save-redis-db=0 \
    --cache-backend=redis \
    --cache-backend-redis-server=127.0.0.1 \
    --cache-backend-redis-port=6379 \
    --cache-backend-redis-db=1 \
    --page-cache=redis \
    --page-cache-redis-server=127.0.0.1 \
    --page-cache-redis-port=6379 \
    --page-cache-redis-db=2 \
    --http-cache-hosts=127.0.0.1:6081 \
    --no-interaction

print_step "Flushing cache..."
php "${MAGENTO_DIR}/bin/magento" cache:flush

print_message "Magento environment configured."
