# Module 01 — Create Magento database and restricted DB user
# Uses: DB_NAME, DB_USER, DB_PASSWORD, DB_HOST, MARIADB_ROOT_PASSWORD
# The restricted DB user is granted access ONLY to this database.

print_step "Creating database '${DB_NAME}' and restricted user '${DB_USER}'@'${DB_HOST}'..."

mariadb -uroot -p"${MARIADB_ROOT_PASSWORD}" <<MYSQL_EOF
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS '${DB_USER}'@'${DB_HOST}'
    IDENTIFIED BY '${DB_PASSWORD}';

GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'${DB_HOST}';

FLUSH PRIVILEGES;
MYSQL_EOF

print_message "Database '${DB_NAME}' created."
print_message "User '${DB_USER}'@'${DB_HOST}' created with full access to '${DB_NAME}' only."
