
import { withSupabase } from "npm:@supabase/server";
import { createClient } from "npm:@supabase/supabase-js@2";

const LEAGUE_ID = 605081630;
const SEASON = 2026;

const SLOT_NAMES: Record<number, string> = {
  0: "QB",
  2: "RB",
  3: "RB/WR",
  4: "WR",
  5: "WR/TE",
  6: "TE",
  8: "DT",
  9: "DE",
  10: "LB",
  11: "DL",
  12: "DB",
  13: "CB",
  14: "S",
  17: "K",
  18: "P",
  19: "HC",
  20: "BE",
  21: "IR",
  23: "FLEX"
};

type EspnEntry = {
  team_id: number;
  espn_player_id: string;
  roster_slot: string;
  is_injured_reserve: boolean;
};

// ESPN NFL team IDs, using the same abbreviations as the NFL schedule.
const NFL_TEAMS: Record<number, string> = {
  1: "ATL", 2: "BUF", 3: "CHI", 4: "CIN", 5: "CLE", 6: "DAL",
  7: "DEN", 8: "DET", 9: "GB", 10: "TEN", 11: "IND", 12: "KC",
  13: "LV", 14: "LAR", 15: "MIA", 16: "MIN", 17: "NE", 18: "NO",
  19: "NYG", 20: "NYJ", 21: "PHI", 22: "ARI", 23: "PIT", 24: "LAC",
  25: "SF", 26: "SEA", 27: "TB", 28: "WAS", 29: "CAR", 30: "JAX",
  33: "BAL", 34: "HOU",
};

