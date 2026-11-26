-- 다른 기기에서 올린 영수증의 품목별 나누기: 올린 사람의 "제안 몫"(ADR-0011, ADR-0010의 선택지 (a)).
--
-- 품목 글자·이름·품목 금액·OCR 줄·조정 줄·사진은 지금도 올린 기기 밖으로 나가지 않는다(ADR-0003, ADR-0005, ADR-0010).
-- 올린 사람이 자기 기기의 품목 계획으로 사람마다 원 단위 몫을 계산하고, 보내기에 따로 동의하면 이 RPC로 몫만 보낸다.
--
-- * 보내는 값(전부): 지출 ID, 올린 사람이 본 지출 버전, 요청 키, 원화 기준과 그 원화 합계(엔화 예상액이면 본 고시값 ID),
--   사람마다 {구성원 ID, 원}. 이름·금액 글자·품목 수 같은 다른 필드는 받지 않는다(서명에 없다).
-- * 누가: 그 지출을 실제로 올린 구성원만(uploaded_by = 나, 사본으로 올린 지출). 다른 구성원은 uploader_only(403),
--   비구성원·없는 지출은 trip_not_found(404, 구분하지 않는다).
-- * 묶기: 제안은 그 지출 버전과 원화 기준·합계에 묶인다. 방장이 볼 수 있고 승인할 수 있는 기준만 받는다.
--   - krw_original: KRW 지출, 합계 = 원래 금액.
--   - reference_rate_estimate: 엔화 지출, 본 고시값의 실질 식별(ADR-0009 fx_identity)이 지금 그 지출일에 적용되는 고시값과
--     같아야 하고 합계 = 그 고시값의 예상액. 아니면 stale_quote(409) / krw_mismatch(400). 기준환율 잠금(공유)을 잡고 본다.
--   - verified_krw_charge | acquisition_cost: 방장이 이미 그 기준·원화로 포함한 지출만(올린 사람도 장부에서 그 원화를 본다).
--     방장이 적은 값을 올린 사람이 바꾸지 않는다. 포함 전이거나 기준이 다르면 basis_invalid(400).
--   - 엔화인데 기준을 정할 수 없으면(고시값 없음·확인 못 함, 포함 전 실제 청구액·환전 원가) 제안을 받지 않는다. 새 기준을 만들지 않는다.
-- * 몫: 양의 정수 원, 구성원만, 한 사람 한 줄, 합 = 원화 합계(shares_invalid / shares_mismatch). 세금·할인·남는 원을 서버가
--   나누지 않는다. 앱은 남는 원이 있으면 올린 사람이 누가 낼지 고르게 한다.
-- * 적용하지 않는다: 제안은 장부의 몫(expense_shares)·지출 상태·방 revision·확정 스냅숏을 바꾸지 않는다. 방장은 장부에서 제안을
--   보고 검토 화면의 "직접 나누기"에 채운 뒤 지금처럼 review_expense로 포함해야 한다. 확정 계산(compute_settlement)은 제안을 읽지 않는다.
-- * 보이는 사람: 올린 사람과 지금 방장만. 표는 앱 역할이 읽지 못하고(권한 없음), 장부가 그 두 사람에게만 지출마다 가장 최근 제안을
--   돌려준다(share_proposal). 다른 구성원의 장부에는 null이다.
-- * 상태(장부): current(그 버전·기준 그대로), stale_expense(지출이 다시 검토됨), stale_basis(고시값 정정 등으로 기준이 바뀜),
--   applied(포함한 원화와 몫이 제안과 같다), closed(확정된 방에서 적용되지 않은 제안).
-- * 동시성·재시도: 여행방 잠금 → 지출 잠금 → (예상액이면) 기준환율 공유 잠금. 방장 검토와 같은 잠금으로 직렬화되어, 늦게 온 제안은
--   stale_expense다. 같은 요청 키·같은 내용은 같은 결과(replayed, 확정 뒤에도), 같은 키의 다른 내용은 idempotency_conflict.
--   행은 바꾸거나 지울 수 없다(트리거). 새 제안은 새 행이고 장부는 가장 최근 것을 보인다.
-- * 예전 앱: 장부 응답에 키 하나가 더해질 뿐이다(모르는 키는 무시한다). 검토·확정 RPC와 스냅숏(v2)은 그대로다.
--
-- 실패 코드(추가): uploader_only(403). 그 밖에 trip_not_found(404), trip_finalized(409), stale_expense(409), stale_quote(409),
-- idempotency_conflict(409), invalid_fields(400), basis_invalid(400), krw_mismatch(400), shares_invalid(400), shares_mismatch(400).

