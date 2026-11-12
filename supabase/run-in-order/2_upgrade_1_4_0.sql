-- Sport Performance production upgrade — 2026-11-12
-- Additive/data-preserving migration. Review and run once in Supabase SQL Editor.
-- It does NOT delete student, attendance, result, measurement, or historical audit rows.

BEGIN;

-- 1) Separate every roster and its records by academic year.
ALTER TABLE public.students ADD COLUMN IF NOT EXISTS school_year_id uuid REFERENCES public.school_years(id);
ALTER TABLE public.students ADD COLUMN IF NOT EXISTS photo_path text;
ALTER TABLE public.classes ADD COLUMN IF NOT EXISTS school_year_id uuid REFERENCES public.school_years(id);
ALTER TABLE public.sessions ADD COLUMN IF NOT EXISTS school_year_id uuid REFERENCES public.school_years(id);
ALTER TABLE public.sessions ADD COLUMN IF NOT EXISTS lesson_plan_id uuid;
ALTER TABLE public.attendance ADD COLUMN IF NOT EXISTS school_year_id uuid REFERENCES public.school_years(id);
ALTER TABLE public.test_results ADD COLUMN IF NOT EXISTS school_year_id uuid REFERENCES public.school_years(id);
ALTER TABLE public.body_measurements ADD COLUMN IF NOT EXISTS school_year_id uuid REFERENCES public.school_years(id);
ALTER TABLE IF EXISTS public.student_measurements ADD COLUMN IF NOT EXISTS school_year_id uuid REFERENCES public.school_years(id);
ALTER TABLE public.observations ADD COLUMN IF NOT EXISTS school_year_id uuid REFERENCES public.school_years(id);
ALTER TABLE IF EXISTS public.rehab_notifications ADD COLUMN IF NOT EXISTS school_year_id uuid REFERENCES public.school_years(id);
ALTER TABLE IF EXISTS public.rehab_history ADD COLUMN IF NOT EXISTS school_year_id uuid REFERENCES public.school_years(id);

-- Existing students are assigned to the active year where possible; otherwise the latest year.
UPDATE public.students s
SET school_year_id = COALESCE(
  (SELECT y.id FROM public.school_years y
   WHERE y.institution_id = s.institution_id AND NOT y.is_archived
   ORDER BY y.start_date DESC LIMIT 1),
  (SELECT y.id FROM public.school_years y
   WHERE y.institution_id = s.institution_id
   ORDER BY y.start_date DESC LIMIT 1)
)
WHERE s.school_year_id IS NULL;
UPDATE public.classes c
SET school_year_id=COALESCE(
  (SELECT y.id FROM public.school_years y WHERE y.institution_id=c.institution_id AND lower(y.name)=lower(c.school_year) ORDER BY y.start_date DESC LIMIT 1),
  (SELECT y.id FROM public.school_years y WHERE y.institution_id=c.institution_id AND NOT y.is_archived ORDER BY y.start_date DESC LIMIT 1)
)
WHERE c.school_year_id IS NULL;

