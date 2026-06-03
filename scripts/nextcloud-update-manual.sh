#!/bin/bash
# =============================================================================
# nextcloud-update-manual.sh
# Nextcloud Update/Upgrade – Manuelle Ausführung durch Administrator
#
# Voraussetzungen:
#   - Ausführung als root
#   - Pakete: curl, jq, rsync, mysqldump
#   - sudo ohne Passwort für root → web{X}-User konfiguriert
#
# Installation:
#   cp nextcloud-update-manual.sh /usr/local/sbin/
#   chmod 700 /usr/local/sbin/nextcloud-update-manual.sh
#
# Verwendung:
#   nextcloud-update-manual.sh [--dry-run]
# =============================================================================

set -uo pipefail

# =============================================================================
# KONFIGURATION
# =============================================================================

NC_SEARCH_BASE="/var/www/clients"
NC_SEARCH_MAXDEPTH=4
LOG_DIR="/var/log/Nextcloud-Update"
BACKUP_BASE="/var/backups/nextcloud"
LOCK_FILE="/var/run/nextcloud-update-manual.lock"
NC_UPDATE_SERVER="https://updates.nextcloud.com/updater_server"
NC_APPSTORE_API="https://apps.nextcloud.com/api/v1"
# NC_UPDATE_SERVER wird nicht mehr direkt abgefragt – occ update:check übernimmt das intern

# Dry-Run-Modus: zeigt Aktionen, führt sie nicht aus
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# =============================================================================
# FARBEN
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# =============================================================================
# GLOBALE VARIABLEN
# =============================================================================

LOG_FILE=""
APPSTORE_CACHE=""
APPSTORE_CACHE_VERSION=""
COMPAT_APPS=()
INCOMPAT_APPS=()
UNKNOWN_APPS=()
declare -A PHP_BIN_CACHE=()

# =============================================================================
# LOGGING
# =============================================================================

log() {
    local level="$1"
    local msg="$2"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local entry="[$ts] [$level] $msg"

    [[ -n "$LOG_FILE" ]] && echo "$entry" >> "$LOG_FILE"

    case "$level" in
        INFO)  echo -e "${GREEN}${entry}${RESET}" ;;
        WARN)  echo -e "${YELLOW}${entry}${RESET}" ;;
        ERROR) echo -e "${RED}${entry}${RESET}" >&2 ;;
        DEBUG) : ;;  # DEBUG nur in Log-Datei, nicht auf stdout
        *)     echo "$entry" ;;
    esac
}

