# PHP Application Server Runbook (Ubuntu 26.04 LTS)

![Platform](https://img.shields.io/badge/platform-Ubuntu%2026.04%20LTS-E95420?logo=ubuntu&logoColor=white)
![PHP](https://img.shields.io/badge/PHP-8.5-777BB4?logo=php&logoColor=white)
![Magento](https://img.shields.io/badge/Magento-2.4.9%20ready-EE672F?logo=magento&logoColor=white)
![License](https://img.shields.io/badge/license-GPL--3.0-blue)

This repository contains one runbook, [`magento-server-setup-runbook.md`](magento-server-setup-runbook.md), which provisions a production PHP application server on Ubuntu 26.04 LTS. It installs Nginx, PHP-FPM, MariaDB, OpenSearch, Valkey, Varnish, Composer, and phpMyAdmin, sets up HTTPS, and hardens the server around them. The server stays general-purpose, but every version and setting meets the system requirements of Magento Open Source and Adobe Commerce 2.4.9, so a Magento store can be deployed onto it without changes.

The runbook does not install or deploy any application. You deploy the application separately, and the runbook's Part 6 then applies the few Magento settings that need Magento's code to be present.

| Component | Version | Source |
|---|---|---|
| PHP | 8.5 | Ubuntu 26.04 |
| Nginx | 1.28 | Ubuntu 26.04 |
| MariaDB | 12.3 | MariaDB repository |
| OpenSearch | 3.x | OpenSearch repository |
| Valkey | 9.0 | Ubuntu 26.04 |
| Varnish | 7.7 | Ubuntu 26.04 |
| Composer | 2.10 | getcomposer.org installer |

Everything can run on one server, or the database and OpenSearch can each run on a server of their own. The runbook is grouped by server role, and each server runs only the parts that apply to it. Its own introduction explains the version choices and the order of the parts in detail.

The rest of this file explains how to prepare a computer to run the runbook. The runbook is a Markdown file whose `bash` blocks run on the **server**, not on your computer. Visual Studio Code makes this possible by connecting to the server over SSH (the Remote - SSH extension) and opening the runbook there as an interactive notebook (the Runme extension), so your computer only provides the editor window. The steps below are written for macOS. They are the same on Linux and Windows, apart from the terminal commands for SSH keys.

With separate servers, repeat steps 3 to 6 for each one. Set up the database and OpenSearch servers before the app server, so that the app server's final checks can reach them.

## 1. What you need before you start

Make sure the following are in place before you open VS Code:

- **One or more Ubuntu 26.04 LTS (x86-64) servers** that you can reach over SSH as a user with `sudo` rights. On AWS, this is normally the `ubuntu` user. The runbook's repositories and package names are chosen for 26.04, and it warns you on any other release.
- **Enough disk space on each server.** AWS's default 8 GB root volume is too small, because Ubuntu and the base packages already use most of it, and the OpenSearch package alone needs about 2.6 GB free while it installs. Plan for roughly 30 GB on an OpenSearch server, 30 to 50 GB on a database server, and 40 to 60 GB on an app server, with more for a large catalogue or many product images. A volume can be enlarged later without downtime, but it cannot be shrunk.
- **The private key for each server**, for example the `.pem` file that AWS gave you when the instance was created.
- **Each server's public IP address or DNS name**, and, with separate servers, each server's private IP address, which the servers use to reach each other.
- **Access to this repository on GitHub**, so that you can download the runbook.
- **A domain name**, if the app server will get its own certificate (`SSL_MODE=letsencrypt`). Its DNS record must point to the app server before you reach the HTTPS section.

You also need an SSH key pair that belongs to this computer. The runbook installs its public half on the app server, so that you can log in as the restricted web user. If you do not have one yet, create it in the macOS Terminal:

```bash
ssh-keygen -t ed25519 -C "your-name@your-mac"
cat ~/.ssh/id_ed25519.pub
```

Keep the printed public key handy, because you will paste it into the runbook later.

## 2. Install the VS Code extensions

Two extensions are required:

| Extension | Marketplace ID | Purpose |
|---|---|---|
| Remote - SSH | `ms-vscode-remote.remote-ssh` | Opens a VS Code window that runs on the server over SSH. |
| Runme | `stateful.runme` | Turns the Markdown runbook into a notebook with a run button on each code block. |

To install them from VS Code, open the Extensions view (`Cmd+Shift+X`), search for each name above, and click **Install**. Check that the publisher is Microsoft for Remote - SSH and Stateful for Runme, because several extensions have similar names.

You can also install them from the Terminal. This requires the `code` command, which you can add from VS Code by opening the Command Palette (`Cmd+Shift+P`) and running **Shell Command: Install 'code' command in PATH**.

```bash
code --install-extension ms-vscode-remote.remote-ssh
code --install-extension stateful.runme
```

Runme also has to be installed on the server side of each connection. You will do that in step 5, once the remote window is open.

## 3. Configure SSH access to the servers

First, store each server's private key in `~/.ssh` and restrict its permissions, because SSH refuses to use a key that other users can read:

```bash
mv ~/Downloads/YOUR_KEY.pem ~/.ssh/
chmod 400 ~/.ssh/YOUR_KEY.pem
```

Next, add an entry for each server to `~/.ssh/config`. A named entry lets both VS Code and the Terminal connect with a short alias, and it keeps the connection alive during long installation steps. With a single server, the `app-server` entry is the only one you need.

```text
Host app-server
    HostName APP_SERVER_IP_OR_DNS
    User ubuntu
    IdentityFile ~/.ssh/YOUR_KEY.pem
    ServerAliveInterval 30
    ServerAliveCountMax 6

Host db-server
    HostName DB_SERVER_IP_OR_DNS
    User ubuntu
    IdentityFile ~/.ssh/YOUR_KEY.pem
    ServerAliveInterval 30
    ServerAliveCountMax 6

Host opensearch-server
    HostName OPENSEARCH_SERVER_IP_OR_DNS
    User ubuntu
    IdentityFile ~/.ssh/YOUR_KEY.pem
    ServerAliveInterval 30
    ServerAliveCountMax 6
```

Finally, confirm that a plain SSH login works for each server before you involve VS Code. Type `yes` if SSH asks you to confirm the server's fingerprint, and then type `exit` to close the session.

```bash
ssh app-server
```

If this command fails, VS Code will fail in the same way, so fix the problem here first. The most common causes are a security group that does not allow port 22 from your IP address, the wrong user name, and incorrect key permissions.

## 4. Copy the runbook to each server

The runbook has to be opened from the server's file system so that its blocks run there. The simplest approach is to clone the repository on your computer and copy the single file to each server:

```bash
git clone git@github.com:Venbhas-Softwares/magento-server-setup.git
scp magento-server-setup/magento-server-setup-runbook.md app-server:~/
scp magento-server-setup/magento-server-setup-runbook.md db-server:~/
scp magento-server-setup/magento-server-setup-runbook.md opensearch-server:~/
```

Cloning on your computer means the new servers never need access to GitHub. If you prefer to clone directly on a server, you must first set up a GitHub key there. Whenever the runbook in the repository changes, copy it to the servers again and reopen it in VS Code, so that Runme runs the current version.

## 5. Open the runbook in a remote VS Code window

1. In VS Code, open the Command Palette (`Cmd+Shift+P`) and run **Remote-SSH: Connect to Host...**.
2. Choose the server from the list, for example `db-server`. When VS Code asks for the platform, choose **Linux**. VS Code then installs its server component on the machine, which takes a minute on the first connection.
3. Once the window shows `SSH: db-server` in the bottom-left corner, open the Extensions view. Find Runme under **Local - Installed** and click **Install in SSH: db-server**. Without this step, the runbook opens as plain Markdown with no run buttons.
4. Choose **File > Open Folder...**, select `/home/ubuntu`, and confirm. Trust the folder if VS Code asks.
5. In the Explorer, open `magento-server-setup-runbook.md`. Runme opens Markdown files as notebooks by default. If the file opens as plain text instead, right-click it and choose **Open With... > Runme**.

Each server gets its own VS Code window, so you can keep the database, OpenSearch, and app server windows open side by side.

## 6. Run the runbook

Read the "How to use it" section at the top of the runbook first. The points below describe how Runme behaves on top of those instructions.

**Follow the parts for this server.** The runbook is grouped by server. Part 1 runs on every server, Parts 2, 3, and 4 cover the database, OpenSearch, and app servers, Part 5 runs on every server again, and Part 6 runs on the app server once Magento's code is deployed. Part 7 is only for repairing file permissions on an app server that is already running. Within the parts that apply, click the run button on each `bash` block from top to bottom. Blocks labelled `text` are notes for you, and you should not try to run them. If you run a block that belongs to another kind of server, it stops with a "Skip this block" message before changing anything.

**Update and reboot first.** Part 1 starts with the system update, and its last block reboots the server when the update requires it. Do this before entering any values, because a reboot clears them.

**Answer the variable prompts.** When you run a block that contains `export NAME="value"`, Runme opens an input box for each variable and uses the value in the file as the default. Type the real value for this server (for example, your domain name) and press Enter. The values you type are kept only in Runme's session and are not written back into the file. Of the three Variables blocks, run **Server role** on every server, **App server settings** only on the app server, and **Database and OpenSearch server settings** only on a server that runs MariaDB or OpenSearch for app servers elsewhere. Then run **Resource sizing**.

**Fix values that are rejected.** Each Variables block checks its values. If one is missing or invalid, for example `example.com` left as the domain or an app server IP address left empty on the database server, the block lists the problems and fails. Run it again and enter corrected values.

**Know what a failed block means for variables.** Runme keeps the variables that a block sets only when the block succeeds. If a block fails, every value it set is discarded, so later blocks may report a missing variable. Fix the cause and run the failed block again.

**Re-run the setup blocks after any restart.** Variables last only as long as the current Runme session. If you reload the window, reconnect after a reboot, or restart VS Code, run this server's **Variables** blocks and the **Resource sizing** block again before continuing. Any block that needs a missing variable stops with a clear error rather than running with an empty value.

**Paste your public key.** In the "Restricted user and web root" section on the app server, replace the placeholder `PUBKEY` value with the public key you printed in step 1 before you run that block.

**Handle the interactive block.** `sudo mariadb-secure-installation` on the database server asks a series of questions. Runme shows them in the block's output area, and you answer them by typing there. If the output area does not accept input, open a terminal in the remote window (`` Ctrl+` ``) and run the command there instead.

**Leave a pager with `q`.** If a block's output ends with a line such as `lines 1-9` and the block keeps running, a command has opened its output in the `less` pager. Click into the output area and press `q`, and the block finishes.

**Expect a reboot to disconnect you.** After `sudo reboot`, VS Code loses the connection. Wait about a minute, click **Reload Window** (or reconnect to the server), reopen the runbook, and continue. If you reboot after entering values, run the **Variables** and **Resource sizing** blocks again first.

**Protect the generated passwords.** Several blocks print a password exactly once. Copy each one into your password manager immediately, and then clear the output with the block's **Clear Output** action. Do not save the notebook with its outputs, and never commit a copy of the runbook that contains them.

**Run the SSH hardening carefully.** The SSH hardening section disables password and root logins. Before you restart `ssh`, open a second Terminal on your computer and confirm that `ssh app-server` (or the alias of the server you are working on) still works. Your `ubuntu` user keeps working because it logs in with a key, so the remote VS Code window is not affected.

## 7. After the runbook is finished

The phpMyAdmin tunnel command in the runbook runs on **your computer**, not on the server. Run it in the macOS Terminal, keep that window open, and browse to `http://localhost:8090`. With the SSH config entry from step 3, the command shortens to:

```bash
ssh -N -L 8090:127.0.0.1:8090 app-server
```

To log in to the app server as the restricted web user, use the key you created in step 1. Replace `webuser` with the value of `WEB_USER` if you changed it.

```bash
ssh -i ~/.ssh/id_ed25519 webuser@APP_SERVER_IP_OR_DNS
```

The servers are now ready for Magento 2.4.9, which you deploy separately. Deploy the code as the restricted user, following the rules in the runbook's **File permissions** section, so that the restricted user and PHP-FPM can both keep writing to the web root. Once Magento's code is in place, return to the app server and run Part 6 of the runbook, which applies Magento's own Nginx configuration, Varnish VCL, and cron jobs.

If file permissions in a web root ever drift, for example after a deployment run as root, run Part 7 of the runbook on that server. It also works on older servers with the same layout, because it does not depend on the earlier parts.

When you no longer need it, you can delete the runbook copy from each server with `rm ~/magento-server-setup-runbook.md`. The copy in this repository remains the source of truth.

## Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| The runbook opens as plain Markdown with no run buttons. | Runme is not installed on the SSH host. Install it with **Install in SSH: &lt;server&gt;** (step 5), then reopen the file with **Open With... > Runme**. |
| A block fails with `Run the Variables blocks first` or `Run the Resource sizing block first`. | The Runme session was reset, or the block that sets the value failed. Run this server's **Variables** blocks and the **Resource sizing** block again. |
| A block stops with `Skip this block`. | The block belongs to another kind of server. Skip it, or check the **Server role** values if this server should run that service. |
| A block keeps running and its output ends with `lines 1-9` or similar. | The output is open in the `less` pager. Click into the output area and press `q`. |
| `apt` or `dpkg` fails with `No space left on device`. | The root volume is too small. Run `sudo apt clean`, enlarge the volume in the AWS console, grow the filesystem with `sudo growpart /dev/nvme0n1 1` and `sudo resize2fs /dev/nvme0n1p1` (check the names with `lsblk`), run `sudo apt -f install`, and then rerun the failed block. |
| VS Code cannot connect to the host. | Run `ssh <alias>` in the Terminal to see the real error, and check the security group, user name, and key permissions. |
| The connection drops during a long install. | Make sure `ServerAliveInterval` is set in `~/.ssh/config`, reconnect, rerun the setup blocks, and then rerun the interrupted block. |
| `apt` reports that it cannot get a lock. | Ubuntu's automatic updates are still running on a newly launched server. Wait a few minutes and run the block again. |
| The application cannot write a file, or a deployment cannot replace one. | The web root's permissions have drifted. Run Part 7 of the runbook on that server. |

## License

This project is licensed under the GNU General Public License v3.0. See [LICENSE](LICENSE) for details.
