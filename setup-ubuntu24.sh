#!/bin/bash
#############################################################################
# Magento Server Setup Script for Ubuntu 24.04
# Main entry point — validates config, calculates resources, then sources
# each module in modules/ automatically in numeric order.
# IMPORTANT: This script MUST be run as root user only
#############################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load shared helper functions (defines print_*, add_temp_file, validators…)
source "${SCRIPT_DIR}/lib/functions.sh"

# ── Root check ────────────────────────────────────────────────────────────────

CURRENT_USER=$(id -u)
if [ "$CURRENT_USER" -ne 0 ]; then
    echo "ERROR: This script MUST be run as root user only (current UID: $CURRENT_USER)"
    echo "Run: sudo bash setup-ubuntu24.sh"
    exit 1
fi

# ── Logging ───────────────────────────────────────────────────────────────────

LOG_FILE="$(pwd)/setup-server-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "Logging to: $LOG_FILE"

# ── Configuration ─────────────────────────────────────────────────────────────

CONFIG_FILE="${SCRIPT_DIR}/magento-setup.conf"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config file not found: $CONFIG_FILE"
    echo "Copy magento-setup.conf.example to magento-setup.conf and fill in your values."
    exit 1
fi

if ! load_config_safely "$CONFIG_FILE"; then
    exit 1
fi

print_step "Validating configuration from $CONFIG_FILE..."
validate_server_config

print_step "Validating SSH public key format..."
SSH_KEY_VALIDATION=$(validate_ssh_public_key "$SSH_PUBLIC_KEY")
if [[ "$SSH_KEY_VALIDATION" != "OK" ]]; then
    print_error "$SSH_KEY_VALIDATION"
    exit 1
fi
print_message "SSH public key validation passed"

# ── System resource detection ─────────────────────────────────────────────────

clear
echo "============================================================================"
echo "          Magento Server Setup Script"
echo "          Ubuntu 24.04 LTS"
echo "============================================================================"
echo ""

ARCH=$(uname -m)
print_message "Detected architecture: $ARCH"

TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))
print_message "Detected RAM: ${TOTAL_RAM_GB}GB"

CPU_CORES=$(nproc)
print_message "Detected CPU cores: ${CPU_CORES}"

validate_system_resources


# ── Installation summary ──────────────────────────────────────────────────────

echo ""
echo "============================================================================"
echo "Installation Summary:"
echo "============================================================================"
echo "Domain:             $DOMAIN_NAME"
echo "Architecture:       $ARCH"
echo "System Resources:   ${TOTAL_RAM_GB}GB RAM, ${CPU_CORES} CPU cores"
echo "PHP Version:        $PHP_VERSION"
echo "OpenSearch Version: $OPENSEARCH_VERSION"
echo "Composer Version:   $COMPOSER_VERSION"
echo "Restricted User:    $RESTRICTED_USER"
echo "phpMyAdmin Port:    $PMA_PORT"
echo "phpMyAdmin Path:    (generated during phpMyAdmin module)"
echo "============================================================================"
echo ""

print_step "Starting installation process..."
sleep 2

# ── Run installation modules ──────────────────────────────────────────────────
# Modules are sourced (not executed) so they inherit all variables above and
# can set variables that later modules will see.

MODULES_DIR="${SCRIPT_DIR}/modules"
for module in "${MODULES_DIR}"/[0-9][0-9]-*.sh; do
    echo ""
    print_step "━━━ Module: $(basename "$module") ━━━"
    source "$module"
done
