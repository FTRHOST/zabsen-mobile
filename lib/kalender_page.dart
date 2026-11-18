import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session.dart';
import 'hari_libur.dart';

const Color _kHeading = Color(0xFF4A1010);
const Color _kHint = Color(0xFF6E6E6E);

/// Warna status pada kalender, mengikuti web referensi.
const Color _kHadirBg = Color(0xFFD6F5E0);
const Color _kHadirFg = Color(0xFF14652F);
const Color _kTelatBg = Color(0xFFFFEFC2);
const Color _kTelatFg = Color(0xFF755600);
const Color _kCutiBg = Color(0xFFFBDDE1);
const Color _kCutiFg = Color(0xFF8C2F39);

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

/// Halaman Kalender Kehadiran.
///
/// Mengikuti bagian kalender pada web referensi (`buatKalender()` di
/// `web-references-zabsen/index.html`):
/// - Grid kalender dimulai hari Minggu.
/// - Hari cuti (Disetujui) dan hari libur rutin (`users.hari_libur`) berwarna
///   merah muda.
/// - Hari dengan absensi `Hadir` berwarna hijau, `Terlambat` kuning.
/// - Hari ini ditandai.
/// - Menekan tanggal membuka **pop up detail** berisi daftar absensi
///   (Tipe, Waktu, Status) atau keterangan "Sedang Cuti"/"Hari Libur Rutin".
///
/// Ditambahkan navigasi bulan sebelumnya/berikutnya agar nyaman di mobile.
class KalenderPage extends StatefulWidget {
  const KalenderPage({super.key});

  @override
  State<KalenderPage> createState() => KalenderPageState();
}

class KalenderPageState extends State<KalenderPage> {
  final SupabaseClient _supabase = Supabase.instance.client;

  int? _userId;

