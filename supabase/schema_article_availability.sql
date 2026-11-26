-- 阅读点开校验：区分「已删除」与「已改类型/下架」。
-- Apply in Supabase SQL editor after schema.sql.

create or replace function public.article_availability(p_id uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
    when n.id is null then 'missing'
    when n.deleted_at is not null then 'deleted'
    when n.kind = 'article' then 'ok'
    else 'delisted'
  end
  from (select p_id as id) q
  left join public.notes n on n.id = q.id;
$$;

revoke all on function public.article_availability(uuid) from public;
grant execute on function public.article_availability(uuid) to anon, authenticated;
