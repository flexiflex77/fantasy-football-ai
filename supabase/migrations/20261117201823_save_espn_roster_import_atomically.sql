create table fantasy_forecast.roster_import_runs (
  league_id bigint not null,
  season integer not null,
  week integer not null,
  observed_at timestamptz not null,
  primary key (league_id, season, week)
);
alter table fantasy_forecast.roster_import_runs enable row level security;
revoke all on fantasy_forecast.roster_import_runs from public, anon, authenticated;
grant usage on schema fantasy_forecast to service_role;
grant select, insert, update on fantasy_forecast.roster_import_runs to service_role;

create function public.save_espn_roster_import(
  target_league bigint, target_week integer, observed_at timestamptz,
  new_players jsonb, roster_rows jsonb, eligibility_updates jsonb
) returns void
language plpgsql
security invoker
set search_path = ''
as $function$
declare
  roster_count integer;
begin
  if target_league <> 605081630 or target_week not between 1 and 18
    or observed_at is null or jsonb_typeof(roster_rows) is distinct from 'array' then
    raise exception 'Ungültiger ESPN-Kaderimport.';
  end if;

  perform pg_advisory_xact_lock(2026, target_week);
  insert into fantasy_forecast.roster_import_runs as runs (league_id, season, week, observed_at)
  values (target_league, 2026, target_week, save_espn_roster_import.observed_at)
  on conflict (league_id, season, week) do update set observed_at = excluded.observed_at
    where runs.observed_at < excluded.observed_at;
  if not found then raise exception 'Ein neuerer ESPN-Kader wurde bereits gespeichert.'; end if;

  insert into public.players (espn_player_id, full_name, position, nfl_team, espn_eligible_slots)
  select p.espn_player_id, p.full_name, p.position, p.nfl_team, p.espn_eligible_slots
  from jsonb_to_recordset(new_players) as p(
    espn_player_id text, full_name text, position text, nfl_team text, espn_eligible_slots jsonb
  )
  on conflict (espn_player_id) do nothing;

  insert into public.roster_entries (team_id, player_id, season, week, roster_slot, is_injured_reserve)
  select r.team_id, p.id, 2026, target_week, r.roster_slot, r.is_injured_reserve
  from jsonb_to_recordset(roster_rows) as r(
    team_id bigint, espn_player_id text, roster_slot text, is_injured_reserve boolean
  )
  join public.players p using (espn_player_id)
  join public.teams t on t.id = r.team_id and t.league_id = target_league
  on conflict (team_id, player_id, season, week) do update
  set roster_slot = excluded.roster_slot, is_injured_reserve = excluded.is_injured_reserve;
  get diagnostics roster_count = row_count;

  if roster_count <> jsonb_array_length(roster_rows) or (
    select count(distinct (entry->>'team_id')::bigint) from jsonb_array_elements(roster_rows) entry
  ) <> (select count(*) from public.teams where league_id = target_league) then
    raise exception 'Der ESPN-Kader konnte nicht vollständig zugeordnet werden.';
  end if;

  delete from public.roster_entries e
  using public.teams t
  where e.team_id = t.id and t.league_id = target_league and e.season = 2026 and e.week = target_week
    and not exists (
      select 1 from jsonb_to_recordset(roster_rows) as r(team_id bigint, espn_player_id text)
      join public.players p using (espn_player_id)
      where r.team_id = e.team_id and p.id = e.player_id
    );

  update public.players p set espn_eligible_slots = u.espn_eligible_slots
  from jsonb_to_recordset(eligibility_updates) as u(id bigint, espn_eligible_slots jsonb)
  where p.id = u.id and p.espn_eligible_slots is distinct from u.espn_eligible_slots;
end;
$function$;
revoke all on function public.save_espn_roster_import(bigint, integer, timestamptz, jsonb, jsonb, jsonb)
  from public, anon, authenticated;
grant execute on function public.save_espn_roster_import(bigint, integer, timestamptz, jsonb, jsonb, jsonb)
  to service_role;