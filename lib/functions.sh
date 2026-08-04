#!/bin/bash
# lib/functions.sh — Shared helper functions for PHP application server setup.
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
        "DOMAIN_NAME" "PHP_VERSION" "OPENSEARCH_ENABLED" "OPENSEARCH_VERSION" "COMPOSER_ENABLED" "COMPOSER_VERSION"
        "DB_ENABLED" "DB_ENGINE" "DB_VERSION" "DB_ROOT_PASSWORD" "RESTRICTED_USERNAME" "ROOT_USER_SSH_PUBLIC_KEY"
        "RESTRICTED_USER_SSH_PUBLIC_KEY" "VALKEY_ENABLED" "VARNISH_ENABLED" "VARNISH_VERSION" "PHPMYADMIN_ENABLED"
        "PMA_USERNAME" "PMA_PASSWORD" "PMA_PORT" "PMA_PATH"
        "WEB_ROOT" "ENABLE_SSL_TERMINATION" "SSL_CERT_PATH" "SSL_KEY_PATH"
        "SSH_PASSWORD_AUTH_ENABLED" "ROOT_PASSWORD_AUTH_ENABLED" "ROOT_USER_PASSWORD" "RESTRICTED_USER_PASSWORD"
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
    # Every optional software component defaults to enabled so existing
    # configs keep working unchanged. PHP and Nginx are not toggleable —
    # they're the irreducible core of "a PHP application server".
    OPENSEARCH_ENABLED="${OPENSEARCH_ENABLED:-yes}"
    DB_ENABLED="${DB_ENABLED:-yes}"
    VALKEY_ENABLED="${VALKEY_ENABLED:-yes}"
    VARNISH_ENABLED="${VARNISH_ENABLED:-yes}"
    COMPOSER_ENABLED="${COMPOSER_ENABLED:-yes}"
    PHPMYADMIN_ENABLED="${PHPMYADMIN_ENABLED:-yes}"
    # Default "no" preserves the existing secure-by-default behavior (key-only
    # SSH) for every config written before these switches existed. The two
    # are independent: SSH_PASSWORD_AUTH_ENABLED governs the restricted
    # (application) user and turns on sshd password auth at all; root's
    # password is only ever touched if ROOT_PASSWORD_AUTH_ENABLED is also
    # yes — resetting root's credential isn't something every run should do.
    SSH_PASSWORD_AUTH_ENABLED="${SSH_PASSWORD_AUTH_ENABLED:-no}"
    ROOT_PASSWORD_AUTH_ENABLED="${ROOT_PASSWORD_AUTH_ENABLED:-no}"

    for toggle_var in OPENSEARCH_ENABLED DB_ENABLED VALKEY_ENABLED VARNISH_ENABLED COMPOSER_ENABLED PHPMYADMIN_ENABLED SSH_PASSWORD_AUTH_ENABLED ROOT_PASSWORD_AUTH_ENABLED; do
        if [[ "${!toggle_var}" != "yes" && "${!toggle_var}" != "no" ]]; then
            echo "ERROR: Invalid ${toggle_var} '${!toggle_var}'. Must be 'yes' or 'no'"
            exit 1
        fi
    done
    if [[ "$PHPMYADMIN_ENABLED" == "yes" && "$DB_ENABLED" == "no" ]]; then
        echo "ERROR: PHPMYADMIN_ENABLED=yes requires DB_ENABLED=yes (phpMyAdmin has no database to administer otherwise)"
        exit 1
    fi
    if [[ "$ROOT_PASSWORD_AUTH_ENABLED" == "yes" && "$SSH_PASSWORD_AUTH_ENABLED" != "yes" ]]; then
        echo "ERROR: ROOT_PASSWORD_AUTH_ENABLED=yes requires SSH_PASSWORD_AUTH_ENABLED=yes (sshd password authentication must be on server-wide before root can use one)"
        exit 1
    fi

    local missing=()
    [[ -z "$DOMAIN_NAME" ]]           && missing+=("DOMAIN_NAME")
    [[ -z "$PHP_VERSION" ]]           && missing+=("PHP_VERSION")
    [[ "$COMPOSER_ENABLED" == "yes" && -z "$COMPOSER_VERSION" ]] && missing+=("COMPOSER_VERSION")
    if [[ "$DB_ENABLED" == "yes" ]]; then
        [[ -z "$DB_ENGINE" ]]         && missing+=("DB_ENGINE")
        [[ -z "$DB_VERSION" ]]        && missing+=("DB_VERSION")
        [[ -z "$DB_ROOT_PASSWORD" ]]  && missing+=("DB_ROOT_PASSWORD")
    fi
    [[ "$OPENSEARCH_ENABLED" == "yes" && -z "$OPENSEARCH_VERSION" ]] && missing+=("OPENSEARCH_VERSION")
    [[ "$VARNISH_ENABLED" == "yes" && -z "$VARNISH_VERSION" ]] && missing+=("VARNISH_VERSION")
    [[ -z "$RESTRICTED_USERNAME" ]]       && missing+=("RESTRICTED_USERNAME")
    # Some servers only accept key-based SSH login, others require passwords —
    # each account picks its own credential independently (root doesn't have
    # to switch to a password just because the restricted user does, and
    # vice versa). Whichever credential isn't required for an account is
    # still optional and gets deployed/set if supplied.
    if [[ "$SSH_PASSWORD_AUTH_ENABLED" == "yes" ]]; then
        [[ -z "$RESTRICTED_USER_PASSWORD" ]] && missing+=("RESTRICTED_USER_PASSWORD")
    else
        [[ -z "$RESTRICTED_USER_SSH_PUBLIC_KEY" ]] && missing+=("RESTRICTED_USER_SSH_PUBLIC_KEY")
    fi
    if [[ "$ROOT_PASSWORD_AUTH_ENABLED" == "yes" ]]; then
        [[ -z "$ROOT_USER_PASSWORD" ]] && missing+=("ROOT_USER_PASSWORD")
    else
        [[ -z "$ROOT_USER_SSH_PUBLIC_KEY" ]] && missing+=("ROOT_USER_SSH_PUBLIC_KEY")
    fi
    if [[ "$PHPMYADMIN_ENABLED" == "yes" ]]; then
        [[ -z "$PMA_PORT" ]]          && missing+=("PMA_PORT")
        [[ -z "$PMA_USERNAME" ]]      && missing+=("PMA_USERNAME")
        [[ -z "$PMA_PASSWORD" ]]      && missing+=("PMA_PASSWORD")
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing required config variables:"
        for var in "${missing[@]}"; do echo "  - $var"; done
        exit 1
    fi
    if ! [[ "$PHP_VERSION" =~ ^7\.[0-4]$|^8\.[0-5]$ ]]; then
        echo "ERROR: Invalid PHP_VERSION '$PHP_VERSION'. Must be 7.0–7.4 or 8.0–8.5"
        exit 1
    fi
    if [[ "$DB_ENABLED" == "yes" ]]; then
        if [[ "$DB_ENGINE" != "mariadb" && "$DB_ENGINE" != "mysql" ]]; then
            echo "ERROR: Invalid DB_ENGINE '$DB_ENGINE'. Must be 'mariadb' or 'mysql'"
            exit 1
        fi
        if [[ "$DB_ENGINE" == "mariadb" ]]; then
            if ! [[ "$DB_VERSION" =~ ^(10\.[6-9]|10\.[1-9][0-9]|11\.[0-9]+)$ ]]; then
                echo "ERROR: Invalid DB_VERSION '$DB_VERSION' for DB_ENGINE=mariadb. Must be 10.6+ or 11.x (e.g., 10.11, 11.4, 11.8)"
                exit 1
            fi
        else
            local valid_mysql_versions=("5.6" "5.7" "8.0" "8.4")
            local is_valid_mysql=0
            for v in "${valid_mysql_versions[@]}"; do
                [[ "$DB_VERSION" == "$v" ]] && is_valid_mysql=1 && break
            done
            if [[ $is_valid_mysql -eq 0 ]]; then
                echo "ERROR: Invalid DB_VERSION '$DB_VERSION' for DB_ENGINE=mysql. Must be one of: ${valid_mysql_versions[*]}"
                exit 1
            fi
        fi
    fi
    if [[ "$COMPOSER_ENABLED" == "yes" && "$COMPOSER_VERSION" != "1" && "$COMPOSER_VERSION" != "2" ]]; then
        echo "ERROR: Invalid COMPOSER_VERSION '$COMPOSER_VERSION'. Must be '1' or '2'"
        exit 1
    fi
    if [[ "$VARNISH_ENABLED" == "yes" ]]; then
        local valid_varnish_versions=("6.0" "7.0" "7.4" "7.5")
        local is_valid_varnish=0
        for v in "${valid_varnish_versions[@]}"; do
            [[ "$VARNISH_VERSION" == "$v" ]] && is_valid_varnish=1 && break
        done
        if [[ $is_valid_varnish -eq 0 ]]; then
            echo "ERROR: Invalid VARNISH_VERSION '$VARNISH_VERSION'. Must be one of: ${valid_varnish_versions[*]}"
            exit 1
        fi
    fi
    if [[ "$PHPMYADMIN_ENABLED" == "yes" ]]; then
        if ! [[ "$PMA_PORT" =~ ^[0-9]+$ ]] || [ "$PMA_PORT" -lt 1 ] || [ "$PMA_PORT" -gt 65535 ]; then
            echo "ERROR: Invalid PMA_PORT '$PMA_PORT'. Must be 1–65535"
            exit 1
        fi
    fi
    if [[ "$SSH_PASSWORD_AUTH_ENABLED" == "yes" ]]; then
        [[ ${#RESTRICTED_USER_PASSWORD} -lt 12 ]] && { echo "ERROR: RESTRICTED_USER_PASSWORD must be at least 12 characters"; exit 1; }
    fi
    if [[ "$ROOT_PASSWORD_AUTH_ENABLED" == "yes" ]]; then
        [[ ${#ROOT_USER_PASSWORD} -lt 12 ]] && { echo "ERROR: ROOT_USER_PASSWORD must be at least 12 characters"; exit 1; }
    fi
}

validate_ssl_config() {
    ENABLE_SSL_TERMINATION="${ENABLE_SSL_TERMINATION:-yes}"

    if [[ "$ENABLE_SSL_TERMINATION" != "yes" && "$ENABLE_SSL_TERMINATION" != "no" ]]; then
        print_error "Invalid ENABLE_SSL_TERMINATION '${ENABLE_SSL_TERMINATION}'. Must be 'yes' or 'no'"
        exit 1
    fi

    if [[ "$ENABLE_SSL_TERMINATION" == "no" ]]; then
        if [[ -n "$SSL_CERT_PATH" || -n "$SSL_KEY_PATH" ]]; then
            print_warning "SSL_CERT_PATH/SSL_KEY_PATH are set but ENABLE_SSL_TERMINATION=no — they will be ignored"
        fi
        return 0
    fi

    if [[ -z "$SSL_CERT_PATH" && -z "$SSL_KEY_PATH" ]]; then
        print_message "ENABLE_SSL_TERMINATION=yes with no custom cert — a self-signed certificate will be generated"
        return 0
    fi

    if [[ -z "$SSL_CERT_PATH" || -z "$SSL_KEY_PATH" ]]; then
        print_error "SSL_CERT_PATH and SSL_KEY_PATH must both be set together (only one was provided)"
        exit 1
    fi
    if [[ ! -f "$SSL_CERT_PATH" ]]; then
        print_error "SSL_CERT_PATH does not exist: $SSL_CERT_PATH"
        exit 1
    fi
    if [[ ! -f "$SSL_KEY_PATH" ]]; then
        print_error "SSL_KEY_PATH does not exist: $SSL_KEY_PATH"
        exit 1
    fi
    if ! openssl x509 -in "$SSL_CERT_PATH" -noout -checkend 0 >/dev/null 2>&1; then
        print_error "SSL_CERT_PATH is not a valid certificate or has expired: $SSL_CERT_PATH"
        exit 1
    fi

    local cert_pubkey key_pubkey
    cert_pubkey=$(openssl x509 -in "$SSL_CERT_PATH" -noout -pubkey 2>/dev/null)
    key_pubkey=$(openssl pkey -in "$SSL_KEY_PATH" -pubout 2>/dev/null)
    if [[ -z "$cert_pubkey" || -z "$key_pubkey" || "$cert_pubkey" != "$key_pubkey" ]]; then
        print_error "SSL_CERT_PATH and SSL_KEY_PATH do not match (certificate/key mismatch)"
        exit 1
    fi

    print_message "Custom SSL certificate validated: $SSL_CERT_PATH"
}

validate_ssh_public_key() {
    local key="$1"
    [[ -z "$key" ]] && echo "ERROR: ROOT_USER_SSH_PUBLIC_KEY is empty" && return 1
    key=$(echo "$key" | xargs)
    if ! [[ "$key" =~ ^(ssh-rsa|ssh-dss|ecdsa-sha2-nistp|ssh-ed25519)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]]+.*)?$ ]]; then
        echo "ERROR: ROOT_USER_SSH_PUBLIC_KEY has invalid format"
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

# calculate_resource_allocations — single source of truth for every RAM-based
# sizing decision, computed up front from TOTAL_RAM_GB/CPU_CORES before any
# module installs anything. Modules php, opensearch, valkey, database, and
# varnish consume the variables this sets rather than calculating their own;
# this also lets validate_resource_allocations run *before* installation
# instead of after, when aborting would be pointless.
#
# Sets: PHP_MEMORY_LIMIT, PHP_MAX_CHILDREN, PHP_START_SERVERS, PHP_MIN_SPARE,
#       PHP_MAX_SPARE, MARIADB_BUFFER_POOL_MB, OPENSEARCH_HEAP, VALKEY_MEMORY,
#       VARNISH_CACHE_MB, OS_RESERVE_MB
# Uses: TOTAL_RAM_GB, CPU_CORES, DB_ENABLED, OPENSEARCH_ENABLED,
#       VALKEY_ENABLED, VARNISH_ENABLED

calculate_resource_allocations() {
    local RAM_MB=$((TOTAL_RAM_GB * 1024))

    # OS/overhead reserve — a flat 512MB undercounts MariaDB's non-pool
    # overhead, OpenSearch's off-heap memory, and page cache on bigger boxes,
    # so it scales with RAM (with 512MB as a floor for small instances).
    OS_RESERVE_MB=$((RAM_MB * 5 / 100))
    [ "$OS_RESERVE_MB" -lt 512 ] && OS_RESERVE_MB=512

    # ── Fixed-size services first — each is fully resident once running, so
    # none of them get a "typical usage" discount the way PHP-FPM does below.

    if [[ "${DB_ENABLED:-yes}" == "yes" ]]; then
        # 25-30% of RAM for InnoDB's pool. 50% is the rule for a *dedicated*
        # DB server; this is a shared single-box stack with PHP-FPM,
        # OpenSearch, Valkey, and Varnish all competing for the same RAM.
        if [ "$TOTAL_RAM_GB" -le 8 ]; then
            MARIADB_BUFFER_POOL_MB=$((RAM_MB * 25 / 100))
        else
            MARIADB_BUFFER_POOL_MB=$((RAM_MB * 30 / 100))
        fi
        [ "$MARIADB_BUFFER_POOL_MB" -lt 256 ] && MARIADB_BUFFER_POOL_MB=256
    else
        MARIADB_BUFFER_POOL_MB=0
    fi

    if [[ "${OPENSEARCH_ENABLED:-yes}" == "yes" ]]; then
        # 25% of RAM, capped at 8GB; capped at 1GB on servers with <=6GB to
        # leave headroom for PHP-FPM and the OS. The standalone "50% of RAM"
        # rule (still fine for a dedicated search node) left no room for
        # MariaDB/Valkey/Varnish/PHP-FPM once all of them were counted in the
        # same validator — this is the shared single-box equivalent of the
        # InnoDB pool's 50%-to-25/30% rebalance above.
        OPENSEARCH_HEAP=$((RAM_MB * 25 / 100))
        [ "$OPENSEARCH_HEAP" -gt 8192 ] && OPENSEARCH_HEAP=8192
        if [ "$TOTAL_RAM_GB" -le 6 ] && [ "$OPENSEARCH_HEAP" -gt 1024 ]; then
            OPENSEARCH_HEAP=1024
        fi
        [ "$OPENSEARCH_HEAP" -lt 1024 ] && OPENSEARCH_HEAP=1024
    else
        OPENSEARCH_HEAP=0
    fi

    if [[ "${VALKEY_ENABLED:-yes}" == "yes" ]]; then
        # 10% of RAM, capped at 2GB, minimum 256MB.
        VALKEY_MEMORY=$((RAM_MB / 10))
        [ "$VALKEY_MEMORY" -gt 2048 ] && VALKEY_MEMORY=2048
        [ "$VALKEY_MEMORY" -lt 256 ]  && VALKEY_MEMORY=256
    else
        VALKEY_MEMORY=0
    fi

    if [[ "${VARNISH_ENABLED:-yes}" == "yes" ]]; then
        # 5% of RAM for the malloc cache, capped at 2GB, minimum 256MB.
        VARNISH_CACHE_MB=$((RAM_MB * 5 / 100))
        [ "$VARNISH_CACHE_MB" -gt 2048 ] && VARNISH_CACHE_MB=2048
        [ "$VARNISH_CACHE_MB" -lt 256 ]  && VARNISH_CACHE_MB=256
    else
        VARNISH_CACHE_MB=0
    fi

    # ── PHP-FPM gets whatever's left ───────────────────────────────────────────
    # PHP_MAX_CHILDREN is derived from the remaining memory instead of a
    # hardcoded 20/100/150 per RAM bracket, so it adapts to whichever other
    # services are actually enabled on this box.

    if [ "$TOTAL_RAM_GB" -le 6 ]; then
        PHP_MEMORY_LIMIT="2G"
    elif [ "$TOTAL_RAM_GB" -le 16 ]; then
        PHP_MEMORY_LIMIT="4G"
    else
        PHP_MEMORY_LIMIT="6G"
    fi

    local php_memory_mb=${PHP_MEMORY_LIMIT%G}
    php_memory_mb=$((php_memory_mb * 1024))

    local fixed_total=$((MARIADB_BUFFER_POOL_MB + OPENSEARCH_HEAP + VALKEY_MEMORY + VARNISH_CACHE_MB + OS_RESERVE_MB))
    local remaining=$((RAM_MB - fixed_total))
    # Always leave room for at least one child's average footprint, even on a
    # box so small the fixed services already ate everything — the resulting
    # overcommit is exactly what validate_resource_allocations exists to flag.
    local avg_rss_per_child=$((php_memory_mb * 15 / 100))
    [ "$remaining" -lt "$avg_rss_per_child" ] && remaining=$avg_rss_per_child

    PHP_MAX_CHILDREN=$((remaining / avg_rss_per_child))
    [ "$PHP_MAX_CHILDREN" -lt 5 ] && PHP_MAX_CHILDREN=5

    PHP_START_SERVERS=$((CPU_CORES * 2))
    PHP_MIN_SPARE=$((CPU_CORES))
    PHP_MAX_SPARE=$((CPU_CORES * 4))

    [ "$PHP_START_SERVERS" -lt 5 ]  && PHP_START_SERVERS=5
    [ "$PHP_MIN_SPARE" -lt 3 ]      && PHP_MIN_SPARE=3
    [ "$PHP_MAX_SPARE" -lt 10 ]     && PHP_MAX_SPARE=10

    # Enforce PHP-FPM constraint: min_spare <= start_servers <= max_spare <= max_children
    [ "$PHP_MAX_SPARE" -ge "$PHP_MAX_CHILDREN" ] && PHP_MAX_SPARE=$((PHP_MAX_CHILDREN - 1))
    [ "$PHP_MAX_SPARE" -lt 1 ]                   && PHP_MAX_SPARE=1
    [ "$PHP_START_SERVERS" -gt "$PHP_MAX_SPARE" ] && PHP_START_SERVERS=$PHP_MAX_SPARE
    [ "$PHP_MIN_SPARE" -gt "$PHP_START_SERVERS" ] && PHP_MIN_SPARE=$PHP_START_SERVERS

    print_message "Resource tiers: PHP ${PHP_MEMORY_LIMIT} × ${PHP_MAX_CHILDREN} children, MariaDB ${MARIADB_BUFFER_POOL_MB}MB, OpenSearch ${OPENSEARCH_HEAP}MB, Valkey ${VALKEY_MEMORY}MB, Varnish ${VARNISH_CACHE_MB}MB, OS reserve ${OS_RESERVE_MB}MB"
}

validate_resource_allocations() {
    local PHP_MEMORY_MB=${PHP_MEMORY_LIMIT%G}
    PHP_MEMORY_MB=$((PHP_MEMORY_MB * 1024))
    local PHP_FPM_MAX_MEMORY=$((PHP_MAX_CHILDREN * PHP_MEMORY_MB * 15 / 100))
    local TOTAL_ALLOCATED=$((PHP_FPM_MAX_MEMORY + OPENSEARCH_HEAP + VALKEY_MEMORY + MARIADB_BUFFER_POOL_MB + VARNISH_CACHE_MB))
    local SYSTEM_RAM_MB=$((TOTAL_RAM_GB * 1024))
    local AVAILABLE=$((SYSTEM_RAM_MB - OS_RESERVE_MB))

    print_message "Resource Allocation Summary:"
    echo "  System RAM:          ${TOTAL_RAM_GB}GB (${SYSTEM_RAM_MB}MB)"
    echo "  OS/overhead reserve: ${OS_RESERVE_MB}MB"
    echo "  PHP-FPM:             ~${PHP_FPM_MAX_MEMORY}MB (${PHP_MAX_CHILDREN} children × ${PHP_MEMORY_MB}MB × 15% avg RSS)"
    echo "  MariaDB/MySQL pool:  ${MARIADB_BUFFER_POOL_MB}MB"
    echo "  OpenSearch heap:     ${OPENSEARCH_HEAP}MB"
    echo "  Valkey:              ${VALKEY_MEMORY}MB"
    echo "  Varnish cache:       ${VARNISH_CACHE_MB}MB"
    echo "  Total allocated:     ~${TOTAL_ALLOCATED}MB"
    echo "  Available:           ${AVAILABLE}MB"
    echo ""

    local warnings=() errors=()
    [ "$PHP_MEMORY_MB" -gt $((TOTAL_RAM_GB * 1024 / 2)) ] && warnings+=("PHP memory limit > 50% of total RAM")
    [ "$PHP_MAX_CHILDREN" -gt 200 ]                        && warnings+=("PHP-FPM max_children (${PHP_MAX_CHILDREN}) is very high")
    [ "$OPENSEARCH_HEAP" -gt $((TOTAL_RAM_GB * 1024 / 2)) ] && warnings+=("OpenSearch heap > 50% of total RAM")
    [ "$OPENSEARCH_HEAP" -gt 0 ] && [ "$OPENSEARCH_HEAP" -lt 1024 ] && warnings+=("OpenSearch heap (${OPENSEARCH_HEAP}MB) < 1GB — search performance may be poor")
    [ "$VALKEY_MEMORY" -gt 0 ] && [ "$VALKEY_MEMORY" -lt 256 ]      && warnings+=("Valkey memory (${VALKEY_MEMORY}MB) is very low")
    [ "$TOTAL_ALLOCATED" -gt $((AVAILABLE * 80 / 100)) ]   && warnings+=("Resource allocation uses >80% of available memory")
    [ "$TOTAL_ALLOCATED" -gt "$AVAILABLE" ]                && errors+=("Total allocation (${TOTAL_ALLOCATED}MB) EXCEEDS available memory by $((TOTAL_ALLOCATED - AVAILABLE))MB")

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

# ── Safe authorized_keys writer ───────────────────────────────────────────────
# write_authorized_key_safely <target_file> <configured_key> <owner_label> <config_var_name>
#
# Used by modules security (root) and system (restricted user) instead of a
# blind `echo ... > authorized_keys`, which would silently destroy a
# cloud-init-provisioned key. Combined with password auth being disabled
# (module: security), overwriting the wrong key is a permanent lockout — so
# any pre-existing key that doesn't match what's configured is a hard stop,
# not a silent overwrite.

write_authorized_key_safely() {
    local target_file="$1"
    local configured_key="$2"
    local owner_label="$3"
    local config_var_name="$4"

    if [[ ! -s "$target_file" ]]; then
        echo "$configured_key" > "$target_file"
        return 0
    fi

    local existing
    existing="$(cat "$target_file")"

    if [[ "$existing" == "$configured_key" ]]; then
        print_message "authorized_keys for ${owner_label} already contains the configured key — leaving it untouched."
        return 0
    fi

    print_error "Refusing to overwrite existing SSH key(s) for ${owner_label} — this looks like a pre-existing key"
    print_error "(e.g. provisioned by your cloud provider's cloud-init) that doesn't match ${config_var_name}."
    print_error ""
    print_error "  File:                ${target_file}"
    print_error "  Currently contains:"
    while IFS= read -r existing_line; do
        [[ -n "$existing_line" ]] && print_error "    ${existing_line}"
    done <<< "$existing"
    print_error "  Configured key (${config_var_name}):"
    print_error "    ${configured_key}"
    print_error ""
    print_error "To resolve, either:"
    print_error "  1. Update ${config_var_name} in server-setup.conf to match the key already on the server, then re-run; or"
    print_error "  2. If you intend to replace it, back up/clear ${target_file} yourself first, then re-run."
    exit 1
}

# ── Module resolution ─────────────────────────────────────────────────────────
# resolve_module <modules_dir> <token>
# Accepts: a 1-based position in the MODULE_ORDER array ("3"), a basename with
# or without .sh ("php" / "php.sh"), or a full path. MODULE_ORDER (set by
# setup-ubuntu24.sh) is the single source of truth for run order now that
# module filenames no longer carry a numeric prefix.
# Prints the resolved absolute path, or returns 1 on failure.

resolve_module() {
    local modules_dir="$1"
    local token="$2"

    [[ "$token" == /* ]] && echo "$token" && return 0

    if [[ "$token" =~ ^[0-9]+$ ]]; then
        local idx=$((10#$token))
        if [[ $idx -lt 1 || $idx -gt ${#MODULE_ORDER[@]} ]]; then
            echo "ERROR: No module at position $token (valid range: 1-${#MODULE_ORDER[@]})" >&2
            return 1
        fi
        echo "${modules_dir}/${MODULE_ORDER[$((idx - 1))]}.sh"
        return 0
    fi

    if [[ "$token" != */* ]]; then
        local candidate="${modules_dir}/${token}"
        [[ -f "$candidate" ]] && echo "$candidate" && return 0
        candidate="${modules_dir}/${token}.sh"
        [[ -f "$candidate" ]] && echo "$candidate" && return 0
        echo "ERROR: No module named '$token' in $modules_dir" >&2
        return 1
    fi

    local rel="${token}"
    echo "$rel"
}
