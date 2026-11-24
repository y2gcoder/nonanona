-- 확정 재시도의 revision 비교를 null-safe로 고친다(독립 리뷰 후속, ADR-0009 범위 안의 버그 수정).
--
-- 20261124150000의 private.finalize_settlement는 같은 request_id의 기존 확정본을 찾으면 `reviewed_revision <> p_expected_revision`
-- 일 때만 idempotency_conflict로 거절했다. p_expected_revision이 null이면 이 비교가 null(거짓 취급)이 되어, revision 없이 보낸
-- 같은 키가 기존 확정본을 그대로 돌려받았다. `is distinct from`으로 바꿔 null도 다른 내용으로 거절한다.
--
-- 본문은 20261124150000과 같고 그 한 줄만 다르다. 검사 순서(재시도 → 방장 → 상태 → 요청 키 → 오래된 revision → 확인 필요 →
-- 기준환율 정정)와 같은 키·같은 revision의 재시도 결과, 실행 권한(create or replace는 권한을 그대로 둔다)은 바뀌지 않는다.
-- 이미 확정한 스냅숏 행도 그대로다. 새 키에 null revision을 보내면 예전처럼 stale_revision(409)이다.

create or replace function private.finalize_settlement(p_trip uuid, p_expected_revision bigint, p_request_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_uid(); l record; v_f public.finalizations; v_calc jsonb; v_snapshot jsonb; v_rev bigint; v_ver int;
  v_fx jsonb;
begin
  select * into l from private.lock_trip(p_trip, v_uid);
  select * into v_f from public.finalizations where trip_id = p_trip and request_id = p_request_id;
  if found then
    -- null-safe: revision 없이(null) 보낸 같은 키는 기존 확정본을 돌려주지 않는다(전에는 <> 가 null이라 재시도로 통과했다).
    if v_f.reviewed_revision is distinct from p_expected_revision then perform private.fail('idempotency_conflict', 'PT409'); end if;
    return jsonb_build_object('finalization_id', v_f.id, 'version', v_f.version, 'replayed', true);
  end if;
  if l.role <> 'host' then perform private.fail('host_only', 'PT403'); end if;
  if (l.trip).status <> 'open' then perform private.fail('trip_finalized', 'PT409'); end if;
  if p_request_id is null then perform private.fail('invalid_fields', 'PT400'); end if;
  if (l.trip).revision is distinct from p_expected_revision then
    perform private.fail_with('stale_revision', 'PT409', jsonb_build_object(
      'current_revision', (l.trip).revision,
      'changes', (select coalesce(jsonb_agg(jsonb_build_object('revision', e.revision, 'action', e.action, 'target', e.target)
                    order by e.revision), '[]'::jsonb)
                  from public.trip_events e where e.trip_id = p_trip and e.revision > p_expected_revision)));
  end if;
  v_calc := private.compute_settlement(p_trip);
  if jsonb_array_length(v_calc -> 'pending_expense_ids') > 0 then
    perform private.fail_with('pending_review', 'PT409', jsonb_build_object('expense_ids', v_calc -> 'pending_expense_ids'));
  end if;
  -- 받기와 직렬화한다: 진행 중인 받기가 있으면 끝날 때까지 기다린 뒤, 커밋된 모든 고시값으로 본다.
  perform private.fx_lock(false);
  v_fx := private.fx_blocking_ids(p_trip);
  if jsonb_array_length(v_fx) > 0 then
    perform private.fail_with('fx_correction_required', 'PT409', jsonb_build_object('expense_ids', v_fx));
  end if;
  select coalesce(max(version), 0) + 1 into v_ver from public.finalizations where trip_id = p_trip;
  v_rev := private.bump(p_trip, v_uid, 'trip_finalized', p_trip);
  update public.trips set status = 'finalized' where id = p_trip;
  v_snapshot := jsonb_build_object(
    'rule_version', 'explicit-krw-shares-v2',
    'trip_id', p_trip, 'trip_name', (l.trip).name, 'reviewed_revision', p_expected_revision,
    'inputs', jsonb_build_object('members', v_calc -> 'members', 'expenses', v_calc -> 'expenses'),
    'outputs', jsonb_build_object('included_total_krw', v_calc -> 'included_total_krw',
      'estimated_total_krw', v_calc -> 'estimated_total_krw', 'balances', v_calc -> 'balances',
      'transfers', v_calc -> 'transfers', 'excluded', v_calc -> 'excluded'));
  insert into public.finalizations (trip_id, version, reviewed_revision, request_id, finalized_by, rule_version,
      included_total_krw, snapshot, snapshot_sha256)
    values (p_trip, v_ver, p_expected_revision, p_request_id, v_uid, 'explicit-krw-shares-v2',
      (v_calc ->> 'included_total_krw')::bigint, v_snapshot, encode(sha256(convert_to(v_snapshot::text, 'UTF8')), 'hex'))
    returning * into v_f;
  return jsonb_build_object('finalization_id', v_f.id, 'version', v_f.version, 'replayed', false, 'revision', v_rev);
end $$;
