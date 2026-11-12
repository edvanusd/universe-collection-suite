"""Uji fungsi backend di Postgres lokal yang sudah berisi supabase_stub.sql + setup.sql.

    python3 supabase/test/test_backend.py "host=/tmp port=54329 dbname=ucs user=postgres"
"""
import sys
import psycopg

DSN = sys.argv[1] if len(sys.argv) > 1 else "host=/tmp port=54329 dbname=ucs user=postgres"
conn = psycopg.connect(DSN, autocommit=False)
UID = {r[0]: str(r[1]) for r in conn.execute("select id, user_id from ucs_staff").fetchall()}
conn.commit()
passed = 0


def run(sql, params=(), who=None, role="authenticated"):
    """Jalankan satu 'request' seperti PostgREST: peran + klaim JWT, satu transaksi."""
    with conn.transaction():
        cur = conn.cursor()
        cur.execute("set local role " + role)
        cur.execute("select set_config('request.jwt.claim.sub', %s, true)", (UID.get(who, who) or "",))
        cur.execute(sql, params)
        return cur.fetchall() if cur.description else None


def sql(q, params=()):
    with conn.transaction():
        cur = conn.cursor()
        cur.execute(q, params)
        return cur.fetchall() if cur.description else None


def ok(name, cond):
    global passed
    if not cond:
        raise AssertionError("GAGAL: " + name)
    passed += 1
    print("  ok ", name)


def fails(name, fn, needle):
    global passed
    try:
        fn()
    except psycopg.Error as e:
        msg = str(e)
        if needle not in msg:
            raise AssertionError("GAGAL: %s -> pesan tak terduga: %s" % (name, msg))
        passed += 1
        print("  ok ", name, "->", msg.splitlines()[0][:90])
        return
    raise AssertionError("GAGAL: %s -> tidak ada error" % name)


P = sql("select process_date from ucs_app_config")[0][0]
acc = lambda stage: sql("select contract_no from ucs_accounts where stage=%s order by contract_no limit 1", (stage,))[0][0]

print("Akses tanpa login dan non-petugas")
fails("anon tidak bisa membaca account", lambda: run("select * from ucs_accounts", role="anon"), "permission denied")
ok("anon bisa cek ID login", run("select ucs_staff_login('tc01')", role="anon")[0][0]["role"] == "TELE")
ok("ID tidak aktif/tidak ada -> null", run("select ucs_staff_login('XX99')", role="anon")[0][0] is None)
fails("anon tidak bisa memanggil RPC", lambda: run("select ucs_record_call('x','PTP')", role="anon"), "permission denied")
stranger = "11111111-1111-1111-1111-111111111111"
ok("login non-petugas tidak melihat data", run("select count(*) from ucs_accounts", who=stranger)[0][0] == 0)
fails("non-petugas ditolak RPC", lambda: run("select ucs_record_call(%s,'NOANS')", (acc('TELE'),), who=stranger), "Sesi tidak valid")
ok("petugas melihat semua account", run("select count(*) from ucs_accounts", who="TC01")[0][0] == 30)
fails("tabel tidak bisa ditulis langsung", lambda: run("update ucs_accounts set name='x'", who="ADM01"), "permission denied")
ok("whoami", run("select ucs_whoami()", who="FC01")[0][0]["name"] == "Rizky Pratama")

print("Desk Call")
tele = sql("select contract_no from ucs_accounts where stage='TELE' and active_ptp is null and phone_status='VALID' and contract_no not in (select contract_no from ucs_skip_cases) and contract_no not in (select contract_no from ucs_rmp) order by contract_no")
c1, c2, c3 = [r[0] for r in tele[:3]]
c4 = sql("select contract_no from ucs_accounts where contract_no not in (select contract_no from ucs_rmp) and stage in ('FIELD','REMEDIAL') order by contract_no limit 1")[0][0]
fails("FC tidak boleh mencatat call", lambda: run("select ucs_record_call(%s,'NOANS')", (c1,), who="FC01"), "Akses ditolak")
fails("PTP di luar batas 7 hari", lambda: run("select ucs_record_call(%s,'PTP',null,'DEBTOR','',%s::date+10,500000)", (c1, P), who="TC01"), "Tanggal janji")
run("select ucs_record_call(%s,'PTP',null,'DEBTOR','janji',%s::date+2,500000)", (c1, P), who="TC01")
ok("PTP tercatat dan aktif di account", sql("select active_ptp->>'amount' from ucs_accounts where contract_no=%s", (c1,))[0][0] == "500000")
run("select ucs_record_call(%s,'PTP',null,'DEBTOR','ganti tanggal',%s::date+3,450000)", (c1, P), who="TC01")
ok("PTP lama otomatis ingkar, hanya satu yang aktif",
   sql("select count(*) filter (where status='ACTIVE'), count(*) filter (where status='BROKEN') from ucs_ptp where contract_no=%s", (c1,))[0] == (1, 1))
