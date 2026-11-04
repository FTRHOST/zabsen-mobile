import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

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

    MediaKit.ensureInitialized();

    _player = Player();

    _controller = VideoController(_player);

    _player.open(Media('asset://assets/video/splash.webm')).then((_) {
      setState(() {
        _isVideoInitialized = true;
      });
      _player.play();
    });

    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {}
    });
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
        child: _isVideoInitialized
            ? SizedBox(
                width: MediaQuery.of(context).size.width,
                height: MediaQuery.of(context).size.height,
                child: Video(
                  controller: _controller,
                  controls: NoVideoControls,
                  fill: Colors.transparent,
                ),
              )
            : const CircularProgressIndicator(
                color: Colors.blue,
              ), // Menunggu video siap
      ),
    );
  }
}
