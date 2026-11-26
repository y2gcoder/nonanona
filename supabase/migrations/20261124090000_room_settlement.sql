-- 여행방 정산(서버 기준). 앱의 로컬 debug 모드가 부르는 서버 쪽이다.
-- local-collaboration 실험의 방 잠금·revision·확정 스냅숏 방식을 옮기고, 부담을 "정확한 원 단위 몫"으로 바꿨다.
--
-- 규칙
-- * 쓰기는 RPC로만 한다. 모든 쓰기 RPC는 여행방 행을 FOR UPDATE로 잠근 뒤 revision을 올리고 trip_events에 남긴다.
--   그래서 확정과 지출 추가·검토·가입이 같은 잠금으로 직렬화된다. 잠금 순서는 여행방 → 지출.
-- * 역할은 따로 둔다: 올린 사람(uploaded_by, 제출한 계정), 결제자(payer_id), 부담자와 몫(expense_shares). 결제자와
--   부담은 방장이 검토에서 정한다. 구성원 제출은 언제나 "확인 필요(pending)"로 들어온다.
-- * 원화: KRW 지출은 원래 금액(krw_original), 외화 지출은 방장이 확인한 실제 원화 청구액(verified_krw_charge)만 받는다.
--   기준환율 자동 환산은 없다(제공처·반올림 미정, ADR-0001). 원화를 모르면 확인 필요로 두거나 사유와 함께 보류한다.
-- * 몫: 서버는 몫을 정하지 않는다. 방장이 보낸 원 단위 몫의 합이 원화 금액과 정확히 같아야 한다. 반으로 나누어떨어지지
--   않으면 앱이 몫을 직접 적게 한다(남는 원을 누구에게 줄지 서버·앱이 고르지 않는다).
-- * 확정: 방장이 검토한 revision으로만, 확인 필요 지출이 없을 때만. 그 시점의 입력(구성원·지출·몫)과 결과(잔액·송금)를
--   불변 스냅숏으로 남기고 방을 잠근다. 보류 지출은 송금에서 빠지고 제외 목록에 사유와 함께 남는다. 확정 뒤 정정은 없다.
-- * 재시도: 지출 제출은 (여행방, request_id) 고유 키와 요청 지문, 검토는 settlement_requests, 확정은 finalizations의
--   (여행방, request_id). 같은 요청은 같은 결과(replayed), 같은 키의 다른 내용은 idempotency_conflict.
--
-- 실패 코드(PostgREST 응답 message, accept_invite의 trip_finalized 포함): not_authenticated(401), trip_not_found(404, 비구성원·없는 방·없는 지출을 구분하지 않음),
-- host_only(403), trip_finalized(409), stale_expense(409), stale_revision(409), pending_review(409), idempotency_conflict(409),
-- invalid_fields(400), payer_required(400), krw_unverified(400), shares_invalid(400), shares_mismatch(400),
-- hold_reason_required(400), decision_invalid(400), artifact_missing(409).

-- ---------------------------------------------------------------- trips: 상태와 revision
alter table public.trips
  add column status text not null default 'open' check (status in ('open', 'finalized')),
  add column revision bigint not null default 1 check (revision >= 1);

-- 수정 이력: 누가 언제 무엇을(값은 담지 않는다). 확정 거절(stale_revision)에 새 변경 목록으로 쓴다.
create table public.trip_events (
  id bigint generated always as identity primary key,
  trip_id uuid not null references public.trips (id),
  revision bigint not null,
  actor uuid not null references auth.users (id),
  action text not null,
  target uuid,
  at timestamptz not null default now(),
  unique (trip_id, revision)
);
create index trip_events_actor_idx on public.trip_events (actor);

-- ---------------------------------------------------------------- expenses: 직접 입력과 검토 필드
alter table public.expenses
  add column entry text not null default 'receipt' check (entry in ('receipt', 'manual')),
  add column payer_id uuid,
  add column status text not null default 'pending' check (status in ('pending', 'included', 'held')),
  add column krw_amount bigint check (krw_amount is null or (krw_amount > 0 and krw_amount < 100000000000)),
  add column krw_basis text check (krw_basis is null or krw_basis in ('krw_original', 'verified_krw_charge')),
  add column hold_reason text check (hold_reason is null
    or (char_length(hold_reason) between 1 and 80 and hold_reason !~ '[[:cntrl:]]')),
  add column version integer not null default 1 check (version >= 1),
  add column updated_at timestamptz not null default now(),
  add column updated_by uuid references auth.users (id),
  add foreign key (trip_id, payer_id) references public.trip_members (trip_id, user_id);
