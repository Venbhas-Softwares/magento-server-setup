# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

The repository's deliverable is a single Runme runbook, `magento-server-setup-runbook.md`, which provisions a production PHP application server on Ubuntu 26.04 LTS. `README.md` explains how to prepare a computer (VS Code, Remote - SSH, Runme, SSH config) to run the runbook against a server. There are no scripts, and the runbook must stay self-contained: it must never reference or depend on separate script files.

The server is general-purpose, but every version and setting is chosen to meet the Magento Open Source and Adobe Commerce 2.4.9 system requirements, so a Magento store can be deployed onto it without changes. Application deployment (installing Magento, Composer installs, database imports) is out of scope. Part 6 holds the only Magento-specific steps, and they run after the code has been deployed.

## Runbook structure

The runbook is grouped by server role, and each server runs only the parts that apply to it:

| Part | Runs on | Contents |
|---|---|---|
| 1 | Every server, first | System update, Variables blocks (Server role, App server settings, Database and OpenSearch server settings), Resource sizing |
| 2 | Database server (`INSTALL_MARIADB=yes`) | MariaDB 12.3 from the MariaDB repository, tuning, application database and user |
| 3 | OpenSearch server (`INSTALL_OPENSEARCH=yes`) | OpenSearch 3.x, ICU and phonetic plugins, memory map limit, systemd drop-in settings |
| 4 | App server (`INSTALL_APP=yes`) | Restricted user, web root and file permission model, PHP 8.5, Nginx 1.28, Valkey 9 (two instances, memory overcommit), Varnish 7.7, Composer 2.10, phpMyAdmin, HTTPS |
| 5 | Every server, to finish | UFW, SSH hardening, Fail2ban, unattended upgrades, final verification |
| 6 | App server, after Magento is deployed | Connection options for `setup:install`, Magento's Nginx configuration, Magento's VCL, cron |
| 7 | Any app server with drifted permissions | Self-contained reset of web root ownership and modes, plus the settings that stop the drift returning |

Everything can run on one server, or the database and OpenSearch can run on their own servers. Remote access is limited to the addresses in `APP_SERVER_IPS` (database and OpenSearch servers), and the app server connects through `DB_SERVER_IP` and `OPENSEARCH_SERVER_IP`.

## Conventions for runbook blocks

- **Variables live in the Runme session.** Each `export NAME="value"` line becomes a Runme prompt whose default is the literal value, so defaults must be plain strings. Variables blocks validate their values and `exit 1` on any error, which makes Runme discard every value the block set.
- **Every block guards itself.** A block for one role starts with a check such as `[ "${INSTALL_APP:?Run the Variables blocks first}" = yes ] || { echo "Skip this block: ..."; exit 1; }`, and a block that needs a computed value starts with `: "${NAME:?Run the ... block first}"`. Keep this pattern on every new block, so that running a block on the wrong server, or in a fresh session, stops before it changes anything.
- **Part 7 is the exception.** It must run on its own in a new session on an older server, so it defines its own `WEB_ROOT` and `WEB_USER` and never relies on Part 1's variables.
- **Package files are never edited.** Settings go into drop-in files (`conf.d/99-*.ini`, `pool.d/zz-tuning.conf`, `mariadb.conf.d/99-tuning.cnf`, `jvm.options.d/`, `sites-available/` and `conf.d/` for Nginx, systemd `*.service.d/` drop-ins, `/etc/sudoers.d/`), so package upgrades never prompt about modified configuration files and the settings survive them. For OpenSearch and Varnish, the systemd drop-in is rebuilt from the package's own `ExecStart` line, with options appended or substituted.
- **Blocks are idempotent.** Running a block twice must be safe. Blocks that generate a password set a new one on each run and print it once.
- **Verify in the block itself.** Blocks end by printing the effective state (`php-fpm -tt`, `sshd -T`, `nginx -t`, `SHOW VARIABLES`, `/proc/<pid>/status`) rather than assuming the change worked. Files in `/etc/sudoers.d/` are checked with `visudo -cf` before they are installed.
- **Heredocs:** use `<<'EOF'` when nothing should expand, and escape `\$` for Nginx and PHP variables inside an unquoted `<<EOF`.

## Resource sizing

The **Resource sizing** block in Part 1 is the only place where memory is calculated. It counts how many of the main services (application, MariaDB, OpenSearch) share the server. A dedicated MariaDB server gets 70% of RAM for the buffer pool, and a dedicated OpenSearch server gets 50% for its heap (capped at 30 GB). On a shared server, the buffer pool gets 25% (up to 8 GB of RAM) or 30%, and the heap gets 25% (capped at 8 GB, or 1 GB at 6 GB of RAM or less). Valkey gets 10% (512 MB to 2 GB, a quarter for sessions), Varnish 5% (256 MB to 2 GB), and the OS reserve 5% (at least 512 MB). PHP-FPM gets what is left after 768 MB for OPcache and JIT, at 120 MB per worker and at least 5 workers.

## File permission model

The web root (`/var/www/<domain>`) is owned by the restricted user or `www-data`, with group `www-data`. Folders are `2775`, ordinary files `664`, and files named `*.sh` or inside a `bin/` folder `775`. The umask is `002` for every writer: the restricted user's `~/.profile` and `~/.bashrc`, a sudoers `Defaults>user umask=0002, umask_override` rule for `sudo -u`, and `UMask=0002` in a PHP-FPM systemd drop-in. The same settings appear in Part 4 (new servers) and Part 7 (repair of existing servers), so a change to one must be made to the other. The count checks in Part 5's final verification and Part 7's check block also use the same `find` expressions.

## Version choices

Verify every version against Adobe's Magento 2.4.9 system requirements and the live package repositories before changing it. Nginx deliberately comes from Ubuntu's repository (1.28) rather than nginx.org, even though Magento 2.4.9 lists 1.30. Varnish is Ubuntu's 7.7 because the packagecloud `varnish80` repository had no `resolute` build when the runbook was written, and the runbook includes the check and the upgrade path to Varnish 8. Do not ship a hand-written VCL: Varnish uses the package default until Part 6 installs the VCL that Magento exports.

## Writing style

The runbook and README are finished prose for operators. Explain why each block exists in complete sentences before the block, keep the existing tone, and never use em dashes or Markdown blockquotes.

## Testing changes

Run `bash -n` over every `bash` block after editing. Behavioural changes should be tested on a fresh Ubuntu 26.04 instance, and on each server role they affect, before they are committed.
