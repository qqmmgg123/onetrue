-- User feedback (联系与反馈). Apply after schema.sql / schema_social.sql.

create table if not exists public.feedback (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  body text not null,
  contact text not null default '',
  created_at timestamptz not null default now()
);

create index if not exists idx_feedback_user_created
  on public.feedback(user_id, created_at desc);

alter table public.feedback enable row level security;

drop policy if exists feedback_owner_all on public.feedback;
create policy feedback_owner_all on public.feedback
  for all
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());
