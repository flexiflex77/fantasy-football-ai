
"use strict";

// Fantasy Football AI – Supabase-Konfiguration
const SUPABASE_URL =
  "https://uzifirhbzrwmxlxgwjss.supabase.co";

// Hier deinen bisherigen öffentlichen Publishable Key eintragen
const SUPABASE_KEY = "sb_publishable_pDEOZqKyCI4rRV6FLbq25Q_83wNcA23";

// Elemente unserer App
const loginForm = document.getElementById("login-form");
const loginMessage = document.getElementById("login-message");
const loginSection = document.getElementById("login");
const dashboard = document.getElementById("dashboard");
const logoutButton = document.getElementById("logout-button");
const statusElement = document.getElementById("recommendation-status");
const listElement = document.getElementById("recommendation-list");
const waiverStatus = document.getElementById("waiver-status");
const waiverList = document.getElementById("waiver-list");
const passwordField = document.getElementById("password");

// Sitzungsdaten bleiben innerhalb dieser Datei
let accessToken = null;
let sessionVersion = 0;
let activeRequest = null;

// Dashboard zu Beginn ausblenden
dashboard.hidden = true;
dashboard.style.display = "none";

// Empfehlungen anzeigen
function showRecommendations(recommendations) {
  listElement.replaceChildren();

    const items = (recommendations.recommendations ?? []).filter(
    (item) => {
      const gain = Number(item.erwarteter_punktegewinn);

      return (
        item.erwarteter_punktegewinn != null &&
        Number.isFinite(gain) &&
        gain >= 3 &&
        item.bewertung !== "NICHT_EMPFEHLEN"
      );
    }
  );

  const count = items.length;

  statusElement.textContent =
    `NFL-Woche ${recommendations.week}: ` +
    `${count} Empfehlung(en)`;

  if (items.length === 0) {
    const message = document.createElement("p");
    message.textContent =
      "Aktuell keine Aufstellungsverbesserung gefunden.";
    listElement.appendChild(message);
    return;
  }

  for (const item of items) {
    const card = document.createElement("div");
    card.style.padding = "12px";
    card.style.marginTop = "12px";
    card.style.borderRadius = "8px";
    card.style.background = "#172338";

    const title = document.createElement("h3");
    title.textContent =
      `${item.bankspieler} statt ${item.starter}`;

    const position = document.createElement("p");
    position.textContent =
      `Position: ${item.zielposition}`;

    const gain = Number(item.erwarteter_punktegewinn);

    const points = document.createElement("p");
    points.textContent = Number.isFinite(gain)
      ? `Erwarteter Punktegewinn: +${gain.toFixed(2)}`
      : "Erwarteter Punktegewinn: Nicht verfügbar";

    const injury = document.createElement("p");
    injury.textContent =
      `Verletzungsstatus: ` +
      `${item.bank_verletzungsstatus ?? "Unbekannt"} ` +
      `/ ${item.starter_verletzungsstatus ?? "Unbekannt"}`;

    const assessment = document.createElement("p");

    if (!Number.isFinite(gain)) {
      assessment.textContent =
        "Bewertung: Prognose nicht verfügbar.";
    } else if (gain < 1) {
      assessment.textContent =
        "Bewertung: Sehr knapper Prognosevorteil – " +
        "kein dringender Wechsel.";
    } else if (gain < 3) {
      assessment.textContent =
        "Bewertung: Mögliche Aufstellungsverbesserung.";
    } else {
      assessment.textContent =
        "Bewertung: Deutlicher Prognosevorteil.";
    }

    card.append(
      title,
      position,
      points,
      injury,
      assessment
    );

    listElement.appendChild(card);
  }
}

const waiverPoints = new Intl.NumberFormat("de-DE", {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
});

