# FindIt 认证/订阅/支付 技术文档

> 最后更新: 2026-02-13
> 版本: v1.0 (Phase S1-S5 + 审查修复 Round 1-2)

---

## 目录

1. [系统概览](#1-系统概览)
2. [Supabase 后端](#2-supabase-后端)
3. [Stripe 集成](#3-stripe-集成)
4. [OpenRouter 集成](#4-openrouter-集成)
5. [macOS 客户端](#5-macos-客户端)
6. [订阅状态机](#6-订阅状态机)
7. [用户流程](#7-用户流程)
8. [API Key 解析优先级](#8-api-key-解析优先级)
9. [安全策略](#9-安全策略)
10. [部署指南](#10-部署指南)
11. [已知问题和限制](#11-已知问题和限制)
12. [未来计划](#12-未来计划)

---

## 1. 系统概览

### 1.1 架构图

```
┌─────────────────────────────────────────────────────────────────────┐
│                      macOS Client (Swift/SwiftUI)                   │
│  ┌─────────────┐  ┌──────────────────┐  ┌───────────────────────┐  │
│  │ AuthManager  │  │ SubscriptionMgr  │  │  IndexingManager      │  │
│  │  (Supabase   │  │  (Plan/Status/   │  │  (API Key 解析        │  │
│  │   Auth SDK)  │  │   Stripe URLs)   │  │   + ProviderConfig)   │  │
│  └──────┬───────┘  └────────┬─────────┘  └──────────┬────────────┘  │
│         │                   │                       │               │
│  ┌──────┴───────────────────┴───────────────────────┴────────────┐  │
│  │                   CloudKeyManager (macOS Keychain)             │  │
│  └───────────────────────────┬───────────────────────────────────┘  │
└──────────────────────────────┼──────────────────────────────────────┘
                               │ HTTPS (JWT)
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                     Supabase (Backend-as-a-Service)                  │
│  ┌───────────────┐  ┌───────────────────────────────────────────┐   │
│  │   Auth         │  │   Edge Functions (Deno)                   │   │
│  │  • Email/Pass  │  │  • on-user-created    (JWT auth)         │   │
│  │  • Apple ID    │  │  • check-subscription (JWT auth)         │   │
│  │  • JWT tokens  │  │  • get-cloud-key      (JWT auth)         │   │
│  └───────┬────────┘  │  • create-checkout    (JWT auth)         │   │
│          │           │  • manage-billing     (JWT auth)         │   │
│  ┌───────┴────────┐  │  • stripe-webhook     (Stripe sig)      │   │
│  │  PostgreSQL     │  │  • checkout-result   (public, no auth)  │   │
│  │  • profiles     │  └──────────┬──────────────────────────────┘   │
│  │  • subscriptions│             │                                   │
│  │  • openrouter_  │             │                                   │
│  │    keys         │             ▼                                   │
│  │  • usage_logs   │  ┌──────────────────┐  ┌─────────────────────┐ │
│  └─────────────────┘  │  Stripe API       │  │  OpenRouter API     │ │
│                       │  • Checkout        │  │  • Key Provisioning │ │
│                       │  • Portal          │  │  • Usage Tracking   │ │
│                       │  • Webhooks        │  │  • Budget Control   │ │
│                       └──────────────────┘  └─────────────────────┘ │
└──────────────────────────────────────────────────────────────────────┘
```

### 1.2 技术栈

| 层 | 技术 | 用途 |
|---|---|---|
| 客户端 | Swift 6.2 / SwiftUI / SPM | macOS 原生 App |
| 认证 | Supabase Auth (supabase-swift 2.41+) | Email/密码登录、JWT 会话管理 |
| 数据库 | PostgreSQL 17 (Supabase hosted) | 用户、订阅、Key 元数据、审计日志 |
| 后端逻辑 | Supabase Edge Functions (Deno 2) | 业务逻辑、第三方 API 调用 |
| 支付 | Stripe (Checkout + Portal + Webhooks) | 订阅计费 |
| AI API 代理 | OpenRouter | 统一 AI API 入口 (Vision + Embedding) |
| Key 存储 | macOS Keychain (Security.framework) | 客户端 API Key 安全存储 |
| 配置持久化 | UserDefaults | ProviderConfig、SubscriptionCache |

### 1.3 订阅模型

| 计划 | 价格 | 月预算 | 功能 |
|---|---|---|---|
| **Free** | 免费 | $0 | 本地索引 (CLIP + Apple Vision + EmbeddingGemma)，无云端 AI |
| **Trial** | 免费 14 天 | $1.00 | 注册即享。云端 Vision (Gemini 2.5 Flash via OpenRouter) + 云端 Embedding |
| **Pro** | $9.99/月 | $10.00 | 全部云端功能，更高预算 |

---

## 2. Supabase 后端

### 2.1 项目信息

| 项 | 值 |
|---|---|
| Project Ref | `xbuyfrzfmyzrioqhnmov` |
| Region | (Supabase hosted) |
| Dashboard | `https://supabase.com/dashboard/project/xbuyfrzfmyzrioqhnmov` |
| API URL | `https://xbuyfrzfmyzrioqhnmov.supabase.co` |
| Migration | `supabase/migrations/20260213180321_create_findit_schema.sql` |

### 2.2 数据库 Schema

#### 自定义类型

```sql
CREATE TYPE public.plan_type AS ENUM ('free', 'trial', 'pro');
CREATE TYPE public.subscription_status AS ENUM (
    'active', 'trialing', 'past_due', 'canceled', 'expired'
);
```

#### `profiles` 表 — 用户扩展信息

| 列 | 类型 | 约束 | 说明 |
|---|---|---|---|
| `id` | UUID | PK, FK → auth.users(id) ON DELETE CASCADE | 与 Auth 用户 1:1 |
| `email` | TEXT | | 冗余存储方便查询 |
| `display_name` | TEXT | | 显示名称 |
| `avatar_url` | TEXT | | 头像 URL |
| `created_at` | TIMESTAMPTZ | NOT NULL, DEFAULT now() | |
| `updated_at` | TIMESTAMPTZ | NOT NULL, DEFAULT now() | 自动更新 |

**RLS 策略:**
- `SELECT`: `auth.uid() = id` (用户只能看自己)
- `UPDATE`: `auth.uid() = id` (用户只能改自己)
- `INSERT`/`DELETE`: 仅 service_role

**触发器:**
- `on_auth_user_created` — Auth 注册时自动创建 profile 行 (DB trigger, 非 Edge Function)
- `set_profiles_updated_at` — 更新时自动刷新 `updated_at`

#### `subscriptions` 表 — 订阅状态

| 列 | 类型 | 约束 | 说明 |
|---|---|---|---|
| `id` | UUID | PK, DEFAULT gen_random_uuid() | |
| `user_id` | UUID | NOT NULL, FK → auth.users, UNIQUE | 每用户唯一 |
| `plan` | plan_type | NOT NULL, DEFAULT 'free' | 当前计划 |
| `status` | subscription_status | NOT NULL, DEFAULT 'active' | 当前状态 |
| `stripe_customer_id` | TEXT | | Stripe 客户 ID |
| `stripe_subscription_id` | TEXT | | Stripe 订阅 ID |
| `trial_started_at` | TIMESTAMPTZ | | Trial 开始时间 |
| `trial_ends_at` | TIMESTAMPTZ | | Trial 结束时间 |
| `current_period_start` | TIMESTAMPTZ | | 当前计费周期开始 |
| `current_period_end` | TIMESTAMPTZ | | 当前计费周期结束 |
| `monthly_budget_cents` | INT | NOT NULL, DEFAULT 100 | 月预算（美分）: Trial=100, Pro=1000 |
| `created_at` | TIMESTAMPTZ | NOT NULL, DEFAULT now() | |
| `updated_at` | TIMESTAMPTZ | NOT NULL, DEFAULT now() | 自动更新 |

**RLS 策略:**
- `SELECT`: `auth.uid() = user_id`
- `INSERT`/`UPDATE`/`DELETE`: 仅 service_role (Edge Functions 通过 admin client 操作)

**索引:**
- `idx_subscriptions_user_id` ON (user_id)
- `idx_subscriptions_stripe_customer` ON (stripe_customer_id)
- `idx_subscriptions_stripe_sub` ON (stripe_subscription_id)

#### `openrouter_keys` 表 — API Key 元数据

| 列 | 类型 | 约束 | 说明 |
|---|---|---|---|
| `id` | UUID | PK, DEFAULT gen_random_uuid() | |
| `user_id` | UUID | NOT NULL, FK → auth.users, UNIQUE | 每用户唯一 |
| `key_hash` | TEXT | NOT NULL | OpenRouter key hash (用于 PATCH/DELETE 管理) |
| `key_prefix` | TEXT | | 前 15 字符用于显示 "sk-or-v1-abc..." |
| `is_active` | BOOLEAN | NOT NULL, DEFAULT true | Key 是否激活 |
| `limit_usd` | NUMERIC(10,4) | | 月预算限额 (USD) |
| `created_at` | TIMESTAMPTZ | NOT NULL, DEFAULT now() | |
| `updated_at` | TIMESTAMPTZ | NOT NULL, DEFAULT now() | 自动更新 |

**重要**: 数据库**不存储完整 API Key**。完整 Key 只在 OpenRouter 创建时返回一次，通过 Edge Function 传给客户端存入 Keychain。数据库仅存 `key_hash`（用于管理 API）和 `key_prefix`（用于 UI 显示）。

**RLS 策略:**
- `SELECT`: `auth.uid() = user_id`
- `INSERT`/`UPDATE`/`DELETE`: 仅 service_role

#### `usage_logs` 表 — 审计日志

| 列 | 类型 | 约束 | 说明 |
|---|---|---|---|
| `id` | BIGSERIAL | PK | 自增 |
| `user_id` | UUID | NOT NULL, FK → auth.users | |
| `event_type` | TEXT | NOT NULL | 事件类型 |
| `details` | JSONB | | 事件详情 |
| `created_at` | TIMESTAMPTZ | NOT NULL, DEFAULT now() | |

**已使用的 event_type 值:**
- `user_created` — 新用户注册成功
- `trial_expired` — Trial 到期自动降级
- `trial_auto_created` — get-cloud-key 自动补建 trial
- `key_rotated` — 新 Key 分配（替换旧 Key）
- `upgrade_to_pro` — Stripe 支付成功升级
- `payment_failed` — Stripe 付款失败
- `downgrade_to_free` — 取消订阅降级

**索引:**
- `idx_usage_logs_user_id` ON (user_id)
- `idx_usage_logs_created_at` ON (created_at)

### 2.3 Auth 配置

**当前设置（测试阶段）:**

| 配置项 | 值 | 说明 |
|---|---|---|
| Site URL | `http://127.0.0.1:3000` (config.toml 本地值) | 远程项目在 Dashboard 配置 |
| Email Confirmations | **关闭** | 测试阶段注册即获得 session |
| Minimum Password Length | 6 (config.toml) | Dashboard 应设为 8 |
| Anonymous Sign-Ins | 关闭 | |
| JWT Expiry | 3600 秒 (1 小时) | |
| Rate Limits | 30 sign-in / 30 sign-up per 5min | |
| SMTP | 未配置 (本地用 Inbucket) | 远程项目需配置 Resend/SendGrid |

**`config.toml` 关键段:**
```toml
[auth]
site_url = "http://127.0.0.1:3000"
enable_signup = true
[auth.email]
enable_signup = true
enable_confirmations = false
```

> **注意**: `config.toml` 仅控制**本地开发环境**。远程 Supabase 项目的 Auth 配置在 [Dashboard](https://supabase.com/dashboard/project/xbuyfrzfmyzrioqhnmov/auth/settings) 中管理。

### 2.4 Edge Functions

所有 Edge Functions 位于 `supabase/functions/` 目录，使用 Deno 2 运行时。

#### 2.4.1 `on-user-created` — 新用户初始化

| 项 | 值 |
|---|---|
| 路径 | `supabase/functions/on-user-created/index.ts` |
| 认证 | JWT (需登录) |
| 部署参数 | 默认（**不加** `--no-verify-jwt`） |
| 触发方式 | 客户端在 `AuthManager.signUpWithEmail()` 成功后主动调用 |

**职责:**
1. 从 JWT 提取 user ID 和 email
2. 检查幂等性（subscription 是否已存在）
3. 创建 trial subscription (14 天, $1.00 月预算)
4. 通过 OpenRouter Management API 创建 API Key
5. 将 Key 元数据 (hash, prefix) 存入 `openrouter_keys` 表
6. 记录 `user_created` 审计日志
7. **返回完整 API Key** 给客户端（仅此一次）

**错误处理:**
- OpenRouter Key 创建失败 → 不致命，用户仍可使用本地功能
- DB 写入 Key 失败 → 尝试清理已创建的 OpenRouter Key
- 已有 subscription → 返回 `already_exists: true`，不重复创建

**响应格式:**
```json
{
  "openrouter_key": "sk-or-v1-...",  // 完整 Key，仅返回一次
  "plan": "trial",
  "trial_ends_at": "2026-02-27T..."
}
```

#### 2.4.2 `check-subscription` — 查询订阅状态

| 项 | 值 |
|---|---|
| 路径 | `supabase/functions/check-subscription/index.ts` |
| 认证 | JWT |
| 调用时机 | App 启动、登录后、每小时轮询、didBecomeActive |

**职责:**
1. 查询用户的 subscription 行
2. **检测 Trial 过期**: 如果 `trial_ends_at < now()`，自动降级为 free/expired 并禁用 OpenRouter Key
3. 查询 OpenRouter 实时用量 (`getKeyInfo`)
4. 返回完整订阅状态

**自动降级逻辑:**
```
if plan == "trial" && trial_ends_at < now:
    UPDATE subscriptions SET plan='free', status='expired'
    DISABLE OpenRouter key (PATCH disabled=true)
    LOG "trial_expired"
```

**响应格式:**
```json
{
  "plan": "trial",
  "status": "trialing",
  "trial_ends_at": "2026-02-27T...",
  "current_period_end": null,
  "usage": { "monthly_usd": 0.23, "limit_usd": 1.0 },
  "cloud_enabled": true
}
```

**`cloud_enabled` 逻辑:**
```
cloud_enabled = (plan in [trial, pro]) AND (status in [active, trialing])
```

#### 2.4.3 `get-cloud-key` — 重新分配 API Key

| 项 | 值 |
|---|---|
| 路径 | `supabase/functions/get-cloud-key/index.ts` |
| 认证 | JWT |
| 调用时机 | 返回用户登录（Keychain 无 Key）、新设备、重装 App |

**职责:**
1. 查询 subscription；如果不存在，**自动创建 trial**（处理 `on-user-created` 调用失败的情况）
2. 检查云端功能是否可用（plan + status）
3. 检查 trial 是否已过期
4. 禁用旧 Key（如果存在）
5. 创建新 Key（预算按 plan 决定：trial=$1, pro=$10）
6. Upsert `openrouter_keys` 表
7. 返回新 Key

**自动 Trial 补建逻辑:**
```
if no subscription found:
    CREATE subscription (plan=trial, status=trialing, 14 days)
    LOG "trial_auto_created" (reason: "get-cloud-key fallback")
```

**预算映射:**
| Plan | 预算 (USD) |
|---|---|
| trial | 1.00 |
| pro | 10.00 |
| free | 0 (不分配 Key) |

#### 2.4.4 `create-checkout` — 创建 Stripe Checkout

| 项 | 值 |
|---|---|
| 路径 | `supabase/functions/create-checkout/index.ts` |
| 认证 | JWT |
| 调用时机 | 用户点击"升级 Pro" |

**职责:**
1. 检查用户是否已是 Pro（是则返回 400）
2. 获取或创建 Stripe Customer（将 `stripe_customer_id` 保存到 subscriptions）
3. 创建 Stripe Checkout Session（mode=subscription）
4. 返回 `checkout_url`

**重定向 URL（硬编码，不接受客户端参数）:**
```
success: https://xbuyfrzfmyzrioqhnmov.supabase.co/functions/v1/checkout-result?status=success
cancel:  https://xbuyfrzfmyzrioqhnmov.supabase.co/functions/v1/checkout-result?status=cancel
```

> **安全设计**: 所有重定向 URL 在服务端硬编码，客户端无法注入自定义 URL。

#### 2.4.5 `stripe-webhook` — Stripe Webhook 处理

| 项 | 值 |
|---|---|
| 路径 | `supabase/functions/stripe-webhook/index.ts` |
| 认证 | Stripe Webhook Signature（不验证 JWT） |
| 部署参数 | `--no-verify-jwt` |

**处理的事件:**

| 事件 | 处理逻辑 |
|---|---|
| `checkout.session.completed` | subscription → pro/active, OpenRouter limit → $10, 提取 `current_period_end` |
| `invoice.payment_failed` | subscription → past_due, 记录日志 |
| `customer.subscription.deleted` | subscription → free/canceled, 禁用 OpenRouter key |

**关键设计:**
- 所有 OpenRouter `updateKey()` 调用包裹在 try/catch 中（非致命）
- 从 Stripe Subscription 对象提取 `current_period_end` 并存入 DB
- 将 `stripe_customer_id` 保存到 subscriptions 表
- 通过 `metadata.supabase_user_id` 或 `stripe_customer_id` 关联用户

#### 2.4.6 `manage-billing` — Stripe 客户门户

| 项 | 值 |
|---|---|
| 路径 | `supabase/functions/manage-billing/index.ts` |
| 认证 | JWT |
| 调用时机 | 用户点击"管理订阅" |

**职责:**
1. 查询用户的 `stripe_customer_id`
2. 创建 Stripe Billing Portal Session
3. 返回 `portal_url`

**Return URL（硬编码）:**
```
https://xbuyfrzfmyzrioqhnmov.supabase.co/functions/v1/checkout-result?status=billing-return
```

#### 2.4.7 `checkout-result` — 支付结果页

| 项 | 值 |
|---|---|
| 路径 | `supabase/functions/checkout-result/index.ts` |
| 认证 | 无（公开页面） |
| 部署参数 | `--no-verify-jwt` |

**背景**: 由于 macOS App 通过 SPM 构建，无法注册 `findit://` URL scheme（需要 Info.plist）。Stripe 支付完成后重定向到此页面，提示用户回到 App。App 在 `didBecomeActive` 时自动刷新订阅状态。

**支持的状态参数:**

| `?status=` | 标题 | 说明 |
|---|---|---|
| `success` | Payment Successful! | 支付成功，请返回 App |
| `cancel` | Payment Cancelled | 支付取消 |
| `billing-return` | Billing Updated | 账单管理完成 |
| 其他 | FindIt | 默认提示 |

### 2.5 共享工具库 (`_shared/`)

#### `supabase.ts` — Supabase 客户端工厂

```typescript
// Admin client (service_role, 绕过 RLS)
export function createAdminClient(): SupabaseClient

// User client (anon key + JWT, 遵守 RLS)
export function createUserClient(authHeader: string): SupabaseClient

// 从 JWT 提取并验证用户
export async function getUser(authHeader: string): Promise<User>
```

**环境变量依赖:**
- `SUPABASE_URL` — Supabase 项目 URL
- `SUPABASE_SERVICE_ROLE_KEY` — service_role key (admin 操作)
- `SUPABASE_ANON_KEY` — 匿名 key (RLS 场景)

#### `openrouter.ts` — OpenRouter Provisioning API

Base URL: `https://openrouter.ai/api/v1/keys`

| 函数 | HTTP | 用途 |
|---|---|---|
| `createKey(opts)` | POST | 创建新 Key (name, limit, limitReset) |
| `getKeyInfo(hash)` | GET `/{hash}` | 查询 Key 信息和用量 |
| `updateKey(hash, updates)` | PATCH `/{hash}` | 更新 Key (disabled, limit, name) |
| `deleteKey(hash)` | DELETE `/{hash}` | 删除 Key |

**环境变量:** `OPENROUTER_MANAGEMENT_KEY` — OpenRouter 管理员 API Key

**`createKey` 返回:**
```typescript
{
  key: string;         // 完整 API Key（仅返回一次！）
  data: {
    hash: string;      // Key 的 hash（用于后续管理操作）
    name: string;
    limit: number | null;
    limit_reset: string | null;
    disabled: boolean;
    usage: number;
  }
}
```

**`getKeyInfo` 返回:**
```typescript
{
  hash: string;
  usage_monthly: number;  // 当月用量 (USD)
  limit: number | null;   // 月限额 (USD)
  disabled: boolean;
}
```

#### `cors.ts` — CORS 支持

```typescript
export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// OPTIONS 预检请求处理
export function handleCors(req: Request): Response | null
```

---

## 3. Stripe 集成

### 3.1 产品和价格

| 项 | 值 |
|---|---|
| 产品名 | FindIt Pro |
| Product ID | `prod_TyNvwVNNugH7jY` |
| Price ID | `price_1T0RA79GqI2bYzqDlVXBHsRk` |
| 金额 | $9.99/月 (recurring) |
| 模式 | Stripe 测试模式 |

### 3.2 Webhook 配置

| 项 | 值 |
|---|---|
| Endpoint | `https://xbuyfrzfmyzrioqhnmov.supabase.co/functions/v1/stripe-webhook` |
| Secret | 通过 `STRIPE_WEBHOOK_SECRET` 环境变量配置 |
| API Version | `2024-12-18.acacia` |

**监听的事件:**
- `checkout.session.completed` — 支付成功
- `invoice.payment_failed` — 付款失败
- `customer.subscription.deleted` — 订阅取消

### 3.3 Customer Portal

通过 `manage-billing` Edge Function 创建临时 Portal Session。用户可以：
- 查看订阅详情
- 更新支付方式
- 取消订阅
- 查看发票历史

### 3.4 Checkout 流程

```
用户点击"升级 Pro"
  → SubscriptionManager.checkoutURL()
  → create-checkout Edge Function
  → Stripe Checkout Session 创建
  → 返回 checkout_url
  → NSWorkspace.shared.open(url) 打开浏览器
  → 用户在 Stripe 页面完成支付
  → Stripe 发 webhook → stripe-webhook 处理
  → 浏览器重定向到 checkout-result 页面
  → 用户回到 App → didBecomeActive → subscriptionManager.refresh()
```

### 3.5 测试支付

使用 Stripe 测试卡:
- **成功**: `4242 4242 4242 4242` (任意未来日期, 任意 CVC)
- **失败**: `4000 0000 0000 0002` (会触发 payment_failed)
- **3DS**: `4000 0025 0000 3155` (需要 3D Secure 验证)

---

## 4. OpenRouter 集成

### 4.1 Management API

| 项 | 值 |
|---|---|
| Base URL | `https://openrouter.ai/api/v1/keys` |
| 认证 | `Bearer {OPENROUTER_MANAGEMENT_KEY}` |
| 文档 | `https://openrouter.ai/docs/api-reference/keys` |

Management API 允许:
- 创建带预算限制的子 Key
- 查询子 Key 用量
- 禁用/启用子 Key
- 修改预算限制
- 删除子 Key

### 4.2 Key 生命周期

```
1. 用户注册
   → on-user-created 调用 createKey(name="findit-{uid[:8]}", limit=$1, reset=monthly)
   → 完整 Key 返回给客户端 → 存入 Keychain
   → key_hash + key_prefix 存入 openrouter_keys 表

2. Trial 期间
   → 客户端使用 Key 调用 OpenRouter API (Vision/Embedding)
   → OpenRouter 自动追踪用量，月底重置
   → check-subscription 查询实时用量 (getKeyInfo)

3. 升级 Pro
   → stripe-webhook 调用 updateKey(hash, {limit: $10})
   → openrouter_keys 表更新 limit_usd

4. Trial 过期 / 取消订阅
   → check-subscription 或 stripe-webhook 调用 updateKey(hash, {disabled: true})
   → openrouter_keys 表更新 is_active=false

5. 重新登录 / 新设备
   → get-cloud-key 调用 updateKey(oldHash, {disabled: true}) 禁用旧 Key
   → 调用 createKey() 创建新 Key
   → 新 Key 返回给客户端 → 存入 Keychain

6. 退出登录
   → AuthManager.signOut() 删除 Keychain 中的 Key
   → （OpenRouter 端的 Key 不会被删除，但客户端已无法使用）
```

### 4.3 预算限制

| 计划 | 月限额 | 重置周期 |
|---|---|---|
| Trial | $1.00 | monthly |
| Pro | $10.00 | monthly |
| Free | N/A (Key 被禁用) | - |

OpenRouter 在达到限额后自动拒绝请求。客户端通过 `check-subscription` 查询当前用量并显示在 UI 中。

---

## 5. macOS 客户端

### 5.1 AuthManager

**文件:** `Sources/FindItApp/Auth/AuthManager.swift`

`@Observable @MainActor` 类，管理 Supabase Auth 会话。

**Supabase Client 配置:**
```swift
SupabaseClient(
    supabaseURL: URL(string: "https://xbuyfrzfmyzrioqhnmov.supabase.co")!,
    supabaseKey: "<anon key>"  // JWT, 非 service_role
)
```

**Auth 状态:**
```swift
enum AuthState: Sendable {
    case unknown       // 尚未检查
    case anonymous     // 无会话
    case authenticated(userId: String, email: String?)
}
```

**注册返回值:**
```swift
enum SignUpResult: Sendable {
    case authenticated        // 立即获得 session (confirmations 关闭)
    case confirmationPending  // 需邮件确认 (confirmations 开启)
}
```

**关键方法:**

| 方法 | 作用 |
|---|---|
| `restoreSession()` | App 启动时从 Keychain 恢复 Supabase session |
| `startListening()` | 监听 `authStateChanges` (token 刷新失败、远程登出等) |
| `signInWithEmail(email:password:)` | 登录 + 自动 `provisionCloudKeyIfNeeded` |
| `signUpWithEmail(email:password:)` | 注册 → 返回 `SignUpResult` → 成功则调 `initializeNewUser` |
| `resetPassword(email:)` | 发送密码重置邮件 |
| `signInWithApple(idToken:nonce:)` | Apple ID 登录（预留，需代码签名） |
| `signOut()` | 清理 Keychain Key + Supabase signOut |

**内部方法:**

| 方法 | 作用 |
|---|---|
| `initializeNewUser(userId:)` | 调用 `on-user-created` Edge Function，存 Key 到 Keychain |
| `provisionCloudKeyIfNeeded(userId:)` | 检查 Keychain 有无 Key，无则调 `get-cloud-key` |

**`startListening()` 监听的事件:**
- `.signedIn` → 更新 authState 为 authenticated
- `.signedOut` → 更新 authState 为 anonymous
- 其他事件忽略

### 5.2 SubscriptionManager

**文件:** `Sources/FindItApp/Auth/SubscriptionManager.swift`

`@Observable @MainActor` 类，管理订阅状态。通过 `check-subscription` Edge Function 获取最新状态。

**类型定义:**
```swift
enum Plan: String { case free, trial, pro }
enum SubStatus: String { case active, trialing, past_due, canceled, expired }

struct SubscriptionInfo: Codable {
    let plan: Plan
    let status: SubStatus
    let trialEndsAt: Date?
    let currentPeriodEnd: Date?
    let monthlyUsageUsd: Double?
    let limitUsd: Double?
    let cloudEnabled: Bool
}
```

**计算属性:**

| 属性 | 用途 |
|---|---|
| `isCloudEnabled` | 云端功能是否可用（IndexingManager 决策用） |
| `currentPlan` | 当前计划（UI 显示用） |
| `trialDaysRemaining` | Trial 剩余天数（nil = 非 trial） |
| `usageText` | 格式化用量 "$0.23 / $1.00" |
| `isPastDue` | 是否付款失败 |

**关键方法:**

| 方法 | 作用 |
|---|---|
| `refresh()` | 调 `check-subscription`，更新状态 + 缓存 |
| `loadCache()` | 从 UserDefaults 加载缓存（离线启动） |
| `clearCache()` | 清理缓存（退出登录时） |
| `checkoutURL()` | 调 `create-checkout`，返回 Stripe Checkout URL |
| `billingPortalURL()` | 调 `manage-billing`，返回 Stripe Portal URL |

**缓存策略:**
- Key: `FindIt.SubscriptionCache` (UserDefaults)
- 每次 `refresh()` 成功后缓存
- 离线启动时加载缓存，但额外检查 Trial 是否本地过期
- 退出登录时清理

**刷新时机:**
1. App 启动 (`ContentView .task`)
2. 登录成功后 (`onChange(authManager.isAuthenticated)`)
3. 每小时轮询 (`ContentView .task` with `Task.sleep(3600s)`)
4. App 从后台恢复 (`NSApplication.didBecomeActiveNotification`)

### 5.3 CloudKeyManager (Keychain)

**文件:** `Sources/FindItCore/Cloud/CloudKeyManager.swift`

`public enum`，管理 macOS Keychain 中的 OpenRouter API Key。

**Keychain 配置:**
```swift
kSecAttrService: "com.findit.openrouter-key"  // 服务名
kSecAttrAccount: userId                        // 用户 ID 作为账户名
kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly  // 仅本设备解锁时可用
```

| 方法 | 作用 |
|---|---|
| `storeKey(_:for:)` | 存储 Key（先删旧值再写入） |
| `retrieveKey(for:)` | 读取 Key |
| `deleteKey(for:)` | 删除 Key（退出登录时调用） |
| `hasKey(for:)` | 检查是否存在 |

**安全特性:**
- Key 仅存在 Keychain，不存文件、不存 UserDefaults
- `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: 设备锁屏时不可读取，不同步到 iCloud Keychain
- `kSecClassGenericPassword`: 通用密码类型

### 5.4 APIKeyManager (文件/环境变量)

**文件:** `Sources/FindItCore/Pipeline/APIKeyManager.swift`

`public enum`，管理基于文件和环境变量的 API Key。这是**旧版机制**，用于 CLI 和高级用户手动配置。

**解析优先级:**
1. override 参数（CLI `--api-key` 传入）
2. 配置文件（`~/.config/findit/{provider}-api-key.txt`）
3. 环境变量

**Provider 文件路径:**

| Provider | 文件路径 | 环境变量 |
|---|---|---|
| Gemini | `~/.config/findit/gemini-api-key.txt` | `GEMINI_API_KEY` |
| OpenRouter | `~/.config/findit/openrouter-api-key.txt` | `OPENROUTER_API_KEY` |
| FindIt Cloud | `~/.config/findit/findit-cloud-token.txt` | `FINDIT_CLOUD_TOKEN` |

**与 CloudKeyManager 的关系:**
- CloudKeyManager = 订阅用户的 Key（Keychain 存储）
- APIKeyManager = 非订阅用户 / CLI 用户的 Key（文件存储）
- IndexingManager 按优先级选择: CloudKeyManager → APIKeyManager

### 5.5 ProviderConfig

**文件:** `Sources/FindItCore/Pipeline/ProviderConfig.swift`

外部 API 提供者配置，控制 Vision 和 Embedding 使用哪个 API。

**APIProvider 枚举:**
```swift
enum APIProvider: String, Codable {
    case gemini        // Google Gemini (直连)
    case openRouter    // OpenRouter (AI API 代理)
    case findItCloud   // FindIt Cloud (预留)
}
```

**ProviderConfig 字段:**

| 字段 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `provider` | APIProvider | `.gemini` | API 提供者 |
| `baseURL` | String? | nil (使用 provider 默认) | 自定义 base URL |
| `visionModel` | String | `"gemini-2.5-flash"` | 视觉分析模型 |
| `visionMaxImages` | Int | 10 | 每请求最大图片数 |
| `visionTimeout` | Double | 60.0 | 超时秒数 |
| `visionMaxRetries` | Int | 3 | 最大重试次数 |
| `embeddingModel` | String | `"gemini-embedding-001"` | 嵌入模型 |
| `embeddingDimensions` | Int | 768 | 向量维度 |
| `rateLimitRPM` | Int | 9 | 每分钟请求数 |

**订阅模式覆盖:**

当 IndexingManager 检测到使用订阅 Key 时，忽略用户保存的 ProviderConfig，强制使用:
```swift
ProviderConfig(
    provider: .openRouter,
    visionModel: "google/gemini-2.5-flash",
    embeddingModel: "qwen/qwen3-embedding-8b",
    embeddingDimensions: 768,
    rateLimitRPM: 30
)
```

**持久化:** UserDefaults key `FindIt.ProviderConfig`

### 5.6 IndexingManager 订阅逻辑

**文件:** `Sources/FindItApp/IndexingManager.swift`

**订阅相关属性:**
```swift
private var resolvedAPIKey: String?         // 已解析的 API Key
private var hasResolvedAPIKey = false        // 是否已尝试解析
private var isUsingSubscriptionKey = false   // 是否使用订阅 Key
weak var authManager: AuthManager?
weak var subscriptionManager: SubscriptionManager?
```

**API Key 解析方法 `resolveAPIKeyForCurrentUser()`:**

```
1. 检查 subscriptionManager.isCloudEnabled 且 authManager.currentUserId 存在
   → 是: 从 CloudKeyManager.retrieveKey(userId) 获取 Keychain Key
     → 有 Key: isUsingSubscriptionKey=true, 返回 Key
     → 无 Key: 后台触发 get-cloud-key 重新分配
2. 回退到 APIKeyManager.resolveAPIKey() (文件/环境变量)
   → isUsingSubscriptionKey=false
```

**`effectiveProviderConfig()`:**
- 订阅 Key → 返回硬编码 OpenRouter 配置
- 文件 Key → 返回 `ProviderConfig.load()` (用户自定义配置)

**`resetAPIKeyCache()`:**
在登录/退出时调用，清除缓存强制下次索引重新解析 Key:
```swift
hasResolvedAPIKey = false
resolvedAPIKey = nil
isUsingSubscriptionKey = false
rateLimiter = nil
networkResilience = nil
geminiEmbeddingProvider = nil
```

**CloudMode 枚举:**
```swift
public enum CloudMode: String, Codable {
    case local  // L3 使用 LocalVLM + EmbeddingGemma，无网络
    case cloud  // L3 使用 Gemini API (需 API Key)
}
```

**`buildLayeredConfig()` 中的 cloud/local 决策:**
```
useCloud = (options.cloudMode == .cloud) && (resolvedAPIKey != nil)

if useCloud:
    L3 Vision → Gemini via OpenRouter/Gemini API
    L3 Embedding → GeminiEmbeddingProvider
else:
    L3 Vision → LocalVLM (opt-in) 或跳过
    L3 Embedding → EmbeddingGemmaProvider (本地)
```

### 5.7 UI 组件

#### LoginSheet

**文件:** `Sources/FindItApp/Views/LoginSheet.swift`

**功能:**
- Email + 密码登录/注册
- 登录/注册模式切换
- "忘记密码？" → 发送重置邮件
- 注册后若需邮件确认，显示绿色提示 "请查收确认邮件"
- 密码重置后显示 "重置邮件已发送"
- 错误信息红色显示

**状态变量:**
```swift
@State private var email = ""
@State private var password = ""
@State private var isSignUp = false
@State private var isLoading = false
@State private var errorMessage: String?
@State private var successMessage: String?
@State private var showForgotPassword = false
```

#### SettingsView — 账户区域

**文件:** `Sources/FindItApp/Views/SettingsView.swift`

账户 Tab 包含:
- 未登录状态：显示"登录"按钮
- 已登录状态：显示邮箱 + 计划 badge + 试用天数/用量 + "管理订阅"/"升级 Pro" 按钮 + "退出登录"

高级 Tab:
- 订阅模式下：显示信息横幅 "订阅模式下自动使用 OpenRouter"，所有 Provider/Model 控件禁用 + 半透明

#### ContentView — 订阅横幅

**文件:** `Sources/FindItApp/ContentView.swift`

`subscriptionBanner` 在以下情况显示:
- `isPastDue` → 红色横幅 "付款失败，云端功能已暂停" + "更新支付方式" 按钮
- `trialDaysRemaining <= 3` → 橙色横幅 "试用将在 X 天后到期" + "升级 Pro" 按钮

#### FindItApp — 入口

**文件:** `Sources/FindItApp/FindItApp.swift`

- `AuthManager` 和 `SubscriptionManager` 作为 `@State` 创建
- 通过 `.environment()` 注入到 `WindowGroup` 和 `Settings` scene
- 无 URL scheme handler（SPM 构建无法注册 URL scheme）

---

## 6. 订阅状态机

### 6.1 状态转换图

```
                                    ┌────────────────────┐
                                    │     anonymous      │
                                    │  (未登录/未注册)    │
                                    └────────┬───────────┘
                                             │ signUp
                                             ▼
                                    ┌────────────────────┐
                     ┌──────────────│  trial / trialing   │
                     │              │  ($1/月, 14天)       │
                     │              └────────┬───────────┘
                     │                       │
                     │          ┌────────────┼────────────┐
                     │          │            │            │
                     │   trial过期     checkout成功    signOut
                     │          │            │            │
                     │          ▼            ▼            ▼
                     │  ┌──────────┐  ┌──────────┐  ┌──────────┐
                     │  │  free /   │  │  pro /    │  │anonymous │
                     │  │  expired  │  │  active   │  │          │
                     │  └──────────┘  │ ($10/月)   │  └──────────┘
                     │                └──────┬─────┘
                     │                       │
                     │          ┌────────────┼────────────┐
                     │          │            │            │
                     │   付款失败      取消订阅       signOut
                     │          │            │            │
                     │          ▼            ▼            ▼
                     │  ┌──────────┐  ┌──────────┐  ┌──────────┐
                     │  │  pro /    │  │  free /   │  │anonymous │
                     │  │ past_due  │  │ canceled  │  │          │
                     │  └──────┬───┘  └──────────┘  └──────────┘
                     │         │
                     │    付款恢复
                     │         │
                     │         ▼
                     │  ┌──────────┐
                     └──│  pro /    │
                        │  active   │
                        └──────────┘
```

### 6.2 各状态行为

| 状态 | `cloud_enabled` | OpenRouter Key | 索引行为 |
|---|---|---|---|
| anonymous | false | 无 | 纯本地 (CLIP + Apple Vision + EmbeddingGemma) |
| trial / trialing | true | active, $1 limit | 云端 L3 (Gemini Vision + Embedding) |
| free / expired | false | disabled | 纯本地 |
| pro / active | true | active, $10 limit | 云端 L3 |
| pro / past_due | false | active (但 cloud_enabled=false) | 纯本地 (UI 显示付款失败横幅) |
| free / canceled | false | disabled | 纯本地 |

---

## 7. 用户流程

### 7.1 新用户注册

```
1. 用户打开 Settings → 账户 → "登录"
2. LoginSheet 显示 → 切换到"注册"
3. 输入 email + password → 点击"注册"
4. AuthManager.signUpWithEmail()
   → Supabase Auth 创建用户
   → [confirmations 关闭] 立即返回 session
   → authState = .authenticated
5. AuthManager.initializeNewUser()
   → 调用 on-user-created Edge Function (JWT auth)
   → Edge Function 创建 trial subscription + OpenRouter key
   → 完整 Key 返回
6. CloudKeyManager.storeKey() 存入 Keychain
7. LoginSheet dismiss
8. ContentView onChange(authManager.isAuthenticated)
   → indexingManager.resetAPIKeyCache()
   → subscriptionManager.refresh()
9. Settings 更新：显示邮箱 + Trial badge
```

### 7.2 返回用户登录

```
1. LoginSheet → 输入 email + password → "登录"
2. AuthManager.signInWithEmail()
   → Supabase Auth 验证 → 返回 session
3. AuthManager.provisionCloudKeyIfNeeded()
   → 检查 Keychain 有无 Key
   → [有 Key] 直接使用
   → [无 Key] 调 get-cloud-key → 获取新 Key → 存 Keychain
4. LoginSheet dismiss
5. ContentView onChange(authManager.isAuthenticated)
   → resetAPIKeyCache() + subscriptionManager.refresh()
```

### 7.3 App 启动（已登录用户）

```
1. FindItApp 创建 AuthManager + SubscriptionManager (@State)
2. ContentView .task:
   a. 设置依赖引用 (subscriptionManager.authManager = authManager, etc.)
   b. authManager.startListening() — 监听 auth 状态变化
   c. authManager.restoreSession()
      → [session 有效] authState = .authenticated
      → [session 过期, refresh token 有效] supabase-swift 自动刷新
      → [refresh token 也过期] authState = .anonymous
   d. [已认证] subscriptionManager.refresh()
      → 调 check-subscription → 更新本地状态 + 缓存
   e. [未认证] subscriptionManager.loadCache()
      → 从 UserDefaults 加载上次状态
3. 后续: 每 1 小时 subscriptionManager.refresh()
4. didBecomeActive 时也会 refresh()
```

### 7.4 升级 Pro

```
1. Settings → 账户 → "升级 Pro"
2. SubscriptionManager.checkoutURL()
   → 调 create-checkout Edge Function
   → Edge Function 创建 Stripe Checkout Session
   → 返回 checkout_url
3. NSWorkspace.shared.open(url) → 浏览器打开
4. 用户完成支付
5. Stripe 发 checkout.session.completed webhook
6. stripe-webhook Edge Function:
   → subscription 更新为 pro/active
   → OpenRouter key limit 升级到 $10
   → 保存 stripe_customer_id + current_period_end
7. 浏览器重定向到 checkout-result 页面 ("Payment Successful!")
8. 用户回到 App → didBecomeActive
9. subscriptionManager.refresh() → UI 更新为 Pro badge
```

### 7.5 管理/取消订阅

```
1. Settings → 账户 → "管理订阅"
2. SubscriptionManager.billingPortalURL()
   → 调 manage-billing → 返回 portal_url
3. 浏览器打开 Stripe Customer Portal
4. 用户取消订阅
5. Stripe 发 customer.subscription.deleted webhook
6. stripe-webhook:
   → subscription 降级为 free/canceled
   → OpenRouter key 禁用 (disabled=true)
7. 用户回到 App → didBecomeActive
8. subscriptionManager.refresh()
9. UI 更新：Free badge，云端模式不可用
10. 下次索引自动使用本地模式
```

### 7.6 忘记密码

```
1. LoginSheet → "忘记密码？"
2. 输入邮箱 → "发送重置邮件"
3. AuthManager.resetPassword(email:)
   → Supabase Auth 发送重置邮件
4. LoginSheet 显示绿色提示 "重置邮件已发送"
5. 用户点击邮件中链接 → Supabase hosted 重置页面
6. 输入新密码 → 保存
7. 回到 App → LoginSheet → 用新密码登录
```

### 7.7 退出登录

```
1. Settings → 账户 → "退出登录"
2. AuthManager.signOut():
   a. CloudKeyManager.deleteKey(userId) → 清除 Keychain Key
   b. client.auth.signOut() → Supabase 登出
   c. authState = .anonymous
3. ContentView onChange(authManager.isAuthenticated):
   a. indexingManager.resetAPIKeyCache()
   b. subscriptionManager.clearCache()
4. Settings 恢复"未登录"状态
5. 索引回退到文件 Key (APIKeyManager) 或纯本地
```

---

## 8. API Key 解析优先级

IndexingManager 在开始索引时按以下优先级解析 API Key:

```
┌─────────────────────────────────────────────────────────┐
│ 优先级 1: 订阅 Key (Keychain)                           │
│                                                         │
│ 条件: subscriptionManager.isCloudEnabled == true        │
│       && authManager.currentUserId != nil               │
│                                                         │
│ 来源: CloudKeyManager.retrieveKey(for: userId)          │
│ 效果: isUsingSubscriptionKey = true                     │
│       → ProviderConfig 强制为 OpenRouter 配置            │
│       → visionModel: "google/gemini-2.5-flash"          │
│       → embeddingModel: "qwen/qwen3-embedding-8b"       │
│       → rateLimitRPM: 30                                │
│                                                         │
│ 无 Key: 后台触发 get-cloud-key 重新分配                  │
└────────────────────┬────────────────────────────────────┘
                     │ 失败 / 不满足条件
                     ▼
┌─────────────────────────────────────────────────────────┐
│ 优先级 2: 文件/环境变量 Key                              │
│                                                         │
│ 来源: APIKeyManager.resolveAPIKey()                     │
│   a. 配置文件 (~/.config/findit/{provider}-api-key.txt) │
│   b. 环境变量 (GEMINI_API_KEY / OPENROUTER_API_KEY)     │
│                                                         │
│ 效果: isUsingSubscriptionKey = false                    │
│       → ProviderConfig 使用用户自定义设置               │
└────────────────────┬────────────────────────────────────┘
                     │ 失败
                     ▼
┌─────────────────────────────────────────────────────────┐
│ 无 API Key                                              │
│                                                         │
│ 效果: resolvedAPIKey = nil                              │
│       → cloudMode=cloud 自动降级为 local 行为            │
│       → L1 (CLIP) + L2 (STT) 正常                      │
│       → L3 Vision: LocalVLM (opt-in) 或跳过             │
│       → L3 Embedding: EmbeddingGemma (本地) 或跳过      │
└─────────────────────────────────────────────────────────┘
```

---

## 9. 安全策略

### 9.1 Row Level Security (RLS)

所有 4 张表均启用 RLS:

| 表 | SELECT | INSERT/UPDATE/DELETE |
|---|---|---|
| profiles | `auth.uid() = id` | service_role only (Edge Functions) |
| subscriptions | `auth.uid() = user_id` | service_role only |
| openrouter_keys | `auth.uid() = user_id` | service_role only |
| usage_logs | `auth.uid() = user_id` | service_role only |

用户只能查看自己的数据。所有写操作通过 Edge Functions 的 admin client (service_role) 执行。

### 9.2 JWT 认证

- 6/7 Edge Functions 通过 JWT 认证（`getUser()` 验证 Authorization header）
- `stripe-webhook` 使用 Stripe Webhook Signature 认证（部署时 `--no-verify-jwt`）
- `checkout-result` 是公开静态页面（`--no-verify-jwt`）
- Supabase Swift SDK 自动管理 JWT 刷新

### 9.3 Keychain 安全

- OpenRouter API Key 仅存在 macOS Keychain
- `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: 锁屏不可读，不同步 iCloud
- 退出登录时主动删除

### 9.4 URL 安全

- 所有 Stripe 重定向 URL 在服务端硬编码
- 客户端不能传入自定义 URL（防钓鱼）
- `checkout-result` 页面是只读 HTML，无 XSS 风险

### 9.5 OpenRouter Key 隔离

- 每个用户一个独立 Key（带预算限制）
- Management API 使用管理员 Key（仅在 Edge Functions 环境变量中）
- 用户的 Key 只能调用 AI API，不能管理其他 Key
- DB 不存储完整 Key（仅 hash 和 prefix）

### 9.6 CORS

```
Access-Control-Allow-Origin: *
Access-Control-Allow-Headers: authorization, x-client-info, apikey, content-type
```

> 当前允许所有 origin。生产环境应限制为 App 专用 User-Agent 或使用 API Gateway。

---

## 10. 部署指南

### 10.1 Edge Function 部署命令

```bash
# 前提: Supabase CLI 已安装并登录
# ~/.local/bin/supabase (或 npx supabase)

# 大部分函数使用默认部署（JWT 验证）
~/.local/bin/supabase functions deploy on-user-created
~/.local/bin/supabase functions deploy check-subscription
~/.local/bin/supabase functions deploy get-cloud-key
~/.local/bin/supabase functions deploy create-checkout
~/.local/bin/supabase functions deploy manage-billing

# Stripe Webhook: 不验证 JWT（Stripe 用自己的签名验证）
~/.local/bin/supabase functions deploy stripe-webhook --no-verify-jwt

# Checkout Result: 公开页面（无需认证）
~/.local/bin/supabase functions deploy checkout-result --no-verify-jwt
```

### 10.2 Supabase Secrets

通过 CLI 设置:
```bash
~/.local/bin/supabase secrets set OPENROUTER_MANAGEMENT_KEY="sk-or-v1-..."
~/.local/bin/supabase secrets set STRIPE_SECRET_KEY="sk_test_..."
~/.local/bin/supabase secrets set STRIPE_PRO_PRICE_ID="price_..."
~/.local/bin/supabase secrets set STRIPE_WEBHOOK_SECRET="whsec_..."
```

**自动提供的环境变量（无需手动设置）:**
- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`

### 10.3 Supabase Dashboard 配置清单

在 `https://supabase.com/dashboard/project/xbuyfrzfmyzrioqhnmov` 中:

| 配置项 | 位置 | 当前值 | 推荐值 |
|---|---|---|---|
| Minimum Password Length | Auth > Settings | 6 | **8** |
| Site URL | Auth > URL Configuration | (默认) | `https://findit.app` |
| Redirect URLs | Auth > URL Configuration | (无) | `findit://auth-callback` |
| Email Confirmations | Auth > Email Auth | 关闭 | **上线前开启** |
| Custom SMTP | Auth > SMTP Settings | 未配置 | **Resend / SendGrid** |
| Email Templates | Auth > Email Templates | 默认 | **自定义中文模板** |
| Captcha | Auth > Captcha | 关闭 | **上线前启用 Turnstile** |

### 10.4 数据库迁移

```bash
# 推送迁移到远程数据库
~/.local/bin/supabase db push

# 查看迁移状态
~/.local/bin/supabase migration list
```

当前迁移文件: `supabase/migrations/20260213180321_create_findit_schema.sql`

---

## 11. 已知问题和限制

### 11.1 SPM 构建限制

- **无 Info.plist**: SPM 可执行文件无法注册 `findit://` URL scheme
- **影响**: Stripe 回调无法直接跳回 App
- **现有方案**: 使用 checkout-result 网页 + didBecomeActive 刷新
- **长期方案**: 迁移到 Xcode 项目后通过 Info.plist 注册 URL scheme

### 11.2 邮件配置

- **SMTP 未配置**: 远程 Supabase 项目尚未配置自定义 SMTP
- **影响**: 密码重置邮件可能使用 Supabase 默认发送器（有速率限制）
- **Email Confirmations 关闭**: 任何人可用任意邮箱注册获取 Trial

### 11.3 Trial 过期惰性触发

- Trial 过期仅在 `check-subscription` 被调用时检测
- 如果用户注册后从不打开 App，OpenRouter Key 不会被禁用
- **兜底**: $1 月限额 + OpenRouter monthly reset

### 11.4 CORS 宽松

- `Access-Control-Allow-Origin: *` 允许所有来源
- 生产环境应限制

### 11.5 Apple Sign-In 未启用

- 代码已预留 `signInWithApple` 方法
- 需要 Apple Developer 代码签名才能使用
- SPM 构建不支持 Sign in with Apple entitlements

### 11.6 OpenRouter 孤儿 Key

- 如果 `on-user-created` 中创建了 OpenRouter Key 但 DB 写入失败
- 已有清理逻辑: 尝试 `deleteKey(hash)`
- 但如果清理也失败，会残留一个未使用的 Key
- **风险低**: Key 有 $1 限额，且不关联任何用户

### 11.7 SettingsView 高级 Tab

- 订阅模式下 Provider/Model 控件被禁用 + 半透明
- 但底层 ProviderConfig 值仍然保留（用户切回非订阅模式时恢复）

---

## 12. 未来计划

### 12.1 上线前必须完成

| 任务 | 优先级 | 说明 |
|---|---|---|
| 配置 SMTP | 🔴 高 | 在 Dashboard 中配置 Resend 或 SendGrid |
| 启用 Email Confirmations | 🔴 高 | 防止 Trial 滥用 |
| 自定义邮件模板 | 🟡 中 | 中文确认/重置模板 |
| Minimum Password → 8 | 🟡 中 | Dashboard Auth 设置 |
| 端到端测试 | 🔴 高 | 注册→索引→支付→取消 完整流程 |
| CORS 限制 | 🟡 中 | 收窄 Allow-Origin |

### 12.2 短期优化

| 任务 | 说明 |
|---|---|
| pg_cron Trial 过期扫描 | 每天凌晨扫描过期 trial 并禁用 Key |
| hCaptcha / Turnstile | 防 bot 注册 |
| Stripe 生产模式 | 切换到 live mode keys |
| Usage 仪表板 | App 内显示更详细的用量分析 |
| 自定义域名 | `https://findit.app` 作为 site_url |

### 12.3 中期功能

| 任务 | 说明 |
|---|---|
| Apple Sign-In | 需要 Xcode 项目 + Apple Developer 会员 |
| URL Scheme 注册 | 迁移到 Xcode 项目后通过 Info.plist 注册 `findit://` |
| FindIt Cloud Proxy | 自建 AI API 代理，替代 OpenRouter（降低成本） |
| 年付计划 | $99/年 (比月付节省约 17%) |
| Team/Enterprise 计划 | 多用户共享预算 |
| Usage Alerts | 接近预算限额时推送通知 |

### 12.4 长期规划

| 任务 | 说明 |
|---|---|
| 完全迁移到 Xcode 项目 | 获得 Info.plist、Entitlements、代码签名、公证 |
| Mac App Store 分发 | 需要代码签名 + 沙盒 + StoreKit 2 |
| StoreKit 2 替代 Stripe | App Store 支付 (30% 抽成) vs Stripe (2.9%) |
| 多平台 | iOS / iPadOS 版本 |

---

## 附录 A: 文件索引

### Supabase 后端

| 文件 | 说明 |
|---|---|
| `supabase/config.toml` | 本地开发配置 |
| `supabase/migrations/20260213180321_create_findit_schema.sql` | 数据库 Schema |
| `supabase/functions/on-user-created/index.ts` | 新用户初始化 |
| `supabase/functions/check-subscription/index.ts` | 订阅状态查询 |
| `supabase/functions/get-cloud-key/index.ts` | Key 重新分配 |
| `supabase/functions/create-checkout/index.ts` | Stripe Checkout |
| `supabase/functions/stripe-webhook/index.ts` | Stripe Webhook |
| `supabase/functions/manage-billing/index.ts` | Stripe Portal |
| `supabase/functions/checkout-result/index.ts` | 支付结果页 |
| `supabase/functions/_shared/supabase.ts` | Supabase 客户端工厂 |
| `supabase/functions/_shared/openrouter.ts` | OpenRouter API 封装 |
| `supabase/functions/_shared/cors.ts` | CORS 工具 |

### Swift 客户端

| 文件 | 说明 |
|---|---|
| `Sources/FindItApp/FindItApp.swift` | App 入口，Environment 注入 |
| `Sources/FindItApp/Auth/AuthManager.swift` | Supabase Auth 管理 |
| `Sources/FindItApp/Auth/SubscriptionManager.swift` | 订阅状态管理 |
| `Sources/FindItCore/Cloud/CloudKeyManager.swift` | Keychain API Key 管理 |
| `Sources/FindItCore/Pipeline/APIKeyManager.swift` | 文件/环境变量 Key 管理 |
| `Sources/FindItCore/Pipeline/ProviderConfig.swift` | API Provider 配置 |
| `Sources/FindItCore/Pipeline/IndexingOptions.swift` | 索引选项 (CloudMode) |
| `Sources/FindItApp/IndexingManager.swift` | 索引管理 (Key 解析 + Config 覆盖) |
| `Sources/FindItApp/Views/LoginSheet.swift` | 登录/注册 UI |
| `Sources/FindItApp/Views/SettingsView.swift` | 设置页 (账户 + 高级) |
| `Sources/FindItApp/ContentView.swift` | 主界面 (横幅 + 初始化) |

---

## 附录 B: 环境变量汇总

### Edge Functions (Supabase Secrets)

| 变量名 | 用途 | 设置方式 |
|---|---|---|
| `SUPABASE_URL` | Supabase API URL | 自动提供 |
| `SUPABASE_ANON_KEY` | 匿名 Key | 自动提供 |
| `SUPABASE_SERVICE_ROLE_KEY` | Service Role Key | 自动提供 |
| `OPENROUTER_MANAGEMENT_KEY` | OpenRouter 管理 Key | `supabase secrets set` |
| `STRIPE_SECRET_KEY` | Stripe API Key | `supabase secrets set` |
| `STRIPE_PRO_PRICE_ID` | Pro 价格 ID | `supabase secrets set` |
| `STRIPE_WEBHOOK_SECRET` | Webhook 签名密钥 | `supabase secrets set` |

### 客户端 (可选，CLI 用)

| 变量名 | 用途 |
|---|---|
| `GEMINI_API_KEY` | Gemini API Key (非订阅用户) |
| `OPENROUTER_API_KEY` | OpenRouter API Key (非订阅用户) |