fails("BUSY wajib isi waktu", lambda: run("select ucs_record_call(%s,'BUSY')", (c2,), who="TC01"), "menghubungi lagi")
fails("REFUSE wajib catatan", lambda: run("select ucs_record_call(%s,'REFUSE')", (c2,), who="TC01"), "Catatan wajib")
run("select ucs_record_call(%s,'REFUSE',null,'DEBTOR','menolak bayar')", (c2,), who="TC01")
row = sql("select escalated, collector_id from ucs_accounts where contract_no=%s", (c2,))[0]
ok("REFUSE -> eskalasi dan ditugaskan ke FC", row[0] is True and row[1] in ("FC01", "FC02", "FC03"))
run("select ucs_record_call(%s,'INVALID')", (c3,), who="TC02")
ok("INVALID -> nomor ditandai + kasus skip", sql("select phone_status from ucs_accounts where contract_no=%s", (c3,))[0][0] == "INVALID"
   and sql("select count(*) from ucs_skip_cases where contract_no=%s and status='OPEN'", (c3,))[0][0] == 1)
run("select ucs_record_call(%s,'RMP',null,'DEBTOR','minta keringanan',null,null,null,'DEFERRAL')", (c4,), who="TC01")
ok("RMP lewat call tercatat", sql("select count(*) from ucs_rmp where contract_no=%s and channel='TELE'", (c4,))[0][0] == 1)
ok("aktivitas call tersimpan dengan work_date", sql("select count(*) from ucs_activities where type='CALL' and work_date=%s", (P,))[0][0] >= 5)

ptp_id = sql("select id from ucs_ptp where contract_no=%s and status='ACTIVE'", (c1,))[0][0]
run("select ucs_set_ptp_status(%s,'KEPT')", (ptp_id,), who="TC01")
ok("PTP ditandai ditepati, account bersih", sql("select active_ptp from ucs_accounts where contract_no=%s", (c1,))[0][0] is None)
fails("PTP yang ditutup tidak bisa diubah lagi", lambda: run("select ucs_set_ptp_status(%s,'BROKEN')", (ptp_id,), who="TC01"), "sudah ditutup")

sk = sql("select id from ucs_skip_cases where contract_no=%s", (c3,))[0][0]
fails("skip FOUND wajib isi data", lambda: run("select ucs_resolve_skip(%s,true,'PHONE','')", (sk,), who="TC01"), "Isi nomor")
run("select ucs_resolve_skip(%s,true,'PHONE','0812-1111-2222','kontak darurat')", (sk,), who="TC01")
row = sql("select phone_status, extra_contacts from ucs_accounts where contract_no=%s", (c3,))[0]
ok("skip FOUND -> kontak baru + nomor valid lagi", row[0] == "VALID" and row[1][-1]["value"] == "0812-1111-2222")

spacc = sql("select contract_no, sp_level from ucs_accounts where sp_level < ucs_sp_due(dpd) order by dpd desc limit 1")[0]
run("select ucs_issue_sp(%s)", (spacc[0],), who="TC02")
ok("SP terbit dan level naik", sql("select sp_level from ucs_accounts where contract_no=%s", (spacc[0],))[0][0] == spacc[1] + 1)
early = sql("select contract_no from ucs_accounts where dpd < 7 limit 1")[0][0]
fails("SP belum waktunya ditolak", lambda: run("select ucs_issue_sp(%s)", (early,), who="TC01"), "belum waktunya")

print("Front Coll")
fc_acc = sql("select contract_no from ucs_accounts where collector_id='FC01' order by contract_no")
v1, v2, v3 = [r[0] for r in fc_acc[:3]]
ttr1 = sql("select ttr_no from ucs_ttr where issued_to='FC01' and status='ISSUED' order by ttr_no limit 1")[0][0]
ttr_other = sql("select ttr_no from ucs_ttr where issued_to='FC02' and status='ISSUED' limit 1")[0][0]
fails("TELE tidak boleh mencatat kunjungan", lambda: run("select ucs_record_visit(%s,'NOTMEET','DEBTOR','x')", (v1,), who="TC01"), "Akses ditolak")
fails("TTR milik petugas lain ditolak",
      lambda: run("select ucs_record_visit(%s,'PAID','DEBTOR','',true,700000,%s)", (v1, ttr_other), who="FC01"), "bukan milik Anda")
