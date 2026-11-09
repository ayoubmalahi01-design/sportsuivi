-- =====================================================================
-- SportSuivi : schéma Supabase (Postgres) — à exécuter UNE SEULE FOIS
-- dans Supabase > SQL Editor, sur un projet NEUF.
-- Rôles : super_admin > sub_admin > admin (الإدارة) > coach (المدرب)
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------- 1. Établissements ----------
create table institutions (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  logo_url text,
  created_at timestamptz not null default now()
);

-- ---------- 2. Profils (un par compte) ----------
create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  institution_id uuid not null references institutions(id),
  full_name text,
  role text not null default 'coach'
    check (role in ('super_admin','sub_admin','admin','coach')),
  status text not null default 'pending'
    check (status in ('pending','active','suspended')),
  created_at timestamptz not null default now()
);

-- ---------- 3. Fonctions utilitaires ----------
create or replace function my_institution() returns uuid
language sql stable security definer set search_path = public as $$
  select institution_id from profiles where id = auth.uid() and status = 'active'
$$;

create or replace function my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from profiles where id = auth.uid() and status = 'active'
$$;

create or replace function role_rank(r text) returns int
language sql immutable as $$
  select case r when 'super_admin' then 4 when 'sub_admin' then 3
                when 'admin' then 2 when 'coach' then 1 else 0 end
$$;

create or replace function is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select my_role() is not null
$$;

create or replace function is_admin_level() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(role_rank(my_role()) >= 2, false)
$$;

-- ---------- 4. Création de compte : toujours coach en attente ----------
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare inst uuid;
begin
  select id into inst from institutions order by created_at limit 1;
  if inst is null then
    raise exception 'Aucun établissement créé. Créez-le d''abord.';
  end if;
  insert into profiles (id, institution_id, full_name, role, status)
  values (new.id, inst, new.raw_user_meta_data->>'full_name', 'coach', 'pending');
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- ---------- 5. Garde anti-promotion sur profiles ----------
create or replace function guard_profile_update() returns trigger
language plpgsql security definer set search_path = public as $$
declare actor text; actor_rank int;
begin
  if auth.uid() is null then return new; end if;  -- SQL Editor / service role
  if new.id <> old.id or new.institution_id <> old.institution_id then
    raise exception 'Modification interdite';
  end if;
  if new.role <> old.role or new.status <> old.status then
    select role into actor from profiles where id = auth.uid() and status = 'active';
    actor_rank := role_rank(actor);
    if old.id = auth.uid() then
      raise exception 'Vous ne pouvez pas modifier votre propre rôle ou statut';
    end if;
    if actor_rank <= role_rank(old.role) then
      raise exception 'Permission insuffisante';
    end if;
    if new.role <> old.role then
      if role_rank(new.role) >= actor_rank then
        raise exception 'Vous ne pouvez pas attribuer ce rôle';
      end if;
      if new.role in ('admin','sub_admin') and actor_rank < 3 then
        raise exception 'Seul un sous-admin ou le super admin peut promouvoir en administration';
      end if;
    end if;
  end if;
  return new;
end $$;

create trigger profiles_guard
  before update on profiles
  for each row execute function guard_profile_update();

-- ---------- 6. Données métier ----------
create table classes (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null default my_institution() references institutions(id),
  name text not null,
  school_year text,
  created_at timestamptz not null default now()
);

create table students (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null default my_institution() references institutions(id),
  class_id uuid references classes(id),
  student_number int not null,
  full_name text not null,
  gender text check (gender in ('M','F')),
  birth_date date,
  archived boolean not null default false,
  created_at timestamptz not null default now(),
  unique (institution_id, student_number)
);

