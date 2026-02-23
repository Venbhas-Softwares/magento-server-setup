# Module 01 — System update, essential packages, restricted user, and Magento web root
# Sets web root ownership to restricted_user:www-data (authoritative — not repeated elsewhere).
# Uses: RESTRICTED_USER, DOMAIN_NAME
# Sets: MAGENTO_DIR (used by modules 08 and 11)

print_step "Updating system packages..."
apt update && apt upgrade -y

print_step "Installing essential packages..."
apt install -y software-properties-common apt-transport-https ca-certificates \
    curl wget git unzip vim nano htop gnupg2 lsb-release

print_step "Creating restricted user: ${RESTRICTED_USER}..."
id -u "${RESTRICTED_USER}" &>/dev/null || useradd -m -d /home/${RESTRICTED_USER} -s /bin/bash ${RESTRICTED_USER}
usermod -a -G www-data ${RESTRICTED_USER}
print_message "Restricted user configured with no sudo and no SSH access (reachable via: su - ${RESTRICTED_USER})"

print_step "Creating Magento web root..."
MAGENTO_DIR="/var/www/${DOMAIN_NAME}"
mkdir -p "$MAGENTO_DIR"
chown -R ${RESTRICTED_USER}:www-data "$MAGENTO_DIR"
chmod -R 755 "$MAGENTO_DIR"
