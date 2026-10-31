-- 검 강화 대장간 · Supabase 테이블과 접근 규칙
-- Supabase 대시보드 → SQL Editor 에 통째로 붙여넣고 Run 하세요. 여러 번 실행해도 안전해요.

-- 닉네임: 친구들과 결투할 때 서로 보이는 이름
create table if not exists public.profiles (
  id         uuid primary key references auth.users (id) on delete cascade,
  nickname   text not null check (char_length(nickname) between 1 and 12),
  created_at timestamptz not null default now()
);

-- 진행 상황: 계정마다 한 줄
create table if not exists public.saves (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  state      jsonb  not null,
  saved_at   bigint not null,          -- 게임이 저장한 시각 (ms)
  device     text,                     -- 어느 탭/기기가 저장했는지
  updated_at timestamptz not null default now()
);

alter table public.profiles enable row level security;
alter table public.saves    enable row level security;

-- 닉네임은 로그인한 사람 누구나 읽고, 자기 것만 만들고 고쳐요
drop policy if exists "profiles: signed-in read" on public.profiles;
create policy "profiles: signed-in read" on public.profiles
  for select to authenticated using (true);
drop policy if exists "profiles: insert own" on public.profiles;
create policy "profiles: insert own" on public.profiles
  for insert to authenticated with check ((select auth.uid()) = id);
drop policy if exists "profiles: update own" on public.profiles;
create policy "profiles: update own" on public.profiles
  for update to authenticated using ((select auth.uid()) = id) with check ((select auth.uid()) = id);

-- 진행 상황은 본인만 읽고 써요
drop policy if exists "saves: read own" on public.saves;
create policy "saves: read own" on public.saves
  for select to authenticated using ((select auth.uid()) = user_id);
drop policy if exists "saves: insert own" on public.saves;
create policy "saves: insert own" on public.saves
  for insert to authenticated with check ((select auth.uid()) = user_id);
drop policy if exists "saves: update own" on public.saves;
create policy "saves: update own" on public.saves
  for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

-- updated_at 자동 갱신
create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at = now(); return new; end $$;
drop trigger if exists saves_touch on public.saves;
create trigger saves_touch before update on public.saves
  for each row execute function public.touch_updated_at();

-- =====================================================================
-- 친구 결투
-- 승패는 아래 duel_fight 함수가 서버에서 정해요. 그래서 양쪽에 같은 결과가 남고,
-- 브라우저에서 결과나 명예 점수를 고칠 수 없어요. (검 단계 자체는 각자의 저장 데이터를 따라요.)
-- =====================================================================

create table if not exists public.duel_stats (
  user_id      uuid primary key references auth.users (id) on delete cascade,
  rating       int not null default 1000,    -- 명예 점수 (체스식)
  wins         int not null default 0,
  losses       int not null default 0,
  last_duel_at timestamptz
);

create table if not exists public.duels (
  id           bigint generated always as identity primary key,
  attacker     uuid not null references auth.users (id) on delete cascade,
  defender     uuid not null references auth.users (id) on delete cascade,
  a_level      int not null,
  d_level      int not null,
  a_power      numeric not null,
  d_power      numeric not null,
  chance       numeric not null,              -- 도전자가 이길 확률
  attacker_won boolean not null,
  delta        int not null,                  -- 오르내린 명예 점수
  prize        boolean not null default false, -- 상금을 받을 수 있는 승리였는지
  rounds       jsonb not null,                -- 연출용 공방 기록
  created_at   timestamptz not null default now()
);
create index if not exists duels_created_idx on public.duels (created_at desc);

alter table public.duel_stats enable row level security;
alter table public.duels      enable row level security;

-- 로그인한 사람은 누구나 순위와 결투 기록을 읽어요. 쓰기는 아래 함수만 해요.
drop policy if exists "duel_stats: signed-in read" on public.duel_stats;
create policy "duel_stats: signed-in read" on public.duel_stats
  for select to authenticated using (true);
drop policy if exists "duels: signed-in read" on public.duels;
create policy "duels: signed-in read" on public.duels
  for select to authenticated using (true);

-- 전투력: 출전 검 단계(champLv) + 경매 보물 0.2 + 던전 보물 0.3 + 혼 0.02 (혼은 100개까지)
create or replace function public.forge_power(s jsonb) returns numeric
language sql immutable as $$
  select coalesce((s->>'champLv')::int, (s->>'level')::int, 0)
       + 0.2 * (select count(*) from jsonb_object_keys(case when jsonb_typeof(s->'relics') = 'object' then s->'relics' else '{}'::jsonb end))
       + 0.3 * (select count(*) from jsonb_object_keys(case when jsonb_typeof(s->'dtr')    = 'object' then s->'dtr'    else '{}'::jsonb end))
       + 0.02 * least(coalesce((s->>'soul')::int, 0), 100)
$$;

