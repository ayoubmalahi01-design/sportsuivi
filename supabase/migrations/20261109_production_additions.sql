-- Sport Performance: additive production additions for the existing single-institution database.
-- SAFE INTENT: no DROP, TRUNCATE, DELETE, table recreation, or data overwrite.
-- Review the actual deployed schema before running. This is not the original fresh-project bootstrap.

DO $$ BEGIN
  IF to_regclass('public.attendance') IS NOT NULL THEN
    ALTER TABLE public.attendance ADD COLUMN IF NOT EXISTS absence_reason text;
    ALTER TABLE public.attendance ADD COLUMN IF NOT EXISTS session_id uuid;
  END IF;
  IF to_regclass('public.test_results') IS NOT NULL AND to_regclass('public.scale_versions') IS NOT NULL THEN
    ALTER TABLE public.test_results ADD COLUMN IF NOT EXISTS scale_version_id uuid;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='test_results_scale_version_id_fkey') THEN
      ALTER TABLE public.test_results ADD CONSTRAINT test_results_scale_version_id_fkey
        FOREIGN KEY (scale_version_id) REFERENCES public.scale_versions(id) ON DELETE RESTRICT;
    END IF;
  END IF;
END $$;

-- Retain reason separately from the attendance state (late is never absence).
DO $$ BEGIN
  IF to_regclass('public.attendance') IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname='attendance_absence_reason_check'
  ) THEN
    ALTER TABLE public.attendance ADD CONSTRAINT attendance_absence_reason_check
      CHECK (absence_reason IS NULL OR absence_reason IN ('ordinary','permission','exempt','official_duty')) NOT VALID;
  END IF;
END $$;

-- Facility configuration for this one institution.
CREATE TABLE IF NOT EXISTS public.institution_facilities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  institution_id uuid NOT NULL REFERENCES public.institutions(id) ON DELETE CASCADE,
  facility_name text NOT NULL,
  facility_description text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.institution_equipment (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  institution_id uuid NOT NULL REFERENCES public.institutions(id) ON DELETE CASCADE,
  equipment_name text NOT NULL,
  quantity integer NOT NULL DEFAULT 1 CHECK (quantity >= 0),
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Rehabilitation follow-up: consecutive full absences, then two actual sessions after return.
CREATE TABLE IF NOT EXISTS public.rehab_notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  trigger_attendance_id uuid,
  institution_id uuid NOT NULL REFERENCES public.institutions(id) ON DELETE CASCADE,
  student_id uuid NOT NULL REFERENCES public.students(id) ON DELETE CASCADE,
  triggered_at date NOT NULL DEFAULT current_date,
  remaining_sessions integer NOT NULL DEFAULT 2 CHECK (remaining_sessions BETWEEN 0 AND 2),
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','handled','expired')),
  handled_by uuid REFERENCES auth.users(id),
  handled_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.rehab_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  institution_id uuid NOT NULL REFERENCES public.institutions(id) ON DELETE CASCADE,
  student_id uuid NOT NULL REFERENCES public.students(id) ON DELETE CASCADE,
  triggered_at date NOT NULL,
  final_session_count integer,
  final_status text NOT NULL CHECK (final_status IN ('expired','handled')),
  handled_at timestamptz,
  handled_by uuid REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Keep a reference to the exact return-to-attendance record, so two sessions on one date count correctly.
ALTER TABLE public.rehab_notifications ADD COLUMN IF NOT EXISTS trigger_attendance_id uuid;

-- Enable RLS; policy creation is conditional and additive.
DO $$ DECLARE t text; BEGIN
  FOREACH t IN ARRAY ARRAY['institution_facilities','institution_equipment','rehab_notifications','rehab_history'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY',t);
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename=t AND policyname=t||'_read_members') THEN
      EXECUTE format('CREATE POLICY %I ON public.%I FOR SELECT USING (institution_id = public.my_institution())',t||'_read_members',t);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename=t AND policyname=t||'_admin_write') THEN
      EXECUTE format('CREATE POLICY %I ON public.%I FOR ALL USING (public.is_admin_level() AND institution_id = public.my_institution()) WITH CHECK (public.is_admin_level() AND institution_id = public.my_institution())',t||'_admin_write',t);
    END IF;
  END LOOP;
END $$;

-- Allow authorized staff to correct attendance while preserving institution scope.
DO $$ BEGIN
  IF to_regclass('public.attendance') IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='attendance' AND policyname='attendance_update_owner_or_admin'
  ) THEN
    CREATE POLICY attendance_update_owner_or_admin ON public.attendance FOR UPDATE
      USING (institution_id=public.my_institution() AND (recorded_by=auth.uid() OR public.is_admin_level()))
      WITH CHECK (institution_id=public.my_institution() AND (recorded_by=auth.uid() OR public.is_admin_level()));
  END IF;
END $$;

