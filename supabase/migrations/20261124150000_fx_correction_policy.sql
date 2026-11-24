-- 확정 전 기준환율 정정 정책(ADR-0009). ADR-0008의 "포함한 예상액 뒤 더 새 고시값은 알리기만 한다"를 바꾼다.
--
-- * 무엇이 "정정"인가: 포함한 예상액(status=included, krw_basis=reference_rate_estimate)이 고정한 고시값과, 지금 그 지출일에
--   적용되는 고시값의 실질 식별(기준일·고시값·단위·출처 종류 ecos_live|fixture)이 다르다. 받기 기록·quote_id만 다른 같은 값의
--   다시 받기는 정정이 아니다. 검토 승인(stale_quote)과 장부 알림(fx_superseded)·확정 차단이 같은 비교(fx_identity)를 쓴다.
--   ADR-0008 뒤 남아 있던 차이(검토는 출처 종류를 비교하고 알림은 비교하지 않음)를 없앤다.
-- * 확정 차단: 정정된 포함 예상액이 하나라도 있으면 첫 확정을 fx_correction_required(409)로 거절한다. 방장이 둘 중 하나를 골라야 한다.
--   - 고정 금액 유지(keep_fx_estimate): 방장이 본 새 고시값의 실질 식별을 그 지출·버전에 묶어 불변 기록으로 남긴다. 금액·몫·기준은
--     그대로이고 계속 "예상 금액"으로 보인다. 지출 버전과 방 revision이 오른다. 그 뒤 지출이 다시 검토되거나(버전 변화) 실질적으로
--     다른 고시값이 한 번이라도 적용되면(또 다른 정정) 그 기록은 효력을 잃는다. 같은 값의 다시 받기는 효력을 잃게 하지 않는다.
--   - 새 예상액 적용: 기존 검토(review_expense)로 새 고시값과 방장이 보낸 몫을 다시 포함한다. 서버는 몫을 고치지 않는다.
-- * 정정 뒤 그 지출일에 쓸 고시값이 없어지면(undetermined·unavailable) 고정 금액 유지도 새 값 적용도 할 수 없다. 자동 재계산 없이
--   기존 검토로 보류하거나 실제 청구액·환전 원가로 다시 포함해야 확정할 수 있다(기다려서 고시값이 다시 생기면 다시 고를 수 있다).
-- * 동시성: 받기(ingest_fx_response)는 기준환율 잠금을 배타로, 검토(예상액)·유지·확정은 공유로 잡은 뒤 지금의 고시값을 본다.
--   그래서 확정과 받기는 어느 한쪽이 끝난 뒤에 다른 쪽이 진행된다. 받기 기록의 fetched_at은 잠금을 잡은 뒤의 시각(clock_timestamp)
--   이고, 지금의 고시값은 트랜잭션 시작 시각이 아니라 커밋된 모든 받기 기록으로 정한다.
-- * 그대로인 것: 이미 확정한 v1·v2 스냅숏(행 불변), 확정 재시도(같은 request_id는 검사 없이 같은 결과), 오래된 revision 거절 순서,
--   요청 지문, 스냅숏 모양(v2, 유지 결정은 스냅숏에 넣지 않고 fx_keep_decisions에 남는다).
--
-- 실패 코드(추가): fx_correction_required(409, detail.expense_ids), fx_not_superseded(409: 유지할 정정이 없음),
-- fx_replacement_unavailable(409: 새 고시값이 없어 유지·적용 불가, detail.fx_proposal). keep_fx_estimate는 stale_quote(409)·
-- stale_expense(409)·host_only(403)·trip_finalized(409)·trip_not_found(404)·idempotency_conflict(409)·invalid_fields(400)도 쓴다.

-- ---------------------------------------------------------------- 기준환율 잠금(받기 ↔ 검토·유지·확정)
create function private.fx_lock(p_exclusive boolean) returns void
language plpgsql set search_path = '' as $$
begin
  if p_exclusive then
    perform pg_advisory_xact_lock(20261124, 1508);
  else
    perform pg_advisory_xact_lock_shared(20261124, 1508);
  end if;
end $$;

