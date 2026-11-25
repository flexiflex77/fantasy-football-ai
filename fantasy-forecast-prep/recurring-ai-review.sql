create function fantasy_forecast.flex_ai_candidates(target_week integer, at_time timestamptz)
returns jsonb language sql stable set search_path = '' as $function$
with schedule as (
  select team, min(kickoff_at) kickoff from public.nfl_games
  cross join lateral unnest(array[home_team, away_team]) as nfl(team)
  where season=2026 and week=target_week and kickoff_at is not null group by team
), slots(label, code) as (
  values ('QB',0),('RB',2),('WR',4),('TE',6),('DT',8),('DE',9),('LB',10),
    ('DB',12),('CB',13),('K',17),('P',18),('HC',19)
), roster as (
  select p.id, p.full_name name, r.roster_slot slot, p.espn_eligible_slots eligibility,
    pr.projected_points points, g.kickoff, coalesce(injury.status,'UNKNOWN') status
  from public.roster_entries r join public.players p on p.id=r.player_id
  join schedule g on g.team = case p.nfl_team when 'LA' then 'LAR' when 'JAC' then 'JAX' when 'WSH' then 'WAS' else p.nfl_team end
  join public.projections pr on pr.player_id=p.id and pr.season=2026 and pr.week=target_week and pr.source='espn_projection'
  left join lateral (select i.status from public.injury_reports i where i.player_id=p.id and i.report_time<=at_time order by i.report_time desc,i.id desc limit 1) injury on true
  where r.team_id=2 and r.season=2026 and r.week=target_week and not r.is_injured_reserve
    and g.kickoff > at_time and pr.projected_points is not null
), lineup as (
  select a.name incoming,b.name outgoing,b.slot,a.status incoming_status,b.status outgoing_status,
    round(a.points::numeric,2) incoming_points,round(b.points::numeric,2) outgoing_points,
    round((a.points-b.points)::numeric,2) gain,least(a.kickoff,b.kickoff) before
  from roster a join roster b on a.slot='BE'
  join slots on slots.label=b.slot and a.eligibility @> jsonb_build_array(slots.code)
  where upper(a.status) not in ('OUT','IR','INJURED_RESERVE','DOUBTFUL','SUSPENDED','PUP')
    and (a.points>b.points or upper(b.status) in ('OUT','IR','INJURED_RESERVE','DOUBTFUL','SUSPENDED','PUP'))
  order by case when upper(b.status) in ('OUT','IR','INJURED_RESERVE','DOUBTFUL','SUSPENDED','PUP') then 0 else 1 end,
    gain desc, incoming, outgoing limit 5
), pool as (
  select x.*,g.kickoff
  from public.espn_free_agent_snapshots s
  cross join lateral jsonb_to_recordset(s.players) x(espn_player_id text,name text,eligible_slots jsonb,nfl_team_id integer,injury_status text,injured boolean,fantasy_status text,projected_points numeric)
  join schedule g on g.team=(array['','ATL','BUF','CHI','CIN','CLE','DAL','DEN','DET','GB','TEN','IND','KC','LV','LAR','MIA','MIN','NE','NO','NYG','NYJ','PHI','ARI','PIT','LAC','SF','SEA','TB','WAS','CAR','JAX','','','BAL','HOU'])[x.nfl_team_id+1]
  where s.league_id=605081630 and s.season=2026 and s.week=target_week
    and g.kickoff>at_time and x.injured is false and upper(x.injury_status)='ACTIVE'
    and x.fantasy_status in ('FREEAGENT','WAIVERS')
    and not exists (select 1 from public.roster_entries r join public.players p on p.id=r.player_id where r.team_id=2 and r.season=2026 and r.week=target_week and p.espn_player_id=x.espn_player_id)
), waiver as (
  select a.name incoming,b.name outgoing,a.injury_status incoming_status,b.status outgoing_status,
    round(a.projected_points,2) incoming_points,round(b.points::numeric,2) outgoing_points,
    round((a.projected_points-b.points)::numeric,2) gain, a.fantasy_status availability, least(a.kickoff,b.kickoff) before
  from pool a join roster b on b.slot='BE' and a.projected_points>b.points
  where exists (select 1 from slots where a.eligible_slots @> jsonb_build_array(code) and b.eligibility @> jsonb_build_array(code))
  order by gain desc,incoming,outgoing limit 5
)
select jsonb_build_object(
 'lineup',coalesce((select jsonb_agg(to_jsonb(l) order by l.gain desc,l.incoming,l.outgoing) from lineup l),'[]'::jsonb),
 'waiver',coalesce((select jsonb_agg(to_jsonb(w) order by w.gain desc,w.incoming,w.outgoing) from waiver w),'[]'::jsonb)
);
$function$;
revoke all on function fantasy_forecast.flex_ai_candidates(integer,timestamptz) from public, anon, authenticated, service_role;
create table fantasy_forecast.ai_review_settings (
  singleton boolean primary key default true check (singleton),
  enabled boolean not null default false,
  monthly_budget_usd numeric(9,4) not null default 0 check (monthly_budget_usd >= 0)
);
insert into fantasy_forecast.ai_review_settings default values;

