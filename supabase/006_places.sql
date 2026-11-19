-- =====================================================================
-- 모일날 006: 장소 단계 1차 (지도 링크 후보 + ❤️ 투표 + 확정) + 링크 미리보기 캐시
--
-- 사용법: schema.sql, 002, 003, 004, 005 를 실행한 프로젝트에서, 이 파일 전체를 SQL Editor 에 붙여넣고 Run.
--         여러 번 실행해도 에러가 나지 않게 작성됨.
--         기존 데이터를 지우는 명령(drop table / delete / truncate)은 쓰지 않는다.
--         (함수 "안"의 delete 는 사용자가 후보를 지우거나 ❤️를 끄거나 초기화할 때만 동작)
--
-- 바뀌는 것
--   * places               : 장소 후보 (지도 링크, 이름, 사진, 추가한 사람). 모임당 10개
--   * place_votes          : 장소 ❤️ 투표. 참여자를 지우면 그 사람 투표도 같이 지워짐
--   * link_previews        : 링크 미리보기 캐시 (Edge Function link-preview 가 service role 로만 사용)
--   * rooms.confirmed_place_id : 확정 장소
--   * add_place / rename_place / delete_place / toggle_place_vote / confirm_place
--   * get_room             : places, confirmed_place 포함
--   * reset_room / undo_reset : 장소 후보·투표·확정 장소까지 초기화하고 되돌리기로 복구
--                               (005 때 빠졌던 날짜 ❤️ 투표·확정 시각도 함께)
-- =====================================================================


-- =====================================================================
-- 1. 테이블
-- =====================================================================

-- 장소 후보
create table if not exists public.places (
  id          uuid primary key default gen_random_uuid(),
  room_id     text not null references public.rooms (id) on delete cascade,
  url         text not null check (url ~ '^https://\S+$' and char_length(url) <= 2000),
  title       text not null check (char_length(title) between 1 and 40),
  image       text check (image is null or (image ~ '^https://\S+$' and char_length(image) <= 2000)),
  added_by    uuid references public.members (id) on delete set null,   -- 참여자를 지워도 후보는 유지
  created_at  timestamptz not null default now(),
  unique (room_id, url),          -- 같은 링크는 한 번만
  unique (id, room_id)            -- 아래 place_votes 의 묶음 외래키용
);
create index if not exists places_room_idx on public.places (room_id, created_at);

-- 장소 ❤️ 투표 (여러 곳에 투표 가능)
create table if not exists public.place_votes (
  room_id     text not null references public.rooms (id) on delete cascade,
  member_id   uuid not null,
  place_id    uuid not null,
  created_at  timestamptz not null default now(),
  primary key (member_id, place_id),
  -- 같은 모임 참여자만. 참여자를 지우면 그 사람 투표도 같이 지워짐
  foreign key (member_id, room_id) references public.members (id, room_id) on delete cascade,
  -- 같은 모임 후보만. 후보를 지우면 투표도 같이 지워짐
  foreign key (place_id, room_id) references public.places (id, room_id) on delete cascade
);
create index if not exists place_votes_place_idx on public.place_votes (place_id);

-- 링크 미리보기 캐시 (url 기준, 7일 동안 재사용)
create table if not exists public.link_previews (
  url          text primary key,
  title        text not null default '',
  image        text,
  description  text not null default '',
  final_url    text,
  fetched_at   timestamptz not null default now()
);

-- 확정 장소 (후보를 지우면 확정도 비워짐)
alter table public.rooms
  add column if not exists confirmed_place_id uuid references public.places (id) on delete set null;

-- 보안: RLS 켜기 + 직접 접근 차단 (정책 없음 → RPC / service role 로만 접근)
alter table public.places        enable row level security;
alter table public.place_votes   enable row level security;
alter table public.link_previews enable row level security;
revoke all on table public.places, public.place_votes, public.link_previews
  from public, anon, authenticated;


-- =====================================================================
-- 2. 내부 도우미
-- =====================================================================

-- 장소 이름: 앞뒤 공백 제거, 연속 공백은 하나로, 1~40자
create or replace function moilnal_private.clean_place_title(p_title text)
returns text
language plpgsql immutable
set search_path = ''
as $$
declare
  v text;
begin
  v := btrim(regexp_replace(coalesce(p_title, ''), '\s+', ' ', 'g'));
  if char_length(v) < 1 or char_length(v) > 40 then
    raise exception 'invalid_place_title';
  end if;
  return v;
end
$$;

