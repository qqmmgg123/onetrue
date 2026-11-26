-- 备忘置顶 / 办结（幂等）。Apply after schema.sql.

alter table public.notes
  add column if not exists pinned_at timestamptz;

alter table public.notes
  add column if not exists completed_at timestamptz;

create index if not exists idx_notes_owner_memo_pin
  on public.notes(owner_id, pinned_at desc nulls last)
  where deleted_at is null and kind = 'memo';

create index if not exists idx_notes_owner_memo_done
  on public.notes(owner_id, completed_at asc nulls last)
  where deleted_at is null and kind = 'memo';
