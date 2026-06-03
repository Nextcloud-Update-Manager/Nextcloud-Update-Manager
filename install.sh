#!/bin/bash
# =============================================================================
# install.sh – Nextcloud Update Manager: Installations- und Update-Skript
#
# Verwendung:
#   sudo ./install.sh          # Erstinstallation ODER Update (automatisch erkannt)
#   sudo ./install.sh --full   # Vollständige Neuinstallation inkl. SMTP + Cronjob
#
# Update-Modus (automatisch wenn Skripte + smtp.conf bereits vorhanden):
#   - Skripte werden aktualisiert (alte Version als .bak gesichert)
#   - SMTP-Konfiguration bleibt unverändert
#   - Cronjob bleibt unverändert
# =============================================================================

set -uo pipefail

# =============================================================================
# KONSTANTEN
# =============================================================================

INSTALL_DIR="/usr/local/sbin"
CONFIG_DIR="/etc/nextcloud-update"
SMTP_CONF="${CONFIG_DIR}/smtp.conf"
LOG_DIR="/var/log/Nextcloud-Update"
BACKUP_BASE="/var/backups/nextcloud"
CRON_FILE="/etc/cron.d/nextcloud-update"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts"
MANUAL_SCRIPT="${SCRIPT_DIR}/nextcloud-update-manual.sh"
CRON_SCRIPT="${SCRIPT_DIR}/nextcloud-update-cron.sh"

# Update-Modus: automatisch wenn Skripte + SMTP-Config bereits vorhanden.
# --full erzwingt immer die vollständige Konfiguration.
UPDATE_MODE=false
if [[ "${1:-}" != "--full" ]] && \
   [[ -f "${INSTALL_DIR}/nextcloud-update-manual.sh" ]] && \
   [[ -f "${INSTALL_DIR}/nextcloud-update-cron.sh" ]] && \
   [[ -f "${SMTP_CONF}" ]]; then
    UPDATE_MODE=true
fi

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
# HILFSFUNKTIONEN
# =============================================================================

ok()   { echo -e "  ${GREEN}✓${RESET}  $1"; }
warn() { echo -e "  ${YELLOW}⚠${RESET}  $1"; }
err()  { echo -e "  ${RED}✗${RESET}  $1" >&2; }
info() { echo -e "  ${CYAN}→${RESET}  $1"; }

sep() {
    echo -e "${BLUE}$(printf '─%.0s' {1..70})${RESET}"
}

print_header() {
    echo ""
    sep
    echo -e "${BOLD}${CYAN}  $1${RESET}"
    sep
}

abort() {
    err "$1"
    echo ""
    exit 1
}

# =============================================================================
# SCHRITT 1: VORAUSSETZUNGEN
# =============================================================================

check_root() {
    print_header "Schritt 1/5: Voraussetzungen prüfen"
    if [[ $EUID -ne 0 ]]; then
        abort "Dieses Skript muss als root ausgeführt werden."
    fi
    ok "Ausführung als root"
}

check_source_files() {
    local missing=false
    for f in "$MANUAL_SCRIPT" "$CRON_SCRIPT"; do
        if [[ ! -f "$f" ]]; then
            err "Quelldatei nicht gefunden: $f"
            missing=true
        fi
    done
    if $missing; then
        abort "Bitte stellen Sie sicher, dass Sie im Hauptverzeichnis des Repositories arbeiten."
    fi
    ok "Quelldateien vorhanden (scripts/)"
}

detect_package_manager() {
    if command -v apt-get &>/dev/null; then
        PKG_MANAGER="apt-get"
        PKG_INSTALL="apt-get install -y"
        PKG_UPDATE="apt-get update -qq"
    elif command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"
        PKG_INSTALL="dnf install -y"
        PKG_UPDATE=":"
    elif command -v yum &>/dev/null; then
        PKG_MANAGER="yum"
        PKG_INSTALL="yum install -y"
        PKG_UPDATE=":"
    else
        abort "Kein unterstützter Paketmanager gefunden (apt-get, dnf, yum)."
    fi
    ok "Paketmanager: $PKG_MANAGER"
}

