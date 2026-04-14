/// Formats a YYYY-MM-DD date string to a short human-readable date.
/// E.g. "2026-03-29" → "29 Mar 2026"
String formatDate(String? yyyymmdd) {
  if (yyyymmdd == null || yyyymmdd.isEmpty) return '—';
  try {
    final parts = yyyymmdd.split('-');
    if (parts.length != 3) return yyyymmdd;
    final dt = DateTime(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
    return _format(dt, dateOnly: true);
  } catch (_) {
    return yyyymmdd;
  }
}

/// Formats an ISO-8601 UTC string to local-time human-readable form.
/// E.g. "2026-03-29T07:30:00.000Z" → "29 Mar 2026 1:00 PM" (IST, UTC+5:30)
String formatLocalDateTime(String? iso) {
  if (iso == null || iso.isEmpty) return '—';
  try {
    final utc = DateTime.parse(iso);
    final local = utc.toLocal();
    return _format(local);
  } catch (_) {
    return iso;
  }
}

String _format(DateTime dt, {bool dateOnly = false}) {
  const months = [
    'Jan','Feb','Mar','Apr','May','Jun',
    'Jul','Aug','Sep','Oct','Nov','Dec'
  ];
  final month = months[dt.month - 1];
  final day = dt.day.toString().padLeft(2, '0');
  final year = dt.year;

  if (dateOnly) return '$day $month $year';

  final hour12 = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  final minute = dt.minute.toString().padLeft(2, '0');
  final ampm = dt.hour < 12 ? 'AM' : 'PM';

  return '$day $month $year $hour12:$minute $ampm';
}
