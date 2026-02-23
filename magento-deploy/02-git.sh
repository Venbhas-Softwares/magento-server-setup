# Module 03 — Clone the Git repository into the Magento directory.
# SSH URLs use the deploy key set up during setup-ubuntu24.sh.
# HTTPS URLs will prompt for username/password interactively via the terminal.
# Uses: GIT_REPO_URL, MAGENTO_DIR

print_step "Preparing Magento directory: ${MAGENTO_DIR}"
mkdir -p "${MAGENTO_DIR}"

print_step "Cloning repository: ${GIT_REPO_URL}"
git clone "${GIT_REPO_URL}" "${MAGENTO_DIR}"

print_message "Repository cloned successfully into ${MAGENTO_DIR}."
