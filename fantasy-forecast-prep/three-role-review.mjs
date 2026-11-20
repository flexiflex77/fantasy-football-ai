const roles = [
  ["Analyst", "Empfiehl höchstens einen Wechsel und begründe ihn."],
  ["Gegenprüfer", "Prüfe die vorherige Einschätzung und benenne das wichtigste Risiko."],
  ["Entscheider", "Entscheide nach beiden Einschätzungen. Kleine ESPN-Differenzen sind unsicher."],
];

export const model = "gpt-5.6-luna";
export const maxOutputTokens = 800;
export const maxRequestBytes = 10000;

export async function runThreeRoleReview(candidates, complete) {
  const reviews = { lineup: [], waiver: [] };
  for (const [role, instruction] of roles) {
    for (const task of ["lineup", "waiver"]) {
      const options = candidates[task];
      const prompt = JSON.stringify({
        role, task, instruction, options, reviews: reviews[task],
        rules: "Wähle eine vorhandene Optionsnummer oder 0 für keinen Wechsel. Erfinde keine Spielernamen oder Tatsachen. Ein Wochenwert allein rechtfertigt keinen Drop. QUESTIONABLE ist ein Risiko. Ein fehlender Bericht bestätigt keine Gesundheit. Antworte auf Deutsch.",
      });
      if (new TextEncoder().encode(prompt).length > maxRequestBytes) {
        throw new Error("Prompt exceeds the test limit");
      }
      const result = await complete({ model, prompt, maxOutputTokens });
      if (!Number.isInteger(result?.choice) || typeof result?.reason !== "string" ||
        !result.reason.trim() || result.reason.length > 1200 ||
        (result.choice !== 0 && !options.some(option => option.option === result.choice))) {
        throw new Error("Invalid role response");
      }
      reviews[task].push({ role, choice: result.choice, reason: result.reason });
    }
  }
  return reviews;
}