# =============================================================================
# SCHRITT 2: ABHÄNGIGKEITEN
# =============================================================================

# Paketname je Distribution
pkg_name_for() {
    local cmd="$1"
    case "$cmd" in
        jq)       echo "jq" ;;
        rsync)    echo "rsync" ;;
        mysqldump)
            case "$PKG_MANAGER" in
                apt-get) echo "default-mysql-client" ;;
                dnf|yum) echo "mariadb" ;;
            esac
            ;;
        curl)     echo "curl" ;;
        *)        echo "$cmd" ;;
    esac
}

install_dependencies() {
    print_header "Schritt 2/5: Abhängigkeiten prüfen und installieren"

    local missing_pkgs=()
    local missing_cmds=()

    for cmd in curl jq rsync mysqldump; do
        if command -v "$cmd" &>/dev/null; then
            ok "$cmd ist installiert ($(command -v "$cmd"))"
        else
            warn "$cmd fehlt – wird installiert"
            missing_cmds+=("$cmd")
            missing_pkgs+=("$(pkg_name_for "$cmd")")
        fi
    done

    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        echo ""
        info "Aktualisiere Paketliste..."
        $PKG_UPDATE > /dev/null 2>&1 || warn "Paketliste konnte nicht aktualisiert werden"

        info "Installiere: ${missing_pkgs[*]}"
        if $PKG_INSTALL "${missing_pkgs[@]}" > /dev/null 2>&1; then
            for cmd in "${missing_cmds[@]}"; do
                if command -v "$cmd" &>/dev/null; then
                    ok "$cmd erfolgreich installiert"
                else
                    abort "Installation von '$cmd' fehlgeschlagen. Bitte manuell installieren."
                fi
            done
        else
            abort "Paketinstallation fehlgeschlagen. Bitte manuell installieren: ${missing_pkgs[*]}"
        fi
    else
        ok "Alle Abhängigkeiten vorhanden"
    fi
}

# =============================================================================
# SCHRITT 3: SKRIPTE INSTALLIEREN
# =============================================================================

install_scripts() {
    print_header "Schritt 3/5: Skripte installieren"

    # Verzeichnisse anlegen
    for dir in "$LOG_DIR" "$BACKUP_BASE"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            chmod 750 "$dir"
            ok "Verzeichnis erstellt: $dir"
        else
            ok "Verzeichnis vorhanden: $dir"
        fi
    done

    # nextcloud-update-manual.sh
    local target_manual="${INSTALL_DIR}/nextcloud-update-manual.sh"
    if [[ -f "$target_manual" ]]; then
        cp "$target_manual" "${target_manual}.bak.$(date +%Y%m%d)" && \
            info "Backup der alten Version: ${target_manual}.bak.$(date +%Y%m%d)"
    fi
    cp "$MANUAL_SCRIPT" "$target_manual"
    chmod 700 "$target_manual"
    chown root:root "$target_manual"
    ok "Installiert: $target_manual (chmod 700)"

    # nextcloud-update-cron.sh
    local target_cron="${INSTALL_DIR}/nextcloud-update-cron.sh"
    if [[ -f "$target_cron" ]]; then
        cp "$target_cron" "${target_cron}.bak.$(date +%Y%m%d)"
    fi
    cp "$CRON_SCRIPT" "$target_cron"
    chmod 700 "$target_cron"
    chown root:root "$target_cron"
    ok "Installiert: $target_cron (chmod 700)"
}

# =============================================================================
# SCHRITT 4: SMTP-KONFIGURATION
# =============================================================================

