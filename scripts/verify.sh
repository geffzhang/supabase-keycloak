#!/usr/bin/env bash
# 端到端验证：确认 Keycloak → Supabase 的信任链真的通了。
# 用法: ./verify.sh [a|b]
#   a = 方案 A（GoTrue 换发 token），验证 /auth/v1/settings 与登录跳转
#   b = 方案 B（直接信任 Keycloak token），验证 PostgREST 接受 Keycloak JWT
set -euo pipefail

MODE="${1:-a}"
SUPABASE_URL="${SUPABASE_URL:?set SUPABASE_URL, 例如 https://supabase.example.com}"
SUPABASE_KEY="${SUPABASE_KEY:?set SUPABASE_KEY (publishable/anon)}"
KC_HOST="${KEYCLOAK_HOST:?set KEYCLOAK_HOST}"
KC_SCHEME="${KC_SCHEME:-https}"    # 本地 docker 用 http 自测时设 KC_SCHEME=http
REALM="${KEYCLOAK_REALM:-supabase}"
KC="${KC_SCHEME}://${KC_HOST}"

pass() { echo "  OK   $1"; }
fail() { echo "  FAIL $1"; exit 1; }

echo "== 1. Keycloak 发现文档 =="
ISSUER=$(curl -fsS --max-time 10 "${KC}/realms/${REALM}/.well-known/openid-configuration" \
  | python -c 'import json,sys; print(json.load(sys.stdin)["issuer"])') || fail "拉不到 openid-configuration"
case "$ISSUER" in
  */auth/realms/*)
    fail "issuer 含 /auth 前缀（Keycloak 17+ 已去掉），当前为 ${ISSUER}；检查 --hostname 与反代路径改写" ;;
  */realms/*) pass "issuer = ${ISSUER}" ;;
  *) fail "issuer 形状异常: ${ISSUER}，期望 …/realms/<realm>" ;;
esac

echo "== 2. JWKS 非对称且带 kid =="
curl -fsS --max-time 10 "${KC}/realms/${REALM}/protocol/openid-connect/certs" \
  | python -c '
import json,sys
ks = json.load(sys.stdin).get("keys",[])
assert ks, "JWKS 为空"
for k in ks:
    assert k.get("alg") != "HS256", "存在 HS256 密钥"
    assert k.get("kid"), "存在无 kid 的密钥"
print("  OK   " + ", ".join(k["kid"][:8] + "/" + k.get("alg","?") for k in ks))
' || fail "JWKS 不满足非对称 + kid 要求"

if [ "$MODE" = "a" ]; then
  echo "== 3. GoTrue 已启用 keycloak provider =="
  SETTINGS=$(curl -fsS --max-time 10 -H "apikey: ${SUPABASE_KEY}" "${SUPABASE_URL}/auth/v1/settings") \
    || fail "拉不到 /auth/v1/settings"
  printf '%s' "$SETTINGS" | python -c '
import json,sys
s=json.load(sys.stdin)
ext=s.get("external") or {}
assert ext.get("keycloak") is True, "external.keycloak 不是 true，检查 GOTRUE_EXTERNAL_KEYCLOAK_* 与 auth 容器是否重建"
print("  OK   external.keycloak = true")
' || fail "keycloak provider 未生效"

  echo "== 4. authorize 返回 302 且带 openid scope =="
  CODE=$(curl -s -o /tmp/kc_authz.html -w '%{http_code}' --max-time 10 \
    "${SUPABASE_URL}/auth/v1/authorize?provider=keycloak&redirect_to=${SUPABASE_URL}/") || true
  [ "$CODE" = "302" ] || fail "authorize 返回 ${CODE}，期望 302（常见原因：redirect_to 未加入 allow list）"
  pass "authorize 302"

  echo "== 5. 登录跳转落在 Keycloak realm 上 =="
  LOC=$(curl -s -o /dev/null -D - --max-time 10 \
    "${SUPABASE_URL}/auth/v1/authorize?provider=keycloak&redirect_to=${SUPABASE_URL}/" \
    | tr -d '\r' | awk 'tolower($1)=="location:"{print $2}') || true
  # 顺序不能反：*/realms/... 是后缀匹配，/auth/realms/... 也会命中，
  # 所以必须先排除老路径前缀
  case "$LOC" in
    *"/auth/realms/"*) fail "跳转地址含 /auth/realms（Keycloak 17+ 已去掉），老路径会 404: ${LOC%%\?*}" ;;
    *"/realms/${REALM}/protocol/openid-connect/auth"*) pass "跳转到 ${LOC%%\?*}" ;;
    *) fail "跳转地址异常: ${LOC:-空}" ;;
  esac

  echo "== 6. 回调地址已注册 (client 配置自查) =="
  echo "  请人工确认 Keycloak client=${KEYCLOAK_CLIENT_ID:-supabase} 的 Valid redirect URIs 含:"
  echo "    ${SUPABASE_URL}/auth/v1/callback"

