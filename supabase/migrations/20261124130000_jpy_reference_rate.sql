-- 엔화(JPY) 지출의 원화 기준을 넓힌다(ADR-0008). 우선순위는 ADR-0001 그대로다:
--   1. 확인한 실제 원화 청구액(verified_krw_charge, 기존)
--   2. 증빙으로 확인한 외화 취득 원가(acquisition_cost): 방장이 환전에 쓴 원화와 받은 엔화를 적는다
--   3. 한국은행 ECOS 기준환율 예상액(reference_rate_estimate): 서버가 가진 고시값으로만 계산하고 "예상"으로 표시한다
-- 어느 기준이든 방장이 고르고 승인해야 포함된다. 서버는 기준을 스스로 고르지 않는다.
--
-- 기준환율(서버 소유)
-- * 출처: ECOS 통계표 731Y001(3.1.1.1. 주요국 통화의 대원화환율, 출처 서울외국환중개, 주기 D), 항목 0000002
--   "원/일본엔(100엔)", 단위 "원". 값은 100엔당 원이다(quote_unit = 100). 고시는 은행 영업일(월~금) 하루 한 번(9시 전)이고
--   주말·공휴일에는 값이 없다. 확인일 2026-11-24(ECOS StatisticItemList·StatisticSearch, 서울외국환중개 매매기준율 안내).
-- * 받기: 받은 ECOS 응답 원문(JSON)을 서버가 직접 검사해 넣는다(ingest_ecos_jpy_rates, service_role 전용). 기간은 KST로
--   이미 끝난 날까지만(오늘·미래 날짜는 받지 않는다). 받은 기록과 고시값은 바꾸거나 지울 수 없다(트리거).
-- * 정하기(as-of): 지출일 D에서 하루씩 거슬러 가며, 그날을 덮는 가장 최근 받기 기록에 고시값이 있으면 그 값을 쓴다.
--   그날을 덮는 받기 기록이 없으면 "아직 확인 못 함(undetermined)"이다(그날 고시가 있었는지 모르므로 앞날 값으로 넘어가지
--   않는다). 31일 안에 값이 없으면 "쓸 수 없음(unavailable)". 같은 날짜를 다시 받아 값이 바뀌면 새 받기 기록이 이긴다.
-- * 환산: 원화 = 엔 × 고시값 ÷ 100을 정확한 십진 계산으로 구한 뒤 원 단위로 반올림한다(양수 .5는 올림). 몫은 그 원화로
--   나눈다(ADR-0007 그대로).
-- * 승인: 방장은 본 고시값(quote_id)과 원화로 포함한다. 그사이 그 지출일의 고시값이 바뀌었으면 stale_quote로 거절한다.
--   포함한 뒤에는 고시값·기준일·단위·원화를 지출에 고정한다. 나중에 들어온 고시값은 포함한 금액·미리보기·확정본을 바꾸지
--   않고, 장부에 fx_superseded로만 알린다.
--
-- 실패 코드(추가): stale_quote(409), krw_mismatch(400), basis_invalid(400), fx_range_invalid(400),
-- fx_response_invalid(400), fx_source_error(502).

-- ---------------------------------------------------------------- 기준환율 받기 기록과 고시값
create table public.fx_ingestions (
  id uuid primary key default gen_random_uuid(),
  source text not null check (source = 'bok_ecos'),
  stat_code text not null check (stat_code = '731Y001'),
  item_code text not null check (item_code = '0000002'),
  item_name text not null check (item_name = '원/일본엔(100엔)'),
  unit_name text not null check (unit_name = '원'),
  currency text not null check (currency = 'JPY'),
  quote_unit integer not null check (quote_unit = 100),
  coverage_start date not null,
  coverage_end date not null,
  -- ecos_live: ECOS에서 실제로 받은 응답. fixture: 가상 시험값(시장 환율 아님). 앱은 fixture를 언제나 따로 표시한다.
  data_origin text not null check (data_origin in ('ecos_live', 'fixture')),
  response_sha256 text not null check (response_sha256 ~ '^[0-9a-f]{64}$'),
  row_count integer not null check (row_count >= 0),
  fetched_at timestamptz not null default now(),
  check (coverage_start <= coverage_end and coverage_end - coverage_start <= 366),
  -- KST로 끝난 날까지만 덮는다(오늘 값은 아직 받기 기록이 덮지 않는다).
  check (coverage_end < (fetched_at at time zone 'Asia/Seoul')::date)
);
create index fx_ingestions_coverage_idx on public.fx_ingestions (currency, coverage_start, coverage_end, fetched_at desc);

