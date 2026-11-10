# AGENTS.md — Instruksi untuk AI Agent (OpenCode / Coding Agent)

Project ini: **Zabsen — Zieda Absen** (Sistem Informasi Kehadiran & Cuti Karyawan).

## Tentang Proyek

- **Mobile App:** Flutter (Dart) — kode utama di folder `lib/` (login, splash, absen, dashboard).
- **Web App:** HTML5/CSS3/Vanilla JS di folder `web-references-zabsen/` (dashboard admin/HRD).
- **Backend & Database:** Supabase (PostgreSQL + Auth + Storage) — arsitektur Serverless/BaaS.

## Sumber Referensi Teknis (WAJIB DIKUNCI)

Apabila permintaan melibatkan hal berikut, AI agent **wajib** merujuk ke folder
**`web-references-zabsen/`** sebagai source of truth sebelum menulis kode atau menjawab:

| Topik | File / Lokasi |
|---|---|
| Koneksi database / Supabase (`config.js`, `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `DATABASE_CONFIGS`, `ACTIVE_ENVIRONMENT`) | `web-references-zabsen/config.js`, `web-references-zabsen/.env.example` |
| Schema database, RLS, RPC functions, seed data | `web-references-zabsen/db/01_starter_schema.sql`, `web-references-zabsen/supabase/migrations/` |
| Arsitektur sistem, instalasi baru, security, Telegram, backup/factory reset | `web-references-zabsen/DOKUMENTASI_IT.md` |
| Spesifikasi kebutuhan fitur (gaji, export Excel absen, dsb.) | `web-references-zabsen/PRD_*.md` |
| Contoh integrasi di sisi Flutter (`Supabase.initialize`) | `lib/main.dart` |

Contoh kebutuhan yang termasuk "referensi teknis":

- Contoh / cara koneksi ke database Supabase.
- Contoh konfigurasi environment variable.
- Contoh skema / query SQL / RPC.
- Contoh integrasi fitur baru (absen, cuti, gaji, export).

Jika data di `web-references-zabsen/` dan kode di `lib/` saling bertentangan, prioritaskan isi folder
`web-references-zabsen/` dan laporkan ketidaksesuaian tersebut ke developer.

## Catatan Penting

- Jangan menyimpan/menambahkan API key baru secara hardcoded tanpa melewati alur konfigurasi yang sudah ada.
- Gunakan Supabase client yang sudah tersedia (`supabase_flutter` di Flutter, `@supabase/supabase-js` di web).
- Untuk perubahan skema database, wajib membuat/mengikuti file migrasi di `web-references-zabsen/supabase/migrations/`.

## Referensi Tambahan

Lihat [`README.md`](./README.md) dan [`web-references-zabsen/README.md`](./web-references-zabsen/README.md).
