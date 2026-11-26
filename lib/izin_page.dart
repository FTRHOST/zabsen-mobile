import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_config.dart';
import 'auth_session.dart';
import 'hari_libur.dart';
import 'session_actions.dart';

typedef _DataMap = Map<String, dynamic>;

/// Bucket penyimpanan lampiran, sama dengan web referensi
/// (`supabase.storage.from("absensi-bucket")`).
const String _kStorageBucket = 'absensi-bucket';

// Font utama & sekunder yang selaras dengan AbsenPage & KalenderPage
const String _primaryFont = 'Google Sans Flex';
const String _secondaryFont = 'Inter';

// Palet warna utama Zieda Absen
const Color _kCanvasBg = Color(0xFFF7F5F4);
const Color _kMaroonDeep = Color(0xFF330808);
const Color _kBurgundy = Color(0xFF5E1212);
const Color _kTerracotta = Color(0xFF8F382B);
const Color _kTextPrimary = Color(0xFF1E1E1E);
const Color _kTextMuted = Color(0xFF6E6E6E);

const List<String> _kMonthShort = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'Mei',
  'Jun',
  'Jul',
  'Ags',
  'Sep',
  'Okt',
  'Nov',
  'Des',
];

/// Halaman Izin & Cuti dengan Hero Gradient Header & Overlapping Card
/// yang selaras dengan AbsenPage dan KalenderPage.
class IzinPage extends StatefulWidget {
  const IzinPage({
    super.key,
    this.isAdmin = false,
    this.onOpenAdmin,
    this.onLogout,
  });

  final bool isAdmin;
  final VoidCallback? onOpenAdmin;
  final VoidCallback? onLogout;

  @override
  State<IzinPage> createState() => IzinPageState();
}

