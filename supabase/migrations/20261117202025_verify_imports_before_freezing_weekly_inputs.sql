create table fantasy_forecast.weekly_import_requests (
  league_id bigint not null,
  season integer not null,
  week integer not null,
  endpoint text not null,
  request_id bigint not null unique,
  requested_at timestamptz not null,
  succeeded_at timestamptz,
  last_error text,
  primary key (league_id, season, week, endpoint)
);
alter table fantasy_forecast.weekly_import_requests enable row level security;
revoke all on fantasy_forecast.weekly_import_requests from public, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION fantasy_forecast.prepare_weekly_inputs()
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  observed_at timestamptz := clock_timestamp();
  target_league bigint;
  target_week integer;
  kickoff timestamptz;
  waiver_data jsonb;
  waiver_time timestamptz;
  cron_key text;
  inserted integer;
  import_step text;
  task fantasy_forecast.weekly_import_requests%rowtype;
  response record;
  payload jsonb;
  request_body jsonb;
  queued_id bigint;
  pending_steps text[] := '{}';
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

  select max(decrypted_secret) into cron_key from vault.decrypted_secrets
  where name = 'fantasy_cron_api_key' having count(*) = 1;
  if cron_key is null then return 'import_key_missing'; end if;

  foreach import_step in array array['espn-import', 'espn-stats-import', 'espn-injury-import', 'espn-free-agent-import']
  loop
    select * into task from fantasy_forecast.weekly_import_requests r
    where r.league_id = target_league and r.season = 2026 and r.week = target_week and r.endpoint = import_step;
    if task.succeeded_at is not null then continue; end if;

    if task.request_id is not null then
      select status_code, timed_out, error_msg, content, created into response
      from net._http_response where id = task.request_id;

      if found then
        payload := case when pg_input_is_valid(response.content, 'jsonb') then response.content::jsonb end;
        if response.status_code between 200 and 299 and payload->'ok' = 'true'::jsonb
          and (case import_step
            when 'espn-import' then payload->>'week' = target_week::text
              and payload->>'teams_found' = '6'
            when 'espn-stats-import' then payload->>'current_espn_week' = target_week::text
              and payload->>'missing_players' = '0'
            when 'espn-injury-import' then payload->>'week' = target_week::text
              and payload->>'matched_players' = payload->>'roster_players_found'
            else payload->>'week' = target_week::text
          end) then
          update fantasy_forecast.weekly_import_requests r
          set succeeded_at = response.created
          where r.request_id = task.request_id;
          continue;
        end if;
        update fantasy_forecast.weekly_import_requests r
        set last_error = left(concat_ws(' ', 'HTTP', response.status_code,
          response.error_msg, payload->>'message', payload->>'error'), 300)
        where r.request_id = task.request_id;
      elsif observed_at - task.requested_at < interval '2 minutes' then
        pending_steps := array_append(pending_steps, import_step);
        if import_step = 'espn-import' then exit; end if;
        continue;
      end if;
    end if;

    pending_steps := array_append(pending_steps, import_step);
    if kickoff - observed_at > interval '3 minutes' then
      request_body := jsonb_build_object('expected_week', target_week, 'confirm', true);
      if import_step = 'espn-free-agent-import' then
        request_body := request_body || '{"action":"import"}'::jsonb;
      end if;
      queued_id := net.http_post(
        url := 'https://uzifirhbzrwmxlxgwjss.supabase.co/functions/v1/' || import_step,
        body := request_body,
        headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', cron_key),
        timeout_milliseconds := 60000
      );
      insert into fantasy_forecast.weekly_import_requests as r
        (league_id, season, week, endpoint, request_id, requested_at)
      values (target_league, 2026, target_week, import_step, queued_id, observed_at)
      on conflict (league_id, season, week, endpoint) do update
      set request_id = excluded.request_id, requested_at = excluded.requested_at;
    end if;
    if import_step = 'espn-import' then exit; end if;
  end loop;

  if cardinality(pending_steps) > 0 then
    return 'awaiting_imports: ' || array_to_string(pending_steps, ', ');
  end if;
  if kickoff - observed_at > interval '45 minutes' then return 'waiting_to_capture'; end if;

  select players, captured_at into waiver_data, waiver_time
  from public.espn_free_agent_snapshots
  where league_id = target_league and season = 2026 and week = target_week
    and captured_at between kickoff - interval '2 hours' and observed_at;
  if (case when jsonb_typeof(waiver_data) = 'array' then jsonb_array_length(waiver_data) = 0 else true end) then
    return 'waiver_data_missing';
  end if;

  with roster as (
    select r.team_id, r.player_id, r.roster_slot, r.is_injured_reserve,
      p.espn_player_id, p.position, p.nfl_team, p.espn_eligible_slots
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
      and p.updated_at >= (select requested_at from fantasy_forecast.weekly_import_requests
        where league_id = target_league and season = 2026 and week = target_week and endpoint = 'espn-stats-import')
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
    'games', (select jsonb_agg(jsonb_build_object('home_team', g.home_team,
      'away_team', g.away_team, 'kickoff_at', g.kickoff_at) order by g.kickoff_at, g.id)
      from public.nfl_games g where g.season = 2026 and g.week = target_week),
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
    and (select count(distinct team_id) from roster) = 6
    and (select count(distinct r.team_id) from roster r join projections p using (player_id)) = 6
  on conflict (league_id, season, week) do nothing;

  get diagnostics inserted = row_count;
  if inserted = 0 then return 'coverage_incomplete_or_kickoff_passed'; end if;
  return 'captured';
end;
$function$
;
revoke all on function fantasy_forecast.prepare_weekly_inputs() from public, anon, authenticated, service_role;

do $migration$
declare
  job record;
begin
  for job in
    select jobid, command from cron.job
    where jobname in ('fantasy-injury-import-daily', 'fantasy-stats-import-daily', 'fantasy-roster-import-daily')
  loop
    perform cron.alter_job(job.jobid, command := replace(job.command,
      'body := ''{"confirm":true}''::jsonb', 'body := ''{"confirm":true}''::jsonb, timeout_milliseconds := 60000'));
  end loop;
end;
$migration$;