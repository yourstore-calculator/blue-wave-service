-- =====================================================================================
-- Blue Wave — مخطط قاعدة البيانات على Supabase
-- الصقه كاملاً في:  Supabase Dashboard ← SQL Editor ← New query ← Run
-- =====================================================================================
--
-- ⚠️ اقرأ هذا قبل التشغيل:
-- مستودعك على GitHub عام، ومفتاح anon مكشوف فيه (وهذا طبيعي في Supabase).
-- لذلك الحماية الحقيقية الوحيدة هي سياسات RLS أدناه + تسجيل الدخول.
-- بدونها يستطيع أي شخص يفتح مستودعك أن يقرأ ويحذف كل بياناتك بثلاثة أسطر كود.
-- كل جدول هنا يُفعَّل عليه RLS فوراً، ولا سياسة تسمح لغير المسجَّلين بأي شيء.
-- =====================================================================================


-- ---------- 1) جدول الكوتيشنات ----------
create table if not exists public.quotations (
  id             uuid primary key default gen_random_uuid(),
  quote_number   text not null,
  customer_name  text,
  customer_phone text,
  total_amount   numeric(14,3) default 0,
  grand_total    numeric(14,3) default 0,
  terms          text,
  status         text default 'draft',
  -- مالك السجل: يُملأ تلقائياً بالمستخدم المسجَّل، وهو أساس كل سياسات RLS
  owner_id       uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);


-- ---------- 2) جدول بنود الكوتيشن ----------
create table if not exists public.quotation_items (
  id            uuid primary key default gen_random_uuid(),
  quotation_id  uuid not null references public.quotations(id) on delete cascade,
  product_name  text,
  height        numeric(12,3) default 0,
  width         numeric(12,3) default 0,
  area_m2       numeric(12,3) default 0,
  quantity      integer default 1,
  unit_price    numeric(14,3) default 0,
  total_price   numeric(14,3) default 0,
  notes         text,
  sort_order    integer default 0,
  created_at    timestamptz not null default now()
);
-- on delete cascade أعلاه: حذف الكوتيشن يحذف بنوده تلقائياً في المخدم،
-- فلا تبقى بنود يتيمة لو انقطع الاتصال في منتصف عملية الحذف.


-- ---------- 3) الفهارس (سرعة الاستعلام) ----------
create index if not exists idx_quotations_owner    on public.quotations(owner_id);
create index if not exists idx_quotations_created  on public.quotations(created_at desc);
create index if not exists idx_quotations_number   on public.quotations(quote_number);
create index if not exists idx_items_quotation     on public.quotation_items(quotation_id);


-- ---------- 4) تحديث updated_at تلقائياً ----------
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

drop trigger if exists trg_quotations_touch on public.quotations;
create trigger trg_quotations_touch
  before update on public.quotations
  for each row execute function public.touch_updated_at();


-- =====================================================================================
-- 5) الحماية: Row Level Security
-- =====================================================================================

alter table public.quotations      enable row level security;
alter table public.quotation_items enable row level security;

-- حذف أي سياسات سابقة بنفس الأسماء (حتى يكون السكربت قابلاً لإعادة التشغيل)
drop policy if exists q_select on public.quotations;
drop policy if exists q_insert on public.quotations;
drop policy if exists q_update on public.quotations;
drop policy if exists q_delete on public.quotations;

drop policy if exists qi_select on public.quotation_items;
drop policy if exists qi_insert on public.quotation_items;
drop policy if exists qi_update on public.quotation_items;
drop policy if exists qi_delete on public.quotation_items;

-- الكوتيشنات: كل مستخدم يرى ويعدّل سجلاته فقط
create policy q_select on public.quotations
  for select to authenticated using (owner_id = auth.uid());

create policy q_insert on public.quotations
  for insert to authenticated with check (owner_id = auth.uid());

create policy q_update on public.quotations
  for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

