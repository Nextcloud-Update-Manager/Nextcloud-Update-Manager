# Nextcloud Update Manager – Documentation

## Table of Contents

1. [Overview](#1-overview)
2. [System Requirements](#2-system-requirements)
3. [Installation](#3-installation)
4. [Configuration](#4-configuration)
5. [Script 1: nextcloud-update-manual.sh](#5-script-1-nextcloud-update-manualsh)
6. [Script 2: nextcloud-update-cron.sh](#6-script-2-nextcloud-update-cronsh)
7. [Installer (install.sh)](#7-installer-installsh)
8. [Log Files](#8-log-files)
9. [Backup Strategy](#9-backup-strategy)
10. [Troubleshooting](#10-troubleshooting)
11. [Technical Reference](#11-technical-reference)

---

## 1. Overview

> **Important: ISPConfig-specific tool**
>
> The Nextcloud Update Manager is designed **exclusively for servers managed by
> [ISPConfig](https://www.ispconfig.org/)**. The scripts depend on ISPConfig's specific
> directory layout (`/var/www/clients/client{N}/web{N}/web/`), the web-user naming convention
> (`web{N}`), and the per-user PHP CLI configuration that ISPConfig sets up automatically.
> On other hosting environments (plain LAMP/LEMP stack, Plesk, cPanel, etc.) the scripts
> will **not** work without modification.

The **Nextcloud Update Manager** automates the maintenance of Nextcloud installations on ISPConfig servers. It consists of two Bash scripts with different purposes:

| Script | Use case | Behaviour on major upgrade |
|--------|----------|---------------------------|
| `nextcloud-update-manual.sh` | Manual execution by an administrator | Interactive confirmation prompt |
| `nextcloud-update-cron.sh` | Automated root cron job | Email notification |

**Functions shared by both scripts:**

- Scans `/var/www/clients/` for all Nextcloud installations
- Applies minor updates (within the same major version) automatically
- Checks app compatibility with the next major version via the Nextcloud App Store API
- Logs all actions to dedicated per-installation log files

---

## 2. System Requirements

### Operating System

| Distribution | Versions | Status |
|---|---|---|
| Debian | 11 (Bullseye), 12 (Bookworm), **13 (Trixie)** | Fully supported |
| Ubuntu | 20.04 LTS, 22.04 LTS, 24.04 LTS | Fully supported |
| RHEL / CentOS / AlmaLinux | 8+ | Limited support (dnf/yum) |

**Debian 13 "Trixie" (stable since August 2025):** All dependencies are available in the official repositories. `bash 5.2`, `curl 8.14`, `default-mysql-client` (including `mysqldump`), and `apt-get` work without any modifications. The scripts run identically on Debian 13 as on Debian 11/12.

### Server Layout

The scripts require the **ISPConfig standard layout**:

```
/var/www/clients/
└── client{N}/
    └── web{N}/
        └── web/                ← Nextcloud root (contains: occ, config/, version.php)
            ├── occ
            ├── config/
            │   └── config.php
            ├── version.php
            └── updater/
                └── updater.phar
```

### Required Packages

| Package | Purpose | Installed automatically |
|---------|---------|------------------------|
| `curl` | Update server queries, email delivery | Yes |
| `jq` | JSON processing (occ output, App Store API) | Yes |
| `rsync` | File backup before major upgrades | Yes |
| `default-mysql-client` (Debian) / `mariadb` (RHEL) | Database backup (`mysqldump`) | Yes |

### Permissions

- Must run as **root**
- `sudo` must be configured to allow `root → web{N}` without a password:
  ```
  # /etc/sudoers.d/nextcloud-update (ISPConfig typically sets this up)
  root ALL=(www-data,web1,web2,...) NOPASSWD: /usr/bin/php
  ```
  In practice this is already in place on standard ISPConfig installations.

### PHP

Each ISPConfig web user has its own PHP CLI version. When running `sudo -u web1 php occ ...`, the PHP CLI version configured for `web1` in ISPConfig is used automatically — no further configuration is required.

---

## 3. Installation

### 3.1 Automated Installation (recommended)

```bash
git clone https://github.com/your-user/nextcloud-update.git
cd nextcloud-update
chmod +x install.sh
sudo ./install.sh
```

The installer performs the following steps:

1. Root check
2. Verify source files
3. Detect package manager (apt-get / dnf / yum)
4. Install missing packages
5. Copy scripts to `/usr/local/sbin/` and set permissions
6. Create log and backup directories
7. Interactively prompt for SMTP settings and save to `/etc/nextcloud-update/smtp.conf`
8. Optionally configure a cron job

### 3.2 Manual Installation

```bash
# Install packages
apt-get install -y curl jq rsync default-mysql-client

# Deploy scripts
cp scripts/nextcloud-update-manual.sh /usr/local/sbin/
cp scripts/nextcloud-update-cron.sh   /usr/local/sbin/
chmod 700 /usr/local/sbin/nextcloud-update-*.sh
chown root:root /usr/local/sbin/nextcloud-update-*.sh

# Create directories
mkdir -p /var/log/Nextcloud-Update
chmod 750 /var/log/Nextcloud-Update

mkdir -p /var/backups/nextcloud
chmod 750 /var/backups/nextcloud

# Set up SMTP configuration
mkdir -p /etc/nextcloud-update
cp scripts/smtp.conf.example /etc/nextcloud-update/smtp.conf
nano /etc/nextcloud-update/smtp.conf   # fill in your values
chmod 600 /etc/nextcloud-update/smtp.conf
chown root:root /etc/nextcloud-update/smtp.conf

# Cron job (every Sunday at 03:00)
cat > /etc/cron.d/nextcloud-update << 'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 3 * * 0 root /usr/local/sbin/nextcloud-update-cron.sh
EOF
chmod 644 /etc/cron.d/nextcloud-update
```

### 3.3 Upgrading an Existing Installation

The installer detects existing scripts and creates backups automatically:

```
/usr/local/sbin/nextcloud-update-manual.sh.bak.20260603
/usr/local/sbin/nextcloud-update-cron.sh.bak.20260603
```

Simply run `sudo ./install.sh` again.

---

## 4. Configuration

### 4.1 SMTP Configuration File

**Path:** `/etc/nextcloud-update/smtp.conf`
**Permissions:** `chmod 600`, `chown root:root`

```ini
# SMTP server (SMTPS with implicit TLS, port 465)
SMTP_HOST=mail.example.com
SMTP_PORT=465

# SMTP credentials
SMTP_USER=nextcloud-notify@example.com
SMTP_PASS=YourPassword

# Sender address (must match the SMTP account)
SMTP_FROM=nextcloud-notify@example.com

# Recipient for major upgrade notifications
MAIL_TO=admin@example.com
```

**Note:** The cron script loads this file on startup. Changes take effect on the next run.

### 4.2 Customising the Installation Search

Both scripts expose configuration variables at the top that can be adjusted:

```bash
NC_SEARCH_BASE="/var/www/clients"    # Root directory for the search
NC_SEARCH_MAXDEPTH=4                 # Maximum search depth
LOG_DIR="/var/log/Nextcloud-Update"  # Log directory
BACKUP_BASE="/var/backups/nextcloud" # Backup directory
```

---

## 5. Script 1: nextcloud-update-manual.sh

### 5.1 Usage

```bash
# Normal run
/usr/local/sbin/nextcloud-update-manual.sh

# Dry run: shows what would happen without making any changes
/usr/local/sbin/nextcloud-update-manual.sh --dry-run
```

### 5.2 Flow

```
Start
 ├─ Root check
 ├─ Check dependencies (curl, jq, rsync, mysqldump)
 ├─ Create log directory (/var/log/Nextcloud-Update/)
 ├─ Acquire lock file (/var/run/nextcloud-update-manual.lock)
 │
 └─ For each Nextcloud installation found:
     ├─ Determine web user (stat)
     ├─ Open log file (/var/log/Nextcloud-Update/{web-user}.log)
     ├─ Retrieve current version (occ status --output=json)
     ├─ Determine web user's PHP version
     ├─ Query update server
     │
     ├─ Same major version?
     │   └─ Yes → Apply minor update automatically
     │           ├─ Maintenance mode: ON
     │           ├─ updater.phar --no-interaction
     │           ├─ occ upgrade
     │           ├─ occ app:update --all
     │           ├─ occ maintenance:repair
     │           └─ Maintenance mode: OFF
     │
     └─ New major version?
         ├─ Check app compatibility (App Store API)
         ├─ Display results (compatible / incompatible / unknown)
         ├─ Ask admin: proceed with upgrade? [y/Y/j/J]
         │
         ├─ No → Skip, write log entry
         │
         └─ Yes → Create backup
                 ├─ rsync (without data/)
                 ├─ mysqldump
                 └─ Upgrade procedure (same as minor update)
```

### 5.3 Interactive Output (Example)

**Minor update:**

```
────────────────────────────────────────────────────────────────────────
  Installation: /var/www/clients/client1/web1/web
────────────────────────────────────────────────────────────────────────
[2026-06-03 03:12:01] [INFO] Installed version: 28.0.12.3
[2026-06-03 03:12:01] [INFO] PHP version: 8.2.18
[2026-06-03 03:12:02] [INFO] Available version: 28.0.14
[2026-06-03 03:12:02] [INFO] Minor update: 28.0.12.3 → 28.0.14

  Applying minor update automatically:
  v28.0.12.3 → v28.0.14

[2026-06-03 03:14:38] [INFO] Minor update complete. New version: 28.0.14
  ✓ Update successful. Installed version: 28.0.14
```

**Major upgrade:**

```
────────────────────────────────────────────────────────────────────────
  ⚠  Nextcloud Major Upgrade Available
────────────────────────────────────────────────────────────────────────

  Installation:      /var/www/clients/client1/web1/web
  Web user:          web1
  Installed:         v28.0.14
  Available:         v29.0.3

  App compatibility with Nextcloud v29:

  Compatible:
    ✓  calendar
    ✓  contacts
    ✓  mail

  Incompatible with v29 (will be disabled!):
    ✗  custom_app

  Not found in App Store (status unknown):
    ?  local_custom_app

  ⚠  WARNING: 1 app(s) are not available in v29!
  These apps will be disabled automatically during the upgrade.
  Please check whether alternatives are available.

────────────────────────────────────────────────────────────────────────
  Proceed with upgrade to v29.0.3?
  [y/Y/j/J = Yes  |  any other input = No / skip]: y

  Backup created: /var/backups/nextcloud/web1_v28.0.14_20260603_031512

  Running upgrade – please wait...

  ✓ Major upgrade successful!
  Installed version: 29.0.3
  Note: Incompatible apps have been disabled: custom_app
```

### 5.4 Dry-Run Mode

The `--dry-run` flag runs all checks but makes no changes:

- No update or upgrade is applied
- No backup is created
- No maintenance mode changes
- Shows exactly what a real run would do

```bash
nextcloud-update-manual.sh --dry-run
```

---

## 6. Script 2: nextcloud-update-cron.sh

### 6.1 Setting Up the Cron Job

**Via the installer** (recommended) or manually:

```bash
# /etc/cron.d/nextcloud-update
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Weekly, Sunday at 03:00
0 3 * * 0 root /usr/local/sbin/nextcloud-update-cron.sh
```

**Suggested schedules:**

- Weekly: `0 3 * * 0` (Sunday 03:00)
- Daily: `0 3 * * *` (every day 03:00)
- Mon + Thu: `30 2 * * 1,4` (Mon and Thu 02:30)

### 6.2 Behaviour

The cron script behaves identically to Script 1, with these differences:

| Aspect | Manual script | Cron script |
|--------|--------------|-------------|
| Output | Coloured terminal output | Log file only |
| Minor update | Automatic | Automatic |
| Major upgrade | Interactive prompt | Email notification, no automatic upgrade |
| SMTP | Not required | Required for major upgrade notifications |

### 6.3 Email Notification (Major Upgrade)

When a major upgrade is available, the script sends an email to the address configured in `smtp.conf`:

```
Subject: [Nextcloud] Major upgrade available: v28→v29 | server.example.com | web1

Nextcloud Major Upgrade Available
──────────────────────────────────────────────────

Server:               server.example.com
Installation:         /var/www/clients/client1/web1/web
Web user:             web1
Installed:            v28.0.14
Available:            v29.0.3

App compatibility with Nextcloud v29:
────────────────────────────────────────

COMPATIBLE (3):
  ✓  calendar
  ✓  contacts
  ✓  mail

INCOMPATIBLE – will be disabled during upgrade! (1):
  ✗  custom_app

────────────────────────────────────────
Next steps:
  Run the upgrade manually:
  > /usr/local/sbin/nextcloud-update-manual.sh

Log file: /var/log/Nextcloud-Update/web1.log
```

### 6.4 Email Delivery – Technical Details

Emails are sent via `curl` over **SMTPS (port 465, implicit TLS)**:

```bash
curl --url "smtps://${SMTP_HOST}:${SMTP_PORT}" \
     --ssl-reqd \
     --mail-from "$SMTP_FROM" \
     --mail-rcpt "$MAIL_TO" \
     --user "${SMTP_USER}:${SMTP_PASS}" \
     --upload-file <(mail_content)
```

All providers offering SMTPS on port 465 are supported. STARTTLS (port 587) is not used by default; to switch, change `--url "smtp://..."` (drop `--ssl-reqd`) and set `SMTP_PORT=587`.

---

## 7. Installer (install.sh)

### 7.1 Usage

```bash
sudo ./install.sh          # First install OR update (detected automatically)
sudo ./install.sh --full   # Full reinstall including SMTP + cron job
```

### 7.2 Automatic Mode Detection

The installer detects whether this is a first-time installation or an update:

| Mode | Trigger | Scripts | SMTP config | Cron job |
|------|---------|---------|-------------|----------|
| **Install** | First run (no existing installation) | Installed | Interactive setup | Interactive setup |
| **Update** | Re-run (scripts + smtp.conf already present) | Updated | Unchanged | Unchanged |
| **Full** | `--full` flag | Updated | Interactive setup | Interactive setup |

**Typical update workflow after a new repository version:**

```bash
cd Nextcloud-Update-Manager
git pull
sudo ./install.sh
```

The installer detects the existing installation and only updates the scripts. SMTP credentials and cron schedule are left untouched.

### 7.3 Flow

```
1. Prerequisites:      Root check, verify source files, detect package manager
2. Dependencies:       Check curl, jq, rsync, mysqldump — install if missing
3. Scripts:            Copy to /usr/local/sbin/, chmod 700, back up existing version as .bak
4. SMTP configuration: Update mode: unchanged | Full install: interactive input
5. Cron job:           Update mode: unchanged | Full install: configurable
```

### 7.4 SMTP Prompts (first install or --full only)

The installer asks for the following values:

| Variable | Description | Validation |
|----------|-------------|------------|
| `SMTP_HOST` | SMTP server hostname | Required |
| `SMTP_PORT` | SMTP port (default: 465) | Number 1–65535 |
| `SMTP_USER` | SMTP username | Required |
| `SMTP_PASS` | SMTP password (hidden input) | Required |
| `SMTP_FROM` | Sender address | Email syntax |
| `MAIL_TO` | Recipient address (default: admin@example.com) | Email syntax |

Existing values from `smtp.conf` are shown as suggestions (password excepted).

After input, a **connection test** is offered that sends a test email to verify the settings.

---

## 8. Log Files

### 8.1 Structure

```
/var/log/Nextcloud-Update/
├── web1.log          # Installation: /var/www/clients/client1/web1/web
├── web2.log          # Installation: /var/www/clients/client1/web2/web
├── web3.log          # Installation: /var/www/clients/client2/web3/web
└── cron.log          # Global cron script log (start/end, errors)
```

### 8.2 Log Format

```
[YYYY-MM-DD HH:MM:SS] [LEVEL] Message
```

**Log levels:**

| Level | Meaning |
|-------|---------|
| `INFO` | Normal operation |
| `WARN` | Non-critical problem (script continues) |
| `ERROR` | Critical failure (action aborted) |
| `DEBUG` | Detailed technical information |

### 8.3 Sample Log (Minor Update)

```
[2026-06-03 03:12:00] [INFO] === Maintenance start: /var/www/clients/client1/web1/web | User: web1 ===
[2026-06-03 03:12:01] [INFO] Installed version: 28.0.12.3
[2026-06-03 03:12:01] [INFO] PHP version (web user): 8.2.18
[2026-06-03 03:12:02] [INFO] Querying update server...
[2026-06-03 03:12:02] [INFO] Available version from update server: 28.0.14
[2026-06-03 03:12:02] [INFO] Minor update available: v28.0.12.3 → v28.0.14
[2026-06-03 03:12:02] [INFO] Maintenance mode: ON
[2026-06-03 03:12:03] [INFO] Running Nextcloud updater (updater.phar)...
[2026-06-03 03:13:44] [INFO] updater.phar completed (exit code: 0)
[2026-06-03 03:13:44] [INFO] Database migrations (occ upgrade)...
[2026-06-03 03:14:12] [INFO] Database migrations OK
[2026-06-03 03:14:12] [INFO] App updates (occ app:update --all)...
[2026-06-03 03:14:28] [INFO] Repair routine (occ maintenance:repair)...
[2026-06-03 03:14:31] [INFO] Maintenance mode: OFF
[2026-06-03 03:14:31] [INFO] Update/upgrade procedure complete
[2026-06-03 03:14:32] [INFO] Minor update complete. New version: 28.0.14
[2026-06-03 03:14:32] [INFO] === Maintenance end: /var/www/clients/client1/web1/web ===
```

### 8.4 Log Rotation (logrotate)

Recommended `/etc/logrotate.d/nextcloud-update`:

```
/var/log/Nextcloud-Update/*.log {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    create 640 root root
}
```

---

## 9. Backup Strategy

A backup is created **only before major upgrades**. Minor updates do not need a backup because `updater.phar` creates its own internal copy.

### 9.1 Backup Contents

| Component | What | Where |
|-----------|------|-------|
| Nextcloud files | rsync (without `data/`) | `/var/backups/nextcloud/{web-user}_v{version}_{date}/files/` |
| Database | mysqldump (MySQL/MariaDB) | `/var/backups/nextcloud/{web-user}_v{version}_{date}/database.sql` |

**Note:** The `data/` directory is excluded from the backup because it typically lives on separate storage and can be very large. User data must be covered by regular server-level backups.

### 9.2 Backup Directory Example

```
/var/backups/nextcloud/
└── web1_v28.0.14_20260603_031512/
    ├── files/                    # Nextcloud application files
    │   ├── occ
    │   ├── config/
    │   ├── apps/
    │   └── ...
    └── database.sql              # Full database dump
```

### 9.3 Rollback After a Failed Upgrade

```bash
# 1. Ensure maintenance mode is on
sudo -u web1 php /var/www/clients/client1/web1/web/occ maintenance:mode --on

# 2. Restore files
rsync -a --delete /var/backups/nextcloud/web1_v28.0.14_20260603_031512/files/ \
    /var/www/clients/client1/web1/web/

# 3. Restore database
mysql -u {db_user} -p{db_pass} {db_name} \
    < /var/backups/nextcloud/web1_v28.0.14_20260603_031512/database.sql

# 4. Turn off maintenance mode
sudo -u web1 php /var/www/clients/client1/web1/web/occ maintenance:mode --off
```

---

## 10. Troubleshooting

### 10.1 Common Errors

**`Cannot determine current version`**

```
[ERROR] Cannot determine current version – installation skipped
```

Possible causes:

- `occ` is not executable: `chmod +x /var/www/.../occ`
- PHP not available for the web user: `sudo -u web1 php --version`
- Nextcloud installation is incomplete
- `jq` not installed: `apt-get install jq`

---

**`updater.phar not found`**

```
[WARN] updater.phar not found at: .../updater/updater.phar
```

The script continues and runs only `occ upgrade` (file replacement is skipped). This happens when:

- The installation was set up manually without the Nextcloud updater
- `updater.phar` is located in a non-standard path

Solution: download `updater.phar` manually or adjust the path in `run_update()`.

---

**`Database migrations failed`**

```
[ERROR] Database migrations failed
```

Maintenance mode has been turned off automatically. Investigate:

```bash
# Run manually to see full output
sudo -u web1 php /var/www/clients/client1/web1/web/occ upgrade

# Check the log
tail -50 /var/log/Nextcloud-Update/web1.log
```

---

**`Could not disable maintenance mode`**

```
[WARN] Maintenance mode could not be disabled automatically!
```

Nextcloud remains in maintenance mode. Immediate action:

```bash
sudo -u web1 php /var/www/clients/client1/web1/web/occ maintenance:mode --off
```

---

**`Email delivery failed`**

Test the connection manually:

```bash
curl -v --url "smtps://mail.example.com:465" --ssl-reqd \
     --mail-from "sender@example.com" \
     --mail-rcpt "recipient@example.com" \
     --user "sender@example.com:password" \
     --upload-file /dev/null
```

Common causes:

- Wrong password in `smtp.conf`
- Firewall blocks outbound port 465
- Two-factor authentication active on the SMTP account (use an app password)
- `SMTP_FROM` does not match `SMTP_USER`

---

**`Another process is already running`**

```
Warning: Another process is already running (PID: 12345). Aborting.
```

A stale lock file is present:

```bash
# Check whether the process is actually still running
ps aux | grep nextcloud-update

# Remove lock file if the process is no longer running
rm /var/run/nextcloud-update-manual.lock
rm /var/run/nextcloud-update-cron.lock
```

---

### 10.2 Debugging

Both scripts write DEBUG messages to the log file only (not to stdout). To monitor in real time:

```bash
# Follow a single installation's log
tail -f /var/log/Nextcloud-Update/web1.log

# Follow all logs simultaneously
tail -f /var/log/Nextcloud-Update/*.log

# Check the last cron run
cat /var/log/Nextcloud-Update/cron.log
```

---

## 11. Technical Reference

### 11.1 APIs Used

**Nextcloud Update Server:**

```
GET https://updates.nextcloud.com/updater_server/
    ?version={current_4part_version}
    &PHP_version={php_version}
    &LANG=de
    &request_type=nextcloud
```

Response (XML):

```xml
<nextcloud>
  <version>29.0.3</version>
  <versionstring>Nextcloud 29.0.3</versionstring>
  <url>https://download.nextcloud.com/...</url>
  <web>https://docs.nextcloud.com/...</web>
  <signature>...</signature>
</nextcloud>
```

An empty response (`<nextcloud/>`) means no update is available.

**Nextcloud App Store API:**

```
GET https://apps.nextcloud.com/api/v1/platform/{major}.0.0/apps.json
```

Returns a JSON array of all apps available for the given platform version. Each element contains at least `id` (the app ID).

### 11.2 occ Commands

| Command | Purpose |
|---------|---------|
| `occ status --output=json` | Current version and status |
| `occ maintenance:mode --on/--off` | Toggle maintenance mode |
| `occ upgrade` | Database migrations after file update |
| `occ app:list --output=json` | List all installed apps |
| `occ app:update --all` | Update all apps to the latest version |
| `occ maintenance:repair` | Repair routine (indices, caches) |

### 11.3 Update Process in Detail

```
updater.phar --no-interaction
    ↓
  Queries update server for a new version
  Downloads new version (ZIP)
  Verifies signature
  Creates internal backup
  Enables maintenance mode
  Extracts new files
  Exits
    ↓
occ upgrade
    ↓
  Reads new version from version.php
  Runs database migrations
  Updates app versions in database
    ↓
occ app:update --all
    ↓
  Updates all apps to latest compatible version
    ↓
occ maintenance:repair
    ↓
  Repairs database indices
  Clears cache
  Checks data integrity
    ↓
Maintenance mode: OFF
```

### 11.4 Version Normalisation

Nextcloud uses four-part version numbers internally (e.g. `28.0.12.3`), while the update server and user interface show three-part versions (`28.0.12`). The scripts normalise to three parts for comparison:

```bash
normalize_version() {
    echo "$1" | cut -d. -f1-3
}
# 28.0.12.3 → 28.0.12
# 29.0.0    → 29.0.0
```

Major version comparison uses only the first field:

```bash
get_major() {
    echo "$1" | cut -d. -f1
}
```

### 11.5 Security Considerations

- **SMTP configuration** protected with `chmod 600` to keep credentials root-readable only
- **SMTP config parsing** avoids a blind `source` — only explicitly whitelisted variable names are loaded
- **Lock file** prevents concurrent execution and race conditions
- **mysqldump password** is passed via `-p"$PASS"` (not via environment variable, as mysqldump preferentially reads `.my.cnf`)
- **occ commands** always run as the web owner (`sudo -u web{N}`), never as root
