-- 允许通知发起人 SELECT 自己发出的行（避免 INSERT…RETURNING 被 RLS 挡回）
drop policy if exists social_notif_actor_select on public.social_notifications;
create policy social_notif_actor_select on public.social_notifications
  for select to authenticated
  using (user_id = auth.uid() or actor_id = auth.uid());