Deno.serve(
  withSupabase({ auth: "secret" }, async (req) => {
    try {
      const body = await req.json().catch(() => ({}));
      const confirm = body.confirm === true;

      const supabaseUrl = Deno.env.get("SUPABASE_URL");
      const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
      const espnS2 = Deno.env.get("ESPN_S2");
      const espnSwid = Deno.env.get("ESPN_SWID");

      if (!supabaseUrl || !serviceKey || !espnS2 || !espnSwid) {
        throw new Error("Erforderliche Secrets fehlen.");
      }

      const supabase = createClient(supabaseUrl, serviceKey);

      const url =
        `https://lm-api-reads.fantasy.espn.com/apis/v3/` +
        `games/ffl/seasons/${SEASON}/segments/0/` +
        `leagues/${LEAGUE_ID}?view=mTeam&view=mRoster`;

      const observedAt = new Date().toISOString();
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

      const week = Number(
        league.scoringPeriodId ??
        league.status?.currentMatchupPeriod
      );

      if (!Number.isInteger(week) || week < 1 || week > 18) {
        throw new Error("Ungültige ESPN-Spielwoche.");
      }

      if (body.expected_week !== undefined && body.expected_week !== week) {
        return Response.json({ ok: false, week, error: "ESPN meldet eine andere Spielwoche." }, { status: 409 });
      }

      const espnTeams = league.teams ?? [];

      if (espnTeams.length !== 6) {
        throw new Error(
          `Erwartet: 6 Teams. ESPN liefert: ${espnTeams.length}`
        );
      }

      const { data: dbTeams, error: teamError } =
        await supabase
          .from("teams")
          .select("id, espn_team_id, team_name")
          .eq("league_id", LEAGUE_ID);

      if (teamError) throw teamError;

      const teamMap = new Map(
        (dbTeams ?? []).map(t => [
          String(t.espn_team_id),
          t.id
        ])
      );

      const entries: EspnEntry[] = [];
      const eligibilityMap = new Map<string, number[]>();

      const rosterPlayers = new Map<string, Record<string, unknown>>();

      for (const team of espnTeams) {
        const teamId = teamMap.get(String(team.id));

        if (!teamId) {
          throw new Error(
            `ESPN-Team ${team.id} fehlt in Supabase.`
          );
        }

        const teamEntries = team.roster?.entries;
        if (!Array.isArray(teamEntries) || teamEntries.length === 0) {
          throw new Error(`ESPN hat für Team ${team.id} keinen Kader geliefert.`);
        }

        for (const entry of teamEntries) {
          const player = entry.playerPoolEntry?.player;

          if (!Number.isSafeInteger(player?.id) || player.id === 0) {
            throw new Error(`Ungültiger Kaderspieler bei ESPN-Team ${team.id}.`);
          }

          const espnPlayerId = String(player.id);
          const slotId = entry.lineupSlotId;
          if (!Number.isInteger(slotId) || slotId < 0 || rosterPlayers.has(espnPlayerId)) {
            throw new Error(`Ungültiger oder doppelter ESPN-Kadereintrag: ${espnPlayerId}.`);
          }
          rosterPlayers.set(espnPlayerId, player);

          entries.push({
            team_id: teamId,
            espn_player_id: espnPlayerId,
            roster_slot:
              SLOT_NAMES[slotId] ?? `SLOT_${slotId}`,
            is_injured_reserve: slotId === 21
          });

          // Originale ESPN-Slot-IDs übernehmen.
          // Fehlende Werte nicht als leeres Array speichern.
          if (Array.isArray(player.eligibleSlots)) {
            const slots = [
              ...new Set(
                player.eligibleSlots
                  .map((value: unknown) => Number(value))
                  .filter(
                    (value: number) =>
                      Number.isInteger(value) &&
                      value >= 0
                  )
              )
            ].sort((a, b) => a - b);

            if (slots.length > 0) {
              const previous = eligibilityMap.get(espnPlayerId);

              if (
                previous &&
                JSON.stringify(previous) !== JSON.stringify(slots)
              ) {
                throw new Error(
                  `Widersprüchliche ESPN-Berechtigungen für Spieler ${espnPlayerId}.`
                );
              }

              eligibilityMap.set(espnPlayerId, slots);
            }
          }
        }
      }

      const espnIds = [
        ...new Set(entries.map(e => e.espn_player_id))
      ];

      if (espnIds.length === 0) {
        throw new Error("ESPN hat keine Kaderspieler geliefert.");
      }

      const { data: players, error: playerError } =
        await supabase
          .from("players")
          .select("id, espn_player_id, espn_eligible_slots")
          .in("espn_player_id", espnIds);

      if (playerError) throw playerError;

      const playerMap = new Map(
        (players ?? []).map(p => [
          String(p.espn_player_id),
          p.id
        ])
      );

      const missing = espnIds.filter(
        id => !playerMap.has(id)
      );

      const newPlayers = missing.map(id => {
        const player = rosterPlayers.get(id)!;
        const fullName = typeof player.fullName === "string" ? player.fullName.trim() : "";
        if (!fullName) throw new Error(`ESPN-Spieler ${id} hat keinen Namen.`);

        const positionId = Number(player.defaultPositionId);
        // ESPN's primary position ID of 12/13/14 is CB/S/DB.
        const defensivePositions: Record<number, string> = { 12: "CB", 13: "S", 14: "DB" };
        const slots = eligibilityMap.get(id);
        return {
          espn_player_id: id,
          full_name: fullName,
          position: slots?.includes(19) ? "HC" :
            defensivePositions[positionId] ?? SLOT_NAMES[positionId] ?? null,
          nfl_team: NFL_TEAMS[Number(player.proTeamId)] ?? null,
          espn_eligible_slots: slots ?? null,
        };
      });

      const eligibilityUpdates: {
        id: number;
        espn_eligible_slots: number[];
      }[] = [];

      let eligibilityUnchanged = 0;
      let eligibilityMissing = 0;

      for (const player of players ?? []) {
        const slots = eligibilityMap.get(
          String(player.espn_player_id)
        );

        if (!slots) {
          eligibilityMissing++;
          continue;
        }

        const existingSlots = player.espn_eligible_slots;

        const normalizedExisting =
          Array.isArray(existingSlots)
            ? [...existingSlots]
                .map(Number)
                .sort((a, b) => a - b)
            : null;

        if (
          normalizedExisting &&
          JSON.stringify(normalizedExisting) ===
            JSON.stringify(slots)
        ) {
          eligibilityUnchanged++;
          continue;
        }

        eligibilityUpdates.push({
          id: player.id,
          espn_eligible_slots: slots
        });
      }

      const rosterRows = entries.map(e => ({
        team_id: e.team_id,
        espn_player_id: e.espn_player_id,
        player_id: playerMap.get(e.espn_player_id),
        season: SEASON,
        week,
        roster_slot: e.roster_slot,
        is_injured_reserve: e.is_injured_reserve
      }));

      const teamIds = [...teamMap.values()];

      const { data: existing, error: existingError } =
        await supabase
          .from("roster_entries")
          .select("id, team_id, player_id, roster_slot")
          .eq("season", SEASON)
          .eq("week", week)
          .in("team_id", teamIds);

      if (existingError) throw existingError;

      const newKeys = new Set(
        rosterRows.map(
          r => `${r.team_id}:${r.player_id}`
        )
      );

      const existingKeys = new Set(
        (existing ?? []).map(
          r => `${r.team_id}:${r.player_id}`
        )
      );

      const removed = (existing ?? []).filter(
        r => !newKeys.has(`${r.team_id}:${r.player_id}`)
      );

      const added = rosterRows.filter(
        r => !existingKeys.has(`${r.team_id}:${r.player_id}`)
      );

      const existingMap = new Map(
        (existing ?? []).map(r => [
          `${r.team_id}:${r.player_id}`,
          r.roster_slot
        ])
      );

      const changedSlots = rosterRows.filter(r => {
        const key = `${r.team_id}:${r.player_id}`;

        return (
          existingMap.has(key) &&
          existingMap.get(key) !== r.roster_slot
        );
      });

      if (!confirm) {
        return Response.json({
          ok: true,
          preview: true,
          season: SEASON,
          week,
          teams_found: espnTeams.length,
          roster_entries_from_espn: rosterRows.length,
          existing_roster_entries: existing?.length ?? 0,
          entries_to_add: added.length,
          entries_to_remove: removed.length,
          changed_roster_slots: changedSlots.length,
          missing_players: missing.length,
          missing_player_ids: missing,
          eligibility_from_espn: eligibilityMap.size,
          eligibility_to_update: eligibilityUpdates.length,
          eligibility_unchanged: eligibilityUnchanged,
          eligibility_missing: eligibilityMissing,
          message: "Vorschau – keine Daten verändert."
        });
      }

      const { error: importError } = await supabase.rpc("save_espn_roster_import", {
        target_league: LEAGUE_ID,
        target_week: week,
        observed_at: observedAt,
        new_players: newPlayers,
        roster_rows: entries,
        eligibility_updates: eligibilityUpdates,
      });
      if (importError) throw new Error(importError.message);

      return Response.json({
        ok: true,
        preview: false,
        season: SEASON,
        week,
        teams_found: espnTeams.length,
        roster_entries_imported: rosterRows.length,
        new_entries: added.length,
        missing_players_discovered: newPlayers.length,
        old_entries_removed: removed.length,
        changed_roster_slots: changedSlots.length,
        eligibility_from_espn: eligibilityMap.size,
        eligibility_updated: eligibilityUpdates.length,
        eligibility_unchanged: eligibilityUnchanged,
        eligibility_missing: eligibilityMissing,
        message:
          "ESPN-Kader und Positionsberechtigungen erfolgreich importiert."
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
