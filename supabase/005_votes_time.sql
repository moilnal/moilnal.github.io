-- =====================================================================
-- 모일날 005: 후보 날짜 ❤️ 투표 + 가능 시간 + 확정 시각
--
-- 사용법: schema.sql, 002, 003, 004 를 실행한 프로젝트에서, 이 파일 전체를 SQL Editor 에 붙여넣고 Run.
--         여러 번 실행해도 에러가 나지 않게 작성됨.
--         기존 데이터를 지우는 명령(drop table / delete / truncate)은 쓰지 않는다.
--         (toggle_vote 함수 "안"의 delete 는 사용자가 ❤️를 끌 때만 동작)
--
-- 바뀌는 것
--   * rooms.confirmed_hour : 확정 시각 (10~23시, 없으면 null)
--   * date_votes           : ❤️ 투표 + 그 날 가능 시간 (start_hour ~ end_hour, 기본 10~24 = 하루 종일)
--   * toggle_vote          : ❤️ 켜기/끄기. 켜면 응답 완료 (004 와 같은 "한 번 응답하면 유지")
--   * set_vote_hours       : 가능 시간 저장 (10~24시, 시작 < 끝)
--   * confirm_date         : 날짜 + 시각 확정 / 취소
--   * set_confirmed_date   : 예전 화면용, 확정 시각을 비움
--   * get_room             : confirmed.hour, votes 포함
-- =====================================================================


-- =====================================================================
-- 1. 테이블
-- =====================================================================

alter table public.rooms
  add column if not exists confirmed_hour smallint;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'rooms_confirmed_hour_check') then
    alter table public.rooms
      add constraint rooms_confirmed_hour_check check (confirmed_hour between 10 and 23);
  end if;
end
$$;

-- ❤️ 투표 + 가능 시간 (날짜별·사람별)
create table if not exists public.date_votes (
  room_id     text not null references public.rooms (id) on delete cascade,
  member_id   uuid not null,
  day         date not null,
  start_hour  smallint not null default 10,
  end_hour    smallint not null default 24,
  created_at  timestamptz not null default now(),
  primary key (member_id, day),
  check (start_hour >= 10 and end_hour <= 24 and start_hour < end_hour),
  -- 같은 모임 참여자만. 참여자를 지우면 그 사람 투표/가능 시간도 같이 지워짐
  foreign key (member_id, room_id) references public.members (id, room_id) on delete cascade
);
create index if not exists date_votes_room_day_idx on public.date_votes (room_id, day);

-- 보안: RLS 켜기 + 직접 접근 차단 (정책 없음 → RPC 로만 접근)
alter table public.date_votes enable row level security;
revoke all on table public.date_votes from public, anon, authenticated;


-- =====================================================================
-- 2. 내부 도우미
-- =====================================================================

-- 투표할 수 있는 날짜인지 (내일 ~ 약 1년)
create or replace function moilnal_private.parse_vote_day(p_day text)
returns date
language plpgsql stable
set search_path = ''
as $$
declare
  v_day date;
begin
  v_day := moilnal_private.parse_day(p_day);
  if v_day <= moilnal_private.kst_today() or v_day > moilnal_private.kst_today() + 400 then
    raise exception 'date_out_of_range';
  end if;
  return v_day;
end
$$;


-- =====================================================================
-- 3. RPC
-- =====================================================================

