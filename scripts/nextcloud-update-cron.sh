#!/bin/bash
# =============================================================================
# nextcloud-update-cron.sh
# Nextcloud Update/Upgrade – Automatischer Cronjob (root)
#
# Voraussetzungen:
#   - Ausführung als root
#   - Pakete: curl, jq, rsync, mysqldump
#   - SMTP-Konfiguration: /etc/nextcloud-update/smtp.conf
#   - sudo ohne Passwort für root → web{X}-User konfiguriert
#
# Installation:
#   cp nextcloud-update-cron.sh /usr/local/sbin/
#   chmod 700 /usr/local/sbin/nextcloud-update-cron.sh
#   mkdir -p /etc/nextcloud-update
#   cp smtp.conf.example /etc/nextcloud-update/smtp.conf
#   chmod 600 /etc/nextcloud-update/smtp.conf
#   chown root:root /etc/nextcloud-update/smtp.conf
#
# Cronjob (z.B. jeden Sonntag um 03:00):
#   0 3 * * 0 root /usr/local/sbin/nextcloud-update-cron.sh
# =============================================================================

set -uo pipefail

# =============================================================================
# KONFIGURATION
# =============================================================================

NC_SEARCH_BASE="/var/www/clients"
NC_SEARCH_MAXDEPTH=4
LOG_DIR="/var/log/Nextcloud-Update"
BACKUP_BASE="/var/backups/nextcloud"
LOCK_FILE="/var/run/nextcloud-update-cron.lock"
NC_UPDATE_SERVER="https://updates.nextcloud.com/updater_server"
NC_APPSTORE_API="https://apps.nextcloud.com/api/v1"

SMTP_CONFIG="/etc/nextcloud-update/smtp.conf"
MAIL_TO="admin@example.com"

# SMTP-Variablen (werden aus SMTP_CONFIG geladen)
SMTP_HOST=""
SMTP_PORT="465"
SMTP_USER=""
SMTP_PASS=""
SMTP_FROM=""

# =============================================================================
# GLOBALE VARIABLEN
# =============================================================================

LOG_FILE=""
GLOBAL_LOG="${LOG_DIR}/cron.log"
APPSTORE_CACHE=""
APPSTORE_CACHE_VERSION=""
COMPAT_APPS=()
INCOMPAT_APPS=()
UNKNOWN_APPS=()
SMTP_AVAILABLE=false
declare -A PHP_BIN_CACHE=()

# =============================================================================
# LOGGING (kein stdout – Cron-sicher)
# =============================================================================

log() {
    local level="$1"
    local msg="$2"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    [[ -n "$LOG_FILE" ]] && echo "[$ts] [$level] $msg" >> "$LOG_FILE"
}

log_global() {
    local level="$1"
    local msg="$2"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] [$level] $msg" >> "$GLOBAL_LOG"
}

log_debug() {
    [[ -n "$LOG_FILE" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $1" >> "$LOG_FILE"
}

# =============================================================================
# VORAUSSETZUNGEN
# =============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Fehler: Dieses Skript muss als root ausgeführt werden." >&2
        exit 1
    fi
}

check_dependencies() {
    local missing=()
    for cmd in curl jq rsync mysqldump; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_global "ERROR" "Fehlende Pakete: ${missing[*]} – Skript abgebrochen"
        exit 1
    fi
}

setup_dirs() {
    if [[ ! -d "$LOG_DIR" ]]; then
        mkdir -p "$LOG_DIR"
        chmod 750 "$LOG_DIR"
    fi
    [[ -d "$BACKUP_BASE" ]] || mkdir -p "$BACKUP_BASE"
}

acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            log_global "WARN" "Anderer Prozess läuft bereits (PID: $pid) – Abbruch"
            exit 0
        fi
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"' EXIT
}

