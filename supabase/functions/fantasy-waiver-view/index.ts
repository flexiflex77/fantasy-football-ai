import { withSupabase } from "npm:@supabase/server@1";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Cache-Control": "no-store",
};

const loadWaivers = withSupabase({ auth: "user" }, async (_request, context) => {
  const { data, error } = await context.supabaseAdmin.rpc("get_fantasy_waiver_view", {
    requesting_user: context.userClaims.sub,
    requested_season: 2026,
  });

  if (error) {
    console.error("Waiver view lookup failed", error.code);
    return Response.json({ error: "Waiver-Liste konnte nicht geladen werden." }, { status: 500 });
  }
  return Response.json(data);
});

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (request.method !== "POST") {
    return Response.json({ error: "Nur POST erlaubt." }, {
      status: 405,
      headers: { ...cors, Allow: "POST, OPTIONS" },
    });
  }

  const response = await loadWaivers(request);
  const headers = new Headers(response.headers);
  for (const [key, value] of Object.entries(cors)) headers.set(key, value);
  return new Response(response.body, { status: response.status, headers });
});
