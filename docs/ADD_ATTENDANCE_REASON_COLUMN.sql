-- إضافة آمنة لعمود سبب الغياب الذي تستخدمه الواجهة.
-- لا يحذف أو يغيّر أي سجل موجود.
ALTER TABLE public.attendance
ADD COLUMN IF NOT EXISTS absence_reason text;

COMMENT ON COLUMN public.attendance.absence_reason IS
'سبب الغياب: ordinary, permission, exempt, official_duty. يبقى NULL للحضور.';

-- تحديث مخطط PostgREST حتى يتعرف Supabase API على العمود الجديد.
NOTIFY pgrst, 'reload schema';