create table fantasy_forecast.ai_review_runs (
  local_day date primary key,
  week integer not null,
  started_at timestamptz not null,
  candidates jsonb not null,
  stage integer not null default 1 check (stage between 1 and 3),
  status text not null default 'running' check (status in ('running','completed','failed')),
  requests jsonb,
  choices jsonb not null default '{"lineup":[],"waiver":[]}',
  reserved_usd numeric(9,4) not null default 0.02,
  failure text
);
alter table fantasy_forecast.ai_review_settings enable row level security;
alter table fantasy_forecast.ai_review_runs enable row level security;
revoke all on fantasy_forecast.ai_review_settings, fantasy_forecast.ai_review_runs from public, anon, authenticated, service_role;

create function fantasy_forecast.advance_flex_ai_review()
returns text language plpgsql set search_path = '' as $function$
<<review_job>>
declare
  berlin timestamp := clock_timestamp() at time zone 'Europe/Berlin';
  local_day date := berlin::date;
  settings fantasy_forecast.ai_review_settings%rowtype;
  run fantasy_forecast.ai_review_runs%rowtype;
  target_week integer;
  ready_imports integer;
  api_key text;
  phase text;
  response record;
  output jsonb;
  decision jsonb;
  choice integer;
  recommendation jsonb;
  reports jsonb := '{}'::jsonb;
  payload jsonb;
  request_ids jsonb := '{}'::jsonb;
  role_names text[] := array['Analyst','Gegenprüfer','Entscheider'];
  role_tasks text[] := array[
    'Prüfe Chancen und Risiken der Optionen.',
    'Hinterfrage die vorherige Auswahl und prüfe, ob kein Wechsel vorzuziehen ist.',
    'Entscheide unter Berücksichtigung der vorherigen Auswahlen und der Eingabedaten.'
  ];
