import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'login_page.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  late final Player _player;
  late final VideoController _controller;
  bool _isVideoSiap = false;
  bool _animasiKelar = false;

  @override
  void initState() {
    super.initState();
    MediaKit.ensureInitialized();

    _player = Player();

    _controller = VideoController(
      _player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: false,
      ),
    );

    _jalankanSplash();
  }

  Future<void> _jalankanSplash() async {
    // 1. Task proses data (misal cek sesi token atau siapin halaman login)
    final Future<void> prosesData = Future(() async {
      // Ganti ini dengan pengecekan login aslimu
      await Future.delayed(const Duration(milliseconds: 2500));
    });

    // 2. Task pemutaran video
    final Future<void> prosesVideo = Future(() async {
      try {
        await _player.open(Media('asset:///assets/video/splash.webm'));
        if (mounted) {
          setState(() {
            _isVideoSiap = true;
          });
          await _player.play();
        }

        // Tunggu sampai video menyentuh akhir
        await _player.stream.completed.firstWhere((selesai) => selesai);

        // Kunci di sini: langsung pause biar gak di-reset ke blank
        await _player.pause();

        if (mounted) {
          setState(() {
            _animasiKelar = true; // Tandai animasi udah mentok di akhir
          });
        }
      } catch (e) {
        // Kalau video error, langsung anggap beres biar gak macet
        if (mounted) {
          setState(() {
            _animasiKelar = true;
          });
        }
      }
    });

    // Tunggu DUA-DUANYA kelar:
    // - Kalau HP kencang: data siap duluan, tapi nunggu video kelar.
    // - Kalau HP lambat: video kelar duluan, animasi bakal diam membeku nunggu proses data kelar.
    await Future.wait([prosesData, prosesVideo]);

    if (!mounted) return;

    // Langsung pindah ke halaman login
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (context, anim1, anim2) => const LoginPage(),
        transitionsBuilder: (context, anim1, anim2, child) =>
            FadeTransition(opacity: anim1, child: child),
        transitionDuration: const Duration(milliseconds: 300),
      ),
    );
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Layer 1: Frame diam / Logo statis (muncul nahan layar pas video udah kelar)
            // Bisa pakai Image.asset logo kamu di sini kalau video tetap flicker
            // if (_animasiKelar)
            //   Image.asset(
            //     'assets/images/logo.png', // assset belum terinput dan juga masih ada beberapa bug
            //     fit: BoxFit.contain,
            //   ),

            // Layer 2: Player Video (transparan saat animasi kelar biar nampilin layer 1)
            if (_isVideoSiap)
              Opacity(
                opacity: _animasiKelar ? 0.0 : 1.0,
                child: SizedBox(
                  width: MediaQuery.of(context).size.width,
                  height: MediaQuery.of(context).size.height,
                  child: Video(
                    controller: _controller,
                    controls: NoVideoControls,
                    fill: Colors.white,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}