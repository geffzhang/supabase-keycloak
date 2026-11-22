#!/usr/bin/env bash
# 生成 .env：以官方模板为基线，随机化所有密钥，并补上 Keycloak 侧变量。
#
# 用法:
#   ./scripts/init-env.sh            # 生成 .env（已存在则拒绝，防误覆盖）
#   ./scripts/init-env.sh --force    # 强制重新生成（作废现有数据库与已签发 token）
#
# 关键设计：
#   1. 以 env.template（官方 .env.example 副本）为基线，覆盖全部 69 个变量。
#      不用本项目自带的精简 example —— 官方 compose 缺一个变量就静默塞空串，
#      容器起来后才发现某功能失效。
#   2. 用 sed 替换**已有键**，只对模板里没有的键用 >> 追加。
#      两份文件有 3 个同名键（JWT_SECRET/API_EXTERNAL_URL/SITE_URL），
#      Compose 读 .env 是后者覆盖前者，直接 cat >> 会让空值盖掉有效值 → 全站 401。
#   3. ANON_KEY / SERVICE_ROLE_KEY 必须用新的 JWT_SECRET 重签。
#      模板里那两把是示例 secret 签的，换 secret 后必然验签失败，
#      而网关只报 `invalid apikey`，极难定位。
#   4. 生成后自检：无重复键、ANON_KEY 能用 JWT_SECRET 验签通过。
set -euo pipefail

cd "$(dirname "$0")/.."

TEMPLATE="${TEMPLATE:-env.template}"
ENV_FILE="${ENV_FILE:-.env}"
FORCE="${1:-}"

if [ ! -f "$TEMPLATE" ]; then
  echo "找不到 $TEMPLATE。它是 supabase/supabase 仓库 docker/.env.example 的副本。" >&2
  exit 1
fi

if [ -f "$ENV_FILE" ] && [ "$FORCE" != "--force" ]; then
  echo "$ENV_FILE 已存在，拒绝覆盖。"
  echo "  想重新生成请加 --force —— 注意会作废现有数据库与已签发的 token。"
  exit 0
fi

PY=$(command -v python3 || command -v python)
[ -n "$PY" ] || { echo "需要 python3 来生成密钥" >&2; exit 1; }

# ── 1. 随机密钥 ────────────────────────────────────────────────
rand() { "$PY" -c "import secrets,sys;print(secrets.token_urlsafe(int(sys.argv[1])))" "$1"; }
alnum() { "$PY" -c "import secrets,string,sys; al=string.ascii_letters+string.digits; print(''.join(secrets.choice(al) for _ in range(int(sys.argv[1]))))" "$1"; }

JWT_SECRET=$(rand 48)
POSTGRES_PASSWORD=$(alnum 32)
DASHBOARD_PASSWORD=$(alnum 20)
# SECRET_KEY_BASE 官方给的是 64 字符 base64
SECRET_KEY_BASE=$("$PY" -c "import base64,secrets;print(base64.b64encode(secrets.token_bytes(48)).decode())")
# VAULT_ENC_KEY 必须恰好 32 字符，否则 storage 起不来
VAULT_ENC_KEY=$("$PY" -c "import secrets;print(secrets.token_hex(16))")
PG_META_CRYPTO_KEY=$(alnum 32)
LOGFLARE_PUBLIC=$(rand 32)
LOGFLARE_PRIVATE=$(rand 32)
KC_ADMIN_PW=$(alnum 18)
KC_DB_PW=$(alnum 24)

