import 'package:flutter/material.dart';

import 'auth_session.dart';
import 'login_page.dart';

/// Menampilkan konfirmasi sebelum pengguna keluar dari akun.
Future<bool> confirmLogout(BuildContext context) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Row(
        children: [
          Icon(Icons.logout_rounded, color: Color(0xFF500808)),
          SizedBox(width: 8),
          Text('Logout', style: TextStyle(fontSize: 18)),
        ],
      ),
      content: const Text(
        'Anda akan keluar dari akun ini. Lanjutkan?',
        style: TextStyle(fontSize: 14),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text(
            'Batal',
            style: TextStyle(color: Color(0xFF6E6E6E)),
          ),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF500808),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
          ),
          child: const Text('Logout'),
        ),
      ],
    ),
  );

  return result ?? false;
}

/// Mengakhiri sesi lalu kembali ke halaman login.
///
/// Set [askConfirmation] ke `false` bila konfirmasi sudah ditangani pemanggil
/// (mis. setelah berhasil mengubah password).
Future<void> logoutToLogin(
  BuildContext context, {
  bool askConfirmation = true,
}) async {
  if (askConfirmation && !await confirmLogout(context)) return;

  await AuthSession.clear();
  if (!context.mounted) return;

  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => const LoginPage()),
    (route) => false,
  );
}
