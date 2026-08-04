# Module php — PHP installation and configuration
# Uses: PHP_VERSION, PHP_MEMORY_LIMIT, PHP_MAX_CHILDREN, PHP_START_SERVERS,
#       PHP_MIN_SPARE, PHP_MAX_SPARE (all set by lib/functions.sh::calculate_resource_allocations)

print_message "PHP resource allocation: Memory=${PHP_MEMORY_LIMIT}, MaxChildren=${PHP_MAX_CHILDREN}, StartServers=${PHP_START_SERVERS}"

# ── Installation ──────────────────────────────────────────────────────────────

print_step "Installing PHP ${PHP_VERSION} and extensions..."
add-apt-repository ppa:ondrej/php -y
apt update

# php-json is built into PHP 8.0+ core.
# php-pcntl is compiled into FPM/CLI in PHP 8.4+'s PPA build.
PHP_EXTRA_PKGS=""
if [[ "$PHP_VERSION" < "8.0" ]]; then
    PHP_EXTRA_PKGS="php${PHP_VERSION}-json"
fi
if [[ "$PHP_VERSION" < "8.4" ]]; then
    PHP_EXTRA_PKGS="$PHP_EXTRA_PKGS php${PHP_VERSION}-pcntl"
fi

# shellcheck disable=SC2086
apt install -y php${PHP_VERSION}-fpm php${PHP_VERSION}-cli php${PHP_VERSION}-common \
    php${PHP_VERSION}-mysql php${PHP_VERSION}-zip php${PHP_VERSION}-gd \
    php${PHP_VERSION}-mbstring php${PHP_VERSION}-curl php${PHP_VERSION}-xml \
    php${PHP_VERSION}-bcmath php${PHP_VERSION}-intl \
    php${PHP_VERSION}-soap php${PHP_VERSION}-xsl php${PHP_VERSION}-gmp \
    php${PHP_VERSION}-opcache php${PHP_VERSION}-redis $PHP_EXTRA_PKGS

print_step "Configuring PHP settings..."
PHP_INI="/etc/php/${PHP_VERSION}/fpm/php.ini"
PHP_CLI_INI="/etc/php/${PHP_VERSION}/cli/php.ini"

for INI_FILE in "$PHP_INI" "$PHP_CLI_INI"; do
    sed -i "s/memory_limit = .*/memory_limit = ${PHP_MEMORY_LIMIT}/"            "$INI_FILE"
    sed -i "s/max_execution_time = .*/max_execution_time = 1800/"               "$INI_FILE"
    sed -i "s/max_input_time = .*/max_input_time = 1800/"                       "$INI_FILE"
    sed -i "s/upload_max_filesize = .*/upload_max_filesize = 64M/"              "$INI_FILE"
    sed -i "s/post_max_size = .*/post_max_size = 64M/"                          "$INI_FILE"
    sed -i "s/max_input_vars = .*/max_input_vars = 5000/"                       "$INI_FILE"
    sed -i "s/;date.timezone.*/date.timezone = UTC/"                            "$INI_FILE"
    sed -i "s/;opcache.enable=.*/opcache.enable=1/"                             "$INI_FILE"
    sed -i "s/;opcache.enable_cli=.*/opcache.enable_cli=1/"                     "$INI_FILE"
    sed -i "s/;opcache.memory_consumption=.*/opcache.memory_consumption=512/"   "$INI_FILE"
    sed -i "s/;opcache.max_accelerated_files=.*/opcache.max_accelerated_files=60000/" "$INI_FILE"
    sed -i "s/;opcache.validate_timestamps=.*/opcache.validate_timestamps=0/"   "$INI_FILE"
    sed -i "s/;opcache.interned_strings_buffer=.*/opcache.interned_strings_buffer=64/" "$INI_FILE"
    sed -i "s/;opcache.save_comments=.*/opcache.save_comments=1/"               "$INI_FILE"
    sed -i "s/;opcache.jit_buffer_size=.*/opcache.jit_buffer_size=256M/"       "$INI_FILE"
    sed -i "s/;opcache.jit=.*/opcache.jit=tracing/"                            "$INI_FILE"
done

print_step "Configuring PHP-FPM pool..."
PHP_FPM_CONF="/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf"
sed -i "s/pm.max_children = .*/pm.max_children = ${PHP_MAX_CHILDREN}/"         "$PHP_FPM_CONF"
sed -i "s/pm.start_servers = .*/pm.start_servers = ${PHP_START_SERVERS}/"      "$PHP_FPM_CONF"
sed -i "s/pm.min_spare_servers = .*/pm.min_spare_servers = ${PHP_MIN_SPARE}/"  "$PHP_FPM_CONF"
sed -i "s/pm.max_spare_servers = .*/pm.max_spare_servers = ${PHP_MAX_SPARE}/"  "$PHP_FPM_CONF"

systemctl restart php${PHP_VERSION}-fpm
systemctl enable  php${PHP_VERSION}-fpm