run("""select ucs_record_visit(p_contract_no=>%s, p_result=>'PAID', p_amount=>700000, p_ttr_no=>%s,
       p_lat=>-6.24, p_lng=>106.98, p_accuracy=>9, p_distance=>41, p_photos=>1)""", (v1, ttr1), who="FC01")
t = sql("select status, contract_no, deposit_status, amount from ucs_ttr where ttr_no=%s", (ttr1,))[0]
ok("PAID -> TTR terpakai dan menunggu setoran", t == ("USED", v1, "PENDING", 700000))
ok("PAID -> field_paid bertambah", sql("select field_paid from ucs_accounts where contract_no=%s", (v1,))[0][0] >= 700000)
ok("GPS dummy tersimpan", sql("select distance_m, gps_dummy from ucs_activities where contract_no=%s and result='PAID'", (v1,))[0] == (41, True))
fails("TTR yang sama tidak bisa dipakai lagi",
      lambda: run("select ucs_record_visit(%s,'PAID','DEBTOR','',true,700000,%s)", (v2, ttr1), who="FC01"), "tidak tersedia")
fails("hasil selain bayar/janji wajib catatan", lambda: run("select ucs_record_visit(%s,'NOTMEET')", (v2,), who="FC01"), "Catatan wajib")
run("select ucs_record_visit(%s,'ADDR_INVALID','NEIGHBOR','pindah',false)", (v2,), who="FC01")
ok("ADDR_INVALID -> kasus skip + unit tidak terlihat",
   sql("select count(*) from ucs_skip_cases where contract_no=%s and trigger_source='VISIT_ADDR_INVALID'", (v2,))[0][0] == 1
   and sql("select unit_status from ucs_accounts where contract_no=%s", (v2,))[0][0] == "NOT_SEEN")
run("select ucs_record_visit(p_contract_no=>%s, p_result=>'PTP', p_ptp_date=>%s::date+1, p_ptp_amount=>300000)", (v3, P), who="FC01")
ok("janji bayar dari kunjungan", sql("select source from ucs_ptp where contract_no=%s and status='ACTIVE'", (v3,))[0][0] == "VISIT")
run("select ucs_add_contact(%s,'ADDRESS','Jl. Baru 9','debitur')", (v3,), who="FC01")
ok("tambah kontak", sql("select extra_contacts->-1->>'source' from ucs_accounts where contract_no=%s", (v3,))[0][0] == "debitur")
ok("setoran TTR", run("select ucs_deposit_ttr()", who="FC01")[0][0] == 1)
fails("setoran kedua kosong", lambda: run("select ucs_deposit_ttr()", who="FC01"), "Tidak ada TTR")

print("RMP")
young = sql("select contract_no from ucs_accounts where mob <= 6 limit 1")[0][0]
fails("MOB <= 6 tidak layak", lambda: run("select ucs_submit_rmp(%s,'TENOR_EXT','turun')", (young,), who="FC01"), "MOB")
fails("RMP ganda ditolak", lambda: run("select ucs_submit_rmp(%s,'SETTLEMENT','x')", (c4,), who="TC01"), "menunggu keputusan")
elig = sql("select contract_no from ucs_accounts where mob > 6 and dpd <= 30 and max_dpd_12m <= 90 and not rmp_flag and contract_no not in (select contract_no from ucs_rmp) limit 1")[0][0]
rid = run("select ucs_submit_rmp(%s,'DEFERRAL','penghasilan turun')", (elig,), who="FC01")[0][0]
ok("RMP dari mobile berkanal MOBILE", sql("select channel from ucs_rmp where id=%s", (rid,))[0][0] == "MOBILE")
fails("TELE tidak bisa memutuskan RMP", lambda: run("select ucs_decide_rmp(%s,'DISETUJUI')", (rid,), who="TC01"), "Akses ditolak")
run("select ucs_decide_rmp(%s,'DISETUJUI')", (rid,), who="ADM01")
ok("RMP disetujui -> rmp_flag", sql("select rmp_flag from ucs_accounts where contract_no=%s", (elig,))[0][0] is True)

print("Admin")
n = run("select ucs_issue_ttr('FC02', 9000001, 3)", who="ADM01")[0][0]
ok("serahkan 3 TTR", n == 3)
fails("rentang TTR yang sama ditolak", lambda: run("select ucs_issue_ttr('FC02', 9000001, 3)", who="ADM01"), "sudah terdaftar")
fails("TTR ke non-FC ditolak", lambda: run("select ucs_issue_ttr('TC01', 9100001, 1)", who="ADM01"), "bukan field collector")
run("select ucs_void_ttr('TTR-9000001')", who="ADM01")
ok("batalkan TTR", sql("select status from ucs_ttr where ttr_no='TTR-9000001'")[0][0] == "VOID")
newno = run("""select ucs_save_account(null, '{"name":"Tes Baru","phone":"0812","address":"Jl. A","unit":"Honda Beat",
  "installment":"800000","oldest_due":"%s","tenor":"36","inst_no":"5","product":"2W","plate":"b 1 xy","mob":"5"}'::jsonb)""" % (P.replace(day=1) if P.day > 20 else P,), who="ADM01")[0][0]
