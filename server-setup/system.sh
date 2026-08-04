# Module system — System update, essential packages, restricted user, and application web root
# Sets web root ownership to restricted_user:www-data (authoritative — not repeated elsewhere).
# Uses: RESTRICTED_USERNAME, DOMAIN_NAME, SSH_PASSWORD_AUTH_ENABLED, RESTRICTED_USER_PASSWORD
# Sets: WEB_ROOT (used by modules vhost and finalize)

print_step "Updating system packages..."
apt update && apt upgrade -y

print_step "Installing essential packages..."
apt install -y software-properties-common apt-transport-https ca-certificates \
    curl wget git unzip vim nano htop gnupg2 lsb-release

print_step "Creating restricted user: ${RESTRICTED_USERNAME}..."
id -u "${RESTRICTED_USERNAME}" &>/dev/null || useradd -m -d /home/${RESTRICTED_USERNAME} -s /bin/bash ${RESTRICTED_USERNAME}
usermod -a -G www-data ${RESTRICTED_USERNAME}

print_step "Setting up SSH access for restricted user '${RESTRICTED_USERNAME}'..."
_ru_home="/home/${RESTRICTED_USERNAME}"
mkdir -p "${_ru_home}/.ssh"
chmod 700 "${_ru_home}/.ssh"
chown "${RESTRICTED_USERNAME}:${RESTRICTED_USERNAME}" "${_ru_home}/.ssh"

if [[ -n "$RESTRICTED_USER_SSH_PUBLIC_KEY" ]]; then
    # A fresh `useradd -m` has no .ssh from /etc/skel, so there's normally nothing
    # to conflict with — but if this account pre-existed (re-run, or provisioned
    # by cloud-init), write_authorized_key_safely refuses to clobber a key that
    # doesn't match what's configured instead of silently overwriting it.
    write_authorized_key_safely "${_ru_home}/.ssh/authorized_keys" "$RESTRICTED_USER_SSH_PUBLIC_KEY" \
        "restricted user '${RESTRICTED_USERNAME}'" "RESTRICTED_USER_SSH_PUBLIC_KEY"
    chmod 600 "${_ru_home}/.ssh/authorized_keys"
    chown "${RESTRICTED_USERNAME}:${RESTRICTED_USERNAME}" "${_ru_home}/.ssh/authorized_keys"
fi

if [[ "${SSH_PASSWORD_AUTH_ENABLED:-no}" == "yes" ]]; then
    # useradd -m leaves the account password-locked ('!') by default, which
    # blocks password SSH login even when sshd allows it — an explicit
    # password must be set for SSH_PASSWORD_AUTH_ENABLED=yes to actually work.
    echo "${RESTRICTED_USERNAME}:${RESTRICTED_USER_PASSWORD}" | chpasswd
    print_message "Password set for restricted user '${RESTRICTED_USERNAME}' (SSH password authentication)"
fi

print_message "Restricted user configured with no sudo (also reachable via: su - ${RESTRICTED_USERNAME})"

print_step "Creating application web root..."
WEB_ROOT="/var/www/${DOMAIN_NAME}"
mkdir -p "$WEB_ROOT"
chown -R ${RESTRICTED_USERNAME}:www-data "$WEB_ROOT"
chmod -R 755 "$WEB_ROOT"
