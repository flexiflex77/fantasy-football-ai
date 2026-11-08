-- Server-side query. Bind team ID, season and week as $1, $2 and $3.
-- The caller must authorize access to the team before binding the parameters.
with snapshot as (
  select t.id as team_id, s.*
  from public.teams t
  join public.espn_free_agent_snapshots s on s.league_id = t.league_id
  where t.id = $1::bigint and s.season = $2::integer and s.week = $3::integer
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
from snapshot s;
