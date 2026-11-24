"use strict";

// Fantasy Football AI – Supabase-Konfiguration
const SUPABASE_URL =
  "https://uzifirhbzrwmxlxgwjss.supabase.co";

// Hier deinen bisherigen öffentlichen Publishable Key eintragen
const SUPABASE_KEY = "sb_publishable_pDEOZqKyCI4rRV6FLbq25Q_83wNcA23";

// Elemente unserer App
const isDemo = new URLSearchParams(location.search).get("demo") === "1";
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

const pages = [...dashboard.querySelectorAll("[data-page]")];
const navigation = [...dashboard.querySelectorAll("[data-page-link]")];
const filters = document.getElementById("waiver-filters");
const waiverEmpty = document.getElementById("waiver-empty");
const lineupForecasts = document.getElementById("lineup-forecasts");
const waiverForecasts = document.getElementById("waiver-forecasts");
const waiverForecastStatus = document.getElementById("waiver-forecast-status");
const weeklyInputsStatus = document.getElementById("weekly-inputs-status");
const weeklyInputsCoverage = document.getElementById("weekly-inputs-coverage");
const weeklyPlayerForecasts = document.getElementById("weekly-player-forecasts");
const weeklyPlayerForecastsTitle = document.getElementById("weekly-player-forecasts-title");
const liveForecastStatus = document.getElementById("live-forecast-status");
const livePlayerForecasts = document.getElementById("live-player-forecasts");
const aiReviewStatus = document.getElementById("ai-review-status");
const aiReviewResults = document.getElementById("ai-review-results");
const dashboardWeek = document.getElementById("dashboard-week");
const heroPlayer = document.getElementById("hero-player");
const heroDetail = document.getElementById("hero-detail");
const heroPhoto = document.getElementById("hero-photo");
const heroMetric = document.getElementById("hero-metric");
const heroGain = document.getElementById("hero-gain");

const points = new Intl.NumberFormat("de-DE", {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
});
const signedPoints = new Intl.NumberFormat("de-DE", {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
  signDisplay: "exceptZero",
});

function createElement(tag, value, className) {
  const element = document.createElement(tag);
  if (value != null) element.textContent = value;
  if (className) element.className = className;
  return element;
}

function showPage(focusHeading = false) {
  const requested = location.hash.slice(1);
  const selected = pages.find(page => page.dataset.page === requested) ?? pages[0];

  for (const page of pages) page.hidden = page !== selected;
  for (const link of navigation) {
    if (link.dataset.pageLink === selected.dataset.page) {
      link.setAttribute("aria-current", "page");
    } else {
      link.removeAttribute("aria-current");
    }
  }
  if (focusHeading && !dashboard.hidden) {
    window.scrollTo(0, 0);
    selected.querySelector("h1").focus({ preventScroll: true });
  }
}

window.addEventListener("hashchange", () => showPage(true));

function showHero(item) {
  heroPlayer.textContent = item?.bankspieler ?? "Aufstellung beibehalten";
  heroDetail.textContent = item
    ? `${item.zielposition} · Statt ${item.starter}. Laut ESPN-Prognose bringt der Wechsel mehr Punkte.`
    : "Die aktuellen Prognosen ergeben keinen Wechsel, der die Aufstellung klar verbessert.";
  heroGain.textContent = item ? signedPoints.format(item.erwarteter_punktegewinn) : "";
  heroMetric.hidden = !item;

  heroPhoto.hidden = true;
  heroPhoto.removeAttribute("src");
  if (!isDemo && item?.bankspieler === "Jahmyr Gibbs") {
    heroPhoto.src = "https://a.espncdn.com/i/headshots/nfl/players/full/4429795.png";
    heroPhoto.hidden = false;
  }
}

heroPhoto.addEventListener("error", () => { heroPhoto.hidden = true; });