load_smtp_config() {
    if [[ ! -f "$SMTP_CONFIG" ]]; then
        log_global "ERROR" "SMTP-Konfiguration nicht gefunden: $SMTP_CONFIG"
        log_global "ERROR" "E-Mail-Benachrichtigungen für Major-Upgrades nicht verfügbar"
        return 1
    fi

    local perms
    perms=$(stat -c '%a' "$SMTP_CONFIG")
    if [[ "$perms" != "600" && "$perms" != "400" ]]; then
        log_global "WARN" "SMTP-Konfiguration hat unsichere Berechtigungen ($perms) – erwartet: 600"
    fi

    # Nur erlaubte Variablennamen aus Config-Datei laden (kein blindes source)
    while IFS='=' read -r key value; do
        # Kommentare und leere Zeilen überspringen
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${key// }" ]] && continue
        # Whitespace trimmen
        key="${key// /}"
        value="${value// /}"
        case "$key" in
            SMTP_HOST|SMTP_PORT|SMTP_USER|SMTP_PASS|SMTP_FROM|MAIL_TO)
                declare "$key=$value"
                ;;
        esac
    done < "$SMTP_CONFIG"

    if [[ -z "$SMTP_HOST" || -z "$SMTP_USER" || -z "$SMTP_PASS" || -z "$SMTP_FROM" ]]; then
        log_global "ERROR" "SMTP-Konfiguration unvollständig (benötigt: SMTP_HOST, SMTP_USER, SMTP_PASS, SMTP_FROM)"
        return 1
    fi

    log_global "INFO" "SMTP-Konfiguration geladen: $SMTP_FROM → $SMTP_HOST:$SMTP_PORT"
    return 0
}

# =============================================================================
# E-MAIL VIA SMTPS (curl)
# =============================================================================

send_email() {
    local subject="$1"
    local body="$2"

    if ! $SMTP_AVAILABLE; then
        log "WARN" "E-Mail-Versand nicht möglich – SMTP nicht konfiguriert"
        return 1
    fi

    # MIME-konformer E-Mail-Header mit CRLF-Zeilenenden (RFC 5321)
    local headers
    headers=$(printf "From: Nextcloud Updater <%s>\r\nTo: %s\r\nSubject: %s\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n" \
        "$SMTP_FROM" "$MAIL_TO" "$subject")

    if curl -sf \
            --url "smtps://${SMTP_HOST}:${SMTP_PORT}" \
            --ssl-reqd \
            --mail-from "$SMTP_FROM" \
            --mail-rcpt "$MAIL_TO" \
            --user "${SMTP_USER}:${SMTP_PASS}" \
            --upload-file <(printf '%s%b' "$headers" "$body") \
            >> "$LOG_FILE" 2>&1; then
        log "INFO" "E-Mail gesendet an $MAIL_TO"
        log "INFO" "  Betreff: $subject"
    else
        log "WARN" "E-Mail-Versand fehlgeschlagen (curl Exit: $?) – Details im Log"
    fi
}

# =============================================================================
# NEXTCLOUD-ERKENNUNG
# =============================================================================

is_nextcloud() {
    local dir="$1"
    [[ -f "$dir/occ" && -f "$dir/config/config.php" && -f "$dir/version.php" ]]
}

find_installations() {
    find "$NC_SEARCH_BASE" -maxdepth "$NC_SEARCH_MAXDEPTH" -name "occ" -type f 2>/dev/null \
        | while IFS= read -r occ; do
            local dir
            dir=$(dirname "$occ")
            is_nextcloud "$dir" && echo "$dir"
        done
}

# =============================================================================
# VERSIONSVERWALTUNG
# =============================================================================

get_web_user() {
    stat -c '%U' "$1"
}