create policy q_delete on public.quotations
  for delete to authenticated using (owner_id = auth.uid());

-- البنود: الصلاحية تُشتق من ملكية الكوتيشن الأب.
-- بدون هذا الربط، يستطيع مستخدم قراءة بنود كوتيشن غيره رغم أن الكوتيشن نفسه محمي.
create policy qi_select on public.quotation_items
  for select to authenticated using (
    exists (select 1 from public.quotations q
            where q.id = quotation_id and q.owner_id = auth.uid())
  );

create policy qi_insert on public.quotation_items
  for insert to authenticated with check (
    exists (select 1 from public.quotations q
            where q.id = quotation_id and q.owner_id = auth.uid())
  );

create policy qi_update on public.quotation_items
  for update to authenticated using (
    exists (select 1 from public.quotations q
            where q.id = quotation_id and q.owner_id = auth.uid())
  );

create policy qi_delete on public.quotation_items
  for delete to authenticated using (
    exists (select 1 from public.quotations q
            where q.id = quotation_id and q.owner_id = auth.uid())
  );


-- =====================================================================================
-- 6) التحقق من نجاح الحماية — شغّل هذا بعد السكربت
-- =====================================================================================
-- يجب أن يعيد rowsecurity = true للجدولين. لو ظهر false فالبيانات مكشوفة للعالم.
--
--   select tablename, rowsecurity
--   from pg_tables
--   where schemaname = 'public' and tablename in ('quotations','quotation_items');
--
-- ولعرض السياسات المطبَّقة:
--
--   select tablename, policyname, cmd from pg_policies where schemaname = 'public';
-- =====================================================================================


-- =====================================================================================
-- ملاحظة عن بقية بياناتك
-- -------------------------------------------------------------------------------------
-- هذا المخطط يغطي الكوتيشنات وبنودها فقط (وهو ما طلبته).
-- تطبيقك يخزّن 27 مفتاحاً في المتصفح، منها: المنتجات وفئاتها والشبك والإعدادات
-- والمسودات وقائمة الأسعار، بالإضافة إلى النظام المالي كاملاً
-- (حسابات، حركات، طلبيات، موردون، شحنات، سجل عمليات).
--
-- لذلك تبقى هذه البيانات في المتصفح حتى ننقلها بجداولها الخاصة.
-- الترتيب المقترح: الكوتيشنات (الآن) ← المنتجات ← النظام المالي أخيراً.
-- =====================================================================================


-- =====================================================================================
-- 7) تحديث: أعمدة إضافية للمستندات النهائية (آمن للتشغيل المتكرر)
-- =====================================================================================
alter table public.quotations add column if not exists location      text;
alter table public.quotations add column if not exists quote_date    date;
alter table public.quotations add column if not exists discount      numeric(14,3) default 0;
alter table public.quotations add column if not exists notes         text;
alter table public.quotations add column if not exists company_signer  text;
alter table public.quotations add column if not exists customer_signer text;
-- status يميّز عرض السعر عن المستند النهائي: 'draft' | 'sent' | 'approved' | 'final'
alter table public.quotations alter column status set default 'draft';

alter table public.quotation_items add column if not exists description text;

create index if not exists idx_quotations_status on public.quotations(status);


-- =====================================================================================
-- 8) دالة مساعدة: حذف كوتيشن مع بنوده في معاملة واحدة
--    (on delete cascade يكفي عادةً، لكن هذه تعيد عدد البنود المحذوفة للتأكيد)
-- =====================================================================================
create or replace function public.delete_quotation(p_id uuid)
returns integer
language plpgsql
security invoker          -- ينفَّذ بصلاحيات المستخدم، فتبقى RLS فعّالة
as $$
declare
  n integer;
begin
  select count(*) into n from public.quotation_items where quotation_id = p_id;
  delete from public.quotations where id = p_id;   -- RLS تمنع حذف ما لا تملكه
  return n;
