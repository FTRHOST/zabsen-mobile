import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:zabsen/SplashScreen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(zabsen());
}

class zabsen extends StatelessWidget {
  const zabsen({super.key});

  @override
  Widget build(BuildContext context) {
    // TODO: implement build
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'zabsen - zieda absen',
      theme: ThemeData(primarySwatch: Colors.red),
      home: const SplashScreen(),
    );
  }
}
