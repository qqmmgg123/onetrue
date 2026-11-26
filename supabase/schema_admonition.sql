-- 谏言（admonition）+ 管理员角色。在 schema_social.sql 之后执行。

alter table public.profiles
  add column if not exists is_admin boolean not null default false;

-- 公开可读已推荐谏言
drop policy if exists notes_listed_admonitions_read on public.notes;
create policy notes_listed_admonitions_read on public.notes
  for select
  to anon, authenticated
  using (
    deleted_at is null
    and listing_status = 'listed'
    and kind = 'admonition'
  );

create index if not exists idx_notes_admonitions
  on public.notes(listed_at desc)
  where listing_status = 'listed' and deleted_at is null and kind = 'admonition';

-- 手动设管理员示例（把 uuid 换成你的 auth.users.id）：
-- update public.profiles set is_admin = true where id = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx';
