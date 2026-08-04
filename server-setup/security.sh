# Module security — UFW firewall, SSH hardening, root SSH key/password setup
# Uses: PHPMYADMIN_ENABLED, PMA_PORT, ROOT_USER_SSH_PUBLIC_KEY, ENABLE_SSL_TERMINATION,
#       SSH_PASSWORD_AUTH_ENABLED, ROOT_PASSWORD_AUTH_ENABLED, ROOT_USER_PASSWORD

print_step "Configuring UFW firewall..."
apt install -y ufw
# Queue every allow rule BEFORE enabling — enabling first (the previous order)
# left a window where a `set -e` failure, or a new SSH connection arriving in
# that instant, could firewall the operator out before port 22 was allowed.
ufw allow 22/tcp
ufw allow 80/tcp
if [[ "$ENABLE_SSL_TERMINATION" == "yes" ]]; then
    ufw allow 443/tcp
fi
if [[ "${PHPMYADMIN_ENABLED:-yes}" == "yes" ]]; then
    ufw allow ${PMA_PORT}/tcp
fi
ufw --force enable

print_step "Hardening SSH configuration..."
SSH_PASSWORD_AUTH_ENABLED="${SSH_PASSWORD_AUTH_ENABLED:-no}"
ROOT_PASSWORD_AUTH_ENABLED="${ROOT_PASSWORD_AUTH_ENABLED:-no}"

# Some servers only ever accept key-based SSH, others require passwords — and
# resetting root's credential specifically isn't something every run should
# do, so it's gated by its own switch instead of following the restricted
# user's setting. PasswordAuthentication is the server-wide sshd switch
# (needed for the restricted user's password to work at all); PermitRootLogin
# is root-specific and only flips to "yes" if ROOT_PASSWORD_AUTH_ENABLED=yes
# (validate_server_config already enforces that this implies
# SSH_PASSWORD_AUTH_ENABLED=yes too, so the two settings below are never
# contradictory).
if [[ "$SSH_PASSWORD_AUTH_ENABLED" == "yes" ]]; then
    SSHD_PASSWORD_AUTHENTICATION="yes"
else
    SSHD_PASSWORD_AUTHENTICATION="no"
fi
if [[ "$ROOT_PASSWORD_AUTH_ENABLED" == "yes" ]]; then
    SSHD_PERMIT_ROOT_LOGIN="yes"
else
    SSHD_PERMIT_ROOT_LOGIN="prohibit-password"
fi

# An authoritative drop-in, not direct sed edits to sshd_config: Ubuntu 24.04
# cloud images ship /etc/ssh/sshd_config.d/50-cloud-init.conf with
# PasswordAuthentication yes, and Include expansion is first-obtained-value-
# wins, so a drop-in sorting before it (40- < 50-) stays authoritative
# regardless of what cloud-init sets. It's also idempotent to re-run and
# immune to the "sed pattern doesn't match this image's exact wording"
# failure mode the old direct edits had.
cat > /etc/ssh/sshd_config.d/40-hardening.conf <<EOF
PermitRootLogin ${SSHD_PERMIT_ROOT_LOGIN}
PasswordAuthentication ${SSHD_PASSWORD_AUTHENTICATION}
PubkeyAuthentication yes
EOF
chmod 644 /etc/ssh/sshd_config.d/40-hardening.conf

print_step "Verifying SSH hardening took effect before restarting sshd..."
if ! SSHD_EFFECTIVE=$(sshd -T 2>&1); then
    print_error "sshd -T failed to parse the configuration — refusing to restart ssh with an unverified config"
    echo "$SSHD_EFFECTIVE"
    exit 1
fi
EFFECTIVE_PASSWORD_AUTH=$(echo "$SSHD_EFFECTIVE" | awk 'tolower($1)=="passwordauthentication"{print tolower($2)}')
EFFECTIVE_ROOT_LOGIN=$(echo "$SSHD_EFFECTIVE"    | awk 'tolower($1)=="permitrootlogin"{print tolower($2)}')

SSHD_MISMATCH=0
if [[ "$EFFECTIVE_PASSWORD_AUTH" != "$SSHD_PASSWORD_AUTHENTICATION" ]]; then
    print_error "  Effective PasswordAuthentication: ${EFFECTIVE_PASSWORD_AUTH:-<unset>} (expected: ${SSHD_PASSWORD_AUTHENTICATION})"
    SSHD_MISMATCH=1
