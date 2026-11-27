import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_config.dart';
import 'auth_session.dart';
import 'face_capture_dialog.dart';
import 'izin_page.dart';
import 'kalender_page.dart';
import 'profile_page.dart';
import 'session_actions.dart';

class AbsenPage extends StatefulWidget {
  const AbsenPage({super.key});

  @override
  State<AbsenPage> createState() => _AbsenPageState();
}

class _AbsenPageState extends State<AbsenPage> {
  static const String _absensiBucket = 'absensi-bucket';

  int _currentNavIndex = 0;
  late Timer _timer;
  DateTime _currentTime = DateTime.now();

  // Data User
  int? _userId;
  String _userName = 'Pengguna';
  String _userCabang = 'Pusat';
  String _userRole = 'Karyawan';

  /// Descriptor wajah (128 dimensi, JSON string) dari kolom
  /// `users.face_descriptor`. Wajib ada sebelum absen wajah.
  String? _faceDescriptor;
  bool _isFaceDialogOpen = false;

  // Key untuk memuat ulang halaman profil saat tab Profil dibuka
  final GlobalKey<ProfilePageState> _profileKey = GlobalKey<ProfilePageState>();

  // Key untuk memuat ulang data cuti saat tab Izin dibuka
  final GlobalKey<IzinPageState> _izinKey = GlobalKey<IzinPageState>();

  // Key untuk memuat ulang data kalender saat tab Kalender dibuka
  final GlobalKey<KalenderPageState> _kalenderKey =
      GlobalKey<KalenderPageState>();

  // Data Lokasi Kantor & Peta (Sinkron dengan Supabase)
  final MapController _mapController = MapController();
  double _latKantor = -6.200000;
  double _lonKantor = 106.816666;
  int _radiusMaksimal = 100;
  String _namaKantor = 'Kantor Pusat';
  List<Map<String, dynamic>> _listKantor = [];

  // Data Lokasi User
  Position? _userPosition;
  int _distanceToOffice = 0;
  bool _isInsideRadius = false;
  bool _isLoadingLocation = false;
  bool _isLoadingKantor = true;

  // Data Riwayat Absen Hari Ini
  List<Map<String, dynamic>> _riwayatHariIni = [];
  bool _isLoadingRiwayat = false;

