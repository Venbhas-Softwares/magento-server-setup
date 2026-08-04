# Production-Readiness Analysis

**Date:** 2026-07-08 · **Scope:** full review of `setup-ubuntu24.sh`, `lib/functions.sh`, all 13 modules in `server-setup/`, `server-setup.conf.example`, and docs. Analysis only — no code has been changed yet.

**Verdict:** Not production-ready yet. Good skeleton (checksum-verified downloads, allowlisted config parsing, shredded temp credentials, privilege separation), but several findings below will break or compromise a real deployment.

**Agreed direction so far:** Finding C1/C2 will be fixed by removing the hand-rolled VCL entirely — see [Proposed solution: Varnish](#proposed-solution-varnish-c1-c2-m9-partly-c3) at the end. All other findings are open, no decisions made.

---

## Critical — will break or compromise a production store

### C1. Varnish VCL can cache `Set-Cookie` responses → session leakage between customers
`server-setup/07-varnish.sh:66-76` — `vcl_backend_response` forces `beresp.ttl = 10m` on all `text/html` and ends with explicit `return (deliver)`, bypassing Varnish's builtin logic that prevents caching responses carrying `Set-Cookie`. Any HTML page not on the pass list (`/admin`, `/checkout`, `/customer`, `/cart`, `/wishlist`) that sets a session cookie is cached for 10 minutes and the cookie replayed to every visitor — one customer can receive another's session. Also stamps `cache-control: public` on pages Magento marked private (form keys, personalized blocks). **Most dangerous issue in the repo.**
→ Resolved by the [Varnish proposal](#proposed-solution-varnish-c1-c2-m9-partly-c3).

### C2. Cache hash ignores `X-Forwarded-Proto` → HTTP/HTTPS share cache objects
With SSL termination on, Nginx :443 proxies to Varnish with `X-Forwarded-Proto: https`, but the VCL has no `vcl_hash` and never includes the scheme in the hash key. A response generated for HTTP (e.g. Magento's redirect-to-HTTPS) can be cached and served to HTTPS visitors — classic redirect-loop / mixed-scheme cache poisoning. Magento's official VCL hashes on this header.
→ Resolved by the [Varnish proposal](#proposed-solution-varnish-c1-c2-m9-partly-c3).

### C3. Port-80 collision between Nginx and Varnish during setup
`server-setup/07-varnish.sh:105-106` — `sed 's/listen 80;/listen 8080;/'` never matches Ubuntu 24.04's actual default (`listen 80 default_server;`), and Nginx is never reloaded in module 07 anyway. `systemctl restart varnish` then starts `varnishd -a 0.0.0.0:80` while Nginx still owns :80. `Type=simple` makes systemctl return success; varnishd dies on bind failure and systemd retry-loops (RestartSec=5) until module 12 removes the default site and reloads Nginx. Setup "succeeds" through a race; with a `--modules=` subset that skips 12, Varnish never comes up.
→ **Agreed fix (2026-07-08):** move the port switch out of module 07 entirely and into module 02, immediately after `apt install -y nginx` — at that point nothing else is bound to :80 yet, so there's no race to manage:
1. In `02-nginx.sh`, right after install: fix the sed to actually match Ubuntu's default site (`listen 80 default_server;` / `listen [::]:80 default_server;`) with a regex tolerant of the optional `default_server` token, e.g. `s/listen 80( default_server)?;/listen 8080\1;/`. Verify the substitution took effect (`grep -q "listen 8080"`, hard error if not — this is exactly the "silent sed no-op" failure mode M6 also flags), then `nginx -t && systemctl reload nginx` right there.
2. Delete the now-redundant/broken sed lines from `07-varnish.sh:105-106` — by the time module 07 runs, Nginx has been off :80 since module 02, so Varnish's `-a 0.0.0.0:80` bind has nothing to race against.
3. Still add a post-start bind check in module 07 (e.g. `ss -tlnp | grep -q ':80.*varnishd'` or `curl -sI localhost:80`) as defense in depth — `Type=simple` + `RestartSec=5` will keep masking *other* bind failures (something unrelated already on :80, a bad drop-in) even with this race eliminated.
4. Module 12's existing sequence (create domain vhost on 8080 → symlink → `rm -f sites-enabled/default` → `nginx -t` → reload) is unaffected and still correct — verified no live-conflict window there either way, since the `rm` always happens before `nginx -t`.

This resolves the collision/race itself; the residual "verify Varnish actually bound" check (step 3) is kept as a small independent hardening item, not a full fix on its own.

### C4. Memory-overcommit guard never runs, and its formula omits MariaDB
`lib/functions.sh:227` — `validate_resource_allocations` (the function CLAUDE.md and comments describe as blocking installation on insufficient memory) is **defined but never called anywhere** (verified by grep). Even its formula only sums PHP-FPM + OpenSearch + Valkey, omitting MariaDB's `innodb_buffer_pool_size` = **50% of total RAM** (`04-mariadb.sh:41`). Real stack on an 8 GB box: 4 GB InnoDB pool + 4 GB OpenSearch heap + 20 FPM children × 2 GB limit + Valkey + OS → severe overcommit, OOM kills under load. The 16 GB tier (`PHP_MAX_CHILDREN=100` at 4 GB/request limit) is especially optimistic.
→ **Agreed fix (2026-07-08):** three parts — compute allocations up front, fix the formula, rebalance the tiers so a default install passes its own validator.
1. **Move all sizing calculations up front, then actually call the validator.** Calling the validator "after modules 03/05/06" is useless — by then everything is already installed and configured, so aborting is pointless. Instead, extract the sizing logic from modules 03/05/06 into a single `calculate_resource_allocations` function in `lib/functions.sh` that sets *all* allocation variables (PHP tier, FPM children/spares, OpenSearch heap, Valkey memory, plus new `MARIADB_BUFFER_POOL_MB` and `VARNISH_CACHE_MB`) from `TOTAL_RAM_GB`/`CPU_CORES`. In `setup-ubuntu24.sh`, right after resource detection: `validate_system_resources` → `calculate_resource_allocations` → `validate_resource_allocations` — blocking **before** any module installs anything. Modules 03/05/06 drop their calculation blocks and just consume the variables; module 04 uses `MARIADB_BUFFER_POOL_MB` instead of inline `TOTAL_RAM_GB * 512`; module 07 uses `VARNISH_CACHE_MB` (ties into the M9/Varnish drop-in). Side benefits: the allocation summary appears on the pre-install summary screen where the operator can still abort, and `--modules=` subset runs get correct values since the main script always runs first.
2. **Fix the formula.** Add the two missing consumers: `TOTAL_ALLOCATED = PHP_FPM_estimate + OPENSEARCH_HEAP + VALKEY_MEMORY + MARIADB_BUFFER_POOL_MB + VARNISH_CACHE_MB`. Keep the 15%-of-limit average-RSS heuristic for PHP-FPM (realistic for Magento), but count MariaDB and OpenSearch as **fully resident** — InnoDB pre-allocates its pool and the JVM gets `-Xms = -Xmx`, so no discounting. Raise the fixed OS reserve from 512MB to RAM-scaled (e.g. `max(512MB, 5% of RAM)`) to cover MariaDB non-pool overhead, OpenSearch off-heap, and page cache.
3. **Rebalance the tiers — fixed services first, PHP gets the remainder.** With MariaDB in the formula, the current tiers fail validation at every RAM size (~50% DB + ~50% search + PHP on top), so they must change or the validator would always abort. InnoDB pool drops from a flat 50% to 25–30% (50% is the dedicated-DB-server rule; this is a shared single-box stack); OpenSearch keeps its existing small-box caps; `PHP_MAX_CHILDREN` is **derived from remaining memory** (`remaining / (limit × 15%)`, floor ~5, existing CPU-based spare logic) instead of the hardcoded 20/100/150. Illustrative defaults: 4GB box → 1GB InnoDB / 1GB OS heap / 256MB Valkey / ~5 children at 2G limit; 8GB → 2GB / 2GB / 768MB / ~12 × 2G; 16GB → 5GB / 4GB / 1.6GB / ~25 × 4G; 32GB+ → 30% InnoDB / 8GB OS cap / 2GB Valkey cap / remainder → ~50 × 6G. The mechanism (derive children from remainder) is the actual fix; exact numbers are tunable. This also removes the "especially optimistic" 16GB tier and the 50%-RAM InnoDB value as a side effect.
   Scope notes: the validator's 80%-warn / 100%-abort thresholds stay as-is (fine once inputs are honest); CLAUDE.md's "Dynamic Sizing" section and the module header `Sets:` comments need syncing per the doc-sync rule.

### C5. SSH password auth likely still enabled on cloud images despite claims
`server-setup/10-security.sh:15-19` edits only `/etc/ssh/sshd_config`. Ubuntu 24.04 cloud images ship `/etc/ssh/sshd_config.d/50-cloud-init.conf` with `PasswordAuthentication yes`, and the `Include` directive is processed first, so drop-ins win. The final summary then prints "Password authentication is COMPLETELY DISABLED" — a false security claim.
→ **Agreed fix (2026-07-08):** replace the direct `sed` edits to `/etc/ssh/sshd_config` with an authoritative drop-in that sorts *before* `50-cloud-init.conf`:
1. Write `/etc/ssh/sshd_config.d/40-magento-hardening.conf` containing `PermitRootLogin prohibit-password`, `PasswordAuthentication no`, `PubkeyAuthentication yes`. Lexical glob order (`40-` < `50-`) puts it ahead of cloud-init's drop-in in the `Include` expansion, and first-obtained-value-wins means ours stays authoritative regardless of what cloud-init sets afterward.
2. Drop the now-redundant `sed` edits on the main `sshd_config` — one source of truth is easier to reason about and re-run idempotently (those sed lines are also fragile: they only match specific `#Foo yes`/`Foo yes` spellings and silently no-op otherwise, the same failure class as M6).
3. Before restarting `ssh`/`sshd`, run `sshd -T | grep -i passwordauthentication` (and `permitrootlogin`) and hard-fail the module if the effective value doesn't match what we just wrote — this catches any distro/image variant where another drop-in sorts ahead of `40-`, or `Include` ordering differs, instead of silently proceeding to print a false claim.
4. Fix `13-finalize.sh`'s summary claim ("Password authentication is COMPLETELY DISABLED") to be based on that same verified `sshd -T` check rather than assumed.

### C6. Lockout risks in module 10
- `server-setup/10-security.sh:6-7` — `ufw --force enable` runs **before** `ufw allow 22/tcp`. If the script dies in that window (`set -e` script), or for new SSH connections in that moment, the operator is firewalled out.
  → **Agreed fix (2026-07-08):** reorder so every `ufw allow ...` rule is queued first and `ufw --force enable` runs last. No dependency issues — nothing before this point relies on UFW already being enabled.
- `server-setup/10-security.sh:32` and `01-system.sh:20` — `authorized_keys` is overwritten with `>`, destroying the cloud-init-provisioned key. If the configured key isn't the one the operator actually uses — combined with password auth disabled (see [[C5]]) — permanent lockout.
  → **Agreed fix (2026-07-08): hard-stop-on-conflict**, applied at both write sites (root in `10-security.sh`; restricted user in `01-system.sh`, relevant only when the account pre-exists — a fresh `useradd -m` has no `.ssh` from `/etc/skel` so there's nothing to conflict with):
    1. Before writing, read the existing `authorized_keys` (if any) and classify: **missing/empty** → write normally; **exists and already contains exactly the configured key** → idempotent no-op, don't rewrite (this is the expected re-run case, see M3); **exists with anything else** (a different key, multiple keys, a cloud-init-provisioned key) → conflict.
    2. On conflict, do **not** touch the file. `print_error` and `exit 1` with a message that: (a) states which file and which user account is affected, (b) shows the key(s) currently in the file so the operator can recognize whether it's their cloud provider's key or something else, (c) shows the `ROOT_USER_SSH_PUBLIC_KEY`/`RESTRICTED_USER_SSH_PUBLIC_KEY` value from the config that caused the conflict, and (d) gives the two concrete ways to resolve it: either update the config variable to match the key already on the server and re-run, or deliberately back up/clear `authorized_keys` on the server first if the intent is to replace it — then re-run.
    3. This follows the same detect-then-`print_error`-then-`exit 1` pattern already used by every other validator in the codebase (`validate_server_config`, `validate_ssl_config`, `validate_ssh_public_key`) rather than introducing a live prompt, which would be the only interactive branch in an otherwise non-interactive validate-then-proceed script (and this project's history already removed its one prior interactive prompt — the deploy confirmation).

---

## High — security loopholes

### H1. phpMyAdmin served over plain HTTP on an internet-exposed port
Module 09 + `10-security.sh:12` (UFW opens `PMA_PORT` to the world). No TLS on that vhost → Basic Auth credentials **and MariaDB root credentials** cross the internet in cleartext on every login. Random port + path is obscurity, not protection; the non-standard port also means Cloudflare never fronts it.
→ Options: TLS on the PMA vhost, UFW IP allowlist for the port, or drop the public exposure entirely and document SSH-tunnel access.

### H2. Nginx alias-traversal pattern in phpMyAdmin vhost
`server-setup/09-phpmyadmin.sh:90-91` — `location /${PMA_PATH}` + `alias ${PMA_INSTALL_DIR}`, neither with trailing slash. `/${PMA_PATH}../foo` maps to `/usr/share/phpmyadmin${PMA_PATH}../foo` → arbitrary reads under `/usr/share` (gated by Basic Auth, so impact limited to authenticated users, but textbook misconfiguration).
→ Trailing slashes on both `location /${PMA_PATH}/` and `alias ${PMA_INSTALL_DIR}/`.

### H3. `chmod 777` on phpMyAdmin tmp dir; dead config-storage import
`server-setup/09-phpmyadmin.sh:49,74` — world-writable dir in a PHP web root; it's already `www-data`-owned, `750/770` suffices. Also `create_tables.sql` is imported (`:52`) but `config.inc.php` never sets `pmadb`/`controluser`, so configuration storage is dead weight and phpMyAdmin will nag.

### H4. Direct-to-origin HTTP wide open even with SSL termination
UFW allows :80 globally, no HTTP→HTTPS redirect, no Cloudflare IP allowlisting, no `real_ip`/`CF-Connecting-IP` restoration. Anyone discovering the origin IP bypasses Cloudflare and gets the site over cleartext HTTP.
→ For a Cloudflare-fronted design, restrict :80/:443 to Cloudflare's published ranges (script-refreshable) and/or add a redirect vhost.

### H5. OpenSearch: security plugin disabled, start never verified
`server-setup/05-opensearch.sh:77` — `plugins.security.disabled: true` gives any local process (`www-data`, restricted user, compromised PHP worker) unauthenticated read/write to all indexes. Localhost binding softens it; document the trade-off or enable basic auth. Module ends with blind `sleep 30` and no `curl localhost:9200` health check — a failed start goes unnoticed. Also: `vm.max_map_count` sysctl not set (below documented requirement; only non-fatal because of loopback binding), and the `opensearch` user gets `/bin/bash` instead of `nologin`.

### H6. Secrets hygiene — file permissions never tightened
`server-setup.conf` (MariaDB root + PMA passwords), `server_setup_info.txt`, and `setup-server-*.log` (PMA path, deploy key) are all created with default umask (typically 644). `.gitignore` covers git only.
→ `chmod 600` all three (config at load time, the others at creation).

---

## Medium — functional/robustness bugs

### M1. `client_max_body_size` never set anywhere (verified by grep)
PHP allows 64 MB uploads but Nginx defaults to 1 MB — on both the :443 terminator and the :8080 backend. Product-image and import uploads >1 MB will 413. Must be set at every Nginx hop in the chain.

### M2. Config parser rejects or mangles legitimate passwords
`lib/functions.sh::load_config_safely`:
- Injection filter (`:57-63`) rejects **values** containing `;`, `|`, `&&`, or substrings `eval`/`exec`/`source`/`./` — so `MARIADB_ROOT_PASSWORD="p;9|x"` fails and `SSL_CERT_PATH=/root/certs/opensource.pem` is rejected ("source"). Pushes operators toward weaker passwords.
- `line=$(echo "$line" | xargs)` (`:54`) errors on values containing quotes/backslashes and collapses inner whitespace.
- `line="${line%%#*}"` (`:53`) truncates passwords containing `#`.
- Meanwhile `04-mariadb.sh:27` interpolates the password unescaped into `ALTER USER ... IDENTIFIED BY '...'` — a single quote in the password breaks the SQL.
→ Validate the *name* strictly and treat the *value* opaquely (no xargs, no substring blocklist on values); escape or use a defaults-file/parameterized mechanism for SQL.

### M3. Re-runs are not idempotent
- `13-finalize.sh:10` appends `PMA_PATH`/`MAGENTO_DIR` to the config on every run → duplicates accumulate.
- Re-running module 09 generates a new random path and a second full phpMyAdmin install under `/usr/share/`, orphaning the old one (old `config.inc.php` + blowfish secret left on disk).
- Running a subset that excludes 09 makes finalize write `PMA_PATH=""` into the config.

### M4. Config values interpolated without format validation
`DOMAIN_NAME` and `RESTRICTED_USERNAME` only checked non-empty. `RESTRICTED_USERNAME="foo bar"` word-splits in the unquoted `useradd` (`01-system.sh:14`); malformed `DOMAIN_NAME` breaks nginx configs and paths. Add regex validation (valid hostname / POSIX username) and quote expansions.

### M5. VERIFY: `innodb_buffer_pool_instances = 6` vs MariaDB version
`server-setup/04-mariadb.sh:42` — deprecated in MariaDB 10.5, removed in 10.6 (re-added later in 11.x). Depending on `MARIADB_VERSION`, an unknown variable in `99-magento.cnf` prevents mysqld startup and `set -e` aborts the whole run at `systemctl restart mariadb`. Test against every version the validator accepts (10.6–11.x).

### M6. VERIFY: `apt install -y valkey` on stock Ubuntu 24.04
Valkey entered the Ubuntu archive after noble's release; module 06 adds no repo/PPA. If the package isn't in noble (or only via backports), module 06 fails on a clean box. Related pattern: the `sed` edits in modules 06, 07, and 10 silently no-op when the distro's default file wording differs — none verify the substitution took effect.

### M7. VERIFY: `ExecReload=/usr/share/varnish/varnishreload.sh`
`server-setup/07-varnish.sh:122` — Ubuntu's varnish package ships the helper as `/usr/sbin/varnishreload`. If the `.sh` path doesn't exist, `systemctl reload varnish` fails at deploy time — exactly when the Magento VCL is being swapped in.
→ Made moot by the [Varnish proposal](#proposed-solution-varnish-c1-c2-m9-partly-c3) (drop-in keeps the package's ExecReload).

### M8. `apt upgrade -y` can hang interactively
Ubuntu 24.04 ships `needrestart` in interactive mode; package config prompts (openssh, grub) can block. Use `DEBIAN_FRONTEND=noninteractive`, `NEEDRESTART_MODE=a`, `-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold`.

### M9. Varnish cache size hardcoded `malloc,256m`
`server-setup/07-varnish.sh:121` — contrary to the repo's dynamic-sizing philosophy, small for a production catalog, and not included in the (never-called) memory validator.

---

## Low / observations

- **PHP tuning** (`03-php.sh`): `max_execution_time = 1800` on the web SAPI invites slow-request pileups; `pm.max_requests` unset (no worker recycling → memory creep); `expose_php` not disabled; `opcache.validate_timestamps=0` requires FPM reload on every deploy — document it; OPcache JIT (`tracing`, 256M) has a history of segfault-class bugs with Magento — most production guides leave it off.
- **Validator drift**: `validate_server_config` accepts PHP 8.5 while all docs/badges/example say 8.1–8.4; `COMPOSER_VERSION` accepts any non-empty value (`"3"` silently installs v2); `OPENSEARCH_VERSION` never format-validated (check 3.5.0 default against target Magento version).
- **`validate_ssh_public_key`**: error messages always name `ROOT_USER_SSH_PUBLIC_KEY` even when validating the restricted user's key; accepts deprecated `ssh-dss`.
- **VCL details** (moot if proposal adopted): `connect_timeout = 600s` nonsensical; no backend probe/grace; pass list assumes default `/admin` path.
- **`clear` calls** (`setup-ubuntu24.sh:83`, `13-finalize.sh:174`) wipe validation warnings and the "ACTION REQUIRED: add deploy key" banner off screen; write control chars into the tee'd log.
- **Hardening gaps** (scope decisions, but standard production checklist items): no `ufw limit 22/tcp`, no fail2ban, no unattended-upgrades, no swap provisioning, no logrotate for `/opt/opensearch/logs`.
- **Doc drift**: CLAUDE.md's "Nginx security headers" claim only holds for the phpMyAdmin vhost — main :8080 vhost and :443 terminator have none (no HSTS; terminator also lacks `http2`).
- **`resolve_module`** (`lib/functions.sh:276,295-296`) returns any absolute/relative path to be sourced as root — not an escalation (operator is root), but no containment to the modules dir.

---

## Proposed solution: Varnish (C1, C2, M9 partly, C3)

**Decision (agreed 2026-07-08):** remove the hand-rolled Magento-specific VCL from module 07 entirely. Magento generates its own VCL at deploy time (admin → Full Page Cache → export, or `bin/magento varnish:vcl:gen`) which correctly handles PURGE/`X-Magento-Tags-Pattern`, health probe, `X-Forwarded-Proto` hashing, cookies, and grace. Shipping a competing VCL was scope creep by the repo's own "server provisioning only" rule and is the source of C1/C2.

**Why the package default VCL is safe in the interim:** Ubuntu's stock `/etc/varnish/default.vcl` already points at `127.0.0.1:8080` (this exact topology). With no custom logic, the builtin VCL applies — conservative by design: any request/response with cookies is passed, not cached. Magento sends session cookies on essentially everything, so Varnish acts as a near-transparent proxy until the real Magento VCL is installed. Correct trade: no FPC between provisioning and deployment, zero risk of session leakage or scheme poisoning. Builtin also appends `X-Forwarded-For` automatically — **keep** module 07's fastcgi_params `HTTP_X_FORWARDED_FOR` mapping, it's still needed.

**What can't come from package defaults:**
1. **Listen address** — stock unit runs `varnishd -a :6081`, not `:80`. Change it via a systemd **drop-in** (`/etc/systemd/system/varnish.service.d/override.conf` overriding only `ExecStart`), not a full unit replacement. Keeps the package's `ExecReload` (fixes M7), sandboxing, and future unit updates.
2. **Cache size** — package default is also `malloc,256m`; fine as a floor, but scale with RAM in the drop-in if keeping the dynamic-sizing philosophy (and include it in the C4 validator formula).
3. **Port-80 handover (C3) is independent** — still must fix the non-matching `sed`, reload Nginx *before* starting Varnish, and verify the bind.

**Resulting module 07:** install varnish → fix Nginx :8080 handover (reload) → add fastcgi XFF param → write systemd drop-in (`-a :80`, cache size) → start & verify. No `default.vcl` written by this repo.

**Docs/finalize updates:** `13-finalize.sh` "Next Steps" and README must state explicitly: *after deploying Magento, export its VCL, replace `/etc/varnish/default.vcl`, `systemctl reload varnish`* — and note FPC is intentionally inactive until that step.

---

## Suggested fix order

1. C1/C2 + M7 + part of M9 — implement the Varnish proposal above.
2. C3 — port-80 handover.
3. C5/C6 — SSH drop-in handling, UFW rule ordering, authorized_keys handling (lockout class).
4. C4 — wire up + fix the resource validator (include InnoDB pool, Varnish).
5. H1–H6 — phpMyAdmin exposure/traversal/perms, origin lockdown, OpenSearch verification, file perms.
6. M1–M4, M8 — body size, config parser, idempotency, input validation, noninteractive apt.
7. M5/M6 — version-matrix verification on a clean Ubuntu 24.04 VM (MariaDB variable, valkey package).
8. Low items + doc sync (CLAUDE.md rule 3: keep README/CLAUDE.md in sync with module changes).
