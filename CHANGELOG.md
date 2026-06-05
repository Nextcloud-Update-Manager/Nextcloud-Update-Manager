# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Planned
- Internationalization (i18n) support
- Support for non-ISPConfig directory layouts

---

## [0.1.0] – 2026-06-04

Initial release.

### Added

#### Core functionality
- Automatic detection of all Nextcloud installations under `/var/www/clients/` (ISPConfig standard layout)
- Minor updates (within the same major version) applied automatically without confirmation
- Major upgrade detection with app compatibility check against the Nextcloud App Store API
- Per-installation log files under `/var/log/Nextcloud-Update/` with `INFO`/`WARN`/`ERROR`/`DEBUG` levels
- Lock file protection against concurrent runs

#### `nextcloud-update-manual.sh` — interactive script
- Coloured terminal output with upgrade summary
- Interactive confirmation prompt for major upgrades (`y/Y/j/J`)
- `--dry-run` mode: shows all planned actions without making any changes
- Backup of Nextcloud files (rsync, without `data/`) and database (mysqldump) before major upgrades
- Detection and automatic completion of pending database migrations (`needsDbUpgrade: true`)

#### `nextcloud-update-cron.sh` — automated cron script
- Silent operation (log file only, no stdout) — safe for unattended cron execution
- Email notification via SMTPS for available major upgrades including app compatibility report
- SMTP configuration loaded from `/etc/nextcloud-update/smtp.conf` (chmod 600)
- Detection and automatic completion of pending database migrations

#### `install.sh` — installer
- Automatic detection of first install vs. update: SMTP and cron configuration are preserved on re-runs
- `--full` flag forces complete reconfiguration including SMTP and cron
- Checks and installs missing system packages (`curl`, `jq`, `rsync`, `default-mysql-client`)
- Interactive SMTP setup with input validation and optional connection test
- Configurable cron schedule

#### Robustness fixes
- PHP CLI binary auto-detection per web user (`find_php_bin`) with fallback scanning of `/usr/bin/php*`
- `run_php()` helper ensures updater.phar uses the same PHP binary as `occ`
- Correct JSON field name (`version` not `installed_version`) and `grep -m 1 '^{'` to filter non-JSON lines from `occ status` output
- `occ update:check` used instead of manual update server URL (complex proprietary format)
- `grep -i 'nextcloud'` filter prevents app version strings from being mistaken for server versions
- Stale `.bak` files with wrong ownership (root) auto-corrected before updater runs
- `read -r answer </dev/tty` prevents stdin conflict with `find_installations` pipe
- Extended `CORE_APPS_PATTERN` covers all Nextcloud bundled apps including recently integrated ones (`app_api`, `files_downloadlimit`, etc.)
- SMTP variables use `declare -g` to be globally accessible outside `load_smtp_config`

#### Documentation
- `README.md` in English with ISPConfig scope notice, quick install, update workflow, and mode table
- `DOKUMENTATION-DE.md` — full German documentation (11 sections)
- `DOKUMENTATION-EN.md` — full English documentation (11 sections)
- `github-discussions-welcome.md` — customised GitHub Discussions welcome text

### Supported platforms
- Debian 11 (Bullseye), 12 (Bookworm), 13 (Trixie)
- Ubuntu 20.04 LTS, 22.04 LTS, 24.04 LTS
- ISPConfig with PHP 8.0–8.5
- Nextcloud 29 and later

---

[Unreleased]: https://github.com/Nextcloud-Update-Manager/Nextcloud-Update-Manager/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Nextcloud-Update-Manager/Nextcloud-Update-Manager/releases/tag/v0.1.0