-- ❤️ 켜기/끄기 (반환: true = 이제 ❤️)
create or replace function public.toggle_vote(p_room_id text, p_member_id uuid, p_day text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_day date;
  v_now boolean;
begin
  perform moilnal_private.lock_room(p_room_id);
  perform moilnal_private.require_member(p_room_id, p_member_id);
  v_day := moilnal_private.parse_vote_day(p_day);

  delete from public.date_votes where member_id = p_member_id and day = v_day;
  if found then
    v_now := false;
  else
    insert into public.date_votes (room_id, member_id, day) values (p_room_id, p_member_id, v_day);
    v_now := true;
    -- ❤️도 응답. 한 번 응답하면 유지
    update public.members set responded = true
     where id = p_member_id and room_id = p_room_id;
  end if;

  perform moilnal_private.after_change(p_room_id);
  return v_now;
end
$$;

-- 가능 시간 저장 (10~24시, 시작 < 끝). ❤️가 없으면 ❤️와 함께 저장
create or replace function public.set_vote_hours(
  p_room_id text, p_member_id uuid, p_day text, p_start int, p_end int)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_day date;
begin
  perform moilnal_private.lock_room(p_room_id);
  perform moilnal_private.require_member(p_room_id, p_member_id);
  v_day := moilnal_private.parse_vote_day(p_day);

  if p_start is null or p_end is null or p_start < 10 or p_end > 24 or p_start >= p_end then
    raise exception 'invalid_hours';
  end if;

  insert into public.date_votes (room_id, member_id, day, start_hour, end_hour)
  values (p_room_id, p_member_id, v_day, p_start, p_end)
  on conflict (member_id, day) do update
    set start_hour = excluded.start_hour, end_hour = excluded.end_hour;

  update public.members set responded = true
   where id = p_member_id and room_id = p_room_id;

  perform moilnal_private.after_change(p_room_id);
end
$$;

-- 날짜 + 시각 확정 (p_day = null 이면 확정 취소, p_hour = null 이면 날짜만)
create or replace function public.confirm_date(p_room_id text, p_day text, p_hour int)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_day date;
begin
  perform moilnal_private.lock_room(p_room_id);

  if p_day is null then
    update public.rooms
       set confirmed_date = null, confirmed_known = '{}', confirmed_hour = null
     where id = p_room_id;
  else
    v_day := moilnal_private.parse_vote_day(p_day);   -- 오늘과 지난 날짜는 확정 불가
    if p_hour is not null and (p_hour < 10 or p_hour > 23) then
      raise exception 'invalid_hours';
    end if;

    -- 확정 시점에 이미 안 된다고 한 사람은 기억 (나중에 "새로" 안 된다고 한 사람만 경고)
    update public.rooms
       set confirmed_date  = v_day,
           confirmed_hour  = p_hour,
           confirmed_known = array(
             select u.member_id from public.unavailable u
              where u.room_id = p_room_id and u.day = v_day
           )
     where id = p_room_id;
  end if;

  perform moilnal_private.after_change(p_room_id);
end
$$;

-- 예전 화면용: 날짜만 확정 (시각은 비움)
create or replace function public.set_confirmed_date(p_room_id text, p_day text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.confirm_date(p_room_id, p_day, null);
end
$$;


-- =====================================================================
-- 4. get_room: 확정 시각 + ❤️ 투표 포함 (002 버전 + 추가)
-- =====================================================================

create or replace function public.get_room(p_room_id text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.rooms;
begin
  if p_room_id is null or p_room_id !~ '^[A-Za-z0-9_-]{12,64}$' then
    raise exception 'room_not_found';
  end if;

  select * into r from public.rooms where id = p_room_id;
  if not found then
    raise exception 'room_not_found';
  end if;

  -- 삭제된 모임: 참여자/날짜 데이터는 주지 않고, 복구 가능한 시각만 알려줌
  if r.deleted_at is not null then
    return jsonb_build_object(
      'id',            r.id,
      'name',          r.name,
      'deleted',       true,
      'restore_until', r.deleted_at + interval '24 hours'
    );
  end if;

  -- 마지막 접속 시각 (너무 자주 쓰지 않도록 1시간에 한 번만 갱신)
  if r.last_seen_at < now() - interval '1 hour' then
    update public.rooms set last_seen_at = now() where id = p_room_id;
  end if;

  return jsonb_build_object(
    'id',      r.id,
    'name',    r.name,
    'deleted', false,
    'size',    r.size,
    'confirmed', case
      when r.confirmed_date is null then null
      else jsonb_build_object('date', r.confirmed_date, 'known', to_jsonb(r.confirmed_known),
                              'hour', r.confirmed_hour)
    end,
    'members', coalesce((
      select jsonb_agg(
               jsonb_build_object('id', m.id, 'name', m.name, 'emoji', m.emoji, 'responded', m.responded)
               order by m.created_at, m.id)
        from public.members m
       where m.room_id = r.id
    ), '[]'::jsonb),
    'unavailable', coalesce((
      select jsonb_object_agg(t.day_key, t.ids)
        from (
          select to_char(u.day, 'YYYY-MM-DD') as day_key,
                 jsonb_agg(u.member_id order by u.created_at) as ids
            from public.unavailable u
           where u.room_id = r.id
           group by u.day
        ) t
    ), '{}'::jsonb),
    'votes', coalesce((
      select jsonb_object_agg(t.day_key, t.list)
        from (
          select to_char(v.day, 'YYYY-MM-DD') as day_key,
                 jsonb_agg(jsonb_build_object('id', v.member_id, 's', v.start_hour, 'e', v.end_hour)
                           order by v.created_at) as list
            from public.date_votes v
           where v.room_id = r.id and v.day > moilnal_private.kst_today()
           group by v.day
        ) t
    ), '{}'::jsonb),
    'undo_until', (
      select b.expires_at
        from public.room_reset_backups b
       where b.room_id = r.id and b.expires_at > now()
    )
  );
end
$$;


-- =====================================================================
-- 5. 함수 실행 권한 (anon 만, 내부 도우미/정리 함수는 막음)
-- =====================================================================

revoke execute on all functions in schema moilnal_private from public, anon, authenticated;

revoke execute on function public.toggle_vote(text, uuid, text)                  from public, anon, authenticated;
revoke execute on function public.set_vote_hours(text, uuid, text, int, int)     from public, anon, authenticated;
revoke execute on function public.confirm_date(text, text, int)                  from public, anon, authenticated;
revoke execute on function public.set_confirmed_date(text, text)                 from public, anon, authenticated;
revoke execute on function public.get_room(text)                                 from public, anon, authenticated;

grant execute on function public.toggle_vote(text, uuid, text)                   to anon;
grant execute on function public.set_vote_hours(text, uuid, text, int, int)      to anon;
grant execute on function public.confirm_date(text, text, int)                   to anon;
grant execute on function public.set_confirmed_date(text, text)                  to anon;
grant execute on function public.get_room(text)                                  to anon;

revoke execute on function public.cleanup_inactive_rooms()                       from public, anon, authenticated;
