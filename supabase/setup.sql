-- =====================================================================
-- Universe Collection Suite · backend Supabase
--
-- Jalankan sekali di Supabase SQL Editor. Aman dijalankan ulang.
-- Semua objek memakai awalan ucs_ supaya tidak bentrok dengan tabel lain
-- di project yang sama.
--
-- Prinsip:
--   * Tabel hanya bisa DIBACA oleh petugas aktif yang sudah login (RLS).
--   * Semua penulisan lewat fungsi ucs_* (RPC). Fungsi memeriksa peran,
--     memvalidasi input, dan menulis beberapa tabel dalam satu transaksi.
--   * Waktu disimpan sebagai jam lokal WIB (timestamp tanpa zona).
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------
-- Waktu lokal
-- ---------------------------------------------------------------------
create or replace function public.ucs_now() returns timestamp
language sql stable as $$ select (now() at time zone 'Asia/Jakarta')::timestamp(0) $$;

create or replace function public.ucs_today() returns date
language sql stable as $$ select (now() at time zone 'Asia/Jakarta')::date $$;

-- ---------------------------------------------------------------------
-- Tabel
-- ---------------------------------------------------------------------
create table if not exists public.ucs_app_config (
  id            smallint primary key default 1 check (id = 1),
  branch        text not null default 'Cabang Bekasi',
  process_date  date not null default public.ucs_today(),
  ptp_max_days  int  not null default 7 check (ptp_max_days between 1 and 31),
  email_domain  text not null default 'ucs-demo.example.com'
);
insert into public.ucs_app_config (id) values (1) on conflict (id) do nothing;

create table if not exists public.ucs_staff (
  id          text primary key check (id ~ '^[A-Z0-9]{3,8}$'),
  name        text not null check (length(trim(name)) > 0),
  role        text not null check (role in ('FC','TELE','ADMIN')),
  scope       text not null default '',
  email       text unique,
  user_id     uuid unique references auth.users(id) on delete set null,
  active      boolean not null default true,
  created_at  timestamp not null default public.ucs_now()
);

create sequence if not exists public.ucs_contract_seq start 30000;

create table if not exists public.ucs_accounts (
  contract_no     text primary key,
  name            text not null,
  phone           text not null,
  phone_status    text not null default 'VALID' check (phone_status in ('VALID','INVALID','UNMATCH')),
  job             text not null default '',
  address         text not null,
  area            text not null default '',
  zipcode         text not null default '',
  product         text not null default '2W' check (product in ('2W','4W')),
  unit            text not null,
  year            int,
  plate           text not null default '',
  tenor           int not null check (tenor > 0),
  inst_no         int not null default 1,
  installment     bigint not null check (installment > 0),
  oldest_due      date not null,
  due_day         int,
  dpd             int not null default 0,
  days_to_due     int not null default 0,
  bucket          text not null default 'B0' check (bucket in ('B0','B1','B2','B3','B4UP','WO')),
  stage           text not null default 'REMINDER',
  overdue_count   int not null default 0,
  overdue_amount  bigint not null default 0,
  penalty         bigint not null default 0,
  os_principal    bigint not null default 0,
  mob             int not null default 1,
  segment         text not null default 'MEDIUM' check (segment in ('HIGH','MEDIUM','LOW')),
  max_dpd_12m     int not null default 0,
  sp_level        int not null default 0 check (sp_level between 0 and 3),
  collector_id    text references public.ucs_staff(id) on update cascade on delete set null,
  rmp_flag        boolean not null default false,
  unit_status     text not null default 'WITH_DEBTOR' check (unit_status in ('WITH_DEBTOR','NOT_SEEN','TRANSFERRED','REPOSSESSED')),
  emergency       jsonb not null default '{}'::jsonb,
  extra_contacts  jsonb not null default '[]'::jsonb,
  last_contact    jsonb,
  active_ptp      jsonb,
  field_paid      bigint not null default 0,
  escalated       boolean not null default false,
  lat             double precision,
  lng             double precision,
  updated_at      timestamp not null default public.ucs_now()
);
create index if not exists ucs_accounts_collector on public.ucs_accounts (collector_id);
create index if not exists ucs_accounts_bucket on public.ucs_accounts (bucket);

create table if not exists public.ucs_activities (
  id              text primary key default 'act-' || replace(gen_random_uuid()::text, '-', ''),
  contract_no     text not null references public.ucs_accounts(contract_no) on update cascade on delete cascade,
  type            text not null check (type in ('CALL','VISIT','SP','NOTE')),
  result          text not null,
  actor           text references public.ucs_staff(id) on update cascade on delete set null,
  occurred_at     timestamp not null default public.ucs_now(),
  work_date       date not null,
  notes           text not null default '',
  met_with        text,
  contacted       text,
  phone           text,
  next_action     text,
  ptp_date        date,
  ptp_amount      bigint,
  amount          bigint,
  ttr_no          text,
  unit_seen       boolean,
  photos          int,
  checkin_at      timestamp,
  checkin_lat     double precision,
  checkin_lng     double precision,
  gps_accuracy_m  int,
  distance_m      int,
  gps_dummy       boolean
);
create index if not exists ucs_activities_contract on public.ucs_activities (contract_no, occurred_at desc);
create index if not exists ucs_activities_work on public.ucs_activities (work_date, type);

create table if not exists public.ucs_ptp (
  id            text primary key default 'ptp-' || replace(gen_random_uuid()::text, '-', ''),
  contract_no   text not null references public.ucs_accounts(contract_no) on update cascade on delete cascade,
  promise_date  date not null,
  amount        bigint not null check (amount > 0),
  status        text not null default 'ACTIVE' check (status in ('ACTIVE','KEPT','BROKEN','CANCELLED')),
  source        text not null check (source in ('CALL','VISIT')),
  actor         text references public.ucs_staff(id) on update cascade on delete set null,
  activity_id   text,
  created_at    timestamp not null default public.ucs_now()
);
create index if not exists ucs_ptp_contract on public.ucs_ptp (contract_no, status);
create unique index if not exists ucs_ptp_one_active on public.ucs_ptp (contract_no) where status = 'ACTIVE';

create table if not exists public.ucs_ttr (
  ttr_no          text primary key check (ttr_no ~ '^TTR-[0-9]{7}$'),
  status          text not null default 'ISSUED' check (status in ('ISSUED','USED','VOID')),
  issued_to       text references public.ucs_staff(id) on update cascade on delete set null,
  issued_at       timestamp not null default public.ucs_now(),
  contract_no     text references public.ucs_accounts(contract_no) on update cascade on delete set null,
  amount          bigint not null default 0,
  payer           text not null default '',
  used_at         timestamp,
  akh_date        date,
  deposit_status  text not null default '' check (deposit_status in ('','PENDING','MATCHED')),
  deposit_at      timestamp
);
create index if not exists ucs_ttr_holder on public.ucs_ttr (issued_to, status);

create table if not exists public.ucs_rmp (
  id           text primary key default 'rmp-' || replace(gen_random_uuid()::text, '-', ''),
  contract_no  text not null references public.ucs_accounts(contract_no) on update cascade on delete cascade,
  type         text not null check (type in ('DEFERRAL','TENOR_EXT','FORBEARANCE','SPP','RESTRUCTURE','SETTLEMENT')),
  reason       text not null,
  status       text not null default 'DIAJUKAN' check (status in ('DIAJUKAN','DISETUJUI','DITOLAK')),
  channel      text not null check (channel in ('MOBILE','TELE')),
  actor        text references public.ucs_staff(id) on update cascade on delete set null,
  created_at   timestamp not null default public.ucs_now(),
  decided_by   text references public.ucs_staff(id) on update cascade on delete set null,
  decided_at   timestamp
);

create table if not exists public.ucs_skip_cases (
  id              text primary key default 'skip-' || replace(gen_random_uuid()::text, '-', ''),
  contract_no     text not null references public.ucs_accounts(contract_no) on update cascade on delete cascade,
  trigger_source  text not null check (trigger_source in ('CALL_INVALID','CALL_UNMATCH','VISIT_ADDR_INVALID')),
  status          text not null default 'OPEN' check (status in ('OPEN','FOUND','NOT_FOUND')),
  note            text not null default '',
  new_contact     text not null default '',
  actor           text references public.ucs_staff(id) on update cascade on delete set null,
  created_at      timestamp not null default public.ucs_now(),
  closed_by       text references public.ucs_staff(id) on update cascade on delete set null,
  closed_at       timestamp
);

-- ---------------------------------------------------------------------
-- Identitas petugas yang sedang login
-- ---------------------------------------------------------------------
create or replace function public.ucs_is_staff() returns boolean
language sql stable security definer set search_path = public
as $$ select exists (select 1 from public.ucs_staff where user_id = auth.uid() and active) $$;

create or replace function public.ucs_require(p_roles text[] default null) returns public.ucs_staff
language plpgsql stable security definer set search_path = public as $$
declare s public.ucs_staff;
begin
  select * into s from public.ucs_staff where user_id = auth.uid() and active;
  if not found then
    raise exception 'Sesi tidak valid atau akun tidak aktif. Silakan masuk kembali.' using errcode = '42501';
  end if;
  if p_roles is not null and not (s.role = any (p_roles)) then
    raise exception 'Akses ditolak: peran % tidak boleh melakukan aksi ini.', s.role using errcode = '42501';
  end if;
  return s;
end $$;

-- Dipanggil layar login sebelum masuk: ID petugas -> email login dan peran.
create or replace function public.ucs_staff_login(p_id text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('email', email, 'role', role)
    from public.ucs_staff
   where id = upper(trim(p_id)) and active and email is not null and user_id is not null
$$;

create or replace function public.ucs_whoami() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', id, 'name', name, 'role', role, 'scope', scope)
    from public.ucs_staff where user_id = auth.uid() and active
$$;

-- ---------------------------------------------------------------------
-- Aturan bisnis bersama
-- ---------------------------------------------------------------------
-- Posisi tunggakan dari jatuh tempo tertua yang belum lunas (PRD Proses 1).
create or replace function public.ucs_position(
  p_due date, p_inst bigint, p_date date,
  out dpd int, out days_to_due int, out bucket text, out stage text,
  out overdue_count int, out overdue_amount bigint, out penalty bigint, out due_day int)
language plpgsql immutable as $$
declare diff int := p_date - p_due;
begin
  dpd            := greatest(diff, 0);
  days_to_due    := greatest(-diff, 0);
  bucket         := case when diff <= 0 then 'B0' when diff <= 30 then 'B1' when diff <= 60 then 'B2' when diff <= 90 then 'B3' else 'B4UP' end;
  stage          := case when diff <= 0 then 'REMINDER' when diff <= 7 then 'TELE' when diff <= 30 then 'FIELD' when diff <= 60 then 'REMEDIAL' else 'END_BUCKET' end;
  overdue_count  := case when diff <= 0 then 0 else 1 + diff / 30 end;
  overdue_amount := overdue_count * p_inst;
  penalty        := (round(p_inst * 0.005 * dpd * greatest(overdue_count, 1) / 1000.0) * 1000)::bigint;
  due_day        := extract(day from p_due)::int;
end $$;

-- SP 1 di DPD 7, SP 2 di DPD 14, SP 3 di DPD 21.
create or replace function public.ucs_sp_due(p_dpd int) returns int
language sql immutable as $$
  select case when p_dpd >= 21 then 3 when p_dpd >= 14 then 2 when p_dpd >= 7 then 1 else 0 end
$$;

create or replace function public.ucs_check_ptp(p_date date, p_amount bigint) returns void
language plpgsql stable set search_path = public as $$
declare c public.ucs_app_config;
begin
  select * into c from public.ucs_app_config where id = 1;
  if p_date is null or p_date < c.process_date or p_date > c.process_date + c.ptp_max_days then
    raise exception 'Tanggal janji harus antara % dan %.',
      to_char(c.process_date, 'DD-MM-YYYY'), to_char(c.process_date + c.ptp_max_days, 'DD-MM-YYYY');
  end if;
  if coalesce(p_amount, 0) <= 0 then
    raise exception 'Isi nominal janji bayar.';
  end if;
end $$;

-- Petugas lapangan aktif dengan beban account paling sedikit.
create or replace function public.ucs_least_loaded_fc() returns text
language sql stable set search_path = public as $$
  select s.id from public.ucs_staff s
   where s.role = 'FC' and s.active
   order by (select count(*) from public.ucs_accounts a where a.collector_id = s.id), s.id
   limit 1
$$;

-- Membuat atau memperbarui pengguna Supabase Auth (email sudah terkonfirmasi).
create or replace function public.ucs_create_auth_user(p_email text, p_password text) returns uuid
language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid;
begin
  select id into uid from auth.users where lower(email) = lower(p_email);
  if uid is not null then
    update auth.users
       set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')),
           email_confirmed_at = coalesce(email_confirmed_at, now()),
           updated_at = now()
     where id = uid;
    return uid;
  end if;
  uid := gen_random_uuid();
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change)
  values (
    '00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', lower(p_email),
    extensions.crypt(p_password, extensions.gen_salt('bf')), now(),
    '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb, now(), now(),
    '', '', '', '');
  insert into auth.identities (id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), uid::text, uid,
          jsonb_build_object('sub', uid::text, 'email', lower(p_email), 'email_verified', true),
          'email', now(), now(), now());
  return uid;