# Sucht die PHP-CLI-Binary für den Web-User.
# ISPConfig legt versionierte Binaries an (/usr/bin/php8.x), nicht zwingend ein
# generisches /usr/bin/php. Ergebnis wird je User gecacht.
find_php_bin() {
    local web_user="$1"

    # Cache-Treffer
    if [[ -n "${PHP_BIN_CACHE[$web_user]:-}" ]]; then
        echo "${PHP_BIN_CACHE[$web_user]}"
        return 0
    fi

    local php_bin=""

    # 1. PHP über die Umgebung des Web-Users (sudo-Session)
    php_bin=$(sudo -u "$web_user" bash -c 'command -v php 2>/dev/null' 2>/dev/null) || true

    # 2. Versionierte Binaries direkt prüfen (neueste PHP-Version zuerst)
    if [[ -z "$php_bin" ]]; then
        while IFS= read -r p; do
            if [[ -x "$p" && ! -L "$p" ]]; then
                php_bin="$p"
                break
            fi
        done < <(find /usr/bin -maxdepth 1 -name 'php[0-9]*' \
                     ! -name 'php-cgi*' ! -name 'php-config*' 2>/dev/null \
                 | sort -rV)
    fi

    # 3. Systemweites php als letzter Ausweg
    if [[ -z "$php_bin" ]]; then
        php_bin=$(command -v php 2>/dev/null) || true
    fi

    if [[ -z "$php_bin" ]]; then
        log "ERROR" "Keine PHP-CLI-Binary für User '$web_user' gefunden"
        return 1
    fi

    log_debug "PHP-Binary für $web_user: $php_bin"
    PHP_BIN_CACHE[$web_user]="$php_bin"
    echo "$php_bin"
}

run_occ() {
    local nc_dir="$1"
    local web_user="$2"
    shift 2
    local php_bin
    php_bin=$(find_php_bin "$web_user") || return 1
    sudo -u "$web_user" "$php_bin" "$nc_dir/occ" "$@"
}

run_php() {
    local web_user="$1"
    shift
    local php_bin
    php_bin=$(find_php_bin "$web_user") || return 1
    sudo -u "$web_user" "$php_bin" "$@"
}

get_current_version() {
    # occ schreibt Warnzeilen auf stdout vor dem JSON (z.B. bei needsDbUpgrade).
    # grep -m 1 '^{' extrahiert nur die JSON-Zeile.
    run_occ "$1" "$2" status --output=json 2>/dev/null \
        | grep -m 1 '^{' \
        | jq -r '.version // empty' 2>/dev/null
}

get_php_version_string() {
    local web_user="$1"
    local php_bin
    php_bin=$(find_php_bin "$web_user") || { echo "8.0"; return; }
    sudo -u "$web_user" "$php_bin" -r 'echo PHP_VERSION;' 2>/dev/null || echo "8.0"
}

normalize_version() {
    echo "$1" | cut -d. -f1-3
}

get_major() {
    echo "$1" | cut -d. -f1
}

get_latest_version() {
    local nc_dir="$1"
    local web_user="$2"
    local output
    output=$(run_occ "$nc_dir" "$web_user" update:check 2>/dev/null) || output=""
    output=$(echo "$output" | grep -v 'require upgrade' | grep -v 'use your browser')
    echo "$output" | grep -oP '[0-9]+\.[0-9]+\.[0-9]+(?= is available)' | head -1
}

# =============================================================================
# APP-KOMPATIBILITÄTSPRÜFUNG
# =============================================================================

CORE_APPS_PATTERN="^(admin_audit|app_api|bruteforcesettings|cloud_federation_api|comments|contactsinteraction|dashboard|dav|encryption|federatedfilesharing|federation|files|files_downloadlimit|files_external|files_pdfviewer|files_reminders|files_sharing|files_trash|files_trashbin|files_versions|firstrunwizard|logreader|lookup_server_connector|nextcloud_announcements|notifications|oauth2|password_policy|privacy|profile|provisioning_api|recommendations|serverinfo|settings|sharebymail|support|survey_client|systemtags|theming|twofactor_backupcodes|updatenotification|user_ldap|user_status|weather_status|webhook_listeners|workflowengine|activity|circles|richdocuments|richdocumentscode|text|viewer|photos|talk|calendar|contacts)$"

is_core_app() {
    echo "$1" | grep -qE "$CORE_APPS_PATTERN"
}

