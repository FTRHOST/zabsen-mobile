import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import 'login_page.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  late VideoPlayerController _controller;
  bool _hasNavigated = false;

  @override
  void initState() {
    super.initState();

    // Pastikan status bar terlihat & berwarna putih dengan ikon gelap
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    _controller = VideoPlayerController.asset('assets/video/splash_white.mp4')
      ..initialize().then((_) {
        if (mounted) {
          _controller.setLooping(false); // Hanya putar 1 kali
          _controller.play();
          setState(() {});
        }
      });

    _controller.addListener(_checkVideoEnd);
  }

  void _checkVideoEnd() {
    // Deteksi saat video telah selesai diputar sampai akhir
    if (_controller.value.isInitialized &&
        !_hasNavigated &&
        _controller.value.position >= _controller.value.duration) {
      _hasNavigated = true;
      _controller.pause(); // Pertahankan (freeze) frame terakhir

      // Tahan frame terakhir sejenak, lalu transisi halus (fade) ke LoginPage
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) {
          Navigator.of(context).pushReplacement(
            PageRouteBuilder(
              pageBuilder: (context, animation, secondaryAnimation) =>
                  const LoginPage(),
              transitionsBuilder:
                  (context, animation, secondaryAnimation, child) {
                    return FadeTransition(opacity: animation, child: child);
                  },
              transitionDuration: const Duration(milliseconds: 400),
            ),
          );
        }
      });
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_checkVideoEnd);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.white,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemNavigationBarColor: Colors.white,
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: _controller.value.isInitialized
              ? AspectRatio(
                  aspectRatio: _controller.value.aspectRatio,
                  child: VideoPlayer(_controller),
                )
              : const SizedBox.shrink(),
        ),
      ),
    );
  }
}