-- 장소가 이 모임 후보인지 확인
create or replace function moilnal_private.require_place(p_room_id text, p_place_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_place_id is null or not exists (
    select 1 from public.places where id = p_place_id and room_id = p_room_id
  ) then
    raise exception 'place_not_found';
  end if;
end
$$;


-- =====================================================================
-- 3. RPC
-- =====================================================================

-- 후보 올리기 (반환: 새 후보 id). p_member_id 는 이 기기의 "나" (없으면 null)
create or replace function public.add_place(
  p_room_id text, p_member_id uuid, p_url text, p_title text, p_image text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url   text;
  v_title text;
  v_image text;
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

  if exists (select 1 from public.places where room_id = p_room_id and url = v_url) then
    raise exception 'place_exists';
  end if;
  if (select count(*) from public.places where room_id = p_room_id) >= 10 then
    raise exception 'too_many_places';
  end if;

  insert into public.places (room_id, url, title, image, added_by)
  values (p_room_id, v_url, v_title, v_image, p_member_id)
  returning id into v_id;

  perform moilnal_private.after_change(p_room_id);
  return v_id;
end
$$;

-- 후보 이름 고치기
create or replace function public.rename_place(p_room_id text, p_place_id uuid, p_title text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform moilnal_private.lock_room(p_room_id);
  perform moilnal_private.require_place(p_room_id, p_place_id);

  update public.places
     set title = moilnal_private.clean_place_title(p_title)
   where id = p_place_id and room_id = p_room_id;

  perform moilnal_private.after_change(p_room_id);
end
$$;

-- 후보 삭제 (투표는 같이 지워지고, 확정 장소였으면 확정도 비워짐)
create or replace function public.delete_place(p_room_id text, p_place_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform moilnal_private.lock_room(p_room_id);
  perform moilnal_private.require_place(p_room_id, p_place_id);

  delete from public.places where id = p_place_id and room_id = p_room_id;

  perform moilnal_private.after_change(p_room_id);
end
$$;

-- 장소 ❤️ 켜기/끄기 (반환: true = 이제 ❤️)
create or replace function public.toggle_place_vote(p_room_id text, p_member_id uuid, p_place_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_now boolean;
begin
  perform moilnal_private.lock_room(p_room_id);
  perform moilnal_private.require_member(p_room_id, p_member_id);
  perform moilnal_private.require_place(p_room_id, p_place_id);

  delete from public.place_votes where member_id = p_member_id and place_id = p_place_id;
  if found then
    v_now := false;
  else
    insert into public.place_votes (room_id, member_id, place_id)
    values (p_room_id, p_member_id, p_place_id);
    v_now := true;
  end if;

  perform moilnal_private.after_change(p_room_id);
  return v_now;
end
$$;

-- 장소 확정 (p_place_id = null 이면 확정 취소)
create or replace function public.confirm_place(p_room_id text, p_place_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform moilnal_private.lock_room(p_room_id);
  if p_place_id is not null then
    perform moilnal_private.require_place(p_room_id, p_place_id);
  end if;

  update public.rooms set confirmed_place_id = p_place_id where id = p_room_id;

  perform moilnal_private.after_change(p_room_id);
end
$$;


-- =====================================================================
-- 4. get_room: 장소 후보 + 확정 장소 포함 (005 버전 + 추가)
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
                 'id', p.id, 'url', p.url, 'title', p.title, 'image', p.image, 'by', p.added_by,
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
-- 5. 처음부터 다시 만들기 / 되돌리기: 장소까지 (schema.sql 버전 + 추가)
--    snapshot 에 date_votes, confirmed_hour, places, place_votes, confirmed_place_id 추가
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
                   'id', p.id, 'url', p.url, 'title', p.title, 'image', p.image,
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

  insert into public.places (id, room_id, url, title, image, added_by, created_at)
  select x.id, p_room_id, x.url, x.title, x.image, x.added_by, x.created_at
    from jsonb_to_recordset(coalesce(v_snap->'places', '[]'::jsonb))
         as x(id uuid, url text, title text, image text, added_by uuid, created_at timestamptz);

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
-- 6. 함수 실행 권한 (anon 만, 내부 도우미/정리 함수는 막음)
-- =====================================================================

revoke execute on all functions in schema moilnal_private from public, anon, authenticated;

revoke execute on function public.add_place(text, uuid, text, text, text)        from public, anon, authenticated;
revoke execute on function public.rename_place(text, uuid, text)                 from public, anon, authenticated;
revoke execute on function public.delete_place(text, uuid)                       from public, anon, authenticated;
revoke execute on function public.toggle_place_vote(text, uuid, uuid)            from public, anon, authenticated;
revoke execute on function public.confirm_place(text, uuid)                      from public, anon, authenticated;
revoke execute on function public.get_room(text)                                 from public, anon, authenticated;
revoke execute on function public.reset_room(text)                               from public, anon, authenticated;
revoke execute on function public.undo_reset(text)                               from public, anon, authenticated;

grant execute on function public.add_place(text, uuid, text, text, text)         to anon;
grant execute on function public.rename_place(text, uuid, text)                  to anon;
grant execute on function public.delete_place(text, uuid)                        to anon;
grant execute on function public.toggle_place_vote(text, uuid, uuid)             to anon;
grant execute on function public.confirm_place(text, uuid)                       to anon;
grant execute on function public.get_room(text)                                  to anon;
grant execute on function public.reset_room(text)                                to anon;
grant execute on function public.undo_reset(text)                                to anon;

revoke execute on function public.cleanup_inactive_rooms()                       from public, anon, authenticated;
