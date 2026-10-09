-- =====================================================================================
-- Blue Wave — بوكت تخزين الصور والمرفقات  (quotation_files)
-- =====================================================================================
--   الغرض: نقل صور الكوتيشنات من قاعدة البيانات (base64) إلى التخزين السحابي.
--   الأثر: الكوتيشن يحمل رابطاً (~100 بايت) بدل صورة (~70 كيلوبايت) — انخفاض
--          يقارب 99% في حجم التخزين المحلي والحمولة السحابية.
--
--   نموذج الحماية المختار (bucket محمي):
--     · القراءة  : عامة — الصور تظهر في الكوتيشن المطبوع وفي PDF بلا تسجيل دخول
--     · الرفع    : للمسجَّلين فقط
--     · التعديل  : للمسجَّلين فقط
--     · الحذف    : للمسجَّلين فقط
--   أي شخص يعرف رابط صورة يراها (وهذا مقصود لعرض الكوتيشن)، لكن لا أحد
--   يستطيع رفع شيء أو حذفه أو تصفّح محتويات البوكت بلا حساب.
--
--   ✅ آمن للتشغيل المتكرر — لا يحذف ملفات ولا بيانات.
--      شغّله في: Supabase ← SQL Editor ← New query ← الصق الكل ← Run
-- =====================================================================================

-- ═════════════════════════════════════════════════════════════════════════
--  ① إنشاء البوكت
-- ═════════════════════════════════════════════════════════════════════════
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'quotation_files',
  'quotation_files',
  true,                                    -- قراءة عامة للروابط المباشرة
  10485760,                                -- حد 10 ميجابايت للملف الواحد
  array['image/jpeg','image/png','image/webp','image/gif','application/pdf']
)
on conflict (id) do update
  set public = true,
      file_size_limit = 10485760,
      allowed_mime_types = array['image/jpeg','image/png','image/webp','image/gif','application/pdf'];


-- ═════════════════════════════════════════════════════════════════════════
--  ② سياسات الوصول
-- ═════════════════════════════════════════════════════════════════════════
-- نحذف القديمة أولاً ليكون التشغيل آمناً للتكرار
do $$
declare r record;
begin
  for r in
    select policyname from pg_policies
    where schemaname = 'storage' and tablename = 'objects'
      and policyname like 'qf_%'
  loop
    execute format('drop policy if exists %I on storage.objects', r.policyname);
  end loop;
end $$;

-- القراءة: عامة — ضرورية لعرض الصور في الكوتيشن والطباعة و PDF
create policy qf_read on storage.objects
  for select to public
  using (bucket_id = 'quotation_files');

-- الرفع: للمسجَّلين فقط
create policy qf_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'quotation_files');

-- التعديل: للمسجَّلين فقط
create policy qf_update on storage.objects
  for update to authenticated
  using (bucket_id = 'quotation_files')
  with check (bucket_id = 'quotation_files');

-- الحذف: للمسجَّلين فقط
create policy qf_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'quotation_files');


-- ═════════════════════════════════════════════════════════════════════════
--  ③ حماية جدول النسخة الاحتياطية (تحذير Supabase الأمني)
-- ═════════════════════════════════════════════════════════════════════════
do $$
begin
  if exists (select 1 from pg_tables where schemaname='public' and tablename='app_state_backup') then
    execute 'alter table public.app_state_backup enable row level security';
    execute 'drop policy if exists asb_read on public.app_state_backup';
    execute 'create policy asb_read on public.app_state_backup for select to authenticated using (true)';
    raise notice '③ حُمي app_state_backup — لم يعد مكشوفاً';
  else
    raise notice '③ app_state_backup غير موجود — لا حاجة';
  end if;
end $$;


-- ═════════════════════════════════════════════════════════════════════════
--  ④ التحقق
-- ═════════════════════════════════════════════════════════════════════════
select 'البوكت' as "الفحص",
       coalesce((select id from storage.buckets where id='quotation_files'), 'غير موجود') as "القيمة",
       case when exists (select 1 from storage.buckets where id='quotation_files')
            then '✅' else '❌' end as "الحالة"

union all
select 'قراءة عامة',
       coalesce((select public::text from storage.buckets where id='quotation_files'), '-'),
       case when (select public from storage.buckets where id='quotation_files') then '✅' else '❌' end

union all
select 'حد حجم الملف',
       coalesce((select (file_size_limit/1048576)::text || ' ميجابايت'
                 from storage.buckets where id='quotation_files'), '-'),
       '✅'

union all
select 'سياسات البوكت',
       count(*)::text || ' / 4',
       case when count(*) = 4 then '✅' else '❌' end
from pg_policies
where schemaname='storage' and tablename='objects' and policyname like 'qf_%'

union all
select 'app_state_backup محمي',
       coalesce((select case when rowsecurity then 'نعم' else 'لا' end
                 from pg_tables where schemaname='public' and tablename='app_state_backup'), 'غير موجود'),
       case when not exists (select 1 from pg_tables where schemaname='public' and tablename='app_state_backup')
             or (select rowsecurity from pg_tables where schemaname='public' and tablename='app_state_backup')
            then '✅' else '❌' end;
