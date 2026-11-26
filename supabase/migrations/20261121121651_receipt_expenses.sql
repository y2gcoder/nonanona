-- 확인한 영수증 올리기: 가림 사본(비공개 Storage) + 허용 필드 지출 행(RPC). 앱의 로컬 debug 모드가 부르는 서버 쪽이다.
-- local-collaboration 실험의 지출 제출·Storage 정책에서 필요한 부분만 옮겼다(결제자·부담자·원화 환산·검토는 정산 단계).
--
-- 순서와 원자성
-- * 앱은 (1) 사본을 <trip>/<올린 사람>/<request_id>.png 로 올리고 (2) submit_receipt_expense RPC로 지출 행을 만든다.
--   Storage와 DB는 한 트랜잭션이 아니다. (1)만 성공하고 끊기면 행 없는 객체가 남는다. 지출 목록은 행으로만 보이므로
--   반쯤 보이는 지출은 없다. 같은 request_id로 다시 시도하면 업로드는 "이미 있음"으로 끝나고 (2)가 행을 만든다.
-- * request_id는 앱이 (여행방, 사본 해시)로 정하는 결정적 키다. 같은 요청의 재시도·다시 열기는 같은 행으로 수렴하고,
--   같은 키에 다른 내용이 오면 idempotency_conflict로 거절한다.
-- * 행 없는 객체를 지우는 정리 작업은 아직 없다(덮어쓰기·삭제 정책도 두지 않는다).
--
-- 실패 코드(PostgREST 응답 message): not_authenticated(401), trip_not_found(404, 비구성원과 없는 방을 구분하지 않음),
-- artifact_missing(409), invalid_fields(400), idempotency_conflict(409).

create table public.expenses (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.trips (id),
  client_request_id uuid not null,
  request_fingerprint text not null,
  uploaded_by uuid not null,
  expense_date date not null,
  amount_minor bigint not null check (amount_minor > 0 and amount_minor < 100000000),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  merchant text check (merchant is null or (char_length(merchant) between 1 and 80 and merchant !~ '[\n\r\t]')),
  artifact_path text not null unique,
  artifact_sha256 text not null check (artifact_sha256 ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now(),
  unique (trip_id, client_request_id),
  foreign key (trip_id, uploaded_by) references public.trip_members (trip_id, user_id)
);
create index expenses_trip_uploaded_by_idx on public.expenses (trip_id, uploaded_by);

alter table public.expenses enable row level security;
revoke all on public.expenses from public, anon, authenticated;
grant select on public.expenses to authenticated;
create policy expenses_member_read on public.expenses for select to authenticated
  using ((select private.is_member(trip_id)));

-- ---------------------------------------------------------------- storage (private bucket)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('receipts', 'receipts', false, 2 * 1024 * 1024, array['image/png'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create function private.storage_trip(p_name text) returns uuid
language plpgsql immutable set search_path = '' as $$
begin
  return split_part(p_name, '/', 1)::uuid;
exception when others then return null;
end $$;

-- 구성원이 자기 폴더에만, 정해진 이름 형식으로만 올린다.
create function private.can_upload_receipt(p_name text) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_name ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9a-f-]{36}\.png$'
     and split_part(p_name, '/', 2) = (select auth.uid())::text
     and exists (select 1 from public.trip_members m
                 where m.trip_id = private.storage_trip(p_name) and m.user_id = (select auth.uid()))
$$;

-- 덮어쓰기(update)·삭제 정책은 두지 않는다.
create policy receipts_member_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'receipts' and (select private.can_upload_receipt(name)));
create policy receipts_member_read on storage.objects for select to authenticated
  using (bucket_id = 'receipts' and (select private.is_member(private.storage_trip(name))));

-- ---------------------------------------------------------------- RPC
create function private.submit_receipt_expense(
  p_trip uuid, p_request_id uuid, p_expense_date date, p_amount_minor bigint, p_currency text,
  p_merchant text, p_artifact_sha256 text
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_uid(); v_path text; v_fp text; v_old public.expenses; v_obj record; v_id uuid;
begin
  if not exists (select 1 from public.trip_members m where m.trip_id = p_trip and m.user_id = v_uid) then
    perform private.fail('trip_not_found', 'PT404');
  end if;
  perform 1 from public.trips where id = p_trip for update;
  v_path := p_trip::text || '/' || v_uid::text || '/' || p_request_id::text || '.png';
  v_fp := encode(sha256(convert_to(concat_ws('|', p_expense_date, p_amount_minor, p_currency,
            coalesce(p_merchant, '-'), p_artifact_sha256), 'UTF8')), 'hex');
  select * into v_old from public.expenses where trip_id = p_trip and client_request_id = p_request_id;
  if found then
    if v_old.request_fingerprint <> v_fp then perform private.fail('idempotency_conflict', 'PT409'); end if;
    return jsonb_build_object('expense_id', v_old.id, 'replayed', true);
  end if;
  if p_amount_minor is null or p_amount_minor <= 0 or p_expense_date is null or p_currency !~ '^[A-Z]{3}$'
     or p_artifact_sha256 !~ '^[0-9a-f]{64}$' then
    perform private.fail('invalid_fields', 'PT400');
  end if;
  select o.owner_id, o.metadata into v_obj from storage.objects o where o.bucket_id = 'receipts' and o.name = v_path;
  if not found or v_obj.owner_id is distinct from v_uid::text or v_obj.metadata ->> 'mimetype' is distinct from 'image/png' then
    perform private.fail('artifact_missing', 'PT409');
  end if;
  insert into public.expenses (trip_id, client_request_id, request_fingerprint, uploaded_by, expense_date,
      amount_minor, currency, merchant, artifact_path, artifact_sha256)
    values (p_trip, p_request_id, v_fp, v_uid, p_expense_date, p_amount_minor, p_currency, p_merchant, v_path, p_artifact_sha256)
    returning id into v_id;
  return jsonb_build_object('expense_id', v_id, 'replayed', false);
end $$;

create function public.submit_receipt_expense(
  p_trip uuid, p_request_id uuid, p_expense_date date, p_amount_minor bigint, p_currency text,
  p_merchant text, p_artifact_sha256 text
) returns jsonb
language sql security invoker set search_path = '' as $$
  select private.submit_receipt_expense(p_trip, p_request_id, p_expense_date, p_amount_minor, p_currency,
    p_merchant, p_artifact_sha256)
$$;

revoke all on function private.storage_trip(text), private.can_upload_receipt(text),
  private.submit_receipt_expense(uuid, uuid, date, bigint, text, text, text),
  public.submit_receipt_expense(uuid, uuid, date, bigint, text, text, text) from public, anon, authenticated;
grant execute on function private.storage_trip(text), private.can_upload_receipt(text),
  private.submit_receipt_expense(uuid, uuid, date, bigint, text, text, text),
  public.submit_receipt_expense(uuid, uuid, date, bigint, text, text, text) to authenticated;
