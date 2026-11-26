-- 文章封面：notes.cover_url
-- Apply after schema.sql（或 python supabase/apply_schema.py）

alter table public.notes
  add column if not exists cover_url text not null default '';