check_app_compatibility() {
    local nc_dir="$1"
    local web_user="$2"
    local target_major="$3"

    COMPAT_APPS=()
    INCOMPAT_APPS=()
    UNKNOWN_APPS=()

    log "INFO" "App-Kompatibilität wird geprüft für v${target_major}..."

    if [[ "$APPSTORE_CACHE_VERSION" != "$target_major" || -z "$APPSTORE_CACHE" ]]; then
        APPSTORE_CACHE=$(curl -sf --max-time 60 \
            "${NC_APPSTORE_API}/platform/${target_major}.0.0/apps.json" 2>/dev/null) || APPSTORE_CACHE=""
        APPSTORE_CACHE_VERSION="$target_major"
        [[ -z "$APPSTORE_CACHE" ]] && log "WARN" "App Store API nicht erreichbar – Apps als 'unbekannt' markiert"
    fi

    local installed_apps
    installed_apps=$(run_occ "$nc_dir" "$web_user" app:list --output=json 2>/dev/null \
        | jq -r '.enabled | keys[]' 2>/dev/null) || installed_apps=""

    if [[ -z "$installed_apps" ]]; then
        log "WARN" "Keine aktivierten Apps ermittelt"
        return 0
    fi

    while IFS= read -r app; do
        [[ -z "$app" ]] && continue
        is_core_app "$app" && continue

        if [[ -z "$APPSTORE_CACHE" ]]; then
            UNKNOWN_APPS+=("$app")
        elif echo "$APPSTORE_CACHE" | jq -e --arg a "$app" '.[] | select(.id == $a)' &>/dev/null; then
            COMPAT_APPS+=("$app")
        else
            UNKNOWN_APPS+=("$app")
        fi
    done <<< "$installed_apps"

    log "INFO" "App-Prüfung: Im App Store=${#COMPAT_APPS[@]} | Nicht gelistet=${#UNKNOWN_APPS[@]}"
}

# =============================================================================
# BACKUP
# =============================================================================

get_config_value() {
    local nc_dir="$1"
    local key="$2"
    php -r "include '${nc_dir}/config/config.php'; echo \$CONFIG['${key}'] ?? '';" 2>/dev/null
}

perform_backup() {
    local nc_dir="$1"
    local web_user="$2"
    local version="$3"
    local backup_dir="${BACKUP_BASE}/${web_user}_v${version}_$(date +%Y%m%d_%H%M%S)"

    log "INFO" "Erstelle Backup: $backup_dir"
    mkdir -p "$backup_dir"

    # Datei-Backup (data/ ausgeschlossen – meist auf separatem Storage)
    rsync -a --delete \
        --exclude="data/" \
        --exclude="updater-*/backups/" \
        "$nc_dir/" "$backup_dir/files/" >> "$LOG_FILE" 2>&1 \
        && log "INFO" "Datei-Backup OK" \
        || log "WARN" "Datei-Backup mit Warnungen"

    # Datenbank-Backup
    local db_type
    db_type=$(get_config_value "$nc_dir" "dbtype")

    if [[ "$db_type" == "mysql" || "$db_type" == "pgsql" ]]; then
        local db_name db_user db_pass db_host
        db_name=$(get_config_value "$nc_dir" "dbname")
        db_user=$(get_config_value "$nc_dir" "dbuser")
        db_pass=$(get_config_value "$nc_dir" "dbpassword")
        db_host=$(get_config_value "$nc_dir" "dbhost")
        db_host="${db_host%%:*}"
        [[ -z "$db_host" ]] && db_host="localhost"

        log "INFO" "Datenbank-Backup: $db_name @ $db_host"
        mysqldump -h "$db_host" -u "$db_user" -p"$db_pass" \
            --single-transaction --routines --triggers \
            "$db_name" > "$backup_dir/database.sql" 2>> "$LOG_FILE" \
            && log "INFO" "Datenbank-Backup OK" \
            || log "WARN" "Datenbank-Backup fehlgeschlagen"
    else
        log "WARN" "DB-Typ '$db_type': kein automatisches Backup (nur MySQL/MariaDB)"
    fi

    echo "$backup_dir"
}

# =============================================================================
# UPDATE-ABLAUF
# =============================================================================