-- ---------------------------------------------------------------- 실질 식별(하나의 비교)
-- 고시값은 numeric 값으로 비교한다(905.25와 905.2500은 같다). quote_id·받기 기록·받은 시각은 넣지 않는다.
create function private.fx_identity(p_rate_date date, p_rate numeric, p_unit integer, p_origin text) returns text
language sql immutable set search_path = '' as $$
  select concat_ws('|', 'proposed', p_rate_date, trim_scale(p_rate), p_unit, p_origin)
$$;

-- 제안(fx_proposal)의 식별. 고시값이 없으면 상태(+확인 못 한 날짜)만.
create function private.fx_proposal_identity(p jsonb) returns text
language sql immutable set search_path = '' as $$
  select case when p is null then null
    when p ->> 'status' = 'proposed' then private.fx_identity((p ->> 'rate_date')::date, (p ->> 'rate')::numeric,
      (p ->> 'quote_unit')::integer, p ->> 'data_origin')
    else concat_ws('|', p ->> 'status', coalesce(p ->> 'missing_date', '-')) end
$$;

-- 지출에 고정한 고시값의 식별(출처 종류는 고정한 고시값의 받기 기록에서).
create function private.fx_pinned_identity(e public.expenses) returns text
language sql stable set search_path = '' as $$
  select private.fx_identity(e.fx_rate_date, e.fx_rate, e.fx_quote_unit, i.data_origin)
  from public.fx_quotes q join public.fx_ingestions i on i.id = q.ingestion_id where q.id = e.fx_quote_id
$$;

-- 지금 그 지출일에 적용되는 제안: 커밋된 모든 받기 기록으로(트랜잭션 시작 시각으로 자르지 않는다).
create function private.fx_current(e public.expenses) returns jsonb
language sql stable set search_path = '' as $$
  select private.fx_proposal(e.currency, e.expense_date, e.amount_minor, 'infinity'::timestamptz)
$$;

-- 포함·보류와 상관없이, 예상액 기준의 고정 고시값이 지금 제안과 실질적으로 다른가(장부 알림).
create or replace function private.fx_superseded(e public.expenses) returns boolean
language sql stable set search_path = '' as $$
  select e.krw_basis is not distinct from 'reference_rate_estimate'
    and private.fx_pinned_identity(e) is distinct from private.fx_proposal_identity(private.fx_current(e))
$$;

-- ---------------------------------------------------------------- 고정 금액 유지 결정(불변 기록)
create table public.fx_keep_decisions (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.trips (id),
  expense_id uuid not null references public.expenses (id),
  -- 유지 뒤의 지출 버전. 이 버전일 때만 효력이 있다(다시 검토하면 버전이 올라 효력을 잃는다).
  expense_version integer not null check (expense_version >= 1),
  pinned_quote_id uuid not null references public.fx_quotes (id),
  -- 방장이 본 새 고시값과 그 실질 식별.
  replacement_quote_id uuid not null references public.fx_quotes (id),
  replacement_rate numeric not null check (replacement_rate > 0),
  replacement_rate_date date not null,
  replacement_quote_unit integer not null check (replacement_quote_unit = 100),
  replacement_data_origin text not null check (replacement_data_origin in ('ecos_live', 'fixture')),
  request_id uuid not null,
  decided_by uuid not null references auth.users (id),
  -- 기준환율 잠금을 잡은 뒤의 시각. 이 뒤의 받기 기록은 모두 이 결정 뒤에 커밋됐다.
  decided_at timestamptz not null,
  unique (expense_id, expense_version)
);
create index fx_keep_decisions_trip_idx on public.fx_keep_decisions (trip_id);
create index fx_keep_decisions_pinned_idx on public.fx_keep_decisions (pinned_quote_id);
create index fx_keep_decisions_replacement_idx on public.fx_keep_decisions (replacement_quote_id);
create index fx_keep_decisions_decided_by_idx on public.fx_keep_decisions (decided_by);
create trigger fx_keep_decisions_immutable before update or delete on public.fx_keep_decisions
  for each row execute function private.reject_fx_mutation();
alter table public.fx_keep_decisions enable row level security;
-- 앱 역할은 표를 직접 읽지 못한다. 장부가 지출마다 fx_correction 상태로만 알려 준다.
revoke all on public.fx_keep_decisions from public, anon, authenticated, service_role;

