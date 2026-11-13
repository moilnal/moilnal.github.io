-- =====================================================================
-- 모일날 003: 응답 간소화 (안 되는 날을 표시하면 자동으로 응답 완료)
--
-- 사용법: schema.sql, 002 를 실행한 프로젝트에서, 이 파일 전체를 SQL Editor 에 붙여넣고 Run.
--         여러 번 실행해도 에러가 나지 않게 작성됨.
--         기존 데이터를 지우는 명령(drop table / delete / truncate)은 쓰지 않는다.
--         (toggle_unavailable 함수 "안"의 delete 는 사용자가 X를 해제할 때만 동작)
--
-- 바뀌는 것
--   * toggle_unavailable : 토글 후 그 사람의 responded 를 자동으로 맞춤
--                          안 되는 날이 하나라도 있으면 true, 전부 해제하면 false
--   * 기존 데이터         : 안 되는 날이 있는데 미응답인 참여자를 응답 완료로 맞춤 (1회)
--   * set_responded       : 그대로 ([다 돼요 👍] 버튼이 사용)
-- =====================================================================


-- =====================================================================
-- 1. 안 되는 날 토글 → 응답 여부 자동 갱신 (반환: true = 이제 안 되는 날)
-- =====================================================================

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

  -- 하나라도 표시했으면 응답 완료, 전부 해제하면 다시 미응답
  update public.members m
     set responded = exists (select 1 from public.unavailable u where u.member_id = p_member_id)
   where m.id = p_member_id and m.room_id = p_room_id;

  perform moilnal_private.after_change(p_room_id);
  return v_now;
end
$$;


-- =====================================================================
-- 2. 기존 데이터 맞추기: 안 되는 날이 있는데 미응답인 사람 → 응답 완료
-- =====================================================================

update public.members m
   set responded = true
 where m.responded = false
   and exists (select 1 from public.unavailable u where u.member_id = m.id);


-- =====================================================================
-- 3. 권한 (anon 만 실행 가능, 그대로 유지)
-- =====================================================================

revoke execute on function public.toggle_unavailable(text, uuid, text) from public, anon, authenticated;
grant  execute on function public.toggle_unavailable(text, uuid, text) to anon;
