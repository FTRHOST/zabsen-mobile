/// Konfigurasi umum aplikasi Zieda Absen.
///
/// URL dashboard admin web (`web-references-zabsen/admin.html`).
/// Isi dengan alamat deploy web Zieda Absen, TANPA garis miring di akhir.
///
/// Contoh:
/// ```dart
/// const String kAdminPanelUrl = 'https://zabsen.contoh.com';
/// ```
///
/// Jika dibiarkan kosong, tombol "Admin" akan menampilkan dialog informasi
/// bahwa panel admin web belum dikonfigurasi.
const String kAdminPanelUrl = '';

/// Path halaman admin pada web dashboard.
const String kAdminPanelPath = '/admin.html';