function appendForecast(list, name, value, detail) {
  const row = createElement("li");
  const top = createElement("div", null, "row-top");
  top.append(createElement("strong", name), createElement("span", value, "row-gain"));
  row.append(top, createElement("p", detail, "row-detail"));
  list.append(row);
}

function showRecommendations(recommendations) {
  listElement.replaceChildren();
  lineupForecasts.replaceChildren();

  const items = (recommendations.recommendations ?? [])
    .filter(item => Number.isFinite(Number(item.erwarteter_punktegewinn)) &&
      Number(item.erwarteter_punktegewinn) >= 3 &&
      item.bewertung !== "NICHT_EMPFEHLEN")
    .sort((a, b) => Number(b.erwarteter_punktegewinn) - Number(a.erwarteter_punktegewinn));

  const week = `NFL-Woche ${recommendations.week}`;
  dashboardWeek.textContent = week;
  statusElement.textContent = `${week} · ${items.length === 1 ? "1 Wechselvorschlag" : `${items.length} Wechselvorschläge`}`;
  showHero(items[0]);

  if (items.length === 0) {
    listElement.append(createElement("p", "Aktuell keine Aufstellungsverbesserung gefunden.", "panel muted"));
    lineupForecasts.append(createElement("li", "Aktuell gibt es keine Wechselvorschläge.", "muted"));
    return;
  }

  const positionLists = new Map();
  for (const item of items) {
    const position = item.zielposition;
    if (!positionLists.has(position)) {
      const group = createElement("section");
      const list = createElement("ul", null, "stack data-list");
      group.append(createElement("h2", position, "position-title"), list);
      listElement.append(group);
      positionLists.set(position, list);
    }

    const card = createElement("li", null, "panel");
    const title = `${item.bankspieler} statt ${item.starter}`;
    const change = `${signedPoints.format(item.erwarteter_punktegewinn)} Pkt.`;
    const top = createElement("div", null, "row-top");
    top.append(createElement("h3", title), createElement("span", change, "row-gain"));
    const injury = `Verletzungsstatus · ${item.bankspieler}: ${item.bank_verletzungsstatus ?? "Unbekannt"} · ${item.starter}: ${item.starter_verletzungsstatus ?? "Unbekannt"}`;
    card.append(top, createElement("p", injury, "row-detail"));
    positionLists.get(position).append(card);
    appendForecast(lineupForecasts, title, change, position);
  }
}

function setWaiverFilter(availability) {
  for (const button of filters.querySelectorAll("button")) {
    button.setAttribute("aria-pressed", String(button.dataset.availability === availability));
  }
  const rows = [...waiverList.children];
  for (const item of rows) {
    item.hidden = availability !== "all" && item.dataset.status !== availability;
  }
  waiverEmpty.hidden = rows.length === 0 || rows.some(item => !item.hidden);
}

filters.addEventListener("click", event => {
  const button = event.target.closest("button[data-availability]");
  if (button) setWaiverFilter(button.dataset.availability);
});

function setWaiverStatus(message, forecastMessage = message) {
  waiverStatus.textContent = message;
  waiverForecastStatus.textContent = forecastMessage;
}

