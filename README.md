# Zabsen — Zieda Absen (Sistem Informasi Kehadiran & Cuti Karyawan)

Aplikasi kehadiran karyawan (absensi wajah + GPS, jam kerja, cuti) untuk Zieda Bakery & Cakes, dibangun oleh tim IT.

## 🎯 Tentang Singkat

Zabsen terdiri dari dua bagian:

1. **Mobile App (Flutter)** — folder `lib/`: karyawan mencatat absensi dan mengajukan cuti.
2. **Web App (HTML/JS)** — folder `web-references-zabsen/`: dashboard admin/HRD (absensi, laporan, gaji).

## ✨ Fitur Utama

- Absensi wajah & GPS (Geotagging) dengan validasi waktu global (anti *time-spoofing*).
- Dashboard HR/Admin monitoring kehadiran & jam kerja.
- Form cuti dinamis (drag & drop) untuk pengajuan cuti/izin/sakit.
- Hak akses berbasis peran (Karyawan / HRD / Super Admin).
- Export absensi ke Excel, Cetak Form Gaji Mingguan, notifikasi Telegram.

## 🛠️ Tech Stack

- **Mobile:** Flutter (Dart) + `supabase_flutter`, `flutter_map`, `geolocator`, `video_player`, `shared_preferences`.
- **Web:** HTML5, CSS3, Vanilla JS, Bootstrap 5, FontAwesome, SweetAlert2, Supabase, FaceAPI.js, Leaflet.js, JSZip.
- **Backend & Database:** Supabase (PostgreSQL + Auth + Storage) — arsitektur Serverless / BaaS.

## 📁 Struktur Singkat

```
zabsen/
├── lib/                    # Aplikasi Flutter utama
├── web/                    # Konfigurasi build web Flutter
├── web-references-zabsen/ # Web dashboard + semua referensi teknis & dokumen
└── test/
```

## 🤖 Untuk AI Agent: Referensi Teknis

Saat diminta **contoh koneksi database, konfigurasi Supabase, skema SQL, atau integrasi fitur**, AI agent **wajib** merujuk ke folder
[`web-references-zabsen/`](./web-references-zabsen/) sebagai **source of truth**:

| Butuh | File |
|---|---|
| Koneksi database Supabase / `config.js` / env | `web-references-zabsen/config.js`, `web-references-zabsen/.env.example` |
| Skema database, RLS, RPC, seed | `web-references-zabsen/db/01_starter_schema.sql`, `web-references-zabsen/supabase/migrations/` |
| Arsitektur, instalasi, security, backup, Telegram | `web-references-zabsen/DOKUMENTASI_IT.md` |
| Spesifikasi kebutuhan fitur (gaji, export Excel, dsb.) | `web-references-zabsen/PRD_*.md` |
| Implementasi koneksi DB di sisi Flutter | `lib/main.dart` (`Supabase.initialize`) |

Jika ada informasi yang bertentangan antar file, prioritaskan isi folder `web-references-zabsen/` dan laporkan ke developer.

## 📚 Dokumentasi Terkait

- [web-references-zabsen/README.md](./web-references-zabsen/README.md)
- [web-references-zabsen/DOKUMENTASI_IT.md](./web-references-zabsen/DOKUMENTASI_IT.md)

## 🚀 Getting Started (Mobile)

```bash
flutter pub get
flutter run
```

Sebelum menjalankan, pastikan referensi teknis (koneksi Supabase, skema database) sudah sesuai — lihat bagian [🤖 Untuk AI Agent](#-untuk-ai-agent-referensi-teknis) di atas.
