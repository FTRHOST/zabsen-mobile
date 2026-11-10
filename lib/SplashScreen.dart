import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  bool _isVideoInitialized = false;

  @override
  void initState() {
    super.initState();

    // Sembunyikan status bar & navigasi agar full screen
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);

    _player = Player();
    _controller = VideoController(_player);

    _initializeVideo();
  }

  Future<void> _initializeVideo() async {
    // Atur latar belakang mpv agar transparansi webm dirender sebagai warna putih
    try {
      final dynamic platform = _player.platform;
      await platform.setProperty('background-color', '#FFFFFF');
      await platform.setProperty('background', 'color');
    } catch (_) {}

    _player.stream.completed.listen((bool completed) {
      if (completed && mounted) {
        // Kembalikan UI sistem normal sebelum beralih ke LoginPage
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (context) => const LoginPage()),
        );
      }
    });

    await _player.open(Media('asset://assets/video/splash_white.mp4'));
    if (mounted) {
      setState(() {
        _isVideoInitialized = true;
      });
      _player.play();
    }
  }

  @override
  void dispose() {
    // Pastikan UI sistem kembali normal jika splash screen ditutup
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SizedBox.expand(
        child: _isVideoInitialized
            ? Video(
                controller: _controller,
                controls: NoVideoControls,
                fit: BoxFit.contain,
                fill: Colors.white,
              )
            : const Center(
                child: CircularProgressIndicator(
                  color: Colors.blue,
                ),
              ),
      ),
    );
  }
}