function showWeeklyInputs(snapshot, message = "Für dein Team liegt noch kein Wochenstand vor Kickoff vor.") {
  weeklyPlayerForecasts.replaceChildren();
  weeklyPlayerForecasts.hidden = true;
  weeklyPlayerForecastsTitle.hidden = true;
  weeklyInputsCoverage.hidden = true;
  weeklyInputsCoverage.textContent = "";
  if (!snapshot) {
    weeklyInputsStatus.textContent = message;
    return;
  }

  const dateTime = new Intl.DateTimeFormat("de-DE", {
    dateStyle: "short",
    timeStyle: "short",
    timeZone: "Europe/Berlin",
  });
  const capturedAt = dateTime.format(new Date(snapshot.captured_at));
  const firstKickoff = dateTime.format(new Date(snapshot.first_kickoff));
  weeklyInputsStatus.textContent =
    `NFL-Woche ${snapshot.week} · gespeichert am ${capturedAt} Uhr · erster Kickoff am ${firstKickoff} Uhr`;
  weeklyInputsCoverage.textContent =
    `Teamkader: ${snapshot.roster_players} Spieler · ${snapshot.espn_projections} ESPN-Prognosen · ${snapshot.waiver_players} Spieler im Free-Agent-/Waiver-Pool`;
  weeklyInputsCoverage.hidden = false;
  const forecasts = snapshot.player_forecasts ?? [];
  for (const player of forecasts) {
    const pointsLabel = player.projected_points == null
      ? "Keine Prognose"
      : `${points.format(player.projected_points)} Pkt.`;
    const detail = player.position && player.roster_slot && player.position !== player.roster_slot
      ? `${player.position} · Kaderplatz ${player.roster_slot}`
      : player.position ?? player.roster_slot ?? "";
    appendForecast(weeklyPlayerForecasts, player.name, pointsLabel, detail);
  }
  weeklyPlayerForecasts.hidden = forecasts.length === 0;
  weeklyPlayerForecastsTitle.hidden = forecasts.length === 0;
}

function showLiveForecasts(snapshot, message = "Für dein Team liegen keine aktuellen ESPN-Prognosen vor.") {
  livePlayerForecasts.replaceChildren();
  liveForecastStatus.textContent = message;
  if (!snapshot?.projections_at) return;

  const date = new Intl.DateTimeFormat("de-DE", {
    dateStyle: "short", timeStyle: "short", timeZone: "Europe/Berlin",
  });
  liveForecastStatus.textContent =
    `NFL-Woche ${snapshot.week} · Letzter Prognoseimport: ${date.format(new Date(snapshot.projections_at))} Uhr`;

  const asOf = isDemo ? Date.parse(snapshot.projections_at) : Date.now();
  for (const player of snapshot.player_forecasts) {
    const kickoff = player.kickoff_at ? new Date(player.kickoff_at) : null;
    const game = !kickoff ? "Kickoff nicht zugeordnet"
      : kickoff.getTime() <= asOf ? "Kickoff vorbei · gesperrt" : `Kickoff ${date.format(kickoff)} Uhr`;
    const detail = [player.roster_slot, player.injury_status, game].filter(Boolean).join(" · ");
    const value = player.projected_points == null ? "Keine Prognose" : `${points.format(player.projected_points)} Pkt.`;
    appendForecast(livePlayerForecasts, player.name, value, detail);
  }
}

function showAiReview(review, message = "Für dein Team liegt noch kein Testergebnis vor.") {
  aiReviewResults.replaceChildren();
  aiReviewStatus.textContent = message;
  if (!review) return;
  aiReviewStatus.textContent = `Historischer Test mit dem Wochenstand vor Kickoff · NFL-Woche ${review.week}`;
  for (const [title, result] of [["Aufstellung", review.lineup], ["Free Agents & Waiver", review.waiver]]) {
    if (typeof result !== "string") continue;
    const item = document.createElement("li");
    item.append(createElement("strong", title), createElement("p", result, "row-detail"));
    aiReviewResults.append(item);
  }
}

async function loadWaivers(currentSession, signal) {
  showAiReview(null, "Testergebnis wird geladen …");
  showLiveForecasts(null, "Prognosen werden geladen …");
  showWeeklyInputs(null, "Wochenstand wird geladen …");
  setWaiverStatus("Spielerpool wird geladen …");
  waiverList.replaceChildren();
  waiverForecasts.replaceChildren();
  filters.hidden = true;
  setWaiverFilter("all");

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
    renderWaiverDashboard(data);
  } catch {
    if (currentSession !== sessionVersion) return;
    waiverList.replaceChildren();
    waiverForecasts.replaceChildren();
    filters.hidden = true;
    setWaiverStatus("Spielerpool konnte nicht geladen werden.");
    showWeeklyInputs(null, "Wochenstand konnte nicht geladen werden.");
    showLiveForecasts(null, "Prognosen konnten nicht geladen werden.");
    showAiReview(null, "Testergebnis konnte nicht geladen werden.");
  }
}

