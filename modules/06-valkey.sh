# Module 06 — Valkey installation and configuration
# Uses: TOTAL_RAM_GB (set by main script)
# Sets: VALKEY_MEMORY

# ── Valkey memory allocation ──────────────────────────────────────────────────
# 10% of RAM, capped at 2GB, minimum 256MB.

VALKEY_MEMORY=$((TOTAL_RAM_GB * 1024 / 10))
[ $VALKEY_MEMORY -gt 2048 ] && VALKEY_MEMORY=2048
[ $VALKEY_MEMORY -lt 256  ] && VALKEY_MEMORY=256

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