-- Backfill dated records to the year that contains their date; fallback to the linked student's year.
UPDATE public.sessions s
SET school_year_id = COALESCE(
  (SELECT y.id FROM public.school_years y WHERE y.institution_id=s.institution_id
    AND s.session_date >= y.start_date AND (y.end_date IS NULL OR s.session_date <= y.end_date)
    ORDER BY y.start_date DESC LIMIT 1),
  (SELECT y.id FROM public.school_years y WHERE y.institution_id=s.institution_id AND NOT y.is_archived ORDER BY y.start_date DESC LIMIT 1)
)
WHERE s.school_year_id IS NULL;
UPDATE public.attendance a
SET school_year_id = COALESCE(
  (SELECT ss.school_year_id FROM public.sessions ss WHERE ss.id=a.session_id),
  (SELECT y.id FROM public.school_years y WHERE y.institution_id=a.institution_id
    AND a.attendance_date >= y.start_date AND (y.end_date IS NULL OR a.attendance_date <= y.end_date)
    ORDER BY y.start_date DESC LIMIT 1),
  (SELECT st.school_year_id FROM public.students st WHERE st.id=a.student_id)
)
WHERE a.school_year_id IS NULL;
UPDATE public.test_results r
SET school_year_id = COALESCE(
  (SELECT y.id FROM public.school_years y WHERE y.institution_id=r.institution_id
    AND r.tested_on >= y.start_date AND (y.end_date IS NULL OR r.tested_on <= y.end_date)
    ORDER BY y.start_date DESC LIMIT 1),
  (SELECT st.school_year_id FROM public.students st WHERE st.id=r.student_id)
)
WHERE r.school_year_id IS NULL;
UPDATE public.body_measurements m
SET school_year_id = COALESCE(
  (SELECT y.id FROM public.school_years y WHERE y.institution_id=m.institution_id
    AND m.measured_on >= y.start_date AND (y.end_date IS NULL OR m.measured_on <= y.end_date)
    ORDER BY y.start_date DESC LIMIT 1),
  (SELECT st.school_year_id FROM public.students st WHERE st.id=m.student_id)
)
WHERE m.school_year_id IS NULL;
UPDATE public.student_measurements m
SET school_year_id=(SELECT st.school_year_id FROM public.students st WHERE st.id=m.student_id)
WHERE m.school_year_id IS NULL;
UPDATE public.rehab_notifications r
SET school_year_id=(SELECT st.school_year_id FROM public.students st WHERE st.id=r.student_id)
WHERE r.school_year_id IS NULL;
UPDATE public.rehab_history h
SET school_year_id=(SELECT st.school_year_id FROM public.students st WHERE st.id=h.student_id)
WHERE h.school_year_id IS NULL;
UPDATE public.observations o
SET school_year_id = COALESCE(
  (SELECT st.school_year_id FROM public.students st WHERE st.id=o.student_id),
  (SELECT y.id FROM public.school_years y WHERE y.institution_id=o.institution_id AND NOT y.is_archived ORDER BY y.start_date DESC LIMIT 1)
)
WHERE o.school_year_id IS NULL;

-- Reuse student numbers in a new academic year without changing old-year records.
DO $$
DECLARE c record;
BEGIN
  FOR c IN
    SELECT conname FROM pg_constraint
    WHERE conrelid='public.students'::regclass AND contype='u'
      AND replace(pg_get_constraintdef(oid),' ','') ILIKE '%(institution_id,student_number)%'
  LOOP
    EXECUTE format('ALTER TABLE public.students DROP CONSTRAINT %I', c.conname);
  END LOOP;
END $$;
CREATE UNIQUE INDEX IF NOT EXISTS students_year_number_unique
  ON public.students(institution_id, school_year_id, student_number)
  WHERE school_year_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS students_year_lookup_idx ON public.students(institution_id, school_year_id, archived);
CREATE INDEX IF NOT EXISTS classes_year_lookup_idx ON public.classes(institution_id, school_year_id);
DO $$
DECLARE c record;
BEGIN
  FOR c IN
    SELECT conname FROM pg_constraint
    WHERE conrelid='public.classes'::regclass AND contype='u'
      AND replace(pg_get_constraintdef(oid),' ','') ILIKE '%(institution_id,name)%'
  LOOP
    EXECUTE format('ALTER TABLE public.classes DROP CONSTRAINT %I', c.conname);
  END LOOP;
