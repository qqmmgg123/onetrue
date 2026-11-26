# 国内可达的注册验证（邮箱 / 短信）

Web / App 注册流程：**邮箱 + 密码 → 邮箱验证码确认 → 登录态**。  
短信接口已在网关预留（`/api/auth/resend-otp` 手机号、`verify-otp` type=sms），需你自备国内短信通道。

## 一、邮箱（推荐先做，国内可达）

Supabase 默认发信对国内邮箱（QQ / 163 等）经常进垃圾箱或被拒。请改用**国内 SMTP**：

### 1. 开通服务（二选一）

| 服务 | 控制台 | 说明 |
|------|--------|------|
| 阿里云邮件推送 | DirectMail | 需备案域名发信地址 |
| 腾讯云 SES | 邮件推送 | 同样需验证发信域名 |

准备好：SMTP 主机、端口（465/587）、用户名、密码/授权码、发信地址（如 `noreply@你的域名.com`）。

### 2. 写入 Supabase

Dashboard → **Authentication → Emails → SMTP Settings**（或 Project Settings → Auth）：

- 打开 Custom SMTP  
- 填入上述主机 / 端口 / 账号 / 密码  
- Sender email / name 用你已验证的发信地址  

### 3. Auth 开关

Dashboard → **Authentication → Providers → Email**：

- Enable Email：开  
- **Confirm email**：开（注册后走验证码）  
- 建议开启 **Email OTP**；若只用 Magic Link，App/Web 验证码页不适用  
- **Email OTP length**：可设为 **6～10**。当前若是 8 位，在同一页改成 **6** 即可（App/Web 已不写死位数，改完立刻生效，无需发版）。  
- **Email OTP expiration**：默认约 **3600 秒（1 小时）**。路径多为 Authentication → Providers → Email（或 Sign In / Providers → Email）。改短了就会感觉「很快过期」；过长（>1 天）不推荐。此值同时影响 Magic Link / 确认信 / 重置密码链接有效期。

Templates → **Confirm sign up**：确认模板里带 `{{ .Token }}`（OTP），不要只用链接。

Templates → **Reset password**（忘记密码）：同样改成验证码，例如：

```html
<h2>重置密码</h2>
<p>你的验证码是：</p>
<p style="font-size:24px;font-weight:bold;">{{ .Token }}</p>
<p>如非本人操作，请忽略本邮件。</p>
```

Subject 建议：`【醍醐】重置密码验证码`

### 4. 自测

1. Web「注册」或 App「注册」提交  
2. 查收 QQ/163 收件箱与垃圾箱  
3. 输入邮件中的验证码完成注册（位数以邮件为准）  
4. 登录页点「忘记密码」→ 收验证码 → 设新密码  

App / Web 已支持：发恢复码 → 校验 `recovery` OTP → 更新密码并登录。

## 二、短信（可选，后续）

Twilio 等国际通道对中国大陆号码不稳定且贵。建议：

1. 开通 **阿里云短信** 或 **腾讯云短信**，申请验证码模板与签名（需企业资质）。  
2. Supabase：Authentication → Phone，或用 **Auth Hook / Edge Function** 转发到阿里云/腾讯云 HTTP API。  
3. 网关已支持：  
   - `POST /api/auth/resend-otp` `{ "phone": "13800138000" }`  
   - `POST /api/auth/verify-otp` `{ "phone": "...", "token": "123456", "type": "sms" }`  
4. UI 手机号注册可在通道就绪后加；当前产品主路径为邮箱。

## 三、与网关的关系

- Web 浏览器只打本站 `/api/auth/*`，不直连 `supabase.co`。  
- App 经 EdgeOne `/api/sb` 代理 Auth。  
- **发信/发短信由 Supabase Auth（+ 你配的 SMTP/SMS）完成**，与 EdgeOne 无关；关键是 SMTP/SMS 服务商本身能打进国内。

## 四、常见问题

| 现象 | 处理 |
|------|------|
| 注册成功但无验证码 | 未开 Confirm email，或 SMTP 未配 / 发信被拒 |
| QQ 邮箱进垃圾箱 | 完善 SPF/DKIM（邮件服务商控制台） |
| `User already registered` | 改登录，或 Dashboard 删测试用户 |
| 验证码很快过期 | 查 Dashboard「Email OTP expiration」是否被改短；**重发后旧码立即失效**，请用最新一封；勿混用注册码与重置密码码 |
| 密码登录失败但已注册 | 邮箱未确认，先走验证码或后台手动 Confirm |
