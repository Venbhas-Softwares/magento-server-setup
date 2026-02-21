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