alter table public.expenses alter column entry drop default;
alter table public.expenses alter column artifact_path drop not null, alter column artifact_sha256 drop not null;
alter table public.expenses
  add constraint expenses_entry_artifact check ((entry = 'receipt') = (artifact_path is not null)),
  add constraint expenses_artifact_pair check ((artifact_path is null) = (artifact_sha256 is null)),
  add constraint expenses_included_complete check (status <> 'included'
    or (payer_id is not null and krw_amount is not null and krw_basis is not null)),
  add constraint expenses_held_reason check (status <> 'held' or hold_reason is not null),
  -- KRW 지출의 원화는 원래 금액뿐이고, 외화 지출은 확인한 청구액뿐이다.
  add constraint expenses_krw_basis check (krw_basis is null
    or (krw_basis = 'krw_original' and currency = 'KRW' and krw_amount = amount_minor)
    or (krw_basis = 'verified_krw_charge' and currency <> 'KRW'));
create index expenses_trip_payer_idx on public.expenses (trip_id, payer_id);
create index expenses_updated_by_idx on public.expenses (updated_by);

-- 부담 몫(원). 한 지출의 몫 합은 원화 금액과 같다(검토 RPC가 검사한다). 품목별·묶음별 나누기는 나중에 몫 줄에
-- 묶음 열을 더하는 식으로 넓힐 수 있게, 지출 행이 아니라 몫 줄로 둔다.
create table public.expense_shares (
  expense_id uuid not null references public.expenses (id),
  trip_id uuid not null,
  user_id uuid not null,
  krw bigint not null check (krw > 0 and krw < 100000000000),
  primary key (expense_id, user_id),
  foreign key (trip_id, user_id) references public.trip_members (trip_id, user_id)
);
create index expense_shares_trip_user_idx on public.expense_shares (trip_id, user_id);

-- 검토 요청 재시도 기록. 앱 역할은 읽지도 못한다.
create table public.settlement_requests (
  trip_id uuid not null references public.trips (id),
  request_id uuid not null,
  kind text not null,
  fingerprint text not null,
  response jsonb not null,
  actor uuid not null references auth.users (id),
  at timestamptz not null default now(),
  primary key (trip_id, request_id)
);
create index settlement_requests_actor_idx on public.settlement_requests (actor);

-- 확정본. 입력과 결과를 함께 고정한다(특권 함수 포함 수정·삭제 불가).
create table public.finalizations (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.trips (id),
  version integer not null check (version >= 1),
  reviewed_revision bigint not null,
  request_id uuid not null,
  finalized_by uuid not null references auth.users (id),
  finalized_at timestamptz not null default now(),
  rule_version text not null,
  included_total_krw bigint not null,
  snapshot jsonb not null,
  snapshot_sha256 text not null check (snapshot_sha256 ~ '^[0-9a-f]{64}$'),
  unique (trip_id, version),
  unique (trip_id, request_id)
);
create index finalizations_finalized_by_idx on public.finalizations (finalized_by);

create function private.reject_mutation() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception 'finalizations are immutable' using errcode = 'PT409';
end $$;
create trigger finalizations_immutable before update or delete on public.finalizations
  for each row execute function private.reject_mutation();

alter table public.trip_events enable row level security;
alter table public.expense_shares enable row level security;
alter table public.settlement_requests enable row level security;
alter table public.finalizations enable row level security;
revoke all on public.trip_events, public.expense_shares, public.settlement_requests, public.finalizations
  from public, anon, authenticated;
grant select on public.trip_events, public.expense_shares, public.finalizations to authenticated;
-- settlement_requests: 앱 역할에 어떤 권한도 주지 않는다.
create policy events_member_read on public.trip_events for select to authenticated
  using ((select private.is_member(trip_id)));
create policy shares_member_read on public.expense_shares for select to authenticated
  using ((select private.is_member(trip_id)));
create policy finalizations_member_read on public.finalizations for select to authenticated
  using ((select private.is_member(trip_id)));

-- ---------------------------------------------------------------- helpers
create function private.fail_with(p_code text, p_http text, p_detail jsonb) returns void
language plpgsql set search_path = '' as $$
begin
  raise exception using errcode = p_http, message = p_code, detail = p_detail::text;
