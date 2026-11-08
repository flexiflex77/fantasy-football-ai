import { withSupabase } from "npm:@supabase/server@1";

const season = 2026;
const limit = 50;

function failure(status: number, message: string) {
  return Response.json({ ok: false, message }, { status });
}

function isObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function numericValue(value: unknown) {
  if (typeof value !== "number" &&
    (typeof value !== "string" || value.trim() === "")) return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

async function fetchEspn(leagueId: number, view: string, headers: HeadersInit): Promise<unknown> {
  const url = "https://lm-api-reads.fantasy.espn.com/apis/v3/" +
    `games/ffl/seasons/${season}/segments/0/leagues/${leagueId}?view=${view}`;
  const response = await fetch(url, {
    headers,
    redirect: "error",
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) throw new Error("ESPN request failed");
  return await response.json();
}

function parsePlayer(entry: unknown, week: number) {
  if (!isObject(entry) || !isObject(entry.player)) return null;
  if (entry.status !== "FREEAGENT" && entry.status !== "WAIVERS") return null;
  const player = entry.player;
  const id = numericValue(player.id);
  if (id === null || !Number.isSafeInteger(id) || id === 0 ||
    typeof player.fullName !== "string" || !player.fullName.trim()) return null;

  const stats: unknown[] = Array.isArray(player.stats) ? player.stats : [];
  const projection = stats.filter(isObject).find((stat) =>
    numericValue(stat.seasonId) === season &&
    numericValue(stat.scoringPeriodId) === week &&
    numericValue(stat.statSourceId) === 1 &&
    (stat.statSplitTypeId == null || numericValue(stat.statSplitTypeId) === 1)
  );

  return {
    espn_player_id: String(id),
    name: player.fullName.trim(),
    nfl_team_id: numericValue(player.proTeamId),
    fantasy_status: entry.status,
    injury_status: typeof player.injuryStatus === "string" ? player.injuryStatus : null,
    injured: typeof player.injured === "boolean" ? player.injured : null,
    eligible_slots: Array.isArray(player.eligibleSlots) &&
        player.eligibleSlots.every((slot) => Number.isSafeInteger(slot))
      ? player.eligibleSlots as number[]
      : null,
    projected_points: numericValue(projection?.appliedTotal),
    bye_week_from_espn: numericValue(player.byeWeek),
  };
}

Deno.serve(withSupabase({ auth: "secret" }, async (request, context) => {
  if (request.method !== "POST") {
    return Response.json({ ok: false, message: "Nur POST erlaubt." }, {
      status: 405,
      headers: { Allow: "POST" },
    });
  }

  let input: unknown;
  try {
    input = await request.json();
  } catch {
    return failure(400, "Bitte einen JSON-Aufruf senden.");
  }
  if (!isObject(input) || (input.action !== "preview" && input.action !== "import")) {
    return failure(400, "Erlaubte Aktionen sind preview und import.");
  }
  if (input.action === "import" &&
    (typeof input.expected_week !== "number" || !Number.isInteger(input.expected_week) ||
      input.expected_week < 1 || input.expected_week > 18)) {
    return failure(400, "Für den Import ist die erwartete ESPN-Woche erforderlich.");
  }

  const espnS2 = Deno.env.get("ESPN_S2");
  const swid = Deno.env.get("ESPN_SWID");
  if (!espnS2 || !swid) return failure(500, "ESPN-Zugangsdaten fehlen.");

  const { data: leagues, error: leagueError } = await context.supabaseAdmin
    .from("leagues").select("id").eq("season", season).limit(2);
  const leagueId = numericValue(leagues?.[0]?.id);
  if (leagueError || leagues?.length !== 1 || leagueId === null ||
    !Number.isSafeInteger(leagueId) || leagueId < 1) {
    return failure(500, "Für die Saison muss genau eine ESPN-Liga hinterlegt sein.");
  }

  const headers = {
    Accept: "application/json",
    Cookie: `espn_s2=${espnS2}; SWID=${swid}`,
  };
  const capturedAt = new Date().toISOString();

  try {
    const settings = await fetchEspn(leagueId, "mSettings", headers);
    const week = isObject(settings) ? numericValue(settings.scoringPeriodId) : null;
    if (week === null || !Number.isInteger(week) || week < 1 || week > 18) {
      return failure(502, "ESPN hat keine gültige Spielwoche geliefert.");
    }
    if (input.action === "import" && input.expected_week !== week) {
      return failure(409, "Die ESPN-Spielwoche hat sich geändert. Vorschau erneut abrufen.");
    }

    const data = await fetchEspn(leagueId, "kona_player_info", {
      ...headers,
      "X-Fantasy-Filter": JSON.stringify({
        players: {
          filterStatus: { value: ["FREEAGENT", "WAIVERS"] },
          limit,
          sortPercOwned: { sortPriority: 1, sortAsc: false },
        },
      }),
    });
    if (!isObject(data) || !Array.isArray(data.players) ||
      data.players.length === 0 || data.players.length > limit) {
      return failure(502, "ESPN hat keine verwertbare Spielerliste geliefert.");
    }

    const players = [];
    const ids = new Set<string>();
    for (const entry of data.players) {
      const player = parsePlayer(entry, week);
      if (!player || ids.has(player.espn_player_id)) {
        return failure(502, "Die ESPN-Liste enthält ungültige oder doppelte Spieler.");
      }
      ids.add(player.espn_player_id);
      players.push(player);
    }

    const summary = {
      ok: true,
      season,
      league_id: leagueId,
      week,
      player_count: players.length,
      player_limit: limit,
    };
    if (input.action === "preview") {
      return Response.json({ ...summary, preview: true, players });
    }

    const { data: saved, error } = await context.supabaseAdmin.rpc(
      "save_espn_free_agent_snapshot",
      {
        snapshot_league: leagueId,
        snapshot_season: season,
        snapshot_week: week,
        snapshot_time: capturedAt,
        snapshot_players: players,
      },
    );
    if (error) return failure(500, "Die Spielerliste konnte nicht gespeichert werden.");
    if (saved !== true) return failure(409, "Eine aktuellere Spielerliste wurde bereits gespeichert.");

    return Response.json({ ...summary, preview: false, saved: true });
  } catch {
    return failure(502, "Die ESPN-Spielerdaten konnten nicht verarbeitet werden.");
  }
}));
