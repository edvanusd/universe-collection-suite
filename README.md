# Universe Collection Suite

Prototipe Collection System dari PRD Collection System, dibuat untuk Universe Solusi Digital. Satu halaman web berisi dua aplikasi yang memakai data yang sama:

- **Front Coll** — aplikasi field collector (tampilan ponsel): AKH harian, check-in dengan GPS dummy, hasil kunjungan, pembayaran dengan TTR, janji bayar, pengajuan RMP, docking.
- **Desk Call** — aplikasi telecollector dan admin (tampilan desktop): dashboard, worklist call, janji bayar, skip tracing, surat peringatan, aktivitas lapangan dan RMP, data account, penugasan, stok TTR, petugas.

## Menjalankan

Halaman memuat `seed.json` lewat `fetch`, jadi harus dibuka lewat server HTTP, bukan `file://`.

```bash
python3 -m http.server 8080
# buka http://localhost:8080
```

Akun contoh: `FC01`, `FC02`, `FC03` (Front Coll) dan `TC01`, `TC02`, `ADM01` (Desk Call). Kata sandi semuanya `demo123`.

## Isi repo

| Berkas | Isi |
| --- | --- |
| `index.html` | Seluruh aplikasi: HTML, CSS, dan JavaScript tanpa build step |
| `seed.json` | Data contoh (30 account fiktif, aktivitas, janji bayar, TTR, petugas) |
| `logo.png` | Logo Universe Solusi Digital |
| `tools/gen_seed.py` | Skrip pembuat `seed.json` |

Three.js r128 dan font dimuat dari CDN.

## Batasan prototipe

- Dijalankan dari repo ini, data hanya ada di memori browser dan hilang saat halaman dimuat ulang. Versi yang terbit sebagai artifact Claude menyimpan data di penyimpanan bersama artifact itu.
- Login hanya gerbang demo dengan satu kata sandi; belum ada autentikasi server.
- GPS adalah koordinat tiruan di sekitar alamat debitur. Kamera dan sambungan telepon tidak aktif.
- Penarikan unit (BAST/AYDA), modul recovery, dan agency belum dibuat.
- Semua nama, nomor telepon, dan nomor kontrak adalah data contoh.
