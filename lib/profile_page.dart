import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_session.dart';
import 'session_actions.dart';

typedef _DataMap = Map<String, dynamic>;

// Font utama & sekunder yang selaras dengan AbsenPage, KalenderPage, dan IzinPage
const String _primaryFont = 'Google Sans Flex';
const String _secondaryFont = 'Inter';

// Palet warna utama Zieda Absen
const Color _kCanvasBg = Color(0xFFF7F5F4);
const Color _kMaroonDeep = Color(0xFF330808);
const Color _kBurgundy = Color(0xFF5E1212);
const Color _kTerracotta = Color(0xFF8F382B);
const Color _kTextPrimary = Color(0xFF1E1E1E);
const Color _kTextMuted = Color(0xFF6E6E6E);

/// Halaman Profil pengguna dengan Hero Gradient Header & Overlapping Card
/// yang ukuran dan tata letaknya identik dengan AbsenPage, KalenderPage, dan IzinPage.
class ProfilePage extends StatefulWidget {
  final ValueChanged<_DataMap>? onUserUpdated;
  final bool isAdmin;
  final VoidCallback? onOpenAdmin;
  final VoidCallback? onLogout;

  const ProfilePage({
    super.key,
    this.onUserUpdated,
    this.isAdmin = false,
    this.onOpenAdmin,
    this.onLogout,
  });

  @override
  State<ProfilePage> createState() => ProfilePageState();
}

