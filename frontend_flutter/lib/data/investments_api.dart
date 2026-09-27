import 'api_client.dart';
import 'models/investments_models.dart';

/// Independent Investments API client — reuses only the generic [ApiClient]
/// (same auth token, same base URL). Never imports or depends on
/// [FinappApi]/Banking's models; kept fully separate per the Investments
/// architecture mandate.
class InvestmentsApi {
  InvestmentsApi(this._client);

  final ApiClient _client;

  /// GET /api/investments/pots/ — Total Portfolio Value + active Pots.
  /// Lazily triggers default-data bootstrap server-side on first call for a
  /// new user (mirrors Banking's implicit bootstrap-on-first-fetch).
  Future<InvestmentsPortfolioDto> fetchPortfolio() async {
    final j = await _client.getJson('/api/investments/pots/') as Map<String, dynamic>;
    return InvestmentsPortfolioDto.fromJson(j);
  }

  /// GET /api/investments/accounts/ — plain Account list (incl. version).
  Future<List<InvestmentsAccountDto>> fetchAccounts() async {
    final j = await _client.getJson('/api/investments/accounts/') as Map<String, dynamic>;
    final list = j['accounts'] as List<dynamic>? ?? [];
    return list.map((e) => InvestmentsAccountDto.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// POST /api/investments/accounts/ — name required, brokerName optional.
  Future<InvestmentsAccountDto> createAccount({
    required String name,
    String? brokerName,
  }) async {
    final j = await _client.postJson('/api/investments/accounts/', body: {
      'name': name,
      if (brokerName != null && brokerName.isNotEmpty) 'brokerName': brokerName,
    }) as Map<String, dynamic>;
    return InvestmentsAccountDto.fromJson(j['account'] as Map<String, dynamic>);
  }

  /// PATCH /api/investments/accounts/:id — rename only (optimistic
  /// concurrency via [version]).
  Future<InvestmentsAccountDto> renameAccount({
    required String accountId,
    required String name,
    required int version,
  }) async {
    final j = await _client.patchJson(
      '/api/investments/accounts/$accountId',
      body: {'name': name, 'version': version},
    ) as Map<String, dynamic>;
    return InvestmentsAccountDto.fromJson(j['account'] as Map<String, dynamic>);
  }

  /// GET /api/investments/assets/ — Assets grouped by Account, each carrying
  /// its read-only Pot allocation breakdown.
  Future<List<InvestmentsAccountAssetsDto>> fetchAssetsGroupedByAccount() async {
    final j = await _client.getJson('/api/investments/assets/') as Map<String, dynamic>;
    final list = j['accounts'] as List<dynamic>? ?? [];
    return list
        .map((e) => InvestmentsAccountAssetsDto.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ── Add Trade upload (Holdings + Trade Book, two files mandatory) ────────

  /// POST /api/investments/uploads/upload — kicks off the async
  /// parse→reconcile→save pipeline. Returns the new job id immediately;
  /// poll [getUploadStatus] for progress.
  Future<String> uploadTrades({
    required String accountId,
    required List<int> holdingsBytes,
    required String holdingsFileName,
    required List<int> tradeBookBytes,
    required String tradeBookFileName,
  }) async {
    final j = await _client.postMultipartMultiBytes(
      '/api/investments/uploads/upload',
      files: [
        MultipartFilePart(fieldName: 'holdings', bytes: holdingsBytes, fileName: holdingsFileName),
        MultipartFilePart(fieldName: 'tradeBook', bytes: tradeBookBytes, fileName: tradeBookFileName),
      ],
      fields: {'accountId': accountId},
    ) as Map<String, dynamic>;
    return j['jobId'] as String;
  }

  /// GET /api/investments/uploads/status?jobId=... — poll target.
  Future<InvestmentsUploadJobStatusDto> getUploadStatus(String jobId) async {
    final j = await _client.getJson(
      '/api/investments/uploads/status',
      queryParams: {'jobId': jobId},
    ) as Map<String, dynamic>;
    return InvestmentsUploadJobStatusDto.fromJson(j);
  }

  /// POST /api/investments/uploads/confirm — resolves an
  /// AWAITING_CONFIRMATION job. [mismatchResolutions] should include one
  /// entry per mismatch the user was shown (missing entries are treated as
  /// "skip" server-side).
  Future<void> confirmUpload({
    required String jobId,
    required List<Map<String, dynamic>> mismatchResolutions,
  }) async {
    await _client.postJson(
      '/api/investments/uploads/confirm',
      body: {'jobId': jobId, 'mismatchResolutions': mismatchResolutions},
    );
  }

  /// POST /api/investments/uploads/reject — discards every pending trade in
  /// an AWAITING_CONFIRMATION job.
  Future<void> rejectUpload(String jobId) async {
    await _client.postJson('/api/investments/uploads/reject', body: {'jobId': jobId});
  }

  // ── Trades: Unlabeled / Labeled lists + allocation ───────────────────────

  /// GET /api/investments/trades/unlabeled — cursor-paginated.
  Future<InvestmentsTradesPageDto> fetchUnlabeledTrades({String? cursor, int limit = 50}) async {
    final j = await _client.getJson('/api/investments/trades/unlabeled', queryParams: {
      'limit': '$limit',
      'cursor': ?cursor,
    }) as Map<String, dynamic>;
    return InvestmentsTradesPageDto.fromJson(j);
  }

  /// GET /api/investments/trades/labeled — cursor-paginated; each trade
  /// already carries its Pot allocation breakdown.
  Future<InvestmentsTradesPageDto> fetchLabeledTrades({String? cursor, int limit = 50}) async {
    final j = await _client.getJson('/api/investments/trades/labeled', queryParams: {
      'limit': '$limit',
      'cursor': ?cursor,
    }) as Map<String, dynamic>;
    return InvestmentsTradesPageDto.fromJson(j);
  }

  /// POST /api/investments/trades/allocate — labels one or more Unlabeled
  /// trades. Exactly 3 supported shapes (enforced server-side too):
  ///   - N trades → 1 Pot        (allocations.length == 1)
  ///   - 1 trade  → N Pots       (allocations sum to 100%)
  /// Throws [ApiException] on validation failure — in particular a 400 with
  /// the exact SELL-insufficient-units message the caller should surface
  /// verbatim.
  Future<int> allocateTrades({
    required List<String> transactionIds,
    required List<({String potId, double percentage})> allocations,
  }) async {
    final j = await _client.postJson('/api/investments/trades/allocate', body: {
      'transactionIds': transactionIds,
      'allocations': allocations.map((a) => {'potId': a.potId, 'percentage': a.percentage}).toList(),
    }) as Map<String, dynamic>;
    return j['allocatedCount'] as int;
  }

  // ── Manual price refresh (Mutual Fund/ETF NAVs only) ─────────────────────

  /// POST /api/investments/prices/refresh — manual, user-triggered NAV
  /// refresh. The server enforces a per-user in-flight guard: a concurrent
  /// call while one is already running throws [ApiException] with status
  /// 409, which the caller should surface as-is (message is already
  /// user-friendly).
  Future<InvestmentsPriceRefreshResultDto> refreshPrices() async {
    final j = await _client.postJson('/api/investments/prices/refresh') as Map<String, dynamic>;
    return InvestmentsPriceRefreshResultDto.fromJson(j);
  }
}
