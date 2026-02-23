#!/bin/bash

#############################################################################
# Magento Deployment Script
# Deploys an existing Magento 2 project from a Git repository.
# IMPORTANT: This script must NOT be run as root or by a user with sudo
# access. It must be run as the restricted user created by setup-ubuntu24.sh.
#############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load shared helper functions
source "${SCRIPT_DIR}/lib/functions.sh"

# ── Privilege check ───────────────────────────────────────────────────────────

if [[ "$(id -u)" -eq 0 ]]; then
    print_error "This script must NOT be run as root."
    print_message "Switch to the restricted user and run: bash install-magento.sh"
    exit 1
fi

if sudo -n true 2>/dev/null; then
    print_error "This script must NOT be run by a user with sudo access."
    print_message "Switch to the restricted user (no sudo privileges) and run: bash install-magento.sh"
    exit 1
fi

# ── Logging ───────────────────────────────────────────────────────────────────

LOG_FILE="${SCRIPT_DIR}/install-magento-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "Logging to: $LOG_FILE"

# ── Configuration ─────────────────────────────────────────────────────────────

CONFIG_FILE="${SCRIPT_DIR}/magento-setup.conf"
if [[ ! -f "$CONFIG_FILE" ]]; then
    print_error "Config file not found: $CONFIG_FILE"
    print_message "Copy magento-setup.conf.example to magento-setup.conf and fill in your values."
    exit 1
fi

if ! load_config_safely "$CONFIG_FILE"; then
    print_error "Failed to load configuration. Fix the errors above and retry."
    exit 1
fi

print_step "Validating configuration..."
validate_magento_install_config

# ── Derived variables ─────────────────────────────────────────────────────────

MAGENTO_DIR="/var/www/${DOMAIN_NAME}"
PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
RESTRICTED_USER_HOME="$(getent passwd "${RESTRICTED_USER}" | cut -d: -f6)"

# Verify restricted user exists
if [[ -z "${RESTRICTED_USER_HOME}" ]]; then
    print_error "Restricted user '${RESTRICTED_USER}' does not exist."
    print_message "Run setup-ubuntu24.sh first to create the server infrastructure."
    exit 1
fi

# ── Summary ───────────────────────────────────────────────────────────────────

clear
echo "============================================================================"
echo "          Magento Deployment Script"
echo "          Git-based deployment — Ubuntu 24.04 LTS"
echo "============================================================================"
echo ""
echo "Domain:         ${DOMAIN_NAME}"
echo "Magento Dir:    ${MAGENTO_DIR}"
echo "Git Repo:       ${GIT_REPO_URL}"
echo "App User:       ${RESTRICTED_USER}"
echo "PHP Version:    ${PHP_VERSION}"
echo "Database:       ${DB_NAME} @ ${DB_HOST}"
echo "DB Dump:        ${DB_DUMP_PATH:-(not set — DB import will be skipped)}"
echo "Media Path:     ${MEDIA_PATH:-(not set — media import will be skipped)}"
echo "============================================================================"
echo ""

read -rp "Proceed with deployment? [y/N]: " _confirm
[[ "${_confirm,,}" != "y" ]] && print_message "Deployment cancelled." && exit 0

# ── Run modules ───────────────────────────────────────────────────────────────
# Modules are sourced so they inherit all variables set above and can set
# new variables visible to later modules.

INSTALL_MODULES_DIR="${SCRIPT_DIR}/magento-deploy"

for _module in "${INSTALL_MODULES_DIR}"/[0-9][0-9]-*.sh; do
    echo ""
    print_step "━━━ Module: $(basename "$_module") ━━━"
    source "$_module"
done
