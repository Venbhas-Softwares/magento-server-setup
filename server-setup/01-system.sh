# Module 01 — System update, essential packages, restricted user, and Magento web root
# Sets web root ownership to restricted_user:www-data (authoritative — not repeated elsewhere).
# Uses: RESTRICTED_USERNAME, DOMAIN_NAME
# Sets: MAGENTO_DIR (used by modules 08 and 11)

print_step "Updating system packages..."
apt update && apt upgrade -y

print_step "Installing essential packages..."
apt install -y software-properties-common apt-transport-https ca-certificates \
    curl wget git unzip vim nano htop gnupg2 lsb-release

print_step "Creating restricted user: ${RESTRICTED_USERNAME}..."
id -u "${RESTRICTED_USERNAME}" &>/dev/null || useradd -m -d /home/${RESTRICTED_USERNAME} -s /bin/bash ${RESTRICTED_USERNAME}
usermod -a -G www-data ${RESTRICTED_USERNAME}

print_step "Setting up SSH key authentication for restricted user '${RESTRICTED_USERNAME}'..."
_ru_home="/home/${RESTRICTED_USERNAME}"
mkdir -p "${_ru_home}/.ssh"
echo "$RESTRICTED_USER_SSH_PUBLIC_KEY" > "${_ru_home}/.ssh/authorized_keys"
chmod 700 "${_ru_home}/.ssh"
chmod 600 "${_ru_home}/.ssh/authorized_keys"
chown -R "${RESTRICTED_USERNAME}:${RESTRICTED_USERNAME}" "${_ru_home}/.ssh"

print_message "Restricted user configured with no sudo, key-based SSH login enabled (also reachable via: su - ${RESTRICTED_USERNAME})"

print_step "Creating Magento web root..."
MAGENTO_DIR="/var/www/${DOMAIN_NAME}"
mkdir -p "$MAGENTO_DIR"
chown -R ${RESTRICTED_USERNAME}:www-data "$MAGENTO_DIR"
chmod -R 755 "$MAGENTO_DIR"
