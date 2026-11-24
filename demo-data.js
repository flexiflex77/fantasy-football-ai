"use strict";

// Fiktive ESPN-Werte, Kaderzuordnungen und Verfügbarkeiten für die Vorführung.
const fantasyDemoData = (() => {
  const week = 12;
  const kickoff = "2026-11-29T18:00:00Z";
  const roster = [
    ["Josh Allen", "QB", "QB", 28.4, "ACTIVE", kickoff],
    ["Jahmyr Gibbs", "RB", "BE", 23.8, "ACTIVE", kickoff],
    ["Amon-Ra St. Brown", "WR", "WR", 20.1, "ACTIVE", kickoff],
    ["Justin Jefferson", "WR", "BE", 19.7, "ACTIVE", kickoff],
    ["Derrick Henry", "RB", "RB", 17.4, "ACTIVE", kickoff],
    ["Terry McLaurin", "WR", "WR", 15.5, "QUESTIONABLE", kickoff],
    ["Brock Bowers", "TE", "TE", 14.3, "ACTIVE", "2026-11-26T18:00:00Z"],
    ["J.K. Dobbins", "RB", "BE", 12.7, "ACTIVE", kickoff],
    ["Darnell Mooney", "WR", "BE", 11.2, "ACTIVE", kickoff],
    ["Dalton Schultz", "TE", "BE", 8.9, "ACTIVE", kickoff],
  ].map(([name, position, roster_slot, projected_points, injury_status, kickoff_at]) =>
    ({name, position, roster_slot, projected_points, injury_status, kickoff_at}));
  const candidates = [
    ["Khalil Shakir", "WR", "FREEAGENT", 15.8, 11.2],
    ["Jaylen Warren", "RB", "WAIVERS", 16.9, 12.7],
    ["Tucker Kraft", "TE", "FREEAGENT", 12.5, 8.9],
    ["Rashid Shaheed", "WR", "WAIVERS", 14.2, 11.2],
  ].map(([name, position, fantasy_status, projected_points, lowest_roster_projection]) =>
    ({name, position, fantasy_status, projected_points, lowest_roster_projection,
      projection_delta: projected_points - lowest_roster_projection}));
  return {
    recommendations: {
      week,
      recommendations: [
        {bankspieler:"Jahmyr Gibbs", starter:"Derrick Henry", zielposition:"RB",
          erwarteter_punktegewinn:6.4, bank_verletzungsstatus:"ACTIVE", starter_verletzungsstatus:"ACTIVE"},
        {bankspieler:"Justin Jefferson", starter:"Terry McLaurin", zielposition:"WR",
          erwarteter_punktegewinn:4.2, bank_verletzungsstatus:"ACTIVE", starter_verletzungsstatus:"QUESTIONABLE"},
      ],
    },
    waivers: {
      status: "ready",
      team_name: "Demo-Team",
      week,
      captured_at: "2026-11-28T17:00:00Z",
      roster_player_count: roster.length,
      source_player_count: candidates.length,
      candidates,
      current_forecasts: {week, projections_at:"2026-11-28T17:00:00Z", player_forecasts:roster},
      weekly_inputs: {week, captured_at:"2026-11-26T17:00:00Z", first_kickoff:"2026-11-26T18:00:00Z",
        roster_players:roster.length, espn_projections:roster.length, waiver_players:candidates.length, player_forecasts:roster},
      ai_review: {week, lineup:"Jahmyr Gibbs auf RB starten. Der erwartete Vorteil beträgt 6,40 Punkte.",
        waiver:"Khalil Shakir ist sofort verfügbar. Bei Jaylen Warren ist ein Waiver-Claim nötig."},
    },
  };
})();
