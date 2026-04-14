import 'package:flutter/foundation.dart';

import '../data/api_client.dart';
import '../data/finapp_api.dart';
import '../data/models/models.dart';
import '../data/session_store.dart';

/// Pagination state for a single transaction list (drafts or settled).
class TxPageState {
  const TxPageState({
    this.items = const [],
    this.nextCursor,
    this.hasMore = false,
    this.isLoadingMore = false,
  });

  final List<TransactionDto> items;
  final String? nextCursor;
  final bool hasMore;
  final bool isLoadingMore;

  TxPageState copyWith({
    List<TransactionDto>? items,
    String? nextCursor,
    bool? hasMore,
    bool? isLoadingMore,
    bool clearCursor = false,
  }) {
    return TxPageState(
      items: items ?? this.items,
      nextCursor: clearCursor ? null : (nextCursor ?? this.nextCursor),
      hasMore: hasMore ?? this.hasMore,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
    );
  }
}

class AppController extends ChangeNotifier {
  AppController({
    ApiClient? apiClient,
    SessionStore? sessionStore,
  })  : _client = apiClient ?? ApiClient(),
        _session = sessionStore ?? SessionStore() {
    _api = FinappApi(_client);
  }

  final ApiClient _client;
  final SessionStore _session;
  late final FinappApi _api;

  String? _token;
  UserDto? user;
  List<AccountDto> accounts = [];
  List<BudgetDto> budgets = [];
  String? error;
  bool loading = false;

  /// Paginated state for drafts and settled lists.
  TxPageState draftsPage = const TxPageState();
  TxPageState settledPage = const TxPageState();

  /// Active date range (UTC). Initialized to last 365 days on login/restore.
  /// The `to` field is frozen at session-start time so load-more calls stay
  /// consistent with the initial load within the same session.
  late DateTime _rangeFrom;
  late DateTime _rangeTo;

  /// Convenience accessors used by existing page widgets.
  List<TransactionDto> get drafts => draftsPage.items;
  List<TransactionDto> get settled => settledPage.items;

  /// Public read-access to the active date range (UTC).
  DateTime get rangeFrom => _rangeFrom;
  DateTime get rangeTo => _rangeTo;

  bool get isAuthenticated => _token != null && _token!.isNotEmpty;

  Future<void> tryRestoreSession() async {
    final t = await _session.loadToken();
    if (t == null || t.isEmpty) return;
    _client.token = t;
    _token = t;
    try {
      await refreshAll();
      notifyListeners();
    } catch (_) {
      await _session.clear();
      _client.token = null;
      _token = null;
    }
  }

  Future<void> login(String email, String otp) async {
    error = null;
    final res = await _api.login(email, otp);
    final token = res['token'] as String;
    _client.token = token;
    _token = token;
    await _session.saveToken(token);
    final u = res['user'] as Map<String, dynamic>;
    user = UserDto.fromJson(u);
    await refreshAll();
    notifyListeners();
  }

  Future<void> logout() async {
    try {
      await _api.logout();
    } catch (_) {}
    await _session.clear();
    _client.token = null;
    _token = null;
    user = null;
    accounts = [];
    budgets = [];
    draftsPage = const TxPageState();
    settledPage = const TxPageState();
    notifyListeners();
  }

  Future<void> refreshAll() async {
    // Freeze the "to" boundary for this session window.
    _rangeTo = DateTime.now().toUtc();
    _rangeFrom = _rangeTo.subtract(const Duration(days: 365));
    loading = true;
    notifyListeners();
    try {
      accounts = await _api.fetchAccounts();
      budgets = await _api.fetchBudgets();
      await _reloadTransactions();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> refreshTransactions() async {
    loading = true;
    notifyListeners();
    try {
      await _reloadTransactions();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// Internal: fetch first page of both lists with the current date range.
  Future<void> _reloadTransactions() async {
    final from = _rangeFrom.toIso8601String();
    final to = _rangeTo.toIso8601String();
    final dResult = await _api.fetchDrafts(from: from, to: to);
    draftsPage = TxPageState(
      items: dResult.transactions,
      nextCursor: dResult.nextCursor,
      hasMore: dResult.hasMore,
    );
    final sResult = await _api.fetchSettled(from: from, to: to);
    settledPage = TxPageState(
      items: sResult.transactions,
      nextCursor: sResult.nextCursor,
      hasMore: sResult.hasMore,
    );
  }

  /// Load the next page of older drafts and prepend to the current list.
  /// With reverse:true ListView, prepended items naturally extend downward.
  Future<void> loadMoreDrafts() async {
    if (!draftsPage.hasMore || draftsPage.isLoadingMore) return;
    draftsPage = draftsPage.copyWith(isLoadingMore: true);
    notifyListeners();
    try {
      final result = await _api.fetchDrafts(
        from: _rangeFrom.toIso8601String(),
        to: _rangeTo.toIso8601String(),
        cursor: draftsPage.nextCursor,
      );
      // Older items are prepended so they appear below existing content
      // in the reversed list.
      draftsPage = TxPageState(
        items: [...result.transactions, ...draftsPage.items],
        nextCursor: result.nextCursor,
        hasMore: result.hasMore,
      );
    } catch (_) {
      draftsPage = draftsPage.copyWith(isLoadingMore: false);
    } finally {
      notifyListeners();
    }
  }

  /// Load the next page of older settled transactions and append to the list.
  Future<void> loadMoreSettled() async {
    if (!settledPage.hasMore || settledPage.isLoadingMore) return;
    settledPage = settledPage.copyWith(isLoadingMore: true);
    notifyListeners();
    try {
      final result = await _api.fetchSettled(
        from: _rangeFrom.toIso8601String(),
        to: _rangeTo.toIso8601String(),
        cursor: settledPage.nextCursor,
      );
      settledPage = TxPageState(
        items: [...settledPage.items, ...result.transactions],
        nextCursor: result.nextCursor,
        hasMore: result.hasMore,
      );
    } catch (_) {
      settledPage = settledPage.copyWith(isLoadingMore: false);
    } finally {
      notifyListeners();
    }
  }

  /// Reset to the default 365-day range and reload only if the range changed.
  /// Called on entry to Drafts / Settled so every visit starts fresh.
  Future<void> resetDateRange() async {
    final newTo = DateTime.now().toUtc();
    final newFrom = newTo.subtract(const Duration(days: 365));
    final alreadyDefault =
        (_rangeFrom.difference(newFrom)).abs() < const Duration(hours: 2);
    if (!alreadyDefault) {
      await setDateRange(newFrom, newTo);
    }
  }

  /// Update the active date range and reload both transaction lists from scratch.
  Future<void> setDateRange(DateTime from, DateTime to) async {
    _rangeFrom = from.toUtc();
    _rangeTo = to.toUtc();
    loading = true;
    notifyListeners();
    try {
      await _reloadTransactions();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> refreshAccountsBudgets() async {
    loading = true;
    notifyListeners();
    try {
      accounts = await _api.fetchAccounts();
      budgets = await _api.fetchBudgets();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  FinappApi get api => _api;
}
