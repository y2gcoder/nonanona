-- 품목 나누기 제안의 범위와 "가장 최근" 판단을 고친다(ADR-0011 독립 리뷰 후속). 20261124170000 뒤에 올린다.
--
-- * 범위: 제안은 원화(KRW)·엔화(JPY) 지출만 받는다. 전에는 실제 청구액·환전 원가 분기가 통화를 보지 않아, 방장이 실제 청구액으로
--   포함한 USD 지출에 제안을 만들 수 있었다. 두 앱은 KRW 원래 금액 밖의 제안은 엔화만 읽으므로 그 방 장부 전체를 읽지 못했다.
--   제출 RPC와 공통 기준 검사(share_proposal_basis_ok)가 모두 통화를 본다.
-- * 이미 들어간 범위 밖 행(예전 USD 제안)은 지우지 않는다(행은 불변). 장부는 그 지출에서 범위 안 제안 가운데 가장 최근 것만 보이고,
--   범위 밖 제안밖에 없으면 null이다. 그래서 그 방은 다시 읽힌다. 같은 요청 키의 재시도는 예전처럼 저장한 결과(replayed)를 돌려준다.
-- * 재시도 응답에 latest를 더한다: 그 제안이 지금도 그 지출의 가장 최근(범위 안) 제안인가. 앱은 latest=false인 재시도를 "보냄"으로
--   보이지 않는다(그사이 다른 제안이 들어왔다). 새로 넣은 제안은 언제나 latest=true다. 앱의 요청 키는 동의한 보내기마다 새로 만들고,
--   응답이 불확실해 다시 보낼 때만 같은 키를 쓴다(A→B→A에서 마지막 A는 새 행이 되어 가장 최근이 된다).
-- * 그대로인 것: 표·권한, 잠금 순서, 다른 실패 코드, 확정에 닿지 않음, 장부의 나머지 모양.

-- 제안이 ADR-0011 범위(KRW 원래 금액, 엔화의 예상액·실제 청구액·환전 원가) 안인가.
create function private.share_proposal_supported(p public.expense_share_proposals, e public.expenses) returns boolean
language sql immutable set search_path = '' as $$
  select (p.krw_basis = 'krw_original' and e.currency = 'KRW')
      or (p.krw_basis in ('reference_rate_estimate', 'verified_krw_charge', 'acquisition_cost') and e.currency = 'JPY')
$$;

-- 지출의 범위 안 제안 가운데 가장 최근 것의 ID(없으면 null).
create function private.share_proposal_latest_id(p_expense uuid) returns uuid
language sql stable set search_path = '' as $$
  select p.id from public.expense_share_proposals p join public.expenses e on e.id = p.expense_id
  where p.expense_id = p_expense and private.share_proposal_supported(p, e)
  order by p.seq desc limit 1
$$;

create or replace function private.share_proposal_basis_ok(p public.expense_share_proposals, e public.expenses) returns boolean
language sql stable set search_path = '' as $$
  select case p.krw_basis
    when 'krw_original' then e.currency = 'KRW' and p.krw_total = e.amount_minor
    when 'reference_rate_estimate' then e.currency = 'JPY' and coalesce((
      select private.fx_identity(q.rate_date, q.rate, i.quote_unit, i.data_origin)
               = private.fx_proposal_identity(private.fx_current(e))
             and p.krw_total = private.fx_krw(e.amount_minor, q.rate, i.quote_unit)
      from public.fx_quotes q join public.fx_ingestions i on i.id = q.ingestion_id where q.id = p.fx_quote_id), false)
    when 'verified_krw_charge' then e.currency = 'JPY' and e.status = 'included' and e.krw_basis = 'verified_krw_charge' and e.krw_amount = p.krw_total
    when 'acquisition_cost' then e.currency = 'JPY' and e.status = 'included' and e.krw_basis = 'acquisition_cost' and e.krw_amount = p.krw_total
    else false end
$$;