create table public.fx_quotes (
  id uuid primary key default gen_random_uuid(),
  ingestion_id uuid not null references public.fx_ingestions (id),
  rate_date date not null,
  -- 고시값 그대로(소수 넷째 자리까지). 문자열로 받아 정확한 numeric으로 둔다(부동소수 없음).
  rate numeric not null check (rate > 0 and rate < 1000000 and scale(rate) <= 4),
  unique (ingestion_id, rate_date)
);

create function private.reject_fx_mutation() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception 'fx records are immutable' using errcode = 'PT409';
end $$;
create trigger fx_ingestions_immutable before update or delete on public.fx_ingestions
  for each row execute function private.reject_fx_mutation();
create trigger fx_quotes_immutable before update or delete on public.fx_quotes
  for each row execute function private.reject_fx_mutation();

alter table public.fx_ingestions enable row level security;
alter table public.fx_quotes enable row level security;
-- 앱 역할은 표를 직접 읽지 못한다. 장부·검토 RPC가 필요한 값만 돌려준다.
revoke all on public.fx_ingestions, public.fx_quotes from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------- 정확한 환산(원 단위 반올림, 양수 .5 올림)
-- n ≥ 0, d > 0인 numeric: floor(n/d + 1/2) = div(2n + d, 2d). 나눗셈의 무한소수 반올림 없이 정확하다.
create function private.half_up_div(p_n numeric, p_d numeric) returns numeric
language sql immutable strict set search_path = '' as $$
  select div(2 * p_n + p_d, 2 * p_d)
$$;

-- 기준환율 예상액: 엔 × 고시값 ÷ 단위.
create function private.fx_krw(p_amount bigint, p_rate numeric, p_unit integer) returns bigint
language sql immutable strict set search_path = '' as $$
  select private.half_up_div(p_amount::numeric * p_rate, p_unit::numeric)::bigint
$$;

-- 외화 취득 원가: 엔 × (환전에 쓴 원화 ÷ 받은 엔).
create function private.acq_krw(p_amount bigint, p_paid bigint, p_foreign bigint) returns bigint
language sql immutable strict set search_path = '' as $$
  select private.half_up_div(p_amount::numeric * p_paid::numeric, p_foreign::numeric)::bigint
$$;

-- ---------------------------------------------------------------- expenses: 환산 기준과 고정한 값
alter table public.expenses
  add column fx_quote_id uuid references public.fx_quotes (id),
  add column fx_rate numeric,
  add column fx_quote_unit integer,
  add column fx_rate_date date,
  add column acq_krw bigint check (acq_krw is null or (acq_krw > 0 and acq_krw < 10000000000)),
  add column acq_foreign_minor bigint check (acq_foreign_minor is null or (acq_foreign_minor > 0 and acq_foreign_minor < 1000000000));
create index expenses_fx_quote_idx on public.expenses (fx_quote_id);
alter table public.expenses drop constraint expenses_krw_basis;
alter table public.expenses drop constraint expenses_krw_basis_check;
alter table public.expenses
  add constraint expenses_krw_basis_check check (krw_basis is null or krw_basis in
    ('krw_original', 'verified_krw_charge', 'acquisition_cost', 'reference_rate_estimate')),
  -- 기준마다 원화가 어디서 왔는지 행 안에서 다시 계산해 맞는지 본다.
  add constraint expenses_krw_basis check (krw_basis is null
    or (krw_basis = 'krw_original' and currency = 'KRW' and krw_amount = amount_minor)
    or (krw_basis = 'verified_krw_charge' and currency <> 'KRW')
    or (krw_basis = 'acquisition_cost' and currency = 'JPY'
        and krw_amount = private.acq_krw(amount_minor, acq_krw, acq_foreign_minor))
    or (krw_basis = 'reference_rate_estimate' and currency = 'JPY' and fx_quote_unit = 100 and fx_rate_date <= expense_date
        and krw_amount = private.fx_krw(amount_minor, fx_rate, fx_quote_unit))),
  add constraint expenses_fx_fields check (
    (krw_basis is not distinct from 'reference_rate_estimate')
      = (fx_quote_id is not null and fx_rate is not null and fx_quote_unit is not null and fx_rate_date is not null)
    and (fx_quote_id is null) = (fx_rate is null) and (fx_rate is null) = (fx_quote_unit is null)
    and (fx_quote_unit is null) = (fx_rate_date is null)),
  add constraint expenses_acq_fields check (
    (krw_basis is not distinct from 'acquisition_cost') = (acq_krw is not null and acq_foreign_minor is not null)
    and (acq_krw is null) = (acq_foreign_minor is null));

