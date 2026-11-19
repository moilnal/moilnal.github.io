-- =====================================================================
-- 모일날 007: 장소 후보에 주소 추가
--
-- 사용법: schema.sql ~ 006 을 실행한 프로젝트에서, 이 파일 전체를 SQL Editor 에 붙여넣고 Run.
--         여러 번 실행해도 에러가 나지 않게 작성됨.
--         기존 데이터를 지우는 명령(drop table / delete / truncate)은 쓰지 않는다.
--         (아래 drop function 은 인자가 바뀐 예전 add_place 함수만 지움. 데이터는 그대로)
--
-- 바뀌는 것
--   * places.address       : 주소 (선택, 80자)
--   * add_place            : p_address 인자 추가 (인자 6개)
--   * get_room             : places[].address 포함
--   * reset_room / undo_reset : 주소도 보관/복구
-- =====================================================================


-- =====================================================================
-- 1. 테이블
-- =====================================================================

alter table public.places
  add column if not exists address text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'places_address_check') then
    alter table public.places
      add constraint places_address_check check (address is null or char_length(address) between 1 and 80);
  end if;
end
$$;


-- =====================================================================
-- 2. add_place: 주소 인자 추가 (예전 5개 인자 버전은 지움)
-- =====================================================================

drop function if exists public.add_place(text, uuid, text, text, text);

-- 후보 올리기 (반환: 새 후보 id). p_member_id 는 이 기기의 "나" (없으면 null)
create or replace function public.add_place(
  p_room_id text, p_member_id uuid, p_url text, p_title text, p_image text, p_address text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url   text;
  v_title text;
  v_image text;
  v_addr  text;
  v_id    uuid;
begin
  perform moilnal_private.lock_room(p_room_id);
  if p_member_id is not null then
    perform moilnal_private.require_member(p_room_id, p_member_id);
  end if;

  v_url := btrim(coalesce(p_url, ''));
  if v_url !~ '^https://\S+$' or char_length(v_url) > 2000 then
    raise exception 'invalid_url';
  end if;
  v_title := moilnal_private.clean_place_title(p_title);

  -- 사진은 https 만, 아니면 사진 없이
  v_image := nullif(btrim(coalesce(p_image, '')), '');
  if v_image is not null and (v_image !~ '^https://\S+$' or char_length(v_image) > 2000) then
    v_image := null;
  end if;

  -- 주소는 선택: 공백 정리, 80자까지 (넘으면 자름)
  v_addr := nullif(btrim(regexp_replace(coalesce(p_address, ''), '\s+', ' ', 'g')), '');
  if v_addr is not null and char_length(v_addr) > 80 then
    v_addr := btrim(left(v_addr, 80));
  end if;

  if exists (select 1 from public.places where room_id = p_room_id and url = v_url) then
    raise exception 'place_exists';
  end if;
  if (select count(*) from public.places where room_id = p_room_id) >= 10 then
    raise exception 'too_many_places';
  end if;

  insert into public.places (room_id, url, title, image, address, added_by)
  values (p_room_id, v_url, v_title, v_image, v_addr, p_member_id)
  returning id into v_id;

  perform moilnal_private.after_change(p_room_id);
  return v_id;
end
$$;



-- =====================================================================
-- 3. get_room: 장소 주소 포함 (006 버전 + address)
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
    'places', coalesce((
      select jsonb_agg(
               jsonb_build_object(
                 'id', p.id, 'url', p.url, 'title', p.title, 'image', p.image, 'address', p.address,
                 'by', p.added_by,
                 'votes', coalesce((
                   select jsonb_agg(pv.member_id order by pv.created_at, pv.member_id)
                     from public.place_votes pv
                    where pv.place_id = p.id
                 ), '[]'::jsonb))
               order by p.created_at, p.id)
        from public.places p
       where p.room_id = r.id
    ), '[]'::jsonb),
    'confirmed_place', r.confirmed_place_id,
    'undo_until', (
      select b.expires_at
        from public.room_reset_backups b
       where b.room_id = r.id and b.expires_at > now()
    )
  );
end
$$;



