# Nextcloud Update Manager

Automated update and upgrade management for multiple Nextcloud installations managed by **ISPConfig**.

> **ISPConfig servers only** — These scripts are designed exclusively for Nextcloud installations
> running under [ISPConfig](https://www.ispconfig.org/). They depend on ISPConfig's specific
> directory layout (`/var/www/clients/client{N}/web{N}/web/`), its web-user naming convention
> (`web{N}`), and the per-user PHP CLI configuration that ISPConfig sets up automatically.
> They will **not** work on plain LAMP/LEMP stacks or other control panels without adaptation.

## Features

- Automatically detects all Nextcloud installations under `/var/www/clients/`
- **Minor updates** (within the same major version) are applied automatically
- **Major upgrades** require manual confirmation (Script 1) or trigger an email notification (Script 2)
- Checks app compatibility against the Nextcloud App Store before any major upgrade
- Creates a backup (files + database) before each major upgrade
- Full update process: `updater.phar` → `occ upgrade` → `app:update` → `maintenance:repair`
- Per-installation log files under `/var/log/Nextcloud-Update/`
- Lock file protection against concurrent runs
- `--dry-run` mode for safe testing

## Scripts

| Script                       | Purpose                                                                     |
| ---------------------------- | --------------------------------------------------------------------------- |
| `nextcloud-update-manual.sh` | Interactive script for manual execution by an administrator                 |
| `nextcloud-update-cron.sh`   | Silent cron job script; sends email for major upgrades instead of prompting |

## Requirements

- Debian 11 (Bullseye), 12 (Bookworm), or 13 (Trixie); Ubuntu 20.04/22.04/24.04; or RHEL/CentOS 8+ (dnf/yum)
- ISPconfig standard directory layout: `/var/www/clients/client{N}/web{N}/web/`
- Root access; `sudo` configured to allow `root → web{N}` without password
- Packages: `curl`, `jq`, `rsync`, `default-mysql-client` (installed automatically)
- SMTPS-capable mail account for cron notifications (Script 2)

## Quick Install

```bash
git clone https://github.com/TheLegeres71/AF-Nextcloud-Update-Skripte.git
cd AF-Nextcloud-Update-Skripte
chmod +x install.sh
sudo ./install.sh
```

The installer will:

1. Check and install all missing dependencies
2. Copy scripts to `/usr/local/sbin/` with correct permissions
3. Create `/etc/nextcloud-update/smtp.conf` (interactive setup)
4. Optionally configure a cron job

## Manual Installation

```bash
# Install scripts
cp scripts/nextcloud-update-manual.sh /usr/local/sbin/
cp scripts/nextcloud-update-cron.sh   /usr/local/sbin/
chmod 700 /usr/local/sbin/nextcloud-update-*.sh

# Create SMTP config
mkdir -p /etc/nextcloud-update
cp scripts/smtp.conf.example /etc/nextcloud-update/smtp.conf
nano /etc/nextcloud-update/smtp.conf
chmod 600 /etc/nextcloud-update/smtp.conf
chown root:root /etc/nextcloud-update/smtp.conf

# Set up cron job (weekly, Sunday 03:00)
echo "0 3 * * 0 root /usr/local/sbin/nextcloud-update-cron.sh" \
  > /etc/cron.d/nextcloud-update
```

## Usage

```bash
# Dry run (no changes, shows what would happen)
nextcloud-update-manual.sh --dry-run

# Run updates interactively
nextcloud-update-manual.sh
```

## Configuration

**SMTP configuration file:** `/etc/nextcloud-update/smtp.conf`

```ini
SMTP_HOST=mail.example.com
SMTP_PORT=465
SMTP_USER=nextcloud-notify@example.com
SMTP_PASS=yourpassword
SMTP_FROM=nextcloud-notify@example.com
MAIL_TO=admin@example.com
```

Permissions must be `600` (readable by root only).

## Repository Structure

```
nextcloud-update/
├── scripts/
│   ├── nextcloud-update-manual.sh   # Manual update script
│   ├── nextcloud-update-cron.sh     # Cron job script
│   └── smtp.conf.example            # SMTP config template
├── install.sh                       # Installer
├── README.md                        # This file
├── DOKUMENTATION-DE.md              # Full documentation (German)
└── DOKUMENTATION-EN.md              # Full documentation (English)
```

## Logs

Each Nextcloud installation gets its own log file:

```
/var/log/Nextcloud-Update/
├── web1.log     # Installation under /var/www/clients/client1/web1/web/
├── web2.log
└── cron.log     # Global cron run log
```

## How It Works

```
find /var/www/clients/*/*/web/ → detect Nextcloud
         ↓
get current version (occ status)
         ↓
query Nextcloud update server
         ↓
same major?  ──yes──→  apply update automatically
         ↓ no
check app compatibility (apps.nextcloud.com API)
         ↓
Script 1: show results → ask admin → backup → upgrade
Script 2: send email notification → wait for manual action
```

## License

MIT
