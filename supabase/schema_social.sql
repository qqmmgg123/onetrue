-- Social layer (profiles / follows / recommends / comments / notifications).
-- Apply after schema.sql: python -c "..." or append via apply_schema.

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  nickname text not null default '',
  avatar_url text not null default '',
  updated_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

drop policy if exists profiles_public_read on public.profiles;
create policy profiles_public_read on public.profiles
  for select to anon, authenticated
  using (true);

drop policy if exists profiles_owner_upsert on public.profiles;
create policy profiles_owner_upsert on public.profiles
  for all to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- ---------------------------------------------------------------------------
-- follows
-- ---------------------------------------------------------------------------
create table if not exists public.follows (
  follower_id uuid not null references auth.users(id) on delete cascade,
  following_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower_id, following_id),
  constraint follows_no_self check (follower_id <> following_id)
);

create index if not exists idx_follows_following on public.follows(following_id, created_at desc);
create index if not exists idx_follows_follower on public.follows(follower_id, created_at desc);

alter table public.follows enable row level security;

drop policy if exists follows_read on public.follows;
create policy follows_read on public.follows
  for select to anon, authenticated
  using (true);

drop policy if exists follows_owner_write on public.follows;
create policy follows_owner_write on public.follows
  for all to authenticated
  using (follower_id = auth.uid())
  with check (follower_id = auth.uid());

-- ---------------------------------------------------------------------------
-- note_stats: recommend / comment counters
-- ---------------------------------------------------------------------------
alter table public.note_stats
  add column if not exists recommend_count bigint not null default 0;
alter table public.note_stats
  add column if not exists comment_count bigint not null default 0;

-- ---------------------------------------------------------------------------
-- article_recommends（红心推荐，一人一文一票）
-- ---------------------------------------------------------------------------
create table if not exists public.article_recommends (
  note_id uuid not null references public.notes(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (note_id, user_id)
);

create index if not exists idx_recommends_note on public.article_recommends(note_id);

alter table public.article_recommends enable row level security;

drop policy if exists recommends_read on public.article_recommends;
create policy recommends_read on public.article_recommends
  for select to anon, authenticated
  using (true);

drop policy if exists recommends_owner_write on public.article_recommends;
create policy recommends_owner_write on public.article_recommends
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- article_favorites（收藏，仅本人可见列表）
-- ---------------------------------------------------------------------------
create table if not exists public.article_favorites (
  note_id uuid not null references public.notes(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (note_id, user_id)
);

create index if not exists idx_favorites_user
  on public.article_favorites(user_id, created_at desc);

alter table public.article_favorites enable row level security;

drop policy if exists favorites_owner_all on public.article_favorites;
create policy favorites_owner_all on public.article_favorites
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- article_comments
-- ---------------------------------------------------------------------------
create table if not exists public.article_comments (
  id uuid primary key default gen_random_uuid(),
  note_id uuid not null references public.notes(id) on delete cascade,
  author_id uuid not null references auth.users(id) on delete cascade,
  parent_id uuid references public.article_comments(id) on delete cascade,
  reply_to_user_id uuid references auth.users(id) on delete set null,
  body text not null,
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);

create index if not exists idx_comments_note on public.article_comments(note_id, created_at);
create index if not exists idx_comments_parent on public.article_comments(parent_id);

alter table public.article_comments enable row level security;

drop policy if exists comments_public_read on public.article_comments;
create policy comments_public_read on public.article_comments
  for select to anon, authenticated
  using (
    deleted_at is null
    and exists (
      select 1 from public.notes n
      where n.id = note_id
        and n.deleted_at is null
        and n.listing_status = 'listed'
        and n.kind = 'article'
    )
  );

drop policy if exists comments_owner_insert on public.article_comments;
create policy comments_owner_insert on public.article_comments
  for insert to authenticated
  with check (
    author_id = auth.uid()
    and exists (
      select 1 from public.notes n
      where n.id = note_id
        and n.deleted_at is null
        and n.listing_status = 'listed'
        and n.kind = 'article'
    )
  );

drop policy if exists comments_owner_update on public.article_comments;
create policy comments_owner_update on public.article_comments
  for update to authenticated
  using (author_id = auth.uid())
  with check (author_id = auth.uid());

-- ---------------------------------------------------------------------------
-- social_notifications（评论 / 回复 / 推荐 / 关注）
-- ---------------------------------------------------------------------------
create table if not exists public.social_notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  actor_id uuid not null references auth.users(id) on delete cascade,
  kind text not null,
  note_id uuid references public.notes(id) on delete cascade,
  comment_id uuid references public.article_comments(id) on delete set null,
  body text not null default '',
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists idx_social_notif_user
  on public.social_notifications(user_id, created_at desc);

alter table public.social_notifications enable row level security;

drop policy if exists social_notif_owner_read on public.social_notifications;
create policy social_notif_owner_read on public.social_notifications
  for select to authenticated
  using (user_id = auth.uid());

drop policy if exists social_notif_owner_update on public.social_notifications;
create policy social_notif_owner_update on public.social_notifications
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists social_notif_owner_delete on public.social_notifications;
create policy social_notif_owner_delete on public.social_notifications
  for delete to authenticated
  using (user_id = auth.uid());

-- inserts come from authenticated clients acting as actor; recipient must be target
drop policy if exists social_notif_actor_insert on public.social_notifications;
create policy social_notif_actor_insert on public.social_notifications
  for insert to authenticated
  with check (actor_id = auth.uid());

-- 允许发起人读自己发出的行（INSERT…RETURNING）
drop policy if exists social_notif_actor_select on public.social_notifications;
create policy social_notif_actor_select on public.social_notifications
  for select to authenticated
  using (user_id = auth.uid() or actor_id = auth.uid());
