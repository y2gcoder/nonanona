-- 정산 흐름용 가상 여행방. scripts/local-backend.py가 가상 계정과 초대 여행방을 만든 뒤 실행한다.
-- 방장(다라)과 회원(가나)이 처음부터 구성원이다(초대 수락 흐름과 나눠 정산만 따로 검증한다). 실제 사용자 자료는 없다.
do $$
declare
  v_host uuid := (select id from auth.users where email = 'host.local@example.com');
  v_member uuid := (select id from auth.users where email = 'member.local@example.com');
  v_trip uuid;
begin
  insert into public.trips (name, host_id) values ('가상 후쿠오카 정산', v_host) returning id into v_trip;
  insert into public.trip_members (trip_id, user_id, role, display_name, joined_at) values
    (v_trip, v_host, 'host', '다라', now() - interval '2 minutes'),
    (v_trip, v_member, 'member', '가나', now() - interval '1 minute');
end $$;
