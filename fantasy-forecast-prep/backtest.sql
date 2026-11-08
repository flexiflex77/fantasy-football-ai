-- Read-only. Historical ESPN rows are mutable, so report a strict
-- pre-kickoff comparison separately from the retrospective diagnostic.
with weeks as (
  select season, week, min(kickoff_at) as first_kickoff,
    max(kickoff_at) + interval '1 day' <= now() as evaluation_window_passed
  from public.nfl_games
  where season = 2026 and kickoff_at is not null
  group by season, week
),
scores as (
  select distinct on (p.season, p.week, p.player_id, p.source)
    p.season, p.week, p.player_id, p.source, upper(trim(player.position)) as position,
    p.actual_points, p.projected_points, p.updated_at
  from public.projections p
  join public.players player on player.id = p.player_id
  where p.season = 2026 and p.source in ('espn_actual', 'espn_projection')
    and nullif(trim(player.position), '') is not null
  order by p.season, p.week, p.player_id, p.source, p.updated_at desc nulls last, p.id desc
),
observations as (
  select a.*, e.projected_points as espn, e.updated_at as espn_updated_at,
    w.first_kickoff, w.evaluation_window_passed
  from scores a
  join weeks w using (season, week)
  left join scores e
    on e.season = a.season and e.week = a.week and e.player_id = a.player_id
    and e.source = 'espn_projection'
  where a.source = 'espn_actual' and a.actual_points is not null
),
forecasts as (
  select o.*, mode.name as test_mode,
    case when player.n > 0
      then (player.total + 2 * position.mean) / (player.n + 2)
    end as own_forecast,
    case when not mode.require_timestamp or o.espn_updated_at < o.first_kickoff
      then o.espn
    end as espn_forecast
  from observations o
  cross join (values ('pre_kickoff', true), ('retrospective', false)) mode(name, require_timestamp)
  cross join lateral (
    select count(*) as n, sum(s.actual_points) as total
    from scores s
    where s.season = o.season and s.week < o.week and s.week >= o.week - 4
      and s.player_id = o.player_id and s.source = 'espn_actual'
      and s.actual_points is not null
      and (not mode.require_timestamp or s.updated_at < o.first_kickoff)
  ) player
  cross join lateral (
    select avg(s.actual_points) as mean
    from scores s
    where s.season = o.season and s.week < o.week and s.week >= o.week - 4
      and s.position = o.position and s.source = 'espn_actual'
      and s.actual_points is not null
      and (not mode.require_timestamp or s.updated_at < o.first_kickoff)
  ) position
)
select week, evaluation_window_passed, test_mode,
  count(*) as recorded_outcomes,
  count(own_forecast) as own_forecasts,
  count(espn_forecast) as espn_forecasts,
  count(*) filter (where own_forecast is not null and espn_forecast is not null) as paired,
  round(avg(abs(own_forecast - actual_points)) filter (where espn_forecast is not null), 2) as own_mae,
  round(avg(abs(espn_forecast - actual_points)) filter (where own_forecast is not null), 2) as espn_mae
from forecasts
group by week, evaluation_window_passed, test_mode
order by week, test_mode;
