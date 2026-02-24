# Module 09 — Configure Magento application settings
#
# Steps:
#   1. Set developer mode
#   2. Update base URLs and cookie domain (imported DB may have the source environment's domain)
#   3. Configure local OpenSearch as the search engine
#   4. Switch indexers realtime → schedule twice to ensure DB triggers are
#      created cleanly (drops any stale triggers from the source DB first)
#   5. Final cache flush
#
# Uses: MAGENTO_DIR, DOMAIN_NAME
# Sets: web/secure/offloader_header so Magento detects HTTPS from Nginx SSL terminator

_mage() {
    php "${MAGENTO_DIR}/bin/magento" "$@"
}

# ── Developer mode ────────────────────────────────────────────────────────────

print_step "Setting Magento to developer mode..."
_mage deploy:mode:set developer

# ── Base URLs ─────────────────────────────────────────────────────────────────

print_step "Updating store base URLs to ${DOMAIN_NAME}..."
_mage config:set web/unsecure/base_url "http://${DOMAIN_NAME}/"
_mage config:set web/secure/base_url   "https://${DOMAIN_NAME}/"
_mage config:set web/cookie/cookie_domain "${DOMAIN_NAME}"

# Tell Magento to trust the X-Forwarded-Proto header set by the Nginx SSL terminator.
# Without this, Magento sees plain HTTP (from Varnish) and generates non-HTTPS URLs.
_mage config:set web/secure/offloader_header X-Forwarded-Proto

# ── Search engine — point to local OpenSearch ─────────────────────────────────

print_step "Configuring OpenSearch search engine..."
_mage config:set catalog/search/engine                     opensearch
_mage config:set catalog/search/opensearch_server_hostname 127.0.0.1
_mage config:set catalog/search/opensearch_server_port     9200
_mage config:set catalog/search/opensearch_index_prefix    magento2
_mage config:set catalog/search/opensearch_server_timeout  15

_mage cache:flush

# ── Indexer mode — done twice to recreate DB triggers cleanly ────────────────
# Switching to 'schedule' creates MySQL triggers. Cycling through 'realtime'
# first drops any stale triggers from the source environment before creating
# fresh ones on the local database.

print_step "Configuring indexers (pass 1 of 2)..."
_mage indexer:set-mode realtime
_mage indexer:set-mode schedule

print_step "Configuring indexers (pass 2 of 2 — ensures clean trigger creation)..."
_mage indexer:set-mode realtime
_mage indexer:set-mode schedule

print_message "Indexers are in schedule mode with DB triggers properly created."

# ── Reindex ───────────────────────────────────────────────────────────────────

print_step "Reindexing..."
_mage indexer:reindex

# ── Final cache flush ─────────────────────────────────────────────────────────

_mage cache:flush

print_message "Magento configuration complete."

unset -f _mage