-- 이 지출의 지금 유지 결정이 효력이 있는가: 같은 버전이고, 결정 뒤의 모든 받기 시점에 적용 고시값의 실질 식별이 결정 때와 같았다.
-- (A→B 유지 → C → B로 돌아와도 C가 한 번 적용됐으므로 효력이 없다. 같은 값 다시 받기는 식별이 같아 효력이 그대로다.)
create function private.fx_keep_valid(e public.expenses) returns boolean
language sql stable set search_path = '' as $$
  select exists (
    select 1 from public.fx_keep_decisions k
    cross join lateral (select private.fx_identity(k.replacement_rate_date, k.replacement_rate, k.replacement_quote_unit,
                          k.replacement_data_origin) as ident) x
    where k.expense_id = e.id and k.expense_version = e.version
      and private.fx_proposal_identity(private.fx_current(e)) = x.ident
      and not exists (
        select 1 from public.fx_ingestions r
        where r.currency = 'JPY' and r.fetched_at > k.decided_at
          and private.fx_proposal_identity(private.fx_proposal(e.currency, e.expense_date, e.amount_minor, r.fetched_at))
              is distinct from x.ident))
$$;

-- 포함한 예상액의 정정 상태. null: 해당 없음(포함한 예상액이 아니거나 고정 고시값이 지금도 적용됨).
-- required: 정정됨, 방장 결정 필요(확정 차단). kept: 방장이 고정 금액 유지를 골랐고 그 결정이 유효함.
-- unavailable: 정정 뒤 쓸 고시값이 없음(확정 차단, 보류·실제 청구액·환전 원가로만 풀 수 있음).
create function private.fx_correction(e public.expenses) returns text
language sql stable set search_path = '' as $$
  select case
    when e.status is distinct from 'included' or e.krw_basis is distinct from 'reference_rate_estimate' then null
    else (select case
            when private.fx_pinned_identity(e) is not distinct from private.fx_proposal_identity(c.p) then null
            when c.p ->> 'status' is distinct from 'proposed' then 'unavailable'
            when private.fx_keep_valid(e) then 'kept'
            else 'required' end
          from (select private.fx_current(e) as p) c)
  end
$$;

