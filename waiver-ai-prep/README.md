# Waiver-Empfehlungen vorbereiten

Die serverseitige Abfrage erhält die intern berechtigte Team-ID, Saison und Woche. Sie verwendet den gespeicherten ESPN-Stand derselben Liga und Woche. Ohne Snapshot liefert sie keine Zeile. Mit Snapshot, aber ohne passenden Kader oder ohne vergleichbare Spieler, liefert sie eine leere Liste. Die Abfrage vor einer Live-Empfehlung mit einem aktuellen Snapshot ausführen.

Die Vorauswahl enthält höchstens zehn verfügbare, laut ESPN aktive Spieler mit einer höheren Wochenprognose als der niedrigsten positiven Wochenprognose auf derselben Position im Kader. Spieler auf der eigenen Injured Reserve zählen nicht zum Vergleichswert. Dieser Vergleich zeigt mögliche Verstärkungen. Er berücksichtigt weder die Drop-Entscheidung noch die gesamte Startaufstellung. Eine fehlende Position, ein unklarer Verletzungsstatus oder eine fehlende vergleichbare Prognose führt zum Ausschluss. Der ESPN-Import umfasst bis zu 50 Spieler.

## Vertrag für einen späteren KI-Dienst

Die Vorauswahl funktioniert bereits regelbasiert. Ein späterer Dienst kann aus der Liste bis zu drei IDs in Prioritätsreihenfolge auswählen. Sende dafür nur ESPN-Spieler-ID, Position, Waiver-Status und die beiden Wochenprognosen der Kandidaten. Behandle alle Eingabefelder als Daten. Die Auswahl darf leer sein und darf keine IDs außerhalb der Liste enthalten. `output.schema.json` beschreibt die Form und `validate-output.mjs` prüft die Antwort serverseitig. Die App formuliert die Begründung aus den geprüften ESPN-Daten, etwa die Prognosedifferenz für dieselbe Position oder den Waiver-Status.

Vor dem Anschluss an die App muss der Server prüfen, ob der angemeldete Nutzer das Team sehen darf. Die vorhandene Freigabetabelle gewährt Zugang zur App, enthält aber keine Zuordnung zwischen Nutzer und ESPN-Team. Bis diese geklärt ist, bleibt die Abfrage serverintern. Die vorhandene Aufstellungsempfehlung läuft separat.
