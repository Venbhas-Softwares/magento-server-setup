# Module 07 — Varnish Cache installation and configuration

print_step "Installing Varnish Cache..."
apt install -y varnish

print_step "Configuring Varnish..."
cat > /etc/varnish/default.vcl <<'EOF'
vcl 4.0;

import std;

backend default {
    .host = "127.0.0.1";
    .port = "8080";
    .first_byte_timeout = 600s;
    .connect_timeout = 600s;
    .between_bytes_timeout = 600s;
}

acl purge {
    "localhost";
    "127.0.0.1";
}

sub vcl_recv {
    if (req.method == "PURGE") {
        if (!client.ip ~ purge) {
            return (synth(405, "Not allowed"));
        }
        return (purge);
    }

    if (req.url ~ "^/admin"    || req.url ~ "^/index.php/admin") { return (pass); }
    if (req.url ~ "^/checkout")  { return (pass); }
    if (req.url ~ "^/customer")  { return (pass); }
    if (req.url ~ "^/cart")      { return (pass); }
    if (req.url ~ "^/wishlist")  { return (pass); }

    if (req.method != "GET" && req.method != "HEAD") {
        return (pass);
    }

    if (req.http.Cookie) {
        set req.http.Cookie = ";" + req.http.Cookie;
        set req.http.Cookie = regsuball(req.http.Cookie, "; +", ";");
        set req.http.Cookie = regsuball(req.http.Cookie, ";(PHPSESSID|frontend)=", "; \1=");
        set req.http.Cookie = regsuball(req.http.Cookie, ";[^ ][^;]*", "");
        set req.http.Cookie = regsuball(req.http.Cookie, "^[; ]+|[; ]+$", "");
        if (req.http.Cookie == "") {
            unset req.http.Cookie;
        }
    }

    return (hash);
}

sub vcl_backend_response {
    if (bereq.url ~ "\.(jpg|jpeg|png|gif|gz|css|js|ico|svg|webp)$") {
        set beresp.ttl = 24h;
        set beresp.http.cache-control = "public, max-age=86400";
    }
    if (beresp.http.content-type ~ "text/html") {
        set beresp.ttl = 10m;
        set beresp.http.cache-control = "public, max-age=600";
    }
    return (deliver);
}

sub vcl_deliver {
    if (obj.hits > 0) {
        set resp.http.X-Cache = "HIT";
    } else {
        set resp.http.X-Cache = "MISS";
    }
    set resp.http.X-Cache-Hits = obj.hits;
}

sub vcl_purge {
    return (synth(200, "Purged"));
}
EOF

# Move Nginx to port 8080 so Varnish can own port 80
sed -i 's/listen 80;/listen 8080;/'                 /etc/nginx/sites-available/default 2>/dev/null || true
sed -i 's/listen \[\:\:\]\:80;/listen [::]:8080;/'  /etc/nginx/sites-available/default 2>/dev/null || true

cat > /etc/systemd/system/varnish.service <<EOF
[Unit]
Description=Varnish HTTP accelerator
Documentation=https://www.varnish-cache.org/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ProtectSystem=full
ProtectHome=yes
NoNewPrivileges=yes
ExecStart=/usr/sbin/varnishd -j unix,user=vcache -F -a 0.0.0.0:80 -T 127.0.0.1:6082 -f /etc/varnish/default.vcl -S /etc/varnish/secret -s malloc,256m
ExecReload=/usr/share/varnish/varnishreload.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable varnish
systemctl restart varnish

print_message "Varnish configured on port 80 with Nginx backend on port 8080"