-- ---------------------------------------------------------------- 받기(ECOS 응답 원문 검사)
create function private.ecos_date(p text) returns date
language plpgsql immutable set search_path = '' as $$
begin
  if p is null or p !~ '^[0-9]{8}$' then return null; end if;
  return make_date(substr(p, 1, 4)::int, substr(p, 5, 2)::int, substr(p, 7, 2)::int);
exception when others then return null;
end $$;

-- p_response: ECOS StatisticSearch 응답(JSON) 그대로. p_start·p_end: 그 응답을 요청한 기간(YYYYMMDD와 같은 날짜).
-- 형식이 하나라도 어긋나면 아무것도 넣지 않는다.
create function private.ingest_fx_response(p_response jsonb, p_start date, p_end date, p_origin text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_rows jsonb; v_row jsonb; v_count int; v_date date; v_dates date[] := '{}'; v_values text[] := '{}';
  v_id uuid; v_today date := (now() at time zone 'Asia/Seoul')::date;
begin
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
      coverage_start, coverage_end, data_origin, response_sha256, row_count)
    values ('bok_ecos', '731Y001', '0000002', '원/일본엔(100엔)', '원', 'JPY', 100, p_start, p_end, p_origin,
      encode(sha256(convert_to(p_response::text, 'UTF8')), 'hex'), v_count)
    returning id into v_id;
  insert into public.fx_quotes (ingestion_id, rate_date, rate)
    select v_id, d, v::numeric from unnest(v_dates, v_values) as u(d, v);
  return jsonb_build_object('ingestion_id', v_id, 'rows', v_count, 'coverage_start', p_start, 'coverage_end', p_end,
    'data_origin', p_origin);
end $$;

-- service_role 전용(API로 받는 길). 언제나 ecos_live로 기록한다: ECOS에서 실제로 받은 응답만 이 길로 넣는다.
-- 가상 시험값은 DB 소유자가 private.ingest_fx_response(..., 'fixture')로만 넣는다(scripts/ecos-fx.py fixture).
create function private.ingest_ecos_live(p_response jsonb, p_start date, p_end date) returns jsonb
language sql security definer set search_path = '' as $$
  select private.ingest_fx_response(p_response, p_start, p_end, 'ecos_live')
$$;
create function public.ingest_ecos_jpy_rates(p_response jsonb, p_start date, p_end date) returns jsonb
language sql security invoker set search_path = '' as $$
  select private.ingest_ecos_live(p_response, p_start, p_end)
$$;

