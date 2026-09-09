-- =====================================================================================
-- Blue Wave — مشاركة البيانات بين مستخدمي الشركة (Team Workspace)
-- =====================================================================================
--
-- المشكلة التي يحلّها:
-- المخطط الحالي يعزل كل مستخدم عن الآخر (owner_id = auth.uid()) — وهو الصحيح
-- لتطبيق شخصي، لكنه خطأ لفريق عمل: موظف يضيف كوتيشناً فلا يراه زميله.
--
-- الحل: مساحة عمل واحدة للشركة. كل مستخدم مسجَّل فيها يرى بيانات الشركة كاملة
-- ويحرّرها. الملكية الفردية (owner_id) تبقى محفوظة للتتبّع — من أنشأ ماذا.
--
-- ⚠️ آمن تماماً: لا DROP TABLE ولا DELETE. بياناتك الحالية تبقى كما هي.
--    شغّله في: Supabase ← SQL Editor ← New query ← Run
-- =====================================================================================


-- ---------- 1) جدول أعضاء الفريق ----------
-- من له حق الوصول لبيانات الشركة. الإضافة يدوية من لوحة Supabase (أو SQL أدناه).
create table if not exists public.team_members (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  email      text,
  role       text not null default 'member',   -- 'owner' | 'member'
  added_at   timestamptz not null default now()
);

alter table public.team_members enable row level security;

drop policy if exists tm_select on public.team_members;
create policy tm_select on public.team_members
  for select to authenticated using (true);    -- كل عضو يرى قائمة الفريق

-- إضافة/حذف الأعضاء من لوحة Supabase فقط (أأمن من فتحها للتطبيق)
drop policy if exists tm_write on public.team_members;
create policy tm_write on public.team_members
  for all to authenticated
  using (exists (select 1 from public.team_members t
                 where t.user_id = auth.uid() and t.role = 'owner'))
  with check (exists (select 1 from public.team_members t
                      where t.user_id = auth.uid() and t.role = 'owner'));


-- ---------- 2) دالة العضوية ----------
-- security definer: تقرأ الجدول بصلاحيات مرتفعة لتفادي حلقة RLS لا نهائية
-- عند استدعائها من داخل سياسات RLS نفسها.
create or replace function public.is_team_member()
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (select 1 from public.team_members where user_id = auth.uid());
$$;

revoke all on function public.is_team_member() from public;
grant execute on function public.is_team_member() to authenticated;


-- ---------- 3) الكوتيشنات: مشتركة بين الفريق ----------
drop policy if exists q_select on public.quotations;
drop policy if exists q_insert on public.quotations;
drop policy if exists q_update on public.quotations;
drop policy if exists q_delete on public.quotations;

-- كل عضو يقرأ كوتيشنات الشركة كلها (أو سجلاته لو لم يُضف للفريق بعد)
create policy q_select on public.quotations
  for select to authenticated
  using (public.is_team_member() or owner_id = auth.uid());

create policy q_insert on public.quotations
  for insert to authenticated
  with check (owner_id = auth.uid());           -- يُنسب لمن أنشأه

create policy q_update on public.quotations
  for update to authenticated
  using (public.is_team_member() or owner_id = auth.uid())
  with check (public.is_team_member() or owner_id = auth.uid());

create policy q_delete on public.quotations
  for delete to authenticated
  using (public.is_team_member() or owner_id = auth.uid());


-- ---------- 4) بنود الكوتيشن: تتبع الكوتيشن الأب ----------
drop policy if exists qi_select on public.quotation_items;
drop policy if exists qi_insert on public.quotation_items;
drop policy if exists qi_update on public.quotation_items;
drop policy if exists qi_delete on public.quotation_items;

create policy qi_select on public.quotation_items
  for select to authenticated using (
    exists (select 1 from public.quotations q where q.id = quotation_id
            and (public.is_team_member() or q.owner_id = auth.uid())));

create policy qi_insert on public.quotation_items
  for insert to authenticated with check (
    exists (select 1 from public.quotations q where q.id = quotation_id
            and (public.is_team_member() or q.owner_id = auth.uid())));

create policy qi_update on public.quotation_items
  for update to authenticated using (
    exists (select 1 from public.quotations q where q.id = quotation_id
            and (public.is_team_member() or q.owner_id = auth.uid())));

create policy qi_delete on public.quotation_items
  for delete to authenticated using (
    exists (select 1 from public.quotations q where q.id = quotation_id
            and (public.is_team_member() or q.owner_id = auth.uid())));


