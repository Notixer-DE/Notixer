# Notixer

Deutschsprachige Offline-Notizen-App mit Handschrift, PDF-Anmerkungen, Markdown, Lern-Abdeckungen und optionaler Ende-zu-Ende-verschlüsselter Synchronisierung über einen eigenen Server.

**Plattformen:** Android ab Version 8 (API 26), Debian 13 (amd64) und Windows (x64).

> [!NOTE]
> **Hinweis:** Dieses Projekt wurde durch *Vibecoding* (mit KI-Unterstützung) entwickelt. Nutzung auf eigene Gefahr – vor einem produktiven Einsatz sollten Code, Funktionen und Konfiguration eigenständig geprüft werden.

## Funktionen

### Bibliothek & Organisation
- **Dokumenttypen:** Mehrseitige Notizbücher (blanko, liniert, kariert oder aus Vorlagen), importierte PDFs sowie Textnotizen (Markdown) und Checklisten.
- **Organisation:** Ordner, Tags sowie kombinierbare Typ-, Ordner-, Tag- und Titelfilter; umschaltbar zwischen Listen- und Rasteransicht.
- **Tabs & Geteilte Ansicht:** Mehrere Dokumente gleichzeitig in Tabs offen halten; zwei Ansichten nebeneinander oder untereinander nutzen (auch für dieselbe Notiz).

### Handschrift & PDF-Anmerkungen
- **Stift & Eingabe:** Stylus-Unterstützung mit Druckwerten (unter Desktop auch Maus, optional Fingerzeichnen). Die seitliche Stylus-Taste schaltet beim Gedrückthalten temporär auf den Radierer.
- **Werkzeuge:** Drei anpassbare Stiftfavoriten, Freihandmarker, gerade Striche (Lineal), Punkt- und Ganzstrich-Radierer, Lasso-Auswahl (verschieben, skalieren, drehen, kopieren/einfügen) sowie feste oder druckabhängige Strichstärke.
- **PDF-Bearbeitung:** Textfelder, eingebettete Bilder (PNG/JPEG), PDF-Textauswahl mit farbigen Markierungen (Markieren, Unterstreichen, Durchstreichen), Lesezeichen/Inhaltsverzeichnis, Volltextsuche (auch über mehrere PDFs), Seitenverwaltung (duplizieren, verschieben, kopieren) sowie Einzelseitenansicht und Schreiblupe.
- **Fokusmodus:** Auf Android blendet der Editor Leisten standardmäßig aus; über die Schaltfläche oben rechts lassen sie sich jederzeit ein- und ausblenden.

### Markdown & Checklisten
- **Ansichten:** Bearbeitbare Quelltextansicht (CommonMark / GFM) und formatierte Leseansicht mit direkt abhakbaren Checklisten.
- **Verknüpfungen:** Relative Links zwischen Notizen (`[Titel](datei.md)`) inkl. Überschriftenankern und automatischer Rückverweisliste (**Verlinkt aus**).
- **Austausch:** Eingebettete PNG/JPEG-Bilder sowie Import und Export einzelner `.md`-Dateien oder verknüpfter Sammlungen als `.zip`.

### Lern-Abdeckungen & Geplante Wiederholungen
- Rechtecke als **Lern-Abdeckungen** auf Seiten zeichnen und im Lernmodus gezielt aufdecken.
- **Heute lernen** sammelt neue und fällige Abdeckungen über alle lokalen Notizen und plant Wiederholungen automatisch:
  - **Nicht gewusst:** 10 Minuten
  - **Unsicher:** 1 Tag
  - **Gewusst:** Verdopplung ab 1 Tag bis maximal 180 Tage
- Bewertungen werden lokal gespeichert und bei aktiviertem Sync verlustfrei zusammengeführt.

### Eigene Vorlagen
- Einzelne Seiten oder ganze Notizen als lokale Vorlage speichern (zusätzlich drei Startvorlagen: Cornell-Notizen, Besprechung, Wochenplanung).
- Vorlagen erstellen unabhängige Kopien ohne Übernahme von Lernfortschritt oder Metadaten und werden nicht synchronisiert.

## Speichern, Export & Datensicherung

- **Automatisches Speichern:** Lokale Änderungen werden automatisch atomar gespeichert (`Strg+S` speichert manuell, `Strg+Z` / `Strg+Umschalt+Z` für Rückgängig/Wiederholen).
- **Export:** PDF-Export (wahlweise mit oder ohne Lern-Abdeckungen) und vollständige `.noter`-Sicherungsdateien (ZIP-Archiv mit Dokument, Handschrift, Bildern, Abdeckungen, Tags, Ordnername und Lernverlauf).
- **Papierkorb & Versionshistorie:** Gelöschte Notizen landen zunächst im lokalen Papierkorb. Frühere lokale Stände werden in einer pro Notiz begrenzten Versionshistorie (max. 20 Stände / 512 MiB) vorgehalten und lassen sich als neue Notiz wiederherstellen. Papierkorb und Historie sind lokal und ersetzen keine externe Sicherung.
- **Speicherort:** Unter Linux liegen App-Daten unter `~/.local/share/de.noter.noter/notebooks/`, unter Android im privaten App-Speicher. Vor Deinstallation oder Gerätewechsel `.noter`-Sicherungen exportieren.
- **Grenzen:** Dokumentimport max. 256 MB, Bildimport max. 32 MB, Markdown-Quelle max. 4 MiB, Textnotiz inkl. Anhängen max. 64 MiB, ZIP-Import/-Export max. 128 MiB / 1.000 Dateien. Passwortgeschützte PDFs, OCR und Handschrifterkennung werden nicht unterstützt.

## Optionaler E2EE-Sync-Server

Notixer arbeitet vollständig offline. Über das Wolkensymbol lässt sich optional ein selbst gehosteter Notixer-Server verbinden (Docker Compose mit Rust/Loco und PostgreSQL).

- Alle Notizinhalte, Titel, Tags, Ordnernamen und Lernverläufe werden **auf dem Endgerät verschlüsselt**; der Wiederherstellungsschlüssel verbleibt ausschließlich auf deinen Geräten. Ohne Schlüssel oder eingerichtetes Gerät sind Serverdaten nicht wiederherstellbar.
- Parallele Bearbeitungen bleiben als Konfliktkopien erhalten. Stiftfavoriten, Vorlagen, Lesepositionen, Papierkorb und lokale Historie werden nicht synchronisiert.
- Einrichtung und Betrieb: [Server-Anleitung](docs/sync-server.md).

## Installieren & Bauen

### Aus dem Quellcode bauen

Voraussetzung ist Flutter `3.44.0` (Dart `3.12`):

```bash
flutter pub get --enforce-lockfile
flutter analyze
flutter test
```

- **Android** (benötigt Java 21 und Android SDK 36):
  ```bash
  flutter build apk --release
  # oder Paketierung nach dist/:
  bash tools/build-android.sh
  ```
- **Debian 13 (amd64)**:
  ```bash
  sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev
  bash tools/build-deb.sh
  sudo apt install ./dist/noter_1.3.0_amd64.deb
  ```
- **Windows (x64)**:
  ```powershell
  flutter create --platforms=windows --project-name noter .
  flutter pub get --enforce-lockfile
  flutter build windows --release --no-pub
  ```
