# Module valkey — Valkey installation and configuration
# Uses: VALKEY_ENABLED, VALKEY_MEMORY (set by lib/functions.sh::calculate_resource_allocations)

if [[ "${VALKEY_ENABLED:-yes}" != "yes" ]]; then
    print_message "VALKEY_ENABLED=no — skipping Valkey installation"
    return 0
fi

print_message "Valkey memory allocation: ${VALKEY_MEMORY}MB"

# ── Installation ──────────────────────────────────────────────────────────────

print_step "Installing Valkey..."
apt install -y valkey

print_step "Configuring Valkey..."
sed -i "s/supervised no/supervised systemd/"                        /etc/valkey/valkey.conf
sed -i "s/# maxmemory <bytes>/maxmemory ${VALKEY_MEMORY}mb/"       /etc/valkey/valkey.conf
sed -i "s/# maxmemory-policy noeviction/maxmemory-policy allkeys-lru/" /etc/valkey/valkey.conf

# The valkey package installs valkey-server.service; valkey.service is an alias —
# systemctl enable refuses to operate on aliases so use the real unit name.
systemctl restart valkey-server
systemctl enable  valkey-server
