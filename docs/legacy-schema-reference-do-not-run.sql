-- مخطط تأسيسي أولي فقط. راجعه واختبره في مشروع Supabase تجريبي قبل أي بيانات حقيقية.
create extension if not exists pgcrypto;

create table if not exists public.institutions (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  logo_url text,
  created_at timestamptz not null default now()
);

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  institution_id uuid not null references public.institutions(id) on delete cascade,
  full_name text not null,
  role text not null check (role in ('admin','coach')),
  created_at timestamptz not null default now()
);

create table if not exists public.students (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null references public.institutions(id) on delete cascade,
  student_code text not null,
  full_name text not null,
  birth_date date,
  group_name text,
  status text not null default 'active',
  created_at timestamptz not null default now(),
  unique(institution_id, student_code)
);

create table if not exists public.attendance (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null references public.institutions(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  attendance_date date not null,
  status text not null check(status in ('present','absent')),
  absence_reason text check(absence_reason in ('ordinary','permission','exempt','duty') or absence_reason is null),
  recorded_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  unique(student_id, attendance_date)
);

create table if not exists public.tests (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null references public.institutions(id) on delete cascade,
  name text not null,
  unit text not null,
  protocol jsonb not null default '{}'::jsonb,
  scoring_table jsonb not null default '[]'::jsonb,
  active boolean not null default true
);

create table if not exists public.test_results (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null references public.institutions(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  test_id uuid not null references public.tests(id),
  raw_value jsonb not null,
  converted_score numeric(5,2),
  recorded_by uuid not null references auth.users(id),
  recorded_at timestamptz not null default now()
);

create table if not exists public.sessions (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null references public.institutions(id) on delete cascade,
  coach_id uuid not null references auth.users(id),
  started_at timestamptz not null,
  ended_at timestamptz,
  duration_minutes integer generated always as (
    case when ended_at is null then null else greatest(0, floor(extract(epoch from (ended_at-started_at))/60)::int) end
  ) stored
);

-- ملاحظات المدرب: لا يوجد institution-wide read policy؛ المالك وحده يقرأ/يعدل.
create table if not exists public.coach_notes (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  title text,
  body text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.audit_log (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null references public.institutions(id) on delete cascade,
  actor_id uuid not null references auth.users(id),
  action text not null,
  entity_type text not null,
  entity_id uuid,
  old_value jsonb,
  new_value jsonb,
  reason text,
  created_at timestamptz not null default now()
);

create or replace function public.current_institution_id()
returns uuid language sql stable security definer set search_path = public
as $$ select institution_id from public.profiles where id = auth.uid() $$;

create or replace function public.current_role()
returns text language sql stable security definer set search_path = public
as $$ select role from public.profiles where id = auth.uid() $$;

alter table public.institutions enable row level security;
alter table public.profiles enable row level security;
alter table public.students enable row level security;
alter table public.attendance enable row level security;
alter table public.tests enable row level security;
alter table public.test_results enable row level security;
alter table public.sessions enable row level security;
alter table public.coach_notes enable row level security;
alter table public.audit_log enable row level security;

-- المؤسسة: المستخدم يرى مؤسسته فقط.
create policy "institution members read own institution" on public.institutions
for select using (id = public.current_institution_id());
create policy "admin updates own institution" on public.institutions
for update using (id = public.current_institution_id() and public.current_role()='admin')
with check (id = public.current_institution_id());

create policy "members read profiles in own institution" on public.profiles
for select using (institution_id = public.current_institution_id());
create policy "admin manages profiles in own institution" on public.profiles
for all using (institution_id = public.current_institution_id() and public.current_role()='admin')
with check (institution_id = public.current_institution_id() and public.current_role()='admin');

create policy "members read students in own institution" on public.students
for select using (institution_id = public.current_institution_id());
create policy "admin manages students" on public.students
for all using (institution_id = public.current_institution_id() and public.current_role()='admin')
with check (institution_id = public.current_institution_id() and public.current_role()='admin');

create policy "members read attendance in own institution" on public.attendance
for select using (institution_id = public.current_institution_id());
create policy "members record attendance in own institution" on public.attendance
for insert with check (institution_id = public.current_institution_id() and recorded_by=auth.uid());

create policy "members read tests" on public.tests
for select using (institution_id = public.current_institution_id());
create policy "admin manages tests" on public.tests
for all using (institution_id = public.current_institution_id() and public.current_role()='admin')
with check (institution_id = public.current_institution_id() and public.current_role()='admin');

create policy "members read results" on public.test_results
for select using (institution_id = public.current_institution_id());
-- مؤقتًا الإدخال للإدارة فقط إلى حين حسم سياسة تعديل النتائج.
create policy "admin manages results" on public.test_results
for all using (institution_id = public.current_institution_id() and public.current_role()='admin')
with check (institution_id = public.current_institution_id() and public.current_role()='admin');

create policy "members read sessions" on public.sessions
for select using (institution_id = public.current_institution_id());
create policy "coach inserts own sessions" on public.sessions
for insert with check (institution_id=public.current_institution_id() and coach_id=auth.uid());
create policy "coach updates own sessions" on public.sessions
for update using (coach_id=auth.uid() and institution_id=public.current_institution_id())
with check (coach_id=auth.uid() and institution_id=public.current_institution_id());

create policy "coach notes owner only" on public.coach_notes
for all using (owner_id=auth.uid())
with check (owner_id=auth.uid());

create policy "members read audit log" on public.audit_log
for select using (institution_id=public.current_institution_id());
create policy "members append audit log" on public.audit_log
for insert with check (institution_id=public.current_institution_id() and actor_id=auth.uid());

-- ملاحظة: سياسات الإنتاج تحتاج مراجعة أمنية واختبارات فعلية، خصوصًا إنشاء المؤسسة/أول مدير،
-- تخزين الشعار، منع التلاعب بسجل التدقيق، وتقييد حقول التحديث حسب الدور.