ask() {
    # Prompt mit optionalem Default-Wert
    local prompt="$1"
    local default="${2:-}"
    local value

    if [[ -n "$default" ]]; then
        read -rp "  $prompt [${default}]: " value
        echo "${value:-$default}"
    else
        while true; do
            read -rp "  $prompt: " value
            [[ -n "$value" ]] && break
            echo -e "  ${RED}Eingabe darf nicht leer sein.${RESET}" >&2
        done
        echo "$value"
    fi
}

ask_password() {
    local prompt="$1"
    local value
    while true; do
        read -rsp "  $prompt: " value
        echo "" >&2
        [[ -n "$value" ]] && break
        echo -e "  ${RED}Passwort darf nicht leer sein.${RESET}" >&2
    done
    echo "$value"
}

ask_email() {
    local prompt="$1"
    local default="${2:-}"
    local value
    while true; do
        if [[ -n "$default" ]]; then
            read -rp "  $prompt [${default}]: " value
            value="${value:-$default}"
        else
            read -rp "  $prompt: " value
        fi
        # Einfache E-Mail-Validierung
        if echo "$value" | grep -qE '^[^@]+@[^@]+\.[^@]+$'; then
            break
        else
            echo -e "  ${RED}Ungültige E-Mail-Adresse.${RESET}" >&2
        fi
    done
    echo "$value"
}

ask_port() {
    local prompt="$1"
    local default="${2:-465}"
    local value
    while true; do
        read -rp "  $prompt [${default}]: " value
        value="${value:-$default}"
        if echo "$value" | grep -qE '^[0-9]+$' && [[ "$value" -ge 1 && "$value" -le 65535 ]]; then
            break
        else
            echo -e "  ${RED}Bitte eine gültige Portnummer (1-65535) eingeben.${RESET}" >&2
        fi
    done
    echo "$value"
}

load_existing_smtp() {
    # Bestehende Werte laden, wenn Datei vorhanden
    if [[ -f "$SMTP_CONF" ]]; then
        while IFS='=' read -r key value; do
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${key// }" ]] && continue
            key="${key// /}"
            value="${value// /}"
            case "$key" in
                SMTP_HOST|SMTP_PORT|SMTP_USER|SMTP_PASS|SMTP_FROM|MAIL_TO)
                    declare -g "EXISTING_${key}=${value}"
                    ;;
            esac
        done < "$SMTP_CONF"
    fi
}

