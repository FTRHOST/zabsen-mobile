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
  int _currentNavIndex = 0;
  late Timer _timer;
  DateTime _currentTime = DateTime.now();

  // Data User
  int? _userId;
  String _userName = 'Pengguna';
  String _userCabang = 'Pusat';
  String _userRole = 'Karyawan';

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
    });
  }

  /// Membuka panel admin web.
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

  /// Tombol pil pada header untuk tab non-Absen (putih bersih).
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

  /// Tombol pil kaca transparan pada Hero Header tab Absen.
  Widget _buildHeroGlassAction({
    required String label,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.white.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(40),
      child: InkWell(
        borderRadius: BorderRadius.circular(40),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(40),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.25),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 14),
              const SizedBox(width: 5),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Header standar untuk tab Izin, Kalender, dan Profil.
  Widget _buildStandardHeader() {
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
                Text(
                  'Selamat Datang, $_userName',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1E1E1E),
                  ),
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
          });
          _loadRiwayatHariIni();
        }
      }
    } catch (_) {}

    // 2. Ambil data kantor dari Supabase API
    try {
      final supabase = Supabase.instance.client;
      final List<dynamic> dataKantor =
          await supabase.from('kantor').select('*');

      if (dataKantor.isNotEmpty && mounted) {
        _listKantor =
            dataKantor.map((e) => Map<String, dynamic>.from(e)).toList();

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
          _riwayatHariIni =
              rows.map((e) => Map<String, dynamic>.from(e)).toList();
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

  /// Menyimpan rekaman absensi ke tabel absensi di Supabase
  Future<void> _simpanAbsensi(String tipe) async {
    if (_userId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sesi pengguna tidak valid, silakan login ulang.'),
        ),
      );
      return;
    }

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
      final now = DateTime.now();
      final todayStr =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final timeStr =
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';

      await Supabase.instance.client.from('absensi').insert([
        {
          'user_id': _userId,
          'tanggal': todayStr,
          'waktu': timeStr,
          'tipe_absen': tipe,
          'lokasi': 'Jarak: $_distanceToOffice m dari $_namaKantor',
          'status': 'Hadir',
          'keterangan_waktu': 'Tepat Waktu',
        },
      ]);

      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Presensi $tipe berhasil dicatat!'),
            backgroundColor: const Color(0xFF2E7D32),
          ),
        );
        _loadRiwayatHariIni();
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Gagal mencatat absen: $e'),
            backgroundColor: Colors.red.shade800,
          ),
        );
      }
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
          title: const Row(
            children: [
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
                _buildTipeAbsenTile(
                  icon: Icons.login_rounded,
                  color: Colors.green,
                  title: 'Absen Masuk',
                  subtitle: 'Catat jam kehadiran masuk kerja',
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _simpanAbsensi('Masuk');
                  },
                ),
                const SizedBox(height: 10),
                _buildTipeAbsenTile(
                  icon: Icons.coffee_rounded,
                  color: Colors.amber.shade700,
                  title: 'Istirahat',
                  subtitle: 'Mulai atau kembali dari istirahat',
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _simpanAbsensi('Istirahat');
                  },
                ),
                const SizedBox(height: 10),
                _buildTipeAbsenTile(
                  icon: Icons.directions_walk_rounded,
                  color: Colors.blue.shade700,
                  title: 'Izin Keluar',
                  subtitle: 'Keperluan dinas atau izin sementara',
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _simpanAbsensi('Izin');
                  },
                ),
                const SizedBox(height: 10),
                _buildTipeAbsenTile(
                  icon: Icons.logout_rounded,
                  color: Colors.red.shade700,
                  title: 'Absen Pulang / Checkout',
                  subtitle: 'Selesaikan jam kerja hari ini',
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _simpanAbsensi('Pulang');
                  },
                ),
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
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.3)),
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

  /// Tab Utama (Absen) dengan tata letak Hero Gradient Header & Overlapping Card
  Widget _buildAbsenTab(String jamMenit, String tanggalFormatted) {
    final double topSafePadding = MediaQuery.of(context).padding.top;

    return RefreshIndicator(
      onRefresh: () async {
        await _loadUserAndKantor();
        await _loadRiwayatHariIni();
      },
      color: const Color(0xFF4A1010),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Stack(
          children: [
            // ==========================================================
            // LAYER BACKGROUND GRADASI HEADER (ZIEDA BURGUNDY PALETTE)
            // ==========================================================
            Container(
              height: 235 + topSafePadding,
              width: double.infinity,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color(0xFF3A0A0A), // Deep Maroon
                    Color(0xFF681616), // Rich Burgundy
                    Color(0xFFA64B3A), // Warm Terracotta Accent
                  ],
                  stops: [0.0, 0.58, 1.0],
                ),
                borderRadius: BorderRadius.vertical(
                  bottom: Radius.circular(32),
                ),
              ),
              child: Stack(
                children: [
                  // Aksen cahaya lembut di sudut kanan bawah header
                  Positioned(
                    right: -30,
                    bottom: -20,
                    child: Container(
                      width: 170,
                      height: 170,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            const Color(0xFFD4A373).withValues(alpha: 0.28),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),
                  // Aksen lingkaran halus di kiri atas
                  Positioned(
                    left: -40,
                    top: -20,
                    child: Container(
                      width: 140,
                      height: 140,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.04),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // ==========================================================
            // KONTEN UTAMA DI ATAS BACKGROUND
            // ==========================================================
            Padding(
              padding: EdgeInsets.fromLTRB(
                22.0,
                topSafePadding + 14.0,
                22.0,
                24.0,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 1. TOP UTILITY BAR (Badge Brand & Tombol Aksi)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Pill Badge Brand & Cabang
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(30),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.2),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 7,
                              height: 7,
                              decoration: const BoxDecoration(
                                color: Color(0xFFE8C391),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 7),
                            const Text(
                              'ZIEDA ABSEN',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                                letterSpacing: 0.8,
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Tombol Admin & Logout
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_isAdmin) ...[
                            _buildHeroGlassAction(
                              label: 'Admin',
                              icon: Icons.admin_panel_settings_outlined,
                              onTap: _openAdminPanel,
                            ),
                            const SizedBox(width: 8),
                          ],
                          _buildHeroGlassAction(
                            label: 'Logout',
                            icon: Icons.logout_rounded,
                            onTap: () => logoutToLogin(context),
                          ),
                        ],
                      ),
                    ],
                  ),

                  const SizedBox(height: 20),

                  // 2. GREETING TIPOGRAFI KONTRAS (Light + Bold)
                  RichText(
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    text: TextSpan(
                      style: const TextStyle(
                        fontSize: 23,
                        color: Colors.white,
                        letterSpacing: -0.3,
                      ),
                      children: [
                        TextSpan(
                          text: 'Halo, ',
                          style: TextStyle(
                            fontWeight: FontWeight.w400,
                            color: Colors.white.withValues(alpha: 0.88),
                          ),
                        ),
                        TextSpan(
                          text: _userName,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    tanggalFormatted,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w400,
                      color: Colors.white.withValues(alpha: 0.82),
                      letterSpacing: 0.1,
                    ),
                  ),

                  const SizedBox(height: 22),

                  // 3. OVERLAPPING HERO CARD: JAM DIGITAL & STATUS LOKASI
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      vertical: 18.0,
                      horizontal: 20.0,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF2D0707).withValues(alpha: 0.10),
                          blurRadius: 24,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        // Kolom Kiri: Jam Realtime
                        Expanded(
                          flex: 5,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'WAKTU SAAT INI',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.grey.shade500,
                                  letterSpacing: 0.8,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.baseline,
                                textBaseline: TextBaseline.alphabetic,
                                children: [
                                  Text(
                                    jamMenit,
                                    style: const TextStyle(
                                      fontSize: 36,
                                      fontWeight: FontWeight.w900,
                                      color: Color(0xFF230505),
                                      letterSpacing: -1.0,
                                      height: 1.0,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  const Text(
                                    'WIB',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w800,
                                      color: Color(0xFF681616),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),

                        // Garis Pemisah Vertikal Tipis
                        Container(
                          height: 46,
                          width: 1,
                          color: const Color(0xFFECE8E6),
                          margin: const EdgeInsets.symmetric(horizontal: 14),
                        ),

                        // Kolom Kanan: Info Cabang & Status Radius
                        Expanded(
                          flex: 5,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: _userPosition == null
                                      ? Colors.grey.shade100
                                      : (_isInsideRadius
                                          ? const Color(0xFFE8F5E9)
                                          : const Color(0xFFFFEBEE)),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  _userPosition == null
                                      ? 'Mencari GPS...'
                                      : (_isInsideRadius
                                          ? 'Dalam Radius'
                                          : 'Di Luar Radius'),
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w700,
                                    color: _userPosition == null
                                        ? Colors.grey.shade700
                                        : (_isInsideRadius
                                            ? const Color(0xFF2E7D32)
                                            : const Color(0xFFC62828)),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                _namaKantor,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF1E1E1E),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _userPosition == null
                                    ? 'Menghitung jarak...'
                                    : 'Jarak $_distanceToOffice m (Maks $_radiusMaksimal m)',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey.shade600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 22),

                  // 4. SECTION HEADER PETA
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Lokasi Presensi',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF1E1E1E),
                          letterSpacing: -0.2,
                        ),
                      ),
                      GestureDetector(
                        onTap: _getCurrentLocation,
                        child: Text(
                          _isLoadingLocation ? 'Memperbarui...' : 'Perbarui GPS',
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF681616),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // 5. KOTAK PETA INTERAKTIF
                  Container(
                    height: 280,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: const Color(0xFFE6DFDC),
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
                                    urlTemplate:
                                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
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
                                        radius: _radiusMaksimal.toDouble(),
                                        useRadiusInMeter: true,
                                        color: Colors.green.withValues(
                                          alpha: 0.22,
                                        ),
                                        borderColor: const Color(0xFF2E7D32),
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
                                            color: Colors.blue.withValues(
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
                                                    BorderRadius.circular(4),
                                                boxShadow: const [
                                                  BoxShadow(
                                                    color: Colors.black26,
                                                    blurRadius: 4,
                                                  ),
                                                ],
                                              ),
                                              child: Text(
                                                _namaKantor,
                                                style: const TextStyle(
                                                  fontSize: 9,
                                                  fontWeight: FontWeight.bold,
                                                  color: Color(0xFF4A1010),
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
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
                                                  color: Colors.blue.shade700,
                                                  borderRadius:
                                                      BorderRadius.circular(4),
                                                  boxShadow: const [
                                                    BoxShadow(
                                                      color: Colors.black26,
                                                      blurRadius: 4,
                                                    ),
                                                  ],
                                                ),
                                                child: const Text(
                                                  'Posisi Anda',
                                                  style: TextStyle(
                                                    fontSize: 9,
                                                    fontWeight: FontWeight.bold,
                                                    color: Colors.white,
                                                  ),
                                                ),
                                              ),
                                              const Icon(
                                                Icons
                                                    .person_pin_circle_rounded,
                                                color: Colors.blueAccent,
                                                size: 28,
                                              ),
                                            ],
                                          ),
                                        ),
                                    ],
                                  ),
                                ],
                              ),

                        // Tombol Cari GPS Mengambang
                        Positioned(
                          top: 12,
                          right: 12,
                          child: Material(
                            color: Colors.white,
                            elevation: 3,
                            shape: const CircleBorder(),
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: _getCurrentLocation,
                              child: Padding(
                                padding: const EdgeInsets.all(10.0),
                                child: _isLoadingLocation
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.2,
                                          color: Color(0xFF4A1010),
                                        ),
                                      )
                                    : const Icon(
                                        Icons.my_location_rounded,
                                        color: Color(0xFF4A1010),
                                        size: 18,
                                      ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 18),

                  // 6. TOMBOL ABSEN UTAMA
                  GestureDetector(
                    onTap: _handleAbsenClick,
                    child: Container(
                      height: 56,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18),
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Color(0xFF5A1212),
                            Color(0xFF2B0606),
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color:
                                const Color(0xFF3A0A0A).withValues(alpha: 0.32),
                            blurRadius: 16,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white,
                                width: 2.0,
                              ),
                            ),
                            child: Center(
                              child: Container(
                                width: 11,
                                height: 11,
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          const Text(
                            'Catat Kehadiran Sekarang',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                              letterSpacing: 0.2,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // 7. SECTION HEADER RIWAYAT ABSEN
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Riwayat Absen Hari Ini',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF1E1E1E),
                          letterSpacing: -0.2,
                        ),
                      ),
                      GestureDetector(
                        onTap: _loadRiwayatHariIni,
                        child: const Text(
                          'Segarkan',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF681616),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // 8. KARTU RIWAYAT ABSEN HARI INI
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(18.0),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.04),
                          blurRadius: 16,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: _isLoadingRiwayat
                        ? const Center(
                            child: Padding(
                              padding: EdgeInsets.symmetric(vertical: 24.0),
                              child: CircularProgressIndicator(
                                color: Color(0xFF500808),
                                strokeWidth: 2.5,
                              ),
                            ),
                          )
                        : _riwayatHariIni.isEmpty
                            ? Center(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 18.0,
                                  ),
                                  child: Column(
                                    children: const [
                                      Icon(
                                        Icons.event_available_outlined,
                                        size: 38,
                                        color: Color(0xFFB8B0AD),
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
                            : ListView.separated(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: _riwayatHariIni.length,
                                separatorBuilder: (_, __) => const Divider(
                                  height: 20,
                                  color: Color(0xFFF3EFEF),
                                ),
                                itemBuilder: (context, index) {
                                  final item = _riwayatHariIni[index];
                                  final tipe =
                                      item['tipe_absen']?.toString() ?? 'Absen';
                                  final waktu =
                                      item['waktu']?.toString() ?? '-';
                                  final status =
                                      item['status']?.toString() ?? 'Hadir';
                                  final lokasi =
                                      item['lokasi']?.toString() ?? '';

                                  final isPulang =
                                      tipe.toLowerCase().contains('pulang') ||
                                          tipe
                                              .toLowerCase()
                                              .contains('checkout');
                                  final isIstirahat =
                                      tipe.toLowerCase().contains('istirahat');

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
                                        width: 42,
                                        height: 42,
                                        decoration: BoxDecoration(
                                          color: iconBg,
                                          borderRadius:
                                              BorderRadius.circular(14),
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
                                                overflow: TextOverflow.ellipsis,
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
                                              fontSize: 13.5,
                                              fontWeight: FontWeight.w800,
                                              color: Color(0xFF230505),
                                            ),
                                          ),
                                          const SizedBox(height: 3),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: status.toLowerCase() ==
                                                      'terlambat'
                                                  ? Colors.amber.shade100
                                                  : Colors.green.shade100,
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                            child: Text(
                                              status,
                                              style: TextStyle(
                                                fontSize: 10,
                                                fontWeight: FontWeight.w700,
                                                color: status.toLowerCase() ==
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
                  ),
                ],
              ),
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
      backgroundColor: _currentNavIndex == 0
          ? const Color(0xFFF7F5F4)
          : Colors.white,
      body: Column(
        children: [
          // Header standar hanya ditampilkan untuk tab selain Absen (Izin, Kalender, Profil)
          if (_currentNavIndex != 0)
            SafeArea(
              bottom: false,
              child: _buildStandardHeader(),
            ),
          Expanded(
            child: IndexedStack(
              index: _currentNavIndex,
              children: [
                _buildAbsenTab(jamMenit, tanggalFormatted),
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

      // ==========================================
      // BOTTOM NAVIGATION BAR
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

            if (index == 3) {
              _profileKey.currentState?.reload();
            }
            if (index == 1) {
              _izinKey.currentState?.reload();
            }
            if (index == 2) {
              _kalenderKey.currentState?.reload();
            }
          },
          type: BottomNavigationBarType.fixed,
          backgroundColor: Colors.white,
          elevation: 0,
          selectedItemColor: const Color(0xFF4A1010),
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