log_debug() {
    [[ -n "$LOG_FILE" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $1" >> "$LOG_FILE"
}

sep() {
    echo -e "${BLUE}$(printf '─%.0s' {1..72})${RESET}"
}

print_header() {
    echo ""
    sep
    echo -e "${BOLD}${CYAN}  $1${RESET}"
    sep
}

# =============================================================================
# VORAUSSETZUNGEN
# =============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Fehler: Dieses Skript muss als root ausgeführt werden.${RESET}" >&2
        exit 1
    fi
}

check_dependencies() {
    local missing=()
    for cmd in curl jq rsync mysqldump; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${RED}Fehlende Pakete: ${missing[*]}${RESET}" >&2
        echo "Installation: apt-get install ${missing[*]}" >&2
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
            echo -e "${YELLOW}Warnung: Anderer Prozess läuft bereits (PID: $pid). Abbruch.${RESET}" >&2
            exit 0
        fi
        rm -f "$LOCK_FILE"
    fi
    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"' EXIT
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
        log "ERROR" "  Prüfen Sie: sudo -u $web_user bash -c 'command -v php'"
        log "ERROR" "  Oder: ls /usr/bin/php*"
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

# Allgemeiner PHP-Aufruf (für updater.phar etc.)
run_php() {
    local web_user="$1"
    shift
    local php_bin
    php_bin=$(find_php_bin "$web_user") || return 1
    sudo -u "$web_user" "$php_bin" "$@"
}

get_current_version() {
    local nc_dir="$1"
    local web_user="$2"
    # occ schreibt Warnzeilen auf stdout vor dem JSON (z.B. bei needsDbUpgrade).
    # grep -m 1 '^{' extrahiert nur die JSON-Zeile.
    # Das Feld heißt 'version', nicht 'installed_version'.
    run_occ "$nc_dir" "$web_user" status --output=json 2>/dev/null \
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
    # Kürzt auf 3 Teile: 28.0.12.3 → 28.0.12
    echo "$1" | cut -d. -f1-3
}

get_major() {
    echo "$1" | cut -d. -f1
}

get_latest_version() {
    local nc_dir="$1"
    local web_user="$2"
    # occ update:check baut intern die korrekte Update-Server-URL auf
    # (proprietäres Format mit x-Trennzeichen, Build-Timestamp, Commit-Hash).
    # Output-Beispiele:
    #   "Nextcloud 32.0.10 is available. Get more information..."
    #   "Nextcloud 32.0.8 is up to date"
    local output
    output=$(run_occ "$nc_dir" "$web_user" update:check 2>/dev/null) || output=""
    # Warnzeilen herausfiltern (z.B. bei needsDbUpgrade)
    output=$(echo "$output" | grep -v 'require upgrade' | grep -v 'use your browser')
    # Versionsnummer aus "X.Y.Z is available" extrahieren; leer wenn aktuell
    echo "$output" | grep -oP '[0-9]+\.[0-9]+\.[0-9]+(?= is available)' | head -1
}

# =============================================================================
# APP-KOMPATIBILITÄTSPRÜFUNG
# =============================================================================

# Core- und Bundled-Apps die MIT Nextcloud ausgeliefert werden.
# Diese sind nicht separat im App Store gelistet, aber immer kompatibel –
# sie werden mit der neuen NC-Version automatisch mitgeliefert.
# Core- und Bundled-Apps die MIT Nextcloud ausgeliefert werden und nicht separat
# im App Store gelistet sind. Nextcloud integriert regelmäßig ehemals externe Apps
# in das Serverpaket – diese Liste bei Bedarf erweitern.
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

    log "INFO" "Prüfe App-Kompatibilität mit Nextcloud v${target_major}..."

    # App-Store-Liste für Zielversion laden (mit Cache pro Major-Version)
    if [[ "$APPSTORE_CACHE_VERSION" != "$target_major" || -z "$APPSTORE_CACHE" ]]; then
        log_debug "Lade App-Liste für NC v${target_major} vom App Store..."
        APPSTORE_CACHE=$(curl -sf --max-time 60 \
            "${NC_APPSTORE_API}/platform/${target_major}.0.0/apps.json" 2>/dev/null) || APPSTORE_CACHE=""
        APPSTORE_CACHE_VERSION="$target_major"
        if [[ -z "$APPSTORE_CACHE" ]]; then
            log "WARN" "App Store API nicht erreichbar – alle Drittanbieter-Apps als 'unbekannt' markiert"
        else
            log_debug "App Store: $(echo "$APPSTORE_CACHE" | jq 'length' 2>/dev/null || echo '?') Apps für v${target_major} geladen"
        fi
    fi

    # Aktivierte Apps der Installation abrufen
    local installed_apps
    installed_apps=$(run_occ "$nc_dir" "$web_user" app:list --output=json 2>/dev/null \
        | jq -r '.enabled | keys[]' 2>/dev/null) || installed_apps=""

    if [[ -z "$installed_apps" ]]; then
        log "WARN" "Keine aktivierten Apps gefunden oder occ app:list fehlgeschlagen"
        return 0
    fi

    while IFS= read -r app; do
        [[ -z "$app" ]] && continue
        # Core-Apps überspringen – immer gebündelt
        is_core_app "$app" && { log_debug "Core-App übersprungen: $app"; continue; }

        if [[ -z "$APPSTORE_CACHE" ]]; then
            UNKNOWN_APPS+=("$app")
        elif echo "$APPSTORE_CACHE" | jq -e --arg a "$app" '.[] | select(.id == $a)' &>/dev/null; then
            COMPAT_APPS+=("$app")
        else
            # Nicht im App Store für Zielversion → UNKNOWN, nicht INCOMPAT.
            # Drittanbieter-Apps die nicht gelistet sind könnten deprecated oder
            # noch nicht für die neue Version freigegeben sein.
            UNKNOWN_APPS+=("$app")
        fi
    done <<< "$installed_apps"

    log_debug "Kompatibel: ${#COMPAT_APPS[@]} | Unbekannt/nicht gelistet: ${#UNKNOWN_APPS[@]}"
}

# =============================================================================
# BACKUP
# =============================================================================

get_config_value() {
    local nc_dir="$1"
    local key="$2"
    # PHP liest direkt aus config.php – sicherer als grep/sed
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
    log "INFO" "Datei-Backup läuft (ohne data/)..."
    if rsync -a --delete \
            --exclude="data/" \
            --exclude="updater-*/backups/" \
            "$nc_dir/" "$backup_dir/files/" >> "$LOG_FILE" 2>&1; then
        log "INFO" "Datei-Backup OK"
    else
        log "WARN" "Datei-Backup mit Warnungen abgeschlossen"
    fi

    # Datenbank-Backup
    local db_type
    db_type=$(get_config_value "$nc_dir" "dbtype")

    if [[ "$db_type" == "mysql" || "$db_type" == "pgsql" ]]; then
        local db_name db_user db_pass db_host
        db_name=$(get_config_value "$nc_dir" "dbname")
        db_user=$(get_config_value "$nc_dir" "dbuser")
        db_pass=$(get_config_value "$nc_dir" "dbpassword")
        db_host=$(get_config_value "$nc_dir" "dbhost")
        db_host="${db_host%%:*}"  # Port-Suffix entfernen (z.B. "localhost:3306")
        [[ -z "$db_host" ]] && db_host="localhost"

        log "INFO" "Datenbank-Backup: $db_name @ $db_host"
        if mysqldump -h "$db_host" -u "$db_user" -p"$db_pass" \
                --single-transaction --routines --triggers \
                "$db_name" > "$backup_dir/database.sql" 2>> "$LOG_FILE"; then
            log "INFO" "Datenbank-Backup OK: $backup_dir/database.sql"
        else
            log "WARN" "Datenbank-Backup fehlgeschlagen – Upgrade fortgesetzt, aber Rollback eingeschränkt!"
        fi
    else
        log "WARN" "Datenbank-Typ '$db_type': kein automatisches Backup möglich (nur MySQL/MariaDB)"
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

    if $DRY_RUN; then
        log "INFO" "[DRY-RUN] Würde Update durchführen für: $nc_dir"
        log "INFO" "[DRY-RUN] Schritte: maintenance:mode --on → updater.phar → occ upgrade → app:update --all → maintenance:repair → maintenance:mode --off"
        return 0
    fi

    # Maintenance Mode bei Fehler sicher deaktivieren
    _maintenance_off() {
        log "WARN" "Deaktiviere Maintenance Mode nach Fehler..."
        run_occ "$nc_dir" "$web_user" maintenance:mode --off >> "$LOG_FILE" 2>&1 || true
    }

    # 1. Überbleibsel prüfen: .bak-Dateien die root gehören blockieren updater.phar
    #    (entsteht wenn ein vorheriger Update-Lauf als root statt als web-user lief)
    local stale_bak_files
    stale_bak_files=$(find "$nc_dir" -name "*.bak" -not -user "$web_user" 2>/dev/null)
    if [[ -n "$stale_bak_files" ]]; then
        log "WARN" "Falsch gesetzte .bak-Dateien gefunden (blockieren updater.phar):"
        while IFS= read -r f; do
            log "WARN" "  $f ($(stat -c '%U:%G' "$f"))"
            chown "${web_user}:" "$f" && log "INFO" "  → Eigentümer korrigiert: $f" \
                                      || log "ERROR" "  → chown fehlgeschlagen: $f"
        done <<< "$stale_bak_files"
    fi

    # 2. Maintenance Mode aktivieren
    log "INFO" "Maintenance Mode: AN"
    if ! run_occ "$nc_dir" "$web_user" maintenance:mode --on >> "$LOG_FILE" 2>&1; then
        log "ERROR" "Fehler beim Aktivieren des Maintenance Modes"
        return 1
    fi

    # 3. Nextcloud Updater ausführen (lädt neue Dateien herunter)
    if [[ -f "$updater_phar" ]]; then
        log "INFO" "Führe Nextcloud Updater (updater.phar) aus..."
        run_php "$web_user" "$updater_phar" --no-interaction >> "$LOG_FILE" 2>&1
        local upd_rc=$?
        # RC 0 = Update durchgeführt, RC 1 = kein Update verfügbar – beides OK
        if [[ $upd_rc -gt 1 ]]; then
            log "ERROR" "updater.phar fehlgeschlagen (Exit-Code: $upd_rc)"
            _maintenance_off
            return 1
        fi
        log "INFO" "updater.phar abgeschlossen (Exit-Code: $upd_rc)"
    else
        log "WARN" "updater.phar nicht gefunden unter: $updater_phar"
        log "WARN" "Dateien-Update übersprungen – nur Datenbankmigrationen werden durchgeführt"
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
    log "INFO" "App-Updates (occ app:update --all)..."
    run_occ "$nc_dir" "$web_user" app:update --all >> "$LOG_FILE" 2>&1 \
        || log "WARN" "App-Update mit Warnungen – bitte Log prüfen"

    # 5. Reparatur-Routine
    log "INFO" "Reparatur-Routine (occ maintenance:repair)..."
    run_occ "$nc_dir" "$web_user" maintenance:repair >> "$LOG_FILE" 2>&1 \
        || log "WARN" "Repair mit Warnungen"

    # 6. Maintenance Mode deaktivieren
    log "INFO" "Maintenance Mode: AUS"
    if ! run_occ "$nc_dir" "$web_user" maintenance:mode --off >> "$LOG_FILE" 2>&1; then
        log "WARN" "Maintenance Mode konnte nicht automatisch deaktiviert werden!"
        log "WARN" "Manuell ausführen: sudo -u $web_user php $nc_dir/occ maintenance:mode --off"
    fi

    log "INFO" "Update/Upgrade-Ablauf abgeschlossen"
    return 0
}

# =============================================================================
# INSTALLATIONS-VERARBEITUNG
# =============================================================================

process_installation() {
    local nc_dir="$1"
    local web_user
    web_user=$(get_web_user "$nc_dir")
    LOG_FILE="${LOG_DIR}/${web_user}.log"

    print_header "Installation: $nc_dir"
    log "INFO" "=== Wartungsbeginn: $nc_dir | User: $web_user ==="

    # Aktuelle Version ermitteln
    local current_version
    current_version=$(get_current_version "$nc_dir" "$web_user")
    if [[ -z "$current_version" ]]; then
        log "ERROR" "Kann aktuelle Version nicht ermitteln – Installation wird übersprungen"
        log "ERROR" "  Mögliche Ursachen: PHP nicht verfügbar, occ nicht ausführbar, NC nicht vollständig installiert"
        return 1
    fi
    log "INFO" "Installierte Version: $current_version"

    # Auf ausstehende Datenbank-Migration prüfen.
    # Tritt auf wenn updater.phar die Dateien bereits aktualisiert hat,
    # aber occ upgrade noch nicht ausgeführt wurde (z.B. nach Absturz oder manuellem Update).
    local needs_db_upgrade
    needs_db_upgrade=$(run_occ "$nc_dir" "$web_user" status --output=json 2>/dev/null \
        | grep -m 1 '^{' | jq -r '.needsDbUpgrade // false' 2>/dev/null) || needs_db_upgrade="false"

    if [[ "$needs_db_upgrade" == "true" ]]; then
        log "WARN" "Ausstehende Datenbankmigrationen erkannt (updater.phar lief bereits, occ upgrade fehlt noch)"
        echo -e "\n${YELLOW}  ⚠  Ausstehende DB-Migration erkannt – Installation v${current_version} ist im Wartungsmodus${RESET}"

        if $DRY_RUN; then
            log "INFO" "[DRY-RUN] Würde DB-Migration abschließen: occ upgrade → app:update --all → maintenance:repair → maintenance:mode --off"
            echo -e "${CYAN}  [DRY-RUN] Würde ausstehende Migration abschließen${RESET}"
        else
            echo -e "${CYAN}  Schließe Migration ab...${RESET}"
            if run_occ "$nc_dir" "$web_user" upgrade >> "$LOG_FILE" 2>&1; then
                run_occ "$nc_dir" "$web_user" app:update --all >> "$LOG_FILE" 2>&1 \
                    || log "WARN" "App-Update mit Warnungen"
                run_occ "$nc_dir" "$web_user" maintenance:repair >> "$LOG_FILE" 2>&1 \
                    || log "WARN" "Repair mit Warnungen"
                run_occ "$nc_dir" "$web_user" maintenance:mode --off >> "$LOG_FILE" 2>&1 \
                    || log "WARN" "Maintenance Mode konnte nicht deaktiviert werden"
                current_version=$(get_current_version "$nc_dir" "$web_user")
                log "INFO" "DB-Migration abgeschlossen. Aktuelle Version: ${current_version:-unbekannt}"
                echo -e "${GREEN}  ✓ Migration abgeschlossen. Aktuelle Version: ${current_version:-unbekannt}${RESET}"
            else
                log "ERROR" "occ upgrade fehlgeschlagen – Installation übersprungen"
                run_occ "$nc_dir" "$web_user" maintenance:mode --off >> "$LOG_FILE" 2>&1 || true
                echo -e "${RED}  ✗ Migration fehlgeschlagen – Log: $LOG_FILE${RESET}"
                return 1
            fi
        fi
    fi

    # PHP-Version des Web-Users ermitteln
    local php_version
    php_version=$(get_php_version_string "$web_user")
    log "INFO" "PHP-Version (Web-User): $php_version"

    # Auf Updates prüfen (occ update:check baut die korrekte Update-Server-URL intern auf)
    log "INFO" "Prüfe auf Updates (occ update:check)..."
    local latest_version
    latest_version=$(get_latest_version "$nc_dir" "$web_user")

    if [[ -z "$latest_version" ]]; then
        log "INFO" "Keine Update-Informationen erhalten (Nextcloud aktuell oder Update-Server nicht erreichbar)"
        log "INFO" "=== Wartungsende: $nc_dir ==="
        return 0
    fi

    log "INFO" "Verfügbare Version laut Update-Server: $latest_version"

    # Versionen normalisieren und vergleichen
    local current_norm latest_norm
    current_norm=$(normalize_version "$current_version")
    latest_norm=$(normalize_version "$latest_version")

    if [[ "$current_norm" == "$latest_norm" ]]; then
        log "INFO" "Nextcloud ist auf dem neuesten Stand (v${current_version})"
        log "INFO" "=== Wartungsende: $nc_dir ==="
        return 0
    fi

    local current_major latest_major
    current_major=$(get_major "$current_version")
    latest_major=$(get_major "$latest_version")

    # -------------------------------------------------------------------------
    # MINOR-UPDATE (gleiche Hauptversion)
    # -------------------------------------------------------------------------
    if [[ "$current_major" == "$latest_major" ]]; then
        log "INFO" "Minor-Update verfügbar: v${current_version} → v${latest_version}"
        echo -e "\n${GREEN}  Minor-Update wird automatisch durchgeführt:${RESET}"
        echo -e "  ${RED}v${current_version}${RESET} → ${GREEN}v${latest_version}${RESET}\n"

        if run_update "$nc_dir" "$web_user"; then
            if ! $DRY_RUN; then
                local new_version
                new_version=$(get_current_version "$nc_dir" "$web_user")
                log "INFO" "Minor-Update abgeschlossen. Neue Version: ${new_version:-unbekannt}"
                echo -e "${GREEN}  ✓ Update erfolgreich. Installierte Version: ${new_version:-unbekannt}${RESET}"
            fi
        else
            log "ERROR" "Minor-Update fehlgeschlagen"
            echo -e "${RED}  ✗ Update fehlgeschlagen – Log: $LOG_FILE${RESET}"
            log "INFO" "=== Wartungsende (FEHLER): $nc_dir ==="
            return 1
        fi

    # -------------------------------------------------------------------------
    # MAJOR-UPGRADE (neue Hauptversion)
    # -------------------------------------------------------------------------
    else
        log "INFO" "Major-Upgrade verfügbar: v${current_major} → v${latest_major} (v${current_version} → v${latest_version})"

        # App-Kompatibilität prüfen
        check_app_compatibility "$nc_dir" "$web_user" "$latest_major"

        # Kompatibilitätsergebnis loggen
        log "INFO" "App-Kompatibilitätsprüfung abgeschlossen:"
        [[ ${#COMPAT_APPS[@]} -gt 0 ]]  && log "INFO" "  Im App Store für v${latest_major} (${#COMPAT_APPS[@]}): ${COMPAT_APPS[*]}"
        [[ ${#UNKNOWN_APPS[@]} -gt 0 ]] && log "WARN" "  Nicht im App Store für v${latest_major} (${#UNKNOWN_APPS[@]}): ${UNKNOWN_APPS[*]}"

        # Anzeige für Administrator
        echo ""
        sep
        echo -e "${BOLD}${YELLOW}  ⚠  Nextcloud Major-Upgrade verfügbar${RESET}"
        sep
        echo ""
        printf "  %-22s %s\n" "Installation:" "$nc_dir"
        printf "  %-22s %s\n" "Web-User:" "$web_user"
        printf "  %-22s ${RED}v%s${RESET}\n" "Aktuell installiert:" "$current_version"
        printf "  %-22s ${GREEN}v%s${RESET}\n" "Verfügbare Version:" "$latest_version"
        echo ""
        echo -e "  ${BOLD}App-Kompatibilität mit Nextcloud v${latest_major}:${RESET}"
        echo ""

        if [[ ${#COMPAT_APPS[@]} -gt 0 ]]; then
            echo -e "  ${GREEN}Im App Store für v${latest_major} verfügbar:${RESET}"
            for app in "${COMPAT_APPS[@]}"; do
                printf "    ${GREEN}✓${RESET}  %s\n" "$app"
            done
            echo ""
        fi

        if [[ ${#UNKNOWN_APPS[@]} -gt 0 ]]; then
            echo -e "  ${YELLOW}Nicht im App Store für v${latest_major} gelistet – bitte vor dem Upgrade prüfen:${RESET}"
            echo -e "  ${YELLOW}(Kann bedeuten: noch nicht freigegeben, deprecated oder proprietär)${RESET}"
            for app in "${UNKNOWN_APPS[@]}"; do
                printf "    ${YELLOW}?${RESET}  %s\n" "$app"
            done
            echo ""
        fi

        if [[ ${#COMPAT_APPS[@]} -eq 0 && ${#UNKNOWN_APPS[@]} -eq 0 ]]; then
            echo -e "  ${YELLOW}Keine Drittanbieter-Apps aktiv – Upgrade kann problemlos erfolgen.${RESET}\n"
        fi

        if [[ ${#UNKNOWN_APPS[@]} -gt 0 ]]; then
            echo -e "  ${YELLOW}⚠  ${#UNKNOWN_APPS[@]} App(s) sind im App Store für v${latest_major} nicht gelistet.${RESET}"
            echo -e "  ${YELLOW}Bitte prüfen Sie auf https://apps.nextcloud.com ob eine kompatible Version verfügbar ist.${RESET}\n"
        fi

        if $DRY_RUN; then
            log "INFO" "[DRY-RUN] Major-Upgrade würde jetzt interaktiv abgefragt werden"
            echo -e "${CYAN}  [DRY-RUN] Im echten Lauf würde jetzt nach Bestätigung gefragt.${RESET}"
            log "INFO" "=== Wartungsende (DRY-RUN): $nc_dir ==="
            return 0
        fi

        # Administrator um Bestätigung bitten.
        # WICHTIG: </dev/tty erzwingt Lesen vom Terminal, nicht von der
        # find_installations-Pipe, die als stdin des while-Loops aktiv ist.
        sep
        echo -e "  ${BOLD}Soll das Upgrade auf v${latest_version} jetzt durchgeführt werden?${RESET}"
        echo -n "  [y/Y/j/J = Ja  |  andere Eingabe = Nein und überspringen]: " >/dev/tty
        local answer
        read -r answer </dev/tty
        echo ""

        if [[ "${answer:-}" =~ ^[yYjJ]$ ]]; then
            log "INFO" "Administrator hat Upgrade bestätigt (Eingabe: '$answer')"

            # Backup erstellen
            log "INFO" "Erstelle Backup vor Major-Upgrade..."
            local backup_dir
            backup_dir=$(perform_backup "$nc_dir" "$web_user" "$current_version")
            echo -e "${CYAN}  Backup erstellt: $backup_dir${RESET}\n"

            # Upgrade durchführen
            echo -e "${CYAN}  Führe Upgrade durch – bitte warten...${RESET}"
            if run_update "$nc_dir" "$web_user"; then
                local new_version
                new_version=$(get_current_version "$nc_dir" "$web_user")
                log "INFO" "Major-Upgrade abgeschlossen. Neue Version: ${new_version:-unbekannt}"
                echo -e "\n${GREEN}  ✓ Major-Upgrade erfolgreich!${RESET}"
                echo -e "  ${GREEN}Installierte Version: ${new_version:-unbekannt}${RESET}"
                [[ ${#INCOMPAT_APPS[@]} -gt 0 ]] && \
                    echo -e "  ${YELLOW}Hinweis: Inkompatible Apps wurden deaktiviert: ${INCOMPAT_APPS[*]}${RESET}"
            else
                log "ERROR" "Major-Upgrade fehlgeschlagen"
                echo -e "${RED}  ✗ Upgrade fehlgeschlagen – Log: $LOG_FILE${RESET}"
                echo -e "${YELLOW}  Backup verfügbar unter: $backup_dir${RESET}"
                log "INFO" "=== Wartungsende (FEHLER): $nc_dir ==="
                return 1
            fi
        else
            log "INFO" "Administrator hat Upgrade abgelehnt (Eingabe: '${answer:-leer}') – übersprungen"
            echo -e "${YELLOW}  Upgrade übersprungen. Nextcloud läuft weiterhin mit v${current_version}.${RESET}"
        fi
    fi

    log "INFO" "=== Wartungsende: $nc_dir ==="
    return 0
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    check_root
    check_dependencies
    setup_dirs
    acquire_lock

    print_header "Nextcloud Update Manager – Manuelle Ausführung"
    echo -e "  Zeitpunkt:   $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "  Suchpfad:    $NC_SEARCH_BASE"
    echo -e "  Log-Verz.:   $LOG_DIR"
    $DRY_RUN && echo -e "  ${YELLOW}${BOLD}MODUS: DRY-RUN – keine Änderungen werden vorgenommen${RESET}"
    echo ""

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

    if [[ $found -eq 0 ]]; then
        echo -e "${YELLOW}Keine Nextcloud-Installationen gefunden unter: $NC_SEARCH_BASE${RESET}"
    fi

    echo ""
    sep
    echo -e "${BOLD}  Zusammenfassung:${RESET}"
    printf "  %-34s %d\n" "Installationen gefunden:" "$found"
    printf "  %-34s %d\n" "Erfolgreich verarbeitet:" "$ok"
    printf "  %-34s %d\n" "Fehler/Übersprungen:" "$failed"
    printf "  %-34s %s\n" "Log-Verzeichnis:" "$LOG_DIR"
    sep
    echo ""
}

main "$@"