-- ---------- 5) app_state: المنتجات والإعدادات والمالية ----------
-- ⚠️ نقطة حرجة: مفتاح الجدول هو (owner_id, key). لو كتب كل عضو بمعرّفه
-- لتكوّنت نسخة منفصلة لكل مستخدم من نفس المفتاح، فلا تتوحّد البيانات.
-- الحل: مفتاح ملكية موحّد للشركة يكتب فيه الجميع.

-- معرّف مساحة الشركة = معرّف أول مالك في الفريق
create or replace function public.team_workspace_id()
returns uuid
language sql
security definer
stable
set search_path = public
as $$
  select coalesce(
    (select user_id from public.team_members where role = 'owner' order by added_at limit 1),
    auth.uid()
  );
$$;

revoke all on function public.team_workspace_id() from public;
grant execute on function public.team_workspace_id() to authenticated;

drop policy if exists as_select on public.app_state;
drop policy if exists as_insert on public.app_state;
drop policy if exists as_update on public.app_state;
drop policy if exists as_delete on public.app_state;

create policy as_select on public.app_state
  for select to authenticated
  using (public.is_team_member() or owner_id = auth.uid());

create policy as_insert on public.app_state
  for insert to authenticated
  with check (public.is_team_member() or owner_id = auth.uid());

create policy as_update on public.app_state
  for update to authenticated
  using (public.is_team_member() or owner_id = auth.uid())
  with check (public.is_team_member() or owner_id = auth.uid());

create policy as_delete on public.app_state
  for delete to authenticated
  using (public.is_team_member() or owner_id = auth.uid());


-- =====================================================================================
-- 6) إضافة أعضاء الفريق — نفّذ هذا بعد إنشاء المستخدمين
-- =====================================================================================
--
-- أولاً: أضفك أنت كمالك (استبدل بريدك):
--
--   insert into public.team_members (user_id, email, role)
--   select id, email, 'owner' from auth.users where email = 'your@email.com'
--   on conflict (user_id) do update set role = 'owner';
--
-- ثم أضف الموظفين (كرّر السطر لكل موظف):
--
--   insert into public.team_members (user_id, email, role)
--   select id, email, 'member' from auth.users where email = 'employee@email.com'
--   on conflict (user_id) do nothing;
--
-- لعرض الفريق:      select * from public.team_members;
-- لإزالة عضو:       delete from public.team_members where email = 'x@y.com';
-- =====================================================================================


-- =====================================================================================
-- 7) توحيد البيانات الموجودة (اختياري — نفّذه مرة واحدة فقط)
-- -------------------------------------------------------------------------------------
-- لو كان كل موظف قد كوّن نسخته من app_state، هذا ينقل بيانات الجميع لمساحة الشركة.
-- ⚠️ يبقي الأحدث لكل مفتاح ويحذف النسخ الأقدم. خذ نسخة احتياطية قبله.
--
--   with newest as (
--     select distinct on (key) key, value
--     from public.app_state
--     order by key, updated_at desc
--   )
--   insert into public.app_state (owner_id, key, value)
--   select public.team_workspace_id(), key, value from newest
--   on conflict (owner_id, key) do update set value = excluded.value;
-- =====================================================================================


-- =====================================================================================
-- 8) التحقق بعد التشغيل
-- =====================================================================================
--   select tablename, policyname, cmd from pg_policies
--   where schemaname = 'public' order by tablename, policyname;
--
--   select * from public.team_members;
-- =====================================================================================


-- =====================================================================================
-- 9) تفعيل التحديث اللحظي (Realtime)
-- -------------------------------------------------------------------------------------
-- بدون هذا القسم لن يرى الموظفون تغييرات بعضهم إلا بعد إعادة تحميل الصفحة.
-- إضافة الجداول لقناة البث تجعل Supabase يرسل التغييرات فور حدوثها.
--
-- ملاحظة أمنية: البث يحترم RLS — كل عضو يستقبل ما يحق له رؤيته فقط.
-- =====================================================================================

-- إنشاء قناة البث إن لم تكن موجودة
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
end $$;

-- إضافة الجداول للقناة (آمن للتكرار)
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'app_state'
  ) then
    alter publication supabase_realtime add table public.app_state;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'quotations'
  ) then
    alter publication supabase_realtime add table public.quotations;
  end if;
end $$;

-- REPLICA IDENTITY FULL: يرسل الصف كاملاً مع التغيير بدل المفتاح فقط،
-- وهو لازم حتى يصل حقل value في حدث التحديث.
alter table public.app_state    replica identity full;
alter table public.quotations   replica identity full;

-- للتحقق:
--   select schemaname, tablename from pg_publication_tables
--   where pubname = 'supabase_realtime';
