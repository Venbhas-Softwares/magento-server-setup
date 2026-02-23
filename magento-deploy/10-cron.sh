# Module 10 — Install Magento cron jobs
# Uses bin/magento cron:install which writes entries to the restricted user's
# crontab automatically.
# Uses: MAGENTO_DIR, RESTRICTED_USER

print_step "Installing Magento cron jobs for user '${RESTRICTED_USER}'..."

php "${MAGENTO_DIR}/bin/magento" cron:install --force

print_message "Cron jobs installed. Current entries for '${RESTRICTED_USER}':"
crontab -l 2>/dev/null | grep -i magento || print_message "(no magento entries visible — check crontab manually)"
