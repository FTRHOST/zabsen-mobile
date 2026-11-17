import 'package:flutter_test/flutter_test.dart';
import 'package:zabsen/hari_libur.dart';

void main() {
  test('parseHariLibur menerima format angka getDay()', () {
    expect(parseHariLibur('0,6'), {0, 6});
    expect(parseHariLibur('2'), {2});
    expect(parseHariLibur(''), isEmpty);
    expect(parseHariLibur(null), isEmpty);
  });

  test('parseHariLibur menerima nama hari', () {
    expect(parseHariLibur('Minggu, Sabtu'), {0, 6});
    expect(parseHariLibur('Sen'), {1});
    expect(parseHariLibur('minggu'), {0});
  });

  test('weekdayIndex memakai urutan Minggu=0 ... Sabtu=6', () {
    expect(weekdayIndex(DateTime(2026, 11, 15)), 0); // Minggu
    expect(weekdayIndex(DateTime(2026, 11, 16)), 1); // Senin
    expect(weekdayIndex(DateTime(2026, 11, 21)), 6); // Sabtu
  });
}
