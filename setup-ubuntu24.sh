#!/bin/bash
#############################################################################
# Magento Server Setup Script for Ubuntu 24.04
# Main entry point — validates config, calculates resources, then sources
# each module in server-setup/ automatically in numeric order.
# IMPORTANT: This script MUST be run as root user only
#############################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Argument parsing ───────────────────────────────────────────────────────────

SELECTED_MODULES=()

for _arg in "$@"; do
    case "$_arg" in
        --modules=*)
            IFS=',' read -ra _tokens <<< "${_arg#--modules=}"
            for _t in "${_tokens[@]}"; do SELECTED_MODULES+=("$_t"); done
            ;;
        --modules)
            echo "ERROR: --modules requires a value: --modules=03,05,09"
            exit 1
            ;;
    esac
done

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

LOG_FILE="${SCRIPT_DIR}/setup-server-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "Logging to: $LOG_FILE"

# ── Configuration ─────────────────────────────────────────────────────────────

CONFIG_FILE="${SCRIPT_DIR}/server-setup.conf"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config file not found: $CONFIG_FILE"
    echo "Copy server-setup.conf.example to server-setup.conf and fill in your values."
    exit 1
fi

if ! load_config_safely "$CONFIG_FILE"; then
    exit 1
fi

print_step "Validating configuration from $CONFIG_FILE..."
validate_server_config

print_step "Validating SSL/TLS configuration..."
validate_ssl_config

print_step "Validating SSH public key format..."
if ! SSH_KEY_VALIDATION=$(validate_ssh_public_key "$ROOT_USER_SSH_PUBLIC_KEY"); then
    print_error "$SSH_KEY_VALIDATION"
    exit 1
fi
print_message "SSH public key validation passed"

print_step "Validating restricted user SSH public key format..."
if ! RESTRICTED_USER_SSH_KEY_VALIDATION=$(validate_ssh_public_key "$RESTRICTED_USER_SSH_PUBLIC_KEY"); then
    print_error "$RESTRICTED_USER_SSH_KEY_VALIDATION"
    exit 1
fi
print_message "Restricted user SSH public key validation passed"

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
echo "Restricted User:    $RESTRICTED_USERNAME"
echo "SSL Termination:    $ENABLE_SSL_TERMINATION"
echo "phpMyAdmin Port:    $PMA_PORT"
echo "phpMyAdmin Path:    (generated during phpMyAdmin module)"
echo "============================================================================"
echo ""

print_step "Starting installation process..."
sleep 2

# ── Run installation modules ──────────────────────────────────────────────────
# Modules are sourced (not executed) so they inherit all variables above and
# can set variables that later modules will see.

MODULES_DIR="${SCRIPT_DIR}/server-setup"

if [[ ${#SELECTED_MODULES[@]} -gt 0 ]]; then
    _modules_to_run=()
    for _token in "${SELECTED_MODULES[@]}"; do
        _path=$(resolve_module "$MODULES_DIR" "$_token") || exit 1
        if [[ ! -f "$_path" ]]; then
            echo "ERROR: Module not found: $_path"
            exit 1
        fi
        _modules_to_run+=("$_path")
    done
else
    _modules_to_run=("${MODULES_DIR}"/[0-9][0-9]-*.sh)
fi

for module in "${_modules_to_run[@]}"; do
    echo ""
    print_step "━━━ Module: $(basename "$module") ━━━"
    source "$module"
done
