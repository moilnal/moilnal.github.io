-- =====================================================================
-- 모일날 Supabase 스키마
--
-- 사용법: Supabase 대시보드 > SQL Editor 에 이 파일 전체를 붙여넣고 Run.
--         여러 번 실행해도 안전하게 작성됨 (if not exists / create or replace,
--         revoke·grant 는 반복 실행해도 에러가 나지 않음).
--
-- 전제: 프로젝트 설정 "Automatically expose new tables" 끔, "Enable automatic RLS" 켬.
--       자동 설정에 기대지 않고, 필요한 권한은 이 파일에서 전부 명시적으로 주고 뺀다.
--
-- 보안 요약
--   * 모든 테이블 RLS 켬 + 정책(policy) 0개 + 테이블 권한 전부 회수
--     → anon/authenticated 키로 테이블 직접 접근 불가
--   * 읽기/쓰기는 security definer RPC 함수로만 가능 (anon 에게만 실행 허용)
--   * 모든 함수는 room_id 하나를 받아 그 모임 데이터만 다룸
--   * 모임 목록을 돌려주는 함수는 없음
--
-- 실시간
--   * 쓰기 함수가 끝나면 서버가 Realtime broadcast 로 알림을 보냄
--       채널(topic) = 모임 ID, 이벤트 = 'changed', 내용 = {} (데이터 없음)
--   * 화면은 알림을 받으면 get_room 으로 데이터를 다시 불러옴
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- 내부 도우미 함수 전용 스키마 (API로 노출되지 않음)
create schema if not exists moilnal_private;
revoke all on schema moilnal_private from public, anon, authenticated;


-- =====================================================================
-- 1. 테이블
-- =====================================================================

-- 모임(약속방)
create table if not exists public.rooms (
  id              text primary key
                  check (id ~ '^[A-Za-z0-9_-]{12,64}$'),
  size            smallint not null default 4
                  check (size between 2 and 15),           -- 전체 인원 (이름 있는 사람 + 빈자리)
  confirmed_date  date,                                      -- 확정 날짜 (없으면 null)
  confirmed_known uuid[] not null default '{}',              -- 확정할 때 이미 "안 된다"고 했던 사람들
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  last_seen_at    timestamptz not null default now()        -- 마지막 접속 (90일 미접속 삭제용)
);

-- 참여자
create table if not exists public.members (
  id          uuid primary key default gen_random_uuid(),
  room_id     text not null references public.rooms (id) on delete cascade,
  name        text not null check (char_length(name) between 1 and 20),
  emoji       text not null check (char_length(emoji) between 1 and 8),
  responded   boolean not null default false,               -- [완료]를 눌렀는지 (응답 완료)
  created_at  timestamptz not null default now(),
  unique (room_id, name),                                   -- 한 모임 안에서 이름 중복 불가
  unique (room_id, emoji),                                  -- 한 모임 안에서 이모지 중복 불가
  unique (id, room_id)                                      -- 아래 unavailable 의 묶음 외래키용
);

-- 안 되는 날 (날짜 단계 데이터)
create table if not exists public.unavailable (
  room_id     text not null references public.rooms (id) on delete cascade,
  member_id   uuid not null,
  day         date not null,
  created_at  timestamptz not null default now(),
  primary key (member_id, day),
  -- 참여자가 반드시 "같은 모임"의 사람이어야 함. 참여자를 지우면 그 사람 표시도 같이 지워짐
  foreign key (member_id, room_id) references public.members (id, room_id) on delete cascade
);
create index if not exists unavailable_room_day_idx on public.unavailable (room_id, day);

-- "처음부터 다시 만들기" 되돌리기용 보관함 (24시간)
create table if not exists public.room_reset_backups (
  room_id     text primary key references public.rooms (id) on delete cascade,
  snapshot    jsonb not null,
  expires_at  timestamptz not null
);

-- 나중에 시간/지역/장소/정산 단계는 위와 같은 방식으로
-- "room_id 를 가진 독립 테이블"을 새로 추가한다. (예: time_votes, places, expenses)


-- =====================================================================
-- 2. 보안: RLS 켜기 + 직접 접근 권한 회수
--    정책(policy)을 하나도 만들지 않으므로 anon/authenticated 는
--    테이블을 직접 읽거나 쓸 수 없다.
-- =====================================================================

alter table public.rooms              enable row level security;
alter table public.members            enable row level security;
alter table public.unavailable        enable row level security;
alter table public.room_reset_backups enable row level security;

