# ESPN Free-Agent-Import

Die Edge Function ist für serverseitige Aufrufe vorgesehen. Beim Deployment gilt `verify_jwt = false`. Der Funktionscode prüft den geheimen Projektschlüssel im Header `apikey` mit `withSupabase({ auth: "secret" })`. Der Schlüssel gehört ausschließlich auf den Server. Die vorhandenen ESPN-Umgebungsvariablen `ESPN_S2` und `ESPN_SWID` werden nur für Anfragen an ESPN verwendet.

- Vorschau mit POST und `{"action":"preview"}`.
- Import mit POST und `{"action":"import","expected_week":9}`. Die Woche muss aus der aktuellen Vorschau stammen. Der Import ruft ESPN erneut ab.
- Die Saison 2026 muss genau eine Liga in `public.leagues` haben. Pro Abruf kommen höchstens 50 Free Agents und Waiver-Spieler, sortiert nach ESPN-Kaderanteil.

## Daten für die spätere KI-Anbindung

`public.espn_free_agent_snapshots` enthält je Liga, Saison und Woche einen Snapshot mit `captured_at` und der Spielerliste in `players`. Ein neuer Abruf aktualisiert den Snapshot derselben Woche. Verwende für die spätere serverseitige Auswertung die gewünschte Liga, Saison und Woche und zeige das Alter des Snapshots an. `espn_player_id` ist die ESPN-Kennung. `fantasy_status` unterscheidet `FREEAGENT` und `WAIVERS`. Eine fehlende Punkteprognose ist `null`. Das Fehlen eines Spielers in der begrenzten Liste erlaubt keinen Rückschluss auf seine Verfügbarkeit.
