-- Rent Agent mirror schema for Neon (Postgres).
-- Apply: python supabase/apply_schema.py  (reads DATABASE_URL from env.local)

create extension if not exists "pgcrypto";

-- App 账号（一期：手机号+密码；正式版应改为后端 Auth API）
create table if not exists public.app_users (
  id uuid primary key default gen_random_uuid(),
  phone text not null unique,
  password_hash text not null,
  display_name text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists public.properties (
  id uuid primary key,
  name text not null,
  address text not null default '',
  city text not null default '',
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  owner_id uuid not null
);

create table if not exists public.rooms (
  id uuid primary key,
  property_id uuid not null references public.properties(id),
  label text not null,
  video_url text not null default '',
  video_poster_url text not null default '',
  listing_status text not null default 'draft',
  listed_at timestamptz,
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  owner_id uuid not null
);

alter table public.properties add column if not exists city text not null default '';
alter table public.rooms add column if not exists video_url text not null default '';
alter table public.rooms add column if not exists video_poster_url text not null default '';
alter table public.rooms add column if not exists listing_status text not null default 'draft';
alter table public.rooms add column if not exists listed_at timestamptz;

create table if not exists public.tenants (
  id uuid primary key,
  name text not null,
  phone text not null default '',
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  owner_id uuid not null
);

create table if not exists public.leases (
  id uuid primary key,
  room_id uuid not null references public.rooms(id),
  tenant_id uuid not null references public.tenants(id),
  start_date date not null,
  end_date date,
  rent_due_day int not null,
  base_rent numeric not null,
  deposit numeric not null default 0,
  status text not null default 'active',
  electric_price numeric not null default 0,
  water_price numeric not null default 0,
  gas_price numeric not null default 0,
  fixed_extra numeric not null default 0,
  fixed_extra_label text not null default '固定杂费',
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  owner_id uuid not null
);

create table if not exists public.lease_extras (
  id uuid primary key,
  lease_id uuid not null references public.leases(id) on delete cascade,
  name text not null,
  amount numeric not null,
  sort_order int not null default 0,
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  owner_id uuid not null
);

create table if not exists public.rent_periods (
  id uuid primary key,
  lease_id uuid not null references public.leases(id) on delete cascade,
  period_start date not null,
  period_end date not null,
  due_date date not null,
  amount numeric not null,
  status text not null default 'pending',
  remark text not null default '',
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  owner_id uuid not null,
  unique (lease_id, period_start)
);

alter table public.rent_periods add column if not exists remark text not null default '';

create table if not exists public.meter_readings (
  id uuid primary key,
  lease_id uuid not null references public.leases(id) on delete cascade,
  kind text not null,
  reading numeric not null,
  recorded_at timestamptz not null,
  period_id uuid references public.rent_periods(id) on delete set null,
  note text not null default '',
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  owner_id uuid not null
);

-- type: 'discount' = 本月优惠；'fee:名称' = 本月一次性额外费用（可多项）
create table if not exists public.period_adjustments (
  id uuid primary key,
  period_id uuid not null references public.rent_periods(id) on delete cascade,
  type text not null default 'discount',
  amount numeric not null,
  note text not null default '',
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  owner_id uuid not null,
  unique (period_id, type)
);

create table if not exists public.invoices (
  id uuid primary key,
  period_id uuid not null references public.rent_periods(id) on delete cascade,
  total numeric not null,
  lines_json text not null,
  issued_at timestamptz not null,
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  owner_id uuid not null
);

create table if not exists public.payments (
  id uuid primary key,
  period_id uuid not null references public.rent_periods(id) on delete cascade,
  amount numeric not null,
  paid_at timestamptz not null,
  note text not null default '',
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  owner_id uuid not null
);

create index if not exists idx_app_users_phone on public.app_users(phone);
create index if not exists idx_properties_owner on public.properties(owner_id);
create index if not exists idx_rooms_owner on public.rooms(owner_id);
create index if not exists idx_rooms_listed on public.rooms(listing_status, listed_at desc)
  where listing_status = 'listed' and deleted_at is null;
create index if not exists idx_properties_city on public.properties(city)
  where deleted_at is null;
create index if not exists idx_leases_owner on public.leases(owner_id);
create index if not exists idx_periods_owner on public.rent_periods(owner_id);
create index if not exists idx_properties_updated on public.properties(owner_id, updated_at);
create index if not exists idx_rooms_updated on public.rooms(owner_id, updated_at);
create index if not exists idx_tenants_updated on public.tenants(owner_id, updated_at);
create index if not exists idx_leases_updated on public.leases(owner_id, updated_at);
create index if not exists idx_lease_extras_updated on public.lease_extras(owner_id, updated_at);
create index if not exists idx_periods_updated on public.rent_periods(owner_id, updated_at);
create index if not exists idx_meters_updated on public.meter_readings(owner_id, updated_at);
create index if not exists idx_adjustments_updated on public.period_adjustments(owner_id, updated_at);
create index if not exists idx_invoices_updated on public.invoices(owner_id, updated_at);
create index if not exists idx_payments_updated on public.payments(owner_id, updated_at);

-- 在 Neon 控制台改数据时自动刷新 updated_at，否则 App 增量同步拉不到
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

do $$
declare
  t text;
begin
  foreach t in array array[
    'properties','rooms','tenants','leases','lease_extras',
    'rent_periods','meter_readings','period_adjustments','invoices','payments'
  ]
  loop
    execute format(
      'drop trigger if exists trg_%s_touch on public.%s; '
      'create trigger trg_%s_touch before update on public.%s '
      'for each row execute function public.touch_updated_at();',
      t, t, t, t
    );
  end loop;
end;
$$;