-- 장부용: 범위 안 제안 가운데 가장 최근 것. 모양은 20261124170000과 같다.
create or replace function private.share_proposal_json(e public.expenses, p_open boolean) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('proposal_id', p.id, 'proposed_by', p.proposed_by, 'expense_version', p.expense_version,
    'krw_basis', p.krw_basis, 'krw_total', p.krw_total, 'fx_quote_id', p.fx_quote_id,
    'shares', private.share_proposal_lines_json(p.id),
    'proposed_at', to_char(p.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'state', private.share_proposal_state(p, e, p_open))
  from public.expense_share_proposals p where p.id = private.share_proposal_latest_id(e.id)
$$;

-- 제출: 본문은 20261124170000과 같고 통화 범위 검사, 실제 청구액·환전 원가의 엔화 검사, 응답의 latest만 다르다.
create or replace function private.propose_expense_shares(
  p_expense uuid, p_expected_version integer, p_request_id uuid, p_krw_basis text, p_krw_total bigint,
  p_fx_quote_id uuid, p_shares jsonb
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_uid(); v_trip uuid; l record; v_e public.expenses; v_fp text;
  v_old public.expense_share_proposals; v_p public.expense_share_proposals; v_count int; v_sum numeric; v_share jsonb;
  v_prop jsonb; v_q public.fx_quotes; v_run public.fx_ingestions; v_resp jsonb;
begin
  select e.trip_id into v_trip from public.expenses e where e.id = p_expense;
  if v_trip is null then perform private.fail('trip_not_found', 'PT404'); end if;
  select * into l from private.lock_trip(v_trip, v_uid);
  -- 몫 순서가 달라도 같은 내용이다(구성원 ID 순으로 지문을 만든다). 형식 검사 전이라 배열이 아니면 글자 그대로 쓴다.
  v_fp := encode(sha256(convert_to(concat_ws('|', 'share_proposal', p_expense, p_expected_version,
            coalesce(p_krw_basis, '-'), coalesce(p_krw_total::text, '-'), coalesce(p_fx_quote_id::text, '-'),
            case when jsonb_typeof(p_shares) = 'array'
              then (select coalesce(string_agg(x::text, ',' order by x::text), '') from jsonb_array_elements(p_shares) x)
              else coalesce(p_shares::text, '-') end), 'UTF8')), 'hex');
  select * into v_old from public.expense_share_proposals where trip_id = v_trip and request_id = p_request_id;
  if found then
    if v_old.fingerprint <> v_fp or v_old.proposed_by <> v_uid then
      perform private.fail('idempotency_conflict', 'PT409');
    end if;
    -- 재시도한 제안이 지금도 그 지출의 가장 최근(지원 범위) 제안인지 알린다. 그사이 다른 제안이 들어왔으면 false다.
    return jsonb_build_object('proposal_id', v_old.id, 'expense_id', v_old.expense_id,
      'expense_version', v_old.expense_version, 'replayed', true,
      'latest', v_old.id is not distinct from private.share_proposal_latest_id(v_old.expense_id));
  end if;
  select * into v_e from public.expenses where id = p_expense for update;
  if v_e.uploaded_by <> v_uid then perform private.fail('uploader_only', 'PT403'); end if;
  if (l.trip).status <> 'open' then perform private.fail('trip_finalized', 'PT409'); end if;
  if p_request_id is null or v_e.entry <> 'receipt' then perform private.fail('invalid_fields', 'PT400'); end if;
  if v_e.version is distinct from p_expected_version then
    perform private.fail_with('stale_expense', 'PT409', jsonb_build_object('current_version', v_e.version, 'status', v_e.status));
  end if;
  if p_krw_total is null or p_krw_total <= 0 or p_krw_total >= 100000000000 then
    perform private.fail('invalid_fields', 'PT400');
  end if;
  -- ADR-0011 범위: 원화·엔화 지출만(두 앱이 읽는 범위와 같다). 다른 통화는 어떤 기준으로도 받지 않는다.
  if v_e.currency not in ('KRW', 'JPY') then perform private.fail('basis_invalid', 'PT400'); end if;

  if p_krw_basis = 'krw_original' then
    if v_e.currency <> 'KRW' or p_fx_quote_id is not null then perform private.fail('basis_invalid', 'PT400'); end if;
    if p_krw_total <> v_e.amount_minor then
      perform private.fail_with('krw_mismatch', 'PT400', jsonb_build_object('krw_amount', v_e.amount_minor));
    end if;
  elsif p_krw_basis = 'reference_rate_estimate' then
    if v_e.currency <> 'JPY' or p_fx_quote_id is null then perform private.fail('basis_invalid', 'PT400'); end if;
    perform private.fx_lock(false);
    v_prop := private.fx_current(v_e);
    select * into v_q from public.fx_quotes where id = p_fx_quote_id;
    if found then select * into v_run from public.fx_ingestions where id = v_q.ingestion_id; end if;
    if v_q.id is null or private.fx_identity(v_q.rate_date, v_q.rate, v_run.quote_unit, v_run.data_origin)
         is distinct from private.fx_proposal_identity(v_prop) then
      perform private.fail_with('stale_quote', 'PT409', jsonb_build_object('fx_proposal', v_prop));
    end if;
    if p_krw_total <> private.fx_krw(v_e.amount_minor, v_q.rate, v_run.quote_unit) then
      perform private.fail_with('krw_mismatch', 'PT400',
        jsonb_build_object('krw_amount', private.fx_krw(v_e.amount_minor, v_q.rate, v_run.quote_unit)));
    end if;
  elsif p_krw_basis in ('verified_krw_charge', 'acquisition_cost') then
    -- 방장이 그 기준으로 이미 포함한 원화만. 올린 사람이 원화를 정하지 않는다.
    if v_e.currency <> 'JPY' or p_fx_quote_id is not null or v_e.status <> 'included'
       or v_e.krw_basis is distinct from p_krw_basis then
      perform private.fail('basis_invalid', 'PT400');
    end if;
    if p_krw_total <> v_e.krw_amount then
      perform private.fail_with('krw_mismatch', 'PT400', jsonb_build_object('krw_amount', v_e.krw_amount));
    end if;
  else
    perform private.fail('basis_invalid', 'PT400');
  end if;

  if p_shares is null or jsonb_typeof(p_shares) <> 'array' or jsonb_array_length(p_shares) = 0 then
    perform private.fail('shares_invalid', 'PT400');
  end if;
  v_count := 0; v_sum := 0;
  for v_share in select value from jsonb_array_elements(p_shares) loop
    -- 한 줄은 정확히 {user_id, krw}다. 다른 키(이름·품목 등)가 붙은 줄은 받지 않는다.
    if jsonb_typeof(v_share) <> 'object'
       or (select array_agg(k order by k) from jsonb_object_keys(v_share) k) is distinct from array['krw', 'user_id']
       or jsonb_typeof(v_share -> 'krw') is distinct from 'number'
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
  if v_sum <> p_krw_total then
    perform private.fail_with('shares_mismatch', 'PT400', jsonb_build_object('krw_amount', p_krw_total, 'shares_total', v_sum));
  end if;

  insert into public.expense_share_proposals (trip_id, expense_id, proposed_by, expense_version, krw_basis, krw_total,
      fx_quote_id, request_id, fingerprint)
    values (v_trip, v_e.id, v_uid, v_e.version, p_krw_basis, p_krw_total, p_fx_quote_id, p_request_id, v_fp)
    returning * into v_p;
  insert into public.expense_share_proposal_lines (proposal_id, trip_id, user_id, krw)
    select v_p.id, v_trip, (s ->> 'user_id')::uuid, (s ->> 'krw')::bigint from jsonb_array_elements(p_shares) s;
  -- 같은 함수로 한 번 더 본다(장부의 current와 같은 판단).
  if private.share_proposal_state(v_p, v_e, true) not in ('current', 'applied') then
    perform private.fail('basis_invalid', 'PT400');
  end if;
  v_resp := jsonb_build_object('proposal_id', v_p.id, 'expense_id', v_e.id, 'expense_version', v_p.expense_version,
    'latest', true);
  return v_resp || jsonb_build_object('replayed', false);
end $$;

revoke all on function private.share_proposal_supported(public.expense_share_proposals, public.expenses),
  private.share_proposal_latest_id(uuid)
  from public, anon, authenticated, service_role;
