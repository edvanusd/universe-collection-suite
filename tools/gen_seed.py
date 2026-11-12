import json, random, os, datetime as dt
random.seed(7)
P = dt.date(2026,11,12)
names = ["Ahmad Fauzi","Siti Rahmawati","Budi Santoso","Dewi Lestari","Eko Prasetyo","Fitri Handayani","Gunawan Wibowo","Hendra Saputra","Indah Permatasari","Joko Susilo","Kartika Sari","Lukman Hakim","Maya Anggraini","Nur Hidayat","Oktaviani Putri","Purnomo Adi","Rina Marlina","Slamet Riyadi","Tri Wahyuni","Usman Effendi","Vina Oktaviana","Wahyu Nugroho","Yanti Susanti","Zainal Abidin","Agus Setiawan","Bambang Hermanto","Citra Kirana","Dedi Kurniawan","Erna Wati","Fajar Ramadhan"]
areas = [("Margahayu","17113","Bekasi Timur"),("Duren Jaya","17111","Bekasi Timur"),("Aren Jaya","17111","Bekasi Timur"),("Bekasi Jaya","17112","Bekasi Timur"),("Jatimulya","17510","Tambun Selatan"),("Mangunjaya","17510","Tambun Selatan"),("Setiamekar","17510","Tambun Selatan"),("Mustika Jaya","17158","Mustika Jaya")]
streets = ["Jl. Mawar","Jl. Kenanga","Jl. Cempaka","Jl. Rajawali","Jl. Merpati","Jl. Pahlawan","Jl. Nusantara","Gg. Haji Saleh","Jl. Kemuning","Jl. Garuda"]
u2 = [("Honda Beat 110",1650000,790000),("Honda Vario 125",2100000,980000),("Yamaha NMAX 155",3200000,1420000),("Honda Scoopy",1900000,890000),("Yamaha Mio M3",1500000,720000)]
u4 = [("Toyota Avanza 1.3 G",21000000,4350000),("Daihatsu Gran Max PU",15000000,3180000),("Honda Brio Satya",16500000,3460000),("Suzuki Carry PU",14500000,3050000)]
jobs = ["Karyawan pabrik","Pedagang","Pengemudi ojek daring","Wiraswasta","Karyawan toko","Buruh harian"]
rel = ["Istri","Suami","Kakak","Adik","Orang tua"]
def phone(i): return "0812-5550-%04d" % (1000+i*37)
# (dpd or -days_to_due, segment, collector, stage)
plan = [(-1,"HIGH"),(-2,"MEDIUM"),(-3,"HIGH"),(-4,"HIGH"),(-6,"LOW"),
        (1,"LOW"),(2,"MEDIUM"),(3,"HIGH"),(4,"LOW"),(6,"MEDIUM"),(7,"HIGH"),
        (9,"MEDIUM"),(11,"HIGH"),(13,"LOW"),(15,"HIGH"),(18,"MEDIUM"),(21,"HIGH"),(24,"MEDIUM"),(27,"HIGH"),(29,"LOW"),
        (33,"HIGH"),(38,"MEDIUM"),(44,"HIGH"),(49,"HIGH"),(53,"MEDIUM"),(58,"HIGH"),
        (64,"HIGH"),(72,"HIGH"),(85,"MEDIUM"),(104,"HIGH")]