-- ---------------------------------------------------------------- 받기: 배타 잠금, 잠금 뒤 시각
-- 본문은 20261124130000과 같고, 맨 앞의 잠금과 fetched_at(clock_timestamp)만 다르다.
create or replace function private.ingest_fx_response(p_response jsonb, p_start date, p_end date, p_origin text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_rows jsonb; v_row jsonb; v_count int; v_date date; v_dates date[] := '{}'; v_values text[] := '{}';
  v_id uuid; v_today date := (now() at time zone 'Asia/Seoul')::date;
begin
  perform private.fx_lock(true);
  if p_origin is null or p_origin not in ('ecos_live', 'fixture') then perform private.fail('fx_response_invalid', 'PT400'); end if;
  if p_start is null or p_end is null or p_start > p_end or p_end >= v_today or p_end - p_start > 366 then
    perform private.fail('fx_range_invalid', 'PT400');
  end if;
  if p_response is null or jsonb_typeof(p_response) <> 'object' then perform private.fail('fx_response_invalid', 'PT400'); end if;

  if p_response ? 'RESULT' then
    -- 데이터 없음(INFO-200)만 빈 결과로 받는다. 인증키·요청·서버 오류는 받지 않는다.
    if jsonb_typeof(p_response -> 'RESULT') <> 'object' or (p_response -> 'RESULT' ->> 'CODE') is distinct from 'INFO-200'
       or p_response ? 'StatisticSearch' then
      perform private.fail('fx_source_error', 'PT502');
    end if;
    v_rows := '[]'::jsonb;
  else
    if jsonb_typeof(p_response -> 'StatisticSearch') is distinct from 'object'
       or jsonb_typeof(p_response -> 'StatisticSearch' -> 'row') is distinct from 'array'
       or jsonb_typeof(p_response -> 'StatisticSearch' -> 'list_total_count') is distinct from 'number' then
      perform private.fail('fx_response_invalid', 'PT400');
    end if;
    v_rows := p_response -> 'StatisticSearch' -> 'row';
    -- 잘린 응답(쪽 나눔)을 받지 않는다: 전체 건수와 받은 줄 수가 같아야 한다.
    if (p_response -> 'StatisticSearch' ->> 'list_total_count') !~ '^[0-9]+$'
       or (p_response -> 'StatisticSearch' ->> 'list_total_count')::int <> jsonb_array_length(v_rows)
       or jsonb_array_length(v_rows) = 0 or jsonb_array_length(v_rows) > 1000 then
      perform private.fail('fx_response_invalid', 'PT400');
    end if;
  end if;

  for v_row in select value from jsonb_array_elements(v_rows) loop
    if jsonb_typeof(v_row) <> 'object'
       or (v_row ->> 'STAT_CODE') is distinct from '731Y001'
       or (v_row ->> 'ITEM_CODE1') is distinct from '0000002'
       or (v_row ->> 'ITEM_NAME1') is distinct from '원/일본엔(100엔)'
       or (v_row ->> 'UNIT_NAME') is distinct from '원'
       or jsonb_typeof(v_row -> 'TIME') is distinct from 'string'
       or jsonb_typeof(v_row -> 'DATA_VALUE') is distinct from 'string'
       or coalesce(v_row ->> 'ITEM_CODE2', '') <> '' then
      perform private.fail('fx_response_invalid', 'PT400');
    end if;
    v_date := private.ecos_date(v_row ->> 'TIME');
    if v_date is null or to_char(v_date, 'YYYYMMDD') <> (v_row ->> 'TIME') or v_date < p_start or v_date > p_end
       or v_date = any (v_dates) then
      perform private.fail('fx_response_invalid', 'PT400');
    end if;
    if (v_row ->> 'DATA_VALUE') !~ '^(0|[1-9][0-9]{0,5})(\.[0-9]{1,4})?$' or (v_row ->> 'DATA_VALUE')::numeric <= 0 then
      perform private.fail('fx_response_invalid', 'PT400');
    end if;
    v_dates := v_dates || v_date;
    v_values := v_values || (v_row ->> 'DATA_VALUE');
  end loop;
  v_count := coalesce(array_length(v_dates, 1), 0);

  insert into public.fx_ingestions (source, stat_code, item_code, item_name, unit_name, currency, quote_unit,
      coverage_start, coverage_end, data_origin, response_sha256, row_count, fetched_at)
    values ('bok_ecos', '731Y001', '0000002', '원/일본엔(100엔)', '원', 'JPY', 100, p_start, p_end, p_origin,
      encode(sha256(convert_to(p_response::text, 'UTF8')), 'hex'), v_count, clock_timestamp())
    returning id into v_id;
  insert into public.fx_quotes (ingestion_id, rate_date, rate)
    select v_id, d, v::numeric from unnest(v_dates, v_values) as u(d, v);
  return jsonb_build_object('ingestion_id', v_id, 'rows', v_count, 'coverage_start', p_start, 'coverage_end', p_end,
    'data_origin', p_origin);
end $$;

-- ---------------------------------------------------------------- 장부: 정정 상태와 하나의 비교
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
                   || jsonb_build_object('artifact_path', e.artifact_path, 'artifact_sha256', e.artifact_sha256,
                        'fx_proposal', case when v_trip.status = 'open' then private.fx_current(e) end,
                        'fx_superseded', v_trip.status = 'open' and private.fx_superseded(e),
                        'fx_correction', case when v_trip.status = 'open' then private.fx_correction(e) end)
                   order by e.expense_date, e.created_at, e.id), '[]'::jsonb)
                 from public.expenses e where e.trip_id = p_trip),
    'finalization_id', (select f.id from public.finalizations f where f.trip_id = p_trip order by f.version desc limit 1));
end $$;

-- 정정 결정이 필요한(확정을 막는) 지출. 순서는 장부와 같다.
create function private.fx_blocking_ids(p_trip uuid) returns jsonb
language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(e.id order by e.expense_date, e.created_at, e.id), '[]'::jsonb)
  from public.expenses e
  where e.trip_id = p_trip and e.status = 'included' and e.krw_basis = 'reference_rate_estimate'
    and private.fx_correction(e) in ('required', 'unavailable')
$$;

