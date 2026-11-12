# Universe Collection Suite

Prototipe Collection System dari PRD Collection System, dibuat untuk Universe Solusi Digital. Satu halaman web berisi dua aplikasi yang memakai data yang sama:

- **Front Coll**: aplikasi field collector (tampilan ponsel). Isinya AKH harian, check-in dengan GPS dummy, hasil kunjungan, pembayaran dengan TTR, janji bayar, pengajuan RMP, dan docking.
- **Desk Call**: aplikasi telecollector dan admin (tampilan desktop). Isinya dashboard, worklist call, janji bayar, skip tracing, surat peringatan, aktivitas lapangan dan RMP. Admin juga mengelola data account, penugasan, stok TTR, petugas, dan batch harian.

Situs: https://edvanusd.github.io/universe-collection-suite/

## Dua mode

| Mode | Kapan | Data |
| --- | --- | --- |
| **Supabase** | `config.js` berisi Project URL dan anon key | Tersimpan di database, login lewat Supabase Auth, perubahan langsung terlihat di semua perangkat |
| **Demo** | `config.js` kosong | Data contoh dari `seed.json`, hanya di browser, hilang saat dimuat ulang |

## Memasang backend Supabase

1. Buka project Supabase → **SQL Editor** → tempel isi `supabase/setup.sql` → **Run**. File ini membuat tabel, aturan akses, fungsi server, dan data contoh. Aman dijalankan ulang.
2. Buka **Project Settings → API**, salin **Project URL** dan **anon public key** ke `config.js`.
3. Push ke `main` dan `gh-pages`.

Akun contoh: `FC01`, `FC02`, `FC03` (Front Coll) dan `TC01`, `TC02`, `ADM01` (Desk Call), kata sandi `demo123`. Ganti kata sandi lewat menu **Petugas** (login sebagai `ADM01`) sebelum dipakai di luar uji coba.

Batch harian (hitung ulang DPD dan bucket) bisa dijalankan admin dari menu **Data account**, atau dijadwalkan otomatis dengan pg_cron. Perintahnya ada di bagian bawah `supabase/schema.sql`.

### Cara kerja backend

- Semua tabel berawalan `ucs_`, jadi tidak bentrok dengan tabel lain di project yang sama.
- **Membaca**: hanya petugas aktif yang sudah login (Row Level Security). Pengguna anonim tidak bisa membaca apa pun.
- **Menulis**: hanya lewat fungsi server `ucs_*`. Fungsi memeriksa peran, memvalidasi input, lalu menulis beberapa tabel dalam satu transaksi. Contohnya, satu kunjungan berstatus bayar sekaligus mencatat aktivitas, memakai TTR, menutup janji bayar, dan memperbarui account.
- **Hak per peran**:
  - Field collector: kunjungan, setoran, kontak baru, pengajuan RMP.
  - Telecollector: call, janji bayar, skip tracing, surat peringatan.
  - Admin: semua di atas, ditambah keputusan RMP, data account, penugasan, TTR, petugas, dan batch harian.
- **Realtime**: aplikasi yang sedang terbuka memuat ulang data saat ada perubahan.

| Berkas | Isi |
| --- | --- |
| `supabase/schema.sql` | Tabel, RLS, fungsi server, realtime |
| `supabase/seed.sql` | Data contoh dan akun login petugas |
| `supabase/setup.sql` | `schema.sql` + `seed.sql` dalam satu file |
| `supabase/teardown.sql` | Menghapus semua objek `ucs_` dan akun petugasnya |
| `supabase/test/` | Uji backend di Postgres lokal (64 pemeriksaan) dan server tiruan Supabase untuk uji frontend |

Membuat ulang seed setelah `seed.json` berubah: `python3 tools/gen_seed.py && python3 tools/make_seed_sql.py`.

## Menjalankan lokal

```bash
python3 -m http.server 8080
# buka http://localhost:8080
```

## Batasan prototipe

- GPS adalah koordinat tiruan di sekitar alamat debitur. Kamera dan sambungan telepon belum aktif.
- Pembayaran lapangan belum diposting ke core system; batch harian menghitung DPD dari tanggal jatuh tempo yang tersimpan.
- Satu browser memakai satu sesi login: masuk ke aplikasi lain akan mengakhiri sesi yang sedang aktif.
- Penarikan unit (BAST/AYDA), modul recovery, dan agency belum dibuat.
- Semua nama, nomor telepon, dan nomor kontrak adalah data contoh.
