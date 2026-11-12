-- Menghapus SELURUH data dan objek Universe Collection Suite dari project Supabase,
-- termasuk akun login petugas yang dibuat oleh aplikasi ini.
-- Tidak menyentuh tabel lain di project. Tidak bisa dibatalkan.

do $$
begin
  if to_regclass('public.ucs_staff') is not null then
    delete from auth.users where id in (select user_id from public.ucs_staff where user_id is not null);
  end if;
end $$;

drop table if exists public.ucs_skip_cases, public.ucs_rmp, public.ucs_ttr, public.ucs_ptp,
  public.ucs_activities, public.ucs_accounts, public.ucs_staff, public.ucs_app_config cascade;
drop sequence if exists public.ucs_contract_seq;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname like 'ucs\_%' loop
    execute 'drop function if exists ' || f.sig || ' cascade';
  end loop;
end $$;
