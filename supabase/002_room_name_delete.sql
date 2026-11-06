-- =====================================================================
-- 모일날 002: 모임명 + 모임 삭제(soft delete)
--
-- 사용법: schema.sql 을 실행한 프로젝트에서, 이 파일 전체를 SQL Editor 에 붙여넣고 Run.
--         여러 번 실행해도 에러가 나지 않게 작성됨.
--         기존 데이터를 지우는 명령(drop table / delete / truncate)은 이 파일을 실행할 때 쓰지 않는다.
--         (cleanup_inactive_rooms 함수 "안"의 delete 는 예약 작업이 실행할 때만 동작)
--
-- 바뀌는 것
--   * rooms.name        : 모임명 (기본 '새 모임', 1~20자)
--   * rooms.deleted_at  : 모임 삭제 시각 (null = 살아있음). 24시간 안에는 복구 가능
--   * 새 RPC            : set_room_name, delete_room, restore_room
--   * get_room          : name 포함. 삭제된 모임이면 데이터 대신 { deleted: true, restore_until } 만 반환
--   * 쓰기 RPC 전체     : 삭제된 모임에는 쓸 수 없음 ('room_deleted')
--   * cleanup           : 삭제 후 24시간 지난 모임도 완전 삭제
-- =====================================================================


-- =====================================================================
-- 1. 컬럼 추가 (이미 있으면 건너뜀)
-- =====================================================================

alter table public.rooms
  add column if not exists name text not null default '새 모임'
  check (char_length(name) between 1 and 20);

alter table public.rooms
  add column if not exists deleted_at timestamptz;


-- =====================================================================
-- 2. 내부 도우미: 모임 잠금 (삭제된 모임이면 'room_deleted')
--    기존 쓰기 RPC들이 모두 이 함수를 거치므로, 여기만 바꾸면 삭제된 모임에 쓰기가 막힌다.
-- =====================================================================

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
  if r.deleted_at is not null then
    raise exception 'room_deleted';
  end if;
  return r;
end
$$;

-- 모임명 검사: 앞뒤 공백 제거 후 1~20자, 제어 문자 금지
create or replace function moilnal_private.clean_room_name(p_name text)
returns text
language plpgsql immutable
set search_path = ''
as $$
declare
  v text := btrim(p_name);
begin
  if v is null or char_length(v) not between 1 and 20 or v ~ '[[:cntrl:]]' then
    raise exception 'invalid_room_name';
  end if;
  return v;
end
$$;


-- =====================================================================
-- 3. get_room: 모임명 포함 + 삭제된 모임 처리
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


-- =====================================================================
-- 4. 새 RPC
-- =====================================================================

-- 모임 이름 바꾸기
create or replace function public.set_room_name(p_room_id text, p_name text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text;
begin
  perform moilnal_private.lock_room(p_room_id);
  v_name := moilnal_private.clean_room_name(p_name);

  update public.rooms set name = v_name where id = p_room_id;
  perform moilnal_private.after_change(p_room_id);   -- 친구 화면에 알림
end
$$;

-- 모임 삭제 (soft delete): 데이터는 남겨두고 삭제 시각만 기록. 24시간 안에 복구 가능
create or replace function public.delete_room(p_room_id text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform moilnal_private.lock_room(p_room_id);    -- 이미 삭제된 모임이면 'room_deleted'

  update public.rooms set deleted_at = now() where id = p_room_id;
  perform moilnal_private.after_change(p_room_id);   -- 친구 화면에 알림 → "삭제된 모임이에요"
end
$$;

-- 모임 복구 (삭제 후 24시간 이내만)
create or replace function public.restore_room(p_room_id text)
returns void
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
  select * into r from public.rooms where id = p_room_id for update;
  if not found then
    raise exception 'room_not_found';
  end if;

  if r.deleted_at is null then
    return;   -- 이미 살아있는 모임: 아무것도 안 함
  end if;
  if r.deleted_at < now() - interval '24 hours' then
    raise exception 'restore_expired';
  end if;

  update public.rooms set deleted_at = null where id = p_room_id;
  perform moilnal_private.after_change(p_room_id);   -- 친구 화면에 알림 → 다시 달력 표시
end
$$;


-- =====================================================================
-- 5. 정리 작업: 90일 미접속 + 삭제 후 24시간 지난 모임 완전 삭제
--    (예약 작업 전용, 앱에서는 호출 불가)
-- =====================================================================

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
  delete from public.rooms
   where last_seen_at < now() - interval '90 days'
      or (deleted_at is not null and deleted_at < now() - interval '24 hours');
  get diagnostics v_deleted = row_count;
  return v_deleted;
end
$$;


-- =====================================================================
-- 6. 함수 실행 권한
-- =====================================================================

-- 내부 도우미: 아무에게도 실행 권한 없음 (새로 만든 clean_room_name 포함)
revoke execute on all functions in schema moilnal_private from public, anon, authenticated;

-- 새 RPC 3개 + 다시 만든 get_room: 먼저 전부 회수한 뒤 anon 에게만 허용
revoke execute on function public.get_room(text)             from public, anon, authenticated;
revoke execute on function public.set_room_name(text, text)  from public, anon, authenticated;
revoke execute on function public.delete_room(text)          from public, anon, authenticated;
revoke execute on function public.restore_room(text)         from public, anon, authenticated;

grant execute on function public.get_room(text)              to anon;
grant execute on function public.set_room_name(text, text)   to anon;
grant execute on function public.delete_room(text)           to anon;
grant execute on function public.restore_room(text)          to anon;

-- 정리 함수는 기존처럼 막아둠
revoke execute on function public.cleanup_inactive_rooms()   from public, anon, authenticated;