-- 순위표: 저장 데이터 전체가 아니라 결투에 필요한 값만 꺼내 보여 줘요
drop function if exists public.duel_board();   -- 반환 열이 바뀌어서 한 번 지우고 다시 만들어요
create or replace function public.duel_board()
returns table (user_id uuid, nickname text, level int, power numeric, rating int, wins int, losses int, in_dungeon boolean, active_at timestamptz, monument int)
language sql stable security definer set search_path = public as $$
  select p.id, p.nickname,
         coalesce((s.state->>'champLv')::int, (s.state->>'level')::int, 0),
         round(public.forge_power(s.state), 2),
         coalesce(d.rating, 1000), coalesce(d.wins, 0), coalesce(d.losses, 0),
         coalesce(jsonb_typeof(s.state->'dg'->'run') = 'object', false),
         s.updated_at,
         coalesce((s.state->>'monument')::int, 0)
  from public.profiles p
  join public.saves s on s.user_id = p.id
  left join public.duel_stats d on d.user_id = p.id
  where auth.uid() is not null
  order by coalesce(d.rating, 1000) desc, p.nickname
  limit 200
$$;
revoke all on function public.duel_board() from public, anon;
grant execute on function public.duel_board() to authenticated;

-- 결투 한 판
create or replace function public.duel_fight(p_defender uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  v_me     uuid := auth.uid();
  v_a      jsonb;
  v_d      jsonb;
  v_dnick  text;
  v_ap     numeric;
  v_dp     numeric;
  v_chance numeric;
  v_won    boolean;
  v_ra     int;
  v_rd     int;
  v_exp    numeric;
  v_delta  int;
  v_prize  boolean;
  v_last   timestamptz;
  v_rounds jsonb := '[]'::jsonb;
  v_hpa    int := 100;
  v_hpd    int := 100;
  v_hit    int;
  v_ahits  boolean;
begin
  if v_me is null then raise exception 'not_signed_in'; end if;
  if p_defender = v_me then raise exception 'self_duel'; end if;
  select state into v_a from saves where user_id = v_me;
  select state into v_d from saves where user_id = p_defender;
  if v_a is null then raise exception 'no_save'; end if;
  if v_d is null then raise exception 'no_opponent'; end if;
  if jsonb_typeof(v_a->'dg'->'run') = 'object' then raise exception 'in_dungeon'; end if;

  insert into duel_stats (user_id) values (v_me), (p_defender) on conflict (user_id) do nothing;
  select last_duel_at into v_last from duel_stats where user_id = v_me;
  if v_last is not null and v_last > now() - interval '10 seconds' then raise exception 'cooldown'; end if;

  select nickname into v_dnick from profiles where id = p_defender;
  v_ap := forge_power(v_a);
  v_dp := forge_power(v_d);
  v_chance := greatest(0.05, least(0.95, 0.5 + (v_ap - v_dp) * 0.12));
  v_won := random() < v_chance;

  -- 두 번 주고받은 뒤 마지막 일격 (연출용)
  for i in 1..2 loop
    v_ahits := random() < 0.5;
    v_hit := 20 + floor(random() * 19)::int;
    if v_ahits then v_hpd := v_hpd - v_hit; else v_hpa := v_hpa - v_hit; end if;
    v_rounds := v_rounds || jsonb_build_object('a', v_ahits, 'hp_a', v_hpa, 'hp_d', v_hpd);
  end loop;
  if v_won then v_hpd := 0; else v_hpa := 0; end if;
  v_rounds := v_rounds || jsonb_build_object('a', v_won, 'hp_a', v_hpa, 'hp_d', v_hpd);

  select rating into v_ra from duel_stats where user_id = v_me for update;
  select rating into v_rd from duel_stats where user_id = p_defender for update;
  v_exp := 1 / (1 + power(10, (v_rd - v_ra) / 400.0));
  v_delta := greatest(1, round(32 * (case when v_won then 1 - v_exp else v_exp end)))::int;
  -- 같은 상대를 10분 안에 다시 이기면 상금은 없어요
  v_prize := v_won and not exists (
    select 1 from duels x
    where x.attacker = v_me and x.defender = p_defender and x.attacker_won and x.prize
      and x.created_at > now() - interval '10 minutes');

  update duel_stats set
    rating = rating + (case when v_won then v_delta else -v_delta end),
    wins = wins + (case when v_won then 1 else 0 end),
    losses = losses + (case when v_won then 0 else 1 end),
    last_duel_at = now()
  where user_id = v_me;
  update duel_stats set
    rating = rating + (case when v_won then -v_delta else v_delta end),
    wins = wins + (case when v_won then 0 else 1 end),
    losses = losses + (case when v_won then 1 else 0 end)
  where user_id = p_defender;

  insert into duels (attacker, defender, a_level, d_level, a_power, d_power, chance, attacker_won, delta, prize, rounds)
  values (v_me, p_defender, coalesce((v_a->>'champLv')::int, (v_a->>'level')::int, 0), coalesce((v_d->>'champLv')::int, (v_d->>'level')::int, 0),
          v_ap, v_dp, v_chance, v_won, v_delta, v_prize, v_rounds);

  return jsonb_build_object(
    'won', v_won, 'chance', v_chance, 'delta', v_delta, 'prize', v_prize, 'rounds', v_rounds,
    'a_level', coalesce((v_a->>'champLv')::int, (v_a->>'level')::int, 0), 'd_level', coalesce((v_d->>'champLv')::int, (v_d->>'level')::int, 0),
    'a_power', v_ap, 'd_power', v_dp,
    'rating', v_ra + (case when v_won then v_delta else -v_delta end), 'd_nick', v_dnick);
end $$;
revoke all on function public.duel_fight(uuid) from public, anon;
grant execute on function public.duel_fight(uuid) to authenticated;