class IzinPageState extends State<IzinPage> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  _DataMap? _user;
  bool _isAdminUser = false;

  List<_FieldConfig> _configs = [];
  List<_DataMap> _masterCuti = [];
  Map<String, _SisaCutiInfo> _sisaCuti = {};
  List<_DataMap> _riwayat = [];

  final Map<String, TextEditingController> _textControllers = {};
  final Map<String, String> _selectedValues = {};
  final Map<String, DateTime> _selectedDates = {};
  final Map<String, PlatformFile> _selectedFiles = {};

  bool _isLoading = true;
  bool _isSubmitting = false;
  String? _loadError;

  /// Dipakai untuk membangun ulang [Form] setelah reset.
  int _formVersion = 0;

  SupabaseClient get _supabase => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _isAdminUser = widget.isAdmin;
    reload();
  }

  @override
  void dispose() {
    for (final controller in _textControllers.values) {
      controller.dispose();
    }
    super.dispose();
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
          _user = null;
          _isLoading = false;
          _loadError =
              'Data pengguna tidak ditemukan. Silakan logout lalu login kembali.';
        });
        return;
      }

      final role = (user['role'] ?? '').toString().trim().toLowerCase();
      final isAdminDetected =
          widget.isAdmin || role == 'hr' || role == 'super admin';

      final results = await Future.wait<dynamic>([
        _supabase
            .from('form_cuti_config')
            .select('*')
            .order('urutan', ascending: true),
        _supabase.from('master_jenis_cuti').select('*'),
        _supabase
            .from('cuti')
            .select('*')
            .eq('user_id', userId)
            .order('id', ascending: false),
      ]);

      final configRows = results[0] is List ? results[0] as List : const [];
      final masterRows = results[1] is List ? results[1] as List : const [];
      final cutiRows = results[2] is List ? results[2] as List : const [];

      final configs = configRows
          .whereType()
          .map((row) => _FieldConfig.fromMap(_DataMap.from(row)))
          .where((config) => config.label.isNotEmpty)
          .toList();

      final masters = masterRows
          .whereType()
          .map((row) => _DataMap.from(row))
          .toList();

      final riwayat = cutiRows
          .whereType()
          .map((row) => _DataMap.from(row))
          .toList();

      if (!mounted) return;

      setState(() {
        _user = _DataMap.from(user);
        _isAdminUser = isAdminDetected;
        _configs = configs;
        _masterCuti = masters;
        _riwayat = riwayat;
        _sisaCuti = _hitungSisaCuti(masters, riwayat);
        _isLoading = false;
        _syncControllers();
      });
    } catch (e) {
      debugPrint('Gagal memuat data izin/cuti: $e');
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _loadError =
            'Gagal memuat data cuti. Periksa koneksi lalu coba lagi.\n\n$e';
      });
    }
  }

  Map<String, _SisaCutiInfo> _hitungSisaCuti(
    List<_DataMap> masters,
    List<_DataMap> riwayat,
  ) {
    final usedRows = riwayat.where((row) {
      final status = (row['status_pengajuan'] ?? '').toString().trim();
      return status == 'Disetujui' || status == 'Menunggu';
    }).toList();

    final now = DateTime.now();
    final currentYear = now.year.toString();
    final currentMonth = '${now.year}-${_pad(now.month)}';

    final result = <String, _SisaCutiInfo>{};

    for (final master in masters) {
      final nama = (master['nama_cuti'] ?? '').toString().trim();
      if (nama.isEmpty) continue;

      final unlimited = master['is_unlimited'] == true;
      final batas = _toInt(master['batas_hari'], 0);
      final siklus = (master['siklus'] ?? 'Tahunan').toString();
      final siklusLower = siklus.toLowerCase();

      var terpakai = 0;
      for (final row in usedRows) {
        final dataTambahan = _asMap(row['data_tambahan']);
        final milikMaster = dataTambahan.values.any(
          (value) => (value ?? '').toString() == nama,
        );
        if (!milikMaster) continue;

        final tanggalMulai = (row['tanggal_mulai'] ?? '').toString();
        final durasi = _toInt(row['durasi_hari'], 0);

        if (siklusLower == 'tahunan' && tanggalMulai.startsWith(currentYear)) {
          terpakai += durasi;
        } else if (siklusLower == 'bulanan' &&
            tanggalMulai.startsWith(currentMonth)) {
          terpakai += durasi;
        } else if (siklusLower == 'sekali') {
          terpakai += durasi;
        }
      }

      result[nama] = _SisaCutiInfo(
        nama: nama,
        unlimited: unlimited,
        batas: batas,
        terpakai: terpakai,
        siklus: siklus,
      );
    }

    return result;
  }

  void _syncControllers() {
    final configIds = _configs
        .where((config) => config.tipe == 'date' || config.tipe == 'keterangan')
        .map((config) => config.id)
        .toSet();

    for (final id in configIds) {
      _textControllers.putIfAbsent(id, TextEditingController.new);
    }

    for (final id in _textControllers.keys.toList()) {
      if (!configIds.contains(id)) {
        _textControllers.remove(id)?.dispose();
      }
    }
  }

  // ============================================================
  // FORM DINAMIS
  // ============================================================

  String _fieldValue(_FieldConfig config) {
    switch (config.tipe) {
      case 'date':
        final date = _selectedDates[config.id];
        return date == null ? '' : _formatDateApi(date);
      case 'dropdown':
      case 'master_cuti':
        return _selectedValues[config.id] ?? '';
      case 'file':
        return _selectedFiles[config.id]?.name ?? '';
      default:
        return _textControllers[config.id]?.text.trim() ?? '';
    }
  }

  bool _isVisible(_FieldConfig config) {
    if (config.tipe == 'dropdown') return true;

    final dependency = config.opsi.trim();
    if (!dependency.contains('=') && !dependency.contains('!=')) return true;

    final notEqual = dependency.contains('!=');
    final parts = dependency.split(notEqual ? '!=' : '=');
    if (parts.length < 2) return true;

    final requiredLabel = parts[0].trim().toLowerCase();
    final expected = parts[1]
        .split('|')
        .map((value) => value.trim().toLowerCase())
        .toList();

    _FieldConfig? source;
    for (final candidate in _configs) {
      if (candidate.label.trim().toLowerCase() == requiredLabel) {
        source = candidate;
        break;
      }
    }
    if (source == null) return true;

    final actual = _fieldValue(source).toLowerCase();

    if (notEqual) {
      return actual.isNotEmpty && !expected.contains(actual);
    }
    return expected.contains(actual);
  }

  void _pruneHiddenFields() {
    for (final config in _configs) {
      if (_isVisible(config)) continue;
      _selectedValues.remove(config.id);
      _selectedDates.remove(config.id);
      _selectedFiles.remove(config.id);
      _textControllers[config.id]?.clear();
    }
  }

  void _onFormChanged() {
    if (!mounted) return;
    setState(_pruneHiddenFields);
  }

  List<String> _optionsFor(_FieldConfig config) {
    if (config.tipe == 'master_cuti') {
      return _masterCuti
          .map((master) => (master['nama_cuti'] ?? '').toString().trim())
          .where((nama) => nama.isNotEmpty)
          .toList();
    }

    return config.opsi
        .split(',')
        .map((option) => option.trim())
        .where((option) => option.isNotEmpty)
        .toList();
  }

  Future<void> _pickDate(_FieldConfig config) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDates[config.id] ?? now,
      firstDate: DateTime(now.year - 3),
      lastDate: DateTime(now.year + 3),
      helpText: config.label,
      cancelText: 'Batal',
      confirmText: 'Pilih',
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(context).colorScheme.copyWith(
                  primary: _kBurgundy,
                  onPrimary: Colors.white,
                  surface: Colors.white,
                ),
          ),
          child: child!,
        );
      },
    );

    if (picked == null || !mounted) return;

    setState(() {
      _selectedDates[config.id] = picked;
      _textControllers[config.id]?.text = _formatDateDisplay(picked);
      _pruneHiddenFields();
    });
  }

  Future<PlatformFile?> _pickFile(_FieldConfig config) async {
    try {
      final file = await FilePicker.pickFile(dialogTitle: config.label);
      if (file == null) return null;

      final maxBytes = 10 * 1024 * 1024;
      final length = file.lengthSync() ?? await file.length();
      if (length != null && length > maxBytes) {
        if (mounted) {
          await _showMessage(
            'Lampiran Terlalu Besar',
            'Ukuran lampiran maksimal 10 MB.',
            isError: true,
          );
        }
        return null;
      }

      return file;
    } catch (e) {
      debugPrint('Gagal memilih file: $e');
      if (mounted) {
        await _showMessage(
          'Gagal Memilih File',
          'Tidak dapat membuka pemilih file: $e',
          isError: true,
        );
      }
      return null;
    }
  }

  Future<String> _uploadFile(PlatformFile file) async {
    final bytes = await file.readAsBytes();
    final millis = DateTime.now().millisecondsSinceEpoch;
    final safeName = file.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final path = 'cuti-$millis-$safeName';

    await _supabase.storage.from(_kStorageBucket).uploadBinary(path, bytes);
    return _supabase.storage.from(_kStorageBucket).getPublicUrl(path);
  }

  // ============================================================
  // SUBMIT
  // ============================================================

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();

    if (!(_formKey.currentState?.validate() ?? false)) return;

    final user = _user;
    final userId = _toInt(user?['id'], 0);
    if (user == null || userId <= 0) {
      await _showMessage(
        'Gagal',
        'Data pengguna tidak ditemukan. Silakan login kembali.',
        isError: true,
      );
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      final dataTambahan = _DataMap();
      String? tanggalMulai;
      String? tanggalSelesai;
      String alasan = '-';
      String? jenisCuti;
      final firstDateValue = <String>[];

      for (final config in _configs.where(_isVisible)) {
        dynamic value = '';

        if (config.tipe == 'date') {
          final date = _selectedDates[config.id];
          value = date == null ? '' : _formatDateApi(date);
          if (value.toString().isNotEmpty) firstDateValue.add(value.toString());
        } else if (config.tipe == 'file') {
          final file = _selectedFiles[config.id];
          if (file != null) {
            try {
              value = await _uploadFile(file);
            } catch (e) {
              debugPrint('Gagal upload lampiran cuti: $e');
              if (!mounted) return;
              await _showMessage(
                'Gagal Unggah Lampiran',
                'Lampiran "${file.name}" gagal diunggah. Silakan coba lagi.',
                isError: true,
              );
              return;
            }
          }
        } else if (config.tipe == 'dropdown' || config.tipe == 'master_cuti') {
          value = _selectedValues[config.id] ?? '';
        } else {
          value = _textControllers[config.id]?.text.trim() ?? '';
        }

        dataTambahan[config.label] = value;

        final label = config.label.toLowerCase();

        if (config.tipe == 'date' && value.toString().isNotEmpty) {
          if (label.contains('selesai') || label.contains('akhir')) {
            tanggalSelesai = value.toString();
          } else if (label.contains('mulai')) {
            tanggalMulai = value.toString();
          }

          if (tanggalMulai == null || tanggalMulai.isEmpty) {
            tanggalMulai = value.toString();
          }
        }

        if ((config.tipe == 'dropdown' || config.tipe == 'master_cuti') &&
            label.contains('jenis')) {
          jenisCuti = value.toString();
        }

        if (config.tipe == 'keterangan' &&
            (label.contains('alasan') || label.contains('keterangan')) &&
            value.toString().trim().isNotEmpty) {
          alasan = value.toString().trim();
        }
      }

      if (firstDateValue.isNotEmpty && tanggalSelesai == null) {
        tanggalSelesai = firstDateValue.first;
      }

      final now = DateTime.now();
      var start = _parseDate(tanggalMulai);
      var end = _parseDate(tanggalSelesai);

      final hasDateValue = tanggalMulai != null || tanggalSelesai != null;
      start ??= DateTime(now.year, now.month, now.day);
      end ??= start;

      if (end.isBefore(start)) {
        await _showMessage(
          'Tanggal Tidak Valid',
          'Tanggal selesai tidak boleh sebelum tanggal mulai.',
          isError: true,
        );
        return;
      }

      var durasiHari = 1;
      if (hasDateValue) {
        final holidayDays = parseHariLibur(user['hari_libur']);
        durasiHari = 0;
        for (
          var day = DateTime(start.year, start.month, start.day);
          !day.isAfter(end);
          day = day.add(const Duration(days: 1))
        ) {
          if (!holidayDays.contains(day.weekday % 7)) {
            durasiHari++;
          }
        }

        if (durasiHari == 0) {
          await _showMessage(
            'Durasi 0 Hari',
            'Seluruh tanggal yang dipilih adalah hari libur rutin Anda. '
                'Silakan pilih tanggal lain.',
            isError: true,
          );
          return;
        }
      }

      final isOverlap = _riwayat.any((row) {
        final status = (row['status_pengajuan'] ?? '').toString().trim();
        if (status != 'Disetujui' && status != 'Menunggu') return false;

        final existingStart = _parseDate(row['tanggal_mulai']);
        final existingEnd = _parseDate(row['tanggal_selesai']);
        if (existingStart == null || existingEnd == null) return false;

        return !start!.isAfter(existingEnd) && !end!.isBefore(existingStart);
      });

      if (isOverlap) {
        await _showMessage(
          'Tanggal Bentrok',
          'Anda sudah memiliki pengajuan cuti (Disetujui/Menunggu) pada '
              'rentang tanggal tersebut. Silakan pilih tanggal lain.',
          isError: true,
        );
        return;
      }

      String? namaCutiTerpilih;
      _SisaCutiInfo? infoCuti;
      for (final value in dataTambahan.values) {
        final key = (value ?? '').toString();
        final match = _sisaCuti[key];
        if (match != null) {
          namaCutiTerpilih = key;
          infoCuti = match;
          break;
        }
      }

      if (infoCuti != null && !infoCuti.unlimited) {
        if (infoCuti.sisa <= 0) {
          await _showMessage(
            'Kuota Habis',
            'Sisa jatah $namaCutiTerpilih Anda sudah habis.',
            isError: true,
          );
          return;
        }
        if (durasiHari > infoCuti.sisa) {
          await _showMessage(
            'Melebihi Kuota',
            'Durasi pengajuan ($durasiHari hari) melebihi sisa '
                '$namaCutiTerpilih Anda (${infoCuti.sisa} hari).',
            isError: true,
          );
          return;
        }
      }

      dataTambahan['Tanggal_Pengajuan_Sistem'] = _formatDateApi(now);

      await _supabase.from('cuti').insert({
        'user_id': userId,
        'tanggal_mulai': _formatDateApi(start),
        'tanggal_selesai': _formatDateApi(end),
        'alasan': alasan,
        'durasi_hari': durasiHari,
        'status_pengajuan': 'Menunggu',
        'data_tambahan': dataTambahan,
      });

      final jenisTeks =
          (namaCutiTerpilih != null && namaCutiTerpilih.isNotEmpty)
              ? namaCutiTerpilih
              : (jenisCuti != null && jenisCuti.isNotEmpty
                  ? jenisCuti
                  : 'Lainnya');

      unawaited(
        _sendTelegramNotification(
          '<b>Pengajuan Cuti/Izin/Sakit</b>\n'
          'Nama: ${user['nama'] ?? '-'}\n'
          'Cabang: ${user['cabang'] ?? '-'}\n'
          'Jenis: $jenisTeks\n'
          'Durasi: $durasiHari Hari '
          '(${_formatDateApi(start)} s/d ${_formatDateApi(end)})\n'
          'Alasan: $alasan',
        ),
      );

      if (!mounted) return;

      await _showMessage(
        'Berhasil',
        'Pengajuan berhasil dikirim ke HRD untuk ditinjau.',
      );

      if (!mounted) return;
      _resetForm();
      await reload(showLoading: false);
    } catch (e) {
      debugPrint('Gagal mengirim pengajuan cuti: $e');
      if (!mounted) return;
      await _showMessage(
        'Gagal Mengirim',
        'Pengajuan tidak dapat dikirim: $e',
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  void _resetForm() {
    _formKey.currentState?.reset();
    for (final controller in _textControllers.values) {
      controller.clear();
    }
    setState(() {
      _selectedValues.clear();
      _selectedDates.clear();
      _selectedFiles.clear();
      _formVersion++;
    });
  }

  Future<void> _sendTelegramNotification(String message) async {
    final chatId = kTelegramChatId.trim();
    if (chatId.isEmpty) return;

    try {
      await _supabase.functions.invoke(
        'telegram-notif',
        body: {'message': message, 'chat_id': chatId},
      );
    } catch (e) {
      debugPrint('Notifikasi Telegram gagal dikirim: $e');
    }
  }

  Future<void> _batalkanPengajuan(_DataMap row) async {
    final scheme = Theme.of(context).colorScheme;
    final id = row['id'];
    if (id == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        backgroundColor: Colors.white,
        icon: Icon(Icons.delete_outline_rounded, color: scheme.error, size: 30),
        title: const Text(
          'Batalkan Pengajuan?',
          style: TextStyle(
            fontFamily: _primaryFont,
            fontSize: 17,
            fontWeight: FontWeight.w800,
            fontVariations: [FontVariation('wght', 800)],
            color: _kTextPrimary,
          ),
        ),
        content: const Text(
          'Pengajuan cuti/izin ini akan dihapus dan tidak dapat dikembalikan.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: _secondaryFont,
            fontSize: 13.5,
            color: _kTextMuted,
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(
              'Tidak',
              style: TextStyle(
                fontFamily: _primaryFont,
                fontWeight: FontWeight.w700,
                fontVariations: [FontVariation('wght', 700)],
                color: _kTextMuted,
              ),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: const Text(
              'Batalkan',
              style: TextStyle(
                fontFamily: _primaryFont,
                fontWeight: FontWeight.w700,
                fontVariations: [FontVariation('wght', 700)],
              ),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await _supabase.from('cuti').delete().eq('id', id);
      if (!mounted) return;

      Navigator.of(context, rootNavigator: true).pop();
      await reload(showLoading: false);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Pengajuan berhasil dibatalkan.',
            style: TextStyle(fontFamily: _secondaryFont),
          ),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
    } catch (e) {
      debugPrint('Gagal membatalkan cuti: $e');
      if (!mounted) return;
      await _showMessage(
        'Gagal Membatalkan',
        'Pengajuan tidak dapat dibatalkan: $e',
        isError: true,
      );
    }
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
                  fontVariations: [FontVariation('wght', 600)],
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
              // LAYER BACKGROUND GRADASI HEADER (IDENTIK DENGAN ABSEN & KALENDER)
              // ==========================================================
              Container(
                height: 212 + topSafePadding,
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
                  topSafePadding + 14.0,
                  22.0,
                  28.0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 1. TOP BAR: Tulisan ZIEDA ABSEN murni tanpa box/lingkaran
                    SizedBox(
                      height: 30,
                      child: Row(
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
                            text: 'Pengajuan ',
                            style: TextStyle(
                              fontFamily: _secondaryFont,
                              fontWeight: FontWeight.w400,
                              color: Colors.white.withValues(alpha: 0.86),
                            ),
                          ),
                          const TextSpan(
                            text: 'Izin & Cuti',
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
                      'Kelola permohonan cuti, izin, & sakit sesuai HRD',
                      style: TextStyle(
                        fontFamily: _secondaryFont,
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                        color: Colors.white.withValues(alpha: 0.80),
                      ),
                    ),

                    const SizedBox(height: 22),

                    // 3. OVERLAPPING HERO CARD: AKSES SISA CUTI & RIWAYAT
                    _buildOverlappingQuickCard(),

                    const SizedBox(height: 22),

                    // 4. KONTEN FORMULIR / LOADING / ERROR
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
                      _buildFormSection(scheme),
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
  Widget _buildOverlappingQuickCard() {
    final menungguCount = _riwayat
        .where((r) =>
            (r['status_pengajuan'] ?? '').toString().trim() == 'Menunggu')
        .length;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 20.0, horizontal: 22.0),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Ringkasan Kuota & Pengajuan',
            style: TextStyle(
              fontFamily: _secondaryFont,
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
              color: Colors.grey.shade500,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              // Tombol Sisa Cuti
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: _isLoading ? null : _showSisaCutiSheet,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFFCE4E6).withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: _kBurgundy,
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: const Icon(
                        Icons.confirmation_number_outlined,
                        size: 18,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Sisa Cuti',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: _primaryFont,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w800,
                              fontVariations: [FontVariation('wght', 800)],
                              color: _kMaroonDeep,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            _isLoading
                                ? 'Memuat...'
                                : '${_masterCuti.length} jenis kuota',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: _secondaryFont,
                              fontSize: 11,
                              color: _kTextMuted,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          const SizedBox(width: 10),

          // Tombol Riwayat Pengajuan
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: _isLoading ? null : _showRiwayatSheet,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: _kCanvasBg,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: const Icon(
                        Icons.history_rounded,
                        size: 19,
                        color: _kBurgundy,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Riwayat',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: _primaryFont,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w800,
                              fontVariations: [FontVariation('wght', 800)],
                              color: _kTextPrimary,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            _isLoading
                                ? 'Memuat...'
                                : menungguCount > 0
                                    ? '$menungguCount menunggu'
                                    : '${_riwayat.length} pengajuan',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: _secondaryFont,
                              fontSize: 11,
                              fontWeight: menungguCount > 0
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: menungguCount > 0
                                  ? const Color(0xFF7A5900)
                                  : _kTextMuted,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
            ],
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
            'Data belum dapat dimuat',
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

  Widget _buildFormSection(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section Header (Senada dengan "Lokasi Presensi" di AbsenPage)
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Formulir Pengajuan',
              style: TextStyle(
                fontFamily: _primaryFont,
                fontSize: 16,
                fontWeight: FontWeight.w700,
                fontVariations: [FontVariation('wght', 700)],
                color: _kTextPrimary,
                letterSpacing: -0.2,
              ),
            ),
            GestureDetector(
              onTap: () => reload(showLoading: false),
              child: const Text(
                'Muat Ulang',
                style: TextStyle(
                  fontFamily: _primaryFont,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  fontVariations: [FontVariation('wght', 700)],
                  color: _kBurgundy,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // Kartu Putih Bersih Form Dinamis
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20.0),
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
          child: _configs.isEmpty
              ? _buildInfoBox(
                  Icons.info_outline_rounded,
                  'Formulir cuti belum dikonfigurasi. Hubungi Admin/HRD.',
                )
              : KeyedSubtree(
                  key: ValueKey(_formVersion),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final config in _configs)
                          if (_isVisible(config)) ...[
                            _buildField(config, scheme),
                            const SizedBox(height: 16),
                          ],
                        const SizedBox(height: 6),
                        GestureDetector(
                          onTap: _isSubmitting ? null : _submit,
                          child: Container(
                            height: 54,
                            width: double.infinity,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(18),
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: _isSubmitting
                                    ? [
                                        const Color(0xFF5A1212)
                                            .withValues(alpha: 0.55),
                                        const Color(0xFF2B0606)
                                            .withValues(alpha: 0.55),
                                      ]
                                    : const [
                                        Color(0xFF5A1212),
                                        Color(0xFF2B0606),
                                      ],
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF3A0A0A)
                                      .withValues(alpha: 0.28),
                                  blurRadius: 14,
                                  offset: const Offset(0, 5),
                                ),
                              ],
                            ),
                            child: Center(
                              child: _isSubmitting
                                  ? const SizedBox(
                                      height: 20,
                                      width: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.4,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Text(
                                      'Kirim Pengajuan',
                                      style: TextStyle(
                                        fontFamily: _primaryFont,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w700,
                                        fontVariations: [
                                          FontVariation('wght', 700),
                                        ],
                                        color: Colors.white,
                                        letterSpacing: 0.2,
                                      ),
                                    ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildField(_FieldConfig config, ColorScheme scheme) {
    switch (config.tipe) {
      case 'date':
        return _buildDateField(config, scheme);
      case 'dropdown':
      case 'master_cuti':
        return _buildChoiceField(config, scheme);
      case 'file':
        return _buildFileField(config, scheme);
      case 'keterangan':
        return _buildTextField(config, scheme);
      default:
        return _buildTextField(config, scheme);
    }
  }

  Widget _buildFieldLabel(_FieldConfig config, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 8),
      child: RichText(
        text: TextSpan(
          text: config.label,
          style: const TextStyle(
            fontFamily: _primaryFont,
            fontSize: 13,
            fontWeight: FontWeight.w700,
            fontVariations: [FontVariation('wght', 700)],
            color: _kTextPrimary,
            letterSpacing: -0.1,
          ),
          children: [
            if (config.wajib)
              TextSpan(
                text: ' *',
                style: TextStyle(
                  color: scheme.error,
                  fontWeight: FontWeight.w800,
                ),
              ),
          ],
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(
    ColorScheme scheme, {
    required String hint,
    Widget? suffixIcon,
    Widget? prefixIcon,
  }) {
    final radius = BorderRadius.circular(16);

    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(
        fontFamily: _secondaryFont,
        fontSize: 13.5,
        color: _kTextMuted,
      ),
      suffixIcon: suffixIcon,
      prefixIcon: prefixIcon,
      filled: true,
      fillColor: _kCanvasBg,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      border: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: const BorderSide(color: _kBurgundy, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: scheme.error, width: 1.2),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: scheme.error, width: 1.5),
      ),
      errorStyle: TextStyle(
        fontFamily: _secondaryFont,
        fontSize: 11.5,
        color: scheme.error,
      ),
    );
  }

  Widget _buildTextField(_FieldConfig config, ColorScheme scheme) {
    return Column(
      key: ValueKey('field-${config.id}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildFieldLabel(config, scheme),
        TextFormField(
          controller: _textControllers[config.id],
          minLines: 3,
          maxLines: 5,
          textCapitalization: TextCapitalization.sentences,
          style: const TextStyle(
            fontFamily: _secondaryFont,
            fontSize: 14,
            color: _kTextPrimary,
          ),
          decoration: _inputDecoration(
            scheme,
            hint: 'Tulis ${config.label.toLowerCase()}',
          ),
          onChanged: (_) => _onFormChanged(),
          validator: (value) {
            if (!config.wajib) return null;
            if (value == null || value.trim().isEmpty) {
              return '${config.label} wajib diisi';
            }
            return null;
          },
        ),
      ],
    );
  }

  Widget _buildDateField(_FieldConfig config, ColorScheme scheme) {
    return Column(
      key: ValueKey('field-${config.id}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildFieldLabel(config, scheme),
        TextFormField(
          controller: _textControllers[config.id],
          readOnly: true,
          onTap: () => _pickDate(config),
          style: const TextStyle(
            fontFamily: _primaryFont,
            fontSize: 14,
            fontWeight: FontWeight.w600,
            fontVariations: [FontVariation('wght', 600)],
            color: _kTextPrimary,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
          decoration: _inputDecoration(
            scheme,
            hint: 'Pilih ${config.label.toLowerCase()}',
            suffixIcon: const Icon(
              Icons.calendar_month_rounded,
              size: 20,
              color: _kBurgundy,
            ),
          ),
          validator: (_) {
            if (!config.wajib) return null;
            return _selectedDates[config.id] == null
                ? '${config.label} wajib diisi'
                : null;
          },
        ),
      ],
    );
  }

  Widget _buildChoiceField(_FieldConfig config, ColorScheme scheme) {
    final options = _optionsFor(config);
    final currentValue = _selectedValues[config.id];
    final validValue = currentValue != null && options.contains(currentValue)
        ? currentValue
        : null;

    return Column(
      key: ValueKey('field-${config.id}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildFieldLabel(config, scheme),
        if (options.isEmpty)
          _buildInfoBox(
            Icons.list_alt_rounded,
            config.tipe == 'master_cuti'
                ? 'Belum ada master jenis cuti dari HRD.'
                : 'Belum ada pilihan untuk ${config.label}.',
          )
        else
          DropdownButtonFormField<String>(
            initialValue: validValue,
            isExpanded: true,
            style: const TextStyle(
              fontFamily: _primaryFont,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              fontVariations: [FontVariation('wght', 600)],
              color: _kTextPrimary,
            ),
            icon: const Icon(
              Icons.keyboard_arrow_down_rounded,
              color: _kBurgundy,
            ),
            decoration: _inputDecoration(
              scheme,
              hint: 'Pilih ${config.label.toLowerCase()}',
            ),
            dropdownColor: Colors.white,
            borderRadius: BorderRadius.circular(16),
            items: options
                .map(
                  (option) => DropdownMenuItem<String>(
                    value: option,
                    child: Text(option, overflow: TextOverflow.ellipsis),
                  ),
                )
                .toList(),
            onChanged: (value) {
              setState(() {
                if (value == null || value.isEmpty) {
                  _selectedValues.remove(config.id);
                } else {
                  _selectedValues[config.id] = value;
                }
                _pruneHiddenFields();
              });
            },
            validator: (value) {
              if (!config.wajib) return null;
              if (value == null || value.isEmpty) {
                return '${config.label} wajib dipilih';
              }
              return null;
            },
          ),
      ],
    );
  }

  Widget _buildFileField(_FieldConfig config, ColorScheme scheme) {
    return Column(
      key: ValueKey('field-${config.id}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildFieldLabel(config, scheme),
        FormField<PlatformFile>(
          initialValue: _selectedFiles[config.id],
          validator: (value) {
            if (!config.wajib) return null;
            return value == null ? '${config.label} wajib dilampirkan' : null;
          },
          builder: (field) {
            final file = field.value;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () async {
                    final picked = await _pickFile(config);
                    if (picked == null || !mounted) return;
                    setState(() => _selectedFiles[config.id] = picked);
                    field.didChange(picked);
                  },
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: _kCanvasBg,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: field.hasError
                            ? scheme.error
                            : Colors.transparent,
                        width: 1.2,
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.attach_file_rounded,
                          size: 20,
                          color: _kBurgundy,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            file?.name ??
                                'Pilih file ${config.label.toLowerCase()}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: file == null
                                  ? _secondaryFont
                                  : _primaryFont,
                              fontSize: 13.5,
                              fontWeight: file == null
                                  ? FontWeight.w400
                                  : FontWeight.w600,
                              color: file == null ? _kTextMuted : _kTextPrimary,
                            ),
                          ),
                        ),
                        if (file != null)
                          InkWell(
                            borderRadius: BorderRadius.circular(20),
                            onTap: () {
                              setState(() => _selectedFiles.remove(config.id));
                              field.didChange(null);
                            },
                            child: const Padding(
                              padding: EdgeInsets.all(4),
                              child: Icon(
                                Icons.close_rounded,
                                size: 18,
                                color: _kTextMuted,
                              ),
                            ),
                          )
                        else
                          const Icon(
                            Icons.add_rounded,
                            size: 20,
                            color: _kBurgundy,
                          ),
                      ],
                    ),
                  ),
                ),
                if (field.hasError)
                  Padding(
                    padding: const EdgeInsets.only(left: 12, top: 6),
                    child: Text(
                      field.errorText!,
                      style: TextStyle(
                        fontFamily: _secondaryFont,
                        fontSize: 11.5,
                        color: scheme.error,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildInfoBox(IconData icon, String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _kCanvasBg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: _kBurgundy),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontFamily: _secondaryFont,
                fontSize: 12.5,
                height: 1.45,
                color: _kTextMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // SHEET SISA CUTI & RIWAYAT
  // ============================================================

  Future<void> _showSisaCutiSheet() {
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
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.78,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Jatah & Sisa Cuti',
                  style: TextStyle(
                    fontFamily: _primaryFont,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    fontVariations: [FontVariation('wght', 800)],
                    color: _kMaroonDeep,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 3),
                const Text(
                  'Terpakai dihitung dari pengajuan Disetujui & Menunggu.',
                  style: TextStyle(
                    fontFamily: _secondaryFont,
                    fontSize: 12.5,
                    color: _kTextMuted,
                  ),
                ),
                const SizedBox(height: 16),
                if (_masterCuti.isEmpty)
                  _buildInfoBox(
                    Icons.info_outline_rounded,
                    'Belum ada master cuti yang diatur HRD.',
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: _masterCuti.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (_, index) {
                        final master = _masterCuti[index];
                        final nama =
                            (master['nama_cuti'] ?? '').toString().trim();
                        return _buildSisaItem(
                          scheme,
                          nama: nama,
                          info: _sisaCuti[nama],
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSisaItem(
    ColorScheme scheme, {
    required String nama,
    required _SisaCutiInfo? info,
  }) {
    final unlimited = info?.unlimited ?? false;
    final sisa = info?.sisa ?? 0;
    final terpakai = info?.terpakai ?? 0;
    final siklus = info?.siklus ?? 'Tahunan';

    final Color badgeBg;
    final Color badgeFg;
    final String badgeText;

    if (unlimited) {
      badgeBg = const Color(0xFFEDE7F6);
      badgeFg = const Color(0xFF4527A0);
      badgeText = 'Tanpa Batas';
    } else if (sisa > 0) {
      badgeBg = const Color(0xFFE8F5E9);
      badgeFg = const Color(0xFF1B6E35);
      badgeText = '$sisa Hari';
    } else {
      badgeBg = const Color(0xFFFCE4E6);
      badgeFg = const Color(0xFF8C2D38);
      badgeText = '$sisa Hari';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  nama.isEmpty ? '-' : nama,
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
                  'Siklus: $siklus • Terpakai: $terpakai hari',
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
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: badgeBg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              badgeText,
              style: TextStyle(
                fontFamily: _primaryFont,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                fontVariations: const [FontVariation('wght', 700)],
                color: badgeFg,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showRiwayatSheet() {
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
        return FractionallySizedBox(
          heightFactor: 0.9,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Riwayat Pengajuan',
                  style: TextStyle(
                    fontFamily: _primaryFont,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    fontVariations: [FontVariation('wght', 800)],
                    color: _kMaroonDeep,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 3),
                const Text(
                  'Seluruh cuti/izin yang pernah Anda ajukan.',
                  style: TextStyle(
                    fontFamily: _secondaryFont,
                    fontSize: 12.5,
                    color: _kTextMuted,
                  ),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: _riwayat.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: const [
                              Icon(
                                Icons.inbox_outlined,
                                size: 44,
                                color: Color(0xFFB8B0AD),
                              ),
                              SizedBox(height: 10),
                              Text(
                                'Belum ada riwayat pengajuan.',
                                style: TextStyle(
                                  fontFamily: _secondaryFont,
                                  fontSize: 13,
                                  color: _kTextMuted,
                                ),
                              ),
                            ],
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.only(bottom: 8),
                          itemCount: _riwayat.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 12),
                          itemBuilder: (_, index) =>
                              _buildRiwayatCard(scheme, _riwayat[index]),
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildRiwayatCard(ColorScheme scheme, _DataMap row) {
    final status = (row['status_pengajuan'] ?? 'Menunggu').toString().trim();
    final (statusBg, statusFg) = _statusColors(status, scheme);
    final durasi = _toInt(row['durasi_hari'], 0);
    final mulai = _parseDate(row['tanggal_mulai']);
    final selesai = _parseDate(row['tanggal_selesai']);
    final dataTambahan = _asMap(row['data_tambahan']);

    final createdAt = DateTime.tryParse((row['created_at'] ?? '').toString());
    final tanggalPengajuan = createdAt != null
        ? _formatDateDisplay(createdAt)
        : (dataTambahan['Tanggal_Pengajuan_Sistem'] ?? '-').toString();

    final details = <Widget>[];
    for (final config in _configs) {
      var value = (dataTambahan[config.label] ?? '').toString().trim();
      if (value.isEmpty) {
        if (config.label.toLowerCase().contains('alasan')) {
          value = (row['alasan'] ?? '').toString().trim();
        }
        if (value.isEmpty) continue;
      }

      if (value.startsWith('http')) {
        details.add(
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    config.label,
                    style: const TextStyle(
                      fontFamily: _secondaryFont,
                      fontSize: 11.5,
                      color: _kTextMuted,
                    ),
                  ),
                ),
                InkWell(
                  onTap: () => _openAttachment(value),
                  borderRadius: BorderRadius.circular(20),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(
                          Icons.open_in_new_rounded,
                          size: 13,
                          color: _kBurgundy,
                        ),
                        SizedBox(width: 4),
                        Text(
                          'Lihat file',
                          style: TextStyle(
                            fontFamily: _primaryFont,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            fontVariations: [FontVariation('wght', 700)],
                            color: _kBurgundy,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      } else {
        details.add(
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 118,
                  child: Text(
                    config.label,
                    style: const TextStyle(
                      fontFamily: _secondaryFont,
                      fontSize: 11.5,
                      color: _kTextMuted,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    value,
                    style: const TextStyle(
                      fontFamily: _primaryFont,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      fontVariations: [FontVariation('wght', 600)],
                      color: _kTextPrimary,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }
    }

    if (details.isEmpty && (row['alasan'] ?? '').toString().trim().isNotEmpty) {
      details.add(
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            row['alasan'].toString(),
            style: const TextStyle(
              fontFamily: _primaryFont,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              fontVariations: [FontVariation('wght', 600)],
              color: _kTextPrimary,
              height: 1.35,
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: statusBg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  status,
                  style: TextStyle(
                    fontFamily: _primaryFont,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    fontVariations: const [FontVariation('wght', 700)],
                    color: statusFg,
                  ),
                ),
              ),
              const Spacer(),
              const Icon(
                Icons.event_available_rounded,
                size: 14,
                color: _kTextMuted,
              ),
              const SizedBox(width: 4),
              Text(
                '$durasi hari',
                style: const TextStyle(
                  fontFamily: _primaryFont,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  fontVariations: [FontVariation('wght', 700)],
                  color: _kTextMuted,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            [
              if (mulai != null) _formatDateDisplay(mulai),
              if (selesai != null && (mulai == null || selesai != mulai))
                _formatDateDisplay(selesai),
            ].join('  •  '),
            style: const TextStyle(
              fontFamily: _primaryFont,
              fontSize: 14.5,
              fontWeight: FontWeight.w800,
              fontVariations: [FontVariation('wght', 800)],
              color: _kMaroonDeep,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 3),
          Text(
            'Diajukan: $tanggalPengajuan',
            style: const TextStyle(
              fontFamily: _secondaryFont,
              fontSize: 11,
              color: _kTextMuted,
            ),
          ),
          ...details,
          if (status == 'Menunggu') ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => _batalkanPengajuan(row),
                icon: const Icon(Icons.delete_outline_rounded, size: 16),
                label: const Text('Batalkan'),
                style: TextButton.styleFrom(
                  foregroundColor: scheme.error,
                  textStyle: const TextStyle(
                    fontFamily: _primaryFont,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    fontVariations: [FontVariation('wght', 700)],
                  ),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _openAttachment(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;

    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Tidak dapat membuka lampiran.')),
      );
    }
  }

  (Color, Color) _statusColors(String status, ColorScheme scheme) {
    switch (status) {
      case 'Disetujui':
        return (const Color(0xFFE8F5E9), const Color(0xFF1B6E35));
      case 'Ditolak':
        return (scheme.errorContainer, scheme.onErrorContainer);
      case 'Menunggu':
        return (const Color(0xFFFFF3CD), const Color(0xFF7A5900));
      default:
        return (_kCanvasBg, _kTextMuted);
    }
  }

  Future<void> _showMessage(
    String title,
    String message, {
    bool isError = false,
  }) {
    final scheme = Theme.of(context).colorScheme;

    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        backgroundColor: Colors.white,
        icon: Icon(
          isError
              ? Icons.error_outline_rounded
              : Icons.check_circle_outline_rounded,
          color: isError ? scheme.error : const Color(0xFF1B6E35),
          size: 34,
        ),
        title: Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: _primaryFont,
            fontSize: 17,
            fontWeight: FontWeight.w800,
            fontVariations: [FontVariation('wght', 800)],
            color: _kTextPrimary,
          ),
        ),
        content: Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: _secondaryFont,
            fontSize: 13.5,
            height: 1.5,
            color: _kTextMuted,
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          GestureDetector(
            onTap: () => Navigator.of(ctx).pop(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF5A1212), Color(0xFF2B0606)],
                ),
              ),
              child: const Text(
                'Mengerti',
                style: TextStyle(
                  fontFamily: _primaryFont,
                  fontSize: 13.5,
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

  // ============================================================
  // UTILITAS
  // ============================================================

  static String _pad(int value) => value.toString().padLeft(2, '0');

  static String _formatDateApi(DateTime date) =>
      '${date.year}-${_pad(date.month)}-${_pad(date.day)}';

  static String _formatDateDisplay(DateTime date) =>
      '${date.day} ${_kMonthShort[date.month - 1]} ${date.year}';

  static DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return DateTime(value.year, value.month, value.day);

    final text = value.toString().trim();
    if (text.isEmpty) return null;

    final parsed = DateTime.tryParse(text);
    if (parsed == null) return null;
    return DateTime(parsed.year, parsed.month, parsed.day);
  }

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

  static _DataMap _asMap(dynamic value) {
    if (value is _DataMap) return value;
    if (value is Map) return _DataMap.from(value);
    return _DataMap();
  }
}

/// Konfigurasi satu kolom formulir dari tabel `form_cuti_config`.
class _FieldConfig {
  const _FieldConfig({
    required this.id,
    required this.label,
    required this.tipe,
    required this.opsi,
    required this.wajib,
    required this.urutan,
  });

  final String id;
  final String label;
  final String tipe;
  final String opsi;
  final bool wajib;
  final int urutan;

  factory _FieldConfig.fromMap(_DataMap map) {
    return _FieldConfig(
      id: (map['id'] ?? '').toString(),
      label: (map['label'] ?? '').toString().trim(),
      tipe: (map['tipe'] ?? 'keterangan').toString().trim().toLowerCase(),
      opsi: (map['opsi'] ?? '').toString(),
      wajib: map['wajib'] == true,
      urutan: _toInt(map['urutan']),
    );
  }

  static int _toInt(dynamic value) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}

/// Ringkasan jatah cuti per jenis, hasil hitung dari `master_jenis_cuti`.
class _SisaCutiInfo {
  const _SisaCutiInfo({
    required this.nama,
    required this.unlimited,
    required this.batas,
    required this.terpakai,
    required this.siklus,
  });

  final String nama;
  final bool unlimited;
  final int batas;
  final int terpakai;
  final String siklus;

  int get sisa => unlimited ? 999999 : batas - terpakai;
}