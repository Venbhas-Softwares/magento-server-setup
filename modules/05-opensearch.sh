# Module 05 — OpenSearch download, installation, and configuration
# Uses: OPENSEARCH_VERSION, TOTAL_RAM_GB, ARCH (set by main script)
# Sets: OPENSEARCH_HEAP

# ── OpenSearch heap allocation ────────────────────────────────────────────────
# 50% of RAM, capped at 8GB; capped at 1GB on servers with ≤6GB to leave
# headroom for PHP-FPM and the OS.

OPENSEARCH_HEAP=$((TOTAL_RAM_GB * 512))
[ $OPENSEARCH_HEAP -gt 8192 ] && OPENSEARCH_HEAP=8192
if [ $TOTAL_RAM_GB -le 6 ] && [ $OPENSEARCH_HEAP -gt 1024 ]; then
    OPENSEARCH_HEAP=1024
fi
[ $OPENSEARCH_HEAP -lt 1024 ] && OPENSEARCH_HEAP=1024

print_message "OpenSearch heap allocation: ${OPENSEARCH_HEAP}MB"

# ── Installation ──────────────────────────────────────────────────────────────

print_step "Installing OpenSearch ${OPENSEARCH_VERSION}..."

if [[ "$ARCH" == "aarch64" ]] || [[ "$ARCH" == "arm64" ]]; then
    OPENSEARCH_ARCH="arm64"
else
    OPENSEARCH_ARCH="x64"
fi

print_message "Downloading OpenSearch ${OPENSEARCH_VERSION}..."
OPENSEARCH_URL="https://artifacts.opensearch.org/releases/bundle/opensearch/${OPENSEARCH_VERSION}"
OPENSEARCH_FILE="opensearch-${OPENSEARCH_VERSION}-linux-${OPENSEARCH_ARCH}.tar.gz"
OPENSEARCH_CHECKSUM_FILE="${OPENSEARCH_FILE}.sha512"
OPENSEARCH_FILE_PATH="/tmp/$OPENSEARCH_FILE"
OPENSEARCH_CHECKSUM_PATH="/tmp/$OPENSEARCH_CHECKSUM_FILE"

add_temp_file "$OPENSEARCH_FILE_PATH"
add_temp_file "$OPENSEARCH_CHECKSUM_PATH"

if ! wget -q "$OPENSEARCH_URL/$OPENSEARCH_FILE" -O "$OPENSEARCH_FILE_PATH"; then
    print_error "Failed to download OpenSearch from $OPENSEARCH_URL/$OPENSEARCH_FILE"
    exit 1
fi

print_message "Verifying OpenSearch integrity..."
if ! wget -q "$OPENSEARCH_URL/$OPENSEARCH_CHECKSUM_FILE" -O "$OPENSEARCH_CHECKSUM_PATH"; then
    print_error "Failed to download OpenSearch checksum file"
    exit 1
fi

EXPECTED_HASH=$(awk '{print $1}' "$OPENSEARCH_CHECKSUM_PATH")
ACTUAL_HASH=$(sha512sum "$OPENSEARCH_FILE_PATH" | awk '{print $1}')
if [ -z "$EXPECTED_HASH" ] || [ "$EXPECTED_HASH" != "$ACTUAL_HASH" ]; then
    print_error "OpenSearch checksum verification FAILED — possible corruption or tampering"
    exit 1
fi
print_message "OpenSearch checksum verified successfully"

id -u opensearch &>/dev/null || useradd -m -d /opt/opensearch -s /bin/bash opensearch

mkdir -p /opt/opensearch
if ! tar -xzf "$OPENSEARCH_FILE_PATH" -C /opt/opensearch --strip-components=1; then
    print_error "Failed to extract OpenSearch archive"
    exit 1
fi
chown -R opensearch:opensearch /opt/opensearch

print_step "Configuring OpenSearch..."
cat > /opt/opensearch/config/opensearch.yml <<EOF
cluster.name: magento-cluster
node.name: node-1
path.data: /opt/opensearch/data
path.logs: /opt/opensearch/logs
network.host: 127.0.0.1
http.port: 9200
discovery.type: single-node

# Security
plugins.security.disabled: true

# Performance
bootstrap.memory_lock: false
EOF

cat > /opt/opensearch/config/jvm.options <<EOF
-Xms${OPENSEARCH_HEAP}m
-Xmx${OPENSEARCH_HEAP}m
-XX:+UseG1GC
-XX:MaxGCPauseMillis=200
EOF

cat > /etc/systemd/system/opensearch.service <<EOF
[Unit]
Description=OpenSearch
Documentation=https://opensearch.org/
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=opensearch
Group=opensearch
ExecStart=/opt/opensearch/bin/opensearch
LimitNOFILE=65536
LimitNPROC=4096
LimitAS=infinity
LimitFSIZE=infinity
TimeoutStopSec=0
KillSignal=SIGTERM
KillMode=process
SendSIGKILL=no
SuccessExitStatus=143
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable opensearch
systemctl start  opensearch

print_message "Waiting for OpenSearch to start..."
sleep 30
