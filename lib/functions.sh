#!/bin/bash
# lib/functions.sh — Shared helper functions for Magento server setup.
# Sourced by setup-ubuntu24.sh; not intended to be executed directly.

# ── Temporary file tracking ───────────────────────────────────────────────────

TEMP_FILES=()

cleanup_temp_files() {
    for temp_file in "${TEMP_FILES[@]}"; do
        if [[ -f "$temp_file" ]]; then
            print_message "Cleaning up temporary file: $temp_file"
            shred -vfz -n 3 "$temp_file" 2>/dev/null || rm -f "$temp_file"
        fi
    done
}

trap cleanup_temp_files EXIT

add_temp_file() {
    TEMP_FILES+=("$1")
}

# ── Output helpers ────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_message() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_step()    { echo -e "${BLUE}[STEP]${NC} $1"; }

# ── Safe configuration loader ─────────────────────────────────────────────────

load_config_safely() {
    local config_file="$1"
    local line_number=0
    local allowed_vars=(
        "DOMAIN_NAME" "PHP_VERSION" "OPENSEARCH_VERSION" "COMPOSER_VERSION"
        "MARIADB_VERSION" "MARIADB_ROOT_PASSWORD" "RESTRICTED_USER" "SSH_PUBLIC_KEY"
        "PMA_USERNAME" "PMA_PASSWORD" "PMA_PORT" "PMA_PATH"
        "DB_NAME" "DB_USER" "DB_PASSWORD" "DB_HOST"
        "GIT_REPO_URL" "DB_DUMP_PATH" "MEDIA_PATH" "CRYPT_KEY"
        "ADMIN_FIRSTNAME" "ADMIN_LASTNAME" "ADMIN_EMAIL"
        "ADMIN_USERNAME" "ADMIN_PASSWORD" "ADMIN_FRONTNAME" "CURRENCY" "TIMEZONE" "LANGUAGE"
        "MAGENTO_DIR" "MAGENTO_DEPLOYED" "MAGENTO_DEPLOY_DATE"
    )

    while IFS= read -r line; do
        ((line_number++))
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        line="${line%%#*}"
        line=$(echo "$line" | xargs)
        [[ -z "$line" ]] && continue

        if [[ "$line" =~ \$\( ]] || [[ "$line" =~ \`   ]] || [[ "$line" =~ \&\& ]] || \
           [[ "$line" =~ \|\| ]] || [[ "$line" =~ \;   ]] || [[ "$line" =~ \|   ]] || \
           [[ "$line" =~ eval ]] || [[ "$line" =~ exec ]] || [[ "$line" =~ source ]] || \
           [[ "$line" =~ \.\/ ]]; then
            echo "ERROR: Config line $line_number contains potentially malicious code: $line"
            return 1
        fi

        if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
            local var_name="${BASH_REMATCH[1]}"
            local var_value="${BASH_REMATCH[2]}"
            local is_allowed=0
            for allowed_var in "${allowed_vars[@]}"; do
                [[ "$var_name" == "$allowed_var" ]] && is_allowed=1 && break
            done
            if [[ $is_allowed -eq 0 ]]; then
                echo "ERROR: Unknown config variable on line $line_number: $var_name"
                return 1
            fi
            var_value="${var_value%\"}"
            var_value="${var_value#\"}"
            var_value="${var_value%\'}"
            var_value="${var_value#\'}"
            declare -g "$var_name=$var_value"
        else
            echo "ERROR: Invalid syntax in config file at line $line_number: $line"
            return 1
        fi
    done < "$config_file"
    return 0
}

# ── Validation functions ──────────────────────────────────────────────────────

validate_server_config() {
    local missing=()
    [[ -z "$DOMAIN_NAME" ]]           && missing+=("DOMAIN_NAME")
    [[ -z "$PHP_VERSION" ]]           && missing+=("PHP_VERSION")
    [[ -z "$OPENSEARCH_VERSION" ]]    && missing+=("OPENSEARCH_VERSION")
    [[ -z "$COMPOSER_VERSION" ]]      && missing+=("COMPOSER_VERSION")
    [[ -z "$MARIADB_VERSION" ]]       && missing+=("MARIADB_VERSION")
    [[ -z "$MARIADB_ROOT_PASSWORD" ]] && missing+=("MARIADB_ROOT_PASSWORD")
    [[ -z "$RESTRICTED_USER" ]]       && missing+=("RESTRICTED_USER")
    [[ -z "$SSH_PUBLIC_KEY" ]]        && missing+=("SSH_PUBLIC_KEY")
    [[ -z "$PMA_PORT" ]]              && missing+=("PMA_PORT")
    [[ -z "$PMA_USERNAME" ]]          && missing+=("PMA_USERNAME")
    [[ -z "$PMA_PASSWORD" ]]          && missing+=("PMA_PASSWORD")
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing required config variables:"
        for var in "${missing[@]}"; do echo "  - $var"; done
        exit 1
    fi
    if ! [[ "$PHP_VERSION" =~ ^8\.[1-5]$ ]]; then
        echo "ERROR: Invalid PHP_VERSION '$PHP_VERSION'. Must be 8.1, 8.2, 8.3, 8.4, or 8.5"
        exit 1
    fi
    if ! [[ "$MARIADB_VERSION" =~ ^(10\.[6-9]|10\.[1-9][0-9]|11\.[0-9]+)$ ]]; then
        echo "ERROR: Invalid MARIADB_VERSION '$MARIADB_VERSION'. Must be 10.6+ or 11.x (e.g., 10.11, 11.4, 11.8)"
        exit 1
    fi
    if ! [[ "$PMA_PORT" =~ ^[0-9]+$ ]] || [ "$PMA_PORT" -lt 1 ] || [ "$PMA_PORT" -gt 65535 ]; then
        echo "ERROR: Invalid PMA_PORT '$PMA_PORT'. Must be 1–65535"
        exit 1
    fi
}

validate_ssh_public_key() {
    local key="$1"
    [[ -z "$key" ]] && echo "ERROR: SSH_PUBLIC_KEY is empty" && return 1
    key=$(echo "$key" | xargs)
    if ! [[ "$key" =~ ^(ssh-rsa|ssh-dss|ecdsa-sha2-nistp|ssh-ed25519)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]]+.*)?$ ]]; then
        echo "ERROR: SSH_PUBLIC_KEY has invalid format"
        return 1
    fi
    local key_type key_data
    key_type=$(echo "$key" | awk '{print $1}')
    key_data=$(echo "$key"  | awk '{print $2}')
    local valid_types=("ssh-rsa" "ssh-dss" "ecdsa-sha2-nistp256" "ecdsa-sha2-nistp384" "ecdsa-sha2-nistp521" "ssh-ed25519")
    local is_valid_type=0
    for valid_type in "${valid_types[@]}"; do
        [[ "$key_type" == "$valid_type" ]] && is_valid_type=1 && break
    done
    [[ $is_valid_type -eq 0 ]] && echo "ERROR: Unknown SSH key type: $key_type" && return 1
    if ! echo "$key_data" | grep -qE '^[A-Za-z0-9+/]*={0,2}$'; then
        echo "ERROR: SSH public key data is not valid base64"
        return 1
    fi
    local min_len=64
    [[ "$key_type" == "ssh-rsa" || "$key_type" == "ssh-dss" ]] && min_len=200
    [[ ${#key_data} -lt $min_len ]] && echo "ERROR: SSH public key appears truncated" && return 1
    if command -v ssh-keygen &>/dev/null; then
        local temp_keyfile
        temp_keyfile=$(mktemp)
        echo "$key" > "$temp_keyfile"
        if ! ssh-keygen -l -f "$temp_keyfile" >/dev/null 2>&1; then
            rm -f "$temp_keyfile"
            echo "ERROR: SSH public key validation failed (invalid key)"
            return 1
        fi
        rm -f "$temp_keyfile"
    fi
    echo "OK"
    return 0
}

validate_magento_install_config() {
    local missing=()
    [[ -z "${DOMAIN_NAME:-}" ]]           && missing+=("DOMAIN_NAME")
    [[ -z "${RESTRICTED_USER:-}" ]]       && missing+=("RESTRICTED_USER")
    [[ -z "${MARIADB_ROOT_PASSWORD:-}" ]] && missing+=("MARIADB_ROOT_PASSWORD")
    [[ -z "${GIT_REPO_URL:-}" ]]          && missing+=("GIT_REPO_URL")
    [[ -z "${DB_NAME:-}" ]]               && missing+=("DB_NAME")
    [[ -z "${DB_USER:-}" ]]               && missing+=("DB_USER")
    [[ -z "${DB_PASSWORD:-}" ]]           && missing+=("DB_PASSWORD")
    [[ -z "${DB_HOST:-}" ]]               && missing+=("DB_HOST")
    [[ -z "${ADMIN_FIRSTNAME:-}" ]]       && missing+=("ADMIN_FIRSTNAME")
    [[ -z "${ADMIN_LASTNAME:-}" ]]        && missing+=("ADMIN_LASTNAME")
    [[ -z "${ADMIN_EMAIL:-}" ]]           && missing+=("ADMIN_EMAIL")
    [[ -z "${ADMIN_USERNAME:-}" ]]        && missing+=("ADMIN_USERNAME")
    [[ -z "${ADMIN_PASSWORD:-}" ]]        && missing+=("ADMIN_PASSWORD")
    [[ -z "${ADMIN_FRONTNAME:-}" ]]       && missing+=("ADMIN_FRONTNAME")
    [[ -z "${CURRENCY:-}" ]]              && missing+=("CURRENCY")
    [[ -z "${TIMEZONE:-}" ]]              && missing+=("TIMEZONE")
    [[ -z "${LANGUAGE:-}" ]]              && missing+=("LANGUAGE")

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing required config variables in magento-setup.conf:"
        for var in "${missing[@]}"; do echo "  - $var"; done
        exit 1
    fi

    # Warn about optional but important values
    if [[ -z "${CRYPT_KEY:-}" ]]; then
        print_warning "CRYPT_KEY is not set. A new random key will be generated."
        print_warning "Encrypted data in the imported DB (passwords, tokens) may be unreadable."
    fi
    if [[ -z "${DB_DUMP_PATH:-}" ]]; then
        print_warning "DB_DUMP_PATH is not set. Database import will be skipped."
    fi
    if [[ -z "${MEDIA_PATH:-}" ]]; then
        print_warning "MEDIA_PATH is not set. Media import will be skipped."
    fi
}

validate_system_resources() {
    local errors=()
    [[ -z "$TOTAL_RAM_GB" || ! "$TOTAL_RAM_GB" =~ ^[0-9]+$ ]] && errors+=("Failed to detect system RAM correctly")
    [ "${TOTAL_RAM_GB:-0}" -eq 0 ] && errors+=("System RAM detected as 0GB — /proc/meminfo may be inaccessible")
    [ "${TOTAL_RAM_GB:-0}" -lt 2 ] && print_warning "System has less than 2GB RAM — below recommended minimum for Magento (4GB+)"
    [ "${TOTAL_RAM_GB:-0}" -gt 512 ] && print_warning "System has very high RAM (${TOTAL_RAM_GB}GB) — unusual configuration"
    [[ -z "$CPU_CORES" || ! "$CPU_CORES" =~ ^[0-9]+$ ]] && errors+=("Failed to detect CPU cores correctly")
    [ "${CPU_CORES:-0}" -eq 0 ] && errors+=("CPU cores detected as 0 — nproc may have failed")
    [ "${CPU_CORES:-0}" -eq 1 ] && print_warning "System has only 1 CPU core — performance will be limited"
    [ "${CPU_CORES:-0}" -gt 128 ] && print_warning "System has very high CPU core count (${CPU_CORES})"
    if [[ ${#errors[@]} -gt 0 ]]; then
        for error in "${errors[@]}"; do print_error "$error"; done
        exit 1
    fi
}

validate_resource_allocations() {
    local PHP_MEMORY_MB=${PHP_MEMORY_LIMIT%G}
    PHP_MEMORY_MB=$((PHP_MEMORY_MB * 1024))
    local PHP_FPM_MAX_MEMORY=$((PHP_MAX_CHILDREN * PHP_MEMORY_MB * 15 / 100))
    local TOTAL_ALLOCATED=$((PHP_FPM_MAX_MEMORY + OPENSEARCH_HEAP + VALKEY_MEMORY))
    local SYSTEM_RAM_MB=$((TOTAL_RAM_GB * 1024))
    local AVAILABLE=$((SYSTEM_RAM_MB - 512))

    print_message "Resource Allocation Summary:"
    echo "  System RAM:        ${TOTAL_RAM_GB}GB (${SYSTEM_RAM_MB}MB)"
    echo "  PHP-FPM:           ~${PHP_FPM_MAX_MEMORY}MB (${PHP_MAX_CHILDREN} children × ${PHP_MEMORY_MB}MB × 15% avg RSS)"
    echo "  OpenSearch heap:   ${OPENSEARCH_HEAP}MB"
    echo "  Valkey:            ${VALKEY_MEMORY}MB"
    echo "  Total allocated:   ~${TOTAL_ALLOCATED}MB"
    echo "  Available:         ${AVAILABLE}MB"
    echo ""

    local warnings=() errors=()
    [ "$PHP_MEMORY_MB" -gt $((TOTAL_RAM_GB * 1024 / 2)) ] && warnings+=("PHP memory limit > 50% of total RAM")
    [ $PHP_MAX_CHILDREN -gt 200 ]                          && warnings+=("PHP-FPM max_children (${PHP_MAX_CHILDREN}) is very high")
    [ $OPENSEARCH_HEAP -gt $((TOTAL_RAM_GB * 1024 / 2)) ] && warnings+=("OpenSearch heap > 50% of total RAM")
    [ $OPENSEARCH_HEAP -lt 1024 ]                          && warnings+=("OpenSearch heap (${OPENSEARCH_HEAP}MB) < 1GB — search performance may be poor")
    [ $VALKEY_MEMORY -lt 256 ]                             && warnings+=("Valkey memory (${VALKEY_MEMORY}MB) is very low")
    [ $TOTAL_ALLOCATED -gt $((AVAILABLE * 80 / 100)) ]    && warnings+=("Resource allocation uses >80% of available memory")
    [ $TOTAL_ALLOCATED -gt $AVAILABLE ]                    && errors+=("Total allocation (${TOTAL_ALLOCATED}MB) EXCEEDS available memory by $((TOTAL_ALLOCATED - AVAILABLE))MB")

    if [[ ${#warnings[@]} -gt 0 ]]; then
        print_warning "RESOURCE ALLOCATION WARNINGS:"
        for w in "${warnings[@]}"; do echo "  ⚠ $w"; done
        echo ""
    fi
    if [[ ${#errors[@]} -gt 0 ]]; then
        print_error "RESOURCE ALLOCATION ERRORS:"
        for e in "${errors[@]}"; do echo "  ✗ $e"; done
        echo ""
        print_error "Installation cannot proceed due to insufficient memory"
        exit 1
    fi
}
