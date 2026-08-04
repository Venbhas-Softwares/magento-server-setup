# Module varnish — Varnish Cache installation and configuration
# Uses: VARNISH_ENABLED, VARNISH_VERSION, VARNISH_CACHE_MB (set by lib/functions.sh::calculate_resource_allocations)
#
# No default.vcl is written by this repo. The application (Magento, etc.)
# generates its own VCL at deploy time, which is the only VCL that correctly
# handles PURGE/tag-based invalidation, backend health probing, and hashing
# on X-Forwarded-Proto for that specific application. Shipping a competing,
# hand-rolled VCL here was scope creep and the source of two prior critical
# bugs: it cached Set-Cookie responses (session leakage between customers)
# and never hashed on scheme (HTTP/HTTPS cache-object collisions).
#
# Ubuntu's stock /etc/varnish/default.vcl already points at 127.0.0.1:8080 —
# this exact topology — and ships no custom logic, so the builtin VCL applies:
# conservative by design, passing (not caching) any request/response carrying
# cookies. Since Magento and most PHP apps send session cookies on nearly
# everything, Varnish acts as a near-transparent proxy until the real
# application VCL is installed post-deploy. The builtin VCL also appends
# X-Forwarded-For automatically for anything it does pass through.

if [[ "${VARNISH_ENABLED:-yes}" != "yes" ]]; then
    print_message "VARNISH_ENABLED=no — skipping Varnish. The application vhost (module: vhost) will bind port 80 directly instead."
    return 0
fi

# Varnish's own maintainers publish an official apt repo per major/minor
# series on packagecloud.io — the same "curl the vendor's setup script" model
# already used for MariaDB in the database module. Ubuntu's own default repo
# also ships an unversioned "varnish" package, so once the packagecloud repo
# is added there are two sources for the same package name; pin the
# packagecloud one so the exact requested series always wins, regardless of
# which one happens to have the higher raw version number.
case "$VARNISH_VERSION" in
    6.0) VARNISH_PC_SERIES="varnish60lts" ;;
    7.0) VARNISH_PC_SERIES="varnish70" ;;
    7.4) VARNISH_PC_SERIES="varnish74" ;;
    7.5) VARNISH_PC_SERIES="varnish75" ;;
    *)
        print_error "Unsupported VARNISH_VERSION '${VARNISH_VERSION}'"
        exit 1
        ;;
esac

print_step "Adding official Varnish ${VARNISH_VERSION} repository..."
apt install -y curl gnupg
if ! curl -s "https://packagecloud.io/install/repositories/varnishcache/${VARNISH_PC_SERIES}/script.deb.sh" | bash; then
    print_error "Failed to add the Varnish ${VARNISH_VERSION} apt repository"
    print_error "Not every series has published packages for every Ubuntu release at all times —"
    print_error "check https://packagecloud.io/varnishcache/${VARNISH_PC_SERIES} if this persists."
    exit 1
fi

cat > /etc/apt/preferences.d/varnish-pin <<EOF
Package: varnish varnish-*
Pin: release o=packagecloud.io/varnishcache/${VARNISH_PC_SERIES}
Pin-Priority: 1000
EOF

print_step "Installing Varnish ${VARNISH_VERSION}..."
apt update
apt install -y varnish

# ── FastCGI params — pass X-Forwarded-For to PHP-FPM ──────────────────────────
# Nginx does not forward arbitrary headers to FastCGI unless explicitly mapped.
# Add HTTP_X_FORWARDED_FOR so the application (IP allowlists, request logging,
# etc.) sees the real visitor IP that Varnish's builtin vcl_recv appends,
# regardless of whether SSL termination (module: ssl-termination) is enabled.

if ! grep -q "HTTP_X_FORWARDED_FOR" /etc/nginx/fastcgi_params; then
    echo 'fastcgi_param  HTTP_X_FORWARDED_FOR  $http_x_forwarded_for;' \
        >> /etc/nginx/fastcgi_params
    print_message "Added HTTP_X_FORWARDED_FOR to /etc/nginx/fastcgi_params"
fi

# ── Listen address + cache size — the only things package defaults can't know ─
# A systemd drop-in overriding only ExecStart, rather than a full unit
# replacement, keeps the package's own ExecReload (the correct
# varnishreload helper — the previous hand-rolled unit pointed at a path
# that doesn't exist in Ubuntu's package), sandboxing directives, and any
# future unit updates the package brings.

print_step "Configuring Varnish to listen on port 80 with a ${VARNISH_CACHE_MB:-256}MB cache..."
mkdir -p /etc/systemd/system/varnish.service.d
cat > /etc/systemd/system/varnish.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=/usr/sbin/varnishd -j unix,user=vcache -a :80 -T localhost:6082 -f /etc/varnish/default.vcl -S /etc/varnish/secret -s malloc,${VARNISH_CACHE_MB:-256}m
EOF

systemctl daemon-reload
systemctl enable varnish
systemctl restart varnish

# ── Verify the bind actually took ──────────────────────────────────────────────
# Type=simple (set by the package unit) makes systemctl report success even if
# varnishd exits immediately after failing to bind — without this check, a
# failed bind (something else on :80, a bad drop-in) goes unnoticed until the
# operator finds the site unreachable.

print_step "Verifying Varnish bound to port 80..."
VARNISH_BOUND=0
for _ in $(seq 1 10); do
    if ss -tlnp 2>/dev/null | grep -q ':80.*varnishd' || curl -sI --max-time 2 http://127.0.0.1:80 >/dev/null 2>&1; then
        VARNISH_BOUND=1
        break
    fi
    sleep 1
done

if [[ $VARNISH_BOUND -ne 1 ]]; then
    print_error "Varnish did not bind to port 80 after restart — check: systemctl status varnish"
    print_error "Common causes: something else already listening on :80, or a bad ExecStart override in"
    print_error "/etc/systemd/system/varnish.service.d/override.conf"
    exit 1
fi

print_message "Varnish ${VARNISH_VERSION} configured on port 80 with Nginx backend on port 8080 (no custom VCL — package default in effect)"
print_warning "Full Page Cache is inactive until the application's own VCL is installed post-deploy (see server_setup_info.txt)."
