import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Pengelola sesi login yang bertahan di perangkat.
///
/// Login hanya perlu dilakukan sekali. Sesi disimpan di [SharedPreferences]
/// (`userLogin`) dan dipulihkan saat aplikasi dibuka kembali, sampai pengguna
/// menekan tombol Logout.
class AuthSession {
  AuthSession._();

  /// Key penyimpanan data pengguna, sama dengan yang dipakai web referensi.
  static const String userCacheKey = 'userLogin';

  static SupabaseClient get _supabase => Supabase.instance.client;

  /// Membaca data pengguna yang tersimpan di perangkat.
  static Future<Map<String, dynamic>?> readCachedUser() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(userCacheKey);
    if (raw == null || raw.isEmpty) return null;

    try {
      final decoded = jsonDecode(raw);
      final Map<String, dynamic>? user = decoded is Map<String, dynamic>
          ? decoded
          : (decoded is Map ? Map<String, dynamic>.from(decoded) : null);

      // Bersihkan password dari cache versi lama bila ada.
      user?.remove('password');
      return user;
    } catch (e) {
      debugPrint('Gagal membaca cache userLogin: $e');
    }
    return null;
  }

  /// Menyimpan data pengguna ke perangkat.
  static Future<void> saveUser(Map<String, dynamic> user) async {
    // Jangan simpan password ke penyimpanan lokal.
    final safeUser = Map<String, dynamic>.from(user)..remove('password');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(userCacheKey, jsonEncode(safeUser));
  }

  /// Menghapus sesi Supabase Auth dan data pengguna lokal.
  static Future<void> clear() async {
    try {
      await _supabase.auth.signOut();
    } catch (e) {
      debugPrint('signOut error (diabaikan): $e');
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(userCacheKey);
  }

  /// Memulihkan sesi login beserta data profil terbaru dari tabel `users`.
  ///
  /// Alur ini mengikuti `syncUserSession()` pada web referensi:
  /// 1. Jika sesi Supabase Auth aktif, ambil profil berdasarkan `auth_id`.
  /// 2. Jika belum terhubung, ambil berdasarkan `id` lalu tautkan `auth_id`.
  /// 3. Saat jaringan bermasalah, tetap gunakan cache agar tidak memaksa login.
  static Future<Map<String, dynamic>?> restore() async {
    final cached = await readCachedUser();
    if (cached == null) return null;

    try {
      final session = _supabase.auth.currentSession;
      Map<String, dynamic>? fresh;

      if (session != null) {
        final byAuth = await _supabase
            .from('users')
            .select('*')
            .eq('auth_id', session.user.id)
            .maybeSingle();

        if (byAuth != null) {
          fresh = Map<String, dynamic>.from(byAuth);
        }
      }

      final cachedId = cached['id'];
      if (fresh == null && cachedId != null) {
        final byId = await _supabase
            .from('users')
            .select('*')
            .eq('id', cachedId)
            .maybeSingle();

        if (byId != null) {
          fresh = Map<String, dynamic>.from(byId);

          // Self-repair: tautkan auth_id agar RLS tetap valid.
          if (session != null) {
            try {
              await _supabase
                  .from('users')
                  .update({'auth_id': session.user.id})
                  .eq('id', cachedId);
            } catch (e) {
              debugPrint('Gagal menautkan auth_id: $e');
            }
          }
        }
      }

      if (fresh != null) {
        await saveUser(fresh);
        return fresh;
      }

      if (session == null) {
        // Tidak ada sesi Auth dan profil benar-benar tidak ada di database
        // (mis. akun sudah dihapus admin) -> bersihkan sesi lokal.
        await clear();
        return null;
      }

      // Sesi Auth masih aktif: pertahankan cache agar pengguna tidak dipaksa
      // login ulang, sama seperti web referensi.
      return cached;
    } catch (e) {
      // Offline / gangguan jaringan: gunakan cache lokal.
      debugPrint('Restore sesi gagal, memakai cache lokal: $e');
      return cached;
    }
  }
}
