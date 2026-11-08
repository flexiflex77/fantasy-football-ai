create table public.fantasy_waiver_team_access (
  user_id uuid primary key references public.fantasy_app_users(user_id) on delete cascade,
  team_id bigint not null references public.teams(id) on delete cascade
);

alter table public.fantasy_waiver_team_access enable row level security;
revoke all on table public.fantasy_waiver_team_access from public, anon, authenticated;
grant select on table public.fantasy_waiver_team_access to service_role;

create function public.get_fantasy_waiver_view(requesting_user uuid, requested_season integer)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  authorized_team bigint;
  result jsonb;
begin
  select team_id into authorized_team
  from public.fantasy_waiver_team_access
  where user_id = requesting_user;

  if authorized_team is null then
    return jsonb_build_object('status', 'unassigned');
  end if;

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
    return jsonb_build_object('status', 'no_snapshot');
  end if;

  return result || jsonb_build_object('status', 'ready');
end;
$$;

revoke all on function public.get_fantasy_waiver_view(uuid, integer) from public, anon, authenticated;
grant execute on function public.get_fantasy_waiver_view(uuid, integer) to service_role;