end $$;

-- 여행방 잠금 + 구성원 검사. 비구성원과 없는 방은 구분하지 않는다.
create function private.lock_trip(p_trip uuid, p_uid uuid, out trip public.trips, out role text)
language plpgsql set search_path = '' as $$
begin
  select m.role into role from public.trip_members m where m.trip_id = p_trip and m.user_id = p_uid;
  if role is null then perform private.fail('trip_not_found', 'PT404'); end if;
  select t.* into trip from public.trips t where t.id = p_trip for update;
end $$;

create function private.bump(p_trip uuid, p_uid uuid, p_action text, p_target uuid) returns bigint
language plpgsql set search_path = '' as $$
declare v bigint;
begin
  update public.trips set revision = revision + 1 where id = p_trip returning revision into v;
  insert into public.trip_events (trip_id, revision, actor, action, target) values (p_trip, v, p_uid, p_action, p_target);
  return v;
end $$;

create function private.valid_merchant(p text) returns boolean
language sql immutable set search_path = '' as $$
  select p is null or (char_length(p) between 1 and 80 and p !~ '[[:cntrl:]]')
$$;

-- 지출 한 건의 앱용 모양(구성원에게 보이는 값만).
create function private.expense_json(e public.expenses) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'expense_id', e.id, 'version', e.version, 'entry', e.entry, 'uploaded_by', e.uploaded_by,
    'expense_date', e.expense_date, 'amount_minor', e.amount_minor, 'currency', e.currency, 'merchant', e.merchant,
    'status', e.status, 'payer_id', e.payer_id, 'krw_amount', e.krw_amount, 'krw_basis', e.krw_basis,
    'hold_reason', e.hold_reason, 'has_artifact', e.artifact_path is not null,
    'shares', (select coalesce(jsonb_agg(jsonb_build_object('user_id', s.user_id, 'krw', s.krw) order by s.user_id), '[]'::jsonb)
               from public.expense_shares s where s.expense_id = e.id))
$$;

-- 지출 종류: pending, held, personal(결제자 혼자 전부 부담 — 공동 정산에서 제외), shared(공동).
create function private.expense_kind(e public.expenses) returns text
language sql stable set search_path = '' as $$
  select case
    when e.status = 'pending' then 'pending'
    when e.status = 'held' then 'held'
    when (select count(*) from public.expense_shares s where s.expense_id = e.id) = 1
     and exists (select 1 from public.expense_shares s where s.expense_id = e.id and s.user_id = e.payer_id) then 'personal'
    else 'shared' end
$$;

-- 지금 입력으로 정산을 계산한다(미리보기와 확정이 같은 함수를 쓴다). 공동 지출만 합계·잔액·송금에 들어가고, 보류와
-- 개인 지출은 제외 목록에 남는다. 확인 필요 지출은 pending_expense_ids로 알린다(확정은 이것이 비어야 한다).
-- 송금은 순잔액(낸 원화 − 부담 원화)을 금액이 큰 순서·user_id 순으로 짝지어 결정적으로 만든다.
create function private.compute_settlement(p_trip uuid) returns jsonb
language plpgsql stable set search_path = '' as $$
declare
  v_members jsonb; v_expenses jsonb; v_total bigint; v_pending jsonb; v_excluded jsonb;
  v_bal jsonb; v_net jsonb; v_transfers jsonb := '[]'::jsonb; d record; c record; v_amt bigint;
begin
  select coalesce(jsonb_agg(jsonb_build_object('user_id', m.user_id, 'display_name', m.display_name, 'role', m.role)
           order by m.joined_at, m.user_id), '[]'::jsonb)
    into v_members from public.trip_members m where m.trip_id = p_trip;

  select
    coalesce(jsonb_agg(private.expense_json(e) || jsonb_build_object('kind', k.kind)
      order by e.expense_date, e.created_at, e.id), '[]'::jsonb),
    coalesce(sum(e.krw_amount) filter (where k.kind = 'shared'), 0),
    coalesce(jsonb_agg(e.id order by e.expense_date, e.created_at, e.id) filter (where k.kind = 'pending'), '[]'::jsonb),
    coalesce(jsonb_agg(jsonb_build_object('expense_id', e.id, 'kind', k.kind, 'reason', e.hold_reason)
      order by e.expense_date, e.created_at, e.id) filter (where k.kind in ('held', 'personal')), '[]'::jsonb)
  into v_expenses, v_total, v_pending, v_excluded
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
    'members', v_members, 'expenses', v_expenses, 'included_total_krw', v_total,
    'pending_expense_ids', v_pending, 'excluded', v_excluded,
    'balances', (select coalesce(jsonb_agg(jsonb_build_object('user_id', key::uuid, 'net_krw', value::bigint) order by key),
                   '[]'::jsonb) from jsonb_each_text(v_bal)),
    'transfers', v_transfers);