END $$;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.classes WHERE school_year_id IS NOT NULL GROUP BY institution_id,school_year_id,name HAVING COUNT(*)>1) THEN
    CREATE UNIQUE INDEX IF NOT EXISTS classes_year_name_unique ON public.classes(institution_id,school_year_id,name) WHERE school_year_id IS NOT NULL;
  ELSE
    RAISE WARNING 'Duplicate class names exist in one academic year; year/name unique index was not created. Existing rows were preserved.';
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS attendance_year_date_idx ON public.attendance(institution_id, school_year_id, attendance_date);
CREATE INDEX IF NOT EXISTS results_year_date_idx ON public.test_results(institution_id, school_year_id, tested_on);
CREATE INDEX IF NOT EXISTS measurements_year_date_idx ON public.body_measurements(institution_id, school_year_id, measured_on);
CREATE INDEX IF NOT EXISTS student_measurements_year_idx ON public.student_measurements(institution_id, school_year_id, student_id);
CREATE INDEX IF NOT EXISTS rehab_notifications_year_idx ON public.rehab_notifications(institution_id,school_year_id,student_id);
CREATE INDEX IF NOT EXISTS rehab_history_year_idx ON public.rehab_history(institution_id,school_year_id,student_id);

-- 2) Administration-authored lesson plans and documents for coaches.
CREATE TABLE IF NOT EXISTS public.lesson_plans (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  institution_id uuid NOT NULL REFERENCES public.institutions(id),
  school_year_id uuid NOT NULL REFERENCES public.school_years(id),
  lesson_number integer NOT NULL,
  title text NOT NULL,
  content text,
  file_path text,
  file_name text,
  content_type text,
  uploaded_by uuid REFERENCES public.profiles(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(institution_id, school_year_id, lesson_number)
);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='sessions_lesson_plan_id_fkey') THEN
    ALTER TABLE public.sessions ADD CONSTRAINT sessions_lesson_plan_id_fkey
      FOREIGN KEY (lesson_plan_id) REFERENCES public.lesson_plans(id) ON DELETE SET NULL;
  END IF;
END $$;
ALTER TABLE public.lesson_plans ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS lesson_plans_read ON public.lesson_plans;
DROP POLICY IF EXISTS lesson_plans_admin_write ON public.lesson_plans;
CREATE POLICY lesson_plans_read ON public.lesson_plans FOR SELECT TO authenticated
  USING (institution_id=public.my_institution() AND public.is_staff());
CREATE POLICY lesson_plans_admin_write ON public.lesson_plans FOR ALL TO authenticated
  USING (institution_id=public.my_institution() AND public.is_admin_level())
  WITH CHECK (institution_id=public.my_institution() AND public.is_admin_level());
GRANT SELECT, INSERT, UPDATE, DELETE ON public.lesson_plans TO authenticated;

-- 3) Private storage for student photos and lesson documents.
INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
VALUES
 ('student-photos','student-photos',false,5242880,ARRAY['image/jpeg','image/png','image/webp']),
 ('lesson-resources','lesson-resources',false,26214400,ARRAY['application/pdf','application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document','application/vnd.ms-excel','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet','text/plain'])
ON CONFLICT (id) DO UPDATE SET public=false;
DROP POLICY IF EXISTS sp_student_photos_read ON storage.objects;
DROP POLICY IF EXISTS sp_student_photos_admin_write ON storage.objects;
DROP POLICY IF EXISTS sp_lesson_resources_read ON storage.objects;
DROP POLICY IF EXISTS sp_lesson_resources_admin_write ON storage.objects;
CREATE POLICY sp_student_photos_read ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id='student-photos' AND (storage.foldername(name))[1]=public.my_institution()::text AND public.is_staff());
CREATE POLICY sp_student_photos_admin_write ON storage.objects FOR ALL TO authenticated
  USING (bucket_id='student-photos' AND (storage.foldername(name))[1]=public.my_institution()::text AND public.is_admin_level() AND EXISTS (SELECT 1 FROM public.school_years y WHERE y.id=(storage.foldername(name))[2]::uuid AND y.institution_id=public.my_institution() AND NOT y.is_archived))
  WITH CHECK (bucket_id='student-photos' AND (storage.foldername(name))[1]=public.my_institution()::text AND public.is_admin_level() AND EXISTS (SELECT 1 FROM public.school_years y WHERE y.id=(storage.foldername(name))[2]::uuid AND y.institution_id=public.my_institution() AND NOT y.is_archived));
