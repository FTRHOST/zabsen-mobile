import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:zabsen/SplashScreen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Inisialisasi Supabase
  await Supabase.initialize(
    url: 'https://ddapevcpuvoduaawhkxz.supabase.co',
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRkYXBldmNwdXZvZHVhYXdoa3h6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODMyOTE4ODQsImV4cCI6MjA5ODg2Nzg4NH0.bbBQSy-b5QP3gvFNt35FdXQaE5RXrU2lj9NznXmt6z0',
  );

  runApp(const zabsen());
}

class zabsen extends StatelessWidget {
  const zabsen({super.key});

  /// Palet Material You diturunkan dari warna utama aplikasi (burgundy),
  /// sehingga komponen M3 (Filled/Outlined Button, sheet, dialog, dsb.)
  /// otomatis selaras dengan halaman Login/Absen/Profil.
  static final ColorScheme _colorScheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF500808),
    brightness: Brightness.light,
  );

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'zabsen - zieda absen',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: _colorScheme,
        scaffoldBackgroundColor: _colorScheme.surface,
        splashFactory: InkSparkle.splashFactory,
      ),
      home: const SplashScreen(),
    );
  }
}
