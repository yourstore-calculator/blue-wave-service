-- =====================================================================================
-- Blue Wave — إصلاح خطأ:
--   violates foreign key constraint "app_state_owner_id_fkey"
-- =====================================================================================
--
-- السبب:
--   جدول app_state فيه قيد يربط owner_id بجدول auth.users. والمساحة المشتركة
--   التي اخترتها في السكربت السابق (0000...0001) ليست مستخدماً حقيقياً،
--   فيرفض القيد إدراجها.
--
-- الحل المُتّبع هنا (الأبسط والأسلم):
--   نُلغي عمود المالك من معادلة المشاركة كلياً. المفتاح يصير key وحده،
--   فلا حاجة لأي معرّف وهمي ولا لقيد يربطه بمستخدم.
--   كل مسجَّل دخول يقرأ ويكتب نفس الصف — وهو المطلوب بالضبط.
--
-- ✅ بياناتك محفوظة: نُبقي الأحدث لكل مفتاح قبل تغيير المفتاح الأساسي.
--    شغّله في: Supabase ← SQL Editor ← New query ← Run
-- =====================================================================================


-- ═════════════════════════════════════════════════════════════════════════
--  ١) نسخة احتياطية داخل قاعدة البيانات (احترازية)
-- ═════════════════════════════════════════════════════════════════════════
create table if not exists public.app_state_backup as
  select * from public.app_state;


-- ═════════════════════════════════════════════════════════════════════════
--  ٢) إزالة القيد الذي يسبب الخطأ
-- ═════════════════════════════════════════════════════════════════════════
-- نحذف أي قيد مفتاح خارجي على owner_id مهما كان اسمه
do $$
declare r record;
begin
  for r in
    select conname
    from pg_constraint
    where conrelid = 'public.app_state'::regclass
      and contype = 'f'
  loop
    execute format('alter table public.app_state drop constraint %I', r.conname);
    raise notice 'أُزيل القيد: %', r.conname;
  end loop;
end $$;

-- ونزيل الافتراضي الذي يربطه بالمستخدم
alter table public.app_state alter column owner_id drop default;
alter table public.app_state alter column owner_id drop not null;


-- ═════════════════════════════════════════════════════════════════════════
--  ٣) توحيد الصفوف: صف واحد لكل مفتاح (الأحدث يفوز)
-- ═════════════════════════════════════════════════════════════════════════
-- نُنشئ جدولاً مؤقتاً بالأحدث لكل مفتاح، ثم نستبدل المحتوى.
create temporary table _newest on commit drop as
  select distinct on (key) key, value, updated_at
  from public.app_state
  order by key, updated_at desc nulls last;

-- نُفرّغ الجدول من التكرارات (البيانات محفوظة في _newest والنسخة الاحتياطية)
truncate table public.app_state;


-- ═════════════════════════════════════════════════════════════════════════
--  ٤) المفتاح الأساسي يصير key وحده — بلا مالك
-- ═════════════════════════════════════════════════════════════════════════
do $$
declare r record;
begin
  for r in
    select conname from pg_constraint
    where conrelid = 'public.app_state'::regclass and contype = 'p'
  loop
    execute format('alter table public.app_state drop constraint %I', r.conname);
  end loop;
end $$;

alter table public.app_state add primary key (key);


-- ═════════════════════════════════════════════════════════════════════════
--  ٥) إعادة البيانات
-- ═════════════════════════════════════════════════════════════════════════
insert into public.app_state (key, value, updated_at, owner_id)
select key, value, coalesce(updated_at, now()), null
from _newest;


-- ═════════════════════════════════════════════════════════════════════════
--  ٦) الحماية: كل مسجَّل دخول يقرأ ويكتب
-- ═════════════════════════════════════════════════════════════════════════
alter table public.app_state enable row level security;

do $$
declare r record;
begin
  for r in
    select policyname from pg_policies
    where schemaname = 'public' and tablename = 'app_state'
  loop
    execute format('drop policy if exists %I on public.app_state', r.policyname);
  end loop;
end $$;

create policy as_all on public.app_state
  for all to authenticated using (true) with check (true);


-- ═════════════════════════════════════════════════════════════════════════
--  ٧) الكوتيشنات: نفس المعالجة (قد تحمل القيد نفسه)
-- ═════════════════════════════════════════════════════════════════════════
alter table public.quotations alter column owner_id drop default;
alter table public.quotations alter column owner_id drop not null;

alter table public.quotations      enable row level security;
alter table public.quotation_items enable row level security;

do $$
declare r record;
begin
  for r in
    select policyname, tablename from pg_policies
    where schemaname='public' and tablename in ('quotations','quotation_items')
  loop
    execute format('drop policy if exists %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

create policy q_all  on public.quotations
  for all to authenticated using (true) with check (true);

create policy qi_all on public.quotation_items
  for all to authenticated using (true) with check (true);


-- ═════════════════════════════════════════════════════════════════════════
--  ٨) التحديث اللحظي
-- ═════════════════════════════════════════════════════════════════════════
do $$
begin
  if not exists (select 1 from pg_publication where pubname='supabase_realtime') then
    create publication supabase_realtime;
  end if;
  if not exists (select 1 from pg_publication_tables
                 where pubname='supabase_realtime' and schemaname='public' and tablename='app_state') then
    alter publication supabase_realtime add table public.app_state;
  end if;
  if not exists (select 1 from pg_publication_tables
                 where pubname='supabase_realtime' and schemaname='public' and tablename='quotations') then
    alter publication supabase_realtime add table public.quotations;
  end if;
exception when others then
  raise notice 'فعّل Realtime يدوياً من Database ← Replication: %', sqlerrm;
end $$;

alter table public.app_state  replica identity full;
alter table public.quotations replica identity full;


-- ═════════════════════════════════════════════════════════════════════════
--  ٩) التحقق
-- ═════════════════════════════════════════════════════════════════════════
select 'قيود المفتاح الخارجي على app_state' as "الفحص",
       count(*)::text as "العدد",
       case when count(*) = 0 then '✅ أُزيلت' else '❌ ما زالت' end as "الحالة"
from pg_constraint where conrelid='public.app_state'::regclass and contype='f'

union all
select 'المفتاح الأساسي = key وحده',
       count(*)::text,
       case when count(*) = 1 then '✅' else '❌' end
from information_schema.key_column_usage
where table_schema='public' and table_name='app_state'
  and constraint_name in (select conname from pg_constraint
                          where conrelid='public.app_state'::regclass and contype='p')

union all
select 'السياسات (q_all/qi_all/as_all)',
       count(*)::text || ' / 3',
       case when count(*) = 3 then '✅' else '❌' end
from pg_policies where schemaname='public' and policyname in ('q_all','qi_all','as_all')

union all
select 'صفوف app_state',
       count(*)::text,
       '✅'
from public.app_state

union all
select 'التحديث اللحظي',
       count(*)::text || ' / 2',
       case when count(*) = 2 then '✅' else '⚠️ فعّله من Database ← Replication' end
from pg_publication_tables where pubname='supabase_realtime' and schemaname='public'
  and tablename in ('app_state','quotations');


-- =====================================================================================
-- ملاحظة: نسختك الاحتياطية محفوظة في الجدول public.app_state_backup
--         بعد التأكد أن كل شيء يعمل، يمكنك حذفه:
--           drop table public.app_state_backup;
-- =====================================================================================