-- Tests et programmes (saisis par l'administration)
create table test_definitions (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null default my_institution() references institutions(id),
  name text not null,
  unit text,
  higher_is_better boolean not null default true,
  created_at timestamptz not null default now()
);

create table test_programs (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null default my_institution() references institutions(id),
  name text not null,
  test_ids uuid[] not null default '{}',
  created_at timestamptz not null default now()
);

-- Barèmes versionnés (contenu saisi/importé par l'administration, rien d'inventé)
create table scale_versions (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null default my_institution() references institutions(id),
  test_id uuid not null references test_definitions(id),
  version int not null default 1,
  valid_from date not null default current_date,
  rules jsonb not null default '[]',
  created_at timestamptz not null default now(),
  unique (test_id, version)
);

create table test_results (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null default my_institution() references institutions(id),
  student_id uuid not null references students(id),
  test_id uuid not null references test_definitions(id),
  program_id uuid references test_programs(id),
  raw_value numeric not null,
  score numeric,
  tested_on date not null default current_date,
  recorded_by uuid not null default auth.uid() references profiles(id),
  created_at timestamptz not null default now()
);

create table body_measurements (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null default my_institution() references institutions(id),
  student_id uuid not null references students(id),
  weight_kg numeric,
  height_cm numeric,
  measured_on date not null default current_date,
  recorded_by uuid not null default auth.uid() references profiles(id),
  created_at timestamptz not null default now()
);

-- Séances et présences (saisis par les coachs)
create table sessions (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null default my_institution() references institutions(id),
  coach_id uuid not null default auth.uid() references profiles(id),
  class_id uuid references classes(id),
  session_date date not null default current_date,
  start_time time,
  end_time time,
  notes text,
  created_at timestamptz not null default now()
);

create table attendance (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null default my_institution() references institutions(id),
  student_id uuid not null references students(id),
  session_id uuid references sessions(id),
  attendance_date date not null default current_date,
  status text not null check (status in
    ('present','absent','late','permission','exempt','official_duty')),
  recorded_by uuid not null default auth.uid() references profiles(id),
  created_at timestamptz not null default now(),
  unique (student_id, attendance_date, session_id)
);

create table observations (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null default my_institution() references institutions(id),
  student_id uuid not null references students(id),
  author_id uuid not null default auth.uid() references profiles(id),
  body text not null,
  created_at timestamptz not null default now()
);

-- Espace coachs : carnet privé + conversations (admin NE VOIT PAS)
create table coach_notebook (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null default auth.uid() references profiles(id),
  body text not null,
  created_at timestamptz not null default now()
);

create table chat_messages (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null default my_institution() references institutions(id),
  author_id uuid not null default auth.uid() references profiles(id),
  body text not null,
  reply_to uuid references chat_messages(id),
  created_at timestamptz not null default now()
);

-- Annonces officielles (administration -> coachs)
create table announcements (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null default my_institution() references institutions(id),
  author_id uuid not null default auth.uid() references profiles(id),
  title text not null,
  body text,
  created_at timestamptz not null default now()
);

-- Journal d'audit (écrit uniquement par triggers)
create table audit_log (
  id bigint generated always as identity primary key,
  institution_id uuid,
  actor_id uuid,
  table_name text not null,
  row_id uuid,
  action text not null,
  old_data jsonb,
  new_data jsonb,
  created_at timestamptz not null default now()
);

create or replace function write_audit() returns trigger
language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  r := to_jsonb(coalesce(new, old));
  insert into audit_log (institution_id, actor_id, table_name, row_id, action, old_data, new_data)
  values ((r->>'institution_id')::uuid, auth.uid(), tg_table_name,
          (r->>'id')::uuid, tg_op,
          case when tg_op <> 'INSERT' then to_jsonb(old) end,
          case when tg_op <> 'DELETE' then to_jsonb(new) end);
  return coalesce(new, old);
end $$;

do $$
declare t text;
begin
  foreach t in array array['profiles','students','test_definitions','scale_versions',
                           'test_results','body_measurements','attendance']
  loop
    execute format('create trigger audit_%1$s after insert or update or delete on %1$s
                    for each row execute function write_audit()', t);
  end loop;
end $$;

-- ---------- 7. RLS : tout est fermé par défaut ----------
do $$
declare t text;
begin
  foreach t in array array['institutions','profiles','classes','students','test_definitions',
    'test_programs','scale_versions','test_results','body_measurements','sessions',
    'attendance','observations','coach_notebook','chat_messages','announcements','audit_log']
  loop
    execute format('alter table %I enable row level security', t);
  end loop;
end $$;

create policy inst_read on institutions for select using (id = my_institution());
create policy inst_write on institutions for update
  using (is_admin_level() and id = my_institution());

create policy prof_read on profiles for select
  using (id = auth.uid() or institution_id = my_institution());
create policy prof_update on profiles for update
  using (id = auth.uid() or (is_admin_level() and institution_id = my_institution()));
-- aucune policy INSERT/DELETE : les profils sont créés uniquement par le trigger

-- Lecture pour tout le personnel actif, écriture réservée à l'administration
do $$
declare t text;
begin
  foreach t in array array['classes','students','test_definitions','test_programs',
                           'scale_versions','test_results','body_measurements']
  loop
    execute format('create policy %1$s_read on %1$s for select
                    using (institution_id = my_institution())', t);
    execute format('create policy %1$s_ins on %1$s for insert
                    with check (is_admin_level() and institution_id = my_institution())', t);
    execute format('create policy %1$s_upd on %1$s for update
                    using (is_admin_level() and institution_id = my_institution())', t);
  end loop;
end $$;

-- Séances : coach crée les siennes ; l'administration peut tout gérer
create policy sess_read on sessions for select using (institution_id = my_institution());
create policy sess_ins on sessions for insert
  with check (is_staff() and institution_id = my_institution() and coach_id = auth.uid());
create policy sess_upd on sessions for update
  using (institution_id = my_institution() and (coach_id = auth.uid() or is_admin_level()));

-- Présences : saisies par coach (ou administration)
create policy att_read on attendance for select using (institution_id = my_institution());
create policy att_ins on attendance for insert
  with check (is_staff() and institution_id = my_institution() and recorded_by = auth.uid());
create policy att_upd on attendance for update
  using (institution_id = my_institution() and (recorded_by = auth.uid() or is_admin_level()));

-- Observations : tout le personnel lit, chacun modifie les siennes
create policy obs_read on observations for select using (institution_id = my_institution());
create policy obs_ins on observations for insert
  with check (is_staff() and institution_id = my_institution() and author_id = auth.uid());
create policy obs_upd on observations for update using (author_id = auth.uid());
create policy obs_del on observations for delete using (author_id = auth.uid());

-- Carnet privé : propriétaire uniquement (aucun accès admin)
create policy nb_all on coach_notebook for all
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- Conversations : COACHS uniquement (l'administration ne lit pas)
create policy chat_read on chat_messages for select
  using (my_role() = 'coach' and institution_id = my_institution());
create policy chat_ins on chat_messages for insert
  with check (my_role() = 'coach' and institution_id = my_institution()
              and author_id = auth.uid());

-- Annonces : l'administration publie, tout le personnel lit
create policy ann_read on announcements for select using (institution_id = my_institution());
create policy ann_ins on announcements for insert
  with check (is_admin_level() and institution_id = my_institution() and author_id = auth.uid());

-- Audit : lecture administration uniquement ; aucune écriture directe
create policy audit_read on audit_log for select
  using (is_admin_level() and institution_id = my_institution());

-- =====================================================================
-- 8. DÉMARRAGE (à exécuter dans l'ordre, après le script ci-dessus)
-- =====================================================================
-- (a) Créer l'établissement :
--     insert into institutions (name) values ('الإدارة العامة للتكوين');
-- (b) Dans l'app (ou Supabase > Authentication > Add user) créer VOTRE compte.
-- (c) Vous promouvoir super admin (remplacez l'email) :
--     update profiles set role = 'super_admin', status = 'active'
--     where id = (select id from auth.users where email = 'VOTRE_EMAIL');