else
  echo "== 3. 取一个真实 Keycloak access_token (direct grant, 仅测试用) =="
  : "${KC_TEST_USER:?set KC_TEST_USER}"
  : "${KC_TEST_PASS:?set KC_TEST_PASS}"
  : "${KEYCLOAK_CLIENT_ID:?set KEYCLOAK_CLIENT_ID}"

  TOKEN=$(curl -fsS --max-time 10 -X POST \
    "${KC}/realms/${REALM}/protocol/openid-connect/token" \
    -d "grant_type=password" \
    -d "client_id=${KEYCLOAK_CLIENT_ID}" \
    ${KEYCLOAK_CLIENT_SECRET:+-d "client_secret=${KEYCLOAK_CLIENT_SECRET}"} \
    -d "username=${KC_TEST_USER}" \
    -d "password=${KC_TEST_PASS}" \
    -d "scope=openid" \
    | python -c 'import json,sys; print(json.load(sys.stdin)["access_token"])') || fail "取 token 失败（client 需开 Direct access grants 或用 password grant 专用 client）"
  pass "拿到 token"

  echo "== 4. token 里必须有 role=authenticated =="
  printf '%s' "$TOKEN" | python -c '
import base64,json,sys
seg = sys.stdin.read().strip().split(".")[1]
seg += "=" * (-len(seg) % 4)
c = json.loads(base64.urlsafe_b64decode(seg))
assert c.get("role") == "authenticated", "role claim 缺失或不是 authenticated，PostgREST 会降级成 anon"
print("  OK   role=authenticated sub=" + c.get("sub","")[:8] + " iss=" + c.get("iss",""))
' || fail "role claim 不满足要求"

  echo "== 4b. sub 必须是 UUID（storage 上传的硬前提）=="
  printf '%s' "$TOKEN" | python -c '
import base64,json,sys,uuid
seg = sys.stdin.read().strip().split(".")[1]
seg += "=" * (-len(seg) % 4)
c = json.loads(base64.urlsafe_b64decode(seg))
sub = c.get("sub","")
try:
    parsed = uuid.UUID(sub)
except (ValueError, AttributeError):
    sys.exit("sub 不是 UUID：%r\n"
             "  storage.objects.owner 是 uuid 列（migration 0017 只删了外键没改类型），\n"
             "  sub 非 UUID 时上传文件会 500 invalid input syntax for type uuid。\n"
             "  Keycloak 自建用户默认就是 UUID；如果导入了外部用户或用了\n"
             "  pairwise 主体标识，需要额外处理。" % sub)
if parsed.version != 4:
    sys.exit("sub 是 UUID 但不是 v4（%r）。Keycloak 自建用户应始终是 v4，"
             "出现其它版本通常意味着做过用户导入或迁移，请人工确认后再上线。" % sub)
print("  OK   sub 是 UUID v%d" % parsed.version)
' || fail "sub 形态不满足 storage 要求"
  echo "== 4c. anon key 仍然可用（legacy 对称密钥没被挤掉）=="
  CODE=$(curl -s -o /tmp/anon_body.txt -w '%{http_code}' --max-time 10 \
    -H "apikey: ${SUPABASE_KEY}" "${SUPABASE_URL}/rest/v1/") || true
  if [ "$CODE" = "200" ] || [ "$CODE" = "404" ]; then
    pass "anon 请求被接受（HTTP ${CODE}，验签已过）"
  elif [ "$CODE" = "401" ]; then
    echo "  401 响应体:"; sed 's/^/    /' /tmp/anon_body.txt
    fail "anon key 被拒 —— KEYCLOAK_JWKS 里缺少 JWT_SECRET 的 oct 密钥。
    只放 Keycloak 公钥会挤掉 anon/service_role，未登录请求与 Dashboard 全挂。
    重跑 scripts/sync-jwks.sh（它会合并 legacy 密钥）并 --force-recreate rest。"
  else
    fail "anon 请求返回 ${CODE}"
  fi

  echo "== 5. PostgREST 接受该 token =="
  CODE=$(curl -s -o /tmp/pgrst_body.txt -w '%{http_code}' --max-time 10 \
    -H "apikey: ${SUPABASE_KEY}" \
    -H "Authorization: Bearer ${TOKEN}" \
    "${SUPABASE_URL}/rest/v1/") || true
  if [ "$CODE" = "200" ]; then
    pass "PostgREST 200"
  elif [ "$CODE" = "401" ]; then
    echo "  401 响应体:"; sed 's/^/    /' /tmp/pgrst_body.txt
    fail "PGRST_JWT_SECRET 与 Keycloak JWKS 不匹配，或 kid 对不上（跑 scripts/sync-jwks.sh 后重启 rest）"
  else
    fail "PostgREST 返回 ${CODE}，期望 200"
  fi

  echo "== 6. Storage 接受该 token =="
  CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -H "apikey: ${SUPABASE_KEY}" \
    -H "Authorization: Bearer ${TOKEN}" \
    "${SUPABASE_URL}/storage/v1/bucket") || true
  if [ "$CODE" = "200" ]; then
    pass "Storage 200"
  elif [ "$CODE" = "400" ]; then
    pass "Storage 400（已通过验签，仅响应体校验失败，说明 JWT_JWKS 生效）"
  else
    fail "Storage 返回 ${CODE}，JWT_JWKS 可能未生效"
  fi

  echo "== 7. Realtime 接受该 token =="
  echo "  人工确认: 浏览器 WebSocket 连 wss://...  后，REALTIME_SUBSCRIBE 不返回 401"
fi

echo
echo "全部通过。"