end $$;


-- =====================================================================================
-- 9) التشغيل المتكرر
-- -------------------------------------------------------------------------------------
-- كل أوامر هذا الملف idempotent:
--   create table if not exists / create index if not exists / add column if not exists
--   drop policy if exists قبل كل create policy
--   create or replace للدوال والمشغّلات
-- فيمكن تشغيله كاملاً في أي وقت بلا أخطاء تعارض.
-- =====================================================================================


-- =====================================================================================
-- 10) الحفظ التلقائي: جدول حالة التطبيق (app_state)
-- -------------------------------------------------------------------------------------
-- المشكلة التي يحلّها: جدولا quotations و quotation_items يغطيان الكوتيشنات فقط،
-- بينما التطبيق يحفظ 27 مفتاحاً (منتجات، إعدادات، مسودات، قائمة أسعار، النظام
-- المالي كاملاً). بدون هذا الجدول لا يوجد مكان سحابي لأي تعديل خارج الكوتيشنات،
-- فيستحيل تحقيق "أي تغيير يُحفظ تلقائياً".
--
-- كل مفتاح يُخزَّن كمستند JSONB لمالكه، ويُحدَّث بـ upsert عند أي تغيير.
-- =====================================================================================
create table if not exists public.app_state (
  owner_id   uuid not null default auth.uid() references auth.users(id) on delete cascade,
  key        text not null,
  value      jsonb,
  updated_at timestamptz not null default now(),
  primary key (owner_id, key)
);

create index if not exists idx_app_state_owner on public.app_state(owner_id);

alter table public.app_state enable row level security;

drop policy if exists as_select on public.app_state;
drop policy if exists as_insert on public.app_state;
drop policy if exists as_update on public.app_state;
drop policy if exists as_delete on public.app_state;

create policy as_select on public.app_state
  for select to authenticated using (owner_id = auth.uid());
create policy as_insert on public.app_state
  for insert to authenticated with check (owner_id = auth.uid());
create policy as_update on public.app_state
  for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy as_delete on public.app_state
  for delete to authenticated using (owner_id = auth.uid());

-- تحديث updated_at تلقائياً
drop trigger if exists trg_app_state_touch on public.app_state;
create trigger trg_app_state_touch
  before update on public.app_state
  for each row execute function public.touch_updated_at();


-- =====================================================================================
-- 11) ترحيل: أعمدة التكلفة والأبواب على بنود الكوتيشن
-- -------------------------------------------------------------------------------------
-- ⚠️ تنبيه أمني مهم: factory_price بيان داخلي حسّاس (تكلفة المصنع).
-- سياسات RLS تحمي الصف كاملاً لمالكه، لكن التطبيق يجب ألا يعرض هذا العمود
-- في أي نسخة تُطبع أو تُرسل للعميل. المعالجة في الكود، لا في قاعدة البيانات.
-- =====================================================================================
alter table public.quotation_items add column if not exists factory_price     numeric(14,3) default 0;
alter table public.quotation_items add column if not exists shipping_factor   numeric(6,3)  default 0.13;
alter table public.quotation_items add column if not exists cbm_volume        numeric(12,3) default 0;
alter table public.quotation_items add column if not exists opening_image_url text;
alter table public.quotation_items add column if not exists selected_addons   jsonb default '[]'::jsonb;

-- إجمالي الربح لكوتيشن (للأدمن فقط) — RLS تضمن أن المستخدم يرى كوتيشناته وحدها
create or replace function public.quotation_profit(p_id uuid)
returns numeric
language sql
security invoker
stable
as $$
  select coalesce(sum(i.total_price - (i.factory_price * i.quantity)), 0)
  from public.quotation_items i
  join public.quotations q on q.id = i.quotation_id
  where i.quotation_id = p_id and q.owner_id = auth.uid();
$$;

create index if not exists idx_items_addons on public.quotation_items using gin (selected_addons);
