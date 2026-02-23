# Module 03 — Run composer install
# Uses: MAGENTO_DIR

print_step "Running composer install in ${MAGENTO_DIR}..."

cd "${MAGENTO_DIR}" && composer install --no-interaction

print_message "Composer dependencies installed."
