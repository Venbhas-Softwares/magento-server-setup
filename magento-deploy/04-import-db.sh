# Module 05 — Import database dump using the MySQL root user
# Uses: DB_DUMP_PATH, DB_NAME, MARIADB_ROOT_PASSWORD
# Root credentials are used to avoid permission issues with LOAD DATA and triggers.
# Supports plain .sql files and gzip-compressed .sql.gz files.

if [[ -z "${DB_DUMP_PATH:-}" ]]; then
    print_warning "DB_DUMP_PATH is not set — skipping database import."
    print_warning "You will need to import the database manually before using Magento."
else
    if [[ ! -f "${DB_DUMP_PATH}" ]]; then
        print_error "DB dump file not found: ${DB_DUMP_PATH}"
        exit 1
    fi

    print_step "Importing database dump into '${DB_NAME}'..."
    print_message "Source: ${DB_DUMP_PATH}"

    if [[ "${DB_DUMP_PATH}" == *.gz ]]; then
        zcat "${DB_DUMP_PATH}" | mysql -uroot -p"${MARIADB_ROOT_PASSWORD}" "${DB_NAME}"
    else
        mysql -uroot -p"${MARIADB_ROOT_PASSWORD}" "${DB_NAME}" < "${DB_DUMP_PATH}"
    fi

    _table_count=$(mysql -uroot -p"${MARIADB_ROOT_PASSWORD}" -N -e \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}';" 2>/dev/null || echo 0)
    print_message "Database import complete — ${_table_count} tables in '${DB_NAME}'."
fi