  @override
  void initState() {
    super.initState();
    _loadUserAndKantor();

    // Jam terus berjalan otomatis tiap detik
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _currentTime = DateTime.now();
        });
      }
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  double _toDouble(dynamic val, [double fallback = 0.0]) {
    if (val == null) return fallback;
    if (val is num) return val.toDouble();
    if (val is String) {
      return double.tryParse(val.trim()) ?? fallback;
    }
    return fallback;
  }

  int _toInt(dynamic val, [int fallback = 100]) {
    if (val == null) return fallback;
    if (val is num) return val.toInt();
    if (val is String) {
      return int.tryParse(val.trim()) ??
          double.tryParse(val.trim())?.toInt() ??
          fallback;
    }
    return fallback;
  }

  /// Menampilkan tombol Admin hanya untuk role HR / Super Admin
  /// (sama seperti web referensi).
  bool get _isAdmin {
    final role = _userRole.trim().toLowerCase();
    return role == 'hr' || role == 'super admin';
  }

  /// Menyinkronkan data pengguna dari halaman Profil ke header AbsenPage.
  void _applyUserUpdate(Map<String, dynamic> user) {
    if (!mounted) return;

    setState(() {
      if (user['id'] != null) _userId = _toInt(user['id'], 0);
      if (user['nama'] != null) _userName = user['nama'];
      if (user['cabang'] != null) _userCabang = user['cabang'];
      if (user['role'] != null) _userRole = user['role'];
      if (user['face_descriptor'] != null) {
        _faceDescriptor = user['face_descriptor'].toString();
      }
    });
  }

  /// Membuka panel admin web (web-references-zabsen/admin.html).
  Future<void> _openAdminPanel() async {
    final baseUrl = kAdminPanelUrl.trim();

    if (baseUrl.isEmpty) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: const Row(
            children: [
              Icon(
                Icons.admin_panel_settings_outlined,
                color: Color(0xFF4A1010),
              ),
              SizedBox(width: 8),
              Text('Panel Admin', style: TextStyle(fontSize: 18)),
            ],
          ),
          content: const Text(
            'URL panel admin web belum dikonfigurasi.\n\n'
            'Isi konstanta kAdminPanelUrl pada lib/app_config.dart dengan '
            'alamat web dashboard Zieda Absen.',
            style: TextStyle(fontSize: 14),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text(
                'OK',
                style: TextStyle(color: Color(0xFF4A1010)),
              ),
            ),
          ],
        ),
      );
      return;
    }

    final normalizedBase = baseUrl.replaceAll(RegExp(r'/+$'), '');
    final Uri adminUri = Uri.parse('$normalizedBase$kAdminPanelPath');

    try {
      final bool opened = await launchUrl(
        adminUri,
        mode: LaunchMode.externalApplication,
      );
      if (!opened && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Tidak dapat membuka panel admin web')),
        );
      }
    } catch (e) {
      debugPrint('Gagal membuka panel admin: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Tidak dapat membuka panel admin web')),
        );
      }
    }
  }

  /// Tombol pil pada header (gaya web referensi).
  Widget _buildHeaderAction({
    required String label,
    required VoidCallback onTap,
  }) {
    return Material(
      color: const Color(0xFF4A1010),
      borderRadius: BorderRadius.circular(40),
      child: InkWell(
        borderRadius: BorderRadius.circular(40),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }

  /// Header global aplikasi (tampil di semua tab, seperti web referensi).
  /// Foto profil lama diganti tombol Admin (khusus HR/Super Admin) & Logout.
  Widget _buildAppHeader() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'ZIEDA ABSEN',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF4A1010),
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        'Selamat Datang, $_userName',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1E1E1E),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Text('👋', style: TextStyle(fontSize: 14)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_isAdmin) ...[
                _buildHeaderAction(label: 'Admin', onTap: _openAdminPanel),
                const SizedBox(width: 8),
              ],
              _buildHeaderAction(
                label: 'Logout',
                onTap: () => logoutToLogin(context),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _loadUserAndKantor() async {
    // 1. Ambil data user dari sesi SharedPreferences
    try {
      final prefs = await SharedPreferences.getInstance();
      final userStr = prefs.getString('userLogin');
      if (userStr != null) {
        final userData = jsonDecode(userStr);
        if (mounted) {
          setState(() {
            if (userData['id'] != null) _userId = _toInt(userData['id'], 0);
            if (userData['nama'] != null) _userName = userData['nama'];
            if (userData['cabang'] != null) _userCabang = userData['cabang'];
            if (userData['role'] != null) _userRole = userData['role'];
            if (userData['face_descriptor'] != null) {
              _faceDescriptor = userData['face_descriptor'].toString();
            }
          });
          await _loadFaceProfile();
          _loadRiwayatHariIni();
        }
      }
    } catch (_) {}

    // 2. Ambil data kantor dari Supabase API
    try {
      final supabase = Supabase.instance.client;
      final List<dynamic> dataKantor = await supabase
          .from('kantor')
          .select('*');

      if (dataKantor.isNotEmpty && mounted) {
        _listKantor = dataKantor
            .map((e) => Map<String, dynamic>.from(e))
            .toList();

        // Cari kantor cabang yang ditugaskan ke user
        final assigned = _listKantor.firstWhere(
          (k) => k['nama'] == _userCabang,
          orElse: () => _listKantor.first,
        );

        setState(() {
          _latKantor = _toDouble(assigned['lat'], -6.200000);
          _lonKantor = _toDouble(assigned['lng'], 106.816666);
          _radiusMaksimal = _toInt(assigned['radius'], 100);
          _namaKantor = assigned['nama']?.toString() ?? 'Kantor Pusat';
          _isLoadingKantor = false;
        });

        _mapController.move(LatLng(_latKantor, _lonKantor), 16.5);
      } else if (mounted) {
        setState(() {
          _isLoadingKantor = false;
        });
      }
    } catch (e) {
      debugPrint('Gagal memuat kantor dari Supabase: $e');
      if (mounted) {
        setState(() {
          _isLoadingKantor = false;
        });
      }
    }

    // 3. Deteksi lokasi GPS user terkini
    _getCurrentLocation();
  }

  /// Memuat daftar absensi hari ini untuk user dari tabel absensi Supabase
  Future<void> _loadRiwayatHariIni() async {
    if (_userId == null) return;
    setState(() => _isLoadingRiwayat = true);

    try {
      final now = DateTime.now();
      final todayStr =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

      final List<dynamic> rows = await Supabase.instance.client
          .from('absensi')
          .select('*')
          .eq('user_id', _userId!)
          .eq('tanggal', todayStr)
          .order('waktu', ascending: true);

      if (mounted) {
        setState(() {
          _riwayatHariIni = rows
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
          _isLoadingRiwayat = false;
        });
      }
    } catch (e) {
      debugPrint('Error load riwayat hari ini: $e');
      if (mounted) {
        setState(() => _isLoadingRiwayat = false);
      }
    }
  }

  /// Memuat descriptor wajah terbaru dari tabel `users`.
  ///
  /// Data ini dipakai untuk membandingkan wajah saat absen (face recognition),
  /// sama seperti `face_descriptor` pada web referensi.
  Future<void> _loadFaceProfile() async {
    if (_userId == null) return;

    try {
      final row = await Supabase.instance.client
          .from('users')
          .select('face_descriptor')
          .eq('id', _userId!)
          .maybeSingle();

      if (row != null && mounted) {
        final descriptor = row['face_descriptor']?.toString();
        if (descriptor != null && descriptor.isNotEmpty) {
          setState(() => _faceDescriptor = descriptor);
        }
      }
    } catch (e) {
      debugPrint('Gagal memuat face_descriptor: $e');
    }
  }

  /// Mendeteksi posisi GPS pengguna & menghitung jarak ke radius kantor
  Future<void> _getCurrentLocation() async {
    if (_isLoadingLocation) return;
    setState(() {
      _isLoadingLocation = true;
    });

    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('GPS tidak aktif. Mohon aktifkan lokasi di HP.'),
            ),
          );
        }
        setState(() => _isLoadingLocation = false);
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          setState(() => _isLoadingLocation = false);
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        setState(() => _isLoadingLocation = false);
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      final distance = Geolocator.distanceBetween(
        _latKantor,
        _lonKantor,
        position.latitude,
        position.longitude,
      );

      if (mounted) {
        setState(() {
          _userPosition = position;
          _distanceToOffice = distance.round();
          _isInsideRadius = distance <= _radiusMaksimal;
          _isLoadingLocation = false;
        });

        _mapController.move(
          LatLng(position.latitude, position.longitude),
          16.5,
        );
      }
    } catch (e) {
      debugPrint('Error mendeteksi lokasi GPS: $e');
      if (mounted) {
        setState(() => _isLoadingLocation = false);
      }
    }
  }

  String _formatDigit(int n) => n.toString().padLeft(2, '0');

  String _formatTanggal(DateTime date) {
    const hari = [
      'Senin',
      'Selasa',
      'Rabu',
      'Kamis',
      'Jumat',
      'Sabtu',
      'Minggu',
    ];
    const bulan = [
      'Januari',
      'Februari',
      'Maret',
      'April',
      'Mei',
      'Juni',
      'Juli',
      'Agustus',
      'September',
      'Oktober',
      'November',
      'Desember',
    ];
    return '${hari[date.weekday - 1]}, ${date.day} ${bulan[date.month - 1]} ${date.year}';
  }

  /// Menyimpan rekaman absensi ke tabel absensi di Supabase.
  ///
  /// Bila [faceResult] tersedia, foto selfie diunggah ke bucket
  /// `absensi-bucket` dan status hasil pencocokan wajah (`status_wajah`)
  /// ikut disimpan, sama seperti alur absen wajah pada web referensi.
  Future<void> _simpanAbsensi(
    String tipe, {
    FaceCaptureResult? faceResult,
  }) async {
    if (_userId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sesi pengguna tidak valid, silakan login ulang.'),
        ),
      );
      return;
    }

    // Pastikan sesi Supabase Auth masih aktif sebelum menulis ke database.
    if (Supabase.instance.client.auth.currentSession == null) {
      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: const Text('Sesi Login Berakhir'),
          content: const Text(
            'Sesi keamanan Anda sudah berakhir. Silakan login kembali untuk '
            'melanjutkan absensi.',
            style: TextStyle(fontSize: 14),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                logoutToLogin(context, askConfirmation: false);
              },
              child: const Text(
                'Login Ulang',
                style: TextStyle(color: Color(0xFF4A1010)),
              ),
            ),
          ],
        ),
      );
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: CircularProgressIndicator(color: Color(0xFF4A1010)),
      ),
    );

    try {
      final supabase = Supabase.instance.client;
      final now = DateTime.now();
      final todayStr =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final timeStr =
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';

      // 1. Unggah foto selfie ke bucket `absensi-bucket` (wajib agar absen
      //    wajah benar-benar tercatat beserta buktinya).
      String? fotoUrl;
      if (faceResult != null) {
        final bytes = base64Decode(faceResult.photoBase64);
        final fileName =
            'selfie-${_userId}_${DateTime.now().millisecondsSinceEpoch}.jpg';

        await supabase.storage
            .from(_absensiBucket)
            .uploadBinary(
              fileName,
              bytes,
              fileOptions: const FileOptions(contentType: 'image/jpeg'),
            );

        fotoUrl = supabase.storage.from(_absensiBucket).getPublicUrl(fileName);
      }

      // 2. Simpan transaksi absensi beserta foto & status wajah.
      await supabase.from('absensi').insert([
        {
          'user_id': _userId,
          'tanggal': todayStr,
          'waktu': timeStr,
          'tipe_absen': tipe,
          'lokasi': 'Jarak: $_distanceToOffice m dari $_namaKantor',
          'status': 'Hadir',
          'keterangan_waktu': 'Tepat Waktu',
          'foto': ?fotoUrl,
          if (faceResult != null) 'status_wajah': faceResult.statusWajah,
        },
      ]);

      if (mounted) {
        Navigator.of(context).pop(); // Tutup loading dialog
        final statusWajah = faceResult?.statusWajah;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              statusWajah == null
                  ? 'Presensi $tipe berhasil dicatat!'
                  : 'Presensi $tipe berhasil. Status wajah: $statusWajah',
            ),
            backgroundColor: const Color(0xFF2E7D32),
          ),
        );
        _loadRiwayatHariIni();
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop(); // Tutup loading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Gagal mencatat absen: $e'),
            backgroundColor: Colors.red.shade800,
          ),
        );
      }
    }
  }

  /// Membuka popup absen wajah (kamera + face-api.js).
  ///
  /// Jika pengguna belum punya `face_descriptor`, tampilkan pendaftaran wajah
  /// terlebih dahulu — sama seperti validasi pada `lanjutKeKameraAtauSubmit()`
  /// di web referensi.
  Future<void> _startFaceAbsen(String tipe) async {
    if (_isFaceDialogOpen) return;
    _isFaceDialogOpen = true;

    try {
      if (_faceDescriptor == null || _faceDescriptor!.isEmpty) {
        final shouldRegister = await _showFaceRegistrationPrompt();
        if (shouldRegister != true) return;

        if (!mounted) return;
        final registered = await _registerFace();
        if (!registered) return;
      }

      if (!mounted) return;

      final result = await showFaceCaptureDialog(
        context,
        mode: FaceCaptureMode.absen,
        tipeAbsen: tipe,
        registeredDescriptor: _faceDescriptor,
      );

      if (result == null || !mounted) return;
      await _simpanAbsensi(tipe, faceResult: result);
    } finally {
      _isFaceDialogOpen = false;
    }
  }

  Future<bool?> _showFaceRegistrationPrompt() {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.face_retouching_natural, color: Color(0xFF4A1010)),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Wajah Wajib Terdaftar!',
                style: TextStyle(fontSize: 18),
              ),
            ),
          ],
        ),
        content: const Text(
          'Anda belum mendaftarkan data wajah (Face Recognition). '
          'Pendaftaran wajah wajib dilakukan terlebih dahulu sebelum '
          'melakukan absensi.',
          style: TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Nanti'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF500808),
              foregroundColor: Colors.white,
            ),
            child: const Text('Daftar Wajah Sekarang'),
          ),
        ],
      ),
    );
  }

  /// Mendaftarkan wajah pengguna ke kolom `users.face_descriptor` dan
  /// `users.foto_wajah` (format data URL, sama dengan web referensi).
  Future<bool> _registerFace() async {
    if (_userId == null) return false;

    final result = await showFaceCaptureDialog(
      context,
      mode: FaceCaptureMode.register,
      tipeAbsen: 'Pendaftaran Wajah',
    );

    if (result == null || result.descriptorJson == null) return false;

    try {
      final supabase = Supabase.instance.client;
      await supabase
          .from('users')
          .update({
            'face_descriptor': result.descriptorJson,
            'foto_wajah': result.photoDataUrl,
          })
          .eq('id', _userId!);

      if (mounted) {
        setState(() => _faceDescriptor = result.descriptorJson);
      }

      // Perbarui cache sesi agar descriptor langsung tersedia pada absen
      // berikutnya tanpa harus menunggu query ulang.
      try {
        final fresh = await supabase
            .from('users')
            .select('*')
            .eq('id', _userId!)
            .maybeSingle();
        if (fresh != null) {
          await AuthSession.saveUser(Map<String, dynamic>.from(fresh));
        }
      } catch (e) {
        debugPrint('Gagal memperbarui cache user setelah daftar wajah: $e');
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Wajah berhasil didaftarkan!'),
            backgroundColor: Color(0xFF2E7D32),
          ),
        );
      }
      return true;
    } catch (e) {
      debugPrint('Gagal menyimpan data wajah: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Gagal menyimpan data wajah: $e'),
            backgroundColor: Colors.red.shade800,
          ),
        );
      }
      return false;
    }
  }

  void _handleAbsenClick() {
    if (_isLoadingLocation) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sedang mendeteksi koordinat GPS...')),
      );
      return;
    }

    if (_userPosition == null) {
      _getCurrentLocation();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Meminta izin & mendeteksi sinyal GPS...'),
        ),
      );
      return;
    }

    if (_isInsideRadius) {
      _showPilihTipeAbsenSheet();
    } else {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: const [
              Icon(Icons.error_outline_rounded, color: Colors.red),
              SizedBox(width: 8),
              Text('Di Luar Jangkauan', style: TextStyle(fontSize: 18)),
            ],
          ),
          content: Text(
            'Anda berada di luar radius $_namaKantor!\nJarak Anda saat ini: $_distanceToOffice meter (Maksimal: $_radiusMaksimal meter).',
            style: const TextStyle(fontSize: 14),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text(
                'Tutup',
                style: TextStyle(color: Color(0xFF4A1010)),
              ),
            ),
          ],
        ),
      );
    }
  }

  /// Memeriksa apakah absen hari ini sudah masuk (Masuk/Izin Masuk/Istirahat
  /// Masuk) — sama logika `sudahMasuk` pada web referensi.
  bool get _sudahMasukAbsenHariIni {
    return _riwayatHariIni.any((a) {
      final tipe = a['tipe_absen']?.toString().toLowerCase() ?? '';
      return (tipe.contains('masuk') || tipe == 'masuk') &&
          !tipe.contains('izin masuk') &&
          !tipe.contains('istirahat masuk');
    });
  }

  /// Memeriksa apakah absen hari ini sudah pulang (Pulang/Checkout).
  bool get _sudahPulangAbsenHariIni {
    return _riwayatHariIni.any((a) {
      final tipe = a['tipe_absen']?.toString().toLowerCase() ?? '';
      return tipe.contains('pulang') || tipe.contains('checkout');
    });
  }

  /// Sedang dalam masa istirahat? (Keluar > Masuk).
  bool get _sedangIstirahat {
    final tipeHariIni = _riwayatHariIni
        .map((a) => a['tipe_absen']?.toString().toLowerCase() ?? '')
        .toList();
    final countIstirahatKeluar = tipeHariIni
        .where((t) => t.contains('istirahat keluar'))
        .length;
    final countIstirahatMasuk = tipeHariIni
        .where((t) => t.contains('istirahat masuk'))
        .length;
    return countIstirahatKeluar > countIstirahatMasuk;
  }

  /// Sedang dalam masa izin keluar? (Keluar > Masuk).
  bool get _sedangIzin {
    final tipeHariIni = _riwayatHariIni
        .map((a) => a['tipe_absen']?.toString().toLowerCase() ?? '')
        .toList();
    final countIzinKeluar = tipeHariIni
        .where((t) => t.contains('izin keluar'))
        .length;
    final countIzinMasuk = tipeHariIni
        .where((t) => t.contains('izin masuk'))
        .length;
    return countIzinKeluar > countIzinMasuk;
  }

  /// Menentukan shift pulang mana yang sesuai dengan shift masuk hari ini.
  String _getTipePulangAktif() {
    final tipeHariIni = _riwayatHariIni
        .map((a) => a['tipe_absen']?.toString().toLowerCase() ?? '')
        .toList();

    final hasMasukPagi = tipeHariIni.any(
      (t) => t.contains('masuk pagi') || t.contains('pagi'),
    );
    final hasMasukSiang = tipeHariIni.any(
      (t) => t.contains('masuk siang') || t.contains('siang'),
    );
    final hasMasukMalam = tipeHariIni.any(
      (t) => t.contains('masuk malam') || t.contains('malam'),
    );

    if (hasMasukPagi && !hasMasukSiang && !hasMasukMalam) {
      return 'Absen Pulang Pagi';
    }
    if (hasMasukSiang && !hasMasukPagi && !hasMasukMalam) {
      return 'Absen Pulang Siang';
    }
    if (hasMasukMalam && !hasMasukPagi && !hasMasukSiang) {
      return 'Absen Pulang Malam';
    }
    return 'Absen Pulang / Checkout';
  }

  /// Bottom Sheet pemilihan jenis absensi
  void _showPilihTipeAbsenSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      backgroundColor: Colors.white,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 24.0,
              vertical: 20.0,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 44,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Pilih Kategori Absen',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1E1E1E),
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),

                if (_sudahPulangAbsenHariIni) ...[
                  const SizedBox(height: 8),
                  _buildTipeAbsenTile(
                    icon: Icons.check_circle_rounded,
                    color: Colors.green,
                    title: 'Absensi Selesai',
                    subtitle: 'Absen masuk dan pulang hari ini sudah tercatat.',
                    onTap: () {},
                  ),
                ] else if (!_sudahMasukAbsenHariIni) ...[
                  // Logika sesuai web: sebelum absen masuk, hanya absen masuk
                  // yang boleh dilakukan.
                  _buildTipeAbsenTile(
                    icon: Icons.login_rounded,
                    color: Colors.green,
                    title: 'Absen Masuk',
                    subtitle: 'Wajib absen masuk sebelum absen lainnya',
                    onTap: () {
                      Navigator.of(ctx).pop();
                      _startFaceAbsen('Absen Masuk');
                    },
                  ),
                ] else ...[
                  _buildTipeAbsenTile(
                    icon: Icons.login_rounded,
                    color: Colors.green,
                    title: 'Absen Masuk',
                    subtitle: 'Selesai',
                    enabled: false,
                    onTap: () {},
                  ),
                  if (!_sedangIstirahat)
                    _buildTipeAbsenTile(
                      icon: Icons.coffee_rounded,
                      color: Colors.amber.shade700,
                      title: _sedangIstirahat
                          ? 'Istirahat Masuk (Kembali)'
                          : 'Istirahat',
                      subtitle: 'Mulai atau kembali dari istirahat',
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _startFaceAbsen(
                          _sedangIstirahat ? 'Istirahat Masuk' : 'Istirahat',
                        );
                      },
                    ),
                  if (!_sedangIstirahat && !_sedangIzin)
                    _buildTipeAbsenTile(
                      icon: Icons.directions_walk_rounded,
                      color: Colors.blue.shade700,
                      title: _sedangIzin
                          ? 'Izin Masuk (Kembali)'
                          : 'Izin Keluar',
                      subtitle: 'Keperluan dinas atau izin sementara',
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _startFaceAbsen(
                          _sedangIzin ? 'Izin Masuk' : 'Izin Keluar',
                        );
                      },
                    ),
                  if (!_sedangIstirahat && !_sedangIzin)
                    _buildTipeAbsenTile(
                      icon: Icons.logout_rounded,
                      color: Colors.red.shade700,
                      title: 'Absen Pulang / Checkout',
                      subtitle: 'Selesaikan jam kerja hari ini',
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _startFaceAbsen(_getTipePulangAktif());
                      },
                    ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTipeAbsenTile({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: enabled ? color.withValues(alpha: 0.08) : Colors.grey.shade200,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: enabled
                ? color.withValues(alpha: 0.3)
                : Colors.grey.shade400,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              child: Icon(icon, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1E1E1E),
                    ),
                  ),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF6E6E6E),
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.arrow_forward_ios_rounded,
              size: 14,
              color: Color(0xFF9E9E9E),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final String jamMenit =
        '${_formatDigit(_currentTime.hour)}:${_formatDigit(_currentTime.minute)}';
    final String tanggalFormatted = _formatTanggal(_currentTime);

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            _buildAppHeader(),
            Expanded(
              child: IndexedStack(
                index: _currentNavIndex,
                children: [
                  RefreshIndicator(
                    onRefresh: () async {
                      await _loadUserAndKantor();
                      await _loadRiwayatHariIni();
                    },
                    color: const Color(0xFF4A1010),
                    child: SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(24.0, 0.0, 24.0, 16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          // ==========================================
                          // 1. KARTU JAM & TANGGAL
                          // ==========================================
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              vertical: 22.0,
                              horizontal: 16.0,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(28),
                              border: Border.all(
                                color: const Color(0xFFE8E8E8),
                                width: 1.5,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.05),
                                  blurRadius: 16,
                                  offset: const Offset(0, 6),
                                ),
                              ],
                            ),
                            child: Column(
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.baseline,
                                  textBaseline: TextBaseline.alphabetic,
                                  children: [
                                    Text(
                                      jamMenit,
                                      style: const TextStyle(
                                        fontSize: 46,
                                        fontWeight: FontWeight.w900,
                                        color: Color(0xFF230505),
                                        letterSpacing: -1,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    const Text(
                                      'WIB',
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w700,
                                        color: Color(0xFF4A1010),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  tanggalFormatted,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Color(0xFF5A3B3B),
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),

                          const SizedBox(height: 18),

                          // ==========================================
                          // 3. KOTAK PETA INTERAKTIF
                          // ==========================================
                          Container(
                            height: 320,
                            width: double.infinity,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(28),
                              border: Border.all(
                                color: const Color(0xFF401010),
                                width: 2,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.1),
                                  blurRadius: 16,
                                  offset: const Offset(0, 6),
                                ),
                              ],
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: Stack(
                              children: [
                                _isLoadingKantor
                                    ? const Center(
                                        child: CircularProgressIndicator(
                                          color: Color(0xFF4A1010),
                                        ),
                                      )
                                    : FlutterMap(
                                        mapController: _mapController,
                                        options: MapOptions(
                                          initialCenter: LatLng(
                                            _latKantor,
                                            _lonKantor,
                                          ),
                                          initialZoom: 16.5,
                                          minZoom: 12,
                                          maxZoom: 19,
                                        ),
                                        children: [
                                          TileLayer(
                                            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                                            userAgentPackageName:
                                                'com.example.zabsen',
                                          ),
                                          CircleLayer(
                                            circles: [
                                              CircleMarker(
                                                point: LatLng(
                                                  _latKantor,
                                                  _lonKantor,
                                                ),
                                                radius: _radiusMaksimal
                                                    .toDouble(),
                                                useRadiusInMeter: true,
                                                color: Colors.green.withValues(
                                                  alpha: 0.22,
                                                ),
                                                borderColor: const Color(
                                                  0xFF2E7D32,
                                                ),
                                                borderStrokeWidth: 2,
                                              ),
                                              for (final k in _listKantor)
                                                if (k['nama'] != _namaKantor &&
                                                    k['lat'] != null &&
                                                    k['lng'] != null)
                                                  CircleMarker(
                                                    point: LatLng(
                                                      _toDouble(k['lat']),
                                                      _toDouble(k['lng']),
                                                    ),
                                                    radius: _toDouble(
                                                      k['radius'],
                                                      100.0,
                                                    ),
                                                    useRadiusInMeter: true,
                                                    color: Colors.blue
                                                        .withValues(
                                                          alpha: 0.15,
                                                        ),
                                                    borderColor: const Color(
                                                      0xFF1976D2,
                                                    ),
                                                    borderStrokeWidth: 1.5,
                                                  ),
                                            ],
                                          ),
                                          MarkerLayer(
                                            markers: [
                                              Marker(
                                                point: LatLng(
                                                  _latKantor,
                                                  _lonKantor,
                                                ),
                                                width: 100,
                                                height: 55,
                                                child: Column(
                                                  children: [
                                                    Container(
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 6,
                                                            vertical: 2,
                                                          ),
                                                      decoration: BoxDecoration(
                                                        color: Colors.white,
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              4,
                                                            ),
                                                        boxShadow: const [
                                                          BoxShadow(
                                                            color:
                                                                Colors.black26,
                                                            blurRadius: 4,
                                                          ),
                                                        ],
                                                      ),
                                                      child: Text(
                                                        _namaKantor,
                                                        style: const TextStyle(
                                                          fontSize: 9,
                                                          fontWeight:
                                                              FontWeight.bold,
                                                          color: Color(
                                                            0xFF4A1010,
                                                          ),
                                                        ),
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                      ),
                                                    ),
                                                    const Icon(
                                                      Icons.storefront_rounded,
                                                      color: Colors.green,
                                                      size: 26,
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              if (_userPosition != null)
                                                Marker(
                                                  point: LatLng(
                                                    _userPosition!.latitude,
                                                    _userPosition!.longitude,
                                                  ),
                                                  width: 80,
                                                  height: 55,
                                                  child: Column(
                                                    children: [
                                                      Container(
                                                        padding:
                                                            const EdgeInsets.symmetric(
                                                              horizontal: 6,
                                                              vertical: 2,
                                                            ),
                                                        decoration: BoxDecoration(
                                                          color: Colors
                                                              .blue
                                                              .shade700,
                                                          borderRadius:
                                                              BorderRadius.circular(
                                                                4,
                                                              ),
                                                          boxShadow: const [
                                                            BoxShadow(
                                                              color: Colors
                                                                  .black26,
                                                              blurRadius: 4,
                                                            ),
                                                          ],
                                                        ),
                                                        child: const Text(
                                                          'Posisi Anda',
                                                          style: TextStyle(
                                                            fontSize: 9,
                                                            fontWeight:
                                                                FontWeight.bold,
                                                            color: Colors.white,
                                                          ),
                                                        ),
                                                      ),
                                                      const Icon(
                                                        Icons
                                                            .person_pin_circle_rounded,
                                                        color:
                                                            Colors.blueAccent,
                                                        size: 28,
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ],
                                      ),

                                // Tombol Cari GPS
                                Positioned(
                                  top: 12,
                                  right: 12,
                                  child: Material(
                                    color: Colors.white,
                                    elevation: 4,
                                    shape: const CircleBorder(),
                                    child: InkWell(
                                      customBorder: const CircleBorder(),
                                      onTap: _getCurrentLocation,
                                      child: Padding(
                                        padding: const EdgeInsets.all(10.0),
                                        child: _isLoadingLocation
                                            ? const SizedBox(
                                                width: 20,
                                                height: 20,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2.5,
                                                      color: Color(0xFF4A1010),
                                                    ),
                                              )
                                            : const Icon(
                                                Icons.my_location_rounded,
                                                color: Color(0xFF4A1010),
                                                size: 20,
                                              ),
                                      ),
                                    ),
                                  ),
                                ),

                                // Banner Status Jarak
                                Positioned(
                                  bottom: 12,
                                  left: 12,
                                  right: 12,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 8,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(
                                        alpha: 0.94,
                                      ),
                                      borderRadius: BorderRadius.circular(20),
                                      boxShadow: const [
                                        BoxShadow(
                                          color: Colors.black26,
                                          blurRadius: 8,
                                          offset: Offset(0, 2),
                                        ),
                                      ],
                                    ),
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          _userPosition == null
                                              ? Icons.gps_not_fixed_rounded
                                              : (_isInsideRadius
                                                    ? Icons.check_circle_rounded
                                                    : Icons.cancel_rounded),
                                          color: _userPosition == null
                                              ? Colors.grey
                                              : (_isInsideRadius
                                                    ? Colors.green
                                                    : Colors.red),
                                          size: 18,
                                        ),
                                        const SizedBox(width: 8),
                                        Flexible(
                                          child: Text(
                                            _userPosition == null
                                                ? 'Mencari lokasi GPS Anda...'
                                                : 'Jarak: $_distanceToOffice m dari $_namaKantor (${_isInsideRadius ? 'Dalam Radius' : 'Di Luar Radius'})',
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold,
                                              color: _userPosition == null
                                                  ? Colors.black87
                                                  : (_isInsideRadius
                                                        ? Colors.green.shade800
                                                        : Colors.red.shade800),
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),

                          const SizedBox(height: 20),

                          // ==========================================
                          // 4. TOMBOL ABSEN
                          // ==========================================
                          GestureDetector(
                            onTap: _handleAbsenClick,
                            child: Container(
                              height: 58,
                              width: double.infinity,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(40),
                                gradient: const LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Color(0xFF3B0B0B),
                                    Color(0xFF1E0404),
                                  ],
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(0xFF2D0707)
                                        .withValues(alpha: 0.4),
                                    blurRadius: 14,
                                    offset: const Offset(0, 6),
                                  ),
                                ],
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Container(
                                    width: 30,
                                    height: 30,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: Colors.white,
                                        width: 2.2,
                                      ),
                                    ),
                                    child: Center(
                                      child: Container(
                                        width: 12,
                                        height: 12,
                                        decoration: const BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  const Text(
                                    'Absen',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),

                          const SizedBox(height: 22),

                          // ==========================================
                          // 5. RIWAYAT ABSEN HARI INI
                          // ==========================================
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(20.0),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(28),
                              border: Border.all(
                                color: const Color(0xFFE8E8E8),
                                width: 1.5,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.05),
                                  blurRadius: 16,
                                  offset: const Offset(0, 6),
                                ),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // Header Card Riwayat
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Row(
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.all(8),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF500808)
                                                .withValues(alpha: 0.08),
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
                                          ),
                                          child: const Icon(
                                            Icons.history_rounded,
                                            color: Color(0xFF500808),
                                            size: 20,
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        const Text(
                                          'Riwayat Absen Hari Ini',
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                            color: Color(0xFF1E1E1E),
                                          ),
                                        ),
                                      ],
                                    ),
                                    IconButton(
                                      onPressed: _loadRiwayatHariIni,
                                      icon: const Icon(
                                        Icons.refresh_rounded,
                                        size: 20,
                                        color: Color(0xFF500808),
                                      ),
                                      tooltip: 'Segarkan Riwayat',
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 16),

                                // Konten Tabel / List
                                if (_isLoadingRiwayat)
                                  const Center(
                                    child: Padding(
                                      padding: EdgeInsets.symmetric(
                                        vertical: 24.0,
                                      ),
                                      child: CircularProgressIndicator(
                                        color: Color(0xFF500808),
                                        strokeWidth: 2.5,
                                      ),
                                    ),
                                  )
                                else if (_riwayatHariIni.isEmpty)
                                  Center(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 20.0,
                                      ),
                                      child: Column(
                                        children: const [
                                          Icon(
                                            Icons.event_available_outlined,
                                            size: 40,
                                            color: Color(0xFFB0B0B0),
                                          ),
                                          SizedBox(height: 8),
                                          Text(
                                            'Belum ada riwayat absensi hari ini',
                                            style: TextStyle(
                                              fontSize: 13,
                                              color: Color(0xFF757575),
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  )
                                else
                                  ListView.separated(
                                    shrinkWrap: true,
                                    physics:
                                        const NeverScrollableScrollPhysics(),
                                    itemCount: _riwayatHariIni.length,
                                    separatorBuilder: (_, _) => const Divider(
                                      height: 20,
                                      color: Color(0xFFF2F2F2),
                                    ),
                                    itemBuilder: (context, index) {
                                      final item = _riwayatHariIni[index];
                                      final tipe =
                                          item['tipe_absen']?.toString() ??
                                          'Absen';
                                      final waktu =
                                          item['waktu']?.toString() ?? '-';
                                      final status =
                                          item['status']?.toString() ?? 'Hadir';
                                      final lokasi =
                                          item['lokasi']?.toString() ?? '';

                                      final isPulang =
                                          tipe.toLowerCase().contains(
                                            'pulang',
                                          ) ||
                                          tipe.toLowerCase().contains(
                                            'checkout',
                                          );
                                      final isIstirahat = tipe
                                          .toLowerCase()
                                          .contains('istirahat');

                                      Color iconBg = Colors.green.shade50;
                                      Color iconColor = Colors.green.shade700;
                                      IconData iconData = Icons.login_rounded;

                                      if (isPulang) {
                                        iconBg = Colors.red.shade50;
                                        iconColor = Colors.red.shade700;
                                        iconData = Icons.logout_rounded;
                                      } else if (isIstirahat) {
                                        iconBg = Colors.amber.shade50;
                                        iconColor = Colors.amber.shade800;
                                        iconData = Icons.coffee_rounded;
                                      }

                                      return Row(
                                        children: [
                                          Container(
                                            width: 40,
                                            height: 40,
                                            decoration: BoxDecoration(
                                              color: iconBg,
                                              shape: BoxShape.circle,
                                            ),
                                            child: Icon(
                                              iconData,
                                              color: iconColor,
                                              size: 20,
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  tipe,
                                                  style: const TextStyle(
                                                    fontSize: 14,
                                                    fontWeight: FontWeight.w700,
                                                    color: Color(0xFF1E1E1E),
                                                  ),
                                                ),
                                                if (lokasi.isNotEmpty)
                                                  Text(
                                                    lokasi,
                                                    style: const TextStyle(
                                                      fontSize: 11,
                                                      color: Color(0xFF888888),
                                                    ),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                              ],
                                            ),
                                          ),
                                          Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.end,
                                            children: [
                                              Text(
                                                waktu,
                                                style: const TextStyle(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.bold,
                                                  color: Color(0xFF230505),
                                                ),
                                              ),
                                              const SizedBox(height: 2),
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 8,
                                                      vertical: 2,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color:
                                                      status.toLowerCase() ==
                                                          'terlambat'
                                                      ? Colors.amber.shade100
                                                      : Colors.green.shade100,
                                                  borderRadius:
                                                      BorderRadius.circular(12),
                                                ),
                                                child: Text(
                                                  status,
                                                  style: TextStyle(
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.bold,
                                                    color:
                                                        status.toLowerCase() ==
                                                            'terlambat'
                                                        ? Colors.amber.shade900
                                                        : Colors.green.shade800,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      );
                                    },
                                  ),
                              ],
                            ),
                          ),

                          const SizedBox(height: 20),
                        ],
                      ),
                    ),
                  ),
                  IzinPage(key: _izinKey),
                  KalenderPage(key: _kalenderKey),
                  ProfilePage(
                    key: _profileKey,
                    onUserUpdated: _applyUserUpdate,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),

      // ==========================================
      // 6. BOTTOM NAVIGATION BAR
      // ==========================================
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFECECEC), width: 1.2)),
        ),
        child: BottomNavigationBar(
          currentIndex: _currentNavIndex,
          onTap: (index) {
            setState(() {
              _currentNavIndex = index;
            });

            // Muat ulang profil setiap kali tab Profil dibuka.
            if (index == 3) {
              _profileKey.currentState?.reload();
            }

            // Muat ulang konfigurasi & sisa cuti saat tab Izin dibuka.
            if (index == 1) {
              _izinKey.currentState?.reload();
            }

            // Muat ulang absensi & cuti saat tab Kalender dibuka.
            if (index == 2) {
              _kalenderKey.currentState?.reload();
            }
          },
          type: BottomNavigationBarType.fixed,
          backgroundColor: Colors.white,
          elevation: 0,
          selectedItemColor: Colors.black,
          unselectedItemColor: const Color(0xFF6E6E6E),
          selectedLabelStyle: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
          unselectedLabelStyle: const TextStyle(
            fontWeight: FontWeight.w500,
            fontSize: 12,
          ),
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.person_pin, size: 26),
              label: 'Absen',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.event_note_outlined, size: 26),
              label: 'Izin',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.calendar_month_outlined, size: 26),
              label: 'Kalender',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.manage_accounts_outlined, size: 26),
              label: 'Profil',
            ),
          ],
        ),
      ),
    );
  }
}
