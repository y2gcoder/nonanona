-- 장부에 공유한 가림 사본의 위치·해시를 더한다(방장이 검토 화면에서 그 사본을 볼 수 있게, ADR-0006).
--
-- * 새로 드러나는 값은 없다. 구성원은 이미 RLS로 public.expenses의 artifact_path·artifact_sha256을 읽을 수 있다.
-- * 사본 바이트는 이 RPC가 아니라 비공개 버킷 receipts의 인증 다운로드로 받는다. 읽기 정책(receipts_member_read)은
--   그 방의 구성원만 허용한다. 공개 URL·서명 URL은 만들지 않는다.
-- * 확정본 스냅숏(compute_settlement → expense_json)은 바꾸지 않는다. 장부 응답에만 더한다.
create or replace function private.get_room_ledger(p_trip uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := private.require_uid(); v_trip public.trips; v_role text;
begin
  select m.role into v_role from public.trip_members m where m.trip_id = p_trip and m.user_id = v_uid;
  if v_role is null then perform private.fail('trip_not_found', 'PT404'); end if;
  select * into v_trip from public.trips where id = p_trip;
  return jsonb_build_object(
    'trip_id', v_trip.id, 'trip_name', v_trip.name, 'status', v_trip.status, 'revision', v_trip.revision,
    'my_role', v_role, 'me', v_uid,
    'members', (select coalesce(jsonb_agg(jsonb_build_object('user_id', m.user_id, 'display_name', m.display_name,
                 'role', m.role) order by m.joined_at, m.user_id), '[]'::jsonb)
                from public.trip_members m where m.trip_id = p_trip),
    'expenses', (select coalesce(jsonb_agg(private.expense_json(e)
                   || jsonb_build_object('artifact_path', e.artifact_path, 'artifact_sha256', e.artifact_sha256)
                   order by e.expense_date, e.created_at, e.id), '[]'::jsonb)
                 from public.expenses e where e.trip_id = p_trip),
    'finalization_id', (select f.id from public.finalizations f where f.trip_id = p_trip order by f.version desc limit 1));
end $$;
