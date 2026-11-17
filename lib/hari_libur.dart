/// Util hari libur rutin karyawan.
///
/// Nilai `users.hari_libur` dari web referensi disimpan sebagai angka ala
/// JavaScript `getDay()` (`0` = Minggu ... `6` = Sabtu), dipisahkan koma.
/// Beberapa data lama dapat berisi nama hari, sehingga keduanya didukung.
library;

const List<String> kNamaHari = [
  'Minggu',
  'Senin',
  'Selasa',
  'Rabu',
  'Kamis',
  'Jumat',
  'Sabtu',
];

/// Mengubah `hari_libur` menjadi kumpulan indeks hari: Minggu=0 ... Sabtu=6.
Set<int> parseHariLibur(dynamic raw) {
  final result = <int>{};
  if (raw == null) return result;

  final text = raw.toString().trim();
  if (text.isEmpty) return result;

  for (final part in text.split(',')) {
    final token = part.trim();
    if (token.isEmpty) continue;

    final number = int.tryParse(token);
    if (number != null) {
      if (number >= 0 && number <= 6) result.add(number);
      continue;
    }

    final lower = token.toLowerCase();
    for (var index = 0; index < kNamaHari.length; index++) {
      final name = kNamaHari[index].toLowerCase();
      if (lower == name || (lower.length >= 3 && name.startsWith(lower))) {
        result.add(index);
        break;
      }
    }
  }

  return result;
}

/// Mengubah `DateTime.weekday` (Senin=1 ... Minggu=7) ke indeks ala
/// `getDay()` (Minggu=0 ... Sabtu=6).
int weekdayIndex(DateTime date) => date.weekday % 7;
