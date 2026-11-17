
import { withSupabase } from "npm:@supabase/server";
import { createClient } from "npm:@supabase/supabase-js@2";

const SEASON = 2026;
const LEAGUE_ID = 605081630;

Deno.serve(
  withSupabase({ auth: "secret" }, async (req) => {
    const corsHeaders = {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers":
        "authorization, x-client-info, apikey, content-type",
      "Access-Control-Allow-Methods": "POST, OPTIONS",
    };

    const json = (data: unknown, status = 200) =>
      new Response(JSON.stringify(data), {
        status,
        headers: {
          ...corsHeaders,
          "Content-Type": "application/json",
        },
      });

    if (req.method === "OPTIONS") {
      return new Response("ok", { headers: corsHeaders });
    }

    try {
      const body = await req.json().catch(() => ({}));
      const confirm = body.confirm === true;

      const supabaseUrl = Deno.env.get("SUPABASE_URL");
      const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
      const espnS2 = Deno.env.get("ESPN_S2");
      const espnSwid = Deno.env.get("ESPN_SWID");

      if (!supabaseUrl || !serviceKey || !espnS2 || !espnSwid) {
        return json({
          ok: false,
          message: "Ein benötigtes Supabase- oder ESPN-Secret fehlt.",
        }, 500);
      }

      const supabase = createClient(supabaseUrl, serviceKey);

      // Zuerst aktuelle ESPN-Spielwoche ermitteln.
      const baseUrl =
        `https://lm-api-reads.fantasy.espn.com/apis/v3/` +
        `games/ffl/seasons/${SEASON}/segments/0/` +
        `leagues/${LEAGUE_ID}`;

      const headers = {
        Cookie: `espn_s2=${espnS2}; SWID=${espnSwid}`,
        Accept: "application/json",
      };

      const statusResponse = await fetch(
        `${baseUrl}?view=mSettings`,
        { headers, signal: AbortSignal.timeout(15000) }
      );

      if (!statusResponse.ok) {
        return json({
          ok: false,
          message: "ESPN-Spielwoche konnte nicht ermittelt werden.",
          espn_status: statusResponse.status,
        }, 502);
      }

      const statusData = await statusResponse.json();

      const currentWeek = Number(
        statusData.scoringPeriodId ??
        statusData.status?.currentScoringPeriod ??
        statusData.status?.currentMatchupPeriod
      );

      if (
        !Number.isInteger(currentWeek) ||
        currentWeek < 1 ||
        currentWeek > 18
      ) {
        return json({
          ok: false,
          message: "Ungültige aktuelle ESPN-Spielwoche.",
          currentWeek,
        }, 500);
      }

      if (body.expected_week !== undefined && body.expected_week !== currentWeek) {
        return json({ ok: false, current_espn_week: currentWeek, message: "ESPN meldet eine andere Spielwoche." }, 409);
      }

      // Statistikdaten für die aktuelle Woche abrufen.
      const url =
        `${baseUrl}` +
        `?view=mSettings&view=mMatchup&view=mRoster` +
        `&view=chui_default_platformsettings` +
        `&scoringPeriodId=${currentWeek}`;

      const observedAt = new Date().toISOString();
      const espnResponse = await fetch(url, { headers, signal: AbortSignal.timeout(20000) });

      if (!espnResponse.ok) {
        return json({
          ok: false,
          espn_status: espnResponse.status,
          message: "ESPN konnte die Liga-Statistiken nicht liefern.",
        }, 502);
      }

      const espnData = await espnResponse.json();
      const teams = espnData.teams ?? [];

      if (teams.length !== 6) {
        return json({
          ok: false,
          message: `Erwartet: 6 Teams. Gefunden: ${teams.length}`,
        }, 502);
      }

      const rosterPlayers = new Map<string, any>();

      for (const team of teams) {
        for (const entry of team.roster?.entries ?? []) {
          const player = entry.playerPoolEntry?.player;

          if (player?.id != null) {
            rosterPlayers.set(String(player.id), player);
          }
        }
      }

      const espnIds = [...rosterPlayers.keys()];
      const playerIdMap = new Map<string, number>();
      const missingPlayerIds: string[] = [];

      for (let i = 0; i < espnIds.length; i += 500) {
        const batch = espnIds.slice(i, i + 500);

        const { data: dbPlayers, error } = await supabase
          .from("players")
          .select("id, espn_player_id")
          .in("espn_player_id", batch);

        if (error) {
          return json({
            ok: false,
            message: "Spielerabgleich fehlgeschlagen.",
            error: error.message,
          }, 500);
        }

        for (const player of dbPlayers ?? []) {
          playerIdMap.set(
            String(player.espn_player_id),
            player.id
          );
        }
      }

      const rows = new Map<string, any>();

      for (const [espnId, player] of rosterPlayers) {
        const databasePlayerId = playerIdMap.get(espnId);

        if (databasePlayerId == null) {
          missingPlayerIds.push(espnId);
          continue;
        }

        for (const stat of player.stats ?? []) {
          if (Number(stat.seasonId) !== SEASON) continue;
          if (Number(stat.scoringPeriodId) <= 0) continue;

          if (
            stat.statSplitTypeId != null &&
            Number(stat.statSplitTypeId) !== 1
          ) continue;

          const sourceId = Number(stat.statSourceId);

          if (sourceId !== 0 && sourceId !== 1) continue;

          const week = Number(stat.scoringPeriodId);
          const source = sourceId === 0
            ? "espn_actual"
            : "espn_projection";

          const key = `${databasePlayerId}-${week}-${source}`;

          rows.set(key, {
            player_id: databasePlayerId,
            season: SEASON,
            week,
            source,
            actual_points: sourceId === 0
              ? Number(stat.appliedTotal ?? 0)
              : null,
            projected_points: sourceId === 1
              ? Number(stat.appliedTotal ?? 0)
              : null,
            raw_stats: {
              espn_player_id: espnId,
              stat_source_id: sourceId,
              stat_split_type_id:
                stat.statSplitTypeId ?? null,
              applied_total: stat.appliedTotal ?? null,
              applied_stats: stat.appliedStats ?? {},
              stats: stat.stats ?? {},
            },
          });
        }
      }

      const weeklyRefresh = body.expected_week !== undefined;
      const allRows = weeklyRefresh
        ? [...rows.values()]
          .filter(row => row.week === currentWeek && row.source === "espn_projection" && row.raw_stats.applied_total != null)
          .map(row => ({ ...row, updated_at: observedAt }))
        : [...rows.values()];

      const actualRows = allRows.filter(
        row => row.source === "espn_actual"
      );

      const projectionRows = allRows.filter(
        row => row.source === "espn_projection"
      );

      if (!confirm) {
        return json({
          ok: true,
          preview: true,
          current_espn_week: currentWeek,
          teams_found: teams.length,
          roster_players_found: rosterPlayers.size,
          matched_players: playerIdMap.size,
          missing_players: missingPlayerIds.length,
          missing_player_ids: missingPlayerIds.slice(0, 30),
          actual_records: actualRows.length,
          projection_records: projectionRows.length,
          message: "Vorschau erfolgreich. Keine Daten gespeichert.",
        });
      }

      if (weeklyRefresh && projectionRows.length === 0) {
        return json({ ok: false, message: "ESPN hat keine Wochenprognosen geliefert." }, 502);
      }

      let imported = 0;
      const batchSize = 100;

      for (let i = 0; i < allRows.length; i += batchSize) {
        const batch = allRows.slice(i, i + batchSize);

        const { error } = await supabase
          .from("projections")
          .upsert(batch, {
            onConflict: "player_id,season,week,source",
          });

        if (error) {
          return json({
            ok: false,
            imported_before_error: imported,
            error: error.message,
            message: "Beim Speichern ist ein Fehler aufgetreten.",
          }, 500);
        }

        imported += batch.length;
      }

      return json({
        ok: true,
        preview: false,
        current_espn_week: currentWeek,
        teams_found: teams.length,
        roster_players_found: rosterPlayers.size,
        matched_players: playerIdMap.size,
        missing_players: missingPlayerIds.length,
        actual_records: actualRows.length,
        projection_records: projectionRows.length,
        imported_records: imported,
        message: "ESPN-Statistikimport erfolgreich abgeschlossen.",
      });

    } catch (error) {
      return json({
        ok: false,
        message: "Unerwarteter Fehler beim Statistikimport.",
        error: String(error),
      }, 500);
    }
  }),
);