# ── 2. 用 JWT_SECRET 重签 ANON_KEY / SERVICE_ROLE_KEY ──────────
SIGNED=$(JWT_SECRET="$JWT_SECRET" "$PY" - <<'PY'
import base64, hashlib, hmac, json, os, time

secret = os.environ["JWT_SECRET"].encode()
b64 = lambda b: base64.urlsafe_b64encode(b).decode().rstrip("=")

def sign(role):
    now = int(time.time())
    header = b64(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
    payload = b64(json.dumps({
        "iss": "supabase", "iat": now,
        # 10 年。轮换只能重新生成 .env，官方示例同样是长期有效。
        "exp": now + 60 * 60 * 24 * 365 * 10, "role": role,
    }, separators=(",", ":")).encode())
    sig = hmac.new(secret, f"{header}.{payload}".encode(), hashlib.sha256).digest()
    return f"{header}.{payload}.{b64(sig)}"

print("ANON=" + sign("anon"))
print("SERVICE=" + sign("service_role"))
PY
)
ANON_KEY=$(printf '%s\n' "$SIGNED" | sed -n 's/^ANON=//p')
SERVICE_ROLE_KEY=$(printf '%s\n' "$SIGNED" | sed -n 's/^SERVICE=//p')

# ── 3. 基于模板生成，替换已有键 ────────────────────────────────
cp "$TEMPLATE" "$ENV_FILE"

# set_kv <key> <value>：只替换已有键，用 | 作分隔符避免值里的 / 冲突
set_kv() {
  local key="$1" val="$2"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    # 用 python 替换而不是 sed：值里可能有 & \ 或 | 会破坏表达式
    KEY="$key" VAL="$val" "$PY" - "$ENV_FILE" <<'PY'
import os, re, sys
path, key, val = sys.argv[1], os.environ["KEY"], os.environ["VAL"]
s = open(path, encoding="utf-8").read()
s = re.sub(r"^%s=.*$" % re.escape(key), lambda _: "%s=%s" % (key, val), s, count=1, flags=re.M)
open(path, "w", encoding="utf-8", newline="\n").write(s)
PY
  else
    printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"
  fi
}

set_kv JWT_SECRET "$JWT_SECRET"
set_kv ANON_KEY "$ANON_KEY"
set_kv SERVICE_ROLE_KEY "$SERVICE_ROLE_KEY"
set_kv POSTGRES_PASSWORD "$POSTGRES_PASSWORD"
set_kv DASHBOARD_PASSWORD "$DASHBOARD_PASSWORD"
set_kv SECRET_KEY_BASE "$SECRET_KEY_BASE"
set_kv VAULT_ENC_KEY "$VAULT_ENC_KEY"
set_kv PG_META_CRYPTO_KEY "$PG_META_CRYPTO_KEY"
set_kv LOGFLARE_PUBLIC_ACCESS_TOKEN "$LOGFLARE_PUBLIC"
set_kv LOGFLARE_PRIVATE_ACCESS_TOKEN "$LOGFLARE_PRIVATE"
# 本地默认：全部指向同一个网关端口
set_kv SUPABASE_PUBLIC_URL "http://localhost:8000"
set_kv API_EXTERNAL_URL "http://localhost:8000/auth/v1"
set_kv SITE_URL "http://localhost:3000"

# ── 4. 追加 Keycloak 侧变量（模板里没有，安全追加）──────────────
cat >> "$ENV_FILE" <<EOF

# ═══════════════════════════════════════════════════════════════
# 以下由 scripts/init-env.sh 追加：Keycloak 与本项目的粘合变量
# ═══════════════════════════════════════════════════════════════

# ── Keycloak ───────────────────────────────────────────────────
# 浏览器可直达的地址。决定 token 里的 iss，必须与
# Oidc.Authority / verify.sh 用的地址逐字一致。
KEYCLOAK_HOST=localhost:8081
# 管理口：/health/ready 在这里，不在 8081
KEYCLOAK_MGMT_PORT=9000
KEYCLOAK_REALM=supabase
KEYCLOAK_ADMIN=admin
KEYCLOAK_ADMIN_PASSWORD=${KC_ADMIN_PW}
KEYCLOAK_DB_PASSWORD=${KC_DB_PW}
KEYCLOAK_CLIENT_ID=supabase
KEYCLOAK_CLIENT_SECRET=

# verify.sh 用：本地走 http
KC_SCHEME=http

# ── 方案 B 粘合点：由 scripts/sync-jwks.sh 写入 ────────────────
# Keycloak 公钥 + 上面 JWT_SECRET 的 oct 密钥，合并后的一整个 JWKS。
# 留空时方案 B 的 rest/storage/realtime 会验签失败。
KEYCLOAK_JWKS=
EOF

chmod 600 "$ENV_FILE"

# ── 5. 自检 ───────────────────────────────────────────────────
echo "已生成 $ENV_FILE（权限 600）"
echo

FAIL=0
DUP=$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE" | sort | uniq -d)
if [ -n "$DUP" ]; then
  echo "  [FAIL] 存在重复键（后者会覆盖前者，可能导致密钥为空）：" >&2
  printf '         %s\n' $DUP >&2
  FAIL=1
else
  echo "  [OK]   无重复键"
fi

JWT_SECRET="$JWT_SECRET" ANON_KEY="$ANON_KEY" SERVICE_ROLE_KEY="$SERVICE_ROLE_KEY" "$PY" - <<'PY' || FAIL=1
import base64, hashlib, hmac, json, os, sys
secret = os.environ["JWT_SECRET"].encode()
ok = True
for name, role in (("ANON_KEY", "anon"), ("SERVICE_ROLE_KEY", "service_role")):
    tok = os.environ[name]
    parts = tok.split(".")
    if len(parts) != 3:
        print("  [FAIL] %s 不是三段式 JWT" % name); ok = False; continue
    want = base64.urlsafe_b64encode(
        hmac.new(secret, ("%s.%s" % (parts[0], parts[1])).encode(), hashlib.sha256).digest()
    ).decode().rstrip("=")
    body = parts[1] + "=" * (-len(parts[1]) % 4)
    payload = json.loads(base64.urlsafe_b64decode(body))
    good = want == parts[2] and payload.get("role") == role
    print("  [%s] %s 用 JWT_SECRET 验签%s，role=%s"
          % ("OK" if good else "FAIL", name, "通过" if want == parts[2] else "失败", payload.get("role")))
    ok = ok and good
sys.exit(0 if ok else 1)
PY

if [ "${#VAULT_ENC_KEY}" -ne 32 ]; then
  echo "  [FAIL] VAULT_ENC_KEY 长度 ${#VAULT_ENC_KEY}，必须恰好 32 字符" >&2
  FAIL=1
else
  echo "  [OK]   VAULT_ENC_KEY 为 32 字符"
fi

echo
if [ "$FAIL" -ne 0 ]; then
  echo "自检未通过，请检查上面的 FAIL 项。" >&2
  exit 1
fi

cat <<'EOF'
下一步：
  ./scripts/start.sh        # 一键起 Keycloak + Supabase
  ./scripts/verify.sh b     # 端到端验证

上线前必改：
  - KEYCLOAK_ADMIN_PASSWORD（本文件已随机生成，但建议记进你的密钥库）
  - realm 导入后改 Keycloak 里的 demo 用户口令
  - KEYCLOAK_HOST 及三个 URL 换成真实域名（必须 HTTPS）
EOF