accs=[]
for i,(d,seg) in enumerate(plan):
    four = i%5==3
    unit,price,inst = random.choice(u4 if four else u2)
    dpd = max(d,0); dtd = -d if d<0 else 0
    oldest = P - dt.timedelta(days=dpd) if dpd else P + dt.timedelta(days=dtd)
    if dpd==0: b,st,col="B0","REMINDER",None
    elif dpd<=7: b,st,col="B1","TELE",None
    elif dpd<=30: b,st,col="B1","FIELD","FC01"
    elif dpd<=60: b,st,col="B2","REMEDIAL","FC02"
    elif dpd<=90: b,st,col="B3","END_BUCKET","FC03"
    else: b,st,col="B4UP","END_BUCKET","FC03"
    cnt = 0 if dpd==0 else 1+dpd//30
    kel,zipc,kec = areas[i%len(areas)]
    mob = random.choice([4,5,8,11,14,19,23,27]) if seg=="HIGH" else random.choice([9,12,16,22,28])
    tenor = 48 if four else random.choice([24,30,36])
    sp = 3 if dpd>=21 else 2 if dpd>=14 else 1 if dpd>=7 else 0
    if dpd in (7,15,21,24): sp -= 1   # SP yang belum terbit, untuk daftar Desk Call
    a = dict(name=names[i], phone=phone(i), phone_status="VALID", job=random.choice(jobs),
        address="%s No. %d RT %02d/RW %02d, %s, %s" % (random.choice(streets), random.randint(3,88), random.randint(1,9), random.randint(1,12), kel, kec),
        area=kel, zipcode=zipc, product="4W" if four else "2W", unit=unit, year=random.randint(2019,2025),
        plate="B %d %s" % (random.randint(1200,9800), "".join(random.choice("ABDFGHKLNPRSTUVZ") for _ in range(3))),
        tenor=tenor, inst_no=min(mob,tenor), installment=inst, due_day=oldest.day, oldest_due=oldest.isoformat(),
        dpd=dpd, days_to_due=dtd, bucket=b, stage=st, overdue_count=cnt, overdue_amount=cnt*inst,
        penalty=int(round(inst*0.005*dpd*max(cnt,1)/1000.0)*1000), os_principal=int(inst*(tenor-min(mob,tenor))*0.82),
        mob=mob, segment=seg, max_dpd_12m=max(dpd, random.choice([0,12,34]) if seg!="LOW" else dpd), sp_level=max(sp,0),
        collector_id=col, rmp_flag=False, unit_status="WITH_DEBTOR",
        emergency=dict(name=random.choice(names).split()[0]+" "+names[i].split()[-1], relation=random.choice(rel), phone=phone(i+40)),
        extra_contacts=[], last_contact=None, active_ptp=None, field_paid=0, escalated=False)
    accs.append(("SMF-%s-%05d" % ("4W" if four else "2W", 20410+i*113), a))
A = dict(accs)
ids = [k for k,_ in accs]
acts=[]; ptps=[]; skips=[]; rmps=[]
def ts(daysago,h,m): return (dt.datetime.combine(P-dt.timedelta(days=daysago), dt.time(h,m))).isoformat()
def act(n,cid,typ,res,by,daysago,h,m,**kw):
    a=dict(contract_no=cid,type=typ,result=res,by=by,at=ts(daysago,h,m),work_date=(P-dt.timedelta(days=daysago)).isoformat(),notes=kw.pop("notes",""),**kw)
    acts.append(("act-seed-%02d"%n,a))
    if typ in("CALL","VISIT"): A[cid]["last_contact"]=dict(at=a["at"],type=typ,result=res)
def ptp(n,cid,date,amt,src,by,status="ACTIVE"):
    ptps.append(("ptp-seed-%02d"%n,dict(contract_no=cid,date=date.isoformat(),amount=amt,status=status,source=src,by=by,created_at=ts(2,10,0))))
    if status=="ACTIVE": A[cid]["active_ptp"]=dict(date=date.isoformat(),amount=amt)