begin
  if extract(isodow from berlin) not in (4,6)
    or berlin::time < time '17:30' or berlin::time >= time '18:15'
    or local_day < date '2026-11-25' or local_day > date '2027-01-10'
  then return 'outside_review_window'; end if;

  select * into settings from fantasy_forecast.ai_review_settings where singleton;
  if not coalesce(settings.enabled,false) then return 'disabled'; end if;
  if not pg_try_advisory_xact_lock(2026,103) then return 'already_running'; end if;
  select * into run from fantasy_forecast.ai_review_runs r where r.local_day=review_job.local_day;
  if found and run.status <> 'running' then return run.status; end if;

  if run.local_day is null then
    select count(*), max((p.json->>'week')::int) filter(where a.endpoint='espn-import')
    into ready_imports,target_week
    from fantasy_forecast.app_refresh_requests a
    join net._http_response r on r.id=a.request_id
    cross join lateral (select case when pg_input_is_valid(r.content,'jsonb') then r.content::jsonb end as json) p
    where a.local_day=review_job.local_day
      and a.endpoint in ('espn-import','espn-stats-import','espn-injury-import','espn-free-agent-import')
      and r.status_code between 200 and 299 and p.json->'ok'='true'::jsonb;
    if ready_imports<>4 or target_week is null or target_week not between 12 and 18
      or not exists(select 1 from public.espn_free_agent_snapshots s where s.league_id=605081630 and s.season=2026
        and s.week=target_week and (s.captured_at at time zone 'Europe/Berlin')::date=review_job.local_day)
      or not exists(select 1 from fantasy_forecast.roster_import_runs i where i.league_id=605081630 and i.season=2026
        and i.week=target_week and (i.observed_at at time zone 'Europe/Berlin')::date=review_job.local_day)
      or not exists(select 1 from public.nfl_games where season=2026 and week=target_week and kickoff_at>clock_timestamp())
    then return 'awaiting_imports'; end if;
    if (select coalesce(sum(reserved_usd),0) from fantasy_forecast.ai_review_runs r
      where date_trunc('month',r.local_day::timestamp)=date_trunc('month',berlin)) + 0.02 > settings.monthly_budget_usd
    then return 'monthly_budget_reached'; end if;

    insert into fantasy_forecast.ai_review_runs(local_day,week,started_at,candidates)
    values (review_job.local_day,target_week,clock_timestamp(),fantasy_forecast.flex_ai_candidates(target_week,clock_timestamp()))
    returning * into run;
  end if;

  if run.requests is not null then
    for phase in select unnest(array['lineup','waiver']) loop
      select status_code,case when pg_input_is_valid(content,'jsonb') then content::jsonb end as data
        into response from net._http_response where id=(run.requests->>phase)::bigint;
      if not found and clock_timestamp()-run.started_at < interval '8 minutes' then return 'awaiting_openai'; end if;
      if response.status_code is distinct from 200 or response.data->>'status' is distinct from 'completed' then
        update fantasy_forecast.ai_review_runs r set status='failed',failure='openai_response' where r.local_day=run.local_day;
        return 'openai_response_failed';
      end if;
      select (x->>'text')::jsonb into output
      from jsonb_array_elements(response.data->'output') item
      cross join lateral jsonb_array_elements(item->'content') x
      where x->>'type'='output_text' and pg_input_is_valid(x->>'text','jsonb') limit 1;
      if output is null or coalesce(output->>'choice','') !~ '^[0-5]$'
        or (output->>'choice')::integer > jsonb_array_length(run.candidates->phase)
      then
        update fantasy_forecast.ai_review_runs r set status='failed',failure='invalid_choice' where r.local_day=run.local_day;
        return 'invalid_choice';
      end if;
      decision := jsonb_build_object('choice',(output->>'choice')::int);
      run.choices := jsonb_set(run.choices,array[phase],(run.choices->phase)||jsonb_build_array(decision));
    end loop;

    if run.stage=3 then
      for phase in select unnest(array['lineup','waiver']) loop
        choice := (run.choices->phase->2->>'choice')::integer;
        recommendation := case when choice>0 then run.candidates->phase->(choice-1) end;
        reports := jsonb_set(reports,array[phase],to_jsonb(case
          when choice=0 then case phase when 'lineup' then 'Aufstellung beibehalten.' else 'Keinen Spieler aufnehmen oder abgeben.' end
          when (recommendation->>'before')::timestamptz<=clock_timestamp() then 'Der gewählte Wechsel ist wegen Spielbeginn inzwischen gesperrt.'
          when phase='lineup' then format('%s statt %s auf %s. ESPN-Prognosen: %s statt %s Punkte.%s',
            recommendation->>'incoming',recommendation->>'outgoing',recommendation->>'slot',
            recommendation->>'incoming_points',recommendation->>'outgoing_points',
            case when recommendation->>'incoming_status'='QUESTIONABLE' then ' Einsatz fraglich.' else '' end)
          else format('%s für %s. %s. ESPN-Prognosen: %s statt %s Punkte.',
            recommendation->>'incoming',recommendation->>'outgoing',
            case when recommendation->>'availability'='WAIVERS' then 'Waiver-Claim nötig' else 'Beim Import sofort verfügbar' end,
            recommendation->>'incoming_points',recommendation->>'outgoing_points')
          end));
      end loop;
      insert into public.agent_analyses(league_id,season,week,agent_name,analysis)
      values (605081630,2026,run.week,'three_role_review', reports || jsonb_build_object(
        'team_id',2,'kind','scheduled','data_at',run.started_at,'local_day',run.local_day,'model','gpt-5.6-luna'));
      update fantasy_forecast.ai_review_runs r set status='completed',choices=run.choices where r.local_day=run.local_day;
      return 'published';
    end if;
    run.stage := run.stage+1;
  end if;

  select max(decrypted_secret) into api_key from vault.decrypted_secrets
    where name='openai_api_key_flex' having count(*)=1;
  if api_key is null or length(api_key)<10 then
    update fantasy_forecast.ai_review_runs r set status='failed',failure='missing_key' where r.local_day=run.local_day;
    return 'missing_key';
  end if;
  for phase in select unnest(array['lineup','waiver']) loop
    payload := jsonb_build_object(
      'model','gpt-5.6-luna','max_output_tokens',600,'store',false,'service_tier','default',
      'reasoning','{"effort":"none"}'::jsonb,
      'input',jsonb_build_object('role',role_names[run.stage],'task',phase,'guidance',role_tasks[run.stage],
        'options',(select coalesce(jsonb_agg(jsonb_build_object('choice',n) || x),'[]') from jsonb_array_elements(run.candidates->phase) with ordinality as t(x,n)),
        'prior_choices',run.choices->phase,
        'rules','Wähle genau eine vorhandene Optionsnummer oder 0 für keinen Wechsel. Bei lineup geht es nur um Tausch im Kader. Bei waiver geht es um Aufnahme plus Abgang. QUESTIONABLE ist ein Einsatzrisiko. UNKNOWN bestätigt keine Gesundheit. Ein Wochenwert allein rechtfertigt keinen Drop.')::text,
      'text','{"format":{"type":"json_schema","name":"fantasy_choice","strict":true,"schema":{"type":"object","properties":{"choice":{"type":"integer"}},"required":["choice"],"additionalProperties":false}}}'::jsonb);
    if octet_length(payload::text)>4800 then
      update fantasy_forecast.ai_review_runs r set status='failed',failure='input_limit' where r.local_day=run.local_day;
      return 'input_limit';
    end if;
    request_ids := jsonb_set(request_ids,array[phase],to_jsonb(net.http_post(
      url:='https://api.openai.com/v1/responses',
      headers:=jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||api_key),
      body:=payload,timeout_milliseconds:=55000)));
  end loop;
  update fantasy_forecast.ai_review_runs r set stage=run.stage,requests=request_ids,choices=run.choices where r.local_day=run.local_day;
  return 'openai_stage_queued';
