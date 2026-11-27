import 'package:astra_gui/util/hlc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('HLC compares time, counter and node', () {
    expect(Hlc(100, 0, 'a').isAfter(Hlc(99, 9, 'z')), isTrue);
    expect(Hlc(100, 1, 'a').isAfter(Hlc(100, 0, 'z')), isTrue);
    expect(Hlc(100, 0, 'b').isAfter(Hlc(100, 0, 'a')), isTrue);
    expect(Hlc(100, 0, 'a'), Hlc(100, 0, 'a'));
  });

  test('HLC parses and round-trips', () {
    const value = Hlc(1700000000000, 4, 'device-1');
    expect(Hlc.parse(value.encode()), value);
    expect(Hlc.parse('garbage'), Hlc.zero);
  });

  test('clock observes remote time and remains monotonic', () {
    final clock = HlcClock('local');
    final first = clock.next();
    final remote = Hlc(first.millis + 5000, 3, 'remote');
    final observed = clock.observe(remote);
    expect(observed.isAfter(remote), isTrue);
    final next = clock.next();
    expect(next.isAfter(observed), isTrue);
  });
}
