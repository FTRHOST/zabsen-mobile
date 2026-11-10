import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'absen_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  bool _obscurePassword = true;
  bool _isLoading = false;

  // Data dinamis dari app_settings
  String _appName = 'ZIEDA ABSEN';
  String _subText = 'Silakan masuk ke akun Anda';
  String? _logoUrl;

  // Warna sesuai tema ZIEDA Bakery & Cakes dari Figma
  static const Color primaryColor = Color(0xff500808); // seed/dark burgundy
  static const Color borderColor = Color(0xffe5e1e1);
  static const Color hintColor = Color(0xff939090);

  SupabaseClient get _supabase => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _fetchAppSettings();
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  /// Mengambil data judul aplikasi, subteks, dan logo dari tabel app_settings
  Future<void> _fetchAppSettings() async {
    try {
      final data = await _supabase
          .from('app_settings')
          .select('nama_aplikasi, logo_url, login_subteks')
          .eq('id', 1)
          .maybeSingle();

      if (data != null && mounted) {
        setState(() {
          if (data['nama_aplikasi'] != null &&
              (data['nama_aplikasi'] as String).isNotEmpty) {
            _appName = data['nama_aplikasi'];
          }
          if (data['login_subteks'] != null &&
              (data['login_subteks'] as String).isNotEmpty) {
            _subText = data['login_subteks'];
          }
          if (data['logo_url'] != null &&
              (data['logo_url'] as String).isNotEmpty) {
            _logoUrl = data['logo_url'];
          }
        });
      }
    } catch (e) {
      debugPrint('Gagal memuat app_settings: $e');
    }
  }

  /// Validasi user dengan RPC link_my_account, tabel users, dan auto-seed
  Future<Map<String, dynamic>> _findAndValidateUser(
    String nama,
    String password,
  ) async {
    // 1. Coba via RPC link_my_account
    try {
      final rpcData = await _supabase.rpc(
        'link_my_account',
        params: {
          'p_nama': nama,
          'p_password': password,
        },
      );
      if (rpcData != null) {
        if (rpcData is List && rpcData.isNotEmpty) {
          return Map<String, dynamic>.from(rpcData.first);
        } else if (rpcData is Map) {
          return Map<String, dynamic>.from(rpcData);
        }
      }
    } catch (e) {
      final errStr = e.toString().toLowerCase();
      if (errStr.contains('salah')) {
        throw Exception('Nama Pengguna atau Password salah!');
      }
      debugPrint('RPC link_my_account fallback: $e');
    }

    // 2. Fallback: Query ke tabel public.users
    try {
      final List<dynamic> users = await _supabase
          .from('users')
          .select(
            'id, nama, role, no_hp, cabang, auth_id, hari_libur, sisa_cuti, password',
          )
          .ilike('nama', nama)
          .eq('password', password);

      if (users.isNotEmpty) {
        return Map<String, dynamic>.from(users.first);
      }
    } catch (usersErr) {
      debugPrint('Users table query error: $usersErr');
      final errStr = usersErr.toString();
      if (errStr.contains('42P01') || errStr.contains('does not exist')) {
        throw Exception(
          'Tabel database belum dibuat! Silakan periksa skema database Supabase.',
        );
      }
    }

    // 3. Fallback Auto-Seed: Khusus akun 'Super Admin' & 'admin123' jika belum ada
    if (nama.trim().toLowerCase() == 'super admin' && password == 'admin123') {
      debugPrint('⚡ Inisialisasi akun Super Admin default...');
      final List<dynamic> seeded = await _supabase
          .from('users')
          .insert([
            {
              'nama': 'Super Admin',
              'password': 'admin123',
              'role': 'Super Admin',
              'cabang': 'Pusat',
            }
          ])
          .select();

      if (seeded.isNotEmpty) {
        return Map<String, dynamic>.from(seeded.first);
      }
    }

    throw Exception('Nama Pengguna atau Password salah!');
  }

  /// Proses login lengkap sesuai alur autentikasi Supabase
  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;

    final String namaUser = _usernameController.text.trim();
    final String password = _passwordController.text;

    setState(() {
      _isLoading = true;
    });

    try {
      // Bersihkan sesi lama jika ada
      try {
        await _supabase.auth.signOut();
      } catch (e) {
        debugPrint('signOut error: $e');
      }

      // 1. Validasi akun ke database master
      final Map<String, dynamic> validUser =
          await _findAndValidateUser(namaUser, password);

      // 2. Buat email dummy aktif berbasis nama karyawan
      final String rawName = validUser['nama']?.toString() ?? namaUser;
      final String cleanName =
          rawName.replaceAll(RegExp(r'\s+'), '').toLowerCase();
      final String activeDummyEmail = '$cleanName@zieabsen.com';

      // 3. Autentikasi dengan Supabase Auth Engine
      try {
        await _supabase.auth.signInWithPassword(
          email: activeDummyEmail,
          password: password,
        );
      } catch (authErr) {
        // Jika akun Auth belum pernah dibuat, lakukan sign up
        try {
          await _supabase.auth.signUp(
            email: activeDummyEmail,
            password: password,
          );
          await _supabase.auth.signInWithPassword(
            email: activeDummyEmail,
            password: password,
          );
        } catch (_) {
          // Jika email bentrok, gunakan email unik dengan ID user
          final String uniqueEmail =
              '${cleanName}_${validUser['id']}@zieabsen.com';
          try {
            await _supabase.auth.signUp(
              email: uniqueEmail,
              password: password,
            );
          } catch (_) {}
          await _supabase.auth.signInWithPassword(
            email: uniqueEmail,
            password: password,
          );
        }
      }

      // 4. Tautkan auth_id terbaru ke tabel public.users
      final currentSession = _supabase.auth.currentSession;
      if (currentSession?.user.id != null) {
        final authUserId = currentSession!.user.id;
        validUser['auth_id'] = authUserId;
        try {
          await _supabase
              .from('users')
              .update({'auth_id': authUserId})
              .eq('id', validUser['id']);
        } catch (updateErr) {
          debugPrint('Gagal update auth_id: $updateErr');
        }
      }

      // 5. Simpan sesi login ke SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('userLogin', jsonEncode(validUser));

      if (!mounted) return;

      // 6. Dialog berhasil login & navigasi ke AbsenPage
      _showSuccessDialog(validUser['nama']?.toString() ?? namaUser);
    } catch (err) {
      debugPrint('Login Error: $err');
      String errMsg = err.toString().replaceFirst('Exception: ', '');
      if (errMsg.isEmpty || errMsg == '{}') {
        errMsg = 'Kredensial tidak valid atau koneksi gagal.';
      }
      if (mounted) {
        _showErrorDialog(errMsg);
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _showSuccessDialog(String nama) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle_rounded, color: Colors.green, size: 64),
            const SizedBox(height: 16),
            const Text(
              'Berhasil Login!',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'Selamat datang kembali, $nama!',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: Colors.black54),
            ),
          ],
        ),
      ),
    );

    Future.delayed(const Duration(milliseconds: 1400), () {
      if (mounted) {
        Navigator.of(context).pop(); // Tutup dialog
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const AbsenPage()),
        );
      }
    });
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: const [
            Icon(Icons.error_outline_rounded, color: Colors.red),
            SizedBox(width: 8),
            Text('Login Gagal', style: TextStyle(fontSize: 18)),
          ],
        ),
        content: Text(message, style: const TextStyle(fontSize: 14)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK', style: TextStyle(color: primaryColor)),
          ),
        ],
      ),
    );
  }

  Future<void> _hubungiAdmin() async {
    final Uri url = Uri.parse('https://wa.me/+6285293392559');
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Tidak dapat membuka WhatsApp')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 36.0, vertical: 24.0),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // --- LOGO APLIKASI ---
                  Center(
                    child: _logoUrl != null
                        ? Image.network(
                            _logoUrl!,
                            height: 72,
                            fit: BoxFit.contain,
                            errorBuilder: (context, error, stackTrace) => Image.asset(
                              'assets/images/logo_zieda.png',
                              height: 72,
                              fit: BoxFit.contain,
                            ),
                          )
                        : Image.asset(
                            'assets/images/logo_zieda.png',
                            height: 72,
                            fit: BoxFit.contain,
                          ),
                  ),
                  const SizedBox(height: 20),

                  // --- JUDUL & SUBTITLE DINAMIS ---
                  Text(
                    _appName,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      color: primaryColor,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _subText,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 13,
                      color: hintColor,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 36),

                  // --- INPUT FIELD: NAMA PENGGUNA ---
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: TextFormField(
                      controller: _usernameController,
                      style: const TextStyle(fontSize: 14, color: Colors.black87),
                      decoration: InputDecoration(
                        hintText: 'Nama Pengguna',
                        hintStyle: const TextStyle(color: hintColor, fontSize: 14),
                        prefixIcon: const Icon(
                          Icons.person_outline_rounded,
                          color: hintColor,
                          size: 24,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 18,
                          horizontal: 16,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: borderColor),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: borderColor),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide:
                              const BorderSide(color: primaryColor, width: 1.5),
                        ),
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Nama Pengguna tidak boleh kosong';
                        }
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(height: 18),

                  // --- INPUT FIELD: PASSWORD ---
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: TextFormField(
                      controller: _passwordController,
                      obscureText: _obscurePassword,
                      style: const TextStyle(fontSize: 14, color: Colors.black87),
                      decoration: InputDecoration(
                        hintText: 'Password',
                        hintStyle: const TextStyle(color: hintColor, fontSize: 14),
                        prefixIcon: const Icon(
                          Icons.lock_outline_rounded,
                          color: hintColor,
                          size: 24,
                        ),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                            color: hintColor,
                          ),
                          onPressed: () {
                            setState(() {
                              _obscurePassword = !_obscurePassword;
                            });
                          },
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 18,
                          horizontal: 16,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: borderColor),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: borderColor),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide:
                              const BorderSide(color: primaryColor, width: 1.5),
                        ),
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Password tidak boleh kosong';
                        }
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(height: 28),

                  // --- TOMBOL LOGIN ---
                  SizedBox(
                    height: 52,
                    child: ElevatedButton(
                      onPressed: _isLoading ? null : _handleLogin,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: primaryColor,
                        foregroundColor: Colors.white,
                        elevation: 4,
                        shadowColor: primaryColor.withValues(alpha: 0.5),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30),
                        ),
                      ),
                      child: _isLoading
                          ? const SizedBox(
                              height: 22,
                              width: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.white,
                              ),
                            )
                          : const Text(
                              'LOGIN',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.0,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // --- LUPA PASSWORD / HUBUNGI ADMIN ---
                  Center(
                    child: TextButton(
                      onPressed: _hubungiAdmin,
                      child: const Text(
                        'Lupa password? Hubungi Admin',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: primaryColor,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
