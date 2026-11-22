# 自托管 Supabase 对接 Keycloak（用户由 Keycloak 统一管理）

**推荐方案：B —— PostgREST / Storage / Realtime 直接信任 Keycloak 签发的 JWT。**
Token 由 Keycloak 签发、Supabase 只验不签，`auth.users` 保持空表，
用户只有一个权威源。

方案 A（GoTrue 换发 token）在文末保留说明，**但它和"用户统一在 Keycloak"
的要求冲突**：会让 GoTrue 在 `auth.users` 里建一份用户镜像，等于双份用户。

## 为什么必须选 B

| | 方案 A（GoTrue 包一层）| 方案 B（推荐）|
|---|---|---|
| 用户存储在哪 | `auth.users` 一份 + Keycloak 一份 | 只在 Keycloak |
| Keycloak 删用户 | `auth.users` 仍留着，要另外清 | 立刻是唯一真相 |
| 改密码 / 加角色 | 要和 GoTrue 同步 | Keycloak 一处生效 |
| 用户列表 | 两处，且会不一致 | 一处 |
| 代价 | Auth 全套功能可用 | 失去 GoTrue 的会话/MFA/踢人 |

既然要求"用户由 Keycloak 统一管理"，A 的双份存储就是必须付的代价，所以选 B。

## 快速开始

三步，全部随机化密钥，不需要手工填 `.env`。

```bash
# 1) 生成 .env：随机化所有口令，并用新的 JWT_SECRET 重签 ANON/SERVICE_ROLE
./scripts/init-env.sh

# 2) 起 Keycloak + Supabase（自动处理顺序依赖、合并 JWKS、等健康）
./scripts/start.sh

# 3) 端到端验证
KC_TEST_USER=demo KC_TEST_PASS=demo-password-change-me \
KEYCLOAK_CLIENT_ID=supabase-verify \
SUPABASE_URL=http://localhost:8000 \
SUPABASE_KEY=$(grep '^ANON_KEY=' .env | cut -d= -f2) \
KEYCLOAK_HOST=localhost:8081 KC_SCHEME=http \
./scripts/verify.sh b
```

期望最后一行是 `全部通过`。首次启动约 3–5 分钟（db 要跑几十个 init-script）。

**`start.sh` 做了什么**（顺序是硬依赖）：

1. 校验 `.env` 无重复键 —— 两份模板拼接会让空值覆盖有效值，导致全站 401
2. 起 Keycloak，等 `/health/ready`（在 **9000** 管理口，不是 8081）
3. `sync-jwks.sh` 把 Keycloak 公钥 + `JWT_SECRET` 的 oct 密钥**合并**成 JWKS
4. 先单独起 db 并等健康，再起其余服务（避免 `depends_on` 卡在 db unhealthy）
5. 等 rest / storage / realtime 健康

**服务地址**：Supabase API `http://localhost:8000`（Studio 同址，Basic Auth 密码见
`.env` 的 `DASHBOARD_PASSWORD`）、Keycloak `http://localhost:8081`（管理员见 `.env`）。

realm 会自动导入，含 seed 用户 `demo`（口令 `demo-password-change-me`）与
`supabase-verify` client（**仅供本地验证脚本，生产请删**）。

## 文件

| 文件 | 作用 |
|---|---|
| `docker-compose.yml` | **官方基线原样副本**（supabase@4ead4b0），不要改它 |
| `volumes/` | 官方挂载文件（envoy / db 初始化 / realtime 等 25 个）|
| `env.template` | 官方 `.env.example` 副本，`init-env.sh` 以它为基线 |
| `BASELINE.txt` | 基线版本与升级步骤 |
| `docker-compose.keycloak.yml` | Keycloak + 自己的 Postgres，可独立 `up` |
| `docker-compose.supabase-thirdparty.yml` | **方案 B**：rest/storage/realtime 注入 JWKS |
| `docker-compose.supabase-auth.yml` | 方案 A 用（本场景不需要，保留备查）|
| `keycloak/realm-supabase.json` | 可导入 realm：两个 client、claim mapper、固定 UUID 的 demo 用户 |
| `scripts/init-env.sh` | 从官方模板生成 `.env`：随机化密钥、重签 ANON/SERVICE_ROLE、自检 |
| `scripts/start.sh` | 一键启动，处理顺序依赖与健康等待 |
| `scripts/sync-jwks.sh` | **合并** Keycloak 公钥 + legacy HS256 写入 `.env` |
| `scripts/verify.sh` | 端到端验证（`b`），含 sub 形态与 anon 存活判据 |
| `scripts/wait-keycloak.sh` | 探 `/health/ready`（镜像里没有 curl，从宿主机探）|
| `sql/roles-and-rls.sql` | 角色表、`is_admin()`、RLS 写法与两个坑 |

## 四条一旦搞错就很难查的坑

### 1. JWKS 必须"合并"，不能只放 Keycloak 公钥

这是实际踩到的。`supabase-js` 每个请求带两个头：

```
apikey: <ANON_KEY>              ← HS256 JWT，用 JWT_SECRET 签的
Authorization: Bearer <token>   ← 用户 token（这里才是 Keycloak 签的）
```

如果把 `PGRST_JWT_SECRET` 整个换成 Keycloak 的 JWKS，PostgREST / Storage /
Realtime 就再也验不过 `anon` 和 `service_role` 这两把 HS256 密钥了 ——
未登录请求 401、Dashboard 打不开、后端 service_role 全废。现象特别像
"Keycloak 配错了"，其实是把自己家的钥匙丢了。

