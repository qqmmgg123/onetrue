-- Notes-only schema for Supabase (Singapore).
-- Apply with project DB URL (migrate machine only — never bake into the App).
-- Requires: Authentication enabled; tables use auth.users via owner_id.

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------------
-- notes
-- ---------------------------------------------------------------------------
create table if not exists public.notes (
  id uuid primary key,
  kind text not null default 'note',
  title text not null default '',
  body text not null default '',
  format text not null default 'plain',
  schedule_at timestamptz,
  remind_at timestamptz,
  recur_freq text not null default '',
  recur_interval int not null default 1,
  recur_byday text,
  recur_until timestamptz,
  recur_count int,
  remind_offset_min int not null default 0,
  listing_status text not null default 'draft',
  listed_at timestamptz,
  city text not null default '',
  cover_url text not null default '',
  parent_uuid uuid,
  sort_order int not null default 0,
  pinned_at timestamptz,
  completed_at timestamptz,
  source_note_uuids jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  owner_id uuid not null references auth.users(id) on delete cascade
);

create table if not exists public.note_stats (
  note_id uuid primary key references public.notes(id) on delete cascade,
  view_count bigint not null default 0
);

create index if not exists idx_notes_owner on public.notes(owner_id);
create index if not exists idx_notes_updated on public.notes(owner_id, updated_at);
create index if not exists idx_notes_listed on public.notes(listing_status, listed_at desc)
  where listing_status = 'listed' and deleted_at is null and kind = 'article';
create index if not exists idx_notes_city on public.notes(city)
  where deleted_at is null and listing_status = 'listed';

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_notes_touch on public.notes;
create trigger trg_notes_touch
  before update on public.notes
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------------
-- RLS (required: anon key is public in the client)
-- ---------------------------------------------------------------------------
alter table public.notes enable row level security;
alter table public.note_stats enable row level security;

-- Owner full access to own notes
drop policy if exists notes_owner_all on public.notes;
create policy notes_owner_all on public.notes
  for all
  to authenticated
  using (owner_id = auth.uid())
  with check (owner_id = auth.uid());

-- Public read of listed articles (marketplace) for anon + authenticated
drop policy if exists notes_listed_articles_read on public.notes;
create policy notes_listed_articles_read on public.notes
  for select
  to anon, authenticated
  using (
    deleted_at is null
    and listing_status = 'listed'
    and kind = 'article'
  );

-- note_stats: owners manage; anyone can read stats for listed articles
drop policy if exists note_stats_owner_all on public.note_stats;
create policy note_stats_owner_all on public.note_stats
  for all
  to authenticated
  using (
    exists (
      select 1 from public.notes n
      where n.id = note_id and n.owner_id = auth.uid()
    )
  )
  with check (
    exists (
      select 1 from public.notes n
      where n.id = note_id and n.owner_id = auth.uid()
    )
  );

drop policy if exists note_stats_listed_read on public.note_stats;
create policy note_stats_listed_read on public.note_stats
  for select
  to anon, authenticated
  using (
    exists (
      select 1 from public.notes n
      where n.id = note_id
        and n.deleted_at is null
        and n.listing_status = 'listed'
        and n.kind = 'article'
    )
  );

-- Allow incrementing view_count for listed articles (authenticated + anon)
drop policy if exists note_stats_listed_update on public.note_stats;
create policy note_stats_listed_update on public.note_stats
  for update
  to anon, authenticated
  using (
    exists (
      select 1 from public.notes n
      where n.id = note_id
        and n.deleted_at is null
        and n.listing_status = 'listed'
        and n.kind = 'article'
    )
  )
  with check (
    exists (
      select 1 from public.notes n
      where n.id = note_id
        and n.deleted_at is null
        and n.listing_status = 'listed'
        and n.kind = 'article'
    )
  );

drop policy if exists note_stats_listed_insert on public.note_stats;
create policy note_stats_listed_insert on public.note_stats
  for insert
  to anon, authenticated
  with check (
    exists (
      select 1 from public.notes n
      where n.id = note_id
        and n.deleted_at is null
        and n.listing_status = 'listed'
        and n.kind = 'article'
    )
  );
