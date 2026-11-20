grant select on public.agent_analyses to service_role;
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
    'week', a.week, 'created_at', a.created_at, 'lineup', a.analysis->'lineup',
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
