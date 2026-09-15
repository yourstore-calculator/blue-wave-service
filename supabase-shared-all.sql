-- =====================================================================================
-- Blue Wave — مساحة عمل واحدة للجميع (بلا أدوار ولا مالك)
-- =====================================================================================
--
-- ما يفعله:
--   كل مستخدم مسجَّل دخوله يرى ويعدّل كل البيانات فوراً — بلا owner، بلا member،
--   وبلا حاجة لإضافة أحد في أي جدول. يعمل مع شخص واحد أو عشرة بنفس الطريقة.
--
-- ⚠️ لماذا يبقى تسجيل الدخول شرطاً؟
--   مفتاح anon مكشوف في صفحة موقعك (هذا تصميم Supabase). لو سمحنا لغير المسجَّلين،
--   لصار بإمكان أي شخص على الإنترنت قراءة كوتيشناتك وعملائك وحساباتك المالية وحذفها.
--   الشرط هنا هو "مسجَّل دخول" فقط — لا أدوار ولا تصاريح إضافية.
--
-- ✅ آمن تماماً: لا DROP TABLE ولا DELETE. بياناتك الحالية تبقى كما هي.
--    شغّله في: Supabase ← SQL Editor ← New query ← Run
-- =====================================================================================


-- ---------- 1) مساحة موحّدة ثابتة ----------
-- معرّف ثابت لا يعتمد على أي مستخدم. بدونه كان كل موظف يكوّن نسخته المنفصلة
-- من نفس المفتاح في app_state، فلا تتوحّد البيانات أبداً.
create or replace function public.shared_workspace_id()
returns uuid
language sql
immutable
as $$
  select '00000000-0000-0000-0000-000000000001'::uuid;
$$;

grant execute on function public.shared_workspace_id() to authenticated;

-- توافق مع النسخة السابقة (التطبيق قد يستدعي هذين الاسمين)
create or replace function public.team_workspace_id()
returns uuid language sql immutable as $$ select public.shared_workspace_id(); $$;

create or replace function public.is_team_member()
returns boolean language sql stable as $$ select auth.uid() is not null; $$;

grant execute on function public.team_workspace_id() to authenticated;
grant execute on function public.is_team_member() to authenticated;


-- ---------- 2) الكوتيشنات: الجميع يقرأ ويكتب ----------
alter table public.quotations enable row level security;

drop policy if exists q_select on public.quotations;
drop policy if exists q_insert on public.quotations;
drop policy if exists q_update on public.quotations;
drop policy if exists q_delete on public.quotations;
drop policy if exists q_all    on public.quotations;

create policy q_all on public.quotations
  for all to authenticated
  using (true) with check (true);


-- ---------- 3) بنود الكوتيشن ----------
alter table public.quotation_items enable row level security;

drop policy if exists qi_select on public.quotation_items;
drop policy if exists qi_insert on public.quotation_items;
drop policy if exists qi_update on public.quotation_items;
drop policy if exists qi_delete on public.quotation_items;
drop policy if exists qi_all    on public.quotation_items;

create policy qi_all on public.quotation_items
  for all to authenticated
  using (true) with check (true);


-- ---------- 4) app_state: المنتجات والإعدادات والمالية ----------
alter table public.app_state enable row level security;

drop policy if exists as_select on public.app_state;
drop policy if exists as_insert on public.app_state;
drop policy if exists as_update on public.app_state;
drop policy if exists as_delete on public.app_state;
drop policy if exists as_all    on public.app_state;

create policy as_all on public.app_state
  for all to authenticated
  using (true) with check (true);

-- الافتراضي يصير المساحة المشتركة بدل معرّف المستخدم
alter table public.app_state alter column owner_id set default public.shared_workspace_id();


-- ---------- 5) توحيد البيانات الموجودة ----------
-- ينقل كل ما كتبه الموظفون في مساحاتهم المنفصلة إلى المساحة المشتركة،
-- ويبقي الأحدث لكل مفتاح. آمن للتكرار.
insert into public.app_state (owner_id, key, value, updated_at)
select public.shared_workspace_id(), s.key, s.value, s.updated_at
from (
  select distinct on (key) key, value, updated_at
  from public.app_state
  order by key, updated_at desc
) s
on conflict (owner_id, key) do update
  set value = excluded.value, updated_at = excluded.updated_at;


-- ---------- 6) تفعيل التحديث اللحظي ----------
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='app_state'
  ) then
    alter publication supabase_realtime add table public.app_state;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='quotations'
  ) then
    alter publication supabase_realtime add table public.quotations;
  end if;
end $$;

-- لازم ليصل حقل value كاملاً مع حدث التحديث
alter table public.app_state  replica identity full;
alter table public.quotations replica identity full;


-- =====================================================================================
-- 7) التحقق بعد التشغيل — المتوقع:
--    · ثلاث سياسات فقط: q_all / qi_all / as_all  (كلها cmd = ALL)
--    · جدولان يبثّان لحظياً
-- =====================================================================================
--   select tablename, policyname, cmd from pg_policies
--   where schemaname='public' order by tablename;
--
--   select tablename from pg_publication_tables
--   where pubname='supabase_realtime' and schemaname='public';
--
-- ملاحظة: لم تعد بحاجة لجدول team_members إطلاقاً. اتركه — لا يضر.
-- =====================================================================================
