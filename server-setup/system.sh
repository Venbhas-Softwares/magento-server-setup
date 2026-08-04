# Module system — System update, essential packages, restricted user, and application web root
# Sets web root ownership to restricted_user:www-data (authoritative — not repeated elsewhere).
# Uses: RESTRICTED_USERNAME, DOMAIN_NAME
# Sets: WEB_ROOT (used by modules vhost and finalize)

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

print_step "Creating application web root..."
WEB_ROOT="/var/www/${DOMAIN_NAME}"
mkdir -p "$WEB_ROOT"
chown -R ${RESTRICTED_USERNAME}:www-data "$WEB_ROOT"
chmod -R 755 "$WEB_ROOT"
