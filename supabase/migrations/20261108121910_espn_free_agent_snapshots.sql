create table public.espn_free_agent_snapshots (
  league_id bigint not null,
  season integer not null,
  week integer not null check (week between 1 and 18),
  captured_at timestamptz not null,
  players jsonb not null check (
    case when jsonb_typeof(players) = 'array'
      then jsonb_array_length(players) between 1 and 50
      else false
    end
  ),
  primary key (league_id, season, week)
);

alter table public.espn_free_agent_snapshots enable row level security;
revoke all on table public.espn_free_agent_snapshots from public, anon, authenticated;
grant select, insert, update on table public.espn_free_agent_snapshots to service_role;

create function public.save_espn_free_agent_snapshot(
  snapshot_league bigint,
  snapshot_season integer,
  snapshot_week integer,
  snapshot_time timestamptz,
  snapshot_players jsonb
) returns boolean
language sql
security invoker
set search_path = ''
as $$
  with saved as (
    insert into public.espn_free_agent_snapshots as current_snapshot
      (league_id, season, week, captured_at, players)
    values
      (snapshot_league, snapshot_season, snapshot_week, snapshot_time, snapshot_players)
    on conflict (league_id, season, week) do update
      set captured_at = excluded.captured_at, players = excluded.players
      where current_snapshot.captured_at <= excluded.captured_at
    returning 1
  )
  select exists (select 1 from saved);
$$;

revoke all on function public.save_espn_free_agent_snapshot(bigint, integer, integer, timestamptz, jsonb)
  from public, anon, authenticated;
grant execute on function public.save_espn_free_agent_snapshot(bigint, integer, integer, timestamptz, jsonb)
  to service_role;