end;
$function$;
revoke all on function fantasy_forecast.advance_flex_ai_review() from public, anon, authenticated, service_role;

do $schedule$
declare job_id bigint;
begin
  job_id := cron.schedule('fantasy-flex-ai-weekend','* 15-17 * * 4,6','select fantasy_forecast.advance_flex_ai_review();');
  perform cron.alter_job(job_id,active:=false);
end;
$schedule$;
CREATE OR REPLACE FUNCTION public.get_fantasy_waiver_view(requesting_user uuid, requested_season integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  authorized_team bigint;
  result jsonb;
  weekly_summary jsonb;
  current_summary jsonb;
  ai_review jsonb;
begin
  select team_id into authorized_team
  from public.fantasy_waiver_team_access
  where user_id = requesting_user;

  if authorized_team is null then
    return jsonb_build_object('status', 'unassigned');
  end if;

  select jsonb_build_object(
    'week', w.week,
    'captured_at', w.captured_at,
    'first_kickoff', w.first_kickoff,
    'roster_players', cardinality(coverage.player_ids),
    'espn_projections', (
      select count(*)
      from jsonb_array_elements(w.inputs->'espn_projections') as p
      where p->>'player_id' = any(coverage.player_ids)
    ),
    'waiver_players', coalesce((w.inputs->'coverage'->>'waiver_players')::integer, 0),
    'player_forecasts', (
      select jsonb_agg(
        jsonb_build_object(
          'name', coalesce(player.full_name, 'ESPN-Spieler ' || roster.espn_player_id),
          'position', roster.position,
          'roster_slot', roster.roster_slot,
          'projected_points', projection.projected_points
        )
        order by projection.projected_points desc nulls last, player.full_name, roster.player_id
      )
      from jsonb_to_recordset(w.inputs->'roster') as roster(
        team_id bigint, player_id bigint, espn_player_id text, position text, roster_slot text
      )
      left join public.players player on player.id = roster.player_id
      left join jsonb_to_recordset(w.inputs->'espn_projections') as projection(
        player_id bigint, projected_points numeric
      ) on projection.player_id = roster.player_id
      where roster.team_id = authorized_team
    )
  ) into weekly_summary
  from public.teams t
  join fantasy_forecast.weekly_inputs w on w.league_id = t.league_id
  cross join lateral (
    with team_roster as (
      select r->>'player_id' as player_id
      from jsonb_array_elements(w.inputs->'roster') as r
      where r->>'team_id' = authorized_team::text
    )
    select array_agg(player_id) as player_ids from team_roster
  ) coverage
  where t.id = authorized_team and w.season = requested_season
    and w.captured_at < w.first_kickoff and cardinality(coverage.player_ids) > 0
  order by w.week desc, w.captured_at desc
  limit 1;

  select jsonb_build_object(
    'week', rr.week, 'roster_at', rr.observed_at,
    'projections_at', max(pr.updated_at),
    'player_forecasts', jsonb_agg(jsonb_build_object(
      'name', p.full_name, 'position', p.position, 'roster_slot', r.roster_slot,
      'projected_points', pr.projected_points, 'injury_status', injury.status,
      'kickoff_at', g.kickoff
    ) order by pr.projected_points desc nulls last, p.full_name)
  ) into current_summary
  from public.teams t
  cross join lateral (
    select week, observed_at from fantasy_forecast.roster_import_runs
    where league_id = t.league_id and season = requested_season
    order by week desc, observed_at desc limit 1
  ) rr
  join public.roster_entries r on r.team_id = t.id and r.season = requested_season and r.week = rr.week
  join public.players p on p.id = r.player_id
  left join lateral (
    select projected_points, updated_at from public.projections
    where player_id = p.id and season = requested_season and week = rr.week and source = 'espn_projection'
    order by updated_at desc nulls last, id desc limit 1
  ) pr on true
  left join lateral (
    select status from public.injury_reports
    where player_id = p.id and report_time <= now()
    order by report_time desc nulls last, id desc limit 1
  ) injury on true
  left join lateral (
    select min(kickoff_at) kickoff from public.nfl_games
    where season = requested_season and week = rr.week and
      (case p.nfl_team when 'LA' then 'LAR' when 'JAC' then 'JAX' when 'WSH' then 'WAS' else p.nfl_team end)
      in (home_team, away_team)
  ) g on true
  where t.id = authorized_team
  group by rr.week, rr.observed_at;

  select jsonb_build_object(
    'week', a.week, 'created_at', a.created_at, 'kind', a.analysis->'kind',
    'data_at', a.analysis->'data_at', 'lineup', a.analysis->'lineup',
    'waiver', a.analysis->'waiver'
  ) into ai_review
  from public.agent_analyses a
  join public.teams t on t.league_id = a.league_id
  where t.id = authorized_team and a.season = requested_season
    and a.agent_name = 'three_role_review' and a.analysis->>'team_id' = authorized_team::text
  order by a.week desc, a.created_at desc nulls last, a.id desc
  limit 1;

  select to_jsonb(view_data) into result
  from (
    with snapshot as (
      select t.id as team_id, t.team_name, s.*
      from public.teams t
      join public.espn_free_agent_snapshots s on s.league_id = t.league_id
      where t.id = authorized_team
        and s.season = requested_season
      order by s.week desc
      limit 1
    ),
    roster as (
      select r.player_id, r.is_injured_reserve, p.espn_player_id, p.position,
        projection.projected_points
      from snapshot s
      join public.roster_entries r
        on r.team_id = s.team_id and r.season = s.season and r.week = s.week
      join public.players p on p.id = r.player_id
      left join lateral (
        select pr.projected_points
        from public.projections pr
        where pr.player_id = r.player_id and pr.season = r.season
          and pr.week = r.week and pr.source = 'espn_projection'
        order by pr.updated_at desc nulls last, pr.id desc
        limit 1
      ) projection on true
    ),
    position_baseline as (
      select position, min(projected_points) as lowest_roster_projection
      from roster
      where is_injured_reserve is false and projected_points > 0
      group by position
    ),
    pool as (
      select j.espn_player_id, j.name, p.position, j.fantasy_status,
        j.injured, j.injury_status, j.projected_points,
        b.lowest_roster_projection,
        j.projected_points - b.lowest_roster_projection as projection_delta
      from snapshot s
      cross join lateral jsonb_to_recordset(s.players) j(
        espn_player_id text, name text, fantasy_status text, injured boolean,
        injury_status text, projected_points numeric
      )
      join public.players p on p.espn_player_id = j.espn_player_id
      join position_baseline b on b.position = p.position
      where j.fantasy_status in ('FREEAGENT', 'WAIVERS')
        and j.injured is false
        and upper(j.injury_status) = 'ACTIVE'
        and j.projected_points > b.lowest_roster_projection
        and not exists (select 1 from roster r where r.espn_player_id = j.espn_player_id)
    ),
    shortlist as (
      select *
      from pool
      order by projection_delta desc, projected_points desc, espn_player_id
      limit 10
    )
    select
      s.team_name,
      s.season,
      s.week,
      s.captured_at,
      jsonb_array_length(s.players) as source_player_count,
      (select count(*) from roster) as roster_player_count,
      coalesce((
        select jsonb_agg(to_jsonb(c) order by c.projection_delta desc,
          c.projected_points desc, c.espn_player_id)
        from shortlist c
      ), '[]'::jsonb) as candidates
    from snapshot s
  ) view_data;

  if result is null then
    return jsonb_build_object('status', 'no_snapshot', 'weekly_inputs', weekly_summary, 'current_forecasts', current_summary, 'ai_review', ai_review);
  end if;

  return result || jsonb_build_object('status', 'ready', 'weekly_inputs', weekly_summary, 'current_forecasts', current_summary, 'ai_review', ai_review);
end;
$function$;
