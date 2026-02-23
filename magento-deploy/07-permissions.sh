# Module 07 — Set file permissions
# Ownership (restricted_user:www-data) is established by server-setup/01-system.sh.
# Uses: MAGENTO_DIR
#
# Base:      dirs 750, files 640
# Writable:  var/ generated/ pub/static/ pub/media/ app/etc/ — dirs 770, files 660
# Executable: bin/magento

print_step "Setting file permissions on ${MAGENTO_DIR}..."

find "${MAGENTO_DIR}" -type d -exec chmod 750 {} +
find "${MAGENTO_DIR}" -type f -exec chmod 640 {} +

# Directories that PHP-FPM and the app user must write to
for _dir in var generated pub/static pub/media app/etc; do
    _path="${MAGENTO_DIR}/${_dir}"
    if [[ -d "${_path}" ]]; then
        find "${_path}" -type d -exec chmod 770 {} +
        find "${_path}" -type f -exec chmod 660 {} +
    fi
done

chmod 750 "${MAGENTO_DIR}/bin/magento"

print_message "Ownership: ${RESTRICTED_USER}:www-data"
print_message "Permissions set — writable dirs: var generated pub/static pub/media app/etc"
