# Claude Ring

Eine macOS-Menüleisten-App (macOS 26 oder neuer), die zeigt, wie viel vom Claude-Nutzungslimit
noch übrig ist und ob Claude Code gerade arbeitet.

> Claude Ring ist ein inoffizielles Projekt und nicht mit Anthropic verbunden. Claude und Claude Code
> sind Marken von Anthropic.

## Installieren

[**ClaudeRing.dmg herunterladen**](https://github.com/antonsiekmann/Claude-Ring/releases/latest/download/ClaudeRing.dmg)
(neueste Version, Apple Silicon und Intel), öffnen und „Claude Ring“ auf „Programme“ ziehen.
Ältere Versionen und Änderungen stehen unter [Releases](https://github.com/antonsiekmann/Claude-Ring/releases).

Voraussetzungen: macOS 26 oder neuer, Claude Code installiert und angemeldet (einmal `claude` im
Terminal starten).

Die App ist nur ad-hoc signiert, nicht bei Apple notarisiert. Beim ersten Öffnen meldet macOS deshalb,
dass Apple sie nicht überprüfen kann. Freigeben unter **Systemeinstellungen ▸ Datenschutz &
Sicherheit ▸ Dennoch öffnen** oder im Terminal mit
`xattr -dr com.apple.quarantine "/Applications/Claude Ring.app"`.

## Was sie zeigt

- **Menüleiste:** ein Ring mit dem verbleibenden Anteil der aktuellen 5-Stunden-Sitzung, daneben die
  Zahl, z. B. `◔ 87 %`. Nur der Ring wechselt die Farbe (grün, unter 30 % orange, unter 10 % rot),
  die Zahl bleibt in der normalen Textfarbe. In der Mitte des Rings sitzt ein **Statuspunkt** für
  Claude Code (bei den Stilen „Zwei Balken“ und „Nur Zahlen“ rechts daneben):
  - rot, pulsierend: Claude Code arbeitet (ruhig bei „Bewegung reduzieren“ und im Stromsparmodus; die
    Animation läuft im WindowServer und kostet die App keine Rechenzeit)
  - hellblau: Claude Code wartet auf eine Antwort (Rückfrage oder Berechtigung)
  - grün: frei
  - kein Punkt: gerade läuft keine Claude-Code-Sitzung

  Bei mehreren Sitzungen gilt Hellblau vor Rot vor Grün.
- **Popover (Linksklick):** großer Ring für die Sitzung mit Reset-Countdown, Karten für die
  Wochenlimits (alle Modelle und modellspezifisch), Wochennutzung nach Bereich und die laufenden
  Claude-Code-Sitzungen mit Projektordner und Zustand. Sitzungen, die Claude Code im Hintergrund
  ausführt (Agentenübersicht, `claude --bg`), tragen den Hinweis „Hintergrund“.
- **Menü (Rechtsklick):** Einstellungen …, Jetzt aktualisieren, Beenden.

## Einstellungen

| Tab | Inhalt |
|---|---|
| Allgemein | Bei der Anmeldung öffnen, Abrufintervall (1 bis 10 Min., Standard 5 Min.), vollständig entfernen |
| Menüleiste | Stil (Ring und Zahl, zwei Balken, nur Zahlen), Limit, übrig/genutzt, Farben, Statuspunkt, Live-Vorschau |
| Popover | Abschnitte ein- und ausblenden |
| Mitteilungen | Warnung und kritische Schwelle, Wochenlimit, Meldung nach Sitzungs-Reset |
| Claude Code | Statusanzeige einrichten oder entfernen, Token-Status |

## Woher kommen die Daten?

Die App liest das OAuth-Token, das **Claude Code** im Schlüsselbund unter `Claude Code-credentials`
ablegt, und ruft damit denselben Endpunkt ab, den Claude Code für `/usage` verwendet:

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <token>
anthropic-beta: oauth-2025-04-20
```

**Keine Passwortabfragen mehr:** Die App liest das Token über `/usr/bin/security`. Mit genau diesem
Werkzeug legt Claude Code den Eintrag an, deshalb erlaubt macOS den Zugriff ohne Rückfrage, auch nach
Neubuilds der App und wenn Claude Code den Eintrag neu schreibt.

**Sicherheit:** Das Token liegt nur im Arbeitsspeicher, wird höchstens einmal pro Minute und nur bei
Ablauf oder Ablehnung neu gelesen und erscheint nie in Logs. Die App speichert, ändert oder erneuert
es nie; das übernimmt Claude Code. Läuft es ab, genügt ein Start von `claude` im Terminal.

## Claude-Code-Status

Den Statuspunkt einrichten: **Einstellungen ▸ Claude Code ▸ Einrichten.** Die App

1. legt `~/Library/Application Support/ClaudeRing/claude-ring-hook.sh` an,
2. sichert `~/.claude/settings.json` nach `…/ClaudeRing/Backups/`,
3. trägt das Skript als Hook für einige Ereignisse ein. Reihenfolge und Format der Datei sowie alle
   anderen Hooks bleiben unverändert.

Das Skript schreibt pro Sitzung eine kleine Datei nach `…/ClaudeRing/Sessions/`, mit nur
Ereignis, Sitzungs-ID, Projektordner, Werkzeugname und Sitzungsart (Terminal oder Hintergrund), ohne
Eingaben oder Inhalte. Es gibt nichts aus
und endet immer erfolgreich, kann Claude Code also nicht stören. „Entfernen“ nimmt alles wieder
heraus.

Die Hooks nutzen Ereignisse, die es in aktuellen Claude-Code-Versionen gibt (getestet mit 2.1.294).
Mit deutlich älteren Versionen, etwa über geteilte Dotfiles, besser nicht einrichten.

Grenzen: Nach dem Genehmigen einer Berechtigung bleibt der Punkt hellblau, bis das Werkzeug fertig ist.
Nach einem Abbruch mit Esc wird er erst nach etwa einer Minute wieder grün.

## Vollständig entfernen

**Einstellungen ▸ Allgemein ▸ Claude Ring vollständig entfernen** nimmt nach einer Rückfrage alles
wieder heraus, was die App angelegt hat, und beendet sie:

- die Hook-Einträge in `~/.claude/settings.json` (alles andere darin bleibt unverändert)
- `~/Library/Application Support/ClaudeRing` (Hook-Skript, Sitzungsdaten, Sicherungen)
- die Einstellungen (`~/Library/Preferences/eu.siekmann.ClaudeRing.plist`)
- das Anmeldeobjekt, zugestellte Mitteilungen
- Caches, HTTP-Speicher und gespeicherte Fensterzustände
- die App selbst, wenn sie in „Programme“ liegt (in den Papierkorb)

Lassen sich die Hooks nicht entfernen, etwa weil `settings.json` gerade kein gültiges JSON ist, löscht
die App gar nichts und meldet den Grund. Claude Code und seine Anmeldung im Schlüsselbund bleiben in
jedem Fall unberührt.

Nicht entfernbar, weil macOS selbst sie verwaltet: der Eintrag unter Systemeinstellungen ▸ Mitteilungen
und Einträge im System-Log (die verfallen von selbst).

## Ressourcen

- Abruf im eingestellten Intervall mit Timer-Toleranz. Nach Fehlern wird seltener abgerufen (bis
  15 Min.), `Retry-After` wird respektiert.
- Pause im Ruhezustand, bei ausgeschaltetem Bildschirm, gesperrtem Bildschirm und Benutzerwechsel.
- Beim Öffnen des Popovers wird nur abgerufen, wenn die Daten älter als 2 Minuten sind.
- Anthropic begrenzt `/api/oauth/usage` sehr streng und antwortet teils lange mit HTTP 429. Dann
  wartet die App erst 5 Minuten, bei weiteren 429 bis zu 30 Minuten, und zeigt so lange den zuletzt
  abgerufenen Stand. Der wird gespeichert (nur Prozente und Zeiten) und gleich nach dem Start angezeigt.
- Der Claude-Code-Status kommt über Dateisystem-Ereignisse, ohne Abfrageschleife.
- Die Menüleiste wird nur neu gezeichnet, wenn sich etwas Sichtbares ändert.

## Entwickeln

`ClaudeRing.xcodeproj` in Xcode öffnen und mit ⌘R starten. Die App ist ohne Sandbox ad-hoc signiert
(„Sign to Run Locally“). Unter *Signing & Capabilities* lässt sich ein eigenes Team eintragen.

Tests: ⌘U in Xcode oder

```
xcodebuild -project ClaudeRing.xcodeproj -scheme ClaudeRing -destination 'platform=macOS' test
```

Mit `TEST_RUNNER_SNAPSHOT_DIR=<ordner>` vor dem Befehl rendern die Snapshot-Tests Menüleiste,
Popover und Einstellungen als PNG, jeweils hell und dunkel.

| Skript | Zweck |
|---|---|
| `scripts/install.sh` | Release-Version bauen und nach `/Applications/Claude Ring.app` installieren. Nur eine installierte Kopie kann bei der Anmeldung starten. |
| `scripts/make-dmg.sh` | Universal-Version bauen und `build/dist/ClaudeRing-<Version>.dmg` anlegen: die App, eine Verknüpfung zu „Programme“ und eine kurze Anleitung |

## Releases

Ein Release ist ein Git-Tag der Form `vMAJOR.MINOR.PATCH`:

```
git tag v1.1.0
git push origin v1.1.0
```

Den Rest erledigt GitHub Actions (`.github/workflows/build.yml`): Tests, Universal-Build, DMG und
die Release-Seite mit automatisch erzeugten Änderungsnotizen. Die Version kommt aus dem Tag, die
Build-Nummer aus der Laufnummer, im Projekt muss sich dafür nichts ändern. Jeder Push auf `main` und
jeder Pull Request lässt die Tests laufen.

## Lizenz

Copyright © 2026 Anton Siekmann

Claude Ring ist freie Software unter der [GNU General Public License v3.0](LICENSE). Du darfst sie
nutzen, verändern und weitergeben. Wer eine veränderte Version weitergibt, muss deren Quellcode
ebenfalls unter der GPL-3.0 offenlegen.

## Projektstruktur

```
ClaudeRing/
├── App/            Einstieg (AppKit), Status-Item, Popover, Einstellungsfenster, Hauptmenü, Login-Item
├── Model/          API-Modelle, Snapshot, Einstellungen
├── Usage/          Token (CredentialProvider), API-Client, Abrufplanung, Ruhezustand/Sperre
├── ClaudeCode/     Hook-Skript, settings.json-Editor, Installer, Sitzungen und ihre Zustände
├── Notifications/  Schwellen-Logik und Mitteilungen
├── Views/          Menüleisten-Renderer, Popover, Einstellungs-Tabs
└── AppIcon.icon    App-Icon im Icon-Composer-Format (Liquid Glass)
ClaudeRingTests/            Swift-Testing-Tests und Snapshot-Tests
scripts/                    install.sh und make-dmg.sh
.github/workflows/          Tests und Releases auf GitHub
```
