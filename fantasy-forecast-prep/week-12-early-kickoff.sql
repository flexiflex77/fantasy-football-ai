CREATE OR REPLACE FUNCTION fantasy_forecast.refresh_app_inputs()
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  berlin timestamp := clock_timestamp() at time zone 'Europe/Berlin';
  target_week integer;
  api_key text;
  item text;
  payload jsonb;
  queued bigint;
begin
  if ((extract(isodow from berlin) not in (4, 6) and berlin::date <> date '2026-11-25') or berlin::date = date '2026-11-26') or berlin::time < time '17:30'
    or berlin::time >= time '18:00' then return 'outside_refresh_window'; end if;
  if not pg_try_advisory_xact_lock(2026, 102) then return 'already_running'; end if;

  select max(decrypted_secret) into api_key from vault.decrypted_secrets
  where name = 'fantasy_cron_api_key' having count(*) = 1;
  if api_key is null then return 'import_key_missing'; end if;

  select (r.content::jsonb->>'week')::integer into target_week
  from fantasy_forecast.app_refresh_requests a
  join net._http_response r on r.id = a.request_id
  where a.local_day = berlin::date and a.endpoint = 'espn-import'
    and r.status_code = 200
    and (case when pg_input_is_valid(r.content, 'jsonb') then r.content::jsonb->'ok' end) = 'true'::jsonb;

  for item in select unnest(case when target_week is null then array['espn-import']
    else array['espn-stats-import', 'espn-injury-import', 'espn-free-agent-import'] end)
  loop
    if exists (
      select 1 from fantasy_forecast.app_refresh_requests a
      left join net._http_response r on r.id = a.request_id
      where a.local_day = berlin::date and a.endpoint = item
        and (a.attempts >= 2 or
          (r.id is null and a.requested_at + interval '2 minutes' > clock_timestamp()) or
          (r.status_code between 200 and 299 and
            (case when pg_input_is_valid(r.content, 'jsonb') then r.content::jsonb->'ok' end) = 'true'::jsonb))
    ) then continue; end if;
    payload := jsonb_build_object('confirm', true);
    if target_week is not null then payload := payload || jsonb_build_object('expected_week', target_week); end if;
    if item = 'espn-free-agent-import' then payload := payload || '{"action":"import"}'::jsonb; end if;
    queued := net.http_post(
      url := 'https://uzifirhbzrwmxlxgwjss.supabase.co/functions/v1/' || item,
      headers := jsonb_build_object('Content-Type','application/json','apikey',api_key),
      body := payload, timeout_milliseconds := 60000
    );
    insert into fantasy_forecast.app_refresh_requests as a (local_day, endpoint, request_id)
    values (berlin::date, item, queued)
    on conflict (local_day, endpoint) do update set
      request_id = excluded.request_id, requested_at = excluded.requested_at, attempts = a.attempts + 1;
  end loop;
  return case when target_week is null then 'awaiting_roster' else 'refresh_dispatched' end;
end;
$function$;

CREATE OR REPLACE FUNCTION fantasy_forecast.advance_flex_ai_review()
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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
  if ((extract(isodow from berlin) not in (4,6) and berlin::date <> date '2026-11-25') or berlin::date = date '2026-11-26')
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

select cron.alter_job(jobid,schedule:='30,35,40,45,50,55 15,16 * * 3,4,6')
from cron.job where jobname='fantasy-app-forecast-thursday-saturday';
select cron.alter_job(jobid,schedule:='* 15-17 * * 3,4,6')
from cron.job where jobname='fantasy-flex-ai-weekend';