create table public.expense_share_proposals (
  id uuid primary key default gen_random_uuid(),
  seq bigint generated always as identity unique,
  trip_id uuid not null references public.trips (id),
  expense_id uuid not null references public.expenses (id),
  proposed_by uuid not null,
  expense_version integer not null check (expense_version >= 1),
  krw_basis text not null check (krw_basis in
    ('krw_original', 'verified_krw_charge', 'acquisition_cost', 'reference_rate_estimate')),
  krw_total bigint not null check (krw_total > 0 and krw_total < 100000000000),
  fx_quote_id uuid references public.fx_quotes (id),
  request_id uuid not null,
  fingerprint text not null,
  created_at timestamptz not null default now(),
  check ((krw_basis = 'reference_rate_estimate') = (fx_quote_id is not null)),
  unique (trip_id, request_id),
  foreign key (trip_id, proposed_by) references public.trip_members (trip_id, user_id)
);
create index expense_share_proposals_expense_idx on public.expense_share_proposals (expense_id, seq desc);
create index expense_share_proposals_quote_idx on public.expense_share_proposals (fx_quote_id);
create index expense_share_proposals_by_idx on public.expense_share_proposals (trip_id, proposed_by);

-- 사람마다 몫(원). 품목 정보는 없다.
create table public.expense_share_proposal_lines (
  proposal_id uuid not null references public.expense_share_proposals (id),
  trip_id uuid not null,
  user_id uuid not null,
  krw bigint not null check (krw > 0 and krw < 100000000000),
  primary key (proposal_id, user_id),
  foreign key (trip_id, user_id) references public.trip_members (trip_id, user_id)
);
create index expense_share_proposal_lines_member_idx on public.expense_share_proposal_lines (trip_id, user_id);

create function private.reject_proposal_mutation() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception 'share proposals are immutable' using errcode = 'PT409';
end $$;
create trigger expense_share_proposals_immutable before update or delete on public.expense_share_proposals
  for each row execute function private.reject_proposal_mutation();
create trigger expense_share_proposal_lines_immutable before update or delete on public.expense_share_proposal_lines
  for each row execute function private.reject_proposal_mutation();

alter table public.expense_share_proposals enable row level security;
alter table public.expense_share_proposal_lines enable row level security;
-- 앱 역할은 표를 직접 읽지 못한다(정책도 없다). 장부가 올린 사람과 방장에게만 보인다.
revoke all on public.expense_share_proposals, public.expense_share_proposal_lines from public, anon, authenticated;

-- ---------------------------------------------------------------- 기준 확인(제출·장부가 같은 함수를 쓴다)
-- 제안의 기준과 합계가 지금 그 지출에서 방장이 볼 수 있는 값과 같은가.
create function private.share_proposal_basis_ok(p public.expense_share_proposals, e public.expenses) returns boolean
language sql stable set search_path = '' as $$
  select case p.krw_basis
    when 'krw_original' then e.currency = 'KRW' and p.krw_total = e.amount_minor
    when 'reference_rate_estimate' then e.currency = 'JPY' and coalesce((
      select private.fx_identity(q.rate_date, q.rate, i.quote_unit, i.data_origin)
               = private.fx_proposal_identity(private.fx_current(e))
             and p.krw_total = private.fx_krw(e.amount_minor, q.rate, i.quote_unit)
      from public.fx_quotes q join public.fx_ingestions i on i.id = q.ingestion_id where q.id = p.fx_quote_id), false)
    when 'verified_krw_charge' then e.status = 'included' and e.krw_basis = 'verified_krw_charge' and e.krw_amount = p.krw_total
    when 'acquisition_cost' then e.status = 'included' and e.krw_basis = 'acquisition_cost' and e.krw_amount = p.krw_total
    else false end
$$;

-- 제안의 몫 줄(구성원 ID 순).
create function private.share_proposal_lines_json(p_proposal uuid) returns jsonb
language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('user_id', l.user_id, 'krw', l.krw) order by l.user_id), '[]'::jsonb)
  from public.expense_share_proposal_lines l where l.proposal_id = p_proposal
