# Module 10 — UFW firewall, SSH hardening, root SSH key setup
# Uses: PMA_PORT, SSH_PUBLIC_KEY

print_step "Configuring UFW firewall..."
apt install -y ufw
ufw --force enable
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow ${PMA_PORT}/tcp

print_step "Hardening SSH configuration..."
sed -i 's/#PermitRootLogin yes/PermitRootLogin prohibit-password/'  /etc/ssh/sshd_config
sed -i 's/PermitRootLogin yes/PermitRootLogin prohibit-password/'   /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/'   /etc/ssh/sshd_config
sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/'    /etc/ssh/sshd_config
sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/'      /etc/ssh/sshd_config

# Ubuntu 24.04 uses 'ssh' as the service name; fall back to 'sshd' for other distros
systemctl restart ssh 2>/dev/null || systemctl restart sshd

print_step "Setting up SSH key authentication for root user..."
mkdir -p /root/.ssh

if ! validate_ssh_public_key "$SSH_PUBLIC_KEY" >/dev/null 2>&1; then
    print_error "SSH public key validation failed during root setup"
    exit 1
fi

echo "$SSH_PUBLIC_KEY" > /root/.ssh/authorized_keys

if [[ ! -s /root/.ssh/authorized_keys ]]; then
    print_error "Failed to write SSH key to root authorized_keys"
    exit 1
fi

chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys

print_message "SSH key successfully configured for root user"

# ── SSH key for restricted user (Git deploy key) ──────────────────────────────

print_step "Generating SSH deploy key for restricted user '${RESTRICTED_USER}'..."

_ru_home="$(getent passwd "${RESTRICTED_USER}" | cut -d: -f6)"
_ru_ssh_dir="${_ru_home}/.ssh"
_ru_key="${_ru_ssh_dir}/id_ed25519"

if [[ ! -d "${_ru_ssh_dir}" ]]; then
    mkdir -p "${_ru_ssh_dir}"
    chmod 700 "${_ru_ssh_dir}"
    chown "${RESTRICTED_USER}:${RESTRICTED_USER}" "${_ru_ssh_dir}"
fi

if [[ ! -f "${_ru_key}" ]]; then
    ssh-keygen -t ed25519 -C "magento@${DOMAIN_NAME}" -f "${_ru_key}" -N ""
    chown "${RESTRICTED_USER}:${RESTRICTED_USER}" "${_ru_key}" "${_ru_key}.pub"
    chmod 600 "${_ru_key}"
    chmod 644 "${_ru_key}.pub"
    print_message "SSH key pair generated at ${_ru_key}"
else
    print_message "SSH key already exists at ${_ru_key} — reusing it."
fi

# Pre-accept host keys for common Git hosting services so the clone later
# does not hang on an interactive host-key confirmation prompt.
print_step "Pre-accepting SSH host keys for GitHub / GitLab / Bitbucket..."
_ru_known_hosts="${_ru_ssh_dir}/known_hosts"
touch "${_ru_known_hosts}"
ssh-keyscan -H github.com gitlab.com bitbucket.org >> "${_ru_known_hosts}" 2>/dev/null || true
chown "${RESTRICTED_USER}:${RESTRICTED_USER}" "${_ru_known_hosts}"
chmod 644 "${_ru_known_hosts}"

# Export for use in server-setup/11-finalize.sh (info file)
RESTRICTED_USER_SSH_PUBKEY="$(cat "${_ru_key}.pub")"

echo ""
print_warning "════════════════════════════════════════════════════════════════════"
print_warning " ACTION REQUIRED — Add the SSH deploy key to your Git repository"
print_warning "════════════════════════════════════════════════════════════════════"
echo ""
echo "Add the following public key as a read-only Deploy Key in your repository:"
echo ""
echo "${RESTRICTED_USER_SSH_PUBKEY}"
echo ""
print_warning "GitHub:    Settings → Deploy keys → Add deploy key"
print_warning "GitLab:    Settings → Repository → Deploy keys"
print_warning "Bitbucket: Repository settings → Access keys"
echo ""
print_warning "Press ENTER once the key has been added to continue..."
read -r _ < /dev/tty
