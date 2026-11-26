-- 收件人可移除（删除）自己的互动提醒
drop policy if exists social_notif_owner_delete on public.social_notifications;
create policy social_notif_owner_delete on public.social_notifications
  for delete to authenticated
  using (user_id = auth.uid());
