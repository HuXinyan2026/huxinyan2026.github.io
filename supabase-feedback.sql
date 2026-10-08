-- ============================================================
--  作品集反馈问卷 —— Supabase 现状核对 / 清理自检数据 / 收紧权限
--  项目：https://wqwxsktgeslmmfgujjxe.supabase.co
--  用法：Supabase 控制台 -> SQL Editor -> 新建查询 -> 全部粘贴 -> Run
--
--  重要：public.feedback 这张表**已经存在**，列名不是我们最初猜的那套。
--  实测出来的真实结构（用 curl 逐个列名探测 + 实际插入验证）：
--      id            (主键)
--      created_at    (默认 now())
--      user_name     text          —— 前端「称呼」字段
--      user_email    text  NULL    —— 前端「邮箱（选填）」，可以为空
--      feedback_type text  非空     —— 前端「类型」，普通 text，不是枚举
--      content       text          —— 前端「留言」
--  前端提交的 payload 就是严格这四个字段，实测返回 201 Created。
--
--  本脚本做三件事：
--    ① 删掉我做连通性验证时写进去的 6 条自检数据；
--    ② 打印当前列结构与 RLS 策略，方便你核对；
--    ③ 把匿名(anon)权限收紧到「只能新增、读不到也删不掉」。
--  整个脚本可重复执行，不会影响真实反馈数据。
-- ============================================================


-- ---------- ① 清掉自检数据（6 条，user_name 都是 '[self-test] DeepWorks'） ----------
-- 只有你在控制台 / service_role 身份下才能删（匿名 key 没有 delete 权限，这是设计使然）。
delete from public.feedback
where user_name = '[self-test] DeepWorks';


-- ---------- ② 核对真实列结构 ----------
select
  ordinal_position as pos,
  column_name,
  data_type,
  is_nullable,
  column_default
from information_schema.columns
where table_schema = 'public'
  and table_name   = 'feedback'
order by ordinal_position;


-- ---------- ③ 看当前 RLS 开关与策略 ----------
select
  c.relname                as table_name,
  c.relrowsecurity         as rls_enabled,
  c.relforcerowsecurity    as rls_forced
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname = 'feedback';

select
  policyname,
  cmd          as applies_to,
  roles,
  qual         as using_expr,
  with_check   as check_expr
from pg_policies
where schemaname = 'public' and tablename = 'feedback';


-- ---------- ④ 收紧权限：只允许匿名新增，其余全部关掉 ----------
alter table public.feedback enable row level security;

-- 4.1 先把我上面那版旧脚本可能建过的策略清掉（幂等，不存在也不报错）
drop policy if exists "anon can insert feedback" on public.feedback;
drop policy if exists "feedback insert anon"      on public.feedback;

-- 4.2 只保留一条：允许匿名 / 登录用户新增（with check 里不限制内容，长度约束靠前端）
create policy "feedback insert anon"
  on public.feedback
  for insert
  to anon, authenticated
  with check (true);

-- 4.3 表级权限：收回一切，只给 insert
--     （这样即便以后有人误加了一条宽松策略，匿名 key 也读不到/改不了/删不掉数据）
revoke all    on public.feedback from anon, authenticated;
grant  insert on public.feedback to anon, authenticated;

-- 4.4 如果 id 是 bigserial，匿名插入需要序列权限；是 uuid 默认值时这段自动跳过
do $$
begin
  if exists (
    select 1
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'S'
      and c.relname = 'feedback_id_seq'
  ) then
    execute 'grant usage, select on sequence public.feedback_id_seq to anon, authenticated';
  end if;
end $$;


-- ---------- ⑤ 验收 ----------
-- 5.1 策略应该只剩 1 条（feedback insert anon / INSERT / {anon,authenticated}）
select count(*) as policy_count
from pg_policies
where schemaname = 'public' and tablename = 'feedback';

-- 5.2 剩余数据量（清理完应该只剩你自己的真实反馈）
select count(*) as rows_now from public.feedback;

-- 5.3 自检数据是否清干净（应该返回 0）
select count(*) as leftover_selftest_rows
from public.feedback
where user_name = '[self-test] DeepWorks';

-- 5.4 最新 10 条反馈长这样（前端字段一一对应）
--     user_name = 称呼 / user_email = 邮箱(可空) / feedback_type = 建议|问题|其他 / content = 留言
select id, created_at, user_name, user_email, feedback_type, content
from public.feedback
order by created_at desc
limit 10;

-- 收工后匿名端的预期行为（不用再动，仅作说明）：
--   POST   /rest/v1/feedback            -> 201 Created      （网页能提交）
--   GET    /rest/v1/feedback            -> []               （拿公开 key 读不到任何反馈）
--   DELETE /rest/v1/feedback?id=eq.xxx  -> 0 行             （拿公开 key 删不掉任何反馈）