CREATE POLICY sp_lesson_resources_read ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id='lesson-resources' AND (storage.foldername(name))[1]=public.my_institution()::text AND public.is_staff());
CREATE POLICY sp_lesson_resources_admin_write ON storage.objects FOR ALL TO authenticated
  USING (bucket_id='lesson-resources' AND (storage.foldername(name))[1]=public.my_institution()::text AND public.is_admin_level() AND EXISTS (SELECT 1 FROM public.school_years y WHERE y.id=(storage.foldername(name))[2]::uuid AND y.institution_id=public.my_institution() AND NOT y.is_archived))
  WITH CHECK (bucket_id='lesson-resources' AND (storage.foldername(name))[1]=public.my_institution()::text AND public.is_admin_level() AND EXISTS (SELECT 1 FROM public.school_years y WHERE y.id=(storage.foldername(name))[2]::uuid AND y.institution_id=public.my_institution() AND NOT y.is_archived));

-- 4) Server-side read-only enforcement for archived academic years.
CREATE OR REPLACE FUNCTION public.prevent_archived_year_write()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pg_catalog','public'
AS $$
DECLARE v_year uuid; v_student_year uuid; v_session_year uuid; v_row_inst uuid;
BEGIN
  IF current_setting('app.allow_year_archive', true) = 'on' THEN
    IF TG_OP='DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
  END IF;
  IF TG_OP='DELETE' THEN
    v_year := OLD.school_year_id;
    v_row_inst := OLD.institution_id;
  ELSE
    v_year := NEW.school_year_id;
    v_row_inst := NEW.institution_id;
    -- Derive the year when a legacy client omits it; never let NULL bypass archive protection.
    IF v_year IS NULL THEN
      IF TG_TABLE_NAME='students' THEN
        SELECT id INTO v_year FROM public.school_years
          WHERE institution_id=NEW.institution_id AND NOT is_archived ORDER BY start_date DESC LIMIT 1;
      ELSIF TG_TABLE_NAME='classes' THEN
        SELECT id INTO v_year FROM public.school_years
          WHERE institution_id=NEW.institution_id AND lower(name)=lower(NEW.school_year) AND NOT is_archived ORDER BY start_date DESC LIMIT 1;
        IF v_year IS NULL THEN SELECT id INTO v_year FROM public.school_years WHERE institution_id=NEW.institution_id AND NOT is_archived ORDER BY start_date DESC LIMIT 1; END IF;
      ELSIF TG_TABLE_NAME='sessions' THEN
        SELECT id INTO v_year FROM public.school_years
          WHERE institution_id=NEW.institution_id AND NOT is_archived ORDER BY start_date DESC LIMIT 1;
      ELSE
        SELECT school_year_id INTO v_student_year FROM public.students WHERE id=NEW.student_id;
        IF TG_TABLE_NAME='attendance' AND NEW.session_id IS NOT NULL THEN
          SELECT school_year_id INTO v_session_year FROM public.sessions WHERE id=NEW.session_id;
        END IF;
        v_year := COALESCE(v_session_year,v_student_year);
      END IF;
      NEW.school_year_id := v_year;
    END IF;
    IF TG_TABLE_NAME='students' AND NEW.class_id IS NOT NULL THEN
      SELECT school_year_id INTO v_student_year FROM public.classes WHERE id=NEW.class_id;
      IF v_student_year IS NOT NULL AND v_year IS DISTINCT FROM v_student_year THEN
        RAISE EXCEPTION 'القسم المحدد لا يتبع السنة الدراسية المختارة';
      END IF;
    END IF;
    IF TG_TABLE_NAME='sessions' AND NEW.lesson_plan_id IS NOT NULL THEN
      SELECT school_year_id INTO v_student_year FROM public.lesson_plans WHERE id=NEW.lesson_plan_id;
      IF v_student_year IS NOT NULL AND v_year IS DISTINCT FROM v_student_year THEN
        RAISE EXCEPTION 'محتوى الحصة لا يتبع السنة الدراسية المختارة';
      END IF;
    END IF;
    IF TG_TABLE_NAME IN ('attendance','test_results','body_measurements','student_measurements','observations','rehab_notifications','rehab_history') THEN
      SELECT school_year_id INTO v_student_year FROM public.students WHERE id=NEW.student_id;
      IF v_student_year IS NOT NULL AND v_year IS DISTINCT FROM v_student_year THEN
        RAISE EXCEPTION 'سجل التلميذ يجب أن ينتمي إلى سنته الدراسية نفسها';
      END IF;
      IF TG_TABLE_NAME='attendance' AND NEW.session_id IS NOT NULL THEN
        SELECT school_year_id INTO v_session_year FROM public.sessions WHERE id=NEW.session_id;
        IF v_session_year IS NOT NULL AND v_year IS DISTINCT FROM v_session_year THEN
          RAISE EXCEPTION 'الحضور والحصة يجب أن ينتميا إلى السنة الدراسية نفسها';
        END IF;
      END IF;
    END IF;
  END IF;
  IF v_year IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.school_years y WHERE y.id=v_year AND y.institution_id=v_row_inst) THEN
    RAISE EXCEPTION 'السنة الدراسية لا تتبع المؤسسة المحددة';
  END IF;
  IF v_year IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.school_years y WHERE y.id=v_year AND y.is_archived=true
  ) THEN
    RAISE EXCEPTION 'هذه السنة الدراسية مؤرشفة — القراءة فقط';
  END IF;
  IF TG_OP='UPDATE' AND OLD.school_year_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.school_years y WHERE y.id=OLD.school_year_id AND y.is_archived=true
  ) THEN
    RAISE EXCEPTION 'لا يمكن تعديل بيانات سنة دراسية مؤرشفة';
  END IF;
  IF TG_OP='DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END $$;