-- 미리보기: 정정 결정이 필요한 지출이 있으면 ready가 아니다. 확정 스냅숏(compute_settlement) 모양은 그대로다.
create or replace function private.preview_settlement(p_trip uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := private.require_uid(); v_trip public.trips; v_calc jsonb; v_fx jsonb;
begin
  if not exists (select 1 from public.trip_members m where m.trip_id = p_trip and m.user_id = v_uid) then
    perform private.fail('trip_not_found', 'PT404');
  end if;
  select * into v_trip from public.trips where id = p_trip;
  v_calc := private.compute_settlement(p_trip);
  v_fx := case when v_trip.status = 'open' then private.fx_blocking_ids(p_trip) else '[]'::jsonb end;
  return v_calc || jsonb_build_object('trip_id', p_trip, 'status', v_trip.status, 'revision', v_trip.revision,
    'fx_correction_expense_ids', v_fx,
    'ready', v_trip.status = 'open' and jsonb_array_length(v_calc -> 'pending_expense_ids') = 0
      and jsonb_array_length(v_fx) = 0);
end $$;

-- ---------------------------------------------------------------- 고정 금액 유지(방장)
-- p_replacement_quote_id: 방장이 본 새 고시값. 그사이 또 정정됐으면 stale_quote. 같은 값의 다시 받기(다른 quote_id)는 받는다.
create function private.keep_fx_estimate(
  p_expense uuid, p_expected_version integer, p_request_id uuid, p_replacement_quote_id uuid
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_uid(); v_trip uuid; l record; v_e public.expenses; v_fp text; v_req public.settlement_requests;
  v_state text; v_prop jsonb; v_q public.fx_quotes; v_run public.fx_ingestions; v_rev bigint; v_resp jsonb;
begin
  select e.trip_id into v_trip from public.expenses e where e.id = p_expense;
  if v_trip is null then perform private.fail('trip_not_found', 'PT404'); end if;
  select * into l from private.lock_trip(v_trip, v_uid);
  v_fp := encode(sha256(convert_to(concat_ws('|', 'fx_keep', p_expense, p_expected_version,
            coalesce(p_replacement_quote_id::text, '-')), 'UTF8')), 'hex');
  select * into v_req from public.settlement_requests where trip_id = v_trip and request_id = p_request_id;
  if found then
    if v_req.fingerprint <> v_fp or v_req.kind <> 'fx_keep' then perform private.fail('idempotency_conflict', 'PT409'); end if;
    return v_req.response || jsonb_build_object('replayed', true);
  end if;
  if l.role <> 'host' then perform private.fail('host_only', 'PT403'); end if;
  if (l.trip).status <> 'open' then perform private.fail('trip_finalized', 'PT409'); end if;
  if p_request_id is null or p_replacement_quote_id is null then perform private.fail('invalid_fields', 'PT400'); end if;
  select * into v_e from public.expenses where id = p_expense for update;
  if v_e.version is distinct from p_expected_version then
    perform private.fail_with('stale_expense', 'PT409', jsonb_build_object('current_version', v_e.version, 'status', v_e.status));
  end if;

  perform private.fx_lock(false);
  v_prop := private.fx_current(v_e);
  v_state := private.fx_correction(v_e);
  if v_state = 'unavailable' then
    perform private.fail_with('fx_replacement_unavailable', 'PT409', jsonb_build_object('fx_proposal', v_prop));
  end if;
  if v_state is distinct from 'required' then
    perform private.fail_with('fx_not_superseded', 'PT409', jsonb_build_object('fx_correction', v_state));
  end if;
  select * into v_q from public.fx_quotes where id = p_replacement_quote_id;
  if found then select * into v_run from public.fx_ingestions where id = v_q.ingestion_id; end if;
  if v_q.id is null or private.fx_identity(v_q.rate_date, v_q.rate, v_run.quote_unit, v_run.data_origin)
       is distinct from private.fx_proposal_identity(v_prop) then
    perform private.fail_with('stale_quote', 'PT409', jsonb_build_object('fx_proposal', v_prop));
  end if;

  update public.expenses set version = version + 1, updated_at = now(), updated_by = v_uid
    where id = p_expense returning * into v_e;
  insert into public.fx_keep_decisions (trip_id, expense_id, expense_version, pinned_quote_id, replacement_quote_id,
      replacement_rate, replacement_rate_date, replacement_quote_unit, replacement_data_origin, request_id, decided_by,
      decided_at)
    values (v_trip, v_e.id, v_e.version, v_e.fx_quote_id, v_q.id, v_q.rate, v_q.rate_date, v_run.quote_unit,
      v_run.data_origin, p_request_id, v_uid, clock_timestamp());
  v_rev := private.bump(v_trip, v_uid, 'expense_fx_kept', v_e.id);
  v_resp := jsonb_build_object('expense_id', v_e.id, 'version', v_e.version, 'status', v_e.status, 'revision', v_rev);
  insert into public.settlement_requests (trip_id, request_id, kind, fingerprint, response, actor)
    values (v_trip, p_request_id, 'fx_keep', v_fp, v_resp, v_uid);
  return v_resp || jsonb_build_object('replayed', false);
end $$;

create function public.keep_fx_estimate(
  p_expense uuid, p_expected_version integer, p_request_id uuid, p_replacement_quote_id uuid
) returns jsonb
language sql security invoker set search_path = '' as $$
  select private.keep_fx_estimate(p_expense, p_expected_version, p_request_id, p_replacement_quote_id) $$;

-- ---------------------------------------------------------------- 검토: 공유 잠금 뒤 하나의 비교로 stale_quote
-- 본문은 20261124130000과 같다(요청 지문 포함). 예상액 분기만 잠금을 잡고, 커밋된 모든 받기 기록으로 정한 제안과
-- 방장이 본 고시값의 실질 식별을 비교한다.
create or replace function private.review_expense(
  p_expense uuid, p_expected_version integer, p_request_id uuid, p_decision text,
  p_payer uuid, p_krw_amount bigint, p_shares jsonb, p_hold_reason text,
  p_krw_basis text, p_fx_quote_id uuid, p_acq_krw bigint, p_acq_foreign_minor bigint
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_uid(); v_trip uuid; l record; v_e public.expenses; v_fp text; v_req public.settlement_requests;
  v_krw bigint; v_basis text; v_rev bigint; v_resp jsonb; v_count int; v_sum numeric; v_share jsonb;
  v_prop jsonb; v_q public.fx_quotes; v_run public.fx_ingestions;
begin
  select e.trip_id into v_trip from public.expenses e where e.id = p_expense;
  if v_trip is null then perform private.fail('trip_not_found', 'PT404'); end if;
  select * into l from private.lock_trip(v_trip, v_uid);
  v_fp := encode(sha256(convert_to(concat_ws('|', 'review', p_expense, p_expected_version, p_decision,
            coalesce(p_payer::text, '-'), coalesce(p_krw_amount::text, '-'), coalesce(p_shares::text, '-'),
            coalesce(p_hold_reason, '-'))
            || case when p_krw_basis is null and p_fx_quote_id is null and p_acq_krw is null and p_acq_foreign_minor is null
                 then '' else '|' || concat_ws('|', 'basis', coalesce(p_krw_basis, '-'), coalesce(p_fx_quote_id::text, '-'),
                   coalesce(p_acq_krw::text, '-'), coalesce(p_acq_foreign_minor::text, '-')) end, 'UTF8')), 'hex');
  select * into v_req from public.settlement_requests where trip_id = v_trip and request_id = p_request_id;
  if found then
    if v_req.fingerprint <> v_fp or v_req.kind <> 'review' then perform private.fail('idempotency_conflict', 'PT409'); end if;
    return v_req.response || jsonb_build_object('replayed', true);
  end if;
  if l.role <> 'host' then perform private.fail('host_only', 'PT403'); end if;
  if (l.trip).status <> 'open' then perform private.fail('trip_finalized', 'PT409'); end if;
  if p_request_id is null then perform private.fail('invalid_fields', 'PT400'); end if;
  select * into v_e from public.expenses where id = p_expense for update;
  if v_e.version is distinct from p_expected_version then
    perform private.fail_with('stale_expense', 'PT409', jsonb_build_object('current_version', v_e.version, 'status', v_e.status));
  end if;

  if p_decision = 'include' then
    if p_payer is null or not exists (select 1 from public.trip_members m where m.trip_id = v_trip and m.user_id = p_payer) then
      perform private.fail('payer_required', 'PT400');
    end if;
    if v_e.currency = 'KRW' then
      if p_krw_basis is distinct from 'krw_original' and p_krw_basis is not null
         or p_fx_quote_id is not null or p_acq_krw is not null or p_acq_foreign_minor is not null then
        perform private.fail('basis_invalid', 'PT400');
      end if;
      if p_krw_amount is not null and p_krw_amount <> v_e.amount_minor then perform private.fail('krw_unverified', 'PT400'); end if;
      v_krw := v_e.amount_minor; v_basis := 'krw_original';
    else
      v_basis := coalesce(p_krw_basis, 'verified_krw_charge');
      if v_basis = 'verified_krw_charge' then
        if p_fx_quote_id is not null or p_acq_krw is not null or p_acq_foreign_minor is not null then
          perform private.fail('basis_invalid', 'PT400');
        end if;
        -- 확인한 실제 원화 청구액(우선순위 1).
        if p_krw_amount is null or p_krw_amount <= 0 or p_krw_amount >= 100000000000 then
          perform private.fail('krw_unverified', 'PT400');
        end if;
        v_krw := p_krw_amount;
      elsif v_basis = 'acquisition_cost' then
        -- 증빙으로 확인한 외화 취득 원가(우선순위 2). 이번에는 엔화만, 지출마다 한 기준(섞인 현금은 다루지 않는다).
        if v_e.currency <> 'JPY' or p_fx_quote_id is not null then perform private.fail('basis_invalid', 'PT400'); end if;
        if p_acq_krw is null or p_acq_krw <= 0 or p_acq_krw >= 10000000000
           or p_acq_foreign_minor is null or p_acq_foreign_minor <= 0 or p_acq_foreign_minor >= 1000000000 then
          perform private.fail('krw_unverified', 'PT400');
        end if;
        v_krw := private.acq_krw(v_e.amount_minor, p_acq_krw, p_acq_foreign_minor);
        if v_krw <= 0 or v_krw >= 100000000000 then perform private.fail('krw_unverified', 'PT400'); end if;
        if p_krw_amount is distinct from v_krw then
          perform private.fail_with('krw_mismatch', 'PT400', jsonb_build_object('krw_amount', v_krw));
        end if;
      elsif v_basis = 'reference_rate_estimate' then
        -- 기준환율 예상액(우선순위 3). 방장이 본 고시값이 지금도 그 지출일의 제안과 실질적으로 같아야 한다.
        if v_e.currency <> 'JPY' or p_acq_krw is not null or p_acq_foreign_minor is not null or p_fx_quote_id is null then
          perform private.fail('basis_invalid', 'PT400');
        end if;
        perform private.fx_lock(false);
        v_prop := private.fx_current(v_e);
        select * into v_q from public.fx_quotes where id = p_fx_quote_id;
        if found then select * into v_run from public.fx_ingestions where id = v_q.ingestion_id; end if;
        if v_q.id is null or (v_prop ->> 'status') is distinct from 'proposed' or v_run.quote_unit is distinct from 100
           or private.fx_identity(v_q.rate_date, v_q.rate, v_run.quote_unit, v_run.data_origin)
              is distinct from private.fx_proposal_identity(v_prop) then
          perform private.fail_with('stale_quote', 'PT409', jsonb_build_object('fx_proposal', v_prop));
        end if;
        v_krw := private.fx_krw(v_e.amount_minor, v_q.rate, v_run.quote_unit);
        if v_krw <= 0 or v_krw >= 100000000000 then perform private.fail('krw_unverified', 'PT400'); end if;
        if p_krw_amount is distinct from v_krw then
          perform private.fail_with('krw_mismatch', 'PT400', jsonb_build_object('krw_amount', v_krw));
        end if;
      else
        perform private.fail('basis_invalid', 'PT400');
      end if;
    end if;
    if p_shares is null or jsonb_typeof(p_shares) <> 'array' or jsonb_array_length(p_shares) = 0 then
      perform private.fail('shares_invalid', 'PT400');
    end if;
    -- 몫 줄마다 형식을 먼저 본다(형 변환 오류가 고정 코드 밖으로 새지 않게).
    v_count := 0; v_sum := 0;
    for v_share in select value from jsonb_array_elements(p_shares) loop
      if jsonb_typeof(v_share) <> 'object' or jsonb_typeof(v_share -> 'krw') is distinct from 'number'
         or jsonb_typeof(v_share -> 'user_id') is distinct from 'string'
         or (v_share ->> 'user_id') !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        perform private.fail('shares_invalid', 'PT400');
      end if;
      if (v_share ->> 'krw')::numeric <= 0 or (v_share ->> 'krw')::numeric <> trunc((v_share ->> 'krw')::numeric)
         or (v_share ->> 'krw')::numeric >= 100000000000
         or not exists (select 1 from public.trip_members m where m.trip_id = v_trip and m.user_id = (v_share ->> 'user_id')::uuid) then
        perform private.fail('shares_invalid', 'PT400');
      end if;
      v_count := v_count + 1; v_sum := v_sum + (v_share ->> 'krw')::numeric;
    end loop;
    if v_count <> (select count(distinct value ->> 'user_id') from jsonb_array_elements(p_shares)) then
      perform private.fail('shares_invalid', 'PT400');
    end if;
    if v_sum <> v_krw then
      perform private.fail_with('shares_mismatch', 'PT400', jsonb_build_object('krw_amount', v_krw, 'shares_total', v_sum));
    end if;
    delete from public.expense_shares where expense_id = p_expense;
    insert into public.expense_shares (expense_id, trip_id, user_id, krw)
      select p_expense, v_trip, (s ->> 'user_id')::uuid, (s ->> 'krw')::bigint from jsonb_array_elements(p_shares) s;
    update public.expenses set status = 'included', payer_id = p_payer, krw_amount = v_krw, krw_basis = v_basis,
        fx_quote_id = case when v_basis = 'reference_rate_estimate' then v_q.id end,
        fx_rate = case when v_basis = 'reference_rate_estimate' then v_q.rate end,
        fx_quote_unit = case when v_basis = 'reference_rate_estimate' then v_run.quote_unit end,
        fx_rate_date = case when v_basis = 'reference_rate_estimate' then v_q.rate_date end,
        acq_krw = case when v_basis = 'acquisition_cost' then p_acq_krw end,
        acq_foreign_minor = case when v_basis = 'acquisition_cost' then p_acq_foreign_minor end,
        hold_reason = null, version = version + 1, updated_at = now(), updated_by = v_uid
      where id = p_expense returning * into v_e;
  elsif p_decision = 'hold' then
    if p_hold_reason is null or char_length(p_hold_reason) not between 1 and 80 or p_hold_reason ~ '[[:cntrl:]]' then
      perform private.fail('hold_reason_required', 'PT400');
    end if;
    update public.expenses set status = 'held', hold_reason = p_hold_reason,
        version = version + 1, updated_at = now(), updated_by = v_uid
      where id = p_expense returning * into v_e;
  else
    perform private.fail('decision_invalid', 'PT400');
  end if;
  v_rev := private.bump(v_trip, v_uid, 'expense_' || v_e.status, v_e.id);
  v_resp := jsonb_build_object('expense_id', v_e.id, 'version', v_e.version, 'status', v_e.status, 'revision', v_rev);
  insert into public.settlement_requests (trip_id, request_id, kind, fingerprint, response, actor)
    values (v_trip, p_request_id, 'review', v_fp, v_resp, v_uid);
  return v_resp || jsonb_build_object('replayed', false);
end $$;

-- ---------------------------------------------------------------- 확정: 정정 결정이 필요한 예상액이 있으면 거절
-- 본문은 20261124130000과 같고, 확인 필요 검사 뒤에 기준환율 잠금(공유)과 정정 검사만 더했다. 재시도는 그대로 맨 앞에서 끝난다.
create or replace function private.finalize_settlement(p_trip uuid, p_expected_revision bigint, p_request_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_uid(); l record; v_f public.finalizations; v_calc jsonb; v_snapshot jsonb; v_rev bigint; v_ver int;
  v_fx jsonb;
begin
  select * into l from private.lock_trip(p_trip, v_uid);
  select * into v_f from public.finalizations where trip_id = p_trip and request_id = p_request_id;
  if found then
    if v_f.reviewed_revision <> p_expected_revision then perform private.fail('idempotency_conflict', 'PT409'); end if;
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

-- ---------------------------------------------------------------- 실행 권한
revoke all on function private.fx_lock(boolean), private.fx_identity(date, numeric, integer, text),
  private.fx_proposal_identity(jsonb), private.fx_pinned_identity(public.expenses),
  private.fx_current(public.expenses), private.fx_keep_valid(public.expenses), private.fx_correction(public.expenses),
  private.fx_blocking_ids(uuid),
  private.keep_fx_estimate(uuid, integer, uuid, uuid), public.keep_fx_estimate(uuid, integer, uuid, uuid)
  from public, anon, authenticated, service_role;
grant execute on function
  private.keep_fx_estimate(uuid, integer, uuid, uuid), public.keep_fx_estimate(uuid, integer, uuid, uuid)
  to authenticated;