i=ids
act(1,i[5],"CALL","NOANS","TC01",1,9,40,contacted="NONE",notes="Dua kali panggilan tidak diangkat.")
act(2,i[6],"CALL","PTP","TC01",1,10,5,contacted="DEBTOR",notes="Gajian tanggal 12, janji transfer.",ptp_date=P.isoformat(),ptp_amount=A[i[6]]["installment"])
ptp(1,i[6],P,A[i[6]]["installment"],"CALL","TC01")
act(3,i[7],"CALL","BUSY","TC02",1,11,20,contacted="DEBTOR",notes="Sedang bekerja, minta dihubungi setelah jam 16.00.")
act(4,i[9],"CALL","PTP","TC02",2,14,10,contacted="SPOUSE",notes="Istri menyampaikan akan bayar akhir pekan.",ptp_date=(P+dt.timedelta(days=2)).isoformat(),ptp_amount=A[i[9]]["installment"])
ptp(2,i[9],P+dt.timedelta(days=2),A[i[9]]["installment"],"CALL","TC02")
act(5,i[10],"CALL","INVALID","TC01",1,13,30,contacted="NONE",notes="Nomor tidak aktif.")
A[i[10]]["phone_status"]="INVALID"
skips.append(("skip-seed-01",dict(contract_no=i[10],trigger="CALL_INVALID",status="OPEN",note="Nomor utama tidak aktif.",new_contact="",by="TC01",created_at=ts(1,13,31))))
act(6,i[11],"VISIT","PTP","FC01",2,10,15,met_with="DEBTOR",notes="Usaha sepi, janji bayar satu angsuran.",ptp_date=P.isoformat(),ptp_amount=A[i[11]]["installment"])
ptp(3,i[11],P,A[i[11]]["installment"],"VISIT","FC01")
act(7,i[12],"VISIT","NOTMEET","FC01",1,11,0,met_with="NEIGHBOR",notes="Rumah kosong, pesan dititip ke tetangga.")
act(8,i[14],"VISIT","MEET_NOPAY","FC01",3,15,20,met_with="DEBTOR",notes="Menunggu pencairan dana dari keluarga.")
act(9,i[16],"VISIT","PTP","FC01",5,9,45,met_with="SPOUSE",notes="Janji bayar tanggal 9.",ptp_date=(P-dt.timedelta(days=3)).isoformat(),ptp_amount=A[i[16]]["installment"])
ptp(4,i[16],P-dt.timedelta(days=3),A[i[16]]["installment"],"VISIT","FC01","BROKEN")
act(10,i[20],"VISIT","ADDR_INVALID","FC02",2,13,10,met_with="NEIGHBOR",notes="Menurut tetangga sudah pindah sejak bulan lalu.")
skips.append(("skip-seed-02",dict(contract_no=i[20],trigger="VISIT_ADDR_INVALID",status="OPEN",note="Debitur pindah, alamat baru belum diketahui.",new_contact="",by="FC02",created_at=ts(2,13,12))))
act(11,i[22],"VISIT","RMP_REQ","FC02",1,10,30,met_with="DEBTOR",notes="Penghasilan turun, minta perpanjangan tenor.")
rmps.append(("rmp-seed-01",dict(contract_no=i[22],type="TENOR_EXT",reason="Penghasilan turun sejak pindah kerja.",status="DIAJUKAN",channel="MOBILE",by="FC02",created_at=ts(1,10,32))))
act(12,i[26],"VISIT","UNCOOP","FC03",4,14,0,met_with="DEBTOR",notes="Menolak membahas pembayaran.")
act(13,i[28],"VISIT","UNIT_MOVED","FC03",6,11,40,met_with="FAMILY",notes="Unit disebut dipakai saudara di luar kota.")
A[i[28]]["unit_status"]="TRANSFERRED"
act(14,i[2],"CALL","PTP","TC01",1,15,5,contacted="DEBTOR",notes="Akan bayar tepat jatuh tempo.",ptp_date=(P+dt.timedelta(days=3)).isoformat(),ptp_amount=A[i[2]]["installment"])
ptp(5,i[2],P+dt.timedelta(days=3),A[i[2]]["installment"],"CALL","TC01")
ttrs=[]
n=48201
for fc in ("FC01","FC02","FC03"):
    for _ in range(4):
        ttrs.append(("TTR-%07d"%n,dict(status="ISSUED",issued_to=fc,issued_at=ts(0,8,40),contract_no="",amount=0,payer="",deposit_status="",used_at="",akh_date="")))
        n+=1
meta=[("config",dict(process_date=P.isoformat(),branch="Cabang Bekasi",sample=True,staff=[
    dict(id="FC01",name="Rizky Pratama",role="FC",scope="Bucket 1 (DPD 8–30) · Bekasi Timur"),
    dict(id="FC02",name="Dimas Anggoro",role="FC",scope="Bucket 2 (DPD 31–60) · Tambun Selatan"),
    dict(id="FC03",name="Yoga Firmansyah",role="FC",scope="Bucket 3+ (DPD 61+) · Bekasi"),
    dict(id="TC01",name="Sari Wulandari",role="TELE",scope="Desk call · tim A"),
    dict(id="TC02",name="Andini Maharani",role="TELE",scope="Desk call · tim B"),
    dict(id="ADM01",name="Putri Larasati",role="ADMIN",scope="Collection admin · TTR dan data")]))]
seed=dict(accounts=accs,activities=acts,ptp=ptps,ttr=ttrs,rmp=rmps,skip=skips,meta=meta)
json.dump({c:[dict(id=k,**v) for k,v in rows] for c,rows in seed.items()}, open("seed.json","w"), ensure_ascii=False)
writes=[]
for c,rows in seed.items():
    for k,v in rows:
        p="seed/%s__%s.json"%(c,k); json.dump(v,open(p,"w"),ensure_ascii=False)
        writes.append(dict(op="set",collection=c,doc_id=k,file_path=os.path.abspath(p)))
json.dump(writes,open("writes.json","w"))
print({c:len(r) for c,r in seed.items()}, len(writes), os.path.getsize("seed.json"))