ok("account baru dengan nomor otomatis", newno.startswith("SMF-2W-3"))
due20 = sql("select %s::date - 20", (P,))[0][0]
run("""select ucs_save_account(%s, jsonb_build_object('name','Tes Baru','phone','0812','address','Jl. A','unit','Honda Beat',
  'installment',800000,'oldest_due',%s::text,'tenor',36,'inst_no',5,'plate','B 1 XY','mob',5))""", (newno, due20), who="ADM01")
row = sql("select dpd, bucket, stage, overdue_amount, collector_id from ucs_accounts where contract_no=%s", (newno,))[0]
ok("posisi dihitung server (DPD 20, B1, FIELD)", row[:4] == (20, "B1", "FIELD", 800000) and row[4] is None)
fails("account wajib isi data pokok", lambda: run("select ucs_save_account(null, '{\"name\":\"x\"}'::jsonb)", who="ADM01"), "wajib diisi")
fails("TELE tidak boleh ubah account", lambda: run("select ucs_save_account(%s, '{}'::jsonb)", (newno,), who="TC01"), "Akses ditolak")
run("select ucs_assign_collector(%s,'FC03')", (newno,), who="ADM01")
ok("penugasan", sql("select collector_id from ucs_accounts where contract_no=%s", (newno,))[0][0] == "FC03")
fails("tugaskan ke non-FC ditolak", lambda: run("select ucs_assign_collector(%s,'TC01')", (newno,), who="ADM01"), "bukan field collector")

fails("petugas baru wajib kata sandi", lambda: run("select ucs_save_staff('FC04','Bayu','FC','',null,true)", who="ADM01"), "kata sandi awal")
run("select ucs_save_staff('fc04','Bayu Saputra','FC','Bucket 1','rahasia9',true)", who="ADM01")
row = sql("select s.email, u.encrypted_password = extensions.crypt('rahasia9', u.encrypted_password) from ucs_staff s join auth.users u on u.id=s.user_id where s.id='FC04'")[0]
ok("petugas baru punya akun login dan sandi benar", row[0] == "fc04@ucs-demo.example.com" and row[1] is True)
fails("ID ganda ditolak", lambda: run("select ucs_save_staff('FC04','X','FC','','abcdef',true)", who="ADM01"), "sudah dipakai")
fails("admin tidak bisa ubah peran sendiri", lambda: run("select ucs_save_staff('ADM01','Putri','TELE','',null,false)", who="ADM01"), "peran akun sendiri")
run("select ucs_delete_staff('FC03')", who="ADM01")
ok("petugas nonaktif: account dilepas, login ditolak",
   sql("select count(*) from ucs_accounts where collector_id='FC03'")[0][0] == 0
   and run("select ucs_staff_login('FC03')", role="anon")[0][0] is None)
fails("petugas nonaktif tidak bisa memakai RPC", lambda: run("select ucs_deposit_ttr()", who="FC03"), "Sesi tidak valid")
fails("admin tidak bisa menonaktifkan diri sendiri", lambda: run("select ucs_delete_staff('ADM01')", who="ADM01"), "akun sendiri")

print("Batch harian")
fails("TELE tidak boleh menjalankan batch", lambda: run("select ucs_refresh_positions()", who="TC01"), "Akses ditolak")
before = dict(sql("select contract_no, dpd from ucs_accounts"))
active_ptp = sql("select contract_no from ucs_ptp where status='ACTIVE' and promise_date < %s::date + 5", (P,))
n = run("select ucs_refresh_positions(%s::date + 5)", (P,), who="ADM01")[0][0]
after = dict(sql("select contract_no, dpd from ucs_accounts"))
ok("batch menghitung ulang semua account", n == len(before))
ok("DPD account menunggak bertambah 5", all(after[k] == before[k] + 5 for k in before if before[k] > 0))
ok("janji bayar yang lewat menjadi ingkar",
   all(sql("select status from ucs_ptp where contract_no=%s order by created_at desc limit 1", (c[0],))[0][0] == "BROKEN" for c in active_ptp))
ok("tanggal proses maju", sql("select process_date from ucs_app_config")[0][0] == sql("select %s::date + 5", (P,))[0][0])

conn.rollback()
print("\n%d pemeriksaan lulus" % passed)