end $$;

-- ---------------------------------------------------------------- 기존 RPC: revision을 올리고 확정된 방을 막는다
-- 실패 코드·서명·권한은 그대로다. 같은 request_id 재시도는 확정 뒤에도 기존 지출을 돌려준다(새로 만들지 않음).
create or replace function private.submit_receipt_expense(
  p_trip uuid, p_request_id uuid, p_expense_date date, p_amount_minor bigint, p_currency text,
  p_merchant text, p_artifact_sha256 text
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_uid(); l record; v_path text; v_fp text; v_old public.expenses; v_obj record; v_id uuid;
  v_rev bigint;
begin
  select * into l from private.lock_trip(p_trip, v_uid);
  v_path := p_trip::text || '/' || v_uid::text || '/' || p_request_id::text || '.png';
  v_fp := encode(sha256(convert_to(concat_ws('|', p_expense_date, p_amount_minor, p_currency,
            coalesce(p_merchant, '-'), p_artifact_sha256), 'UTF8')), 'hex');
  select * into v_old from public.expenses where trip_id = p_trip and client_request_id = p_request_id;
  if found then
    if v_old.request_fingerprint <> v_fp or v_old.entry <> 'receipt' then
      perform private.fail('idempotency_conflict', 'PT409');
    end if;
    return jsonb_build_object('expense_id', v_old.id, 'replayed', true);
  end if;
  if (l.trip).status <> 'open' then perform private.fail('trip_finalized', 'PT409'); end if;
  if p_amount_minor is null or p_amount_minor <= 0 or p_amount_minor >= 100000000 or p_expense_date is null
     or p_currency is null or p_currency !~ '^[A-Z]{3}$' or p_artifact_sha256 is null
     or p_artifact_sha256 !~ '^[0-9a-f]{64}$' or not private.valid_merchant(p_merchant) then
    perform private.fail('invalid_fields', 'PT400');
  end if;
  select o.owner_id, o.metadata into v_obj from storage.objects o where o.bucket_id = 'receipts' and o.name = v_path;
  if not found or v_obj.owner_id is distinct from v_uid::text or v_obj.metadata ->> 'mimetype' is distinct from 'image/png' then
    perform private.fail('artifact_missing', 'PT409');
  end if;
  insert into public.expenses (trip_id, client_request_id, request_fingerprint, uploaded_by, entry, expense_date,
      amount_minor, currency, merchant, artifact_path, artifact_sha256, updated_by)
    values (p_trip, p_request_id, v_fp, v_uid, 'receipt', p_expense_date, p_amount_minor, p_currency, p_merchant,
      v_path, p_artifact_sha256, v_uid)
    returning id into v_id;
  v_rev := private.bump(p_trip, v_uid, 'expense_submitted', v_id);
  return jsonb_build_object('expense_id', v_id, 'replayed', false, 'revision', v_rev);
end $$;

-- 가입도 방의 입력(구성원)을 바꾸므로 revision을 올린다. 확정된 방에는 새로 참여할 수 없다(trip_finalized, 409):
-- 여행방 잠금 뒤, 어떤 쓰기보다 먼저 거절해 초대·구성원·revision이 그대로다. 이미 그 초대로 참여한 같은 계정의 재시도는
-- 확정 뒤에도 기존 결과로 수렴한다.
create or replace function private.accept_invite(p_token text, p_display_name text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.require_uid(); v_inv public.trip_invites; v_trip public.trips; v_replayed boolean;
begin
  select * into v_inv from public.trip_invites where token_hash = private.token_hash(p_token);
  perform private.check_invite(v_inv, v_uid);
  select * into v_trip from public.trips where id = v_inv.trip_id for update;
  select * into v_inv from public.trip_invites where id = v_inv.id for update;
  perform private.check_invite(v_inv, v_uid);
  v_replayed := exists (select 1 from public.trip_members where trip_id = v_trip.id and user_id = v_uid);
  if not v_replayed and v_trip.status <> 'open' then perform private.fail('trip_finalized', 'PT409'); end if;
  if not v_replayed then
    insert into public.trip_members (trip_id, user_id, role, display_name)
      values (v_trip.id, v_uid, 'member', p_display_name);
    update public.trip_invites set used_by = v_uid, used_at = now() where id = v_inv.id;
    perform private.bump(v_trip.id, v_uid, 'member_joined', v_uid);
  end if;
  return jsonb_build_object(
    'trip_id', v_trip.id,
    'trip_name', v_trip.name,
    'replayed', v_replayed,
    'members', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'display_name', m.display_name, 'is_host', m.role = 'host', 'is_me', m.user_id = v_uid
      ) order by m.joined_at), '[]'::jsonb)
      from public.trip_members m where m.trip_id = v_trip.id
    )
  );
