
import { withSupabase } from "npm:@supabase/server";
import { createClient } from "npm:@supabase/supabase-js@2";

Deno.serve(
  withSupabase({ auth: "secret" }, async (req) => {
    try {
      const body = await req.json().catch(() => ({}));
      const confirm = body.confirm === true;

      const espnS2 = Deno.env.get("ESPN_S2");
      const espnSwid = Deno.env.get("ESPN_SWID");
      const supabaseUrl = Deno.env.get("SUPABASE_URL");
      const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

      if (!espnS2 || !espnSwid || !supabaseUrl || !serviceKey) {
        throw new Error("Erforderliche Secrets fehlen.");
      }

      const supabase = createClient(supabaseUrl, serviceKey);

      const url =
        "https://lm-api-reads.fantasy.espn.com/apis/v3/" +
        "games/ffl/seasons/2026/segments/0/" +
        "leagues/605081630?view=mRoster";

      const response = await fetch(url, {
        signal: AbortSignal.timeout(20000),
        headers: {
          Cookie: `espn_s2=${espnS2}; SWID=${espnSwid}`,
          Accept: "application/json"
        }
      });

      if (!response.ok) {
        throw new Error(`ESPN HTTP ${response.status}`);
      }

      const league = await response.json();
      const week = Number(league.scoringPeriodId ?? league.status?.currentMatchupPeriod);
      if (body.expected_week !== undefined && body.expected_week !== week) {
        return Response.json({ ok: false, week, error: "ESPN meldet eine andere Spielwoche." }, { status: 409 });
      }

      const teams = league.teams ?? [];
      if (body.expected_week !== undefined && (
        !Array.isArray(teams) || teams.length !== 6 ||
        teams.some((team: any) => !Array.isArray(team.roster?.entries) || team.roster.entries.length === 0)
      )) {
        return Response.json({ ok: false, week, error: "ESPN hat keinen vollständigen Kader für Verletzungen geliefert." }, { status: 502 });
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

      const { data: players, error: playerError } =
        await supabase
          .from("players")
          .select("id, espn_player_id")
          .in("espn_player_id", espnIds);

      if (playerError) throw playerError;

      const playerIds = new Map(
        (players ?? []).map((p) => [
          String(p.espn_player_id),
          p.id
        ])
      );

      const reports = [];
const statuses: Record<string, number> = {};

const playerIdList = [...playerIds.values()];

const { data: previousReports, error: historyError } =
  await supabase
    .from("injury_reports")
    .select("player_id, status, injury, report_time, id")
    .eq("report_source", "espn")
    .in("player_id", playerIdList)
    .order("report_time", { ascending: false })
    .order("id", { ascending: false });

if (historyError) throw historyError;

const latestReport = new Map<number, any>();

for (const report of previousReports ?? []) {
  if (!latestReport.has(report.player_id)) {
    latestReport.set(report.player_id, report);
  }
}

for (const [espnId, player] of rosterPlayers) {
  const playerId = playerIds.get(espnId);
  if (!playerId) continue;

  const status = player.injuryStatus ?? "UNKNOWN";
  statuses[status] = (statuses[status] ?? 0) + 1;

  const injury =
    typeof player.injuryType === "string"
      ? player.injuryType
      : null;

  // UNKNOWN ist kein bestätigter Gesundheitsstatus.
  if (status === "UNKNOWN") continue;

  const previous = latestReport.get(playerId);

  // Gesunde Spieler ohne bisherigen Verletzungsverlauf
  // benötigen keinen Eintrag.
  if (
    !previous &&
    (status === "ACTIVE" || status === "NORMAL")
  ) {
    continue;
  }

  // Nur echte Änderungen speichern.
  if (
    previous &&
    previous.status === status &&
    previous.injury === injury
  ) {
    continue;
  }

  reports.push({
    player_id: playerId,
    status,
    injury,
    report_source: "espn",
    report_time: new Date().toISOString()
  });
}

      if (!confirm) {
        return Response.json({
          ok: true,
          preview: true,
          roster_players_found: rosterPlayers.size,
          matched_players: playerIds.size,
          new_or_changed_reports: reports.length,
          statuses,
          sample: reports.slice(0, 5),
          message: "Vorschau – keine Daten gespeichert."
        });
      }

      if (reports.length > 0) {
        const { error } = await supabase
          .from("injury_reports")
          .insert(reports);

        if (error) throw error;
      }

      return Response.json({
        ok: true,
        preview: false,
        week,
        roster_players_found: rosterPlayers.size,
        matched_players: playerIds.size,
        injury_reports_imported: reports.length,
        message: "ESPN-Verletzungsimport abgeschlossen."
      });
    } catch (error) {
      return Response.json(
        {
          ok: false,
          error: String(error)
        },
        { status: 500 }
      );
    }
  })
);
