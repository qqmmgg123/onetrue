-- 阅读：所有未删除的文章类型公开可读（不再依赖 listing_status=listed）。
-- Apply after schema.sql / schema_social.sql.

drop policy if exists notes_listed_articles_read on public.notes;
create policy notes_listed_articles_read on public.notes
  for select
  to anon, authenticated
  using (
    deleted_at is null
    and kind = 'article'
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
        and n.kind = 'article'
    )
  );

drop policy if exists note_stats_listed_update on public.note_stats;
create policy note_stats_listed_update on public.note_stats
  for update
  to anon, authenticated
  using (
    exists (
      select 1 from public.notes n
      where n.id = note_id
        and n.deleted_at is null
        and n.kind = 'article'
    )
  )
  with check (
    exists (
      select 1 from public.notes n
      where n.id = note_id
        and n.deleted_at is null
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
        and n.kind = 'article'
    )
  );

-- 留言：挂在任意未删除文章上即可
drop policy if exists comments_public_read on public.article_comments;
create policy comments_public_read on public.article_comments
  for select to anon, authenticated
  using (
    deleted_at is null
    and exists (
      select 1 from public.notes n
      where n.id = note_id
        and n.deleted_at is null
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
        and n.kind = 'article'
    )
  );