-- Storage bucket for institution logo. Public read; authenticated staff may upload within this app bucket.
INSERT INTO storage.buckets (id,name,public)
VALUES ('institution-assets','institution-assets',true)
ON CONFLICT (id) DO NOTHING;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='storage' AND tablename='objects' AND policyname='institution_assets_public_read') THEN
    CREATE POLICY institution_assets_public_read ON storage.objects FOR SELECT USING (bucket_id='institution-assets');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='storage' AND tablename='objects' AND policyname='institution_assets_authenticated_upload') THEN
    CREATE POLICY institution_assets_authenticated_upload ON storage.objects FOR INSERT TO authenticated
      WITH CHECK (bucket_id='institution-assets' AND public.is_staff());
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='storage' AND tablename='objects' AND policyname='institution_assets_authenticated_update') THEN
    CREATE POLICY institution_assets_authenticated_update ON storage.objects FOR UPDATE TO authenticated
      USING (bucket_id='institution-assets' AND public.is_staff())
      WITH CHECK (bucket_id='institution-assets' AND public.is_staff());
  END IF;
END $$;

-- Existing audit_log remains append-only via existing triggers/policies. Do not grant direct client writes here.

-- Rehabilitation notification automation. Counts attendance records (actual PE sessions), not calendar days.
DO $$ BEGIN
  IF to_regclass('public.attendance') IS NOT NULL AND to_regclass('public.rehab_notifications') IS NOT NULL THEN
    CREATE OR REPLACE FUNCTION public.process_rehab_attendance()
    RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $fn$
    DECLARE consecutive_absences integer := 0; active_notice record;
    BEGIN
      -- On return to presence, count the immediately preceding consecutive absent records.
      IF NEW.status IN ('present','late') THEN
        SELECT count(*) INTO consecutive_absences
        FROM (
          SELECT status FROM public.attendance
          WHERE student_id=NEW.student_id AND institution_id=NEW.institution_id
            AND id<>NEW.id
            AND (attendance_date < NEW.attendance_date OR (attendance_date=NEW.attendance_date AND created_at < NEW.created_at))
          ORDER BY attendance_date DESC, created_at DESC
          LIMIT 5
        ) recent
        WHERE status='absent';
        IF consecutive_absences=5 THEN
          INSERT INTO public.rehab_notifications(institution_id,student_id,triggered_at,trigger_attendance_id,remaining_sessions,status)
          SELECT NEW.institution_id,NEW.student_id,NEW.attendance_date,NEW.id,2,'active'
          WHERE NOT EXISTS (SELECT 1 FROM public.rehab_notifications n
            WHERE n.student_id=NEW.student_id AND n.status='active');
        END IF;
      END IF;

      -- Every subsequent inserted attendance record is one actual session.
      FOR active_notice IN
        SELECT * FROM public.rehab_notifications
        WHERE student_id=NEW.student_id AND status='active'
          AND trigger_attendance_id IS DISTINCT FROM NEW.id
      LOOP
        IF active_notice.remaining_sessions <= 1 THEN
          UPDATE public.rehab_notifications SET remaining_sessions=0,status='expired'
          WHERE id=active_notice.id;
        ELSE
          UPDATE public.rehab_notifications SET remaining_sessions=remaining_sessions-1 WHERE id=active_notice.id;
        END IF;
      END LOOP;
      RETURN NEW;
    END $fn$;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='attendance_rehab_after_insert') THEN
      CREATE TRIGGER attendance_rehab_after_insert AFTER INSERT ON public.attendance
      FOR EACH ROW EXECUTE FUNCTION public.process_rehab_attendance();
    END IF;
  END IF;
END $$;

-- Persist handled/expired notifications in history exactly once.
DO $$ BEGIN
  IF to_regclass('public.rehab_notifications') IS NOT NULL AND to_regclass('public.rehab_history') IS NOT NULL THEN
    CREATE OR REPLACE FUNCTION public.archive_rehab_notification()
    RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $fn$
    BEGIN
      IF OLD.status='active' AND NEW.status IN ('handled','expired') THEN
        INSERT INTO public.rehab_history(institution_id,student_id,triggered_at,final_session_count,final_status,handled_at,handled_by)
        VALUES(NEW.institution_id,NEW.student_id,NEW.triggered_at,2,NEW.status,NEW.handled_at,NEW.handled_by);
      END IF;
      RETURN NEW;
    END $fn$;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='rehab_notification_archive_after_update') THEN
      CREATE TRIGGER rehab_notification_archive_after_update AFTER UPDATE OF status ON public.rehab_notifications
      FOR EACH ROW EXECUTE FUNCTION public.archive_rehab_notification();
    END IF;
  END IF;
END $$;

DO $$ BEGIN
  IF to_regclass('public.rehab_notifications') IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM pg_policies WHERE schemaname='public' AND tablename='rehab_notifications' AND policyname='rehab_notifications_staff_handle'
  ) THEN
    CREATE POLICY rehab_notifications_staff_handle ON public.rehab_notifications FOR UPDATE
      USING (institution_id=public.my_institution() AND public.is_staff())
      WITH CHECK (institution_id=public.my_institution() AND public.is_staff() AND status IN ('active','handled'));
  END IF;
END $$;
