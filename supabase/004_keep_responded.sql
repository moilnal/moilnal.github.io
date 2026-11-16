-- =====================================================================
-- 모일날 004: 응답 규칙 단순화 (한 번 응답하면 계속 응답 완료)
--
-- 사용법: schema.sql, 002, 003 을 실행한 프로젝트에서, 이 파일 전체를 SQL Editor 에 붙여넣고 Run.
--         여러 번 실행해도 에러가 나지 않게 작성됨.
--         기존 데이터를 지우는 명령(drop table / delete / truncate)은 쓰지 않는다.
--         (toggle_unavailable 함수 "안"의 delete 는 사용자가 X를 해제할 때만 동작)
--
-- 바뀌는 것
--   * toggle_unavailable : 안 되는 날을 표시하면 responded = true
--                          해제할 때는 responded 를 건드리지 않음 (전부 해제해도 응답 완료 유지)
--   * set_responded       : 그대로 ([다 돼요 👍] 버튼이 사용)
--   * 기존 데이터         : 보정 없음 (003 에서 이미 맞춰짐)
-- =====================================================================


-- =====================================================================
-- 1. 안 되는 날 토글 (반환: true = 이제 안 되는 날)
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

  -- 표시하면 응답 완료. 해제해도 응답 완료는 그대로 유지
  if v_now then
    update public.members m
       set responded = true
     where m.id = p_member_id and m.room_id = p_room_id;
  end if;

  perform moilnal_private.after_change(p_room_id);
  return v_now;
end
$$;


-- =====================================================================
-- 2. 권한 (anon 만 실행 가능, 그대로 유지)
-- =====================================================================

revoke execute on function public.toggle_unavailable(text, uuid, text) from public, anon, authenticated;
grant  execute on function public.toggle_unavailable(text, uuid, text) to anon;