-- ---------------------------------------------------------------- 정하기(as-of)
create function private.fx_quote_json(p_quote uuid) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object('quote_id', q.id, 'source', i.source, 'stat_code', i.stat_code, 'item_code', i.item_code,
    'item_name', i.item_name, 'unit_name', i.unit_name, 'currency', i.currency, 'quote_unit', i.quote_unit,
    'rate', q.rate::text, 'rate_date', q.rate_date, 'data_origin', i.data_origin,
    'determined_at', to_char(i.fetched_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
  from public.fx_quotes q join public.fx_ingestions i on i.id = q.ingestion_id where q.id = p_quote
$$;

-- 지출일 p_date의 기준환율 제안(p_as_of 시점까지 받은 기록으로). JPY가 아니면 null.
-- status: proposed(값과 원화 포함) | undetermined(그날을 덮는 받기 기록 없음) | unavailable(31일 안에 고시 없음).
create function private.fx_proposal(p_currency text, p_date date, p_amount bigint, p_as_of timestamptz) returns jsonb
language plpgsql stable set search_path = '' as $$
declare v_day date; v_run uuid; v_quote public.fx_quotes;
begin
  if p_currency is distinct from 'JPY' or p_date is null or p_amount is null then return null; end if;
  for i in 0..31 loop
    v_day := p_date - i;
    select r.id into v_run from public.fx_ingestions r
      where r.currency = 'JPY' and v_day between r.coverage_start and r.coverage_end and r.fetched_at <= p_as_of
      order by r.fetched_at desc, r.id desc limit 1;
    if v_run is null then
      return jsonb_build_object('status', 'undetermined', 'missing_date', v_day);
    end if;
    select * into v_quote from public.fx_quotes q where q.ingestion_id = v_run and q.rate_date = v_day;
    if found then
      return private.fx_quote_json(v_quote.id) || jsonb_build_object('status', 'proposed',
        'krw', private.fx_krw(p_amount, v_quote.rate, 100));
    end if;
    v_run := null;
  end loop;
  return jsonb_build_object('status', 'unavailable');
end $$;

-- 포함한 예상액이 지금의 제안과 다른가(더 새 고시값이 들어왔다). 포함 금액은 바뀌지 않는다.
create function private.fx_superseded(e public.expenses) returns boolean
language sql stable set search_path = '' as $$
  select case when e.krw_basis is distinct from 'reference_rate_estimate' then false else
    coalesce((select p ->> 'status' <> 'proposed' or (p ->> 'rate_date')::date <> e.fx_rate_date
                or (p ->> 'rate')::numeric <> e.fx_rate or (p ->> 'quote_unit')::int <> e.fx_quote_unit
              from (select private.fx_proposal(e.currency, e.expense_date, e.amount_minor, now()) as p) x), true) end
$$;

-- ---------------------------------------------------------------- 앱용 모양: 환산 기준을 함께 보인다
-- 확정 스냅숏(compute_settlement)도 이 모양을 쓴다. 고정한 고시값의 출처·단위·기준일·받은 시각이 스냅숏에 들어간다.
create or replace function private.expense_json(e public.expenses) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'expense_id', e.id, 'version', e.version, 'entry', e.entry, 'uploaded_by', e.uploaded_by,
    'expense_date', e.expense_date, 'amount_minor', e.amount_minor, 'currency', e.currency, 'merchant', e.merchant,
    'status', e.status, 'payer_id', e.payer_id, 'krw_amount', e.krw_amount, 'krw_basis', e.krw_basis,
    'hold_reason', e.hold_reason, 'has_artifact', e.artifact_path is not null,
    'shares', (select coalesce(jsonb_agg(jsonb_build_object('user_id', s.user_id, 'krw', s.krw) order by s.user_id), '[]'::jsonb)
               from public.expense_shares s where s.expense_id = e.id),
    'is_estimate', e.krw_basis is not distinct from 'reference_rate_estimate',
    'fx', case when e.fx_quote_id is not null then
      private.fx_quote_json(e.fx_quote_id) || jsonb_build_object('rate', e.fx_rate::text, 'rate_date', e.fx_rate_date,
        'quote_unit', e.fx_quote_unit) end,
    'acquisition', case when e.acq_krw is not null then
      jsonb_build_object('krw_paid', e.acq_krw, 'foreign_minor', e.acq_foreign_minor, 'currency', e.currency) end)
$$;

-- 장부: 열린 방의 JPY 지출에는 지금의 기준환율 제안을, 포함한 예상액에는 더 새 고시값이 있는지를 더한다(스냅숏에는 넣지 않는다).
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
                        'fx_proposal', case when v_trip.status = 'open'
                          then private.fx_proposal(e.currency, e.expense_date, e.amount_minor, now()) end,
                        'fx_superseded', v_trip.status = 'open' and private.fx_superseded(e))
                   order by e.expense_date, e.created_at, e.id), '[]'::jsonb)
                 from public.expenses e where e.trip_id = p_trip),
    'finalization_id', (select f.id from public.finalizations f where f.trip_id = p_trip order by f.version desc limit 1));
end $$;

-- 계산: 공동 지출 중 기준환율 예상액의 합(estimated_total_krw)을 더한다. 나머지는 그대로다.
create or replace function private.compute_settlement(p_trip uuid) returns jsonb
language plpgsql stable set search_path = '' as $$
declare
  v_members jsonb; v_expenses jsonb; v_total bigint; v_estimated bigint; v_pending jsonb; v_excluded jsonb;
  v_bal jsonb; v_net jsonb; v_transfers jsonb := '[]'::jsonb; d record; c record; v_amt bigint;
