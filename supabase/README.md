# Supabase 同步（本地优先）

## 步骤

1. 在 [supabase.com](https://supabase.com) 新建项目  
2. SQL Editor 执行本目录 `schema.sql`  
3. Project Settings → API：复制 **Project URL** 与 **anon public** key  
4. App「对话设置」→ 开启静默同步，粘贴 URL / anon key  
5. 多端共享：把同一台手机的 `owner_id` 复制到其它设备  

## 当前同步范围

- 已实现：`properties` / `rooms` / `tenants` / `leases` / `lease_extras`  
- 本地仍为主库；打开 App 后台推拉；菜单「立即同步」可手动触发  
- 账期 / 抄表 / 发票：表结构已预留，下一迭代接入  

## 安全说明

`schema.sql` 里 anon 策略偏开放，仅适合个人试用。上线前请改为 `auth.uid() = owner_id`。
