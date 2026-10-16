# Supabase 同步（本地优先）

## 步骤

1. 在 [supabase.com](https://supabase.com) 新建项目  
2. 把连接信息填进 `supabase/env.local`（可参考 `env.example`）  
   - **SUPABASE_URL**、**SUPABASE_ANON_KEY**：Settings → API  
   - **SUPABASE_DB_PASSWORD**：建项目时的数据库密码；或直接填 **DATABASE_URL**（Database → Connection string → URI）  
3. 告诉我「填好了」，由脚本执行 `schema.sql`（也可本地：`python supabase/apply_schema.py`）  
4. App「对话设置」→ 开启静默同步，粘贴 URL / anon key  
5. 多端共享：把同一台手机的 `owner_id` 复制到其它设备  

## 当前同步范围

- 已实现：`properties` / `rooms` / `tenants` / `leases` / `lease_extras` / `rent_periods` / `meter_readings` / `period_adjustments` / `invoices` / `payments`  
- 本地仍为主库；打开 App 后台推拉；菜单「立即同步」可手动触发  
- 删除走软删（`deleted_at`），多端按 `updated_at` LWW 合并  

## 安全说明

`schema.sql` 里 anon 策略偏开放，仅适合个人试用。上线前请改为 `auth.uid() = owner_id`。