$$;

create function private.share_proposal_state(p public.expense_share_proposals, e public.expenses, p_open boolean)
returns text
language sql stable set search_path = '' as $$
  select case
    when e.status = 'included' and e.krw_amount = p.krw_total
         and private.share_proposal_lines_json(p.id) = (
           select coalesce(jsonb_agg(jsonb_build_object('user_id', s.user_id, 'krw', s.krw) order by s.user_id), '[]'::jsonb)
           from public.expense_shares s where s.expense_id = e.id) then 'applied'
    when not p_open then 'closed'
    when p.expense_version <> e.version then 'stale_expense'
    when not private.share_proposal_basis_ok(p, e) then 'stale_basis'
    else 'current' end
$$;

-- 지출의 가장 최근 제안(장부용). 품목 정보는 없다.
create function private.share_proposal_json(e public.expenses, p_open boolean) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('proposal_id', p.id, 'proposed_by', p.proposed_by, 'expense_version', p.expense_version,
    'krw_basis', p.krw_basis, 'krw_total', p.krw_total, 'fx_quote_id', p.fx_quote_id,
    'shares', private.share_proposal_lines_json(p.id),
    'proposed_at', to_char(p.created_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'state', private.share_proposal_state(p, e, p_open))
  from public.expense_share_proposals p where p.expense_id = e.id order by p.seq desc limit 1
$$;

-- ---------------------------------------------------------------- 제안 보내기(올린 사람)
-- p_shares: [{"user_id": uuid, "krw": 정수}]. p_fx_quote_id는 reference_rate_estimate일 때만.
create function private.propose_expense_shares(
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
    return jsonb_build_object('proposal_id', v_old.id, 'expense_id', v_old.expense_id,
      'expense_version', v_old.expense_version, 'replayed', true);
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
    if p_fx_quote_id is not null or v_e.status <> 'included' or v_e.krw_basis is distinct from p_krw_basis then
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
  v_resp := jsonb_build_object('proposal_id', v_p.id, 'expense_id', v_e.id, 'expense_version', v_p.expense_version);
  return v_resp || jsonb_build_object('replayed', false);
end $$;

create function public.propose_expense_shares(
  p_expense uuid, p_expected_version integer, p_request_id uuid, p_krw_basis text, p_krw_total bigint,
  p_fx_quote_id uuid default null, p_shares jsonb default null
) returns jsonb
language sql security invoker set search_path = '' as $$
  select private.propose_expense_shares(p_expense, p_expected_version, p_request_id, p_krw_basis, p_krw_total,
    p_fx_quote_id, p_shares) $$;

-- ---------------------------------------------------------------- 장부: 올린 사람과 방장에게만 제안을 더한다
-- 본문은 20261124150000과 같고 share_proposal 한 키만 더했다.
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
                        'fx_correction', case when v_trip.status = 'open' then private.fx_correction(e) end,
                        'share_proposal', case when v_role = 'host' or e.uploaded_by = v_uid
                          then private.share_proposal_json(e, v_trip.status = 'open') end)
                   order by e.expense_date, e.created_at, e.id), '[]'::jsonb)
                 from public.expenses e where e.trip_id = p_trip),
    'finalization_id', (select f.id from public.finalizations f where f.trip_id = p_trip order by f.version desc limit 1));
end $$;

-- ---------------------------------------------------------------- 실행 권한
revoke all on function private.reject_proposal_mutation(),
  private.share_proposal_basis_ok(public.expense_share_proposals, public.expenses),
  private.share_proposal_lines_json(uuid),
  private.share_proposal_state(public.expense_share_proposals, public.expenses, boolean),
  private.share_proposal_json(public.expenses, boolean),
  private.propose_expense_shares(uuid, integer, uuid, text, bigint, uuid, jsonb),
  public.propose_expense_shares(uuid, integer, uuid, text, bigint, uuid, jsonb)
  from public, anon, authenticated, service_role;
grant execute on function
  private.propose_expense_shares(uuid, integer, uuid, text, bigint, uuid, jsonb),
  public.propose_expense_shares(uuid, integer, uuid, text, bigint, uuid, jsonb)
  to authenticated;
