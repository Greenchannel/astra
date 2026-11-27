import 'dart:math';

const _alphabet = '23456789abcdefghjkmnpqrstuvwxyz';

final Random _random = Random.secure();

String randomToken(int length) => List<String>.generate(
      length,
      (_) => _alphabet[_random.nextInt(_alphabet.length)],
    ).join();

String newId([String prefix = '']) {
  final time = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final suffix = randomToken(10);
  return prefix.isEmpty ? '$time$suffix' : '${prefix}_$time$suffix';
}

String isoNow() => DateTime.now().toUtc().toIso8601String();
