export function validateWaiverOutput(output, candidates) {
  if (!output || typeof output !== "object" ||
    Object.keys(output).length !== 1 || !Array.isArray(output.recommendations) ||
    output.recommendations.length > 3) {
    throw new Error("Invalid recommendation list");
  }

  const byId = new Map(candidates.map((candidate) => [candidate.espn_player_id, candidate]));
  const selected = new Set();
  return output.recommendations.map((item) => {
    if (!item || typeof item !== "object" || Object.keys(item).length !== 1 ||
      typeof item.espn_player_id !== "string" || selected.has(item.espn_player_id)) {
      throw new Error("Invalid or repeated recommendation");
    }
    const candidate = byId.get(item.espn_player_id);
    if (!candidate) throw new Error("Recommendation is outside the candidate list");
    selected.add(item.espn_player_id);
    return candidate;
  });
}
