# Module 08 — Composer installation
# Uses: RESTRICTED_USER, COMPOSER_VERSION

print_step "Installing Composer ${COMPOSER_VERSION}..."
COMPOSER_INSTALLER="/tmp/composer-installer.php"
COMPOSER_INSTALLER_SIG="/tmp/composer-installer.php.sig"

add_temp_file "$COMPOSER_INSTALLER"
add_temp_file "$COMPOSER_INSTALLER_SIG"

print_message "Downloading Composer installer..."
if ! curl -sS https://getcomposer.org/installer -o "$COMPOSER_INSTALLER"; then
    print_error "Failed to download Composer installer"
    exit 1
fi

print_message "Downloading Composer installer signature..."
if ! curl -sS https://composer.github.io/installer.sig -o "$COMPOSER_INSTALLER_SIG"; then
    print_error "Failed to download Composer installer hash"
    exit 1
fi

print_message "Verifying Composer installer signature..."
EXPECTED_HASH=$(tr -d '[:space:]' < "$COMPOSER_INSTALLER_SIG")
ACTUAL_HASH=$(php -r "echo hash_file('sha384', '$COMPOSER_INSTALLER');")
if [ -z "$EXPECTED_HASH" ] || [ "$EXPECTED_HASH" != "$ACTUAL_HASH" ]; then
    print_error "Composer installer signature verification FAILED — possible tampering"
    exit 1
fi
print_message "✓ Composer installer signature verified successfully"

print_message "Installing Composer..."
if [ "$COMPOSER_VERSION" = "1" ]; then
    if ! php "$COMPOSER_INSTALLER" --install-dir=/usr/local/bin --filename=composer --1; then
        print_error "Composer installation failed"; exit 1
    fi
else
    if ! php "$COMPOSER_INSTALLER" --install-dir=/usr/local/bin --filename=composer --2; then
        print_error "Composer installation failed"; exit 1
    fi
fi

# Verify installation as restricted user — avoids Composer's root warning and
# any network checks that cause hangs when run as root
if ! sudo -u "${RESTRICTED_USER}" COMPOSER_NO_INTERACTION=1 \
        /usr/local/bin/composer --version --no-interaction >/dev/null 2>&1; then
    print_error "Composer installation verification failed"
    exit 1
fi

print_message "Composer ${COMPOSER_VERSION} installed successfully"
chmod +x /usr/local/bin/composer

print_step "Confirming Composer is accessible for restricted user..."
sudo -u "${RESTRICTED_USER}" COMPOSER_NO_INTERACTION=1 composer --version --no-interaction \
    >/dev/null 2>&1 && print_message "Composer is accessible for ${RESTRICTED_USER}"