  List<Map<String, dynamic>> _absensi = [];
  List<Map<String, dynamic>> _cutiDisetujui = [];

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
          _loadError = 'Data pengguna tidak ditemukan. Silakan logout lalu login kembali.';
        });
        return;
      }

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
          ? Map<String, dynamic>.from(results[2] as Map)
          : <String, dynamic>{};

      if (!mounted) return;

      setState(() {
        _userId = userId;
        _hariLibur = parseHariLibur(user['hari_libur']);
        _absensi = absensiRows
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .toList();
        _cutiDisetujui = cutiRows
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
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
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
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

  // ============================================================
  // UI
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (_isLoading) {
      return Center(child: CircularProgressIndicator(color: scheme.primary));
    }

    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.cloud_off_rounded, size: 56, color: scheme.outline),
              const SizedBox(height: 12),
              const Text(
                'Kalender belum dapat dimuat',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                _loadError!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  color: _kHint,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: reload,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Coba Lagi'),
                style: FilledButton.styleFrom(minimumSize: const Size(160, 46)),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      color: scheme.primary,
      onRefresh: () => reload(showLoading: false),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
        children: [
          const Text(
            'Kalender',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w900,
              color: _kHeading,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Statistik kehadiran & detail absensi harian',
            style: TextStyle(
              fontSize: 13,
              color: _kHint,
              fontWeight: FontWeight.w500,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 20),
          _buildCalendarCard(scheme),
          const SizedBox(height: 24),
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

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.7),
          width: 1.2,
        ),
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
          Row(
            children: [
              IconButton.filledTonal(
                onPressed: _isLoadingAbsensi ? null : () => _changeMonth(-1),
                icon: const Icon(Icons.chevron_left_rounded),
                tooltip: 'Bulan sebelumnya',
                visualDensity: VisualDensity.compact,
              ),
              Expanded(
                child: Column(
                  children: [
                    Text(
                      '${_kMonthLong[_visibleMonth.month - 1]} ${_visibleMonth.year}',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _isLoadingAbsensi
                          ? 'Memuat absensi...'
                          : '${_absensi.length} catatan absensi',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton.filledTonal(
                onPressed: _isLoadingAbsensi ? null : () => _changeMonth(1),
                icon: const Icon(Icons.chevron_right_rounded),
                tooltip: 'Bulan berikutnya',
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              for (var index = 0; index < _kDayShort.length; index++)
                Expanded(
                  child: Center(
                    child: Text(
                      _kDayShort[index],
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: index == 0
                            ? scheme.error
                            : index == 6
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (_isLoadingAbsensi)
            SizedBox(
              height: 240,
              child: Center(
                child: CircularProgressIndicator(color: scheme.primary),
              ),
            )
          else
            GridView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 7,
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
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
          if (!isCurrentMonth) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _isLoadingAbsensi ? null : _goToCurrentMonth,
                icon: const Icon(Icons.today_rounded, size: 16),
                label: const Text('Bulan ini'),
                style: TextButton.styleFrom(
                  foregroundColor: scheme.primary,
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Divider(
            height: 1,
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 12),
          _buildLegend(scheme),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(
                Icons.touch_app_rounded,
                size: 14,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Ketuk tanggal untuk melihat detail absensi.',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
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

    Color background = Colors.transparent;
    Color foreground = scheme.onSurface;
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
              ? BorderSide(color: scheme.primary, width: 2)
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
                fontSize: 13,
                fontWeight: isToday ? FontWeight.w800 : FontWeight.w600,
                color: isToday && background == Colors.transparent
                    ? scheme.primary
                    : foreground,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLegend(ColorScheme scheme) {
    return Wrap(
      spacing: 14,
      runSpacing: 8,
      children: [
        _legendItem(scheme, _kHadirBg, 'Hadir'),
        _legendItem(scheme, _kTelatBg, 'Terlambat'),
        _legendItem(scheme, _kCutiBg, 'Cuti / Libur'),
        _legendItem(scheme, scheme.errorContainer, 'Alpha'),
        _legendItem(scheme, scheme.tertiaryContainer, 'Lembur'),
        _legendTodayItem(scheme),
      ],
    );
  }

  Widget _legendItem(ColorScheme scheme, Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _legendTodayItem(ColorScheme scheme) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: scheme.primary, width: 2),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          'Hari ini',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: scheme.onSurfaceVariant,
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
    required List<Map<String, dynamic>> rows,
    required Map<String, dynamic>? cuti,
    required bool isHoliday,
  }) {
    final scheme = Theme.of(context).colorScheme;

    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: scheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) {
        final sheetScheme = Theme.of(ctx).colorScheme;
        final cutiRange = _cutiRange(cuti);
        final jenisCuti = _jenisCuti(cuti);

        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.82,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: sheetScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        Icons.event_note_rounded,
                        size: 20,
                        color: sheetScheme.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _formatTanggalPanjang(date),
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              color: sheetScheme.onSurface,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            rows.isEmpty
                                ? 'Tidak ada catatan absensi'
                                : '${rows.length} catatan absensi',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: sheetScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (cuti != null) ...[
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: _kCutiBg,
                      borderRadius: BorderRadius.circular(16),
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
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  color: _kCutiFg,
                                ),
                              ),
                              if (cutiRange.isNotEmpty) ...[
                                const SizedBox(height: 3),
                                Text(
                                  cutiRange,
                                  style: TextStyle(
                                    fontSize: 11,
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
                  _buildEmptyDay(sheetScheme, cuti: cuti, isHoliday: isHoliday)
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      itemCount: rows.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (_, index) =>
                          _buildAbsensiTile(sheetScheme, rows[index]),
                    ),
                  ),
                const SizedBox(height: 18),
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    backgroundColor: _kHeading,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  child: const Text('Tutup'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildEmptyDay(
    ColorScheme scheme, {
    required Map<String, dynamic>? cuti,
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 28),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.7)),
      ),
      child: Column(
        children: [
          Icon(icon, size: 36, color: scheme.outline),
          const SizedBox(height: 10),
          Text(
            message,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAbsensiTile(ColorScheme scheme, Map<String, dynamic> row) {
    final tipe = (row['tipe_absen'] ?? '-').toString().trim();
    final status = (row['status'] ?? '-').toString().trim();
    final waktu = _formatWaktuValue(row['waktu']);
    final (bg, fg) = _statusColors(status, scheme);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.7)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: scheme.secondaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              _tipeIcon(tipe),
              size: 18,
              color: scheme.onSecondaryContainer,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tipe.isEmpty ? '-' : tipe,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Icon(
                      Icons.schedule_rounded,
                      size: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Pukul $waktu',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              status.isEmpty ? '-' : status,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
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
        return (scheme.surfaceContainerHighest, scheme.onSurfaceVariant);
    }
  }

  IconData _tipeIcon(String tipe) {
    final lower = tipe.toLowerCase();
    if (lower.contains('pulang')) return Icons.logout_rounded;
    if (lower.contains('izin')) return Icons.assignment_outlined;
    if (lower.contains('istirahat')) return Icons.free_breakfast_rounded;
    if (lower.contains('lembur')) return Icons.nightlight_round;
    return Icons.login_rounded;
  }

  // ============================================================
  // UTILITAS
  // ============================================================

  List<Map<String, dynamic>> _absensiForDate(String dateStr) {
    return _absensi
        .where((row) => (row['tanggal'] ?? '').toString() == dateStr)
        .toList();
  }

  Map<String, dynamic>? _cutiForDate(String dateStr) {
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

  String? _jenisCuti(Map<String, dynamic>? cuti) {
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

  String _cutiRange(Map<String, dynamic>? cuti) {
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