end $$;

-- Menyimpan petugas dan (jika ada kata sandi) akun login-nya.
create or replace function public.ucs_put_staff(p_id text, p_name text, p_role text, p_scope text, p_password text)
returns void language plpgsql security definer set search_path = public as $$
declare v_dom text; v_email text; v_uid uuid;
begin
  select email_domain into v_dom from public.ucs_app_config where id = 1;
  insert into public.ucs_staff (id, name, role, scope, email, active)
  values (p_id, trim(p_name), p_role, coalesce(trim(p_scope), ''), lower(p_id) || '@' || v_dom, true)
  on conflict (id) do update
     set name = excluded.name, role = excluded.role, scope = excluded.scope, active = true,
         email = coalesce(public.ucs_staff.email, excluded.email);
  if p_password is not null then
    select email into v_email from public.ucs_staff where id = p_id;
    v_uid := public.ucs_create_auth_user(v_email, p_password);
    update public.ucs_staff set user_id = v_uid where id = p_id;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- RPC: Front Coll
-- ---------------------------------------------------------------------
create or replace function public.ucs_record_visit(
  p_contract_no text, p_result text,
  p_met_with text default 'DEBTOR', p_notes text default '', p_unit_seen boolean default true,
  p_amount bigint default null, p_ttr_no text default null, p_payer text default null,
  p_ptp_date date default null, p_ptp_amount bigint default null,
  p_checkin_at timestamp default null, p_lat double precision default null, p_lng double precision default null,
  p_accuracy int default null, p_distance int default null, p_photos int default 0)
returns text language plpgsql security definer set search_path = public as $$
declare
  me public.ucs_staff; a public.ucs_accounts; cfg public.ucs_app_config;
  v_now timestamp := public.ucs_now(); v_id text := 'act-' || replace(gen_random_uuid()::text, '-', '');
  v_notes text := trim(coalesce(p_notes, '')); v_unit text;
begin
  me := public.ucs_require(array['FC','ADMIN']);
  select * into cfg from public.ucs_app_config where id = 1;
  select * into a from public.ucs_accounts where contract_no = p_contract_no for update;
  if not found then raise exception 'Account % tidak ditemukan.', p_contract_no; end if;
  if p_result is null or p_result not in ('PAID','PTP','MEET_NOPAY','NOTMEET','ADDR_INVALID','UNIT_MOVED','UNCOOP','OUT_AREA','RMP_REQ') then
    raise exception 'Pilih hasil kunjungan.';
  end if;
  if p_result not in ('PAID','PTP') and v_notes = '' then
    raise exception 'Catatan wajib diisi untuk hasil ini.';
  end if;

  if p_result = 'PAID' then
    if coalesce(p_amount, 0) <= 0 then raise exception 'Isi nominal yang diterima.'; end if;
    update public.ucs_ttr
       set status = 'USED', contract_no = a.contract_no, amount = p_amount,
           payer = coalesce(nullif(trim(p_payer), ''), a.name),
           used_at = v_now, akh_date = cfg.process_date, deposit_status = 'PENDING'
     where ttr_no = p_ttr_no and issued_to = me.id and status = 'ISSUED';
    if not found then
      raise exception 'TTR % tidak tersedia atau bukan milik Anda.', coalesce(p_ttr_no, '(kosong)');
    end if;
    update public.ucs_ptp set status = 'KEPT' where contract_no = a.contract_no and status = 'ACTIVE';
    if found then a.active_ptp := null; end if;
    a.field_paid := a.field_paid + p_amount;
  elsif p_result = 'PTP' then
    perform public.ucs_check_ptp(p_ptp_date, p_ptp_amount);
    update public.ucs_ptp set status = 'BROKEN' where contract_no = a.contract_no and status = 'ACTIVE';
    insert into public.ucs_ptp (contract_no, promise_date, amount, status, source, actor, activity_id, created_at)
    values (a.contract_no, p_ptp_date, p_ptp_amount, 'ACTIVE', 'VISIT', me.id, v_id, v_now);
    a.active_ptp := jsonb_build_object('date', p_ptp_date, 'amount', p_ptp_amount);
  elsif p_result = 'ADDR_INVALID' then
    insert into public.ucs_skip_cases (contract_no, trigger_source, note, actor, created_at)
    values (a.contract_no, 'VISIT_ADDR_INVALID', v_notes, me.id, v_now);
  end if;

  v_unit := case when p_result = 'UNIT_MOVED' then 'TRANSFERRED'
                 when not coalesce(p_unit_seen, true) then 'NOT_SEEN'
                 when a.unit_status = 'NOT_SEEN' then 'WITH_DEBTOR'
                 else a.unit_status end;

  insert into public.ucs_activities (
    id, contract_no, type, result, actor, occurred_at, work_date, notes, met_with, unit_seen, photos,
    amount, ttr_no, ptp_date, ptp_amount, checkin_at, checkin_lat, checkin_lng, gps_accuracy_m, distance_m, gps_dummy)
  values (
    v_id, a.contract_no, 'VISIT', p_result, me.id, v_now, cfg.process_date, v_notes,
    coalesce(p_met_with, 'DEBTOR'), coalesce(p_unit_seen, true), coalesce(p_photos, 0),
    case when p_result = 'PAID' then p_amount end, case when p_result = 'PAID' then p_ttr_no end,
    case when p_result = 'PTP' then p_ptp_date end, case when p_result = 'PTP' then p_ptp_amount end,
    coalesce(p_checkin_at, v_now), p_lat, p_lng, p_accuracy, p_distance, true);

  update public.ucs_accounts
     set last_contact = jsonb_build_object('at', v_now, 'type', 'VISIT', 'result', p_result),
         escalated = false, unit_status = v_unit, active_ptp = a.active_ptp,
         field_paid = a.field_paid, updated_at = v_now
   where contract_no = a.contract_no;
  return v_id;
end $$;

create or replace function public.ucs_deposit_ttr() returns int
language plpgsql security definer set search_path = public as $$
declare me public.ucs_staff; n int;
begin
  me := public.ucs_require(array['FC']);
  with u as (
    update public.ucs_ttr set deposit_status = 'MATCHED', deposit_at = public.ucs_now()
     where issued_to = me.id and status = 'USED' and deposit_status = 'PENDING'
    returning 1)
  select count(*) into n from u;
  if n = 0 then raise exception 'Tidak ada TTR yang perlu disetor.'; end if;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- RPC: Desk Call
-- ---------------------------------------------------------------------
create or replace function public.ucs_record_call(
  p_contract_no text, p_result text,
  p_phone text default null, p_contacted text default 'DEBTOR', p_notes text default '',
  p_ptp_date date default null, p_ptp_amount bigint default null,
  p_next_action text default null, p_rmp_type text default 'TENOR_EXT')
returns text language plpgsql security definer set search_path = public as $$
declare
  me public.ucs_staff; a public.ucs_accounts; cfg public.ucs_app_config;
  v_now timestamp := public.ucs_now(); v_id text := 'act-' || replace(gen_random_uuid()::text, '-', '');
  v_notes text := trim(coalesce(p_notes, '')); v_phone text;
begin
  me := public.ucs_require(array['TELE','ADMIN']);
  select * into cfg from public.ucs_app_config where id = 1;
  select * into a from public.ucs_accounts where contract_no = p_contract_no for update;
  if not found then raise exception 'Account % tidak ditemukan.', p_contract_no; end if;
  if p_result is null or p_result not in ('PTP','PAID','NOANS','BUSY','INVALID','UNMATCH','REFUSE','RMP') then
    raise exception 'Pilih hasil call.';
  end if;
  if p_result in ('REFUSE','UNMATCH','PAID') and v_notes = '' then
    raise exception 'Catatan wajib diisi untuk hasil ini.';
  end if;
  if p_result = 'BUSY' and trim(coalesce(p_next_action, '')) = '' then
    raise exception 'Isi waktu untuk menghubungi lagi.';
  end if;
  v_phone := coalesce(nullif(trim(p_phone), ''), a.phone);

  if p_result = 'PTP' then
    perform public.ucs_check_ptp(p_ptp_date, p_ptp_amount);
    update public.ucs_ptp set status = 'BROKEN' where contract_no = a.contract_no and status = 'ACTIVE';
    insert into public.ucs_ptp (contract_no, promise_date, amount, status, source, actor, activity_id, created_at)
    values (a.contract_no, p_ptp_date, p_ptp_amount, 'ACTIVE', 'CALL', me.id, v_id, v_now);
    a.active_ptp := jsonb_build_object('date', p_ptp_date, 'amount', p_ptp_amount);
  elsif p_result in ('INVALID','UNMATCH') then
    if v_phone = a.phone then a.phone_status := p_result; end if;
    insert into public.ucs_skip_cases (contract_no, trigger_source, note, actor, created_at)
    values (a.contract_no, 'CALL_' || p_result,
            coalesce(nullif(v_notes, ''), 'Nomor ' || v_phone || case when p_result = 'INVALID' then ' tidak valid.' else ' bukan milik debitur.' end),
            me.id, v_now);
  elsif p_result = 'REFUSE' then
    a.escalated := true;
    if a.collector_id is null then a.collector_id := public.ucs_least_loaded_fc(); end if;
  elsif p_result = 'RMP' then
    if exists (select 1 from public.ucs_rmp where contract_no = a.contract_no and status = 'DIAJUKAN') then
      raise exception 'Masih ada pengajuan RMP yang menunggu keputusan untuk account ini.';
    end if;
    insert into public.ucs_rmp (contract_no, type, reason, status, channel, actor, created_at)
    values (a.contract_no, coalesce(p_rmp_type, 'TENOR_EXT'),
            coalesce(nullif(v_notes, ''), 'Permintaan keringanan lewat telepon.'), 'DIAJUKAN', 'TELE', me.id, v_now);
  end if;

  insert into public.ucs_activities (
    id, contract_no, type, result, actor, occurred_at, work_date, notes, phone, contacted, next_action, ptp_date, ptp_amount)
  values (
    v_id, a.contract_no, 'CALL', p_result, me.id, v_now, cfg.process_date, v_notes, v_phone,
    coalesce(p_contacted, 'DEBTOR'), nullif(trim(coalesce(p_next_action, '')), ''),
    case when p_result = 'PTP' then p_ptp_date end, case when p_result = 'PTP' then p_ptp_amount end);

  update public.ucs_accounts
     set last_contact = jsonb_build_object('at', v_now, 'type', 'CALL', 'result', p_result),
         phone_status = a.phone_status, escalated = a.escalated, collector_id = a.collector_id,
         active_ptp = a.active_ptp, updated_at = v_now
   where contract_no = a.contract_no;
  return v_id;
end $$;