-- 테이블 권한을 public(모든 역할), anon, authenticated 에서 전부 회수
-- (select/insert/update/delete/truncate/references/trigger 포함)
revoke all on table public.rooms, public.members, public.unavailable, public.room_reset_backups
  from public, anon, authenticated;


-- =====================================================================
-- 3. 내부 도우미 함수 (moilnal_private, 외부에서 호출 불가)
-- =====================================================================

-- 한국 시간 기준 오늘 날짜
create or replace function moilnal_private.kst_today()
returns date
language sql stable
set search_path = ''
as $$
  select (now() at time zone 'Asia/Seoul')::date
$$;

-- 앱에서 쓰는 24개 이모지만 허용
create or replace function moilnal_private.allowed_emojis()
returns text[]
language sql immutable
set search_path = ''
as $$
  select array[
    '🐶','🐱','🐭','🐹','🐰','🦊','🐻','🐼','🐨','🐯','🦁','🐮',
    '🐷','🐸','🐵','🐧','🐤','🦄','🐙','🐳','😀','😎','🤓','🥳'
  ]
$$;

-- 모임 ID 확인 + 그 모임 행을 잠금 (동시에 여러 명이 써도 인원 제한이 깨지지 않게)
-- ID 형식이 틀려도, 없는 모임이어도 똑같이 'room_not_found' (정보 노출 방지)
create or replace function moilnal_private.lock_room(p_room_id text)
returns public.rooms
language plpgsql
set search_path = ''
as $$
declare
  r public.rooms;
begin
  if p_room_id is null or p_room_id !~ '^[A-Za-z0-9_-]{12,64}$' then
    raise exception 'room_not_found';
  end if;
  select * into r from public.rooms where id = p_room_id for update;
  if not found then
    raise exception 'room_not_found';
  end if;
  return r;
end
$$;

-- 'YYYY-MM-DD' 문자열을 날짜로 (형식이 틀리면 'invalid_date')
create or replace function moilnal_private.parse_day(p_day text)
returns date
language plpgsql stable
set search_path = ''
as $$
begin
  if p_day is null or p_day !~ '^\d{4}-\d{2}-\d{2}$' then
    raise exception 'invalid_date';
  end if;
  begin
    return p_day::date;
  exception when others then
    raise exception 'invalid_date';      -- 예: 2026-02-30
  end;
end
$$;

