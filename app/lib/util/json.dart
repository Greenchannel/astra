Map<String, dynamic> asMap(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.cast<String, dynamic>();
  return <String, dynamic>{};
}

List<dynamic> asList(dynamic value) =>
    value is List ? value : const <dynamic>[];

String asString(dynamic value, [String fallback = '']) =>
    value is String ? value : fallback;

String? asStringOrNull(dynamic value) => value is String ? value : null;

int asInt(dynamic value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

double? asDoubleOrNull(dynamic value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

bool asBool(dynamic value, [bool fallback = false]) =>
    value is bool ? value : fallback;

List<Map<String, dynamic>> asMapList(dynamic value) =>
    asList(value).map(asMap).toList(growable: false);
