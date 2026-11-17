import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_config.dart';
import 'auth_session.dart';
import 'hari_libur.dart';

/// Bucket penyimpanan lampiran, sama dengan web referensi
/// (`supabase.storage.from("absensi-bucket")`).
const String _kStorageBucket = 'absensi-bucket';

/// Warna inti aplikasi (sama dengan halaman Login/Absen/Profil).
const Color _kHeading = Color(0xFF4A1010);
const Color _kPrimary = Color(0xFF500808);
const Color _kHint = Color(0xFF6E6E6E);

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

/// Halaman Izin & Cuti.
///
/// Fitur dan alurnya disamakan dengan tab "Cuti" pada web referensi
/// (`web-references-zabsen/index.html`):
/// - Formulir pengajuan dibangun **dinamis** dari tabel `form_cuti_config`.
/// - Pilihan jenis cuti diambil dari `master_jenis_cuti` (tipe `master_cuti`).
/// - Sisa cuti dihitung dari `cuti` + aturan siklus pada `master_jenis_cuti`.
/// - Riwayat pengajuan, pembatalan, validasi tanggal, overlapping, dan kuota.
///
/// Tampilan memakai komponen Material You (Material 3) agar konsisten dengan
/// halaman lain pada aplikasi ini.
class IzinPage extends StatefulWidget {
  const IzinPage({super.key});

  @override
  State<IzinPage> createState() => IzinPageState();
}

