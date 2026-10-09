-- =====================================================================================
-- Blue Wave — تشخيص مشكلة "الحماية منعت العملية"
-- شغّله في: Supabase ← SQL Editor ← New query ← Run
-- كل استعلام يخبرك بشيء محدد. اقرأ النتائج بالترتيب.
-- =====================================================================================


-- ①  هل الجداول موجودة و RLS مفعّل؟
-- المتوقع: 3 صفوف، كلها rowsecurity = true
select tablename, rowsecurity as "RLS مفعّل"
from pg_tables
where schemaname = 'public'
  and tablename in ('quotations','quotation_items','app_state','team_members')
order by tablename;


-- ②  هل شُغّل ملف المشاركة؟
-- المتوقع: صفّان (is_team_member و team_workspace_id)
-- لو فارغ → لم تُشغّل supabase-team-sharing.sql
select routine_name as "الدالة"
from information_schema.routines
where routine_schema = 'public'
  and routine_name in ('is_team_member','team_workspace_id');


-- ③  من هم أعضاء الفريق؟
-- المتوقع: صف لكل موظف، وواحد على الأقل role = 'owner'
-- لو فارغ → لم تُضف أحداً بعد
select email, role, added_at from public.team_members order by added_at;


-- ④  من في auth ولم يُضف للفريق؟  ← هذا سبب مشكلتك على الأرجح
-- كل بريد يظهر هنا سيفشل حفظه في مساحة الشركة
select u.email as "مستخدم غير مضاف للفريق"
from auth.users u
left join public.team_members t on t.user_id = u.id
where t.user_id is null;


-- ⑤  هل السياسات الجديدة مطبَّقة؟
-- المتوقع: 14 سياسة تقريباً، وسياسات app_state تذكر is_team_member
select tablename, policyname, cmd
from pg_policies
where schemaname = 'public'
order by tablename, policyname;


-- ⑥  هل Realtime مفعّل؟
-- المتوقع: app_state و quotations
select tablename as "جدول يبث لحظياً"
from pg_publication_tables
where pubname = 'supabase_realtime' and schemaname = 'public';


-- =====================================================================================
-- 🔧 الإصلاح السريع — أضف كل مستخدم لم يظهر في ③
-- =====================================================================================
--
-- أضف نفسك مالكاً (بدّل البريد):
--
--   insert into public.team_members (user_id, email, role)
--   select id, email, 'owner' from auth.users where email = 'بريدك@example.com'
--   on conflict (user_id) do update set role = 'owner';
--
-- أضف موظفاً:
--
--   insert into public.team_members (user_id, email, role)
--   select id, email, 'member' from auth.users where email = 'الموظف@example.com'
--   on conflict (user_id) do nothing;
--
-- ⚡ أو أضف الجميع دفعة واحدة (كل من في auth.users):
--
--   insert into public.team_members (user_id, email, role)
--   select id, email, 'member' from auth.users
--   on conflict (user_id) do nothing;
--   -- ثم اجعل نفسك مالكاً:
--   update public.team_members set role = 'owner' where email = 'بريدك@example.com';
--
-- بعد الإضافة: على كل موظف تسجيل خروج ثم دخول ليُقرأ وضعه الجديد.
-- =====================================================================================
