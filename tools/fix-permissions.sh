#!/usr/bin/env bash
#
# fix-permissions.sh — Resync ownership and directory setgid bit on a web root
# after ownership/permission drift (e.g. RESTRICTED_USER:webgroup -> RESTRICTED_USER:RESTRICTED_USER).
#
# What it does:
#   1. chown -R <user>:<group> on the whole web root
#   2. chmod 2775 on every directory (rwxrwsr-x — setgid so new files/dirs
#      created underneath inherit <group> instead of the creator's own
#      primary group)
#   3. chmod 0664 on every file (rw-rw-r--)
#   4. Restores the execute bit on known-legitimate executable locations
#      (*.sh scripts, bin/, vendor/bin/) that step 3 would otherwise strip
#
# Does NOT touch umask or ACLs — those are handled separately/manually.
#
# Usage:
#   sudo ./fix-permissions.sh <web_root> [user] [group]
#
# Example:
#   sudo ./fix-permissions.sh /var/www/html/cigarhumidors-online.com webuser www-data

set -euo pipefail

WEB_ROOT="${1:?Usage: $0 <web_root> [user] [group]}"
OWNER_USER="${2:-webuser}"
OWNER_GROUP="${3:-www-data}"

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (use sudo)." >&2
    exit 1
fi

if [[ ! -d "$WEB_ROOT" ]]; then
    echo "Web root '$WEB_ROOT' does not exist or is not a directory." >&2
    exit 1
fi

if ! id -u "$OWNER_USER" &>/dev/null; then
    echo "User '$OWNER_USER' does not exist on this system." >&2
    exit 1
fi

if ! getent group "$OWNER_GROUP" &>/dev/null; then
    echo "Group '$OWNER_GROUP' does not exist on this system." >&2
    exit 1
fi

echo "Web root:    $WEB_ROOT"
echo "Owner user:  $OWNER_USER"
echo "Owner group: $OWNER_GROUP"
read -r -p "Proceed with ownership/permission fix? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

echo "Setting ownership to ${OWNER_USER}:${OWNER_GROUP} ..."
chown -R "${OWNER_USER}:${OWNER_GROUP}" "$WEB_ROOT"

echo "Setting directories to 2775 (rwxrwsr-x, setgid) ..."
find "$WEB_ROOT" -type d -exec chmod 2775 {} \;

echo "Setting files to 0664 (rw-rw-r--) ..."
find "$WEB_ROOT" -type f -exec chmod 0664 {} \;

echo "Restoring execute bit on known executable locations (*.sh, bin/, vendor/bin/) ..."
find "$WEB_ROOT" -type f \( -name "*.sh" -o -path "*/bin/*" -o -path "*/vendor/bin/*" \) -exec chmod ug+x {} \;

echo "Done."