-- =====================================================================
-- 4. 처음부터 다시 만들기 / 되돌리기: 주소도 보관/복구 (006 버전 + address)
-- =====================================================================

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
     or r.confirmed_place_id is not null
     or r.size <> 4
     or exists (select 1 from public.members where room_id = p_room_id)
     or exists (select 1 from public.places  where room_id = p_room_id) then
    insert into public.room_reset_backups (room_id, snapshot, expires_at)
    values (
      p_room_id,
      jsonb_build_object(
        'size',               r.size,
        'confirmed_date',     r.confirmed_date,
        'confirmed_known',    to_jsonb(r.confirmed_known),
        'confirmed_hour',     r.confirmed_hour,
        'confirmed_place_id', r.confirmed_place_id,
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
        ), '[]'::jsonb),
        'date_votes', coalesce((
          select jsonb_agg(jsonb_build_object(
                   'member_id', v.member_id, 'day', v.day,
                   'start_hour', v.start_hour, 'end_hour', v.end_hour, 'created_at', v.created_at))
            from public.date_votes v where v.room_id = p_room_id
        ), '[]'::jsonb),
        'places', coalesce((
          select jsonb_agg(jsonb_build_object(
                   'id', p.id, 'url', p.url, 'title', p.title, 'image', p.image, 'address', p.address,
                   'added_by', p.added_by, 'created_at', p.created_at))
            from public.places p where p.room_id = p_room_id
        ), '[]'::jsonb),
        'place_votes', coalesce((
          select jsonb_agg(jsonb_build_object(
                   'member_id', pv.member_id, 'place_id', pv.place_id, 'created_at', pv.created_at))
            from public.place_votes pv where pv.room_id = p_room_id
        ), '[]'::jsonb)
      ),
      now() + interval '24 hours'
    )
    on conflict (room_id) do update
      set snapshot = excluded.snapshot, expires_at = excluded.expires_at;
  end if;

  delete from public.places  where room_id = p_room_id;   -- 장소 투표·확정 장소도 함께
  delete from public.members where room_id = p_room_id;   -- 안 되는 날·날짜 ❤️도 함께
  update public.rooms
     set size = 4, confirmed_date = null, confirmed_known = '{}',
         confirmed_hour = null, confirmed_place_id = null
   where id = p_room_id;

  perform moilnal_private.after_change(p_room_id);
end
$$;

-- 초기화 되돌리기 (24시간 안에만)
-- 주의: 초기화 뒤에 새로 입력한 내용은 지워지고 초기화 직전 상태로 돌아간다
-- 006 이전에 보관한 snapshot 에는 장소/날짜 ❤️ 키가 없으므로 빈 목록으로 처리
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

  delete from public.places  where room_id = p_room_id;
  delete from public.members where room_id = p_room_id;

  update public.rooms
     set size               = (v_snap->>'size')::smallint,
         confirmed_date     = (v_snap->>'confirmed_date')::date,
         confirmed_known    = array(
           select jsonb_array_elements_text(coalesce(v_snap->'confirmed_known', '[]'::jsonb))::uuid
         ),
         confirmed_hour     = (v_snap->>'confirmed_hour')::smallint,
         confirmed_place_id = null
   where id = p_room_id;

  insert into public.members (id, room_id, name, emoji, responded, created_at)
  select x.id, p_room_id, x.name, x.emoji, x.responded, x.created_at
    from jsonb_to_recordset(coalesce(v_snap->'members', '[]'::jsonb))
         as x(id uuid, name text, emoji text, responded boolean, created_at timestamptz);

  insert into public.unavailable (room_id, member_id, day, created_at)
  select p_room_id, x.member_id, x.day, x.created_at
    from jsonb_to_recordset(coalesce(v_snap->'unavailable', '[]'::jsonb))
         as x(member_id uuid, day date, created_at timestamptz);

  insert into public.date_votes (room_id, member_id, day, start_hour, end_hour, created_at)
  select p_room_id, x.member_id, x.day, x.start_hour, x.end_hour, x.created_at
    from jsonb_to_recordset(coalesce(v_snap->'date_votes', '[]'::jsonb))
         as x(member_id uuid, day date, start_hour smallint, end_hour smallint, created_at timestamptz);

  insert into public.places (id, room_id, url, title, image, address, added_by, created_at)
  select x.id, p_room_id, x.url, x.title, x.image, x.address, x.added_by, x.created_at
    from jsonb_to_recordset(coalesce(v_snap->'places', '[]'::jsonb))
         as x(id uuid, url text, title text, image text, address text, added_by uuid, created_at timestamptz);

  insert into public.place_votes (room_id, member_id, place_id, created_at)
  select p_room_id, x.member_id, x.place_id, x.created_at
    from jsonb_to_recordset(coalesce(v_snap->'place_votes', '[]'::jsonb))
         as x(member_id uuid, place_id uuid, created_at timestamptz);

  update public.rooms
     set confirmed_place_id = (v_snap->>'confirmed_place_id')::uuid
   where id = p_room_id;

  delete from public.room_reset_backups where room_id = p_room_id;

  perform moilnal_private.after_change(p_room_id);
end
$$;


-- =====================================================================
-- 5. 함수 실행 권한 (anon 만, 내부 도우미/정리 함수는 막음)
-- =====================================================================

revoke execute on all functions in schema moilnal_private from public, anon, authenticated;

revoke execute on function public.add_place(text, uuid, text, text, text, text)  from public, anon, authenticated;
revoke execute on function public.get_room(text)                                 from public, anon, authenticated;
revoke execute on function public.reset_room(text)                               from public, anon, authenticated;
revoke execute on function public.undo_reset(text)                               from public, anon, authenticated;

grant execute on function public.add_place(text, uuid, text, text, text, text)   to anon;
grant execute on function public.get_room(text)                                  to anon;
grant execute on function public.reset_room(text)                                to anon;
grant execute on function public.undo_reset(text)                                to anon;

revoke execute on function public.cleanup_inactive_rooms()                       from public, anon, authenticated;