setup_smtp_config() {
    print_header "Schritt 4/5: SMTP-Konfiguration"

    mkdir -p "$CONFIG_DIR"
    chmod 750 "$CONFIG_DIR"

    # Im Update-Modus bestehende Konfiguration unverändert lassen
    if $UPDATE_MODE; then
        ok "SMTP-Konfiguration unverändert übernommen: $SMTP_CONF"
        info "Zum Ändern der Konfiguration: sudo ./install.sh --full"
        return 0
    fi

    if [[ -f "$SMTP_CONF" ]]; then
        warn "Bestehende SMTP-Konfiguration gefunden: $SMTP_CONF"
        info "Bestehende Werte werden als Vorschlag angezeigt."
        load_existing_smtp
        echo ""
    fi

    echo -e "  ${BOLD}Bitte SMTP-Zugangsdaten eingeben:${RESET}"
    echo -e "  ${CYAN}(Enter drücken um vorgeschlagenen Wert zu übernehmen)${RESET}"
    echo ""

    local smtp_host smtp_port smtp_user smtp_pass smtp_from mail_to

    smtp_host=$(ask "SMTP-Server (z.B. mail.example.com)" "${EXISTING_SMTP_HOST:-}")
    smtp_port=$(ask_port "SMTP-Port (SMTPS)" "${EXISTING_SMTP_PORT:-465}")
    smtp_user=$(ask "SMTP-Benutzername" "${EXISTING_SMTP_USER:-}")
    smtp_pass=$(ask_password "SMTP-Passwort")
    smtp_from=$(ask_email "Absender-E-Mail-Adresse" "${EXISTING_SMTP_FROM:-$smtp_user}")
    mail_to=$(ask_email "Empfänger-E-Mail-Adresse" "${EXISTING_MAIL_TO:-admin@example.com}")

    # Backup der alten Konfiguration
    if [[ -f "$SMTP_CONF" ]]; then
        cp "$SMTP_CONF" "${SMTP_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
        info "Backup der alten Konfiguration erstellt"
    fi

    # Konfigurationsdatei schreiben
    cat > "$SMTP_CONF" << EOF
# =============================================================================
# SMTP-Konfiguration – Nextcloud Update Manager
# Erstellt: $(date '+%Y-%m-%d %H:%M:%S')
# Berechtigungen: chmod 600, chown root:root
# =============================================================================

SMTP_HOST=${smtp_host}
SMTP_PORT=${smtp_port}
SMTP_USER=${smtp_user}
SMTP_PASS=${smtp_pass}
SMTP_FROM=${smtp_from}
MAIL_TO=${mail_to}
EOF

    chmod 600 "$SMTP_CONF"
    chown root:root "$SMTP_CONF"
    ok "SMTP-Konfiguration gespeichert: $SMTP_CONF (chmod 600)"

    # Verbindungstest anbieten
    echo ""
    read -rp "  SMTP-Verbindung jetzt testen? [y/N]: " test_smtp
    if [[ "${test_smtp:-}" =~ ^[yYjJ]$ ]]; then
        info "Teste SMTP-Verbindung zu ${smtp_host}:${smtp_port}..."
        local test_body
        test_body=$(printf "From: Nextcloud Updater <%s>\r\nTo: %s\r\nSubject: [Test] Nextcloud Update Manager\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nDies ist eine Test-E-Mail vom Nextcloud Update Manager.\r\nInstalliert auf: %s\r\nZeitpunkt: %s\r\n" \
            "$smtp_from" "$mail_to" "$(hostname -f 2>/dev/null)" "$(date '+%Y-%m-%d %H:%M:%S')")

        if curl -sf \
                --url "smtps://${smtp_host}:${smtp_port}" \
                --ssl-reqd \
                --mail-from "$smtp_from" \
                --mail-rcpt "$mail_to" \
                --user "${smtp_user}:${smtp_pass}" \
                --upload-file <(printf '%s' "$test_body") \
                2>/dev/null; then
            ok "Test-E-Mail erfolgreich gesendet an: $mail_to"
        else
            warn "Test-E-Mail fehlgeschlagen. Bitte Zugangsdaten und Server prüfen."
            info "Manuelle Prüfung: curl -v --url smtps://${smtp_host}:${smtp_port} --ssl-reqd ..."
        fi
    fi
}

# =============================================================================
# SCHRITT 5: CRONJOB EINRICHTEN
# =============================================================================

