# Neon 同步与 env 打包

同步已从 Supabase REST 改为 **Neon Postgres 直连**（国内通常不需要代理；可能比本地库慢一点）。

## 步骤

1. 在 [neon.tech](https://neon.tech) 新建项目（区域建议新加坡 / 香港附近）
2. 复制 Connection string 到 `supabase/env.local` 的 `DATABASE_URL`
3. 建表：
   ```powershell
   python supabase/apply_schema.py
   ```
4. 确认 `SYNC_OWNER_ID`、`SYNC_ENABLED=true`，以及 LLM/ASR Key
5. 打包：
   ```powershell
   .\build_apk.ps1 -Install
   ```

## 说明

- App 用 Postgres 协议同步，不再访问 `*.supabase.co` HTTPS
- `DATABASE_URL` 会打进安装包（仅适合自用）；勿公开分发 APK
- 多端请使用同一个 `SYNC_OWNER_ID`
- 延迟：Neon 冷启动或跨国链路可能有 1–3 秒，属正常

## 同步范围

`properties` / `rooms`（含 `video_url`）/ `tenants` / `leases` / `lease_extras` / `rent_periods` / `meter_readings` / `period_adjustments` / `invoices` / `payments`

## 房间视频（七牛优先，R2 备用 + Vercel）

1. **优先**七牛：建公开空间 + 绑定 CDN 域名 → 填 `QINIU_ACCESS_KEY` / `QINIU_SECRET_KEY` / `QINIU_BUCKET` / `QINIU_PUBLIC_BASE`（按区域设 `QINIU_UPLOAD_HOST`）
2. **备用** Cloudflare R2：建桶并开启公共访问 → 填 `R2_*` / `R2_PUBLIC_BASE`（七牛失败时自动改用）
3. 部署 `share-web/` 到 EdgeOne Makers（见 `share-web/README.md`）→ 填 `SHARE_WEB_BASE`；分享站媒体前缀与上传端一致（七牛用 `NEXT_PUBLIC_QINIU_PUBLIC_BASE`）
4. Neon 执行 `python supabase/apply_schema.py`（会加 `rooms.video_url` 列）
5. `.\build_apk.ps1 -Install`

App 内：房间列表/详情右侧缩略图 → 竖屏播放页 → **本机处理后再上传**（已是 H.264/MP4 则跳过转码，否则 LowQuality 硬编）；优先七牛，失败用 R2。云端转码暂关。播放会落本地缓存。
