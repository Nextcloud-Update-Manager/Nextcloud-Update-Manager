# Nextcloud Update Manager – Dokumentation

## Inhaltsverzeichnis

1. [Überblick](#1-überblick)
2. [Systemvoraussetzungen](#2-systemvoraussetzungen)
3. [Installation](#3-installation)
4. [Konfiguration](#4-konfiguration)
5. [Skript 1: nextcloud-update-manual.sh](#5-skript-1-nextcloud-update-manualsh)
6. [Skript 2: nextcloud-update-cron.sh](#6-skript-2-nextcloud-update-cronsh)
7. [Installationsskript (install.sh)](#7-installationsskript-installsh)
8. [Log-Dateien](#8-log-dateien)
9. [Backup-Strategie](#9-backup-strategie)
10. [Fehlerbehebung](#10-fehlerbehebung)
11. [Technische Referenz](#11-technische-referenz)

---

## 1. Überblick

> **Wichtiger Hinweis: ISPConfig-spezifisches Werkzeug**
>
> Der Nextcloud Update Manager ist **ausschließlich für Server konzipiert, die mit
> [ISPConfig](https://www.ispconfig.org/) verwaltet werden**. Die Skripte setzen das
> ISPConfig-typische Verzeichnislayout (`/var/www/clients/client{N}/web{N}/web/`), die
> Web-User-Benennung (`web{N}`) sowie die von ISPConfig eingerichtete benutzerspezifische
> PHP-CLI-Konfiguration voraus. Auf anderen Hosting-Umgebungen (reiner LAMP/LEMP-Stack,
> Plesk, cPanel o.ä.) funktionieren die Skripte ohne Anpassungen **nicht**.

Der **Nextcloud Update Manager** automatisiert die Wartung von Nextcloud-Installationen auf ISPConfig-Servern. Er besteht aus zwei Bash-Skripten mit unterschiedlichen Einsatzzwecken:

| Skript                       | Einsatz                         | Verhalten bei Major-Upgrade |
| ---------------------------- | ------------------------------- | --------------------------- |
| `nextcloud-update-manual.sh` | Manuelle Ausführung durch Admin | Interaktive Rückfrage       |
| `nextcloud-update-cron.sh`   | Automatischer Root-Cronjob      | E-Mail-Benachrichtigung     |

**Gemeinsame Funktionen beider Skripte:**

- Durchsucht `/var/www/clients/` nach allen Nextcloud-Installationen
- Spielt Minor-Updates (innerhalb derselben Hauptversion) automatisch ein
- Prüft App-Kompatibilität mit der nächsten Hauptversion via Nextcloud App Store API
- Protokolliert alle Aktionen in dedizierte Log-Dateien

---

## 2. Systemvoraussetzungen

### Betriebssystem

| Distribution | Versionen | Status |
|---|---|---|
| Debian | 11 (Bullseye), 12 (Bookworm), **13 (Trixie)** | Vollständig unterstützt |
| Ubuntu | 20.04 LTS, 22.04 LTS, 24.04 LTS | Vollständig unterstützt |
| RHEL / CentOS / AlmaLinux | 8+ | Eingeschränkt unterstützt (dnf/yum) |

**Debian 13 "Trixie" (stable seit August 2025):** Alle Abhängigkeiten sind in den offiziellen Repos vorhanden. `bash 5.2`, `curl 8.14`, `default-mysql-client` (inkl. `mysqldump`) und `apt-get` funktionieren ohne Anpassungen. Die Skripte laufen auf Debian 13 identisch wie auf Debian 11/12.

### Server-Layout

Das Skript erwartet das **ISPconfig-Standard-Layout**:

```
/var/www/clients/
└── client{N}/
    └── web{N}/
        └── web/                ← Nextcloud-Root (enthält: occ, config/, version.php)
            ├── occ
            ├── config/
            │   └── config.php
            ├── version.php
            └── updater/
                └── updater.phar
```

### Benötigte Pakete

| Paket                                              | Zweck                                           | Wird automatisch installiert |
| -------------------------------------------------- | ----------------------------------------------- | ---------------------------- |
| `curl`                                             | Update-Server-Abfragen, E-Mail-Versand          | Ja                           |
| `jq`                                               | JSON-Verarbeitung (occ-Ausgaben, App Store API) | Ja                           |
| `rsync`                                            | Datei-Backup vor Major-Upgrade                  | Ja                           |
| `default-mysql-client` (Debian) / `mariadb` (RHEL) | Datenbank-Backup (`mysqldump`)                  | Ja                           |

### Berechtigungen

- Ausführung als **root**
- `sudo` muss für root → `web{N}`-User ohne Passwort konfiguriert sein:
  ```
  # /etc/sudoers.d/nextcloud-update (ISPconfig setzt dies üblicherweise)
  root ALL=(www-data,web1,web2,...) NOPASSWD: /usr/bin/php
  ```
  In der Praxis ist dies bei ISPconfig-Installationen standardmäßig gegeben.

### PHP

Jeder ISPconfig-Web-User hat eine eigene PHP-CLI-Version. Beim Ausführen von `sudo -u web1 php occ ...` wird automatisch die für `web1` konfigurierte PHP-CLI verwendet.

---

## 3. Installation

### 3.1 Automatische Installation (empfohlen)

```bash
git clone https://github.com/Nextcloud-Update-Manager/Nextcloud-Update-Manager.git
cd Nextcloud-Update-Manager
chmod +x install.sh
sudo ./install.sh
```

Das Installationsskript führt folgende Schritte durch:

1. Root-Prüfung
2. Quelldateien prüfen
3. Paketmanager erkennen (apt-get / dnf / yum)
4. Fehlende Pakete installieren
5. Skripte nach `/usr/local/sbin/` kopieren, Rechte setzen
6. Log- und Backup-Verzeichnisse anlegen
7. SMTP-Konfiguration interaktiv abfragen und unter `/etc/nextcloud-update/smtp.conf` speichern
8. Optionalen Cronjob einrichten

### 3.2 Manuelle Installation

```bash
# Pakete installieren
apt-get install -y curl jq rsync default-mysql-client

# Skripte deployen
cp scripts/nextcloud-update-manual.sh /usr/local/sbin/
cp scripts/nextcloud-update-cron.sh   /usr/local/sbin/
chmod 700 /usr/local/sbin/nextcloud-update-*.sh
chown root:root /usr/local/sbin/nextcloud-update-*.sh

# Verzeichnisse anlegen
mkdir -p /var/log/Nextcloud-Update
chmod 750 /var/log/Nextcloud-Update

mkdir -p /var/backups/nextcloud
chmod 750 /var/backups/nextcloud

# SMTP-Konfiguration einrichten
mkdir -p /etc/nextcloud-update
cp scripts/smtp.conf.example /etc/nextcloud-update/smtp.conf
nano /etc/nextcloud-update/smtp.conf   # Werte eintragen
chmod 600 /etc/nextcloud-update/smtp.conf
chown root:root /etc/nextcloud-update/smtp.conf

# Cronjob (Sonntag 03:00 Uhr)
cat > /etc/cron.d/nextcloud-update << 'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 3 * * 0 root /usr/local/sbin/nextcloud-update-cron.sh
EOF
chmod 644 /etc/cron.d/nextcloud-update
```

### 3.3 Update einer bestehenden Installation

Das Installationsskript erkennt bestehende Skripte und erstellt automatisch Backups:

```
/usr/local/sbin/nextcloud-update-manual.sh.bak.20260603
/usr/local/sbin/nextcloud-update-cron.sh.bak.20260603
```

Einfach `sudo ./install.sh` erneut ausführen.

---

## 4. Konfiguration

### 4.1 SMTP-Konfigurationsdatei

**Pfad:** `/etc/nextcloud-update/smtp.conf`
**Berechtigungen:** `chmod 600`, `chown root:root`

```ini
# SMTP-Server (SMTPS mit implizitem TLS, Port 465)
SMTP_HOST=mail.example.com
SMTP_PORT=465

# SMTP-Zugangsdaten
SMTP_USER=nextcloud-notify@example.com
SMTP_PASS=IhrPasswort

# Absender (muss zum SMTP_USER passen)
SMTP_FROM=nextcloud-notify@example.com

# Empfänger für Major-Upgrade-Benachrichtigungen
MAIL_TO=admin@example.com
```

**Hinweis:** Das Cron-Skript lädt diese Datei beim Start. Änderungen werden beim nächsten Lauf übernommen.

### 4.2 Suche nach Installationen anpassen

Beide Skripte enthalten am Anfang Konfigurationsvariablen, die angepasst werden können:

```bash
NC_SEARCH_BASE="/var/www/clients"   # Wurzelverzeichnis der Suche
NC_SEARCH_MAXDEPTH=4                # Maximale Suchtiefe
LOG_DIR="/var/log/Nextcloud-Update" # Log-Verzeichnis
BACKUP_BASE="/var/backups/nextcloud" # Backup-Verzeichnis
```

---

## 5. Skript 1: nextcloud-update-manual.sh

### 5.1 Verwendung

```bash
# Normaler Lauf
/usr/local/sbin/nextcloud-update-manual.sh

# Dry-Run: zeigt was passieren würde, führt nichts aus
/usr/local/sbin/nextcloud-update-manual.sh --dry-run
```

### 5.2 Ablauf

```
Start
 ├─ Root-Prüfung
 ├─ Abhängigkeiten prüfen (curl, jq, rsync, mysqldump)
 ├─ Log-Verzeichnis anlegen (/var/log/Nextcloud-Update/)
 ├─ Lock-Datei setzen (/var/run/nextcloud-update-manual.lock)
 │
 └─ Für jede gefundene Nextcloud-Installation:
     ├─ Web-User ermitteln (stat)
     ├─ Log-Datei öffnen (/var/log/Nextcloud-Update/{web-user}.log)
     ├─ Aktuelle Version abrufen (occ status --output=json)
     ├─ PHP-Version des Web-Users ermitteln
     ├─ Update-Server abfragen
     │
     ├─ Gleiche Hauptversion?
     │   └─ Ja → Minor-Update automatisch durchführen
     │           ├─ Maintenance Mode: AN
     │           ├─ updater.phar --no-interaction
     │           ├─ occ upgrade
     │           ├─ occ app:update --all
     │           ├─ occ maintenance:repair
     │           └─ Maintenance Mode: AUS
     │
     └─ Neue Hauptversion?
         ├─ App-Kompatibilität prüfen (App Store API)
         ├─ Ergebnis anzeigen (kompatibel / inkompatibel / unbekannt)
         ├─ Admin fragen: Upgrade durchführen? [y/Y/j/J]
         │
         ├─ Nein → Überspringen, Log-Eintrag
         │
         └─ Ja → Backup erstellen
                 ├─ rsync (ohne data/)
                 ├─ mysqldump
                 └─ Upgrade-Ablauf (wie Minor-Update)
```

### 5.3 Interaktive Ausgabe (Beispiel)

**Minor-Update:**

```
────────────────────────────────────────────────────────────────────────
  Installation: /var/www/clients/client1/web1/web
────────────────────────────────────────────────────────────────────────
[2026-06-03 03:12:01] [INFO] Installierte Version: 28.0.12.3
[2026-06-03 03:12:01] [INFO] PHP-Version: 8.2.18
[2026-06-03 03:12:02] [INFO] Verfügbare Version: 28.0.14
[2026-06-03 03:12:02] [INFO] Minor-Update: 28.0.12.3 → 28.0.14

  Minor-Update wird automatisch durchgeführt:
  v28.0.12.3 → v28.0.14

[2026-06-03 03:14:38] [INFO] Minor-Update abgeschlossen. Neue Version: 28.0.14
  ✓ Update erfolgreich. Installierte Version: 28.0.14
```

**Major-Upgrade:**

```
────────────────────────────────────────────────────────────────────────
  ⚠  Nextcloud Major-Upgrade verfügbar
────────────────────────────────────────────────────────────────────────

  Installation:         /var/www/clients/client1/web1/web
  Web-User:             web1
  Aktuell installiert:  v28.0.14
  Verfügbare Version:   v29.0.3

  App-Kompatibilität mit Nextcloud v29:

  Kompatibel:
    ✓  calendar
    ✓  contacts
    ✓  mail

  Nicht kompatibel mit v29 (werden deaktiviert!):
    ✗  custom_app

  Nicht im App Store gefunden (Status unbekannt):
    ?  local_custom_app

  ⚠  WARNUNG: 1 App(s) sind in v29 nicht verfügbar!
  Diese Apps werden beim Upgrade automatisch deaktiviert.
  Bitte prüfen Sie, ob Alternativen verfügbar sind.

────────────────────────────────────────────────────────────────────────
  Soll das Upgrade auf v29.0.3 jetzt durchgeführt werden?
  [y/Y/j/J = Ja  |  andere Eingabe = Nein und überspringen]: y

  Backup erstellt: /var/backups/nextcloud/web1_v28.0.14_20260603_031512

  Führe Upgrade durch – bitte warten...

  ✓ Major-Upgrade erfolgreich!
  Installierte Version: 29.0.3
  Hinweis: Inkompatible Apps wurden deaktiviert: custom_app
```

### 5.4 Dry-Run Modus

Der `--dry-run`-Schalter führt alle Prüfungen durch, aber:

- Kein Update/Upgrade wird tatsächlich eingespielt
- Kein Backup wird erstellt
- Keine Maintenance Mode-Änderungen
- Zeigt was bei einem echten Lauf passieren würde

```bash
nextcloud-update-manual.sh --dry-run
```

---

## 6. Skript 2: nextcloud-update-cron.sh

### 6.1 Cronjob einrichten

**Via Installationsskript** (empfohlen) oder manuell:

```bash
# /etc/cron.d/nextcloud-update
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Wöchentlich, Sonntag 03:00 Uhr
0 3 * * 0 root /usr/local/sbin/nextcloud-update-cron.sh
```

**Empfohlene Ausführungszeiten:**

- Wöchentlich: `0 3 * * 0` (Sonntag 03:00)
- Täglich: `0 3 * * *` (täglich 03:00)
- Mo + Do: `30 2 * * 1,4` (Mo und Do 02:30)

### 6.2 Verhalten

Das Cron-Skript verhält sich wie Skript 1, mit folgenden Unterschieden:

| Aspekt        | Manual-Skript            | Cron-Skript                          |
| ------------- | ------------------------ | ------------------------------------ |
| Ausgabe       | Farbige Terminal-Ausgabe | Nur Log-Datei                        |
| Minor-Update  | Automatisch              | Automatisch                          |
| Major-Upgrade | Interaktive Abfrage      | E-Mail, kein automatisches Upgrade   |
| SMTP          | Nicht benötigt           | Pflicht für Major-Benachrichtigungen |

### 6.3 E-Mail-Benachrichtigung (Major-Upgrade)

Das Skript sendet bei einem verfügbaren Major-Upgrade eine E-Mail an die in `smtp.conf` konfigurierte Adresse:

```
Betreff: [Nextcloud] Major-Upgrade verfügbar: v28→v29 | server.example.com | web1

Nextcloud Major-Upgrade verfügbar
──────────────────────────────────────────────────

Server:               server.example.com
Installation:         /var/www/clients/client1/web1/web
Web-User:             web1
Aktuell:              v28.0.14
Verfügbar:            v29.0.3

App-Kompatibilität mit Nextcloud v29:
────────────────────────────────────────

KOMPATIBEL (3):
  ✓  calendar
  ✓  contacts
  ✓  mail

INKOMPATIBEL – werden beim Upgrade deaktiviert! (1):
  ✗  custom_app

────────────────────────────────────────
Nächste Schritte:
  Führen Sie das Upgrade manuell durch:
  > /usr/local/sbin/nextcloud-update-manual.sh

Log-Datei: /var/log/Nextcloud-Update/web1.log
```

### 6.4 E-Mail-Versand technisch

Der E-Mail-Versand erfolgt via `curl` über **SMTPS (Port 465, implizites TLS)**:

```bash
curl --url "smtps://${SMTP_HOST}:${SMTP_PORT}" \
     --ssl-reqd \
     --mail-from "$SMTP_FROM" \
     --mail-rcpt "$MAIL_TO" \
     --user "${SMTP_USER}:${SMTP_PASS}" \
     --upload-file <(mail_content)
```

Unterstützte SMTP-Anbieter: alle Anbieter mit SMTPS (Port 465). STARTTLS (Port 587) wird nicht direkt unterstützt; bei Bedarf `--url "smtp://..."` ohne `--ssl-reqd` verwenden und `SMTP_PORT=587` setzen.

---

## 7. Installationsskript (install.sh)

### 7.1 Verwendung

```bash
sudo ./install.sh          # Erstinstallation ODER Update (automatisch erkannt)
sudo ./install.sh --full   # Vollständige Neuinstallation inkl. SMTP + Cronjob
```

### 7.2 Automatischer Modus-Erkennung

Das Skript erkennt automatisch ob es sich um eine Erst- oder Aktualisierungsinstallation handelt:

| Modus | Auslöser | Skripte | SMTP-Konfiguration | Cronjob |
| ----- | -------- | ------- | ------------------ | ------- |
| **Installation** | Erster Aufruf (keine bestehende Installation) | Installiert | Interaktive Eingabe | Interaktive Eingabe |
| **Update** | Erneuter Aufruf (Skripte + smtp.conf vorhanden) | Aktualisiert | Unverändert | Unverändert |
| **Vollständig** | Flag `--full` | Aktualisiert | Interaktive Eingabe | Interaktive Eingabe |

**Typisches Update-Szenario nach einem neuen Repository-Stand:**

```bash
cd Nextcloud-Update-Manager
git pull
sudo ./install.sh
```

Das Skript erkennt die bestehende Installation und aktualisiert nur die Skripte. SMTP-Zugangsdaten und Cronjob-Zeitplan bleiben unberührt.

### 7.3 Ablauf

```
1. Voraussetzungen:    Root-Prüfung, Quelldateien prüfen, Paketmanager erkennen
2. Abhängigkeiten:     curl, jq, rsync, mysqldump prüfen und ggf. installieren
3. Skripte:            /usr/local/sbin/ kopieren, chmod 700, alte Version als .bak sichern
4. SMTP-Konfiguration: Update-Modus: unverändert | Vollinstallation: interaktive Eingabe
5. Cronjob:            Update-Modus: unverändert | Vollinstallation: konfigurierbar
```

### 7.4 SMTP-Eingabe (nur bei Erstinstallation oder --full)

Das Installationsskript fragt folgende Werte ab:

| Variable    | Beschreibung                                     | Validierung   |
| ----------- | ------------------------------------------------ | ------------- |
| `SMTP_HOST` | SMTP-Servername                                  | Pflichtfeld   |
| `SMTP_PORT` | SMTP-Port (Standard: 465)                        | Zahl 1–65535  |
| `SMTP_USER` | SMTP-Benutzername                                | Pflichtfeld   |
| `SMTP_PASS` | SMTP-Passwort (versteckte Eingabe)               | Pflichtfeld   |
| `SMTP_FROM` | Absender-Adresse                                 | E-Mail-Syntax |
| `MAIL_TO`   | Empfänger-Adresse (Standard: admin@example.com)  | E-Mail-Syntax |

Bestehende Werte aus `smtp.conf` werden als Vorschlag angezeigt (außer dem Passwort).

Nach der Eingabe wird ein **SMTP-Verbindungstest** angeboten, der eine Test-E-Mail sendet.

---

## 8. Log-Dateien

### 8.1 Struktur

```
/var/log/Nextcloud-Update/
├── web1.log          # Installation: /var/www/clients/client1/web1/web
├── web2.log          # Installation: /var/www/clients/client1/web2/web
├── web3.log          # Installation: /var/www/clients/client2/web3/web
└── cron.log          # Globales Log des Cron-Skripts (Start/Ende, Fehler)
```

### 8.2 Log-Format

```
[YYYY-MM-DD HH:MM:SS] [LEVEL] Meldung
```

**Log-Level:**

| Level   | Bedeutung                                      |
| ------- | ---------------------------------------------- |
| `INFO`  | Normaler Betrieb                               |
| `WARN`  | Nicht kritische Probleme (Skript läuft weiter) |
| `ERROR` | Kritische Fehler (Aktion wurde abgebrochen)    |
| `DEBUG` | Detaillierte technische Informationen          |

### 8.3 Beispiel-Log (Minor-Update)

```
[2026-06-03 03:12:00] [INFO] === Wartungsbeginn: /var/www/clients/client1/web1/web | User: web1 ===
[2026-06-03 03:12:01] [INFO] Installierte Version: 28.0.12.3
[2026-06-03 03:12:01] [INFO] PHP-Version (Web-User): 8.2.18
[2026-06-03 03:12:02] [INFO] Frage Update-Server an...
[2026-06-03 03:12:02] [INFO] Verfügbare Version laut Update-Server: 28.0.14
[2026-06-03 03:12:02] [INFO] Minor-Update verfügbar: v28.0.12.3 → v28.0.14
[2026-06-03 03:12:02] [INFO] Maintenance Mode: AN
[2026-06-03 03:12:03] [INFO] Führe Nextcloud Updater (updater.phar) aus...
[2026-06-03 03:13:44] [INFO] updater.phar abgeschlossen (Exit-Code: 0)
[2026-06-03 03:13:44] [INFO] Datenbankmigrationen (occ upgrade)...
[2026-06-03 03:14:12] [INFO] Datenbankmigrationen OK
[2026-06-03 03:14:12] [INFO] App-Updates (occ app:update --all)...
[2026-06-03 03:14:28] [INFO] Reparatur-Routine (occ maintenance:repair)...
[2026-06-03 03:14:31] [INFO] Maintenance Mode: AUS
[2026-06-03 03:14:31] [INFO] Update/Upgrade-Ablauf abgeschlossen
[2026-06-03 03:14:32] [INFO] Minor-Update abgeschlossen. Neue Version: 28.0.14
[2026-06-03 03:14:32] [INFO] === Wartungsende: /var/www/clients/client1/web1/web ===
```

### 8.4 Log-Rotation (logrotate)

Empfohlene `/etc/logrotate.d/nextcloud-update`:

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

## 9. Backup-Strategie

Ein Backup wird **nur vor Major-Upgrades** automatisch erstellt. Minor-Updates benötigen kein Backup, da `updater.phar` intern eine eigene Sicherung anlegt.

### 9.1 Backup-Inhalt

| Komponente        | Was                       | Wo                                                                  |
| ----------------- | ------------------------- | ------------------------------------------------------------------- |
| Nextcloud-Dateien | rsync (ohne `data/`)      | `/var/backups/nextcloud/{web-user}_v{version}_{datum}/files/`       |
| Datenbank         | mysqldump (MySQL/MariaDB) | `/var/backups/nextcloud/{web-user}_v{version}_{datum}/database.sql` |

**Hinweis:** Das `data/`-Verzeichnis wird vom Backup ausgeschlossen, da es typischerweise auf separatem Storage liegt und sehr groß sein kann. Die Benutzerdaten sind über reguläre Server-Backups zu sichern.

### 9.2 Backup-Verzeichnis-Beispiel

```
/var/backups/nextcloud/
└── web1_v28.0.14_20260603_031512/
    ├── files/                    # Nextcloud-Anwendungsdateien
    │   ├── occ
    │   ├── config/
    │   ├── apps/
    │   └── ...
    └── database.sql              # Vollständiger Datenbank-Dump
```

### 9.3 Rollback nach fehlgeschlagenem Upgrade

```bash
# 1. Maintenance Mode prüfen
sudo -u web1 php /var/www/clients/client1/web1/web/occ maintenance:mode --on

# 2. Dateien wiederherstellen
rsync -a --delete /var/backups/nextcloud/web1_v28.0.14_20260603_031512/files/ \
    /var/www/clients/client1/web1/web/

# 3. Datenbank wiederherstellen
mysql -u {db_user} -p{db_pass} {db_name} \
    < /var/backups/nextcloud/web1_v28.0.14_20260603_031512/database.sql

# 4. Maintenance Mode ausschalten
sudo -u web1 php /var/www/clients/client1/web1/web/occ maintenance:mode --off
```

---

## 10. Fehlerbehebung

### 10.1 Häufige Fehler

**`Kann aktuelle Version nicht ermitteln`**

```
[ERROR] Kann aktuelle Version nicht ermitteln – Installation wird übersprungen
```

Mögliche Ursachen:

- `occ` ist nicht ausführbar: `chmod +x /var/www/.../occ`
- PHP nicht verfügbar für den Web-User: `sudo -u web1 php --version`
- Nextcloud nicht vollständig installiert
- `jq` nicht installiert: `apt-get install jq`

---

**`updater.phar nicht gefunden`**

```
[WARN] updater.phar nicht gefunden unter: .../updater/updater.phar
```

Das Skript fährt fort und führt nur `occ upgrade` durch (Dateien werden nicht aktualisiert). Dies tritt auf wenn:

- Die Installation manuell ohne den Nextcloud-Updater durchgeführt wurde
- `updater.phar` sich in einem anderen Verzeichnis befindet

Lösung: `updater.phar` manuell herunterladen oder Pfad in `run_update()` anpassen.

---

**`Datenbankmigrationen fehlgeschlagen`**

```
[ERROR] Datenbankmigrationen fehlgeschlagen
```

Der Maintenance Mode wurde automatisch deaktiviert. Prüfen:

```bash
# Manuell ausführen mit Ausgabe
sudo -u web1 php /var/www/clients/client1/web1/web/occ upgrade

# Log prüfen
tail -50 /var/log/Nextcloud-Update/web1.log
```

---

**`Maintenance Mode konnte nicht deaktiviert werden`**

```
[WARN] Maintenance Mode konnte nicht automatisch deaktiviert werden!
```

Nextcloud bleibt im Wartungsmodus. Sofortmaßnahme:

```bash
sudo -u web1 php /var/www/clients/client1/web1/web/occ maintenance:mode --off
```

---

**`E-Mail-Versand fehlgeschlagen`**

Verbindungstest durchführen:

```bash
# SMTP-Verbindung prüfen
curl -v --url "smtps://mail.example.com:465" --ssl-reqd \
     --mail-from "sender@example.com" \
     --mail-rcpt "empfaenger@example.com" \
     --user "sender@example.com:passwort" \
     --upload-file /dev/null
```

Häufige Ursachen:

- Falsches Passwort in `smtp.conf`
- Firewall blockiert Port 465 (ausgehend)
- 2FA beim SMTP-Account aktiv (App-Passwort benötigt)
- `SMTP_FROM` stimmt nicht mit `SMTP_USER` überein

---

**`Anderer Prozess läuft bereits`**

```
Warnung: Anderer Prozess läuft bereits (PID: 12345). Abbruch.
```

Stale Lock-Datei vorhanden:

```bash
# Prüfen ob Prozess wirklich noch läuft
ps aux | grep nextcloud-update

# Lock-Datei entfernen wenn Prozess nicht läuft
rm /var/run/nextcloud-update-manual.lock
rm /var/run/nextcloud-update-cron.lock
```

---

### 10.2 Debugging

Beide Skripte schreiben DEBUG-Meldungen nur in die Log-Datei (nicht auf stdout). Für Debugging den Log live beobachten:

```bash
# Log einer Installation live verfolgen
tail -f /var/log/Nextcloud-Update/web1.log

# Alle Logs auf einmal
tail -f /var/log/Nextcloud-Update/*.log

# Letzten Cronjob-Lauf prüfen
cat /var/log/Nextcloud-Update/cron.log
```

---

## 11. Technische Referenz

### 11.1 Verwendete APIs

**Nextcloud Update-Server:**

```
GET https://updates.nextcloud.com/updater_server/
    ?version={current_4part_version}
    &PHP_version={php_version}
    &LANG=de
    &request_type=nextcloud
```

Antwort (XML):

```xml
<nextcloud>
  <version>29.0.3</version>
  <versionstring>Nextcloud 29.0.3</versionstring>
  <url>https://download.nextcloud.com/...</url>
  <web>https://docs.nextcloud.com/...</web>
  <signature>...</signature>
</nextcloud>
```

Leere Antwort (`<nextcloud/>`) bedeutet: kein Update verfügbar.

**Nextcloud App Store API:**

```
GET https://apps.nextcloud.com/api/v1/platform/{major}.0.0/apps.json
```

Gibt JSON-Array aller für diese Plattformversion verfügbaren Apps zurück. Jedes Element enthält mindestens `id` (App-ID).

### 11.2 occ-Befehle

| Befehl                            | Zweck                                       |
| --------------------------------- | ------------------------------------------- |
| `occ status --output=json`        | Aktuelle Version und Status                 |
| `occ maintenance:mode --on/--off` | Wartungsmodus                               |
| `occ upgrade`                     | Datenbank-Migrationen nach Datei-Update     |
| `occ app:list --output=json`      | Liste aller installierten Apps              |
| `occ app:update --all`            | Alle Apps auf neueste Version aktualisieren |
| `occ maintenance:repair`          | Reparatur-Routine (Indizes, Caches)         |

### 11.3 Update-Prozess im Detail

```
updater.phar --no-interaction
    ↓
  Prüft Update-Server auf neue Version
  Lädt neue Version herunter (ZIP)
  Verifiziert Signatur
  Erstellt internen Backup
  Aktiviert Maintenance Mode
  Extrahiert neue Dateien
  Beendet sich
    ↓
occ upgrade
    ↓
  Liest neue Version aus version.php
  Führt Datenbank-Migrationen aus
  Aktualisiert App-Versionen in DB
    ↓
occ app:update --all
    ↓
  Aktualisiert alle Apps auf neueste kompatible Version
    ↓
occ maintenance:repair
    ↓
  Repariert Datenbankindizes
  Leert Cache
  Prüft Datenintegrität
    ↓
Maintenance Mode: AUS
```

### 11.4 Versionsnormalisierung

Nextcloud verwendet intern 4-stellige Versionsnummern (z.B. `28.0.12.3`), während der Update-Server und das User-Interface 3-stellige Versionen zeigen (`28.0.12`). Das Skript normalisiert auf 3 Teile für den Vergleich:

```bash
normalize_version() {
    echo "$1" | cut -d. -f1-3
}
# 28.0.12.3 → 28.0.12
# 29.0.0    → 29.0.0
```

Der Major-Version-Vergleich verwendet nur das erste Feld:

```bash
get_major() {
    echo "$1" | cut -d. -f1
}
```

### 11.5 Sicherheitsaspekte

- **SMTP-Konfiguration** mit `chmod 600` schützt Zugangsdaten
- **SMTP-Config-Parsing** vermeidet blindes `source` – nur erlaubte Variablennamen werden geladen
- **Lock-Datei** verhindert parallele Ausführung und Race Conditions
- **mysqldump-Passwort** wird per `-p"$PASS"` übergeben (nicht via Umgebungsvariable, da mysqldump `.my.cnf` bevorzugt)
- **occ-Befehle** laufen immer als Web-Owner (`sudo -u web{N}`), nie als root
