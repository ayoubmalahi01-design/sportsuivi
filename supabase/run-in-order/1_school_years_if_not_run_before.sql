-- SportSuivi : السنوات الدراسية (إضافة فقط، لا حذف ولا تعديل لبياناتك). شغّله مرة واحدة فقط.
create table if not exists public.school_years (
  id uuid primary key default gen_random_uuid(),
  institution_id uuid not null default public.my_institution() references public.institutions(id) on delete cascade,
  name text not null,
  start_date date not null,
  end_date date,
  is_archived boolean not null default false,
  created_at timestamptz not null default now(),
  unique (institution_id, name)
);
alter table public.school_years enable row level security;
create policy school_years_read on public.school_years for select
  using (institution_id = public.my_institution());
create policy school_years_admin_write on public.school_years for all
  using (public.is_admin_level() and institution_id = public.my_institution())
  with check (public.is_admin_level() and institution_id = public.my_institution());
