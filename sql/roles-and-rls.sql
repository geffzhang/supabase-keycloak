-- 方案 B（Keycloak 为唯一用户源）的数据库侧约定。
--
-- ┌─ 选方案 B 的前提必须先明确 ───────────────────────────────────┐
-- │ 用户的唯一权威来源是 Keycloak。auth.users 在方案 B 下是空表，  │
-- │ Supabase Auth 只是一个"没被使用的组件"。因此：                 │
-- │   · 不要写 references auth.users(id) 的外键                    │
-- │   · 不要用 auth.users 的 trigger 做业务初始化                  │
-- │   · Dashboard 的用户列表里看不到任何业务用户                   │
-- └──────────────────────────────────────────────────────────────┘

-- ── 1. 用户镜像表（可选）────────────────────────────────────────
-- 只在需要「按邮箱搜人」「显示作者名」这类 UI 时才建。
-- 权威数据仍在 Keycloak；这张表是可重建的投影，允许脏。
create table if not exists public.app_users (
  subject      text primary key,          -- JWT 的 sub，Keycloak 用户 UUID
  email        text,
  display_name text,
  synced_at    timestamptz not null default now()
);

alter table public.app_users enable row level security;

drop policy if exists "app_users_read_all" on public.app_users;
create policy "app_users_read_all"
  on public.app_users for select
  to authenticated
  using (true);

revoke insert, update, delete on public.app_users from authenticated, anon;

-- ── 2. 角色 ─────────────────────────────────────────────────────
-- Keycloak 的 realm role / group 不会变成 Postgres 角色。
-- 进库的 role 永远是 authenticated，业务角色只能用表 + claim 表达。
create table if not exists public.user_roles (
  subject     text primary key,
  app_role    text not null default 'user'
              check (app_role in ('user', 'admin')),
  updated_at  timestamptz not null default now()
);

alter table public.user_roles enable row level security;

drop policy if exists "user_roles_self_read" on public.user_roles;
create policy "user_roles_self_read"
  on public.user_roles for select
  to authenticated
  using (subject = (select auth.jwt() ->> 'sub'));

revoke insert, update, delete on public.user_roles from authenticated, anon;

-- 幂等 upsert，供后端登录钩子调用（security definer 绕过 RLS）
create or replace function public.sync_app_role(
  p_subject text,
  p_email   text,
  p_role    text
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_role not in ('user', 'admin') then
    raise exception 'invalid app_role: %', p_role;
  end if;

  insert into public.user_roles (subject, app_role, updated_at)
  values (p_subject, p_role, now())
  on conflict (subject) do update
    set app_role   = excluded.app_role,
        updated_at = now();

  insert into public.app_users (subject, email, synced_at)
  values (p_subject, p_email, now())
  on conflict (subject) do update
    set email     = excluded.email,
        synced_at = now();
end;
$$;

revoke all on function public.sync_app_role(text, text, text) from public, anon, authenticated;
grant execute on function public.sync_app_role(text, text, text) to service_role;

-- 判断当前请求者是否管理员。表查询比在每个 policy 里内联 exists 更好读。
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.user_roles
    where subject = (select auth.jwt() ->> 'sub')
      and app_role = 'admin'
  );
$$;

grant execute on function public.is_admin() to authenticated, anon;

-- ── 3. 业务表与 RLS 的正确写法 ──────────────────────────────────
-- 归属列用 text 存 sub，不要 uuid：
--   Keycloak 自建用户的 sub 是 UUID，但导入用户 / 外部 user storage
--   可能是 "f:provider:xxx" 形态，uuid 列会在那种租户上直接炸。
--
--   create table public.todos (
--     id         uuid primary key default gen_random_uuid(),
--     owner_sub  text not null,
--     title      text not null
--   );
--   alter table public.todos enable row level security;
--
--   create policy "todos_own" on public.todos
--     for all to authenticated
--     using      (owner_sub = (select auth.jwt() ->> 'sub'))
--     with check (owner_sub = (select auth.jwt() ->> 'sub'));
--
--   create policy "todos_admin" on public.todos
--     for all to authenticated
--     using (public.is_admin());

-- ── 4. 两个必须避开的坑 ────────────────────────────────────────

-- 坑一：不要用 auth.uid()
--   auth.uid() 把 sub 转 uuid，sub 不是 UUID 时抛异常而非返回 null，
--   整条请求 500。统一用 (select auth.jwt() ->> 'sub')。
--   外层 select 让 Postgres 走 InitPlan 缓存，否则每个 policy
--   都会对每一行重新做一次 json 解析。

-- 坑二：storage.objects.owner 是 uuid 列
--   上传文件时 Storage 把 sub 写进 owner(uuid)，sub 不是 UUID 时直接 500：
--     invalid input syntax for type uuid
--   这是 storage 自身实现（migration 0017 只删了外键，没改列类型），
--   改列类型官方明确不建议——升级时会被覆盖回去。
--   所以方案 B 要求 Keycloak 用户的 sub 必须是 UUID，
--   verify.sh 第 4b 步专门检查这一条。
--
--   文件归属推荐做法：bucket 内用 <sub>/... 分目录，
--   RLS 比对 owner_id（text 列，0018 起存在）而不是 owner：
--     create policy "own files" on storage.objects
--       for select to authenticated
--       using (bucket_id = 'private'
--              and owner_id = (select auth.jwt() ->> 'sub'));

-- ── 5. 用户被删除时 ────────────────────────────────────────────
-- Keycloak 删用户后，已签发的 token 在 exp 前仍然有效
-- （默认 5 分钟，取决于 accessTokenLifespan）。
-- 需要"立刻禁用"就要在 RLS 里再查一次状态表，
-- 不能只靠"删掉 Keycloak 用户"。