run_update() {
    local nc_dir="$1"
    local web_user="$2"
    local updater_phar="$nc_dir/updater/updater.phar"

    _maintenance_off() {
        log "WARN" "Deaktiviere Maintenance Mode nach Fehler..."
        run_occ "$nc_dir" "$web_user" maintenance:mode --off >> "$LOG_FILE" 2>&1 || true
    }

    # 1. Überbleibsel prüfen: .bak-Dateien die root gehören blockieren updater.phar
    local stale_bak_files
    stale_bak_files=$(find "$nc_dir" -name "*.bak" -not -user "$web_user" 2>/dev/null)
    if [[ -n "$stale_bak_files" ]]; then
        log "WARN" "Falsch gesetzte .bak-Dateien gefunden – korrigiere Eigentümer:"
        while IFS= read -r f; do
            log "WARN" "  $f ($(stat -c '%U:%G' "$f"))"
            chown "${web_user}:" "$f" && log "INFO" "  → chown OK: $f" \
                                      || log "ERROR" "  → chown fehlgeschlagen: $f"
        done <<< "$stale_bak_files"
    fi

    # 2. Maintenance Mode aktivieren
    log "INFO" "Maintenance Mode: AN"
    if ! run_occ "$nc_dir" "$web_user" maintenance:mode --on >> "$LOG_FILE" 2>&1; then
        log "ERROR" "Fehler beim Aktivieren des Maintenance Modes"
        return 1
    fi

    # 3. Nextcloud Updater
    if [[ -f "$updater_phar" ]]; then
        log "INFO" "Führe updater.phar aus..."
        run_php "$web_user" "$updater_phar" --no-interaction >> "$LOG_FILE" 2>&1
        local upd_rc=$?
        if [[ $upd_rc -gt 1 ]]; then
            log "ERROR" "updater.phar fehlgeschlagen (Exit: $upd_rc)"
            _maintenance_off
            return 1
        fi
        log "INFO" "updater.phar abgeschlossen (Exit: $upd_rc)"
    else
        log "WARN" "updater.phar nicht gefunden ($updater_phar) – nur DB-Migration"
    fi

    # 3. Datenbank-Migrationen
    log "INFO" "Datenbankmigrationen (occ upgrade)..."
    if ! run_occ "$nc_dir" "$web_user" upgrade >> "$LOG_FILE" 2>&1; then
        log "ERROR" "Datenbankmigrationen fehlgeschlagen"
        _maintenance_off
        return 1
    fi
    log "INFO" "Datenbankmigrationen OK"

    # 4. Apps aktualisieren
    log "INFO" "App-Updates..."
    run_occ "$nc_dir" "$web_user" app:update --all >> "$LOG_FILE" 2>&1 \
        || log "WARN" "App-Update mit Warnungen"

    # 5. Reparatur-Routine
    log "INFO" "Reparatur-Routine..."
    run_occ "$nc_dir" "$web_user" maintenance:repair >> "$LOG_FILE" 2>&1 \
        || log "WARN" "Repair mit Warnungen"

    # 6. Maintenance Mode deaktivieren
    log "INFO" "Maintenance Mode: AUS"
    run_occ "$nc_dir" "$web_user" maintenance:mode --off >> "$LOG_FILE" 2>&1 \
        || log "WARN" "Maintenance Mode konnte nicht deaktiviert werden – bitte manuell prüfen!"

    log "INFO" "Update/Upgrade abgeschlossen"
    return 0
}

# =============================================================================
# E-MAIL-BODY FÜR MAJOR-UPGRADE-BENACHRICHTIGUNG
# =============================================================================

