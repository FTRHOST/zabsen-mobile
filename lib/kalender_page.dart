import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session.dart';
import 'hari_libur.dart';
import 'session_actions.dart';

typedef _DataRow = Map<String, dynamic>;

// Font utama & sekunder yang selaras dengan AbsenPage
const String _primaryFont = 'Google Sans Flex';
const String _secondaryFont = 'Inter';

// Palet warna utama Zieda Absen
const Color _kCanvasBg = Color(0xFFF7F5F4);
const Color _kMaroonDeep = Color(0xFF330808);
const Color _kBurgundy = Color(0xFF5E1212);
const Color _kTerracotta = Color(0xFF8F382B);
const Color _kTextPrimary = Color(0xFF1E1E1E);
const Color _kTextMuted = Color(0xFF6E6E6E);

/// Warna status pada kalender
const Color _kHadirBg = Color(0xFFE8F5E9);
const Color _kHadirFg = Color(0xFF1B6E35);
const Color _kTelatBg = Color(0xFFFFF3CD);
const Color _kTelatFg = Color(0xFF7A5900);
const Color _kCutiBg = Color(0xFFFCE4E6);
const Color _kCutiFg = Color(0xFF8C2D38);

const List<String> _kMonthLong = [
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

const List<String> _kDayShort = [
  'Min',
  'Sen',
  'Sel',
  'Rab',
  'Kam',
  'Jum',
  'Sab',
];

/// Halaman Kalender Kehadiran dengan Hero Gradient Header & Overlapping Card
/// yang langsung menggantikan header putih standar dan selaras dengan AbsenPage.
class KalenderPage extends StatefulWidget {
  const KalenderPage({
    super.key,
    this.isAdmin = false,
    this.onOpenAdmin,
    this.onLogout,
  });

  final bool isAdmin;
  final VoidCallback? onOpenAdmin;
  final VoidCallback? onLogout;

  @override
  State<KalenderPage> createState() => KalenderPageState();
}

class KalenderPageState extends State<KalenderPage> {
  final SupabaseClient _supabase = Supabase.instance.client;

  int? _userId;
  bool _isAdminUser = false;

  List<_DataRow> _absensi = [];
  List<_DataRow> _cutiDisetujui = [];

  Set<int> _hariLibur = {};
  late DateTime _visibleMonth;
  String _formatWaktu = 'HH:mm:ss';

  bool _isLoading = true;
  bool _isLoadingAbsensi = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _visibleMonth = DateTime(now.year, now.month);
    _isAdminUser = widget.isAdmin;
    reload();
  }

  // ============================================================
  // DATA
  // ============================================================

  Future<void> reload({bool showLoading = true}) async {
    if (mounted) {
      setState(() {
        if (showLoading) _isLoading = true;
        _loadError = null;
      });
    }

    try {
      final user =
          await AuthSession.restore() ?? await AuthSession.readCachedUser();
      final userId = _toInt(user?['id'], 0);

      if (user == null || userId <= 0) {
        if (!mounted) return;
        setState(() {
          _isLoading = false;
          _loadError =
              'Data pengguna tidak ditemukan. Silakan logout lalu login kembali.';
        });
        return;
      }

      final role = (user['role'] ?? '').toString().trim().toLowerCase();
      final isAdminDetected =
          widget.isAdmin || role == 'hr' || role == 'super admin';

      final first = DateTime(_visibleMonth.year, _visibleMonth.month, 1);
      final last = DateTime(_visibleMonth.year, _visibleMonth.month + 1, 0);

      final results = await Future.wait<dynamic>([
        _supabase
            .from('absensi')
            .select('*')
            .eq('user_id', userId)
            .gte('tanggal', _formatDateApi(first))
            .lte('tanggal', _formatDateApi(last))
            .order('tanggal', ascending: true)
            .order('waktu', ascending: true),
        _supabase
            .from('cuti')
            .select('*')
            .eq('user_id', userId)
            .eq('status_pengajuan', 'Disetujui'),
        _supabase
            .from('app_settings')
            .select('format_waktu')
            .eq('id', 1)
            .maybeSingle(),
      ]);

      final absensiRows = results[0] is List ? results[0] as List : const [];
      final cutiRows = results[1] is List ? results[1] as List : const [];
      final settings = results[2] is Map
          ? _DataRow.from(results[2] as Map)
          : _DataRow();

      if (!mounted) return;

      setState(() {
        _userId = userId;
        _isAdminUser = isAdminDetected;
        _hariLibur = parseHariLibur(user['hari_libur']);
        _absensi = absensiRows
            .whereType()
            .map((row) => _DataRow.from(row))
            .toList();
        _cutiDisetujui = cutiRows
            .whereType()
            .map((row) => _DataRow.from(row))
            .toList();
        _formatWaktu = (settings['format_waktu'] ?? 'HH:mm:ss').toString();
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Gagal memuat kalender: $e');
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _loadError =
            'Gagal memuat data kalender. Periksa koneksi lalu coba lagi.\n\n$e';
      });
    }
  }

  Future<void> _loadAbsensiBulanIni() async {
    final userId = _userId;
    if (userId == null) return;

    final first = DateTime(_visibleMonth.year, _visibleMonth.month, 1);
    final last = DateTime(_visibleMonth.year, _visibleMonth.month + 1, 0);

    try {
      final rows = await _supabase
          .from('absensi')
          .select('*')
          .eq('user_id', userId)
          .gte('tanggal', _formatDateApi(first))
          .lte('tanggal', _formatDateApi(last))
          .order('tanggal', ascending: true)
          .order('waktu', ascending: true);

      if (!mounted) return;
      setState(() {
        _absensi = rows
            .whereType()
            .map((row) => _DataRow.from(row))
            .toList();
      });
    } catch (e) {
      debugPrint('Gagal memuat absensi bulan ini: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Gagal memuat absensi bulan ini.')),
      );
    }
  }

  Future<void> _changeMonth(int delta) async {
    if (_isLoadingAbsensi) return;

    setState(() {
      _visibleMonth = DateTime(_visibleMonth.year, _visibleMonth.month + delta);
      _isLoadingAbsensi = true;
      _absensi = [];
    });

    await _loadAbsensiBulanIni();
    if (mounted) setState(() => _isLoadingAbsensi = false);
  }

  Future<void> _goToCurrentMonth() async {
    if (_isLoadingAbsensi) return;

    final now = DateTime.now();
    if (_visibleMonth.year == now.year && _visibleMonth.month == now.month) {
      return;
    }

    setState(() {
      _visibleMonth = DateTime(now.year, now.month);
      _isLoadingAbsensi = true;
      _absensi = [];
    });

    await _loadAbsensiBulanIni();
    if (mounted) setState(() => _isLoadingAbsensi = false);
  }

  // Menghitung ringkasan status kehadiran pada bulan yang sedang tampil
  (int hadir, int telat, int cutiLibur) _monthlySummary() {
    final totalDays = DateTime(
      _visibleMonth.year,
      _visibleMonth.month + 1,
      0,
    ).day;

    int hadirCount = 0;
    int telatCount = 0;
    int cutiLiburCount = 0;

    for (int d = 1; d <= totalDays; d++) {
      final date = DateTime(_visibleMonth.year, _visibleMonth.month, d);
      final dateStr = _formatDateApi(date);
      final cuti = _cutiForDate(dateStr);
      final isHoliday = _hariLibur.contains(weekdayIndex(date));

      if (cuti != null || isHoliday) {
        cutiLiburCount++;
        continue;
      }

      final dayRows = _absensiForDate(dateStr);
      if (dayRows.isNotEmpty) {
        final status = (dayRows.first['status'] ?? '').toString().trim();
        if (status == 'Hadir') {
          hadirCount++;
        } else if (status == 'Terlambat') {
          telatCount++;
        }
      }
    }

    return (hadirCount, telatCount, cutiLiburCount);
  }

  // ============================================================
  // UI
  // ============================================================

  Widget _buildHeroGlassAction({
    required String label,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.white.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(40),
      child: InkWell(
        borderRadius: BorderRadius.circular(40),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 14),
              const SizedBox(width: 5),
              Text(
                label,
                style: const TextStyle(
                  fontFamily: _primaryFont,
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final double topSafePadding = MediaQuery.of(context).padding.top;

    // Jika dibuka di bawah _buildStandardHeader milik AbsenPage, geser ke atas
    // agar Hero Gradient Header langsung menutupi header putih bawaan.
    final bool hasParentStandardHeader =
        context.findAncestorWidgetOfExactType<SafeArea>() != null;
    final double effectiveTopPadding =
        hasParentStandardHeader ? 14.0 : topSafePadding + 14.0;
    final double headerHeight =
        hasParentStandardHeader ? 212.0 : 212.0 + topSafePadding;

    return ColoredBox(
      color: _kCanvasBg,
      child: RefreshIndicator(
        color: _kBurgundy,
        onRefresh: () => reload(showLoading: false),
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Stack(
            children: [
              // ==========================================================
              // LAYER BACKGROUND GRADASI HEADER (IDENTIK DENGAN ABSEN PAGE)
              // ==========================================================
              Container(
                height: headerHeight,
                width: double.infinity,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      _kMaroonDeep,
                      _kBurgundy,
                      _kTerracotta,
                    ],
                    stops: [0.0, 0.55, 1.0],
                  ),
                  borderRadius: BorderRadius.vertical(
                    bottom: Radius.circular(32),
                  ),
                ),
                child: Stack(
                  children: [
                    Positioned(
                      right: -25,
                      bottom: -25,
                      child: Container(
                        width: 180,
                        height: 180,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: RadialGradient(
                            colors: [
                              const Color(0xFFE0B17E).withValues(alpha: 0.24),
                              Colors.transparent,
                            ],
                          ),
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
                  effectiveTopPadding,
                  22.0,
                  28.0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 1. TOP BAR: Tulisan ZIEDA ABSEN murni tanpa box/lingkaran
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const Text(
                          'ZIEDA ABSEN',
                          style: TextStyle(
                            fontFamily: _primaryFont,
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            fontVariations: [FontVariation('wght', 800)],
                            color: Colors.white,
                            letterSpacing: 1.4,
                          ),
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_isAdminUser &&
                                widget.onOpenAdmin != null) ...[
                              _buildHeroGlassAction(
                                label: 'Admin',
                                icon: Icons.admin_panel_settings_outlined,
                                onTap: widget.onOpenAdmin!,
                              ),
                              const SizedBox(width: 8),
                            ],
                            _buildHeroGlassAction(
                              label: 'Logout',
                              icon: Icons.logout_rounded,
                              onTap: widget.onLogout ??
                                  () => logoutToLogin(context),
                            ),
                          ],
                        ),
                      ],
                    ),

                    const SizedBox(height: 18),

                    // 2. JUDUL HALAMAN (Tipografi Kontras)
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
                            text: 'Kalender ',
                            style: TextStyle(
                              fontFamily: _secondaryFont,
                              fontWeight: FontWeight.w400,
                              color: Colors.white.withValues(alpha: 0.86),
                            ),
                          ),
                          const TextSpan(
                            text: 'Kehadiran',
                            style: TextStyle(
                              fontFamily: _primaryFont,
                              fontWeight: FontWeight.w800,
                              fontVariations: [FontVariation('wght', 800)],
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Rekap status & rincian absensi harian',
                      style: TextStyle(
                        fontFamily: _secondaryFont,
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                        color: Colors.white.withValues(alpha: 0.80),
                      ),
                    ),

                    const SizedBox(height: 22),

                    // 3. OVERLAPPING HERO CARD: NAVIGASI BULAN & RINGKASAN STAT
                    _buildOverlappingSummaryCard(),

                    const SizedBox(height: 22),

                    // 4. KONTEN KALENDER / LOADING / ERROR
                    if (_isLoading)
                      Container(
                        height: 300,
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: const Center(
                          child: CircularProgressIndicator(color: _kBurgundy),
                        ),
                      )
                    else if (_loadError != null)
                      _buildErrorCard()
                    else
                      _buildCalendarCard(scheme),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Kartu putih melayang tepat di garis transisi header (tanpa garis pemisah)
  Widget _buildOverlappingSummaryCard() {
    final (hadirCount, telatCount, cutiLiburCount) = _monthlySummary();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 18.0, horizontal: 20.0),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF2D0707).withValues(alpha: 0.09),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Sisi Kiri: Navigasi Bulan & Tahun Aktif
          Expanded(
            flex: 6,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Periode Aktif',
                  style: TextStyle(
                    fontFamily: _secondaryFont,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: Colors.grey.shade500,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    _buildMiniMonthArrow(
                      icon: Icons.chevron_left_rounded,
                      onTap: (_isLoading || _isLoadingAbsensi)
                          ? null
                          : () => _changeMonth(-1),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _kMonthLong[_visibleMonth.month - 1],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: _primaryFont,
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              fontVariations: [FontVariation('wght', 800)],
                              color: _kMaroonDeep,
                              letterSpacing: -0.4,
                              height: 1.1,
                            ),
                          ),
                          Text(
                            '${_visibleMonth.year}',
                            style: const TextStyle(
                              fontFamily: _primaryFont,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: _kTerracotta,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    _buildMiniMonthArrow(
                      icon: Icons.chevron_right_rounded,
                      onTap: (_isLoading || _isLoadingAbsensi)
                          ? null
                          : () => _changeMonth(1),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(width: 10),

          // Sisi Kanan: Tiga Angka Ringkasan Tanpa Garis Pemisah
          Expanded(
            flex: 5,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _buildStatPill(
                  value: hadirCount,
                  label: 'Hadir',
                  bg: _kHadirBg,
                  fg: _kHadirFg,
                ),
                const SizedBox(width: 6),
                _buildStatPill(
                  value: telatCount,
                  label: 'Telat',
                  bg: _kTelatBg,
                  fg: _kTelatFg,
                ),
                const SizedBox(width: 6),
                _buildStatPill(
                  value: cutiLiburCount,
                  label: 'Libur',
                  bg: _kCutiBg,
                  fg: _kCutiFg,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMiniMonthArrow({
    required IconData icon,
    required VoidCallback? onTap,
  }) {
    return Material(
      color: _kCanvasBg,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: SizedBox(
          width: 30,
          height: 30,
          child: Icon(
            icon,
            size: 19,
            color: onTap == null ? Colors.grey.shade400 : _kBurgundy,
          ),
        ),
      ),
    );
  }

  Widget _buildStatPill({
    required int value,
    required String label,
    required Color bg,
    required Color fg,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _isLoading ? '-' : '$value',
            style: TextStyle(
              fontFamily: _primaryFont,
              fontSize: 14,
              fontWeight: FontWeight.w800,
              fontVariations: [FontVariation('wght', 800)],
              color: fg,
              height: 1.0,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: TextStyle(
              fontFamily: _secondaryFont,
              fontSize: 9.5,
              fontWeight: FontWeight.w600,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 32.0),
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
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.cloud_off_rounded, size: 48, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          const Text(
            'Kalender belum dapat dimuat',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: _primaryFont,
              fontSize: 16,
              fontWeight: FontWeight.w700,
              fontVariations: [FontVariation('wght', 700)],
              color: _kTextPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _loadError!,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: _secondaryFont,
              fontSize: 12.5,
              color: _kTextMuted,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 20),
          GestureDetector(
            onTap: reload,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 13),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF5A1212), Color(0xFF2B0606)],
                ),
              ),
              child: const Text(
                'Coba Lagi',
                style: TextStyle(
                  fontFamily: _primaryFont,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  fontVariations: [FontVariation('wght', 700)],
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCalendarCard(ColorScheme scheme) {
    final now = DateTime.now();
    final first = DateTime(_visibleMonth.year, _visibleMonth.month, 1);
    final leadingBlank = weekdayIndex(first);
    final totalDays = DateTime(
      _visibleMonth.year,
      _visibleMonth.month + 1,
      0,
    ).day;
    final isCurrentMonth =
        _visibleMonth.year == now.year && _visibleMonth.month == now.month;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section Header (Senada dengan "Lokasi Presensi" di AbsenPage)
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Jadwal & Presensi',
              style: TextStyle(
                fontFamily: _primaryFont,
                fontSize: 16,
                fontWeight: FontWeight.w700,
                fontVariations: [FontVariation('wght', 700)],
                color: _kTextPrimary,
                letterSpacing: -0.2,
              ),
            ),
            if (!isCurrentMonth)
              GestureDetector(
                onTap: _isLoadingAbsensi ? null : _goToCurrentMonth,
                child: const Text(
                  'Bulan Ini',
                  style: TextStyle(
                    fontFamily: _primaryFont,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    fontVariations: [FontVariation('wght', 700)],
                    color: _kBurgundy,
                  ),
                ),
              )
            else
              Text(
                '${_absensi.length} catatan',
                style: const TextStyle(
                  fontFamily: _secondaryFont,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: _kTextMuted,
                ),
              ),
          ],
        ),

        const SizedBox(height: 12),

        // Kartu Grid Kalender
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
          child: Column(
            children: [
              // Nama Hari (Min - Sab)
              Row(
                children: [
                  for (var index = 0; index < _kDayShort.length; index++)
                    Expanded(
                      child: Center(
                        child: Text(
                          _kDayShort[index],
                          style: TextStyle(
                            fontFamily: _primaryFont,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            fontVariations: [FontVariation('wght', 700)],
                            color: index == 0
                                ? const Color(0xFFC62828)
                                : index == 6
                                    ? _kTerracotta
                                    : _kTextMuted,
                          ),
                        ),
                      ),
                    ),
                ],
              ),

              const SizedBox(height: 10),

              // Grid Tanggal
              if (_isLoadingAbsensi)
                const SizedBox(
                  height: 240,
                  child: Center(
                    child: CircularProgressIndicator(color: _kBurgundy),
                  ),
                )
              else
                GridView.builder(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 7,
                    mainAxisSpacing: 7,
                    crossAxisSpacing: 7,
                    mainAxisExtent: 42,
                  ),
                  itemCount: leadingBlank + totalDays,
                  itemBuilder: (context, index) {
                    if (index < leadingBlank) return const SizedBox.shrink();
                    final day = index - leadingBlank + 1;
                    return _buildDayCell(
                      scheme,
                      DateTime(_visibleMonth.year, _visibleMonth.month, day),
                    );
                  },
                ),

              const SizedBox(height: 18),

              // Legenda Minimalis 1 Baris (Tanpa chip/kotak AI-slop)
              _buildLegend(scheme),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDayCell(ColorScheme scheme, DateTime date) {
    final dateStr = _formatDateApi(date);
    final now = DateTime.now();
    final isToday = _sameDay(date, now);
    final cuti = _cutiForDate(dateStr);
    final isHoliday = _hariLibur.contains(weekdayIndex(date));
    final dayRows = _absensiForDate(dateStr);
    final firstStatus = dayRows.isNotEmpty
        ? (dayRows.first['status'] ?? '').toString().trim()
        : '';

    Color background = _kCanvasBg.withValues(alpha: 0.65);
    Color foreground = _kTextPrimary;
    String? tooltip;

    if (cuti != null) {
      background = _kCutiBg;
      foreground = _kCutiFg;
      tooltip = 'Dalam Masa Cuti';
    } else if (isHoliday) {
      background = _kCutiBg;
      foreground = _kCutiFg;
      tooltip = 'Hari Libur Rutin';
    } else if (firstStatus.isNotEmpty) {
      switch (firstStatus) {
        case 'Hadir':
          background = _kHadirBg;
          foreground = _kHadirFg;
          tooltip = 'Hadir Tepat Waktu';
        case 'Terlambat':
          background = _kTelatBg;
          foreground = _kTelatFg;
          tooltip = 'Hadir Terlambat';
        case 'Alpha':
          background = scheme.errorContainer;
          foreground = scheme.onErrorContainer;
          tooltip = 'Alpha';
        case 'Lembur':
          background = scheme.tertiaryContainer;
          foreground = scheme.onTertiaryContainer;
          tooltip = 'Lembur';
        default:
          background = scheme.secondaryContainer;
          foreground = scheme.onSecondaryContainer;
          tooltip = firstStatus;
      }
    }

    return Tooltip(
      message: tooltip ?? '',
      waitDuration: const Duration(milliseconds: 500),
      child: Material(
        color: background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: isToday
              ? const BorderSide(color: _kBurgundy, width: 2)
              : BorderSide.none,
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _showDayDetail(
            date: date,
            rows: dayRows,
            cuti: cuti,
            isHoliday: isHoliday,
          ),
          child: Center(
            child: Text(
              '${date.day}',
              style: TextStyle(
                fontFamily: _primaryFont,
                fontSize: 13,
                fontWeight: isToday ? FontWeight.w800 : FontWeight.w600,
                color: isToday && firstStatus.isEmpty && cuti == null && !isHoliday
                    ? _kBurgundy
                    : foreground,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLegend(ColorScheme scheme) {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 14,
      runSpacing: 6,
      children: [
        _legendDot(const Color(0xFF1B6E35), 'Hadir'),
        _legendDot(const Color(0xFFD99B00), 'Telat'),
        _legendDot(const Color(0xFFD6455D), 'Cuti / Libur'),
        _legendDot(const Color(0xFFC62828), 'Alpha'),
        _legendDot(const Color(0xFF5E35B1), 'Lembur'),
      ],
    );
  }

  Widget _legendDot(Color dotColor, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: dotColor,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: const TextStyle(
            fontFamily: _secondaryFont,
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: _kTextMuted,
          ),
        ),
      ],
    );
  }

  // ============================================================
  // POP UP DETAIL TANGGAL
  // ============================================================

  Future<void> _showDayDetail({
    required DateTime date,
    required List<_DataRow> rows,
    required _DataRow? cuti,
    required bool isHoliday,
  }) {
    final scheme = Theme.of(context).colorScheme;

    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: _kCanvasBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) {
        final cutiRange = _cutiRange(cuti);
        final jenisCuti = _jenisCuti(cuti);

        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.82,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _formatTanggalPanjang(date),
                  style: const TextStyle(
                    fontFamily: _primaryFont,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    fontVariations: [FontVariation('wght', 800)],
                    color: _kMaroonDeep,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  rows.isEmpty
                      ? 'Tidak ada catatan absensi pada tanggal ini'
                      : '${rows.length} catatan absensi tercatat',
                  style: const TextStyle(
                    fontFamily: _secondaryFont,
                    fontSize: 12.5,
                    color: _kTextMuted,
                  ),
                ),
                const SizedBox(height: 16),
                if (cuti != null) ...[
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: _kCutiBg,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.beach_access_rounded,
                          size: 18,
                          color: _kCutiFg,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                jenisCuti == null
                                    ? 'Cuti disetujui'
                                    : 'Cuti disetujui • $jenisCuti',
                                style: const TextStyle(
                                  fontFamily: _primaryFont,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  fontVariations: [FontVariation('wght', 700)],
                                  color: _kCutiFg,
                                ),
                              ),
                              if (cutiRange.isNotEmpty) ...[
                                const SizedBox(height: 3),
                                Text(
                                  cutiRange,
                                  style: TextStyle(
                                    fontFamily: _secondaryFont,
                                    fontSize: 11.5,
                                    color: _kCutiFg.withValues(alpha: 0.85),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                ],
                if (rows.isEmpty)
                  _buildEmptyDay(cuti: cuti, isHoliday: isHoliday)
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      itemCount: rows.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (_, index) =>
                          _buildAbsensiTile(scheme, rows[index]),
                    ),
                  ),
                const SizedBox(height: 18),
                GestureDetector(
                  onTap: () => Navigator.of(ctx).pop(),
                  child: Container(
                    height: 50,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFF5A1212), Color(0xFF2B0606)],
                      ),
                    ),
                    child: const Center(
                      child: Text(
                        'Tutup',
                        style: TextStyle(
                          fontFamily: _primaryFont,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          fontVariations: [FontVariation('wght', 700)],
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildEmptyDay({
    required _DataRow? cuti,
    required bool isHoliday,
  }) {
    final String message;
    final IconData icon;

    if (cuti != null) {
      message = 'Sedang Cuti';
      icon = Icons.beach_access_rounded;
    } else if (isHoliday) {
      message = 'Hari Libur Rutin';
      icon = Icons.weekend_rounded;
    } else {
      message = 'Belum ada absensi';
      icon = Icons.event_busy_rounded;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 30),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          Icon(icon, size: 36, color: const Color(0xFFB8B0AD)),
          const SizedBox(height: 10),
          Text(
            message,
            style: const TextStyle(
              fontFamily: _secondaryFont,
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: _kTextMuted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAbsensiTile(ColorScheme scheme, _DataRow row) {
    final tipe = (row['tipe_absen'] ?? '-').toString().trim();
    final status = (row['status'] ?? '-').toString().trim();
    final waktu = _formatWaktuValue(row['waktu']);
    final (bg, fg) = _statusColors(status, scheme);
    final (iconBg, iconFg, iconData) = _tipeVisuals(tipe);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(
              iconData,
              size: 20,
              color: iconFg,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tipe.isEmpty ? '-' : tipe,
                  style: const TextStyle(
                    fontFamily: _primaryFont,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    fontVariations: [FontVariation('wght', 700)],
                    color: _kTextPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Pukul $waktu',
                  style: const TextStyle(
                    fontFamily: _secondaryFont,
                    fontSize: 11.5,
                    color: _kTextMuted,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              status.isEmpty ? '-' : status,
              style: TextStyle(
                fontFamily: _primaryFont,
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                fontVariations: [FontVariation('wght', 700)],
                color: fg,
              ),
            ),
          ),
        ],
      ),
    );
  }

  (Color, Color) _statusColors(String status, ColorScheme scheme) {
    switch (status) {
      case 'Hadir':
        return (_kHadirBg, _kHadirFg);
      case 'Terlambat':
        return (_kTelatBg, _kTelatFg);
      case 'Alpha':
        return (scheme.errorContainer, scheme.onErrorContainer);
      case 'Lembur':
        return (scheme.tertiaryContainer, scheme.onTertiaryContainer);
      default:
        return (_kCanvasBg, _kTextMuted);
    }
  }

  (Color, Color, IconData) _tipeVisuals(String tipe) {
    final lower = tipe.toLowerCase();
    if (lower.contains('pulang') || lower.contains('checkout')) {
      return (Colors.red.shade50, Colors.red.shade700, Icons.logout_rounded);
    }
    if (lower.contains('izin')) {
      return (
        Colors.blue.shade50,
        Colors.blue.shade700,
        Icons.directions_walk_rounded,
      );
    }
    if (lower.contains('istirahat')) {
      return (
        Colors.amber.shade50,
        Colors.amber.shade800,
        Icons.coffee_rounded,
      );
    }
    if (lower.contains('lembur')) {
      return (
        Colors.purple.shade50,
        Colors.purple.shade700,
        Icons.nightlight_round,
      );
    }
    return (Colors.green.shade50, Colors.green.shade700, Icons.login_rounded);
  }

  // ============================================================
  // UTILITAS
  // ============================================================

  List<_DataRow> _absensiForDate(String dateStr) {
    return _absensi
        .where((row) => (row['tanggal'] ?? '').toString() == dateStr)
        .toList();
  }

  _DataRow? _cutiForDate(String dateStr) {
    for (final row in _cutiDisetujui) {
      final start = (row['tanggal_mulai'] ?? '').toString();
      final end = (row['tanggal_selesai'] ?? '').toString();
      if (start.isEmpty || end.isEmpty) continue;
      if (dateStr.compareTo(start) >= 0 && dateStr.compareTo(end) <= 0) {
        return row;
      }
    }
    return null;
  }

  String? _jenisCuti(_DataRow? cuti) {
    if (cuti == null) return null;
    final data = cuti['data_tambahan'];
    if (data is Map) {
      for (final entry in data.entries) {
        final key = entry.key.toString().toLowerCase();
        if (key.contains('tanggal')) continue;
        if (key.contains('alasan') || key.contains('keterangan')) continue;
        final value = (entry.value ?? '').toString().trim();
        if (value.isNotEmpty) return value;
      }
    }
    return null;
  }

  String _cutiRange(_DataRow? cuti) {
    if (cuti == null) return '';
    final start = _parseDate(cuti['tanggal_mulai']);
    final end = _parseDate(cuti['tanggal_selesai']);
    if (start == null || end == null) return '';
    if (_sameDay(start, end)) return _formatTanggalPendek(start);
    return '${_formatTanggalPendek(start)} – ${_formatTanggalPendek(end)}';
  }

  String _formatWaktuValue(dynamic value) {
    final text = (value ?? '').toString().trim();
    if (text.isEmpty || text == '-') return '-';

    final parts = text.split(':');
    if (parts.length < 2) return text;

    if (_formatWaktu == 'HH:mm') {
      return '${parts[0]}:${parts[1]}';
    }
    return text.length == 5 ? '$text:00' : text;
  }

  static String _pad(int value) => value.toString().padLeft(2, '0');

  static String _formatDateApi(DateTime date) =>
      '${date.year}-${_pad(date.month)}-${_pad(date.day)}';

  static String _formatTanggalPendek(DateTime date) =>
      '${date.day} ${_kMonthLong[date.month - 1]} ${date.year}';

  static String _formatTanggalPanjang(DateTime date) =>
      '${kNamaHari[weekdayIndex(date)]}, ${date.day} '
      '${_kMonthLong[date.month - 1]} ${date.year}';

  static DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return DateTime(value.year, value.month, value.day);

    final text = value.toString().trim();
    if (text.isEmpty) return null;

    final parsed = DateTime.tryParse(text);
    if (parsed == null) return null;
    return DateTime(parsed.year, parsed.month, parsed.day);
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static int _toInt(dynamic value, [int fallback = 0]) {
    if (value == null) return fallback;
    if (value is num) return value.toInt();
    if (value is String) {
      return int.tryParse(value.trim()) ??
          double.tryParse(value.trim())?.toInt() ??
          fallback;
    }
    return fallback;
  }
}