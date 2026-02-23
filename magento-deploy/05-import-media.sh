# Module 06 — Import media files into pub/media/
# Uses: MEDIA_PATH, MAGENTO_DIR, RESTRICTED_USER
# Supported formats: directory (rsync), .tar.gz / .tgz, .tar, .zip

if [[ -z "${MEDIA_PATH:-}" ]]; then
    print_warning "MEDIA_PATH is not set — skipping media import."
else
    if [[ ! -e "${MEDIA_PATH}" ]]; then
        print_warning "Media path not found: ${MEDIA_PATH} — skipping media import."
    else
        MEDIA_TARGET="${MAGENTO_DIR}/pub/media"
        mkdir -p "${MEDIA_TARGET}"

        print_step "Importing media from: ${MEDIA_PATH}"

        if [[ "${MEDIA_PATH}" == *.tar.gz ]] || [[ "${MEDIA_PATH}" == *.tgz ]]; then
            tar -xzf "${MEDIA_PATH}" -C "${MEDIA_TARGET}/" --strip-components=1
        elif [[ "${MEDIA_PATH}" == *.tar ]]; then
            tar -xf "${MEDIA_PATH}" -C "${MEDIA_TARGET}/" --strip-components=1
        elif [[ "${MEDIA_PATH}" == *.zip ]]; then
            unzip -q "${MEDIA_PATH}" -d "${MEDIA_TARGET}/"
        elif [[ -d "${MEDIA_PATH}" ]]; then
            rsync -a --progress "${MEDIA_PATH}/" "${MEDIA_TARGET}/"
        else
            print_error "Unsupported media format: ${MEDIA_PATH}"
            print_error "Supported: directory, .tar.gz, .tgz, .tar, .zip"
            exit 1
        fi

        chown -R "${RESTRICTED_USER}:www-data" "${MEDIA_TARGET}"
        print_message "Media import complete."
    fi
fi