create or replace function public.ucs_set_ptp_status(p_id text, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare p public.ucs_ptp;
begin
  perform public.ucs_require(array['TELE','ADMIN']);
  if p_status not in ('KEPT','BROKEN') then raise exception 'Status janji bayar tidak dikenal.'; end if;
  select * into p from public.ucs_ptp where id = p_id for update;
  if not found then raise exception 'Janji bayar tidak ditemukan.'; end if;
  if p.status <> 'ACTIVE' then raise exception 'Janji bayar ini sudah ditutup.'; end if;
  update public.ucs_ptp set status = p_status where id = p_id;
  update public.ucs_accounts set active_ptp = null, updated_at = public.ucs_now() where contract_no = p.contract_no;
end $$;

create or replace function public.ucs_resolve_skip(
  p_id text, p_found boolean, p_type text default 'PHONE', p_value text default null, p_source text default null)
returns void language plpgsql security definer set search_path = public as $$
declare me public.ucs_staff; c public.ucs_skip_cases; v_val text := trim(coalesce(p_value, ''));
begin
  me := public.ucs_require(array['TELE','ADMIN']);
  select * into c from public.ucs_skip_cases where id = p_id for update;
  if not found then raise exception 'Kasus skip tracing tidak ditemukan.'; end if;
  if c.status <> 'OPEN' then raise exception 'Kasus ini sudah ditutup.'; end if;
  if not p_found then
    update public.ucs_skip_cases set status = 'NOT_FOUND', closed_by = me.id, closed_at = public.ucs_now() where id = p_id;
    return;
  end if;
  if v_val = '' then raise exception 'Isi nomor atau alamat baru terlebih dahulu.'; end if;
  if p_type not in ('PHONE','ADDRESS') then raise exception 'Jenis data baru tidak dikenal.'; end if;
  update public.ucs_skip_cases
     set status = 'FOUND', new_contact = v_val, closed_by = me.id, closed_at = public.ucs_now()
   where id = p_id;
  update public.ucs_accounts
     set extra_contacts = extra_contacts || jsonb_build_array(jsonb_build_object(
           'type', p_type, 'value', v_val, 'source', coalesce(nullif(trim(p_source), ''), 'skip tracing'))),
         phone_status = case when p_type = 'PHONE' then 'VALID' else phone_status end,
         updated_at = public.ucs_now()
   where contract_no = c.contract_no;
end $$;

create or replace function public.ucs_issue_sp(p_contract_no text) returns int
language plpgsql security definer set search_path = public as $$
declare me public.ucs_staff; a public.ucs_accounts; cfg public.ucs_app_config; n int;
begin
  me := public.ucs_require(array['TELE','ADMIN']);
  select * into cfg from public.ucs_app_config where id = 1;
  select * into a from public.ucs_accounts where contract_no = p_contract_no for update;
  if not found then raise exception 'Account % tidak ditemukan.', p_contract_no; end if;
  n := a.sp_level + 1;
  if n > public.ucs_sp_due(a.dpd) then
    raise exception 'SP % belum waktunya terbit untuk DPD %.', n, a.dpd;
  end if;
  insert into public.ucs_activities (contract_no, type, result, actor, work_date, notes)
  values (a.contract_no, 'SP', 'SP ' || n, me.id, cfg.process_date,
          'Surat peringatan ' || n || ' diterbitkan untuk dikirim ke alamat debitur.');
  update public.ucs_accounts set sp_level = n, updated_at = public.ucs_now() where contract_no = a.contract_no;
  return n;
end $$;

-- ---------------------------------------------------------------------
-- RPC: dipakai kedua aplikasi
-- ---------------------------------------------------------------------
create or replace function public.ucs_add_contact(p_contract_no text, p_type text, p_value text, p_source text default '')
returns void language plpgsql security definer set search_path = public as $$
declare me public.ucs_staff; v_val text := trim(coalesce(p_value, ''));
begin
  me := public.ucs_require(null);
  if p_type not in ('PHONE','ADDRESS') then raise exception 'Jenis kontak tidak dikenal.'; end if;
  if v_val = '' then raise exception 'Isi nomor atau alamat baru terlebih dahulu.'; end if;
  if length(v_val) > 300 then raise exception 'Kontak terlalu panjang (maksimal 300 karakter).'; end if;
  update public.ucs_accounts
     set extra_contacts = extra_contacts || jsonb_build_array(jsonb_build_object(
           'type', p_type, 'value', v_val,
           'source', coalesce(nullif(trim(p_source), ''), case when me.role = 'FC' then 'kunjungan' else 'desk call' end))),
         updated_at = public.ucs_now()
   where contract_no = p_contract_no;
  if not found then raise exception 'Account % tidak ditemukan.', p_contract_no; end if;
end $$;

create or replace function public.ucs_submit_rmp(p_contract_no text, p_type text, p_reason text)
returns text language plpgsql security definer set search_path = public as $$
declare me public.ucs_staff; a public.ucs_accounts; v_id text; lim_last int; lim_hist int;
begin
  me := public.ucs_require(null);
  select * into a from public.ucs_accounts where contract_no = p_contract_no;
  if not found then raise exception 'Account % tidak ditemukan.', p_contract_no; end if;
  if trim(coalesce(p_reason, '')) = '' then raise exception 'Isi alasan penurunan kemampuan bayar.'; end if;
  if p_type not in ('DEFERRAL','TENOR_EXT','FORBEARANCE','SPP','RESTRUCTURE','SETTLEMENT') then
    raise exception 'Jenis program tidak dikenal.';
  end if;
  -- Persyaratan utama RMP (PRD Proses 5)
  if a.mob <= 6 then raise exception 'Tidak memenuhi syarat: masa aktif kontrak harus lebih dari 6 bulan (MOB %).', a.mob; end if;
  if a.rmp_flag then raise exception 'Tidak memenuhi syarat: account sudah pernah mendapat program RMP.'; end if;
  select l, h into lim_last, lim_hist from (values
    ('DEFERRAL', 30, 90), ('TENOR_EXT', 90, 90), ('SPP', 180, 180), ('RESTRUCTURE', 60, 60)) v(t, l, h)
   where t = p_type;
  if lim_last is not null and a.dpd > lim_last then
    raise exception 'Tidak memenuhi syarat: status terakhir maksimal % hari (DPD %).', lim_last, a.dpd;
  end if;
  if lim_hist is not null and a.max_dpd_12m > lim_hist then
    raise exception 'Tidak memenuhi syarat: status sebelumnya pernah di atas % hari.', lim_hist;
  end if;
  if exists (select 1 from public.ucs_rmp where contract_no = a.contract_no and status = 'DIAJUKAN') then
    raise exception 'Masih ada pengajuan RMP yang menunggu keputusan untuk account ini.';
  end if;
  insert into public.ucs_rmp (contract_no, type, reason, status, channel, actor)
  values (a.contract_no, p_type, trim(p_reason), 'DIAJUKAN', case when me.role = 'FC' then 'MOBILE' else 'TELE' end, me.id)
  returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- RPC: admin
-- ---------------------------------------------------------------------
create or replace function public.ucs_decide_rmp(p_id text, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare me public.ucs_staff; r public.ucs_rmp;
begin
  me := public.ucs_require(array['ADMIN']);
  if p_status not in ('DISETUJUI','DITOLAK') then raise exception 'Keputusan tidak dikenal.'; end if;
  select * into r from public.ucs_rmp where id = p_id for update;
  if not found then raise exception 'Pengajuan RMP tidak ditemukan.'; end if;
  if r.status <> 'DIAJUKAN' then raise exception 'Pengajuan ini sudah diputuskan.'; end if;
  update public.ucs_rmp set status = p_status, decided_by = me.id, decided_at = public.ucs_now() where id = p_id;
  if p_status = 'DISETUJUI' then
    update public.ucs_accounts set rmp_flag = true, updated_at = public.ucs_now() where contract_no = r.contract_no;
  end if;
end $$;

create or replace function public.ucs_issue_ttr(p_fc text, p_start bigint, p_count int) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform public.ucs_require(array['ADMIN']);
  if not exists (select 1 from public.ucs_staff where id = p_fc and role = 'FC' and active) then
    raise exception 'Petugas % bukan field collector aktif.', p_fc;
  end if;
  if coalesce(p_start, 0) <= 0 or coalesce(p_count, 0) not between 1 and 20 then
    raise exception 'Isi nomor awal dan jumlah lembar (1 sampai 20).';
  end if;
  if p_start + p_count - 1 > 9999999 then raise exception 'Nomor TTR maksimal 7 digit.'; end if;
  with ins as (
    insert into public.ucs_ttr (ttr_no, status, issued_to)
    select 'TTR-' || lpad((p_start + g)::text, 7, '0'), 'ISSUED', p_fc from generate_series(0, p_count - 1) g
    on conflict (ttr_no) do nothing
    returning 1)
  select count(*) into n from ins;
  if n = 0 then raise exception 'Semua nomor pada rentang itu sudah terdaftar.'; end if;
  return n;
end $$;

create or replace function public.ucs_void_ttr(p_ttr_no text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.ucs_require(array['ADMIN']);
  update public.ucs_ttr set status = 'VOID' where ttr_no = p_ttr_no and status = 'ISSUED';
  if not found then raise exception 'Hanya TTR yang belum dipakai yang bisa dibatalkan.'; end if;
end $$;

create or replace function public.ucs_assign_collector(p_contract_no text, p_collector_id text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform public.ucs_require(array['ADMIN']);
  if p_collector_id is not null and not exists (
       select 1 from public.ucs_staff where id = p_collector_id and role = 'FC' and active) then
    raise exception 'Petugas % bukan field collector aktif.', p_collector_id;
  end if;
  update public.ucs_accounts set collector_id = p_collector_id, updated_at = public.ucs_now()
   where contract_no = p_contract_no;
  if not found then raise exception 'Account % tidak ditemukan.', p_contract_no; end if;
end $$;

-- p berisi field form account. Posisi tunggakan dihitung di server.
create or replace function public.ucs_save_account(p_contract_no text, p jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare
  cfg public.ucs_app_config; old public.ucs_accounts; pos record;
  v_no text; v_due date; v_inst bigint; v_tenor int; v_instno int; v_year int; v_mob int; v_product text;
begin
  perform public.ucs_require(array['ADMIN']);
  select * into cfg from public.ucs_app_config where id = 1;
  if trim(coalesce(p->>'name', '')) = '' or trim(coalesce(p->>'phone', '')) = ''
     or trim(coalesce(p->>'address', '')) = '' or trim(coalesce(p->>'unit', '')) = '' then
    raise exception 'Nama, telepon, alamat dan unit wajib diisi.';
  end if;
  begin
    v_due := nullif(p->>'oldest_due', '')::date;
    v_inst := nullif(p->>'installment', '')::bigint;
    v_tenor := coalesce(nullif(p->>'tenor', '')::int, 36);
    v_instno := coalesce(nullif(p->>'inst_no', '')::int, 1);
    v_year := nullif(p->>'year', '')::int;
    v_mob := coalesce(nullif(p->>'mob', '')::int, 1);
  exception when others then
    raise exception 'Periksa format tanggal, angsuran, tenor, angsuran ke, tahun dan MOB.';
  end;
  if v_tenor <= 0 or v_instno <= 0 or v_mob <= 0 then raise exception 'Tenor, angsuran ke dan MOB harus lebih dari 0.'; end if;
  if v_due is null then raise exception 'Isi tanggal jatuh tempo tertua.'; end if;
  if coalesce(v_inst, 0) <= 0 then raise exception 'Isi angsuran per bulan.'; end if;
  v_product := coalesce(nullif(p->>'product', ''), '2W');
  select * into pos from public.ucs_position(v_due, v_inst, cfg.process_date);

  if p_contract_no is null or p_contract_no = '' then
    v_no := 'SMF-' || v_product || '-' || lpad(nextval('public.ucs_contract_seq')::text, 5, '0');
    insert into public.ucs_accounts (
      contract_no, name, phone, job, address, area, zipcode, product, unit, plate, year,
      tenor, inst_no, installment, segment, mob, emergency, os_principal,
      oldest_due, due_day, dpd, days_to_due, bucket, stage, overdue_count, overdue_amount, penalty, max_dpd_12m)
    values (
      v_no, trim(p->>'name'), trim(p->>'phone'), coalesce(trim(p->>'job'), ''), trim(p->>'address'),
      coalesce(trim(p->>'area'), ''), coalesce(trim(p->>'zipcode'), ''), v_product, trim(p->>'unit'),
      upper(coalesce(trim(p->>'plate'), '')), v_year,
      v_tenor, v_instno, v_inst, coalesce(nullif(p->>'segment', ''), 'MEDIUM'), v_mob,
      coalesce(p->'emergency', '{}'::jsonb), (v_inst * greatest(0, v_tenor - v_instno) * 0.82)::bigint,
      v_due, pos.due_day, pos.dpd, pos.days_to_due, pos.bucket, pos.stage, pos.overdue_count, pos.overdue_amount, pos.penalty, pos.dpd);
    return v_no;
  end if;

  select * into old from public.ucs_accounts where contract_no = p_contract_no for update;
  if not found then raise exception 'Account % tidak ditemukan.', p_contract_no; end if;
  update public.ucs_accounts set
    name = trim(p->>'name'), phone = trim(p->>'phone'), job = coalesce(trim(p->>'job'), ''),
    address = trim(p->>'address'), area = coalesce(trim(p->>'area'), ''), zipcode = coalesce(trim(p->>'zipcode'), ''),
    product = v_product, unit = trim(p->>'unit'), plate = upper(coalesce(trim(p->>'plate'), '')),
    year = v_year, tenor = v_tenor, inst_no = v_instno, installment = v_inst,
    segment = coalesce(nullif(p->>'segment', ''), 'MEDIUM'), mob = v_mob,
    emergency = coalesce(p->'emergency', '{}'::jsonb),
    os_principal = (v_inst * greatest(0, v_tenor - v_instno) * 0.82)::bigint,
    oldest_due = v_due, due_day = pos.due_day, dpd = pos.dpd, days_to_due = pos.days_to_due,
    bucket = pos.bucket, stage = pos.stage, overdue_count = pos.overdue_count,
    overdue_amount = pos.overdue_amount, penalty = pos.penalty,
    max_dpd_12m = greatest(old.max_dpd_12m, pos.dpd),
    collector_id = case when old.stage = pos.stage then old.collector_id end,
    updated_at = public.ucs_now()
  where contract_no = p_contract_no;
  return p_contract_no;
end $$;

create or replace function public.ucs_save_staff(
  p_id text, p_name text, p_role text, p_scope text default '', p_password text default null, p_is_new boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare me public.ucs_staff; cur public.ucs_staff; v_id text := upper(trim(coalesce(p_id, ''))); v_pw text := nullif(p_password, '');
begin
  me := public.ucs_require(array['ADMIN']);
  if v_id !~ '^[A-Z0-9]{3,8}$' then raise exception 'ID petugas 3 sampai 8 huruf atau angka, tanpa spasi.'; end if;
  if trim(coalesce(p_name, '')) = '' then raise exception 'Isi nama petugas.'; end if;
  if p_role not in ('FC','TELE','ADMIN') then raise exception 'Peran tidak dikenal.'; end if;
  if v_pw is not null and length(v_pw) < 6 then raise exception 'Kata sandi minimal 6 karakter.'; end if;
  select * into cur from public.ucs_staff where id = v_id;
  if p_is_new then
    if found and cur.active then raise exception 'ID % sudah dipakai.', v_id; end if;
    if v_pw is null then raise exception 'Isi kata sandi awal untuk petugas baru.'; end if;
  else
    if not found then raise exception 'Petugas % tidak ditemukan.', v_id; end if;
    if v_id = me.id and p_role <> me.role then raise exception 'Anda tidak bisa mengubah peran akun sendiri.'; end if;
  end if;
  perform public.ucs_put_staff(v_id, p_name, p_role, p_scope, v_pw);
  if p_role <> 'FC' then
    update public.ucs_accounts set collector_id = null where collector_id = v_id;
  end if;
end $$;

create or replace function public.ucs_delete_staff(p_id text) returns void
language plpgsql security definer set search_path = public as $$
declare me public.ucs_staff;
begin
  me := public.ucs_require(array['ADMIN']);
  if p_id = me.id then raise exception 'Anda tidak bisa menonaktifkan akun sendiri.'; end if;
  update public.ucs_staff set active = false where id = p_id and active;
  if not found then raise exception 'Petugas % tidak ditemukan.', p_id; end if;
  update public.ucs_accounts set collector_id = null where collector_id = p_id;
end $$;

-- Batch harian: hitung ulang DPD, bucket dan tunggakan, tutup janji bayar yang lewat.
-- Bisa dijalankan admin dari aplikasi, atau terjadwal lewat pg_cron (lihat bawah).
create or replace function public.ucs_refresh_positions(p_date date default null) returns int
language plpgsql security definer set search_path = public as $$
declare d date := coalesce(p_date, public.ucs_today()); n int;
begin
  if auth.uid() is not null then perform public.ucs_require(array['ADMIN']); end if;
  update public.ucs_app_config set process_date = d where id = 1;
  update public.ucs_accounts a
     set (dpd, days_to_due, bucket, stage, overdue_count, overdue_amount, penalty, due_day) =
         (select p.dpd, p.days_to_due, p.bucket, p.stage, p.overdue_count, p.overdue_amount, p.penalty, p.due_day
            from public.ucs_position(a.oldest_due, a.installment, d) p)
   where a.bucket <> 'WO';
  get diagnostics n = row_count;
  -- Account yang kembali ke tahap reminder/telepon dilepas dari petugas lapangan, kecuali dieskalasi.
  update public.ucs_accounts
     set max_dpd_12m = greatest(max_dpd_12m, dpd),
         collector_id = case when stage in ('REMINDER','TELE') and not escalated then null else collector_id end
   where bucket <> 'WO';
  with b as (
    update public.ucs_ptp set status = 'BROKEN'
     where status = 'ACTIVE' and promise_date < d
    returning contract_no)
  update public.ucs_accounts set active_ptp = null where contract_no in (select contract_no from b);
  return n;
end $$;

-- ---------------------------------------------------------------------
-- Keamanan: RLS dan hak akses
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['ucs_app_config','ucs_staff','ucs_accounts','ucs_activities','ucs_ptp','ucs_ttr','ucs_rmp','ucs_skip_cases'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists ucs_staff_read on public.%I', t);
    execute format('create policy ucs_staff_read on public.%I for select to authenticated using ((select public.ucs_is_staff()))', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end $$;
revoke all on sequence public.ucs_contract_seq from anon, authenticated;

-- Fungsi internal: tidak bisa dipanggil dari aplikasi.
revoke execute on function public.ucs_require(text[]) from public, anon, authenticated;
revoke execute on function public.ucs_check_ptp(date, bigint) from public, anon, authenticated;
revoke execute on function public.ucs_least_loaded_fc() from public, anon, authenticated;
revoke execute on function public.ucs_create_auth_user(text, text) from public, anon, authenticated;
revoke execute on function public.ucs_put_staff(text, text, text, text, text) from public, anon, authenticated;
revoke execute on function public.ucs_is_staff() from public, anon;
grant  execute on function public.ucs_is_staff() to authenticated;

-- Login: boleh dipanggil sebelum masuk.
revoke execute on function public.ucs_staff_login(text) from public;
grant  execute on function public.ucs_staff_login(text) to anon, authenticated;

-- RPC aplikasi: hanya pengguna yang sudah masuk; peran diperiksa di dalam fungsi.
do $$
declare f text;
begin
  foreach f in array array[
    'ucs_whoami()',
    'ucs_record_visit(text,text,text,text,boolean,bigint,text,text,date,bigint,timestamp,double precision,double precision,int,int,int)',
    'ucs_deposit_ttr()',
    'ucs_record_call(text,text,text,text,text,date,bigint,text,text)',
    'ucs_set_ptp_status(text,text)',
    'ucs_resolve_skip(text,boolean,text,text,text)',
    'ucs_issue_sp(text)',
    'ucs_add_contact(text,text,text,text)',
    'ucs_submit_rmp(text,text,text)',
    'ucs_decide_rmp(text,text)',
    'ucs_issue_ttr(text,bigint,int)',
    'ucs_void_ttr(text)',
    'ucs_assign_collector(text,text)',
    'ucs_save_account(text,jsonb)',
    'ucs_save_staff(text,text,text,text,text,boolean)',
    'ucs_delete_staff(text)',
    'ucs_refresh_positions(date)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Realtime: perubahan tabel dikirim ke aplikasi yang sedang terbuka.
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['ucs_app_config','ucs_staff','ucs_accounts','ucs_activities','ucs_ptp','ucs_ttr','ucs_rmp','ucs_skip_cases'] loop
      if not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Opsional: batch harian otomatis pukul 00.30 WIB (17.30 UTC).
-- Aktifkan extension pg_cron di Database → Extensions, lalu jalankan:
--
--   select cron.schedule('ucs-batch-harian', '30 17 * * *', $$select public.ucs_refresh_positions()$$);
-- ---------------------------------------------------------------------


-- =====================================================================
-- DATA CONTOH
-- =====================================================================
-- Data contoh Universe Collection Suite (fiktif). Aman dijalankan ulang.
-- Kata sandi semua akun contoh: demo123. Ganti setelah uji coba.

update public.ucs_app_config set branch = 'Cabang Bekasi', process_date = '2026-11-12' where id = 1;

-- Petugas dan akun login (Supabase Auth)
select public.ucs_put_staff('FC01', 'Rizky Pratama', 'FC', 'Bucket 1 (DPD 8–30) · Bekasi Timur', 'demo123');
select public.ucs_put_staff('FC02', 'Dimas Anggoro', 'FC', 'Bucket 2 (DPD 31–60) · Tambun Selatan', 'demo123');
select public.ucs_put_staff('FC03', 'Yoga Firmansyah', 'FC', 'Bucket 3+ (DPD 61+) · Bekasi', 'demo123');
select public.ucs_put_staff('TC01', 'Sari Wulandari', 'TELE', 'Desk call · tim A', 'demo123');
select public.ucs_put_staff('TC02', 'Andini Maharani', 'TELE', 'Desk call · tim B', 'demo123');
select public.ucs_put_staff('ADM01', 'Putri Larasati', 'ADMIN', 'Collection admin · TTR dan data', 'demo123');

-- Account
insert into public.ucs_accounts (contract_no, name, phone, phone_status, job, address, area, zipcode, product, unit, year, plate, tenor, inst_no, installment, due_day, oldest_due, dpd, days_to_due, bucket, stage, overdue_count, overdue_amount, penalty, os_principal, mob, segment, max_dpd_12m, sp_level, collector_id, rmp_flag, unit_status, emergency, extra_contacts, last_contact, active_ptp, field_paid, escalated) values ('SMF-2W-20410', 'Ahmad Fauzi', '0812-5550-1000', 'VALID', 'Buruh harian', 'Jl. Mawar No. 12 RT 09/RW 02, Margahayu, Bekasi Timur', 'Margahayu', '17113', '2W', 'Yamaha NMAX 155', 2021, 'B 2150 KBD', 30, 8, 1420000, 13, '2026-11-13', 0, 1, 'B0', 'REMINDER', 0, 0, 0, 25616800, 8, 'HIGH', 12, 0, null, false, 'WITH_DEBTOR', '{"name": "Nur Fauzi", "relation": "Istri", "phone": "0812-5550-2480"}'::jsonb, '[]'::jsonb, null, null, 0, false) on conflict (contract_no) do nothing;
insert into public.ucs_accounts (contract_no, name, phone, phone_status, job, address, area, zipcode, product, unit, year, plate, tenor, inst_no, installment, due_day, oldest_due, dpd, days_to_due, bucket, stage, overdue_count, overdue_amount, penalty, os_principal, mob, segment, max_dpd_12m, sp_level, collector_id, rmp_flag, unit_status, emergency, extra_contacts, last_contact, active_ptp, field_paid, escalated) values ('SMF-2W-20523', 'Siti Rahmawati', '0812-5550-1037', 'VALID', 'Wiraswasta', 'Jl. Mawar No. 75 RT 02/RW 04, Duren Jaya, Bekasi Timur', 'Duren Jaya', '17111', '2W', 'Honda Vario 125', 2024, 'B 2213 TBL', 36, 9, 980000, 14, '2026-11-14', 0, 2, 'B0', 'REMINDER', 0, 0, 0, 21697200, 9, 'MEDIUM', 0, 0, null, false, 'WITH_DEBTOR', '{"name": "Slamet Rahmawati", "relation": "Suami", "phone": "0812-5550-2517"}'::jsonb, '[]'::jsonb, null, null, 0, false) on conflict (contract_no) do nothing;
insert into public.ucs_accounts (contract_no, name, phone, phone_status, job, address, area, zipcode, product, unit, year, plate, tenor, inst_no, installment, due_day, oldest_due, dpd, days_to_due, bucket, stage, overdue_count, overdue_amount, penalty, os_principal, mob, segment, max_dpd_12m, sp_level, collector_id, rmp_flag, unit_status, emergency, extra_contacts, last_contact, active_ptp, field_paid, escalated) values ('SMF-2W-20636', 'Budi Santoso', '0812-5550-1074', 'VALID', 'Karyawan toko', 'Jl. Kenanga No. 76 RT 05/RW 09, Aren Jaya, Bekasi Timur', 'Aren Jaya', '17111', '2W', 'Yamaha NMAX 155', 2025, 'B 4161 FKS', 24, 23, 1420000, 15, '2026-11-15', 0, 3, 'B0', 'REMINDER', 0, 0, 0, 1164400, 23, 'HIGH', 0, 0, null, false, 'WITH_DEBTOR', '{"name": "Slamet Santoso", "relation": "Istri", "phone": "0812-5550-2554"}'::jsonb, '[]'::jsonb, '{"at": "2026-11-11T15:05:00", "type": "CALL", "result": "PTP"}'::jsonb, '{"date": "2026-11-15", "amount": 1420000}'::jsonb, 0, false) on conflict (contract_no) do nothing;
insert into public.ucs_accounts (contract_no, name, phone, phone_status, job, address, area, zipcode, product, unit, year, plate, tenor, inst_no, installment, due_day, oldest_due, dpd, days_to_due, bucket, stage, overdue_count, overdue_amount, penalty, os_principal, mob, segment, max_dpd_12m, sp_level, collector_id, rmp_flag, unit_status, emergency, extra_contacts, last_contact, active_ptp, field_paid, escalated) values ('SMF-4W-20749', 'Dewi Lestari', '0812-5550-1111', 'VALID', 'Wiraswasta', 'Jl. Kemuning No. 57 RT 06/RW 08, Bekasi Jaya, Bekasi Timur', 'Bekasi Jaya', '17112', '4W', 'Toyota Avanza 1.3 G', 2023, 'B 8624 SPL', 48, 11, 4350000, 16, '2026-11-16', 0, 4, 'B0', 'REMINDER', 0, 0, 0, 131978999, 11, 'HIGH', 0, 0, null, false, 'WITH_DEBTOR', '{"name": "Yanti Lestari", "relation": "Suami", "phone": "0812-5550-2591"}'::jsonb, '[]'::jsonb, null, null, 0, false) on conflict (contract_no) do nothing;
insert into public.ucs_accounts (contract_no, name, phone, phone_status, job, address, area, zipcode, product, unit, year, plate, tenor, inst_no, installment, due_day, oldest_due, dpd, days_to_due, bucket, stage, overdue_count, overdue_amount, penalty, os_principal, mob, segment, max_dpd_12m, sp_level, collector_id, rmp_flag, unit_status, emergency, extra_contacts, last_contact, active_ptp, field_paid, escalated) values ('SMF-2W-20862', 'Eko Prasetyo', '0812-5550-1148', 'VALID', 'Karyawan toko', 'Gg. Haji Saleh No. 46 RT 08/RW 05, Jatimulya, Tambun Selatan', 'Jatimulya', '17510', '2W', 'Honda Beat 110', 2023, 'B 2399 FUH', 30, 28, 790000, 18, '2026-11-18', 0, 6, 'B0', 'REMINDER', 0, 0, 0, 1295600, 28, 'LOW', 0, 0, null, false, 'WITH_DEBTOR', '{"name": "Agus Prasetyo", "relation": "Kakak", "phone": "0812-5550-2628"}'::jsonb, '[]'::jsonb, null, null, 0, false) on conflict (contract_no) do nothing;
insert into public.ucs_accounts (contract_no, name, phone, phone_status, job, address, area, zipcode, product, unit, year, plate, tenor, inst_no, installment, due_day, oldest_due, dpd, days_to_due, bucket, stage, overdue_count, overdue_amount, penalty, os_principal, mob, segment, max_dpd_12m, sp_level, collector_id, rmp_flag, unit_status, emergency, extra_contacts, last_contact, active_ptp, field_paid, escalated) values ('SMF-2W-20975', 'Fitri Handayani', '0812-5550-1185', 'VALID', 'Karyawan pabrik', 'Jl. Kenanga No. 74 RT 06/RW 06, Mangunjaya, Tambun Selatan', 'Mangunjaya', '17510', '2W', 'Honda Vario 125', 2024, 'B 6937 ZVD', 30, 22, 980000, 11, '2026-11-11', 1, 0, 'B1', 'TELE', 1, 980000, 5000, 6428800, 22, 'LOW', 1, 0, null, false, 'WITH_DEBTOR', '{"name": "Citra Handayani", "relation": "Istri", "phone": "0812-5550-2665"}'::jsonb, '[]'::jsonb, '{"at": "2026-11-11T09:40:00", "type": "CALL", "result": "NOANS"}'::jsonb, null, 0, false) on conflict (contract_no) do nothing;
insert into public.ucs_accounts (contract_no, name, phone, phone_status, job, address, area, zipcode, product, unit, year, plate, tenor, inst_no, installment, due_day, oldest_due, dpd, days_to_due, bucket, stage, overdue_count, overdue_amount, penalty, os_principal, mob, segment, max_dpd_12m, sp_level, collector_id, rmp_flag, unit_status, emergency, extra_contacts, last_contact, active_ptp, field_paid, escalated) values ('SMF-2W-21088', 'Gunawan Wibowo', '0812-5550-1222', 'VALID', 'Buruh harian', 'Jl. Kenanga No. 10 RT 05/RW 11, Setiamekar, Tambun Selatan', 'Setiamekar', '17510', '2W', 'Yamaha NMAX 155', 2023, 'B 8501 PTS', 36, 22, 1420000, 10, '2026-11-10', 2, 0, 'B1', 'TELE', 1, 1420000, 14000, 16301599, 22, 'MEDIUM', 2, 0, null, false, 'WITH_DEBTOR', '{"name": "Oktaviani Wibowo", "relation": "Kakak", "phone": "0812-5550-2702"}'::jsonb, '[]'::jsonb, '{"at": "2026-11-11T10:05:00", "type": "CALL", "result": "PTP"}'::jsonb, '{"date": "2026-11-12", "amount": 1420000}'::jsonb, 0, false) on conflict (contract_no) do nothing;
insert into public.ucs_accounts (contract_no, name, phone, phone_status, job, address, area, zipcode, product, unit, year, plate, tenor, inst_no, installment, due_day, oldest_due, dpd, days_to_due, bucket, stage, overdue_count, overdue_amount, penalty, os_principal, mob, segment, max_dpd_12m, sp_level, collector_id, rmp_flag, unit_status, emergency, extra_contacts, last_contact, active_ptp, field_paid, escalated) values ('SMF-2W-21201', 'Hendra Saputra', '0812-5550-1259', 'VALID', 'Karyawan pabrik', 'Jl. Rajawali No. 39 RT 03/RW 12, Mustika Jaya, Mustika Jaya', 'Mustika Jaya', '17158', '2W', 'Honda Vario 125', 2020, 'B 7719 TZD', 30, 5, 980000, 9, '2026-11-09', 3, 0, 'B1', 'TELE', 1, 980000, 15000, 20090000, 5, 'HIGH', 3, 0, null, false, 'WITH_DEBTOR', '{"name": "Oktaviani Saputra", "relation": "Adik", "phone": "0812-5550-2739"}'::jsonb, '[]'::jsonb, '{"at": "2026-11-11T11:20:00", "type": "CALL", "result": "BUSY"}'::jsonb, null, 0, false) on conflict (contract_no) do nothing;
insert into public.ucs_accounts (contract_no, name, phone, phone_status, job, address, area, zipcode, product, unit, year, plate, tenor, inst_no, installment, due_day, oldest_due, dpd, days_to_due, bucket, stage, overdue_count, overdue_amount, penalty, os_principal, mob, segment, max_dpd_12m, sp_level, collector_id, rmp_flag, unit_status, emergency, extra_contacts, last_contact, active_ptp, field_paid, escalated) values ('SMF-4W-21314', 'Indah Permatasari', '0812-5550-1296', 'VALID', 'Wiraswasta', 'Jl. Kemuning No. 38 RT 07/RW 06, Margahayu, Bekasi Timur', 'Margahayu', '17113', '4W', 'Honda Brio Satya', 2024, 'B 7433 LGD', 48, 12, 3460000, 8, '2026-11-08', 4, 0, 'B1', 'TELE', 1, 3460000, 69000, 102139200, 12, 'LOW', 4, 0, null, false, 'WITH_DEBTOR', '{"name": "Fitri Permatasari", "relation": "Suami", "phone": "0812-5550-2776"}'::jsonb, '[]'::jsonb, null, null, 0, false) on conflict (contract_no) do nothing;
insert into public.ucs_accounts (contract_no, name, phone, phone_status, job, address, area, zipcode, product, unit, year, plate, tenor, inst_no, installment, due_day, oldest_due, dpd, days_to_due, bucket, stage, overdue_count, overdue_amount, penalty, os_principal, mob, segment, max_dpd_12m, sp_level, collector_id, rmp_flag, unit_status, emergency, extra_contacts, last_contact, active_ptp, field_paid, escalated) values ('SMF-2W-21427', 'Joko Susilo', '0812-5550-1333', 'VALID', 'Wiraswasta', 'Jl. Garuda No. 26 RT 05/RW 05, Duren Jaya, Bekasi Timur', 'Duren Jaya', '17111', '2W', 'Honda Vario 125', 2019, 'B 3586 USR', 24, 12, 980000, 6, '2026-11-06', 6, 0, 'B1', 'TELE', 1, 980000, 29000, 9643200, 12, 'MEDIUM', 6, 0, null, false, 'WITH_DEBTOR', '{"name": "Yanti Susilo", "relation": "Orang tua", "phone": "0812-5550-2813"}'::jsonb, '[]'::jsonb, '{"at": "2026-11-10T14:10:00", "type": "CALL", "result": "PTP"}'::jsonb, '{"date": "2026-11-14", "amount": 980000}'::jsonb, 0, false) on conflict (contract_no) do nothing;
insert into public.ucs_accounts (contract_no, name, phone, phone_status, job, address, area, zipcode, product, unit, year, plate, tenor, inst_no, installment, due_day, oldest_due, dpd, days_to_due, bucket, stage, overdue_count, overdue_amount, penalty, os_principal, mob, segment, max_dpd_12m, sp_level, collector_id, rmp_flag, unit_status, emergency, extra_contacts, last_contact, active_ptp, field_paid, escalated) values ('SMF-2W-21540', 'Kartika Sari', '0812-5550-1370', 'INVALID', 'Buruh harian', 'Jl. Kemuning No. 53 RT 07/RW 07, Aren Jaya, Bekasi Timur', 'Aren Jaya', '17111', '2W', 'Yamaha Mio M3', 2022, 'B 2896 ZTB', 30, 4, 720000, 5, '2026-11-05', 7, 0, 'B1', 'TELE', 1, 720000, 25000, 15350400, 4, 'HIGH', 7, 0, null, false, 'WITH_DEBTOR', '{"name": "Budi Sari", "relation": "Suami", "phone": "0812-5550-2850"}'::jsonb, '[]'::jsonb, '{"at": "2026-11-11T13:30:00", "type": "CALL", "result": "INVALID"}'::jsonb, null, 0, false) on conflict (contract_no) do nothing;
insert into public.ucs_accounts (contract_no, name, phone, phone_status, job, address, area, zipcode, product, unit, year, plate, tenor, inst_no, installment, due_day, oldest_due, dpd, days_to_due, bucket, stage, overdue_count, overdue_amount, penalty, os_principal, mob, segment, max_dpd_12m, sp_level, collector_id, rmp_flag, unit_status, emergency, extra_contacts, last_contact, active_ptp, field_paid, escalated) values ('SMF-2W-21653', 'Lukman Hakim', '0812-5550-1407', 'VALID', 'Pengemudi ojek daring', 'Jl. Garuda No. 9 RT 02/RW 01, Bekasi Jaya, Bekasi Timur', 'Bekasi Jaya', '17112', '2W', 'Honda Scoopy', 2023, 'B 3678 FSA', 24, 12, 890000, 3, '2026-11-03', 9, 0, 'B1', 'FIELD', 1, 890000, 40000, 8757600, 12, 'MEDIUM', 9, 1, 'FC01', false, 'WITH_DEBTOR', '{"name": "Dedi Hakim", "relation": "Suami", "phone": "0812-5550-2887"}'::jsonb, '[]'::jsonb, '{"at": "2026-11-10T10:15:00", "type": "VISIT", "result": "PTP"}'::jsonb, '{"date": "2026-11-12", "amount": 890000}'::jsonb, 0, false) on conflict (contract_no) do nothing;
insert into public.ucs_accounts (contract_no, name, phone, phone_status, job, address, area, zipcode, product, unit, year, plate, tenor, inst_no, installment, due_day, oldest_due, dpd, days_to_due, bucket, stage, overdue_count, overdue_amount, penalty, os_principal, mob, segment, max_dpd_12m, sp_level, collector_id, rmp_flag, unit_status, emergency, extra_contacts, last_contact, active_ptp, field_paid, escalated) values ('SMF-2W-21766', 'Maya Anggraini', '0812-5550-1444', 'VALID', 'Buruh harian', 'Jl. Merpati No. 47 RT 06/RW 08, Jatimulya, Tambun Selatan', 'Jatimulya', '17510', '2W', 'Yamaha Mio M3', 2019, 'B 3089 ZVZ', 24, 23, 720000, 1, '2026-11-01', 11, 0, 'B1', 'FIELD', 1, 720000, 40000, 590400, 23, 'HIGH', 12, 1, 'FC01', false, 'WITH_DEBTOR', '{"name": "Joko Anggraini", "relation": "Istri", "phone": "0812-5550-2924"}'::jsonb, '[]'::jsonb, '{"at": "2026-11-11T11:00:00", "type": "VISIT", "result": "NOTMEET"}'::jsonb, null, 0, false) on conflict (contract_no) do nothing;
insert into public.ucs_accounts (contract_no, name, phone, phone_status, job, address, area, zipcode, product, unit, year, plate, tenor, inst_no, installment, due_day, oldest_due, dpd, days_to_due, bucket, stage, overdue_count, overdue_amount, penalty, os_principal, mob, segment, max_dpd_12m, sp_level, collector_id, rmp_flag, unit_status, emergency, extra_contacts, last_contact, active_ptp, field_paid, escalated) values ('SMF-4W-21879', 'Nur Hidayat', '0812-5550-1481', 'VALID', 'Buruh harian', 'Jl. Pahlawan No. 36 RT 08/RW 12, Mangunjaya, Tambun Selatan', 'Mangunjaya', '17510', '4W', 'Daihatsu Gran Max PU', 2020, 'B 9659 AKS', 48, 9, 3180000, 30, '2026-10-30', 13, 0, 'B1', 'FIELD', 1, 3180000, 207000, 101696400, 9, 'LOW', 13, 1, 'FC01', false, 'WITH_DEBTOR', '{"name": "Eko Hidayat", "relation": "Orang tua", "phone": "0812-5550-2961"}'::jsonb, '[]'::jsonb, null, null, 0, false) on conflict (contract_no) do nothing;
insert into public.ucs_accounts (contract_no, name, phone, phone_status, job, address, area, zipcode, product, unit, year, plate, tenor, inst_no, installment, due_day, oldest_due, dpd, days_to_due, bucket, stage, overdue_count, overdue_amount, penalty, os_principal, mob, segment, max_dpd_12m, sp_level, collector_id, rmp_flag, unit_status, emergency, extra_contacts, last_contact, active_ptp, field_paid, escalated) values ('SMF-2W-21992', 'Oktaviani Putri', '0812-5550-1518', 'VALID', 'Karyawan pabrik', 'Jl. Merpati No. 69 RT 06/RW 03, Setiamekar, Tambun Selatan', 'Setiamekar', '17510', '2W', 'Honda Beat 110', 2021, 'B 4850 RLK', 36, 14, 790000, 28, '2026-10-28', 15, 0, 'B1', 'FIELD', 1, 790000, 59000, 14251600, 14, 'HIGH', 15, 1, 'FC01', false, 'WITH_DEBTOR', '{"name": "Citra Putri", "relation": "Adik", "phone": "0812-5550-2998"}'::jsonb, '[]'::jsonb, '{"at": "2026-11-09T15:20:00", "type": "VISIT", "result": "MEET_NOPAY"}'::jsonb, null, 0, false) on conflict (contract_no) do nothing;
insert into public.ucs_accounts (contract_no, name, phone, phone_status, job, address, area, zipcode, product, unit, year, plate, tenor, inst_no, installment, due_day, oldest_due, dpd, days_to_due, bucket, stage, overdue_count, overdue_amount, penalty, os_principal, mob, segment, max_dpd_12m, sp_level, collector_id, rmp_flag, unit_status, emergency, extra_contacts, last_contact, active_ptp, field_paid, escalated) values ('SMF-2W-22105', 'Purnomo Adi', '0812-5550-1555', 'VALID', 'Wiraswasta', 'Jl. Pahlawan No. 6 RT 01/RW 05, Mustika Jaya, Mustika Jaya', 'Mustika Jaya', '17158', '2W', 'Honda Vario 125', 2022, 'B 5446 KSV', 36, 12, 980000, 25, '2026-10-25', 18, 0, 'B1', 'FIELD', 1, 980000, 88000, 19286400, 12, 'MEDIUM', 34, 2, 'FC01', false, 'WITH_DEBTOR', '{"name": "Lukman Adi", "relation": "Kakak", "phone": "0812-5550-3035"}'::jsonb, '[]'::jsonb, null, null, 0, false) on conflict (contract_no) do nothing;
insert into public.ucs_accounts (contract_no, name, phone, phone_status, job, address, area, zipcode, product, unit, year, plate, tenor, inst_no, installment, due_day, oldest_due, dpd, days_to_due, bucket, stage, overdue_count, overdue_amount, penalty, os_principal, mob, segment, max_dpd_12m, sp_level, collector_id, rmp_flag, unit_status, emergency, extra_contacts, last_contact, active_ptp, field_paid, escalated) values ('SMF-2W-22218', 'Rina Marlina', '0812-5550-1592', 'VALID', 'Pedagang', 'Gg. Haji Saleh No. 28 RT 06/RW 04, Margahayu, Bekasi Timur', 'Margahayu', '17113', '2W', 'Honda Beat 110', 2022, 'B 1231 ZSD', 24, 11, 790000, 22, '2026-10-22', 21, 0, 'B1', 'FIELD', 1, 790000, 83000, 8421400, 11, 'HIGH', 34, 2, 'FC01', false, 'WITH_DEBTOR', '{"name": "Dewi Marlina", "relation": "Adik", "phone": "0812-5550-3072"}'::jsonb, '[]'::jsonb, '{"at": "2026-11-07T09:45:00", "type": "VISIT", "result": "PTP"}'::jsonb, null, 0, false) on conflict (contract_no) do nothing;
insert into public.ucs_accounts (contract_no, name, phone, phone_status, job, address, area, zipcode, product, unit, year, plate, tenor, inst_no, installment, due_day, oldest_due, dpd, days_to_due, bucket, stage, overdue_count, overdue_amount, penalty, os_principal, mob, segment, max_dpd_12m, sp_level, collector_id, rmp_flag, unit_status, emergency, extra_contacts, last_contact, active_ptp, field_paid, escalated) values ('SMF-2W-22331', 'Slamet Riyadi', '0812-5550-1629', 'VALID', 'Wiraswasta', 'Jl. Pahlawan No. 14 RT 07/RW 08, Duren Jaya, Bekasi Timur', 'Duren Jaya', '17111', '2W', 'Honda Vario 125', 2022, 'B 2591 HHG', 24, 22, 980000, 19, '2026-10-19', 24, 0, 'B1', 'FIELD', 1, 980000, 118000, 1607200, 22, 'MEDIUM', 24, 2, 'FC01', false, 'WITH_DEBTOR', '{"name": "Eko Riyadi", "relation": "Orang tua", "phone": "0812-5550-3109"}'::jsonb, '[]'::jsonb, null, null, 0, false) on conflict (contract_no) do nothing;
insert into public.ucs_accounts (contract_no, name, phone, phone_status, job, address, area, zipcode, product, unit, year, plate, tenor, inst_no, installment, due_day, oldest_due, dpd, days_to_due, bucket, stage, overdue_count, overdue_amount, penalty, os_principal, mob, segment, max_dpd_12m, sp_level, collector_id, rmp_flag, unit_status, emergency, extra_contacts, last_contact, active_ptp, field_paid, escalated) values ('SMF-4W-22444', 'Tri Wahyuni', '0812-5550-1666', 'VALID', 'Karyawan toko', 'Jl. Garuda No. 63 RT 06/RW 03, Aren Jaya, Bekasi Timur', 'Aren Jaya', '17111', '4W', 'Suzuki Carry PU', 2023, 'B 3346 AAF', 48, 8, 3050000, 16, '2026-10-16', 27, 0, 'B1', 'FIELD', 1, 3050000, 412000, 100040000, 8, 'HIGH', 34, 3, 'FC01', false, 'WITH_DEBTOR', '{"name": "Zainal Wahyuni", "relation": "Suami", "phone": "0812-5550-3146"}'::jsonb, '[]'::jsonb, null, null, 0, false) on conflict (contract_no) do nothing;
insert into public.ucs_accounts (contract_no, name, phone, phone_status, job, address, area, zipcode, product, unit, year, plate, tenor, inst_no, installment, due_day, oldest_due, dpd, days_to_due, bucket, stage, overdue_count, overdue_amount, penalty, os_principal, mob, segment, max_dpd_12m, sp_level, collector_id, rmp_flag, unit_status, emergency, extra_contacts, last_contact, active_ptp, field_paid, escalated) values ('SMF-2W-22557', 'Usman Effendi', '0812-5550-1703', 'VALID', 'Karyawan pabrik', 'Jl. Merpati No. 30 RT 05/RW 09, Bekasi Jaya, Bekasi Timur', 'Bekasi Jaya', '17112', '2W', 'Honda Scoopy', 2020, 'B 6541 NUG', 24, 12, 890000, 14, '2026-10-14', 29, 0, 'B1', 'FIELD', 1, 890000, 129000, 8757600, 12, 'LOW', 29, 3, 'FC01', false, 'WITH_DEBTOR', '{"name": "Siti Effendi", "relation": "Kakak", "phone": "0812-5550-3183"}'::jsonb, '[]'::jsonb, null, null, 0, false) on conflict (contract_no) do nothing;
insert into public.ucs_accounts (contract_no, name, phone, phone_status, job, address, area, zipcode, product, unit, year, plate, tenor, inst_no, installment, due_day, oldest_due, dpd, days_to_due, bucket, stage, overdue_count, overdue_amount, penalty, os_principal, mob, segment, max_dpd_12m, sp_level, collector_id, rmp_flag, unit_status, emergency, extra_contacts, last_contact, active_ptp, field_paid, escalated) values ('SMF-2W-22670', 'Vina Oktaviana', '0812-5550-1740', 'VALID', 'Pedagang', 'Jl. Kemuning No. 22 RT 09/RW 09, Jatimulya, Tambun Selatan', 'Jatimulya', '17510', '2W', 'Honda Scoopy', 2019, 'B 8411 HAG', 36, 23, 890000, 10, '2026-10-10', 33, 0, 'B2', 'REMEDIAL', 2, 1780000, 294000, 9487400, 23, 'HIGH', 33, 3, 'FC02', false, 'WITH_DEBTOR', '{"name": "Eko Oktaviana", "relation": "Adik", "phone": "0812-5550-3220"}'::jsonb, '[]'::jsonb, '{"at": "2026-11-10T13:10:00", "type": "VISIT", "result": "ADDR_INVALID"}'::jsonb, null, 0, false) on conflict (contract_no) do nothing;
insert into public.ucs_accounts (contract_no, name, phone, phone_status, job, address, area, zipcode, product, unit, year, plate, tenor, inst_no, installment, due_day, oldest_due, dpd, days_to_due, bucket, stage, overdue_count, overdue_amount, penalty, os_principal, mob, segment, max_dpd_12m, sp_level, collector_id, rmp_flag, unit_status, emergency, extra_contacts, last_contact, active_ptp, field_paid, escalated) values ('SMF-2W-22783', 'Wahyu Nugroho', '0812-5550-1777', 'VALID', 'Karyawan pabrik', 'Jl. Pahlawan No. 69 RT 09/RW 09, Mangunjaya, Tambun Selatan', 'Mangunjaya', '17510', '2W', 'Yamaha Mio M3', 2022, 'B 2938 BLK', 36, 9, 720000, 5, '2026-10-05', 38, 0, 'B2', 'REMEDIAL', 2, 1440000, 274000, 15940799, 9, 'MEDIUM', 38, 3, 'FC02', false, 'WITH_DEBTOR', '{"name": "Siti Nugroho", "relation": "Istri", "phone": "0812-5550-3257"}'::jsonb, '[]'::jsonb, null, null, 0, false) on conflict (contract_no) do nothing;
insert into public.ucs_accounts (contract_no, name, phone, phone_status, job, address, area, zipcode, product, unit, year, plate, tenor, inst_no, installment, due_day, oldest_due, dpd, days_to_due, bucket, stage, overdue_count, overdue_amount, penalty, os_principal, mob, segment, max_dpd_12m, sp_level, collector_id, rmp_flag, unit_status, emergency, extra_contacts, last_contact, active_ptp, field_paid, escalated) values ('SMF-2W-22896', 'Yanti Susanti', '0812-5550-1814', 'VALID', 'Karyawan pabrik', 'Jl. Kenanga No. 59 RT 06/RW 10, Setiamekar, Tambun Selatan', 'Setiamekar', '17510', '2W', 'Yamaha Mio M3', 2023, 'B 9591 KNV', 36, 27, 720000, 29, '2026-09-29', 44, 0, 'B2', 'REMEDIAL', 2, 1440000, 317000, 5313600, 27, 'HIGH', 44, 3, 'FC02', false, 'WITH_DEBTOR', '{"name": "Slamet Susanti", "relation": "Adik", "phone": "0812-5550-3294"}'::jsonb, '[]'::jsonb, '{"at": "2026-11-11T10:30:00", "type": "VISIT", "result": "RMP_REQ"}'::jsonb, null, 0, false) on conflict (contract_no) do nothing;
insert into public.ucs_accounts (contract_no, name, phone, phone_status, job, address, area, zipcode, product, unit, year, plate, tenor, inst_no, installment, due_day, oldest_due, dpd, days_to_due, bucket, stage, overdue_count, overdue_amount, penalty, os_principal, mob, segment, max_dpd_12m, sp_level, collector_id, rmp_flag, unit_status, emergency, extra_contacts, last_contact, active_ptp, field_paid, escalated) values ('SMF-4W-23009', 'Zainal Abidin', '0812-5550-1851', 'VALID', 'Karyawan toko', 'Jl. Rajawali No. 60 RT 03/RW 07, Mustika Jaya, Mustika Jaya', 'Mustika Jaya', '17158', '4W', 'Daihatsu Gran Max PU', 2019, 'B 7628 VRD', 48, 14, 3180000, 24, '2026-09-24', 49, 0, 'B2', 'REMEDIAL', 2, 6360000, 1558000, 88658400, 14, 'HIGH', 49, 3, 'FC02', false, 'WITH_DEBTOR', '{"name": "Hendra Abidin", "relation": "Adik", "phone": "0812-5550-3331"}'::jsonb, '[]'::jsonb, null, null, 0, false) on conflict (contract_no) do nothing;
insert into public.ucs_accounts (contract_no, name, phone, phone_status, job, address, area, zipcode, product, unit, year, plate, tenor, inst_no, installment, due_day, oldest_due, dpd, days_to_due, bucket, stage, overdue_count, overdue_amount, penalty, os_principal, mob, segment, max_dpd_12m, sp_level, collector_id, rmp_flag, unit_status, emergency, extra_contacts, last_contact, active_ptp, field_paid, escalated) values ('SMF-2W-23122', 'Agus Setiawan', '0812-5550-1888', 'VALID', 'Pengemudi ojek daring', 'Jl. Kenanga No. 22 RT 06/RW 03, Margahayu, Bekasi Timur', 'Margahayu', '17113', '2W', 'Honda Beat 110', 2021, 'B 3448 VLF', 36, 12, 790000, 20, '2026-09-20', 53, 0, 'B2', 'REMEDIAL', 2, 1580000, 419000, 15547200, 12, 'MEDIUM', 53, 3, 'FC02', false, 'WITH_DEBTOR', '{"name": "Erna Setiawan", "relation": "Adik", "phone": "0812-5550-3368"}'::jsonb, '[]'::jsonb, null, null, 0, false) on conflict (contract_no) do nothing;
insert into public.ucs_accounts (contract_no, name, phone, phone_status, job, address, area, zipcode, product, unit, year, plate, tenor, inst_no, installment, due_day, oldest_due, dpd, days_to_due, bucket, stage, overdue_count, overdue_amount, penalty, os_principal, mob, segment, max_dpd_12m, sp_level, collector_id, rmp_flag, unit_status, emergency, extra_contacts, last_contact, active_ptp, field_paid, escalated) values ('SMF-2W-23235', 'Bambang Hermanto', '0812-5550-1925', 'VALID', 'Buruh harian', 'Jl. Nusantara No. 68 RT 07/RW 06, Duren Jaya, Bekasi Timur', 'Duren Jaya', '17111', '2W', 'Honda Vario 125', 2022, 'B 4407 SRD', 24, 11, 980000, 15, '2026-09-15', 58, 0, 'B2', 'REMEDIAL', 2, 1960000, 568000, 10446800, 11, 'HIGH', 58, 3, 'FC02', false, 'WITH_DEBTOR', '{"name": "Lukman Hermanto", "relation": "Istri", "phone": "0812-5550-3405"}'::jsonb, '[]'::jsonb, null, null, 0, false) on conflict (contract_no) do nothing;
insert into public.ucs_accounts (contract_no, name, phone, phone_status, job, address, area, zipcode, product, unit, year, plate, tenor, inst_no, installment, due_day, oldest_due, dpd, days_to_due, bucket, stage, overdue_count, overdue_amount, penalty, os_principal, mob, segment, max_dpd_12m, sp_level, collector_id, rmp_flag, unit_status, emergency, extra_contacts, last_contact, active_ptp, field_paid, escalated) values ('SMF-2W-23348', 'Citra Kirana', '0812-5550-1962', 'VALID', 'Buruh harian', 'Jl. Mawar No. 52 RT 06/RW 09, Aren Jaya, Bekasi Timur', 'Aren Jaya', '17111', '2W', 'Yamaha NMAX 155', 2023, 'B 6040 DFL', 30, 27, 1420000, 9, '2026-09-09', 64, 0, 'B3', 'END_BUCKET', 3, 4260000, 1363000, 3493200, 27, 'HIGH', 64, 3, 'FC03', false, 'WITH_DEBTOR', '{"name": "Budi Kirana", "relation": "Kakak", "phone": "0812-5550-3442"}'::jsonb, '[]'::jsonb, '{"at": "2026-11-08T14:00:00", "type": "VISIT", "result": "UNCOOP"}'::jsonb, null, 0, false) on conflict (contract_no) do nothing;
insert into public.ucs_accounts (contract_no, name, phone, phone_status, job, address, area, zipcode, product, unit, year, plate, tenor, inst_no, installment, due_day, oldest_due, dpd, days_to_due, bucket, stage, overdue_count, overdue_amount, penalty, os_principal, mob, segment, max_dpd_12m, sp_level, collector_id, rmp_flag, unit_status, emergency, extra_contacts, last_contact, active_ptp, field_paid, escalated) values ('SMF-2W-23461', 'Dedi Kurniawan', '0812-5550-1999', 'VALID', 'Pengemudi ojek daring', 'Jl. Cempaka No. 57 RT 05/RW 07, Bekasi Jaya, Bekasi Timur', 'Bekasi Jaya', '17112', '2W', 'Yamaha NMAX 155', 2020, 'B 9634 ZRD', 24, 4, 1420000, 1, '2026-09-01', 72, 0, 'B3', 'END_BUCKET', 3, 4260000, 1534000, 23288000, 4, 'HIGH', 72, 3, 'FC03', false, 'WITH_DEBTOR', '{"name": "Siti Kurniawan", "relation": "Suami", "phone": "0812-5550-3479"}'::jsonb, '[]'::jsonb, null, null, 0, false) on conflict (contract_no) do nothing;
insert into public.ucs_accounts (contract_no, name, phone, phone_status, job, address, area, zipcode, product, unit, year, plate, tenor, inst_no, installment, due_day, oldest_due, dpd, days_to_due, bucket, stage, overdue_count, overdue_amount, penalty, os_principal, mob, segment, max_dpd_12m, sp_level, collector_id, rmp_flag, unit_status, emergency, extra_contacts, last_contact, active_ptp, field_paid, escalated) values ('SMF-4W-23574', 'Erna Wati', '0812-5550-2036', 'VALID', 'Pengemudi ojek daring', 'Jl. Mawar No. 84 RT 02/RW 05, Jatimulya, Tambun Selatan', 'Jatimulya', '17510', '4W', 'Suzuki Carry PU', 2019, 'B 4843 DNF', 48, 9, 3050000, 19, '2026-08-19', 85, 0, 'B3', 'END_BUCKET', 3, 9150000, 3889000, 97539000, 9, 'MEDIUM', 85, 3, 'FC03', false, 'TRANSFERRED', '{"name": "Ahmad Wati", "relation": "Kakak", "phone": "0812-5550-3516"}'::jsonb, '[]'::jsonb, '{"at": "2026-11-06T11:40:00", "type": "VISIT", "result": "UNIT_MOVED"}'::jsonb, null, 0, false) on conflict (contract_no) do nothing;
insert into public.ucs_accounts (contract_no, name, phone, phone_status, job, address, area, zipcode, product, unit, year, plate, tenor, inst_no, installment, due_day, oldest_due, dpd, days_to_due, bucket, stage, overdue_count, overdue_amount, penalty, os_principal, mob, segment, max_dpd_12m, sp_level, collector_id, rmp_flag, unit_status, emergency, extra_contacts, last_contact, active_ptp, field_paid, escalated) values ('SMF-2W-23687', 'Fajar Ramadhan', '0812-5550-2073', 'VALID', 'Karyawan toko', 'Jl. Cempaka No. 8 RT 09/RW 12, Mangunjaya, Tambun Selatan', 'Mangunjaya', '17510', '2W', 'Yamaha Mio M3', 2020, 'B 2993 HNB', 30, 23, 720000, 31, '2026-07-31', 104, 0, 'B4UP', 'END_BUCKET', 4, 2880000, 1498000, 4132799, 23, 'HIGH', 104, 3, 'FC03', false, 'WITH_DEBTOR', '{"name": "Gunawan Ramadhan", "relation": "Kakak", "phone": "0812-5550-3553"}'::jsonb, '[]'::jsonb, null, null, 0, false) on conflict (contract_no) do nothing;

-- Riwayat aktivitas
insert into public.ucs_activities (id, contract_no, type, result, actor, occurred_at, work_date, notes, contacted) values ('act-seed-01', 'SMF-2W-20975', 'CALL', 'NOANS', 'TC01', '2026-11-11T09:40:00', '2026-11-11', 'Dua kali panggilan tidak diangkat.', 'NONE') on conflict (id) do nothing;
insert into public.ucs_activities (id, contract_no, type, result, actor, occurred_at, work_date, notes, contacted, ptp_date, ptp_amount) values ('act-seed-02', 'SMF-2W-21088', 'CALL', 'PTP', 'TC01', '2026-11-11T10:05:00', '2026-11-11', 'Gajian tanggal 12, janji transfer.', 'DEBTOR', '2026-11-12', 1420000) on conflict (id) do nothing;
insert into public.ucs_activities (id, contract_no, type, result, actor, occurred_at, work_date, notes, contacted) values ('act-seed-03', 'SMF-2W-21201', 'CALL', 'BUSY', 'TC02', '2026-11-11T11:20:00', '2026-11-11', 'Sedang bekerja, minta dihubungi setelah jam 16.00.', 'DEBTOR') on conflict (id) do nothing;
insert into public.ucs_activities (id, contract_no, type, result, actor, occurred_at, work_date, notes, contacted, ptp_date, ptp_amount) values ('act-seed-04', 'SMF-2W-21427', 'CALL', 'PTP', 'TC02', '2026-11-10T14:10:00', '2026-11-10', 'Istri menyampaikan akan bayar akhir pekan.', 'SPOUSE', '2026-11-14', 980000) on conflict (id) do nothing;
insert into public.ucs_activities (id, contract_no, type, result, actor, occurred_at, work_date, notes, contacted) values ('act-seed-05', 'SMF-2W-21540', 'CALL', 'INVALID', 'TC01', '2026-11-11T13:30:00', '2026-11-11', 'Nomor tidak aktif.', 'NONE') on conflict (id) do nothing;
insert into public.ucs_activities (id, contract_no, type, result, actor, occurred_at, work_date, notes, met_with, ptp_date, ptp_amount) values ('act-seed-06', 'SMF-2W-21653', 'VISIT', 'PTP', 'FC01', '2026-11-10T10:15:00', '2026-11-10', 'Usaha sepi, janji bayar satu angsuran.', 'DEBTOR', '2026-11-12', 890000) on conflict (id) do nothing;
insert into public.ucs_activities (id, contract_no, type, result, actor, occurred_at, work_date, notes, met_with) values ('act-seed-07', 'SMF-2W-21766', 'VISIT', 'NOTMEET', 'FC01', '2026-11-11T11:00:00', '2026-11-11', 'Rumah kosong, pesan dititip ke tetangga.', 'NEIGHBOR') on conflict (id) do nothing;
insert into public.ucs_activities (id, contract_no, type, result, actor, occurred_at, work_date, notes, met_with) values ('act-seed-08', 'SMF-2W-21992', 'VISIT', 'MEET_NOPAY', 'FC01', '2026-11-09T15:20:00', '2026-11-09', 'Menunggu pencairan dana dari keluarga.', 'DEBTOR') on conflict (id) do nothing;
insert into public.ucs_activities (id, contract_no, type, result, actor, occurred_at, work_date, notes, met_with, ptp_date, ptp_amount) values ('act-seed-09', 'SMF-2W-22218', 'VISIT', 'PTP', 'FC01', '2026-11-07T09:45:00', '2026-11-07', 'Janji bayar tanggal 9.', 'SPOUSE', '2026-11-09', 790000) on conflict (id) do nothing;
insert into public.ucs_activities (id, contract_no, type, result, actor, occurred_at, work_date, notes, met_with) values ('act-seed-10', 'SMF-2W-22670', 'VISIT', 'ADDR_INVALID', 'FC02', '2026-11-10T13:10:00', '2026-11-10', 'Menurut tetangga sudah pindah sejak bulan lalu.', 'NEIGHBOR') on conflict (id) do nothing;
insert into public.ucs_activities (id, contract_no, type, result, actor, occurred_at, work_date, notes, met_with) values ('act-seed-11', 'SMF-2W-22896', 'VISIT', 'RMP_REQ', 'FC02', '2026-11-11T10:30:00', '2026-11-11', 'Penghasilan turun, minta perpanjangan tenor.', 'DEBTOR') on conflict (id) do nothing;
insert into public.ucs_activities (id, contract_no, type, result, actor, occurred_at, work_date, notes, met_with) values ('act-seed-12', 'SMF-2W-23348', 'VISIT', 'UNCOOP', 'FC03', '2026-11-08T14:00:00', '2026-11-08', 'Menolak membahas pembayaran.', 'DEBTOR') on conflict (id) do nothing;
insert into public.ucs_activities (id, contract_no, type, result, actor, occurred_at, work_date, notes, met_with) values ('act-seed-13', 'SMF-4W-23574', 'VISIT', 'UNIT_MOVED', 'FC03', '2026-11-06T11:40:00', '2026-11-06', 'Unit disebut dipakai saudara di luar kota.', 'FAMILY') on conflict (id) do nothing;
insert into public.ucs_activities (id, contract_no, type, result, actor, occurred_at, work_date, notes, contacted, ptp_date, ptp_amount) values ('act-seed-14', 'SMF-2W-20636', 'CALL', 'PTP', 'TC01', '2026-11-11T15:05:00', '2026-11-11', 'Akan bayar tepat jatuh tempo.', 'DEBTOR', '2026-11-15', 1420000) on conflict (id) do nothing;

-- Janji bayar
insert into public.ucs_ptp (id, contract_no, promise_date, amount, status, source, actor, created_at) values ('ptp-seed-01', 'SMF-2W-21088', '2026-11-12', 1420000, 'ACTIVE', 'CALL', 'TC01', '2026-11-10T10:00:00') on conflict (id) do nothing;
insert into public.ucs_ptp (id, contract_no, promise_date, amount, status, source, actor, created_at) values ('ptp-seed-02', 'SMF-2W-21427', '2026-11-14', 980000, 'ACTIVE', 'CALL', 'TC02', '2026-11-10T10:00:00') on conflict (id) do nothing;
insert into public.ucs_ptp (id, contract_no, promise_date, amount, status, source, actor, created_at) values ('ptp-seed-03', 'SMF-2W-21653', '2026-11-12', 890000, 'ACTIVE', 'VISIT', 'FC01', '2026-11-10T10:00:00') on conflict (id) do nothing;
insert into public.ucs_ptp (id, contract_no, promise_date, amount, status, source, actor, created_at) values ('ptp-seed-04', 'SMF-2W-22218', '2026-11-09', 790000, 'BROKEN', 'VISIT', 'FC01', '2026-11-10T10:00:00') on conflict (id) do nothing;
insert into public.ucs_ptp (id, contract_no, promise_date, amount, status, source, actor, created_at) values ('ptp-seed-05', 'SMF-2W-20636', '2026-11-15', 1420000, 'ACTIVE', 'CALL', 'TC01', '2026-11-10T10:00:00') on conflict (id) do nothing;

-- Stok TTR
insert into public.ucs_ttr (ttr_no, status, issued_to, issued_at, contract_no, amount, payer, deposit_status, used_at, akh_date) values ('TTR-0048201', 'ISSUED', 'FC01', '2026-11-12T08:40:00', null, 0, '', '', null, null) on conflict (ttr_no) do nothing;
insert into public.ucs_ttr (ttr_no, status, issued_to, issued_at, contract_no, amount, payer, deposit_status, used_at, akh_date) values ('TTR-0048202', 'ISSUED', 'FC01', '2026-11-12T08:40:00', null, 0, '', '', null, null) on conflict (ttr_no) do nothing;
insert into public.ucs_ttr (ttr_no, status, issued_to, issued_at, contract_no, amount, payer, deposit_status, used_at, akh_date) values ('TTR-0048203', 'ISSUED', 'FC01', '2026-11-12T08:40:00', null, 0, '', '', null, null) on conflict (ttr_no) do nothing;
insert into public.ucs_ttr (ttr_no, status, issued_to, issued_at, contract_no, amount, payer, deposit_status, used_at, akh_date) values ('TTR-0048204', 'ISSUED', 'FC01', '2026-11-12T08:40:00', null, 0, '', '', null, null) on conflict (ttr_no) do nothing;
insert into public.ucs_ttr (ttr_no, status, issued_to, issued_at, contract_no, amount, payer, deposit_status, used_at, akh_date) values ('TTR-0048205', 'ISSUED', 'FC02', '2026-11-12T08:40:00', null, 0, '', '', null, null) on conflict (ttr_no) do nothing;
insert into public.ucs_ttr (ttr_no, status, issued_to, issued_at, contract_no, amount, payer, deposit_status, used_at, akh_date) values ('TTR-0048206', 'ISSUED', 'FC02', '2026-11-12T08:40:00', null, 0, '', '', null, null) on conflict (ttr_no) do nothing;
insert into public.ucs_ttr (ttr_no, status, issued_to, issued_at, contract_no, amount, payer, deposit_status, used_at, akh_date) values ('TTR-0048207', 'ISSUED', 'FC02', '2026-11-12T08:40:00', null, 0, '', '', null, null) on conflict (ttr_no) do nothing;
insert into public.ucs_ttr (ttr_no, status, issued_to, issued_at, contract_no, amount, payer, deposit_status, used_at, akh_date) values ('TTR-0048208', 'ISSUED', 'FC02', '2026-11-12T08:40:00', null, 0, '', '', null, null) on conflict (ttr_no) do nothing;
insert into public.ucs_ttr (ttr_no, status, issued_to, issued_at, contract_no, amount, payer, deposit_status, used_at, akh_date) values ('TTR-0048209', 'ISSUED', 'FC03', '2026-11-12T08:40:00', null, 0, '', '', null, null) on conflict (ttr_no) do nothing;
insert into public.ucs_ttr (ttr_no, status, issued_to, issued_at, contract_no, amount, payer, deposit_status, used_at, akh_date) values ('TTR-0048210', 'ISSUED', 'FC03', '2026-11-12T08:40:00', null, 0, '', '', null, null) on conflict (ttr_no) do nothing;
insert into public.ucs_ttr (ttr_no, status, issued_to, issued_at, contract_no, amount, payer, deposit_status, used_at, akh_date) values ('TTR-0048211', 'ISSUED', 'FC03', '2026-11-12T08:40:00', null, 0, '', '', null, null) on conflict (ttr_no) do nothing;
insert into public.ucs_ttr (ttr_no, status, issued_to, issued_at, contract_no, amount, payer, deposit_status, used_at, akh_date) values ('TTR-0048212', 'ISSUED', 'FC03', '2026-11-12T08:40:00', null, 0, '', '', null, null) on conflict (ttr_no) do nothing;

-- Pengajuan RMP
insert into public.ucs_rmp (id, contract_no, type, reason, status, channel, actor, created_at) values ('rmp-seed-01', 'SMF-2W-22896', 'TENOR_EXT', 'Penghasilan turun sejak pindah kerja.', 'DIAJUKAN', 'MOBILE', 'FC02', '2026-11-11T10:32:00') on conflict (id) do nothing;

-- Kasus skip tracing
insert into public.ucs_skip_cases (id, contract_no, trigger_source, status, note, new_contact, actor, created_at) values ('skip-seed-01', 'SMF-2W-21540', 'CALL_INVALID', 'OPEN', 'Nomor utama tidak aktif.', '', 'TC01', '2026-11-11T13:31:00') on conflict (id) do nothing;
insert into public.ucs_skip_cases (id, contract_no, trigger_source, status, note, new_contact, actor, created_at) values ('skip-seed-02', 'SMF-2W-22670', 'VISIT_ADDR_INVALID', 'OPEN', 'Debitur pindah, alamat baru belum diketahui.', '', 'FC02', '2026-11-10T13:12:00') on conflict (id) do nothing;
