-- 로컬 E2E용 가상 여행방과 초대. scripts/local-backend.py가 가상 계정을 만든 뒤 실행한다.
-- 초대 코드는 가상 값이며 서버에는 해시만 남는다. 실제 사용자 자료는 없다.
-- 흐름마다 여행방을 나눠, 다시 시도·다시 로그인 뒤의 수락이 반복 수락(replayed)이 아니라 새 수락이 되게 한다.
do $$
declare
  v_host uuid := (select id from auth.users where email = 'host.local@example.com');
  v_trip uuid;
  r record;
begin
  for r in
    select * from (values
      ('가상 오사카 여행', 'SYNTHLOCAL0001', interval '48 hours', false),     -- 정상 수락, 같은 계정의 반복 수락
      ('가상 오사카 여행', 'SYNTHLOCALEXPIRED', interval '-1 hour', false),   -- 만료
      ('가상 오사카 여행', 'SYNTHLOCALREVOKED', interval '48 hours', true),   -- 방장이 취소
      ('가상 교토 여행', 'SYNTHLOCALRETRY', interval '48 hours', false),      -- 연결 실패 뒤 다시 시도
      ('가상 나라 여행', 'SYNTHLOCALRELOG', interval '48 hours', false)       -- 세션 만료 뒤 다시 로그인
    ) as t(trip_name, code, expires_in, revoked)
  loop
    select id into v_trip from public.trips where name = r.trip_name;
    if v_trip is null then
      insert into public.trips (name, host_id) values (r.trip_name, v_host) returning id into v_trip;
      insert into public.trip_members (trip_id, user_id, role, display_name) values (v_trip, v_host, 'host', '다라');
    end if;
    insert into public.trip_invites (trip_id, token_hash, created_by, expires_at, revoked_at)
    values (v_trip, private.token_hash(r.code), v_host, now() + r.expires_in, case when r.revoked then now() end);
  end loop;
end $$;