begin
  select coalesce(jsonb_agg(jsonb_build_object('user_id', m.user_id, 'display_name', m.display_name, 'role', m.role)
           order by m.joined_at, m.user_id), '[]'::jsonb)
    into v_members from public.trip_members m where m.trip_id = p_trip;

  select
    coalesce(jsonb_agg(private.expense_json(e) || jsonb_build_object('kind', k.kind)
      order by e.expense_date, e.created_at, e.id), '[]'::jsonb),
    coalesce(sum(e.krw_amount) filter (where k.kind = 'shared'), 0),
    coalesce(sum(e.krw_amount) filter (where k.kind = 'shared' and e.krw_basis = 'reference_rate_estimate'), 0),
    coalesce(jsonb_agg(e.id order by e.expense_date, e.created_at, e.id) filter (where k.kind = 'pending'), '[]'::jsonb),
    coalesce(jsonb_agg(jsonb_build_object('expense_id', e.id, 'kind', k.kind, 'reason', e.hold_reason)
      order by e.expense_date, e.created_at, e.id) filter (where k.kind in ('held', 'personal')), '[]'::jsonb)
  into v_expenses, v_total, v_estimated, v_pending, v_excluded
  from public.expenses e cross join lateral (select private.expense_kind(e) as kind) k
  where e.trip_id = p_trip;

  with shared as (
    select e.* from public.expenses e where e.trip_id = p_trip and private.expense_kind(e) = 'shared'
  ), paid as (
    select payer_id as user_id, sum(krw_amount) as krw from shared group by payer_id
  ), owed as (
    select s.user_id, sum(s.krw) as krw from public.expense_shares s join shared on shared.id = s.expense_id group by s.user_id
  )
  select coalesce(jsonb_object_agg(m.user_id::text, coalesce(p.krw, 0) - coalesce(o.krw, 0)), '{}'::jsonb)
    into v_bal
    from public.trip_members m left join paid p on p.user_id = m.user_id left join owed o on o.user_id = m.user_id
    where m.trip_id = p_trip;

  v_net := v_bal;
  loop
    select key::uuid as user_id, -(value::bigint) as amt into d from jsonb_each_text(v_net)
      where value::bigint < 0 order by value::bigint asc, key limit 1;
    exit when not found;
    select key::uuid as user_id, value::bigint as amt into c from jsonb_each_text(v_net)
      where value::bigint > 0 order by value::bigint desc, key limit 1;
    exit when not found;
    v_amt := least(d.amt, c.amt);
    v_transfers := v_transfers || jsonb_build_array(jsonb_build_object('from', d.user_id, 'to', c.user_id, 'krw', v_amt));
    v_net := v_net || jsonb_build_object(d.user_id::text, (v_net ->> d.user_id::text)::bigint + v_amt,
                                         c.user_id::text, (v_net ->> c.user_id::text)::bigint - v_amt);
  end loop;
  if exists (select 1 from jsonb_each_text(v_net) where value::bigint <> 0) then
    perform private.fail('unbalanced', 'PT500');
  end if;

  return jsonb_build_object(
    'members', v_members, 'expenses', v_expenses, 'included_total_krw', v_total, 'estimated_total_krw', v_estimated,
    'pending_expense_ids', v_pending, 'excluded', v_excluded,
    'balances', (select coalesce(jsonb_agg(jsonb_build_object('user_id', key::uuid, 'net_krw', value::bigint) order by key),
                   '[]'::jsonb) from jsonb_each_text(v_bal)),
    'transfers', v_transfers);
end $$;

-- ---------------------------------------------------------------- 검토: 환산 기준을 받는다
-- 새 인자는 모두 기본값 null이다. p_krw_basis가 null이면 예전 요청과 같다(외화는 확인한 청구액, 요청 지문도 같다).
-- p_krw_basis: null | krw_original | verified_krw_charge | acquisition_cost | reference_rate_estimate.
-- acquisition_cost: p_acq_krw(환전에 쓴 원화), p_acq_foreign_minor(받은 엔). reference_rate_estimate: p_fx_quote_id(본 고시값).
-- 두 기준 모두 p_krw_amount는 방장이 본 원화이고, 서버 계산과 다르면 krw_mismatch로 거절한다.
drop function public.review_expense(uuid, integer, uuid, text, uuid, bigint, jsonb, text);
drop function private.review_expense(uuid, integer, uuid, text, uuid, bigint, jsonb, text);