-- 참여자가 이 모임 사람인지 확인
create or replace function moilnal_private.require_member(p_room_id text, p_member_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_member_id is null or not exists (
    select 1 from public.members where id = p_member_id and room_id = p_room_id
  ) then
    raise exception 'member_not_found';
  end if;
end
$$;

-- 변경이 끝난 뒤: 시각 기록 + 실시간 알림
create or replace function moilnal_private.after_change(p_room_id text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  update public.rooms
     set updated_at = now(), last_seen_at = now()
   where id = p_room_id;

  -- Realtime broadcast: 채널 = 모임 ID, 이벤트 = 'changed', private = false (공개 채널)
  -- 알림은 트랜잭션이 커밋된 뒤 전달되므로, 받은 쪽이 get_room 하면 새 데이터가 보인다.
  begin
    perform realtime.send('{}'::jsonb, 'changed', p_room_id, false);
  exception when others then
    null;  -- 실시간 알림이 실패해도 저장 자체는 성공시킨다
  end;
end
$$;


-- =====================================================================
-- 4. 공개 RPC 함수 (앱에서 supabase.rpc('함수이름', {...}) 로 호출)
--    모두 security definer: 함수 주인 권한으로 실행되므로 RLS를 지나갈 수 있지만,
--    함수 안에서 room_id 로 범위를 제한한다.
-- =====================================================================

-- 새 모임 만들기 → 새 모임 ID 반환
-- ID: 64가지 문자 × 16자리 = 96비트 난수 (추측 불가능)
create or replace function public.create_room()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_alphabet constant text :=
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  v_bytes bytea;
  v_id    text;
begin
  loop
    v_bytes := extensions.gen_random_bytes(16);
    v_id := '';
    for i in 0..15 loop
      v_id := v_id || substr(v_alphabet, (get_byte(v_bytes, i) & 63) + 1, 1);
    end loop;

    begin
      insert into public.rooms (id) values (v_id);
      return v_id;
    exception when unique_violation then
      null;  -- 극히 드물게 겹치면 다시 만든다
    end;
  end loop;
end
$$;

-- 모임 하나의 전체 데이터 읽기
-- 반환 예:
-- {
--   "id": "...", "size": 4,
--   "confirmed": {"date": "2026-11-07", "known": ["uuid", ...]} 또는 null,
--   "members": [{"id": "uuid", "name": "멍청", "emoji": "🐶", "responded": true}, ...],
--   "unavailable": {"2026-11-12": ["uuid", ...], ...},
--   "undo_until": "2026-11-07T12:00:00+00" 또는 null   ← 있으면 "초기화됨 · 되돌리기" 표시
-- }
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

  -- 마지막 접속 시각 (너무 자주 쓰지 않도록 1시간에 한 번만 갱신)
  if r.last_seen_at < now() - interval '1 hour' then
    update public.rooms set last_seen_at = now() where id = p_room_id;
  end if;

  return jsonb_build_object(
    'id',   r.id,
    'size', r.size,
    'confirmed', case
      when r.confirmed_date is null then null
      else jsonb_build_object('date', r.confirmed_date, 'known', to_jsonb(r.confirmed_known))
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
    'undo_until', (
      select b.expires_at
        from public.room_reset_backups b
       where b.room_id = r.id and b.expires_at > now()
    )
  );
end
$$;

-- 참여자 추가(p_member_id = null) 또는 수정(이름/이모지) → 참여자 id 반환
create or replace function public.save_member(
  p_room_id   text,
  p_member_id uuid,
  p_name      text,
  p_emoji     text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  r       public.rooms;
  v_name  text := btrim(p_name);
  v_id    uuid;
  v_count int;
begin
  select * into r from moilnal_private.lock_room(p_room_id);

  if v_name is null or char_length(v_name) not between 1 and 20 or v_name ~ '[[:cntrl:]]' then
    raise exception 'invalid_name';
  end if;
  if p_emoji is null or not (p_emoji = any (moilnal_private.allowed_emojis())) then
    raise exception 'invalid_emoji';
  end if;
  if exists (select 1 from public.members
              where room_id = p_room_id and name = v_name and id is distinct from p_member_id) then
    raise exception 'name_taken';
  end if;
  if exists (select 1 from public.members
              where room_id = p_room_id and emoji = p_emoji and id is distinct from p_member_id) then
    raise exception 'emoji_taken';
  end if;

  if p_member_id is null then
    -- 새 참여자: 빈자리가 있어야 함 (최대 15명)
    select count(*) into v_count from public.members where room_id = p_room_id;
    if v_count >= least(r.size, 15) then
      raise exception 'room_full';
    end if;
    insert into public.members (room_id, name, emoji)
    values (p_room_id, v_name, p_emoji)
    returning id into v_id;
  else
    update public.members
       set name = v_name, emoji = p_emoji
     where id = p_member_id and room_id = p_room_id
    returning id into v_id;
    if v_id is null then
      raise exception 'member_not_found';
    end if;
  end if;

  perform moilnal_private.after_change(p_room_id);
  return v_id;
end
$$;

-- 참여자 빼기 ([-]에서 "누구를 뺄까요?")
-- 그 사람의 안 되는 날도 함께 지워지고, 인원수도 1 줄어든다 (최소 2명)
create or replace function public.delete_member(p_room_id text, p_member_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform moilnal_private.lock_room(p_room_id);
  perform moilnal_private.require_member(p_room_id, p_member_id);

  delete from public.members where id = p_member_id and room_id = p_room_id;

  update public.rooms
     set size = greatest(2, size - 1),
         confirmed_known = array_remove(confirmed_known, p_member_id)
   where id = p_room_id;

  perform moilnal_private.after_change(p_room_id);
end
$$;

-- 인원수 바꾸기 ([+] / 빈자리 [-])
create or replace function public.set_room_size(p_room_id text, p_size int)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count int;
begin
  perform moilnal_private.lock_room(p_room_id);

  if p_size is null or p_size not between 2 and 15 then
    raise exception 'invalid_size';
  end if;
  select count(*) into v_count from public.members where room_id = p_room_id;
  if p_size < v_count then
    raise exception 'size_below_members';   -- 이름 있는 사람보다 적게 줄일 수 없음
  end if;

  update public.rooms set size = p_size where id = p_room_id;
  perform moilnal_private.after_change(p_room_id);
end
$$;

-- 안 되는 날 토글 → 바꾼 뒤 상태 반환 (true = 이제 안 되는 날)
create or replace function public.toggle_unavailable(p_room_id text, p_member_id uuid, p_day text)
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

  v_day := moilnal_private.parse_day(p_day);
  -- 지난 날짜는 표시할 수 없음. 너무 먼 미래도 막음 (약 1년)
  if v_day < moilnal_private.kst_today() or v_day > moilnal_private.kst_today() + 400 then
    raise exception 'date_out_of_range';
  end if;

  delete from public.unavailable where member_id = p_member_id and day = v_day;
  if found then
    v_now := false;
  else
    insert into public.unavailable (room_id, member_id, day) values (p_room_id, p_member_id, v_day);
    v_now := true;
  end if;

  perform moilnal_private.after_change(p_room_id);
  return v_now;
end
$$;

-- 응답 완료 표시 ([완료] 버튼)
create or replace function public.set_responded(p_room_id text, p_member_id uuid, p_responded boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform moilnal_private.lock_room(p_room_id);
  perform moilnal_private.require_member(p_room_id, p_member_id);

  update public.members
     set responded = coalesce(p_responded, false)
   where id = p_member_id and room_id = p_room_id;

  perform moilnal_private.after_change(p_room_id);
end
$$;

-- 날짜 확정 (p_day = 'YYYY-MM-DD') / 확정 취소 (p_day = null)
-- 확정은 한 번에 하나: 새로 확정하면 기존 확정은 바뀐다
create or replace function public.set_confirmed_date(p_room_id text, p_day text)
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
       set confirmed_date = null, confirmed_known = '{}'
     where id = p_room_id;
  else
    v_day := moilnal_private.parse_day(p_day);
    -- 오늘과 지난 날짜는 확정 불가
    if v_day <= moilnal_private.kst_today() or v_day > moilnal_private.kst_today() + 400 then
      raise exception 'date_out_of_range';
    end if;

    -- 확정 시점에 이미 안 된다고 한 사람은 기억 (나중에 "새로" 안 된다고 한 사람만 경고)
    update public.rooms
       set confirmed_date  = v_day,
           confirmed_known = array(
             select u.member_id from public.unavailable u
              where u.room_id = p_room_id and u.day = v_day
           )
     where id = p_room_id;
  end if;

  perform moilnal_private.after_change(p_room_id);
end
$$;

-- 처음부터 다시 만들기: 같은 링크 유지, 참여자/안 되는 날/확정 날짜 초기화 (기본 4명)
-- 초기화 직전 데이터는 24시간 보관 → undo_reset 으로 되돌릴 수 있음
create or replace function public.reset_room(p_room_id text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.rooms;
begin
  select * into r from moilnal_private.lock_room(p_room_id);

  -- 이미 빈 모임을 또 초기화하면, 앞서 보관해 둔 데이터를 덮어쓰지 않는다
  if r.confirmed_date is not null
     or r.size <> 4
     or exists (select 1 from public.members where room_id = p_room_id) then
    insert into public.room_reset_backups (room_id, snapshot, expires_at)
    values (
      p_room_id,
      jsonb_build_object(
        'size',            r.size,
        'confirmed_date',  r.confirmed_date,
        'confirmed_known', to_jsonb(r.confirmed_known),
        'members', coalesce((
          select jsonb_agg(jsonb_build_object(
                   'id', m.id, 'name', m.name, 'emoji', m.emoji,
                   'responded', m.responded, 'created_at', m.created_at))
            from public.members m where m.room_id = p_room_id
        ), '[]'::jsonb),
        'unavailable', coalesce((
          select jsonb_agg(jsonb_build_object(
                   'member_id', u.member_id, 'day', u.day, 'created_at', u.created_at))
            from public.unavailable u where u.room_id = p_room_id
        ), '[]'::jsonb)
      ),
      now() + interval '24 hours'
    )
    on conflict (room_id) do update
      set snapshot = excluded.snapshot, expires_at = excluded.expires_at;
  end if;

  delete from public.members where room_id = p_room_id;   -- 안 되는 날도 함께 지워짐
  update public.rooms
     set size = 4, confirmed_date = null, confirmed_known = '{}'
   where id = p_room_id;

  perform moilnal_private.after_change(p_room_id);
end
$$;

-- 초기화 되돌리기 (24시간 안에만)
-- 주의: 초기화 뒤에 새로 입력한 내용은 지워지고 초기화 직전 상태로 돌아간다
create or replace function public.undo_reset(p_room_id text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_snap jsonb;
begin
  perform moilnal_private.lock_room(p_room_id);

  select b.snapshot into v_snap
    from public.room_reset_backups b
   where b.room_id = p_room_id and b.expires_at > now();
  if not found then
    raise exception 'nothing_to_undo';
  end if;

  delete from public.members where room_id = p_room_id;

  update public.rooms
     set size            = (v_snap->>'size')::smallint,
         confirmed_date  = (v_snap->>'confirmed_date')::date,
         confirmed_known = array(
           select jsonb_array_elements_text(coalesce(v_snap->'confirmed_known', '[]'::jsonb))::uuid
         )
   where id = p_room_id;

  insert into public.members (id, room_id, name, emoji, responded, created_at)
  select x.id, p_room_id, x.name, x.emoji, x.responded, x.created_at
    from jsonb_to_recordset(v_snap->'members')
         as x(id uuid, name text, emoji text, responded boolean, created_at timestamptz);

  insert into public.unavailable (room_id, member_id, day, created_at)
  select p_room_id, x.member_id, x.day, x.created_at
    from jsonb_to_recordset(v_snap->'unavailable')
         as x(member_id uuid, day date, created_at timestamptz);

  delete from public.room_reset_backups where room_id = p_room_id;

  perform moilnal_private.after_change(p_room_id);
end
$$;


-- =====================================================================
-- 5. 정리 작업 (앱에서는 호출 불가, 서버 예약 작업 전용)
-- =====================================================================

-- 90일 동안 아무도 접속하지 않은 모임 + 기한 지난 되돌리기 보관함 삭제
create or replace function public.cleanup_inactive_rooms()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_deleted int;
begin
  delete from public.room_reset_backups where expires_at < now();
  delete from public.rooms where last_seen_at < now() - interval '90 days';
  get diagnostics v_deleted = row_count;
  return v_deleted;
end
$$;

-- 매일 새벽 4시(UTC)에 자동 실행하려면: 대시보드 > Database > Extensions 에서 pg_cron 을 켠 뒤
-- 아래 줄의 주석(--)을 지우고 실행
-- select cron.schedule('moilnal-cleanup', '0 4 * * *', $$select public.cleanup_inactive_rooms()$$);


-- =====================================================================
-- 6. 함수 실행 권한
--    PostgreSQL은 새 함수에 기본으로 public(모든 역할) 실행 권한을 주므로,
--    먼저 전부 회수한 뒤 앱이 써야 하는 함수만 anon 에게 다시 허용한다.
--    (앱은 로그인이 없어서 항상 anon 역할로 호출함 → authenticated 에는 주지 않음)
-- =====================================================================

-- anon 이 public 스키마의 RPC 를 부를 수 있도록 스키마 사용 권한 (이미 있어도 에러 없음)
grant usage on schema public to anon;

-- 내부 도우미 함수: 아무에게도 실행 권한 없음
revoke execute on all functions in schema moilnal_private from public, anon, authenticated;

revoke execute on function public.create_room()                              from public, anon, authenticated;
revoke execute on function public.get_room(text)                             from public, anon, authenticated;
revoke execute on function public.save_member(text, uuid, text, text)        from public, anon, authenticated;
revoke execute on function public.delete_member(text, uuid)                  from public, anon, authenticated;
revoke execute on function public.set_room_size(text, int)                   from public, anon, authenticated;
revoke execute on function public.toggle_unavailable(text, uuid, text)       from public, anon, authenticated;
revoke execute on function public.set_responded(text, uuid, boolean)         from public, anon, authenticated;
revoke execute on function public.set_confirmed_date(text, text)             from public, anon, authenticated;
revoke execute on function public.reset_room(text)                           from public, anon, authenticated;
revoke execute on function public.undo_reset(text)                           from public, anon, authenticated;
revoke execute on function public.cleanup_inactive_rooms()                   from public, anon, authenticated;

-- 앱에서 쓰는 RPC 10개만 anon 에게 실행 허용
grant execute on function public.create_room()                               to anon;
grant execute on function public.get_room(text)                              to anon;
grant execute on function public.save_member(text, uuid, text, text)         to anon;
grant execute on function public.delete_member(text, uuid)                   to anon;
grant execute on function public.set_room_size(text, int)                    to anon;
grant execute on function public.toggle_unavailable(text, uuid, text)        to anon;
grant execute on function public.set_responded(text, uuid, boolean)          to anon;
grant execute on function public.set_confirmed_date(text, text)              to anon;
grant execute on function public.reset_room(text)                            to anon;
grant execute on function public.undo_reset(text)                            to anon;

-- cleanup_inactive_rooms 는 위에서 public/anon/authenticated 모두 회수했고,
-- 여기서 다시 허용하지 않는다 (예약 작업만 실행, 함수 주인 postgres 권한으로 동작)
