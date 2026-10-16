-- Rent Agent mirror schema for Supabase (Postgres).
-- Run in Supabase SQL Editor. Then paste Project URL + anon key into App settings.
-- WARNING: open RLS below is for personal/dev only. Add Auth + per-user policies before sharing.

create extension if not exists "pgcrypto";

create table if not exists public.properties (
  id uuid primary key,
  name text not null,
  address text not null default '',
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  owner_id uuid not null
);

create table if not exists public.rooms (
  id uuid primary key,
  property_id uuid not null references public.properties(id),
  label text not null,
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  owner_id uuid not null
);

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
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  owner_id uuid not null,
  unique (lease_id, period_start)
);

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

create index if not exists idx_properties_owner on public.properties(owner_id);
create index if not exists idx_rooms_owner on public.rooms(owner_id);
create index if not exists idx_leases_owner on public.leases(owner_id);
create index if not exists idx_periods_owner on public.rent_periods(owner_id);

-- Dev-only open policies (tighten with auth.uid() before multi-user).
alter table public.properties enable row level security;
alter table public.rooms enable row level security;
alter table public.tenants enable row level security;
alter table public.leases enable row level security;
alter table public.lease_extras enable row level security;
alter table public.rent_periods enable row level security;
alter table public.meter_readings enable row level security;
alter table public.period_adjustments enable row level security;
alter table public.invoices enable row level security;
alter table public.payments enable row level security;

-- Personal/dev: anon can read/write. App still scopes rows by owner_id.
-- Before sharing the project, replace with auth.uid() = owner_id policies.
do $$
declare t text;
begin
  foreach t in array array[
    'properties','rooms','tenants','leases','lease_extras',
    'rent_periods','meter_readings','period_adjustments','invoices','payments'
  ]
  loop
    execute format('drop policy if exists "dev_anon_all" on public.%I', t);
    execute format(
      'create policy "dev_anon_all" on public.%I for all to anon using (true) with check (true)',
      t
    );
  end loop;
end $$;