setup_cronjob() {
    print_header "Schritt 5/5: Cronjob einrichten"

    # Im Update-Modus bestehenden Cronjob unverändert lassen
    if $UPDATE_MODE; then
        if [[ -f "$CRON_FILE" ]]; then
            local current_schedule
            current_schedule=$(grep -v '^#' "$CRON_FILE" | grep -v '^$' | grep -v '^[A-Z_]' \
                               | awk '{print $1,$2,$3,$4,$5}' | head -1)
            ok "Cronjob unverändert übernommen: $CRON_FILE"
            info "Aktueller Zeitplan: ${current_schedule:-unbekannt}"
        else
            warn "Kein Cronjob gefunden – wird übersprungen"
            info "Zum Einrichten: sudo ./install.sh --full"
        fi
        return 0
    fi

    echo -e "  Empfehlung: Wöchentlicher Lauf (z.B. Sonntag 03:00 Uhr)\n"

    read -rp "  Cronjob jetzt einrichten? [Y/n]: " setup_cron
    if [[ "${setup_cron:-y}" =~ ^[nN]$ ]]; then
        info "Cronjob übersprungen."
        info "Manuell einrichten: echo '0 3 * * 0 root ${INSTALL_DIR}/nextcloud-update-cron.sh' > $CRON_FILE"
        return 0
    fi

    echo ""
    echo -e "  ${BOLD}Cronjob-Zeitplan (cron-Format):${RESET}"
    echo -e "  Beispiele:"
    echo -e "    Täglich 03:00:         0 3 * * *"
    echo -e "    Sonntags 03:00:        0 3 * * 0"
    echo -e "    Mo+Do 02:30:           30 2 * * 1,4"
    echo ""

    local cron_schedule
    cron_schedule=$(ask "Cron-Zeitplan" "0 3 * * 0")

    # Cronjob-Datei schreiben
    cat > "$CRON_FILE" << EOF
# Nextcloud Update Manager – automatischer Cronjob
# Erstellt: $(date '+%Y-%m-%d %H:%M:%S')
# Manuell ausführen: ${INSTALL_DIR}/nextcloud-update-manual.sh
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

${cron_schedule} root ${INSTALL_DIR}/nextcloud-update-cron.sh
EOF

    chmod 644 "$CRON_FILE"
    ok "Cronjob erstellt: $CRON_FILE"
    info "Zeitplan: $cron_schedule"
}

# =============================================================================
# ZUSAMMENFASSUNG
# =============================================================================

print_summary() {
    echo ""
    sep
    if $UPDATE_MODE; then
        echo -e "${BOLD}${GREEN}  Aktualisierung abgeschlossen!${RESET}"
    else
        echo -e "${BOLD}${GREEN}  Installation abgeschlossen!${RESET}"
    fi
    sep
    echo ""
    echo -e "  ${BOLD}Installierte Dateien:${RESET}"
    printf "  %-12s %s\n" "Manuell:"  "${INSTALL_DIR}/nextcloud-update-manual.sh"
    printf "  %-12s %s\n" "Cronjob:"  "${INSTALL_DIR}/nextcloud-update-cron.sh"
    printf "  %-12s %s\n" "SMTP:"     "${SMTP_CONF}"
    [[ -f "$CRON_FILE" ]] && printf "  %-12s %s\n" "Crontab:" "$CRON_FILE"
    printf "  %-12s %s\n" "Logs:"     "${LOG_DIR}/"
    printf "  %-12s %s\n" "Backups:"  "${BACKUP_BASE}/"
    echo ""
    echo -e "  ${BOLD}Nächste Schritte:${RESET}"
    echo ""
    echo -e "  1. Testlauf (ohne Änderungen):"
    echo -e "     ${CYAN}${INSTALL_DIR}/nextcloud-update-manual.sh --dry-run${RESET}"
    echo ""
    echo -e "  2. Manuelles Update starten:"
    echo -e "     ${CYAN}${INSTALL_DIR}/nextcloud-update-manual.sh${RESET}"
    echo ""
    echo -e "  3. Logs beobachten:"
    echo -e "     ${CYAN}ls -la ${LOG_DIR}/${RESET}"
    echo ""
    sep
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================

echo ""
sep
if $UPDATE_MODE; then
    echo -e "${BOLD}${CYAN}  Nextcloud Update Manager – Aktualisierung${RESET}"
    echo -e "  $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "  ${YELLOW}Update-Modus: SMTP und Cronjob bleiben unverändert${RESET}"
    echo -e "  ${CYAN}Vollständige Neukonfiguration: sudo ./install.sh --full${RESET}"
else
    echo -e "${BOLD}${CYAN}  Nextcloud Update Manager – Installation${RESET}"
    echo -e "  $(date '+%Y-%m-%d %H:%M:%S')"
fi
sep

check_root
check_source_files
detect_package_manager
install_dependencies
install_scripts
setup_smtp_config
setup_cronjob
print_summary