REVOKE ALL ON FUNCTION public.prevent_archived_year_write() FROM PUBLIC,anon,authenticated;
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['students','classes','sessions','attendance','test_results','body_measurements','student_measurements','observations','lesson_plans','rehab_notifications','rehab_history'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS prevent_archived_year_write ON public.%I',t);
    EXECUTE format('CREATE TRIGGER prevent_archived_year_write BEFORE INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.prevent_archived_year_write()',t);
  END LOOP;
END $$;

-- Prevent changing or deleting a year once it is archived; the rollover RPC is the only controlled exception.
CREATE OR REPLACE FUNCTION public.guard_archived_school_year()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pg_catalog','public'
AS $$
BEGIN
  IF current_setting('app.allow_year_archive', true) = 'on' THEN
    IF TG_OP='DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
  END IF;
  IF TG_OP='DELETE' AND OLD.is_archived THEN
    RAISE EXCEPTION 'لا يمكن حذف سنة دراسية مؤرشفة';
  END IF;
  IF TG_OP='UPDATE' AND OLD.is_archived THEN
    RAISE EXCEPTION 'السنة الدراسية المؤرشفة للقراءة فقط';
  END IF;
  IF TG_OP='UPDATE' AND OLD.is_archived=false AND NEW.is_archived=true THEN
    RAISE EXCEPTION 'أرشف السنة عبر إجراء بدء السنة الجديدة';
  END IF;
  IF TG_OP='DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END $$;
REVOKE ALL ON FUNCTION public.guard_archived_school_year() FROM PUBLIC,anon,authenticated;
DROP TRIGGER IF EXISTS guard_archived_school_year ON public.school_years;
CREATE TRIGGER guard_archived_school_year BEFORE UPDATE OR DELETE ON public.school_years
FOR EACH ROW EXECUTE FUNCTION public.guard_archived_school_year();

-- Atomic year rollover: archive the prior roster and open a completely separate empty roster.
CREATE OR REPLACE FUNCTION public.start_school_year(p_name text,p_start_date date)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'pg_catalog','public'
AS $$
DECLARE v_inst uuid; v_new uuid; v_has_active boolean;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_admin_level() THEN
    RAISE EXCEPTION 'غير مخوّل بإنشاء سنة دراسية';
  END IF;
  v_inst := public.my_institution();
  IF v_inst IS NOT NULL THEN PERFORM pg_advisory_xact_lock(hashtext(v_inst::text)); END IF;
  IF v_inst IS NULL OR length(trim(coalesce(p_name,'')))=0 OR p_start_date IS NULL THEN
    RAISE EXCEPTION 'اسم السنة وتاريخ البداية مطلوبان';
  END IF;
  IF EXISTS (SELECT 1 FROM public.school_years WHERE institution_id=v_inst AND lower(trim(name))=lower(trim(p_name))) THEN
    RAISE EXCEPTION 'اسم السنة الدراسية موجود مسبقاً';
  END IF;
  IF EXISTS (SELECT 1 FROM public.school_years WHERE institution_id=v_inst AND NOT is_archived AND p_start_date<=start_date) THEN
    RAISE EXCEPTION 'تاريخ بداية السنة الجديدة يجب أن يكون بعد بداية السنة الحالية';
  END IF;
  SELECT EXISTS(SELECT 1 FROM public.school_years WHERE institution_id=v_inst AND NOT is_archived) INTO v_has_active;
  PERFORM set_config('app.allow_year_archive','on',true);
  IF v_has_active THEN
    UPDATE public.school_years SET is_archived=true,end_date=p_start_date-1
      WHERE institution_id=v_inst AND NOT is_archived;
    UPDATE public.students SET archived=true
      WHERE institution_id=v_inst AND school_year_id IN
        (SELECT id FROM public.school_years WHERE institution_id=v_inst AND is_archived AND end_date=p_start_date-1);
  END IF;
  INSERT INTO public.school_years(institution_id,name,start_date,is_archived)
  VALUES(v_inst,trim(p_name),p_start_date,false) RETURNING id INTO v_new;
  IF NOT v_has_active THEN
    UPDATE public.classes SET school_year_id=v_new,school_year=COALESCE(school_year,trim(p_name))
      WHERE institution_id=v_inst AND school_year_id IS NULL;
    UPDATE public.students SET school_year_id=v_new,archived=false
      WHERE institution_id=v_inst AND school_year_id IS NULL;
    UPDATE public.sessions SET school_year_id=v_new WHERE institution_id=v_inst AND school_year_id IS NULL;
    UPDATE public.attendance SET school_year_id=v_new WHERE institution_id=v_inst AND school_year_id IS NULL;
    UPDATE public.test_results SET school_year_id=v_new WHERE institution_id=v_inst AND school_year_id IS NULL;
    UPDATE public.body_measurements SET school_year_id=v_new WHERE institution_id=v_inst AND school_year_id IS NULL;
    UPDATE public.student_measurements SET school_year_id=v_new WHERE institution_id=v_inst AND school_year_id IS NULL;
    UPDATE public.observations SET school_year_id=v_new WHERE institution_id=v_inst AND school_year_id IS NULL;
    UPDATE public.rehab_notifications SET school_year_id=v_new WHERE institution_id=v_inst AND school_year_id IS NULL;
    UPDATE public.rehab_history SET school_year_id=v_new WHERE institution_id=v_inst AND school_year_id IS NULL;
  END IF;
  RETURN v_new;
END $$;
REVOKE ALL ON FUNCTION public.start_school_year(text,date) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.start_school_year(text,date) TO authenticated;

-- (تم حذف البند 5: إيقاف سجل التعديلات. سجل التعديلات يبقى يعمل للإدارة.)

COMMIT;

-- Verification after execution:
-- SELECT table_name,column_name FROM information_schema.columns
-- WHERE table_schema='public' AND column_name IN ('school_year_id','photo_path','lesson_plan_id') ORDER BY table_name,column_name;
-- SELECT proname,prosecdef,proconfig FROM pg_proc JOIN pg_namespace ON pg_namespace.oid=pronamespace
-- WHERE nspname='public' AND proname IN ('start_school_year','prevent_archived_year_write');
-- SELECT id,name,is_archived FROM public.school_years ORDER BY start_date;
