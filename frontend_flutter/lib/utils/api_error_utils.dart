/// Extracts a human-friendly message out of a thrown [Object] — in
/// particular an [ApiException] whose `toString()` includes the raw JSON
/// response body (`ApiException($status): {"error":"..."}`). Falls back to
/// the raw `toString()` when no `"error"` field is found (e.g. a network
/// failure, a timeout, or any other non-ApiException error).
///
/// Shared by every Investments widget that surfaces backend errors inline
/// (Allocate sheet, Add Trade upload, Refresh Prices) so the extraction
/// logic stays in one place.
String friendlyApiError(Object e) {
  final s = e.toString();
  final match = RegExp(r'"error"\s*:\s*"([^"]+)"').firstMatch(s);
  return match?.group(1) ?? s;
}