end $$;

-- ---------------------------------------------------------------- 새 RPC
-- 내가 참여한 여행방 목록.
create function private.list_my_trips() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := private.require_uid();
begin
  return (select coalesce(jsonb_agg(jsonb_build_object('trip_id', t.id, 'trip_name', t.name, 'status', t.status,
            'my_role', m.role) order by t.created_at, t.id), '[]'::jsonb)
          from public.trip_members m join public.trips t on t.id = m.trip_id where m.user_id = v_uid);
end $$;

-- 여행방 장부: 방 상태·revision, 구성원(ID 포함), 지출과 검토 값, 확정본 식별자.
create function private.get_room_ledger(p_trip uuid) returns jsonb
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
    'expenses', (select coalesce(jsonb_agg(private.expense_json(e) order by e.expense_date, e.created_at, e.id), '[]'::jsonb)
                 from public.expenses e where e.trip_id = p_trip),
    'finalization_id', (select f.id from public.finalizations f where f.trip_id = p_trip order by f.version desc limit 1));
end $$;

-- 증빙 없는 직접 입력. 허용 필드만 받고 사본은 없다. 결제자·부담은 방장이 검토에서 정한다.
create function private.submit_manual_expense(
  p_trip uuid, p_request_id uuid, p_expense_date date, p_amount_minor bigint, p_currency text, p_merchant text
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.require_uid(); l record; v_fp text; v_old public.expenses; v_id uuid; v_rev bigint;
begin
  select * into l from private.lock_trip(p_trip, v_uid);
  v_fp := encode(sha256(convert_to(concat_ws('|', 'manual', p_expense_date, p_amount_minor, p_currency,
            coalesce(p_merchant, '-')), 'UTF8')), 'hex');
  select * into v_old from public.expenses where trip_id = p_trip and client_request_id = p_request_id;
  if found then
    if v_old.request_fingerprint <> v_fp or v_old.entry <> 'manual' then
      perform private.fail('idempotency_conflict', 'PT409');
    end if;
    return jsonb_build_object('expense_id', v_old.id, 'replayed', true);
  end if;
  if (l.trip).status <> 'open' then perform private.fail('trip_finalized', 'PT409'); end if;
  if p_request_id is null or p_amount_minor is null or p_amount_minor <= 0 or p_amount_minor >= 100000000
     or p_expense_date is null or p_currency is null or p_currency !~ '^[A-Z]{3}$' or not private.valid_merchant(p_merchant) then
    perform private.fail('invalid_fields', 'PT400');
  end if;
  insert into public.expenses (trip_id, client_request_id, request_fingerprint, uploaded_by, entry, expense_date,
      amount_minor, currency, merchant, updated_by)
    values (p_trip, p_request_id, v_fp, v_uid, 'manual', p_expense_date, p_amount_minor, p_currency, p_merchant, v_uid)
    returning id into v_id;
  v_rev := private.bump(p_trip, v_uid, 'expense_submitted', v_id);
  return jsonb_build_object('expense_id', v_id, 'replayed', false, 'revision', v_rev);
end $$;

-- 방장 검토: 포함(결제자·원화·정확한 몫) 또는 보류(사유). 지출 버전으로 늦은 검토를 거부한다.
-- p_shares: [{"user_id": uuid, "krw": 정수}] (포함일 때만 쓴다).
create function private.review_expense(
  p_expense uuid, p_expected_version integer, p_request_id uuid, p_decision text,
  p_payer uuid, p_krw_amount bigint, p_shares jsonb, p_hold_reason text
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_uid(); v_trip uuid; l record; v_e public.expenses; v_fp text; v_req public.settlement_requests;
  v_krw bigint; v_basis text; v_rev bigint; v_resp jsonb; v_count int; v_sum numeric; v_share jsonb;
begin
  select e.trip_id into v_trip from public.expenses e where e.id = p_expense;
  if v_trip is null then perform private.fail('trip_not_found', 'PT404'); end if;
  select * into l from private.lock_trip(v_trip, v_uid);
  v_fp := encode(sha256(convert_to(concat_ws('|', 'review', p_expense, p_expected_version, p_decision,
            coalesce(p_payer::text, '-'), coalesce(p_krw_amount::text, '-'), coalesce(p_shares::text, '-'),
            coalesce(p_hold_reason, '-')), 'UTF8')), 'hex');
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
      if p_krw_amount is not null and p_krw_amount <> v_e.amount_minor then perform private.fail('krw_unverified', 'PT400'); end if;
      v_krw := v_e.amount_minor; v_basis := 'krw_original';
    else
      -- 외화는 확인한 실제 원화 청구액만 받는다. 기준환율 환산은 이번 범위에 없다.
      if p_krw_amount is null or p_krw_amount <= 0 or p_krw_amount >= 100000000000 then
        perform private.fail('krw_unverified', 'PT400');
      end if;
      v_krw := p_krw_amount; v_basis := 'verified_krw_charge';
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

-- 미리보기: 지금 입력으로 서버가 계산한 송금표. 구성원 누구나 볼 수 있다. 확정되면 확정본을 대신 보라고 알린다.
create function private.preview_settlement(p_trip uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := private.require_uid(); v_trip public.trips; v_calc jsonb;
begin
  if not exists (select 1 from public.trip_members m where m.trip_id = p_trip and m.user_id = v_uid) then
    perform private.fail('trip_not_found', 'PT404');
  end if;
  select * into v_trip from public.trips where id = p_trip;
  v_calc := private.compute_settlement(p_trip);
  return v_calc || jsonb_build_object('trip_id', p_trip, 'status', v_trip.status, 'revision', v_trip.revision,
    'ready', v_trip.status = 'open' and jsonb_array_length(v_calc -> 'pending_expense_ids') = 0);
end $$;

-- 원자적 확정: 방 잠금 → request_id 재생 확인 → 방장·상태·revision 검사 → 확인 필요 거부 → 계산 → 스냅숏·방 상태.
create function private.finalize_settlement(p_trip uuid, p_expected_revision bigint, p_request_id uuid) returns jsonb
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
    'rule_version', 'explicit-krw-shares-v1',
    'trip_id', p_trip, 'trip_name', (l.trip).name, 'reviewed_revision', p_expected_revision,
    'inputs', jsonb_build_object('members', v_calc -> 'members', 'expenses', v_calc -> 'expenses'),
    'outputs', jsonb_build_object('included_total_krw', v_calc -> 'included_total_krw', 'balances', v_calc -> 'balances',
      'transfers', v_calc -> 'transfers', 'excluded', v_calc -> 'excluded'));
  insert into public.finalizations (trip_id, version, reviewed_revision, request_id, finalized_by, rule_version,
      included_total_krw, snapshot, snapshot_sha256)
    values (p_trip, v_ver, p_expected_revision, p_request_id, v_uid, 'explicit-krw-shares-v1',
      (v_calc ->> 'included_total_krw')::bigint, v_snapshot, encode(sha256(convert_to(v_snapshot::text, 'UTF8')), 'hex'))
    returning * into v_f;
  return jsonb_build_object('finalization_id', v_f.id, 'version', v_f.version, 'replayed', false, 'revision', v_rev);
end $$;

-- 확정 결과 조회. 기기는 다시 계산하지 않고 이 스냅숏을 그린다.
create function private.get_finalized_settlement(p_trip uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := private.require_uid(); v_f public.finalizations;
begin
  if not exists (select 1 from public.trip_members m where m.trip_id = p_trip and m.user_id = v_uid) then
    perform private.fail('trip_not_found', 'PT404');
  end if;
  select * into v_f from public.finalizations where trip_id = p_trip order by version desc limit 1;
  if not found then return null; end if;
  -- 시각은 초 단위 UTC ISO 8601(끝에 Z). 기기가 자기 시간대로 보인다.
  return jsonb_build_object('finalization_id', v_f.id, 'version', v_f.version,
    'finalized_at', to_char(v_f.finalized_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'finalized_by', v_f.finalized_by, 'reviewed_revision', v_f.reviewed_revision, 'rule_version', v_f.rule_version,
    'snapshot_sha256', v_f.snapshot_sha256, 'snapshot', v_f.snapshot);
end $$;

-- ---------------------------------------------------------------- public wrappers (invoker)
create function public.list_my_trips() returns jsonb
language sql security invoker set search_path = '' as $$ select private.list_my_trips() $$;
create function public.get_room_ledger(p_trip uuid) returns jsonb
language sql security invoker set search_path = '' as $$ select private.get_room_ledger(p_trip) $$;
create function public.submit_manual_expense(
  p_trip uuid, p_request_id uuid, p_expense_date date, p_amount_minor bigint, p_currency text, p_merchant text default null
) returns jsonb
language sql security invoker set search_path = '' as $$
  select private.submit_manual_expense(p_trip, p_request_id, p_expense_date, p_amount_minor, p_currency, p_merchant) $$;
create function public.review_expense(
  p_expense uuid, p_expected_version integer, p_request_id uuid, p_decision text,
  p_payer uuid default null, p_krw_amount bigint default null, p_shares jsonb default null, p_hold_reason text default null
) returns jsonb
language sql security invoker set search_path = '' as $$
  select private.review_expense(p_expense, p_expected_version, p_request_id, p_decision, p_payer, p_krw_amount, p_shares,
    p_hold_reason) $$;
create function public.preview_settlement(p_trip uuid) returns jsonb
language sql security invoker set search_path = '' as $$ select private.preview_settlement(p_trip) $$;
create function public.finalize_settlement(p_trip uuid, p_expected_revision bigint, p_request_id uuid) returns jsonb
language sql security invoker set search_path = '' as $$ select private.finalize_settlement(p_trip, p_expected_revision, p_request_id) $$;
create function public.get_finalized_settlement(p_trip uuid) returns jsonb
language sql security invoker set search_path = '' as $$ select private.get_finalized_settlement(p_trip) $$;

-- 실행 권한: 새 함수 모두에서 PUBLIC/anon/authenticated를 뺀 뒤, 앱이 부르는 래퍼와 그 본문에만 authenticated를 준다.
-- 보조 함수(fail_with, lock_trip, bump, expense_json, expense_kind, compute_settlement, valid_merchant)는 definer 본문 안에서만 불린다.
revoke all on function private.reject_mutation(), private.fail_with(text, text, jsonb),
  private.lock_trip(uuid, uuid), private.bump(uuid, uuid, text, uuid), private.valid_merchant(text),
  private.expense_json(public.expenses), private.expense_kind(public.expenses), private.compute_settlement(uuid),
  private.list_my_trips(), private.get_room_ledger(uuid),
  private.submit_manual_expense(uuid, uuid, date, bigint, text, text),
  private.review_expense(uuid, integer, uuid, text, uuid, bigint, jsonb, text),
  private.preview_settlement(uuid), private.finalize_settlement(uuid, bigint, uuid), private.get_finalized_settlement(uuid),
  public.list_my_trips(), public.get_room_ledger(uuid),
  public.submit_manual_expense(uuid, uuid, date, bigint, text, text),
  public.review_expense(uuid, integer, uuid, text, uuid, bigint, jsonb, text),
  public.preview_settlement(uuid), public.finalize_settlement(uuid, bigint, uuid), public.get_finalized_settlement(uuid)
  from public, anon, authenticated;
grant execute on function
  private.list_my_trips(), private.get_room_ledger(uuid),
  private.submit_manual_expense(uuid, uuid, date, bigint, text, text),
  private.review_expense(uuid, integer, uuid, text, uuid, bigint, jsonb, text),
  private.preview_settlement(uuid), private.finalize_settlement(uuid, bigint, uuid), private.get_finalized_settlement(uuid),
  public.list_my_trips(), public.get_room_ledger(uuid),
  public.submit_manual_expense(uuid, uuid, date, bigint, text, text),
  public.review_expense(uuid, integer, uuid, text, uuid, bigint, jsonb, text),
  public.preview_settlement(uuid), public.finalize_settlement(uuid, bigint, uuid), public.get_finalized_settlement(uuid)
  to authenticated;
