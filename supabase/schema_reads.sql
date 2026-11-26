-- 登录用户「近期阅读」云端（游客永不写此表）。Apply after schema.sql.

create table if not exists public.user_article_reads (
  user_id uuid not null references auth.users(id) on delete cascade,
  note_id uuid not null references public.notes(id) on delete cascade,
  title text not null default '',
  body text not null default '',
  format text not null default 'plain',
  city text not null default '',
  cover_url text not null default '',
  owner_id uuid,
  last_read_at timestamptz not null default now(),
  primary key (user_id, note_id)
);

-- 已有库补列（幂等）
alter table public.user_article_reads
  add column if not exists cover_url text not null default '';

create index if not exists idx_user_article_reads_user_time
  on public.user_article_reads(user_id, last_read_at desc);

alter table public.user_article_reads enable row level security;

drop policy if exists user_article_reads_owner_all on public.user_article_reads;
create policy user_article_reads_owner_all on public.user_article_reads
  for all
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());
