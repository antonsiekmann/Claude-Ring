# Änderungen

Ein Abschnitt pro Version, die neueste oben. Beim Release übernimmt GitHub Actions den Abschnitt der
getaggten Version als Text der Release-Seite; „Was ist neu?“ in der App führt dorthin. Ohne Abschnitt
für die Version bricht der Release-Job ab.

## 1.2.1

### Geändert

- Updates öffnen das Disk-Image mit `diskutil image attach` statt mit `hdiutil`, das macOS 27 als
  veraltet meldet. Unter macOS 26 funktioniert das Update genauso wie bisher.

## 1.2.0

### Einfacher einrichten

- Willkommensfenster beim ersten Start: Es prüft die Anmeldung von Claude Code (und erkennt eine
  Anmeldung im Terminal von selbst), richtet Statuspunkt und Anmeldeobjekt mit einem Klick ein und
  zeigt, wo das Symbol in der Menüleiste sitzt. Wurde die App direkt im Disk-Image geöffnet, verschiebt
  es sie auf Wunsch nach „Programme“.
- Das Fenster des Disk-Images zeigt mit einem Pfeil, wohin die App gehört, und die Schritte für den
  ersten Start; die Textdatei entfällt.
- Claude Ring gibt es jetzt auch auf Englisch, passend zur Systemsprache.

### Behoben

- Einrichten und Entfernen des Statuspunkts legte jedes Mal eine neue Sicherung von
  `~/.claude/settings.json` an. Jetzt gibt es genau eine, angelegt vor der ersten Änderung.
- Das Einstellungsfenster passt seine Größe beim Wechsel der Tabs sofort und in einem Zug an.
- Nach der Anmeldung in Claude Code erscheinen die Werte sofort statt erst nach bis zu 15 Minuten.
- Läuft ein Zeitfenster ab, etwa die 5-Stunden-Sitzung, zeigt die Menüleiste es sofort als
  zurückgesetzt.
- Mitteilungen, die in den Systemeinstellungen nachträglich erlaubt wurden, kommen ohne Neustart an.
- Nach dem Aufwachen wartet der Abruf auf das Netz, statt einen Fehler zu zeigen.

### Geändert

- Drosselt Anthropic die Abfragen, zeigt das Popover einen ruhigen Hinweis statt einer Warnung. Das
  „!“ in der Menüleiste erscheint nur noch, wenn du etwas tun kannst oder die Daten veraltet sind.
- Der Statuspunkt unterscheidet die Zustände auch per Form: voll, wenn Claude Code arbeitet, halb,
  wenn es wartet, ein Ring, wenn es frei ist. „Arbeitet“ ist jetzt violett; Rot bleibt dem fast
  aufgebrauchten Limit vorbehalten.
- Ring und Balken färben sich an denselben Schwellen, an denen die Mitteilungen kommen
  (einstellbar unter Mitteilungen).
- Ist der Statuspunkt noch nicht eingerichtet, sagen das der Tab „Menüleiste“ und das Popover und
  bieten das Einrichten direkt an.

## 1.1.0

- Updates: Claude Ring fragt täglich bei GitHub nach einer neuen Version, lädt sie auf Klick, prüft
  sie und ersetzt sich selbst. Zurück bleibt dabei nichts.
- Der Statuspunkt für „Wartet auf Antwort“ ist hellblau.

## 1.0.0

- Erste Version: Ring mit dem verbleibenden Sitzungslimit in der Menüleiste, Popover mit Wochenlimits
  und Claude-Code-Sitzungen, Statuspunkt über Hooks, Mitteilungen an einstellbaren Schwellen.
