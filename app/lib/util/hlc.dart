import 'dart:math' as math;

/// Hybrid logical clock, serialized as `millis:counter:node`.
///
/// Ordering is numeric, so records can be merged last-write-wins across
/// devices without trusting wall-clock time alone.
class Hlc implements Comparable<Hlc> {
  const Hlc(this.millis, this.counter, this.node);

  final int millis;
  final int counter;
  final String node;

  static const zero = Hlc(0, 0, '');

  static Hlc parse(String? raw) {
    if (raw == null || raw.isEmpty) return zero;
    final parts = raw.split(':');
    if (parts.length != 3) return zero;
    return Hlc(
      int.tryParse(parts[0]) ?? 0,
      int.tryParse(parts[1]) ?? 0,
      parts[2],
    );
  }

  String encode() => '$millis:$counter:$node';

  @override
  int compareTo(Hlc other) {
    final byTime = millis.compareTo(other.millis);
    if (byTime != 0) return byTime;
    final byCounter = counter.compareTo(other.counter);
    if (byCounter != 0) return byCounter;
    return node.compareTo(other.node);
  }

  bool isAfter(Hlc other) => compareTo(other) > 0;

  @override
  String toString() => encode();

  @override
  bool operator ==(Object other) =>
      other is Hlc &&
      other.millis == millis &&
      other.counter == counter &&
      other.node == node;

  @override
  int get hashCode => Object.hash(millis, counter, node);
}

class HlcClock {
  HlcClock(this.node);

  final String node;
  Hlc _last = Hlc.zero;

  Hlc next() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final time = math.max(now, _last.millis);
    final counter = time == _last.millis ? _last.counter + 1 : 0;
    _last = Hlc(time, counter, node);
    return _last;
  }

  Hlc observe(Hlc remote) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final maxTime = [now, _last.millis, remote.millis].reduce(math.max);
    var counter = 0;
    if (maxTime == _last.millis && maxTime == remote.millis) {
      counter = math.max(_last.counter, remote.counter) + 1;
    } else if (maxTime == _last.millis) {
      counter = _last.counter + 1;
    } else if (maxTime == remote.millis) {
      counter = remote.counter + 1;
    }
    _last = Hlc(maxTime, counter, node);
    return _last;
  }
}