class ProfilePageState extends State<ProfilePage> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _newPasswordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();

  _DataMap? _user;
  bool _isAdminUser = false;
  bool _isLoading = true;
  bool _obscureNewPassword = true;
  bool _obscureConfirmPassword = true;
  bool _isSavingPassword = false;

  SupabaseClient get _supabase => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _isAdminUser = widget.isAdmin;
    reload();
  }

  @override
  void dispose() {
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  /// Memuat ulang profil dari cache lalu menyinkronkan dengan Supabase.
  Future<void> reload() async {
    final restored = await AuthSession.restore();
    final user = restored ?? await AuthSession.readCachedUser();

    if (!mounted) return;

    final role = (user?['role'] ?? '').toString().trim().toLowerCase();
    final isAdminDetected =
        widget.isAdmin || role == 'hr' || role == 'super admin';

    setState(() {
      if (user != null) _user = user;
      _isAdminUser = isAdminDetected;
      _isLoading = false;
    });

    if (user != null) {
      widget.onUserUpdated?.call(user);
    }
  }

  Future<void> _updatePassword() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;

    final user = _user;
    if (user == null || user['id'] == null) {
      _showMessageDialog(
        title: 'Gagal',
        message: 'Data pengguna tidak ditemukan. Silakan login kembali.',
        isError: true,
      );
      return;
    }

    final String newPassword = _newPasswordController.text;

    setState(() => _isSavingPassword = true);

    try {
      // 1. Perbarui password di Supabase Auth.
      await _supabase.auth.updateUser(UserAttributes(password: newPassword));

      // 2. Perbarui password di tabel public.users.
      await _supabase
          .from('users')
          .update({'password': newPassword})
          .eq('id', user['id']);

      if (!mounted) return;

      await _showMessageDialog(
        title: 'Berhasil',
        message:
            'Password berhasil diubah. Silakan login ulang dengan password baru Anda.',
      );

      if (!mounted) return;
      await logoutToLogin(context, askConfirmation: false);
    } on AuthException catch (e) {
      _showMessageDialog(
        title: 'Gagal',
        message:
            'Gagal memperbarui kata sandi keamanan: ${e.message}\n\n'
            'Jika sesi keamanan sudah berakhir, silakan logout lalu login kembali.',
        isError: true,
      );
    } catch (e) {
      _showMessageDialog(
        title: 'Gagal',
        message: 'Gagal mengubah password: $e',
        isError: true,
      );
    } finally {
      if (mounted) {
        setState(() => _isSavingPassword = false);
      }
    }
  }

  Future<void> _showMessageDialog({
    required String title,
    required String message,
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

  String _textValue(dynamic value, [String fallback = '-']) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? fallback : text;
  }

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
    final double topSafePadding = MediaQuery.of(context).padding.top;

    return ColoredBox(
      color: _kCanvasBg,
      child: RefreshIndicator(
        color: _kBurgundy,
        onRefresh: reload,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Stack(
            children: [
              // ==========================================================
              // LAYER BACKGROUND GRADASI HEADER (IDENTIK DENGAN SEMUA TAB)
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
                            text: 'Profil ',
                            style: TextStyle(
                              fontFamily: _secondaryFont,
                              fontWeight: FontWeight.w400,
                              color: Colors.white.withValues(alpha: 0.86),
                            ),
                          ),
                          const TextSpan(
                            text: 'Karyawan',
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
                      'Informasi penempatan kerja & keamanan akun',
                      style: TextStyle(
                        fontFamily: _secondaryFont,
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                        color: Colors.white.withValues(alpha: 0.80),
                      ),
                    ),

                    const SizedBox(height: 22),

                    // 3. OVERLAPPING HERO CARD: IDENTITAS PENGGUNA
                    _buildOverlappingIdentityCard(),

                    const SizedBox(height: 22),

                    // 4. KONTEN DETAIL PROFIL & UBAH PASSWORD
                    if (_isLoading)
                      Container(
                        height: 260,
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: const Center(
                          child: CircularProgressIndicator(color: _kBurgundy),
                        ),
                      )
                    else if (_user == null)
                      _buildEmptyProfileCard()
                    else ...[
                      _buildDetailCard(),
                      const SizedBox(height: 22),
                      _buildPasswordSection(),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Kartu putih melayang tepat di garis transisi header
  Widget _buildOverlappingIdentityCard() {
    final user = _user;
    final String nama = _isLoading ? 'Memuat...' : _textValue(user?['nama']);
    final String role = _textValue(user?['role'], 'Karyawan');
    final String cabang = _textValue(user?['cabang'], 'Pusat');

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
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: const Color(0xFFFCE4E6).withValues(alpha: 0.7),
              shape: BoxShape.circle,
            ),
            child: ClipOval(
              child: Image.asset(
                'assets/images/profil.png',
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) {
                  return const Icon(
                    Icons.person_rounded,
                    color: _kBurgundy,
                    size: 30,
                  );
                },
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  nama,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: _primaryFont,
                    fontSize: 17.5,
                    fontWeight: FontWeight.w800,
                    fontVariations: [FontVariation('wght', 800)],
                    color: _kMaroonDeep,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 5),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFCE4E6),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        role,
                        style: const TextStyle(
                          fontFamily: _primaryFont,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          fontVariations: [FontVariation('wght', 700)],
                          color: _kBurgundy,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        cabang,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: _secondaryFont,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: _kTextMuted,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyProfileCard() {
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
          Icon(
            Icons.person_off_outlined,
            size: 48,
            color: Colors.grey.shade400,
          ),
          const SizedBox(height: 12),
          const Text(
            'Data profil tidak ditemukan',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: _primaryFont,
              fontSize: 16,
              fontWeight: FontWeight.w700,
              fontVariations: [FontVariation('wght', 700)],
              color: _kTextPrimary,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Silakan logout lalu login kembali.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: _secondaryFont,
              fontSize: 13,
              color: _kTextMuted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailCard() {
    final user = _user;
    final String noHp = _textValue(user?['no_hp']);
    final String cabang = _textValue(user?['cabang'], 'Pusat');
    final String unit = _textValue(user?['unit']);
    final String sisaCuti = _textValue(user?['sisa_cuti'], '0');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Informasi Akun',
          style: TextStyle(
            fontFamily: _primaryFont,
            fontSize: 16,
            fontWeight: FontWeight.w700,
            fontVariations: [FontVariation('wght', 700)],
            color: _kTextPrimary,
            letterSpacing: -0.2,
          ),
        ),
        const SizedBox(height: 12),
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
          child: Column(
            children: [
              _buildInfoRow(
                icon: Icons.phone_outlined,
                label: 'No HP',
                value: noHp,
                tabular: true,
              ),
              const SizedBox(height: 14),
              _buildInfoRow(
                icon: Icons.storefront_outlined,
                label: 'Penempatan',
                value: cabang,
              ),
              const SizedBox(height: 14),
              _buildInfoRow(
                icon: Icons.work_outline_rounded,
                label: 'Unit / Divisi',
                value: unit,
              ),
              const SizedBox(height: 14),
              _buildInfoRow(
                icon: Icons.beach_access_outlined,
                label: 'Sisa Cuti',
                value: '$sisaCuti hari',
                tabular: true,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildInfoRow({
    required IconData icon,
    required String label,
    required String value,
    bool tabular = false,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: _kCanvasBg,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, size: 18, color: _kBurgundy),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontFamily: _secondaryFont,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                  color: _kTextMuted,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value,
                style: TextStyle(
                  fontFamily: _primaryFont,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  fontVariations: const [FontVariation('wght', 700)],
                  color: _kTextPrimary,
                  fontFeatures:
                      tabular ? const [FontFeature.tabularFigures()] : null,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPasswordSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Keamanan Password',
          style: TextStyle(
            fontFamily: _primaryFont,
            fontSize: 16,
            fontWeight: FontWeight.w700,
            fontVariations: [FontVariation('wght', 700)],
            color: _kTextPrimary,
            letterSpacing: -0.2,
          ),
        ),
        const SizedBox(height: 12),
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
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildPasswordField(
                  controller: _newPasswordController,
                  label: 'Password Baru',
                  hint: 'Masukkan password baru (min. 6 karakter)',
                  obscure: _obscureNewPassword,
                  onToggleVisibility: () {
                    setState(() => _obscureNewPassword = !_obscureNewPassword);
                  },
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Password baru tidak boleh kosong';
                    }
                    if (value.length < 6) {
                      return 'Password minimal 6 karakter';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                _buildPasswordField(
                  controller: _confirmPasswordController,
                  label: 'Konfirmasi Password Baru',
                  hint: 'Ulangi password baru',
                  obscure: _obscureConfirmPassword,
                  onToggleVisibility: () {
                    setState(
                      () => _obscureConfirmPassword = !_obscureConfirmPassword,
                    );
                  },
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Konfirmasi password tidak boleh kosong';
                    }
                    if (value != _newPasswordController.text) {
                      return 'Konfirmasi password tidak cocok';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 20),
                GestureDetector(
                  onTap: _isSavingPassword ? null : _updatePassword,
                  child: Container(
                    height: 54,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: _isSavingPassword
                            ? [
                                const Color(0xFF5A1212).withValues(alpha: 0.55),
                                const Color(0xFF2B0606).withValues(alpha: 0.55),
                              ]
                            : const [
                                Color(0xFF5A1212),
                                Color(0xFF2B0606),
                              ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF3A0A0A).withValues(alpha: 0.28),
                          blurRadius: 14,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                    child: Center(
                      child: _isSavingPassword
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                                color: Colors.white,
                              ),
                            )
                          : const Text(
                              'Perbarui Password',
                              style: TextStyle(
                                fontFamily: _primaryFont,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                fontVariations: [FontVariation('wght', 700)],
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
      ],
    );
  }

  Widget _buildPasswordField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required bool obscure,
    required VoidCallback onToggleVisibility,
    required String? Function(String?) validator,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(16);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 8),
          child: Text(
            label,
            style: const TextStyle(
              fontFamily: _primaryFont,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              fontVariations: [FontVariation('wght', 700)],
              color: _kTextPrimary,
              letterSpacing: -0.1,
            ),
          ),
        ),
        TextFormField(
          controller: controller,
          obscureText: obscure,
          style: const TextStyle(
            fontFamily: _secondaryFont,
            fontSize: 14,
            color: _kTextPrimary,
          ),
          validator: validator,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(
              fontFamily: _secondaryFont,
              fontSize: 13.5,
              color: _kTextMuted,
            ),
            prefixIcon: const Icon(
              Icons.lock_outline_rounded,
              color: _kBurgundy,
              size: 20,
            ),
            suffixIcon: IconButton(
              icon: Icon(
                obscure
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                color: _kTextMuted,
                size: 20,
              ),
              onPressed: onToggleVisibility,
            ),
            filled: true,
            fillColor: _kCanvasBg,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              vertical: 15,
              horizontal: 16,
            ),
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
          ),
        ),
      ],
    );
  }
}