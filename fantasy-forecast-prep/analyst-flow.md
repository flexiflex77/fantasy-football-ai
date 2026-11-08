# Prognose und KI-Empfehlungen

## Eigene Punkteprognose

Die erste Vergleichsprognose verwendet ausschließlich die tatsächlichen Fantasy-Punkte aus bis zu vier früheren Wochen. Sie kombiniert den Spielerdurchschnitt mit dem Positionsdurchschnitt, der wie zwei zusätzliche Spiele gewichtet wird. Ohne vorherige Spielergebnisse enthält sich das Modell. ESPN-Prognosen gehen nicht in die Berechnung ein. Sie dienen als Vergleich.

Der historische Test misst die mittlere absolute Abweichung für dieselben Spieler und Wochen bei beiden Prognosen. Der strenge Vergleich setzt voraus, dass die gespeicherten Eingaben vor dem ersten Kickoff der Zielwoche aktualisiert wurden. Der rückblickende Vergleich zeigt nur, wie die Methode auf den derzeit gespeicherten Daten aussieht. Eine noch laufende Woche zählt nicht als vollständige Testwoche.

## Drei Rollen für die spätere Empfehlung

1. **Analyst** erstellt getrennte Vorschläge für Startaufstellung und Waiver. Er verwendet die eigene Prognose, die ESPN-Prognose und den vorliegenden Verletzungs- und Verfügbarkeitsstand. Er nennt bei schwacher Datenlage ausdrücklich keinen Wechsel.
2. **Gegenprüfer** erhält denselben Datenstand und den Vorschlag. Er prüft Position und Startberechtigung, Spielbeginn, Verletzungsstatus und die Größe des erwarteten Vorteils. Bei Waivers prüft er zusätzlich, ob eine sofortige Aufnahme möglich ist oder ein Claim nötig wäre. Er benennt fehlende Informationen und schlägt bei Bedarf eine Alternative aus dem Kandidatenpool vor.
3. **Entscheider** legt eine Empfehlung, eine Alternative oder „kein Wechsel“ vor. Er nennt den stärksten Einwand und die verbleibende Unsicherheit. Die Anwendung prüft ausgewählte Spieler-IDs, Positionen und Status gegen die Eingangsdaten. Sie übernimmt Punkte ausschließlich aus den berechneten Prognosen. Kein Schritt führt einen Wechsel bei ESPN aus.

Für alle drei Rollen gilt derselbe Datenstand. Punkteprognosen und die Begründung sind getrennte Felder. Die Rollen können später mit einem oder mehreren Modellanbietern getestet werden. Mehrere Rollen allein sind kein Nachweis für unabhängige oder bessere Vorhersagen.

## Voraussetzungen für eine belastbare Auswertung

Prognosen, Kader, verfügbare Spieler und Verletzungsmeldungen vor dem ersten Spiel als unveränderlichen Wochenstand erfassen. Endergebnisse nach Abschluss der Woche getrennt ablegen. Über mehrere vollständige Wochen zunächst Prognosefehler, Abdeckung und Fehlentscheidungen vergleichen. Die App kann danach ESPN-Prognose und eigene Prognose nebeneinander anzeigen.