create function private.review_expense(
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
        -- 기준환율 예상액(우선순위 3). 방장이 본 고시값이 지금도 그 지출일의 제안과 같아야 한다.
        if v_e.currency <> 'JPY' or p_acq_krw is not null or p_acq_foreign_minor is not null or p_fx_quote_id is null then
          perform private.fail('basis_invalid', 'PT400');
        end if;
        v_prop := private.fx_proposal(v_e.currency, v_e.expense_date, v_e.amount_minor, now());
        select * into v_q from public.fx_quotes where id = p_fx_quote_id;
        if found then select * into v_run from public.fx_ingestions where id = v_q.ingestion_id; end if;
        -- null이 섞여도 거절하도록 is distinct from으로만 비교한다.
        if v_q.id is null or (v_prop ->> 'status') is distinct from 'proposed'
           or (v_prop ->> 'rate_date')::date is distinct from v_q.rate_date
           or (v_prop ->> 'rate')::numeric is distinct from v_q.rate or v_run.quote_unit is distinct from 100
           or (v_prop ->> 'data_origin') is distinct from v_run.data_origin then
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

create function public.review_expense(
  p_expense uuid, p_expected_version integer, p_request_id uuid, p_decision text,
  p_payer uuid default null, p_krw_amount bigint default null, p_shares jsonb default null, p_hold_reason text default null,
  p_krw_basis text default null, p_fx_quote_id uuid default null, p_acq_krw bigint default null,
  p_acq_foreign_minor bigint default null
) returns jsonb
language sql security invoker set search_path = '' as $$
  select private.review_expense(p_expense, p_expected_version, p_request_id, p_decision, p_payer, p_krw_amount, p_shares,
    p_hold_reason, p_krw_basis, p_fx_quote_id, p_acq_krw, p_acq_foreign_minor) $$;

-- ---------------------------------------------------------------- 확정: 규칙 판 v2
-- v2 = v1(explicit-krw-shares-v1) + 지출의 환산 기준(취득 원가·고정한 기준환율 고시값)과 outputs.estimated_total_krw.
-- 이미 확정한 v1 스냅숏은 그대로 둔다(행은 바꿀 수 없다).
create or replace function private.finalize_settlement(p_trip uuid, p_expected_revision bigint, p_request_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_uid(); l record; v_f public.finalizations; v_calc jsonb; v_snapshot jsonb; v_rev bigint; v_ver int;
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
revoke all on function private.reject_fx_mutation(), private.half_up_div(numeric, numeric),
  private.fx_krw(bigint, numeric, integer), private.acq_krw(bigint, bigint, bigint), private.ecos_date(text),
  private.ingest_fx_response(jsonb, date, date, text), private.ingest_ecos_live(jsonb, date, date),
  public.ingest_ecos_jpy_rates(jsonb, date, date), private.fx_quote_json(uuid),
  private.fx_proposal(text, date, bigint, timestamptz), private.fx_superseded(public.expenses),
  private.review_expense(uuid, integer, uuid, text, uuid, bigint, jsonb, text, text, uuid, bigint, bigint),
  public.review_expense(uuid, integer, uuid, text, uuid, bigint, jsonb, text, text, uuid, bigint, bigint)
  from public, anon, authenticated, service_role;
grant execute on function
  private.review_expense(uuid, integer, uuid, text, uuid, bigint, jsonb, text, text, uuid, bigint, bigint),
  public.review_expense(uuid, integer, uuid, text, uuid, bigint, jsonb, text, text, uuid, bigint, bigint)
  to authenticated;
-- 받기는 service_role만(앱 역할·익명은 부를 수 없다). 가상 시험값을 넣는 private.ingest_fx_response는 소유자만.
grant usage on schema private to service_role;
grant execute on function private.ingest_ecos_live(jsonb, date, date), public.ingest_ecos_jpy_rates(jsonb, date, date)
  to service_role;
