create schema fantasy_forecast;
revoke all on schema fantasy_forecast from public, anon, authenticated;

create table fantasy_forecast.weekly_inputs (
  league_id bigint not null,
  season integer not null,
  week integer not null,
  captured_at timestamptz not null,
  first_kickoff timestamptz not null,
  inputs jsonb not null,
  primary key (league_id, season, week),
  check (captured_at < first_kickoff)
);

alter table fantasy_forecast.weekly_inputs enable row level security;
revoke all on table fantasy_forecast.weekly_inputs from public, anon, authenticated, service_role;

create function fantasy_forecast.prepare_weekly_inputs()
returns text
language plpgsql
security invoker
set search_path = ''
as $$
declare
  observed_at timestamptz := clock_timestamp();
  target_league bigint;
  target_week integer;
  kickoff timestamptz;
  waiver_data jsonb;
  waiver_time timestamptz;
  cron_key text;
  inserted integer;
begin
  if not pg_try_advisory_xact_lock(2026, 101) then
    return 'already_running';
  end if;

  select min(id) into target_league from public.leagues where season = 2026
  having count(*) = 1;
  if target_league is null then return 'league_not_configured'; end if;

  select g.week, min(g.kickoff_at) into target_week, kickoff
  from public.nfl_games g
  where g.season = 2026
  group by g.week
  having count(*) = count(g.kickoff_at)
    and min(g.kickoff_at) > observed_at
    and min(g.kickoff_at) <= observed_at + interval '2 hours'
  order by min(g.kickoff_at)
  limit 1;
  if target_week is null then return 'outside_capture_window'; end if;

  if exists (
    select 1 from fantasy_forecast.weekly_inputs
    where league_id = target_league and season = 2026 and week = target_week
  ) then return 'already_captured'; end if;

  select players, captured_at into waiver_data, waiver_time
  from public.espn_free_agent_snapshots
  where league_id = target_league and season = 2026 and week = target_week
    and captured_at between kickoff - interval '2 hours' and observed_at;

  if kickoff - observed_at > interval '45 minutes'
    or (waiver_data is null and kickoff - observed_at > interval '15 minutes') then
    if waiver_data is not null then return 'waiting_to_capture'; end if;

    select max(decrypted_secret) into cron_key from vault.decrypted_secrets
    where name = 'fantasy_cron_api_key' having count(*) = 1;
    if cron_key is null then return 'waiver_key_missing'; end if;

    perform net.http_post(
      url := 'https://uzifirhbzrwmxlxgwjss.supabase.co/functions/v1/espn-free-agent-import',
      body := jsonb_build_object('action', 'import', 'expected_week', target_week),
      headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', cron_key),
      timeout_milliseconds := 25000
    );
    return 'waiver_refresh_requested';
  end if;

  with roster as (
    select r.team_id, r.player_id, r.roster_slot, r.is_injured_reserve,
      p.espn_player_id, p.position, p.nfl_team
    from public.roster_entries r
    join public.teams t on t.id = r.team_id
    join public.players p on p.id = r.player_id
    where t.league_id = target_league and r.season = 2026 and r.week = target_week
  ),
  projections as (
    select distinct on (p.player_id)
      p.player_id, p.projected_points, p.updated_at
    from public.projections p
    join (select distinct player_id from roster) r using (player_id)
    where p.season = 2026 and p.week = target_week and p.source = 'espn_projection'
      and p.projected_points is not null and p.updated_at <= observed_at
    order by p.player_id, p.updated_at desc, p.id desc
  ),
  injuries as (
    select distinct on (i.player_id)
      i.player_id, i.status, i.injury, i.report_time
    from public.injury_reports i
    join (select distinct player_id from roster) r using (player_id)
    where i.report_time between observed_at - interval '7 days' and observed_at
    order by i.player_id, i.report_time desc, i.id desc
  )
  insert into fantasy_forecast.weekly_inputs
    (league_id, season, week, captured_at, first_kickoff, inputs)
  select target_league, 2026, target_week, observed_at, kickoff, jsonb_build_object(
    'roster', coalesce((select jsonb_agg(to_jsonb(r) order by team_id, player_id) from roster r), '[]'::jsonb),
    'espn_projections', coalesce((select jsonb_agg(to_jsonb(p) order by player_id) from projections p), '[]'::jsonb),
    'injuries', coalesce((select jsonb_agg(to_jsonb(i) order by player_id) from injuries i), '[]'::jsonb),
    'waiver_players', waiver_data,
    'waiver_captured_at', waiver_time,
    'coverage', jsonb_build_object(
      'league_teams', (select count(*) from public.teams where league_id = target_league),
      'teams_with_roster', (select count(distinct team_id) from roster),
      'roster_players', (select count(distinct player_id) from roster),
      'players_with_espn_projection', (select count(*) from projections),
      'players_with_injury_report', (select count(*) from injuries),
      'waiver_players', jsonb_array_length(waiver_data)
    )
  )
  where clock_timestamp() < kickoff
  on conflict (league_id, season, week) do nothing;

  get diagnostics inserted = row_count;
  if inserted = 0 then return 'capture_skipped'; end if;
  return 'captured';
end;
$$;

revoke all on function fantasy_forecast.prepare_weekly_inputs()
  from public, anon, authenticated, service_role;

select cron.schedule(
  'fantasy-freeze-weekly-inputs',
  '*/10 * * * *',
  $job$select fantasy_forecast.prepare_weekly_inputs();$job$
);