function renderWaiverDashboard(data) {
  showWeeklyInputs(data.weekly_inputs);
  showLiveForecasts(data.current_forecasts);
  showAiReview(data.ai_review);
  if (data.status === "unassigned") {
    setWaiverStatus("Für dieses Konto ist noch kein ESPN-Team zugeordnet.");
    return;
  }
  if (data.status === "no_snapshot") {
    setWaiverStatus("Für dein Team liegt noch kein ESPN-Import vor.");
    return;
  }
  if (data.status !== "ready") throw new Error("Unbekannter Waiver-Status");

  const importedAt = new Intl.DateTimeFormat("de-DE", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(data.captured_at));

  const summary = `${data.team_name} · ESPN-Woche ${data.week} · Import vom ${importedAt}`;
  if (data.roster_player_count === 0) {
    setWaiverStatus(`${summary}. Für diese Woche fehlen Kaderdaten.`);
    return;
  }

  const count = data.candidates.length;
  const detail = count === 0
    ? "Keine passenden Kandidaten im importierten Spielerpool."
    : `${count} von ${data.source_player_count} importierten Spielern passen zum Kadervergleich.`;
  setWaiverStatus(`${summary}. ${detail}`, count === 0 ? `${summary}. ${detail}` : summary);

  for (const candidate of data.candidates) {
    const item = createElement("li", null, "panel");
    const name = `${candidate.name} · ${candidate.position}`;
    const top = createElement("div", null, "row-top");
    const availability = candidate.fantasy_status === "WAIVERS" ? "Waiver-Claim nötig"
      : candidate.fantasy_status === "FREEAGENT" ? "Sofort verfügbar" : "Verfügbarkeit unbekannt";
    const badge = createElement("span", availability, "availability");
    item.dataset.status = badge.dataset.status = candidate.fantasy_status ?? "unknown";
    top.append(createElement("h3", name), badge);
    const prediction = `${points.format(candidate.projected_points)} Pkt.`;
    const comparison = `Kadervergleich ${points.format(candidate.lowest_roster_projection)} Pkt. · ${signedPoints.format(candidate.projection_delta)} Pkt.`;
    item.append(top, createElement("p", `${prediction} prognostiziert · ${comparison}`, "row-detail"));
    waiverList.append(item);
    appendForecast(waiverForecasts, name, prediction, comparison);
  }
  filters.hidden = count === 0;
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

    dashboard.hidden = false;
    logoutButton.hidden = false;
    showPage(true);

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
  logoutButton.hidden = true;

  // Anmeldemaske anzeigen
  loginSection.hidden = false;
  document.getElementById("email").focus();

  passwordField.value = "";

  // Alte Empfehlungen entfernen
  listElement.replaceChildren();
  statusElement.textContent = "";
  waiverList?.replaceChildren();
  lineupForecasts.replaceChildren();
  waiverForecasts.replaceChildren();
  setWaiverStatus("");
  showAiReview(null, "Testergebnis wird geladen …");
  showLiveForecasts(null, "Prognosen werden geladen …");
  showWeeklyInputs(null, "Wochenstand wird geladen …");
  showHero(null);

  loginMessage.textContent =
    "Erfolgreich abgemeldet.";

  console.log("Fantasy Football AI: Abgemeldet");
});

if (isDemo && typeof fantasyDemoData !== "undefined") {
  loginSection.hidden = true;
  dashboard.hidden = false;
  document.getElementById("demo-notice").hidden = false;
  document.getElementById("demo-exit").hidden = false;
  showRecommendations(fantasyDemoData.recommendations);
  renderWaiverDashboard(fantasyDemoData.waivers);
  showPage(true);
}

console.log("Fantasy Football AI gestartet");