build_upgrade_email_body() {
    local nc_dir="$1"
    local web_user="$2"
    local current_version="$3"
    local latest_version="$4"
    local latest_major="$5"
    local hostname="$6"

    local line50
    line50=$(printf '%.0s─' {1..50})

    printf "Nextcloud Major-Upgrade verfügbar\n"
    printf "%s\n\n" "$line50"
    printf "%-22s %s\n" "Server:"            "$hostname"
    printf "%-22s %s\n" "Installation:"      "$nc_dir"
    printf "%-22s %s\n" "Web-User:"          "$web_user"
    printf "%-22s v%s\n" "Aktuell:"          "$current_version"
    printf "%-22s v%s\n" "Verfügbar:"        "$latest_version"
    printf "\n"
    printf "App-Kompatibilität mit Nextcloud v%s:\n" "$latest_major"
    printf "%s\n" "$line50"

    if [[ ${#COMPAT_APPS[@]} -gt 0 ]]; then
        printf "\nIM APP STORE FÜR v%s VERFÜGBAR (%d):\n" "$latest_major" "${#COMPAT_APPS[@]}"
        for app in "${COMPAT_APPS[@]}"; do
            printf "  ✓  %s\n" "$app"
        done
    fi

    if [[ ${#UNKNOWN_APPS[@]} -gt 0 ]]; then
        printf "\nNICHT IM APP STORE FÜR v%s GELISTET – bitte prüfen (%d):\n" "$latest_major" "${#UNKNOWN_APPS[@]}"
        printf "(Kann bedeuten: noch nicht freigegeben, deprecated oder proprietäre App)\n"
        for app in "${UNKNOWN_APPS[@]}"; do
            printf "  ?  %s\n" "$app"
        done
    fi

    if [[ ${#COMPAT_APPS[@]} -eq 0 && ${#UNKNOWN_APPS[@]} -eq 0 ]]; then
        printf "\nKeine Drittanbieter-Apps aktiv – Upgrade unproblematisch.\n"
    fi

    printf "\n%s\n" "$line50"
    printf "\nNächste Schritte:\n"
    printf "  Führen Sie das Upgrade manuell durch:\n"
    printf "  > /usr/local/sbin/nextcloud-update-manual.sh\n\n"
    printf "  Das Skript führt Sie interaktiv durch den Upgrade-Prozess\n"
    printf "  und zeigt die App-Kompatibilität erneut an.\n\n"
    printf "Log-Datei: %s\n" "$LOG_FILE"
    printf "\n%s\n" "$line50"
    printf "Nextcloud Update Manager | %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
}

# =============================================================================
# INSTALLATIONS-VERARBEITUNG
# =============================================================================

process_installation() {
    local nc_dir="$1"
    local web_user
    web_user=$(get_web_user "$nc_dir")
    LOG_FILE="${LOG_DIR}/${web_user}.log"

    log "INFO" "=== Wartungsbeginn: $nc_dir | User: $web_user ==="

    # Aktuelle Version ermitteln
    local current_version
    current_version=$(get_current_version "$nc_dir" "$web_user")
    if [[ -z "$current_version" ]]; then
        log "ERROR" "Kann aktuelle Version nicht ermitteln – Installation übersprungen"
        return 1
    fi
    log "INFO" "Installierte Version: $current_version"

    # Auf ausstehende Datenbank-Migration prüfen.
    local needs_db_upgrade
    needs_db_upgrade=$(run_occ "$nc_dir" "$web_user" status --output=json 2>/dev/null \
        | grep -m 1 '^{' | jq -r '.needsDbUpgrade // false' 2>/dev/null) || needs_db_upgrade="false"

    if [[ "$needs_db_upgrade" == "true" ]]; then
        log "WARN" "Ausstehende Datenbankmigrationen erkannt (updater.phar lief bereits) – führe occ upgrade aus"
        if run_occ "$nc_dir" "$web_user" upgrade >> "$LOG_FILE" 2>&1; then
            run_occ "$nc_dir" "$web_user" app:update --all >> "$LOG_FILE" 2>&1 \
                || log "WARN" "App-Update mit Warnungen"
            run_occ "$nc_dir" "$web_user" maintenance:repair >> "$LOG_FILE" 2>&1 \
                || log "WARN" "Repair mit Warnungen"
            run_occ "$nc_dir" "$web_user" maintenance:mode --off >> "$LOG_FILE" 2>&1 \
                || log "WARN" "Maintenance Mode konnte nicht deaktiviert werden"
            current_version=$(get_current_version "$nc_dir" "$web_user")
            log "INFO" "DB-Migration abgeschlossen. Aktuelle Version: ${current_version:-unbekannt}"
        else
            log "ERROR" "occ upgrade fehlgeschlagen – Installation übersprungen"
            run_occ "$nc_dir" "$web_user" maintenance:mode --off >> "$LOG_FILE" 2>&1 || true
            return 1
        fi
    fi

    # PHP-Version
    local php_version
    php_version=$(get_php_version_string "$web_user")
    log_debug "PHP-Version: $php_version"

    # Auf Updates prüfen
    log "INFO" "Prüfe auf Updates (occ update:check)..."
    local latest_version
    latest_version=$(get_latest_version "$nc_dir" "$web_user")

    if [[ -z "$latest_version" ]]; then
        log "INFO" "Kein Update erhalten (aktuell oder Update-Server nicht erreichbar)"
        log "INFO" "=== Wartungsende: $nc_dir ==="
        return 0
    fi

    log "INFO" "Verfügbare Version: $latest_version"

    if [[ "$(normalize_version "$current_version")" == "$(normalize_version "$latest_version")" ]]; then
        log "INFO" "Nextcloud ist aktuell (v${current_version})"
        log "INFO" "=== Wartungsende: $nc_dir ==="
        return 0
    fi

    local current_major latest_major
    current_major=$(get_major "$current_version")
    latest_major=$(get_major "$latest_version")

    # -------------------------------------------------------------------------
    # MINOR-UPDATE: automatisch durchführen
    # -------------------------------------------------------------------------
    if [[ "$current_major" == "$latest_major" ]]; then
        log "INFO" "Minor-Update wird automatisch durchgeführt: v${current_version} → v${latest_version}"

        if run_update "$nc_dir" "$web_user"; then
            local new_version
            new_version=$(get_current_version "$nc_dir" "$web_user")
            log "INFO" "Minor-Update OK. Installierte Version: ${new_version:-unbekannt}"
        else
            log "ERROR" "Minor-Update fehlgeschlagen"
            log "INFO" "=== Wartungsende (FEHLER): $nc_dir ==="
            return 1
        fi

    # -------------------------------------------------------------------------
    # MAJOR-UPGRADE: E-Mail senden, nicht automatisch upgraden
    # -------------------------------------------------------------------------
    else
        log "INFO" "Major-Upgrade verfügbar: v${current_major} → v${latest_major}"

        # App-Kompatibilität prüfen
        check_app_compatibility "$nc_dir" "$web_user" "$latest_major"

        # Kompatibilitätsergebnis loggen
        [[ ${#COMPAT_APPS[@]} -gt 0 ]]  && log "INFO" "Im App Store für v${latest_major}: ${COMPAT_APPS[*]}"
        [[ ${#UNKNOWN_APPS[@]} -gt 0 ]] && log "WARN" "Nicht im App Store für v${latest_major}: ${UNKNOWN_APPS[*]}"

        # E-Mail-Benachrichtigung senden
        local hostname
        hostname=$(hostname -f 2>/dev/null || hostname)

        local subject="[Nextcloud] Major-Upgrade verfügbar: v${current_major}→v${latest_major} | ${hostname} | ${web_user}"
        local body
        body=$(build_upgrade_email_body \
            "$nc_dir" "$web_user" "$current_version" "$latest_version" "$latest_major" "$hostname")

        log "INFO" "Sende E-Mail-Benachrichtigung an $MAIL_TO..."
        send_email "$subject" "$body"
    fi

    log "INFO" "=== Wartungsende: $nc_dir ==="
    return 0
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    check_root
    setup_dirs
    acquire_lock

    log_global "INFO" "=== Nextcloud Cron-Wartung gestartet ==="
    log_global "INFO" "Suchpfad: $NC_SEARCH_BASE"

    check_dependencies

    # SMTP-Konfiguration laden
    if load_smtp_config; then
        SMTP_AVAILABLE=true
    else
        SMTP_AVAILABLE=false
        log_global "WARN" "SMTP nicht verfügbar – Major-Upgrade-Benachrichtigungen werden nicht gesendet"
    fi

    local found=0 ok=0 failed=0

    while IFS= read -r nc_dir; do
        [[ -z "$nc_dir" ]] && continue
        ((found++)) || true

        if process_installation "$nc_dir"; then
            ((ok++)) || true
        else
            ((failed++)) || true
        fi
    done < <(find_installations)

    log_global "INFO" "Installationen gefunden: $found | Erfolgreich: $ok | Fehler: $failed"
    log_global "INFO" "=== Nextcloud Cron-Wartung abgeschlossen ==="
}

main "$@"
