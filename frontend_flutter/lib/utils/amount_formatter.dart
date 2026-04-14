/// Formats a [double] amount into a compact Indian-style string.
///
/// Uses truncation (not rounding) to avoid showing inflated values, e.g.
/// 197900 → "1.97L" instead of "2.0L". Trailing zeros are trimmed for
/// cleaner display: 200000 → "2L", 150000 → "1.5L", 197900 → "1.97L".
String compactAmount(double v) {
  final neg = v < 0;
  final abs = v.abs();
  final sign = neg ? '-' : '';

  if (abs >= 1e7) return '$sign${_fmt(abs / 1e7)}Cr';
  if (abs >= 1e5) return '$sign${_fmt(abs / 1e5)}L';
  if (abs >= 1e3) return '$sign${_fmt(abs / 1e3)}k';
  if (abs == abs.truncateToDouble()) return '$sign${abs.toStringAsFixed(0)}';
  return '$sign${abs.toStringAsFixed(2)}';
}

/// Truncates [val] to 2 decimal places and strips trailing zeros.
String _fmt(double val) {
  final truncated = (val * 100).floor() / 100;
  final raw = truncated.toStringAsFixed(2);
  var trimmed = raw.replaceAll(RegExp(r'0+$'), '');
  if (trimmed.endsWith('.')) trimmed = trimmed.substring(0, trimmed.length - 1);
  return trimmed;
}
