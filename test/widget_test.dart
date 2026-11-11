import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zabsen/auth_session.dart';
import 'package:zabsen/profile_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'userLogin': jsonEncode({
        'id': 1,
        'nama': 'Budi Pagi',
        'role': 'Karyawan',
        'no_hp': '081234567891',
        'cabang': 'Zieda Pusat',
        'unit': 'Operasional',
        'sisa_cuti': 12,
        'password': '123456',
      }),
    });
  });

  test('Sesi tersimpan tidak menyimpan password', () async {
    final cached = await AuthSession.readCachedUser();

    expect(cached, isNotNull);
    expect(cached!['nama'], 'Budi Pagi');
    expect(cached['password'], isNull);
  });

  testWidgets('Halaman profil menampilkan informasi pengguna', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ProfilePage())),
    );
    await tester.pumpAndSettle();

    expect(find.text('Informasi Profil'), findsOneWidget);
    expect(find.text('Budi Pagi'), findsOneWidget);
    expect(find.text('Ubah Password'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