class IzinPageState extends State<IzinPage> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  Map<String, dynamic>? _user;

  List<_FieldConfig> _configs = [];
  List<Map<String, dynamic>> _masterCuti = [];
  Map<String, _SisaCutiInfo> _sisaCuti = {};
  List<Map<String, dynamic>> _riwayat = [];

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

  /// Memuat ulang sesi pengguna, konfigurasi form, master cuti, dan riwayat.
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
          _loadError = 'Data pengguna tidak ditemukan. Silakan logout lalu login kembali.';
        });
        return;
      }

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
          .whereType<Map>()
          .map((row) => _FieldConfig.fromMap(Map<String, dynamic>.from(row)))
          .where((config) => config.label.isNotEmpty)
          .toList();

      final masters = masterRows
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList();

      final riwayat = cutiRows
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList();

      if (!mounted) return;

      setState(() {
        _user = Map<String, dynamic>.from(user);
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

  /// Menghitung sisa cuti per jenis, mengikuti aturan siklus pada web:
  /// Tahunan (tahun berjalan), Bulanan (bulan berjalan), Sekali (seluruhnya).
  Map<String, _SisaCutiInfo> _hitungSisaCuti(
    List<Map<String, dynamic>> masters,
    List<Map<String, dynamic>> riwayat,
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

  /// Meniru `evalFormConditions()` pada web referensi.
  ///
  /// Kolom non-dropdown yang punya `opsi` berisi `Label=Nilai` atau
  /// `Label!=Nilai` hanya tampil ketika nilai kolom `Label` cocok.
  /// Nilai ganda dipisahkan tanda `|`.
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

  /// Membersihkan nilai kolom yang sedang tersembunyi agar tidak ikut terkirim
  /// (perilaku web: input di-reset saat disembunyikan).
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
      final dataTambahan = <String, dynamic>{};
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

          // Fallback: tanggal pertama menjadi tanggal mulai.
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
          // DateTime.weekday: Senin=1 ... Minggu=7. Hari libur web memakai
          // getDay(): Minggu=0 ... Sabtu=6.
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

      // Cek bentrok dengan pengajuan lain yang masih Menunggu/Disetujui.
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

      // Validasi kuota terhadap master jenis cuti yang dipilih.
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
          : (jenisCuti != null && jenisCuti.isNotEmpty ? jenisCuti : 'Lainnya');

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
      // Notifikasi bersifat opsional; pengajuan tetap tersimpan.
      debugPrint('Notifikasi Telegram gagal dikirim: $e');
    }
  }

  Future<void> _batalkanPengajuan(Map<String, dynamic> row) async {
    final scheme = Theme.of(context).colorScheme;
    final id = row['id'];
    if (id == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        icon: Icon(Icons.delete_outline_rounded, color: scheme.error, size: 30),
        title: const Text('Batalkan Pengajuan?'),
        content: const Text(
          'Pengajuan cuti/izin ini akan dihapus dan tidak dapat dikembalikan.',
          textAlign: TextAlign.center,
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Tidak'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            child: const Text('Batalkan'),
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
          content: const Text('Pengajuan berhasil dibatalkan.'),
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
                'Data belum dapat dimuat',
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
            'Izin & Cuti',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w900,
              color: _kHeading,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Ajukan cuti, izin, atau sakit sesuai formulir dari HRD',
            style: TextStyle(
              fontSize: 13,
              color: _kHint,
              fontWeight: FontWeight.w500,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 20),
          _buildActionRow(scheme),
          const SizedBox(height: 16),
          _buildFormCard(scheme),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildActionRow(ColorScheme scheme) {
    final buttonShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
    );

    return Row(
      children: [
        Expanded(
          child: FilledButton.tonalIcon(
            onPressed: _showSisaCutiSheet,
            icon: const Icon(Icons.confirmation_number_outlined, size: 20),
            label: const Text('Sisa Cuti'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              shape: buttonShape,
              textStyle: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _showRiwayatSheet,
            icon: const Icon(Icons.history_rounded, size: 20),
            label: const Text('Riwayat'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              shape: buttonShape,
              side: BorderSide(color: scheme.outlineVariant, width: 1.2),
              foregroundColor: scheme.onSurface,
              textStyle: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFormCard(ColorScheme scheme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20.0),
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.edit_calendar_rounded,
                  size: 20,
                  color: scheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Formulir Pengajuan',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Formulir mengikuti konfigurasi HRD',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          if (_configs.isEmpty)
            _buildInfoBox(
              scheme,
              Icons.info_outline_rounded,
              'Formulir cuti belum dikonfigurasi. Hubungi Admin/HRD.',
            )
          else
            KeyedSubtree(
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
                    const SizedBox(height: 4),
                    FilledButton(
                      onPressed: _isSubmitting ? null : _submit,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                        backgroundColor: _kPrimary,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: _kPrimary.withValues(
                          alpha: 0.55,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.3,
                        ),
                      ),
                      child: _isSubmitting
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                                color: Colors.white,
                              ),
                            )
                          : const Text('Kirim Pengajuan'),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
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
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: RichText(
        text: TextSpan(
          text: config.label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: scheme.onSurfaceVariant,
            letterSpacing: 0.1,
          ),
          children: [
            if (config.wajib)
              TextSpan(
                text: ' *',
                style: TextStyle(color: scheme.error),
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
      hintStyle: TextStyle(
        fontSize: 14,
        color: scheme.onSurfaceVariant.withValues(alpha: 0.65),
      ),
      suffixIcon: suffixIcon,
      prefixIcon: prefixIcon,
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
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
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: scheme.error, width: 1.2),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: scheme.error, width: 1.5),
      ),
      errorStyle: TextStyle(fontSize: 11.5, color: scheme.error),
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
          style: TextStyle(fontSize: 14, color: scheme.onSurface),
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
          style: TextStyle(fontSize: 14, color: scheme.onSurface),
          decoration: _inputDecoration(
            scheme,
            hint: 'Pilih ${config.label.toLowerCase()}',
            suffixIcon: Icon(
              Icons.calendar_month_rounded,
              size: 20,
              color: scheme.primary,
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
            scheme,
            Icons.list_alt_rounded,
            config.tipe == 'master_cuti'
                ? 'Belum ada master jenis cuti dari HRD.'
                : 'Belum ada pilihan untuk ${config.label}.',
          )
        else
          DropdownButtonFormField<String>(
            initialValue: validValue,
            isExpanded: true,
            style: TextStyle(fontSize: 14, color: scheme.onSurface),
            icon: Icon(
              Icons.keyboard_arrow_down_rounded,
              color: scheme.onSurfaceVariant,
            ),
            decoration: _inputDecoration(
              scheme,
              hint: 'Pilih ${config.label.toLowerCase()}',
            ),
            dropdownColor: scheme.surfaceContainerHigh,
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
                      color: scheme.surfaceContainerHighest.withValues(
                        alpha: 0.55,
                      ),
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
                        Icon(
                          Icons.attach_file_rounded,
                          size: 20,
                          color: scheme.primary,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            file?.name ??
                                'Pilih file ${config.label.toLowerCase()}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: file == null
                                  ? scheme.onSurfaceVariant
                                  : scheme.onSurface,
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
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: Icon(
                                Icons.close_rounded,
                                size: 18,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          )
                        else
                          Icon(
                            Icons.add_rounded,
                            size: 20,
                            color: scheme.onSurfaceVariant,
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
                      style: TextStyle(fontSize: 11.5, color: scheme.error),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildInfoBox(ColorScheme scheme, IconData icon, String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: scheme.onSecondaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.45,
                color: scheme.onSecondaryContainer,
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
      backgroundColor: scheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) {
        final sheetScheme = Theme.of(ctx).colorScheme;

        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.78,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Jatah & Sisa Cuti',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: sheetScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Terpakai dihitung dari pengajuan Disetujui & Menunggu.',
                  style: TextStyle(
                    fontSize: 12,
                    color: sheetScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                if (_masterCuti.isEmpty)
                  _buildInfoBox(
                    sheetScheme,
                    Icons.info_outline_rounded,
                    'Belum ada master cuti yang diatur HRD.',
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: _masterCuti.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (_, index) {
                        final master = _masterCuti[index];
                        final nama = (master['nama_cuti'] ?? '')
                            .toString()
                            .trim();
                        return _buildSisaItem(
                          sheetScheme,
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
      badgeBg = scheme.tertiaryContainer;
      badgeFg = scheme.onTertiaryContainer;
      badgeText = 'Tanpa Batas';
    } else if (sisa > 0) {
      badgeBg = scheme.primaryContainer;
      badgeFg = scheme.onPrimaryContainer;
      badgeText = '$sisa Hari';
    } else {
      badgeBg = scheme.errorContainer;
      badgeFg = scheme.onErrorContainer;
      badgeText = '$sisa Hari';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.7)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  nama.isEmpty ? '-' : nama,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Siklus: $siklus • Terpakai: $terpakai hari',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
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
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              badgeText,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: badgeFg,
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
      backgroundColor: scheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) {
        final sheetScheme = Theme.of(ctx).colorScheme;

        return FractionallySizedBox(
          heightFactor: 0.9,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Riwayat Pengajuan',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: sheetScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Seluruh cuti/izin yang pernah Anda ajukan.',
                  style: TextStyle(
                    fontSize: 12,
                    color: sheetScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: _riwayat.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.inbox_outlined,
                                size: 44,
                                color: sheetScheme.outline,
                              ),
                              const SizedBox(height: 10),
                              Text(
                                'Belum ada riwayat pengajuan.',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: sheetScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.only(bottom: 8),
                          itemCount: _riwayat.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 12),
                          itemBuilder: (_, index) =>
                              _buildRiwayatCard(sheetScheme, _riwayat[index]),
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildRiwayatCard(ColorScheme scheme, Map<String, dynamic> row) {
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
                    style: TextStyle(
                      fontSize: 11.5,
                      color: scheme.onSurfaceVariant,
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
                      children: [
                        Icon(
                          Icons.open_in_new_rounded,
                          size: 13,
                          color: scheme.primary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Lihat file',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: scheme.primary,
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
                    style: TextStyle(
                      fontSize: 11.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    value,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
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
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
              height: 1.35,
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.7)),
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
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  status,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: statusFg,
                  ),
                ),
              ),
              const Spacer(),
              Icon(
                Icons.event_available_rounded,
                size: 14,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Text(
                '$durasi hari',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurfaceVariant,
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
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            'Diajukan: $tanggalPengajuan',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
          ...details,
          if (status == 'Menunggu') ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => _batalkanPengajuan(row),
                icon: Icon(Icons.delete_outline_rounded, size: 16),
                label: const Text('Batalkan'),
                style: TextButton.styleFrom(
                  foregroundColor: scheme.error,
                  textStyle: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
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
        return (const Color(0xFFD6F5E0), const Color(0xFF14652F));
      case 'Ditolak':
        return (scheme.errorContainer, scheme.onErrorContainer);
      case 'Menunggu':
        return (const Color(0xFFFFEFC2), const Color(0xFF755600));
      default:
        return (scheme.surfaceContainerHighest, scheme.onSurfaceVariant);
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        icon: Icon(
          isError
              ? Icons.error_outline_rounded
              : Icons.check_circle_outline_rounded,
          color: isError ? scheme.error : scheme.primary,
          size: 34,
        ),
        title: Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
        ),
        content: Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13.5,
            height: 1.5,
            color: scheme.onSurfaceVariant,
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            ),
            child: const Text('Mengerti'),
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

  static Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return <String, dynamic>{};
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

  factory _FieldConfig.fromMap(Map<String, dynamic> map) {
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