`sync-jwks.sh` 会把 `JWT_SECRET` 转成 RFC 7517 的 `oct` 密钥并入 JWKS：

```json
{"keys":[
  {"kid":"...","kty":"RSA","alg":"RS256", "...":"..."},        // 验 Keycloak 用户 token
  {"kty":"oct","k":"<base64url(JWT_SECRET)>","alg":"HS256"}     // 验 anon/service_role
]}
```

`verify.sh` 第 4c 步用 anon key 打一次 REST 来守住这条。

### 2. Keycloak 用户的 sub 必须是 UUID

`storage.objects.owner` 是 **`uuid`** 列（migration `0017` 只删了外键，
没改列类型；`0018` 另外加了 `owner_id text` 用来取代它）。
sub 不是 UUID 时上传文件直接：

```
500 invalid input syntax for type uuid: "auth0|user_abc123"
```

Keycloak 自建用户的 sub 天生是 UUID v4，默认没问题；风险在**导入用户**
或用外部 user storage（sub 会变成 `f:provider:xxx`）。
`verify.sh` 第 4b 步检查这一条。

realm JSON 里给 demo 用户固定了 id，避免重新导入时 UUID 漂移导致
`owner` 对不上：

```json
"id": "d0000000-0000-4000-8000-000000000001"
```

### 3. JWKS 是启动时快照，不会自动刷新

Cloud 上的 Third-Party Auth 会周期去拉 `jwks_uri`；**自托管不会**。
Keycloak 轮换密钥后旧 kid 的 token 立刻 401。轮换流程：

```bash
./scripts/sync-jwks.sh
docker compose -f docker-compose.yml -f docker-compose.supabase-thirdparty.yml \
  up -d --force-recreate rest storage realtime
```

`restart` 不算，它不重读环境变量。

### 4. issuer 不能带 `/auth`

Keycloak 17 之后路径前缀去掉了。`https://kc/auth/realms/x` 会 404，
正确是 `https://kc/realms/x`。而 `KC_HOSTNAME`（compose 里的 `--hostname`）
决定 token 里的 `iss`，写成容器内地址会导致"验签通过但 iss 对不上"，
表现为莫名其妙的 401。反代后面必须 `--proxy-headers=xforwarded`，
且 `.env` 里的 `KEYCLOAK_HOST` 与浏览器地址栏逐字一致。

`verify.sh` 第 1 步会拒掉带 `/auth` 的 issuer。

## 客户端怎么接

方案 B 下**不要**用 `supabase.auth.*` 登录，登录完全交给 Keycloak：

```ts
import Keycloak from 'keycloak-js'
import { createClient } from '@supabase/supabase-js'

const kc = new Keycloak({
  url: 'https://kc.example.com',
  realm: 'supabase',
  clientId: 'supabase-spa',   // public client，PKCE
})
await kc.init({ onLoad: 'login-required', pkceMethod: 'S256' })

const supabase = createClient(
  'https://supabase.example.com',
  '<anon key>',
  {
    // 关键：用 accessToken 函数，不要手写 Authorization 头
    accessToken: async () => kc.token ?? null,
  }
)
```

三点注意：

- **别用 `supabase.auth.getUser()`** —— 它只认 GoTrue 自己签的 token。
  要验身份用 `kc.tokenParsed`，或在后端用 JWKS 自己验。
- **`signOut()` 对 Keycloak 无效**，只清 Supabase 侧本地状态。
  真登出要走 `kc.logout()`（Keycloak 的 `end_session_endpoint`）。
- 若同一前端还要用 Supabase Auth，必须加限制性策略防 sub 撞车；
  只部署 Keycloak 则不需要。

## 角色与 RLS

Keycloak 的 `app_admin` **不会**变成 Postgres 角色。进库的 role 永远是
`authenticated`，写成 `to app_admin` 会报 `role "app_admin" does not exist`。
正确做法见 `sql/roles-and-rls.sql`：建 `user_roles` 表 + `is_admin()` 函数。

另外**不要用 `auth.uid()`**：sub 不是合法 UUID 时它抛异常而不是返回 null。
统一用 `(select auth.jwt() ->> 'sub')`，外层 `select` 是为了走 InitPlan 缓存
（否则每个 policy 对每行都要重新解析一次 json）。

## 登出与"立刻禁用"

Keycloak 删用户后，**已签发的 token 在 `exp` 前仍然有效**
（`accessTokenLifespan` 默认 300 秒）。要立刻生效需要：

- 把 `accessTokenLifespan` 调短（代价是刷新更频繁），或
- 在 RLS 里再查一次状态表 / 黑名单

不能只靠"删掉 Keycloak 用户"。

---

## 附：为什么方案 A 不适合本场景

方案 A 让 GoTrue 把 Keycloak 当成一个 OIDC provider
（`GOTRUE_EXTERNAL_KEYCLOAK_*`），登录后 GoTrue 换发自己的 JWT。
好处是 `auth.uid()`、会话管理、MFA 都能用。

但它会在 `auth.users` 里建一份用户记录 —— 这就是双份用户存储：

- Keycloak 改名 / 改邮箱，`auth.users` 不会自动跟着变
- Keycloak 删用户，`auth.users` 里仍然留着，要另外清
- 用户列表、角色以哪边为准会变成长期的口径问题

将来若因为要 MFA / 会话吊销而考虑切回 A，那是架构变更而非配置调整。
配置片段留在 `docker-compose.supabase-auth.yml` 备查。