async function loadWaivers(currentSession, signal) {
  if (!waiverStatus || !waiverList) return;
  waiverStatus.textContent = "Waiver-Liste wird geladen …";
  waiverList.replaceChildren();

  try {
    const response = await fetch(
      `${SUPABASE_URL}/functions/v1/fantasy-waiver-view`,
      {
        method: "POST",
        headers: {
          "apikey": SUPABASE_KEY,
          "Authorization": `Bearer ${accessToken}`,
        },
        signal,
      }
    );
    if (!response.ok) throw new Error(`HTTP ${response.status}`);

    const data = await response.json();
    if (currentSession !== sessionVersion) return;
    if (data.status === "unassigned") {
      waiverStatus.textContent = "Für dieses Konto ist noch kein ESPN-Team zugeordnet.";
      return;
    }
    if (data.status === "no_snapshot") {
      waiverStatus.textContent = "Für dein Team liegt noch kein ESPN-Import vor.";
      return;
    }
    if (data.status !== "ready") throw new Error("Unbekannter Waiver-Status");

    const importedAt = new Intl.DateTimeFormat("de-DE", {
      dateStyle: "medium",
      timeStyle: "short",
    }).format(new Date(data.captured_at));

    const summary = `${data.team_name} · ESPN-Woche ${data.week} · Import vom ${importedAt}`;
    if (data.roster_player_count === 0) {
      waiverStatus.textContent = `${summary}. Für diese Woche fehlen Kaderdaten.`;
      return;
    }

    const count = data.candidates.length;
    waiverStatus.textContent = `${summary}. ${count === 0
      ? "Keine passenden Kandidaten im importierten Spielerpool."
      : `${count} von ${data.source_player_count} importierten Spielern passen zum Kadervergleich.`}`;

    for (const candidate of data.candidates) {
      const item = document.createElement("li");
      const name = document.createElement("strong");
      name.textContent = `${candidate.name} · ${candidate.position}`;
      const availability = document.createElement("p");
      availability.textContent = candidate.fantasy_status === "WAIVERS"
        ? "Auf Waivers beim Import"
        : "Free Agent beim Import";
      const comparison = document.createElement("p");
      comparison.textContent =
        `${waiverPoints.format(candidate.projected_points)} prognostizierte Punkte · ` +
        `Kadervergleich ${waiverPoints.format(candidate.lowest_roster_projection)} · ` +
        `+${waiverPoints.format(candidate.projection_delta)} Punkte`;
      item.append(name, availability, comparison);
      waiverList.appendChild(item);
    }
  } catch {
    if (currentSession !== sessionVersion) return;
    waiverList.replaceChildren();
    waiverStatus.textContent = "Waiver-Liste konnte nicht geladen werden.";
  }
}

// Anmeldung über Supabase Auth
async function login(email, password) {
  const currentSession = ++sessionVersion;

  loginMessage.textContent = "Anmeldung läuft ...";

  try {
    const response = await fetch(
      `${SUPABASE_URL}/auth/v1/token?grant_type=password`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "apikey": SUPABASE_KEY
        },
        body: JSON.stringify({ email, password })
      }
    );

    const data = await response.json();

    // Veraltete Anmeldeantwort ignorieren
    if (currentSession !== sessionVersion) return;

    if (!response.ok || !data.access_token) {
      loginMessage.textContent =
        "Anmeldung fehlgeschlagen. Bitte Zugangsdaten prüfen.";
      return;
    }

    accessToken = data.access_token;
    passwordField.value = "";

    // Empfehlungen abrufen, bevor das Dashboard erscheint
    loginMessage.textContent =
      "Anmeldung erfolgreich. Empfehlungen werden geladen ...";

    const controller = new AbortController();
    activeRequest = controller;

    const recommendationResponse = await fetch(
      `${SUPABASE_URL}/functions/v1/fantasy-recommendations`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "apikey": SUPABASE_KEY,
          "Authorization": `Bearer ${accessToken}`
        },
        body: JSON.stringify({}),
        signal: controller.signal
      }
    );

    if (currentSession !== sessionVersion) return;

    if (!recommendationResponse.ok) {
      throw new Error(
        `HTTP ${recommendationResponse.status}`
      );
    }

    const recommendations =
      await recommendationResponse.json();

    if (currentSession !== sessionVersion) return;

    if (!recommendations.success) {
      throw new Error("Keine gültige Antwort erhalten");
    }

    showRecommendations(recommendations);

    // Dashboard erst nach erfolgreicher Prüfung anzeigen
    loginSection.hidden = true;
    loginSection.style.display = "none";

    dashboard.hidden = false;
    dashboard.style.display = "block";

    loginMessage.textContent =
      "Empfehlungen erfolgreich geladen";

    await loadWaivers(currentSession, controller.signal);

  } catch (error) {
    if (currentSession !== sessionVersion) return;

    console.error("Fantasy AI Fehler:", error);

    accessToken = null;
    loginMessage.textContent =
      "Anmeldung oder Laden der Empfehlungen fehlgeschlagen.";

  } finally {
    if (currentSession === sessionVersion) {
      activeRequest = null;
    }
  }
}

// Anmeldebutton aktivieren
loginForm.addEventListener("submit", async (event) => {
  event.preventDefault();

  const email = document.getElementById("email").value;
  const password = passwordField.value;

  await login(email, password);
});

// Abmeldung
logoutButton.addEventListener("click", () => {
  // Laufende Anfragen ungültig machen
  sessionVersion++;

  if (activeRequest) {
    activeRequest.abort();
    activeRequest = null;
  }

  // Zugriffstoken aus dem Arbeitsspeicher entfernen
  accessToken = null;

  // Dashboard ausblenden
  dashboard.hidden = true;
  dashboard.style.display = "none";

  // Anmeldemaske anzeigen
  loginSection.hidden = false;
  loginSection.style.display = "block";

  passwordField.value = "";

  // Alte Empfehlungen entfernen
  listElement.replaceChildren();
  statusElement.textContent = "";
  waiverList?.replaceChildren();
  if (waiverStatus) waiverStatus.textContent = "";

  loginMessage.textContent =
    "Erfolgreich abgemeldet.";

  console.log("Fantasy Football AI: Abgemeldet");
});

console.log("Fantasy Football AI gestartet");
