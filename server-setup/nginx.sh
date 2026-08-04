# Module nginx — Nginx installation, moved off port 80 for Varnish
# Uses: VARNISH_ENABLED
#
# When Varnish is enabled it must own port 80 (module: varnish, module: vhost).
# The switch happens here, immediately after install, while nothing else is
# bound to port 80 yet — this avoids the bind race that existed when the same
# sed ran later, in module varnish, after Nginx was already serving :80.

print_step "Installing Nginx..."
apt install -y nginx

if [[ "${VARNISH_ENABLED:-yes}" != "yes" ]]; then
    print_message "VARNISH_ENABLED=no — leaving Nginx on port 80."
    return 0
fi

print_step "Moving Nginx's default site to port 8080 so Varnish can own port 80..."
DEFAULT_SITE="/etc/nginx/sites-available/default"

if [[ -f "$DEFAULT_SITE" ]]; then
    # Ubuntu's stock default site uses "listen 80 default_server;" — the
    # optional "default_server" token must be preserved, not dropped, or the
    # site silently stops being nginx's default vhost.
    sed -i -E 's/listen 80(;| default_server;)/listen 8080\1/'            "$DEFAULT_SITE"
    sed -i -E 's/listen \[::\]:80(;| default_server;)/listen [::]:8080\1/' "$DEFAULT_SITE"

    if ! grep -q "listen 8080" "$DEFAULT_SITE"; then
        print_error "Failed to move Nginx off port 80 — 'listen 80' substitution did not take effect in ${DEFAULT_SITE}"
        print_error "Check the file's actual 'listen' directive wording and adjust the sed pattern in this module."
        exit 1
    fi

    nginx -t
    systemctl reload nginx
    print_message "Nginx default site moved to port 8080; port 80 is now free for Varnish."
else
    print_message "No default site at ${DEFAULT_SITE} — nothing to move (fresh Nginx install with no default vhost)."
fi
