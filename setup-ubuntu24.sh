#!/bin/bash
#############################################################################
# PHP Application Server Setup Script for Ubuntu 24.04
# Provisions Nginx, PHP-FPM, a database (MariaDB or MySQL), and a set of
# optional services (OpenSearch, Valkey, Varnish, Composer, phpMyAdmin) —
# each individually toggleable in server-setup.conf. Framework-agnostic:
# the web root it creates can be populated with Magento, WordPress, Drupal,
# or any other PHP application.
# Main entry point — validates config, calculates resources, then sources
# each module in server-setup/ in the order defined by MODULE_ORDER below.
# IMPORTANT: This script MUST be run as root user only
#############################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Canonical module run order. Filenames carry no numeric prefix — this array
# is the single source of truth for both the default full run and for
# resolving numeric --modules= tokens (position-based, 1-indexed).
MODULE_ORDER=(
    "system" "nginx" "php" "database" "opensearch" "valkey" "varnish"
    "composer" "phpmyadmin" "security" "ssl-termination" "vhost" "finalize"
)

# ── Argument parsing ───────────────────────────────────────────────────────────

SELECTED_MODULES=()

for _arg in "$@"; do
    case "$_arg" in
        --modules=*)
            IFS=',' read -ra _tokens <<< "${_arg#--modules=}"
            for _t in "${_tokens[@]}"; do SELECTED_MODULES+=("$_t"); done
            ;;
        --modules)
            echo "ERROR: --modules requires a value: --modules=php,database,phpmyadmin (or by position: --modules=3,4,9)"
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

# SSH keys are only mandatory in key-only mode (validate_server_config already
# enforced that); in password mode they're optional extras, still validated
# for format if supplied.
if [[ -n "$ROOT_USER_SSH_PUBLIC_KEY" ]]; then
    print_step "Validating SSH public key format..."
    if ! SSH_KEY_VALIDATION=$(validate_ssh_public_key "$ROOT_USER_SSH_PUBLIC_KEY"); then
        print_error "$SSH_KEY_VALIDATION"
        exit 1
    fi
    print_message "SSH public key validation passed"
fi

if [[ -n "$RESTRICTED_USER_SSH_PUBLIC_KEY" ]]; then
    print_step "Validating restricted user SSH public key format..."
    if ! RESTRICTED_USER_SSH_KEY_VALIDATION=$(validate_ssh_public_key "$RESTRICTED_USER_SSH_PUBLIC_KEY"); then
        print_error "$RESTRICTED_USER_SSH_KEY_VALIDATION"
        exit 1
    fi
    print_message "Restricted user SSH public key validation passed"
fi

# ── System resource detection ─────────────────────────────────────────────────

clear
echo "============================================================================"
echo "          PHP Application Server Setup Script"
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

# Compute every RAM-based sizing decision up front, then validate the result
# BEFORE any module installs anything — validating after modules 03/05/06 (the
# previous approach) meant aborting only after the overcommitted stack was
# already installed and running, which defeats the point of the check.
calculate_resource_allocations
validate_resource_allocations


# ── Installation summary ──────────────────────────────────────────────────────

echo ""
echo "============================================================================"
echo "Installation Summary:"
echo "============================================================================"
echo "Domain:             $DOMAIN_NAME"
echo "Architecture:       $ARCH"
echo "System Resources:   ${TOTAL_RAM_GB}GB RAM, ${CPU_CORES} CPU cores"
echo "PHP Version:        $PHP_VERSION"
if [[ "$DB_ENABLED" == "yes" ]]; then
    echo "Database:           $DB_ENGINE $DB_VERSION"
else
    echo "Database:           disabled"
fi
if [[ "$OPENSEARCH_ENABLED" == "yes" ]]; then
    echo "OpenSearch Version: $OPENSEARCH_VERSION"
else
    echo "OpenSearch:         disabled"
fi
echo "Valkey:             $([ "$VALKEY_ENABLED" == "yes" ] && echo enabled || echo disabled)"
echo "Varnish:            $([ "$VARNISH_ENABLED" == "yes" ] && echo enabled || echo disabled)"
if [[ "$COMPOSER_ENABLED" == "yes" ]]; then
    echo "Composer Version:   $COMPOSER_VERSION"
else
    echo "Composer:           disabled"
fi
echo "Restricted User:    $RESTRICTED_USERNAME"
echo "Restricted SSH:     $([ "$SSH_PASSWORD_AUTH_ENABLED" == "yes" ] && echo "password" || echo "key")"
echo "Root SSH:           $([ "$ROOT_PASSWORD_AUTH_ENABLED" == "yes" ] && echo "password" || echo "key")"
echo "SSL Termination:    $ENABLE_SSL_TERMINATION"
if [[ "$PHPMYADMIN_ENABLED" == "yes" ]]; then
    echo "phpMyAdmin Port:    $PMA_PORT"
    echo "phpMyAdmin Path:    (generated during phpmyadmin module)"
else
    echo "phpMyAdmin:         disabled"
fi
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
    _modules_to_run=()
    for _name in "${MODULE_ORDER[@]}"; do
        _modules_to_run+=("${MODULES_DIR}/${_name}.sh")
    done
fi

for module in "${_modules_to_run[@]}"; do
    echo ""
    print_step "━━━ Module: $(basename "$module") ━━━"
    source "$module"
done