fi
# sshd -T normalizes "prohibit-password" to its older synonym
# "without-password" in the effective-config dump (both mean the same thing
# to sshd) — accept either so this check doesn't fail on a config that's
# actually correct.
if [[ "$SSHD_PERMIT_ROOT_LOGIN" == "prohibit-password" ]]; then
    if [[ "$EFFECTIVE_ROOT_LOGIN" != "prohibit-password" && "$EFFECTIVE_ROOT_LOGIN" != "without-password" ]]; then
        print_error "  Effective PermitRootLogin:        ${EFFECTIVE_ROOT_LOGIN:-<unset>} (expected: prohibit-password/without-password)"
        SSHD_MISMATCH=1
    fi
elif [[ "$EFFECTIVE_ROOT_LOGIN" != "$SSHD_PERMIT_ROOT_LOGIN" ]]; then
    print_error "  Effective PermitRootLogin:        ${EFFECTIVE_ROOT_LOGIN:-<unset>} (expected: ${SSHD_PERMIT_ROOT_LOGIN})"
    SSHD_MISMATCH=1
fi

if [[ "$SSHD_MISMATCH" -eq 1 ]]; then
    print_error "SSH hardening did NOT take effect — another config file is overriding /etc/ssh/sshd_config.d/40-hardening.conf"
    print_error "Check for a conflicting /etc/ssh/sshd_config.d/*.conf that sorts before 40-hardening.conf,"
    print_error "or an Include order in /etc/ssh/sshd_config that doesn't process sshd_config.d first."
    exit 1
fi
print_message "Verified via sshd -T: PasswordAuthentication=${SSHD_PASSWORD_AUTHENTICATION}, PermitRootLogin=${SSHD_PERMIT_ROOT_LOGIN}."

# Ubuntu 24.04 uses 'ssh' as the service name; fall back to 'sshd' for other distros
systemctl restart ssh 2>/dev/null || systemctl restart sshd

print_step "Setting up root user access..."
mkdir -p /root/.ssh
chmod 700 /root/.ssh

if [[ -n "$ROOT_USER_SSH_PUBLIC_KEY" ]]; then
    if ! validate_ssh_public_key "$ROOT_USER_SSH_PUBLIC_KEY" >/dev/null 2>&1; then
        print_error "SSH public key validation failed during root setup"
        exit 1
    fi

    write_authorized_key_safely "/root/.ssh/authorized_keys" "$ROOT_USER_SSH_PUBLIC_KEY" "root" "ROOT_USER_SSH_PUBLIC_KEY"

    if [[ ! -s /root/.ssh/authorized_keys ]]; then
        print_error "Failed to write SSH key to root authorized_keys"
        exit 1
    fi

    chmod 600 /root/.ssh/authorized_keys
    print_message "SSH key successfully configured for root user"
fi

if [[ "$ROOT_PASSWORD_AUTH_ENABLED" == "yes" ]]; then
    print_step "Setting root account password for SSH password authentication..."
    echo "root:${ROOT_USER_PASSWORD}" | chpasswd
    print_message "Root account password set"
fi

# ── SSH key for restricted user (Git deploy key) ──────────────────────────────

print_step "Generating SSH deploy key for restricted user '${RESTRICTED_USERNAME}'..."

_ru_home="$(getent passwd "${RESTRICTED_USERNAME}" | cut -d: -f6)"
_ru_ssh_dir="${_ru_home}/.ssh"
_ru_key="${_ru_ssh_dir}/id_ed25519"

if [[ ! -d "${_ru_ssh_dir}" ]]; then
    mkdir -p "${_ru_ssh_dir}"
    chmod 700 "${_ru_ssh_dir}"
    chown "${RESTRICTED_USERNAME}:${RESTRICTED_USERNAME}" "${_ru_ssh_dir}"
fi

if [[ ! -f "${_ru_key}" ]]; then
    ssh-keygen -t ed25519 -C "${RESTRICTED_USERNAME}@${DOMAIN_NAME}" -f "${_ru_key}" -N ""
    chown "${RESTRICTED_USERNAME}:${RESTRICTED_USERNAME}" "${_ru_key}" "${_ru_key}.pub"
    chmod 600 "${_ru_key}"
    chmod 644 "${_ru_key}.pub"
    print_message "SSH key pair generated at ${_ru_key}"
else
    print_message "SSH key already exists at ${_ru_key} — reusing it."
fi

# Export for use in server-setup/finalize.sh (info file)
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
print_warning "The key is also saved in server_setup_info.txt — add it to your repo before deploying."
