-- 여행방 초대 수락. 앱의 로컬 debug 모드가 실제 Auth 세션으로 부르는 서버 쪽이다.
-- local-collaboration 실험 스키마에서 여행방·구성원·초대 부분만 옮겼다(지출·정산·Storage는 다음 슬라이스).
--
-- 원칙
-- * 앱(authenticated)은 테이블을 SELECT만 한다. 쓰기는 accept_invite RPC로만 한다.
-- * 특권 함수(SECURITY DEFINER)는 Data API에 노출되지 않는 private 스키마에 두고 auth.uid()를 직접 검사한다.
--   public에는 SECURITY INVOKER 래퍼만 둔다. search_path는 비우고 모든 이름을 스키마로 한정한다.
-- * 실패는 고정된 코드로만 알린다. PostgREST 응답 본문의 message가 아래 코드 중 하나이고, HTTP 상태는 PTxxx로 정한다.
--   not_authenticated(401), invite_invalid(404), invite_revoked(410), invite_used(410), invite_expired(410).
--   앱은 이 코드와 정확히 일치할 때만 기능별 실패로 옮기고, 나머지는 알 수 없는 실패로 다룬다.

create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

-- ---------------------------------------------------------------- tables
create table public.trips (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 80),
  host_id uuid not null references auth.users (id),
  created_at timestamptz not null default now()
);

create table public.trip_members (
  trip_id uuid not null references public.trips (id),
  user_id uuid not null references auth.users (id),
  role text not null check (role in ('host', 'member')),
  display_name text not null check (char_length(display_name) between 1 and 40),
  joined_at timestamptz not null default now(),
  primary key (trip_id, user_id)
);

-- 초대 원문은 저장하지 않는다. 링크를 가진 사람만 원문을 안다.
create table public.trip_invites (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.trips (id),
  token_hash bytea not null unique,
  created_by uuid not null references auth.users (id),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  used_by uuid references auth.users (id),
  used_at timestamptz
);

create index trips_host_id_idx on public.trips (host_id);
create index trip_members_user_id_idx on public.trip_members (user_id);
create index trip_invites_trip_id_idx on public.trip_invites (trip_id);
create index trip_invites_created_by_idx on public.trip_invites (created_by);
create index trip_invites_used_by_idx on public.trip_invites (used_by);

alter table public.trips enable row level security;
alter table public.trip_members enable row level security;
alter table public.trip_invites enable row level security;

revoke all on public.trips, public.trip_members, public.trip_invites from public, anon, authenticated;
grant select on public.trips, public.trip_members to authenticated;
-- trip_invites: 앱 역할에 어떤 권한도 주지 않는다(토큰 해시조차 읽을 수 없음).

create function private.is_member(p_trip uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.trip_members m
    where m.trip_id = p_trip and m.user_id = (select auth.uid())
  )
$$;

create policy trips_member_read on public.trips for select to authenticated
  using ((select private.is_member(id)));
create policy members_member_read on public.trip_members for select to authenticated
  using ((select private.is_member(trip_id)));

-- ---------------------------------------------------------------- helpers
create function private.fail(p_code text, p_http text) returns void
language plpgsql set search_path = '' as $$
begin
  raise exception using errcode = p_http, message = p_code;
end $$;

create function private.require_uid() returns uuid
language plpgsql stable set search_path = '' as $$
declare v uuid := (select auth.uid());
begin
  if v is null then perform private.fail('not_authenticated', 'PT401'); end if;
  return v;
end $$;

create function private.token_hash(p_token text) returns bytea
language sql immutable set search_path = '' as $$
  select sha256(convert_to(coalesce(p_token, ''), 'UTF8'))
$$;

-- 초대 상태 판정. 위조·오타 토큰은 invite_invalid로 존재 여부를 드러내지 않는다.
create function private.check_invite(v_inv public.trip_invites, p_uid uuid) returns void
language plpgsql set search_path = '' as $$
begin
  if v_inv.id is null then perform private.fail('invite_invalid', 'PT404'); end if;
  if v_inv.revoked_at is not null then perform private.fail('invite_revoked', 'PT410'); end if;
  if v_inv.used_by is not null and v_inv.used_by <> p_uid then perform private.fail('invite_used', 'PT410'); end if;
  if v_inv.used_by is null and v_inv.expires_at <= now() then perform private.fail('invite_expired', 'PT410'); end if;
end $$;

-- ---------------------------------------------------------------- RPC
-- 같은 계정이 같은 초대를 다시 수락하면 새로 소비하지 않고 같은 여행방을 돌려준다(replayed).
create function private.accept_invite(p_token text, p_display_name text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.require_uid(); v_inv public.trip_invites; v_trip public.trips; v_replayed boolean;
begin
  select * into v_inv from public.trip_invites where token_hash = private.token_hash(p_token);
  perform private.check_invite(v_inv, v_uid);
  select * into v_trip from public.trips where id = v_inv.trip_id for update;
  select * into v_inv from public.trip_invites where id = v_inv.id for update;
  perform private.check_invite(v_inv, v_uid);
  v_replayed := exists (select 1 from public.trip_members where trip_id = v_trip.id and user_id = v_uid);
  if not v_replayed then
    insert into public.trip_members (trip_id, user_id, role, display_name)
      values (v_trip.id, v_uid, 'member', p_display_name);
    update public.trip_invites set used_by = v_uid, used_at = now() where id = v_inv.id;
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

create function public.accept_invite(p_token text, p_display_name text) returns jsonb
language sql security invoker set search_path = '' as $$ select private.accept_invite(p_token, p_display_name) $$;

-- 실행 권한: 모든 함수에서 PUBLIC/anon/authenticated를 뺀 뒤, 앱이 부르는 경로에만 authenticated를 준다.
-- private 스키마는 Data API에 노출되지 않으므로 private.* 은 /rest/v1/rpc 로 직접 부를 수 없다.
revoke all on function private.is_member(uuid), private.fail(text, text), private.require_uid(),
  private.token_hash(text), private.check_invite(public.trip_invites, uuid),
  private.accept_invite(text, text), public.accept_invite(text, text) from public, anon, authenticated;
grant execute on function private.is_member(uuid), private.accept_invite(text, text),
  public.accept_invite(text, text) to authenticated;
