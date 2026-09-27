import 'package:flutter/foundation.dart';

import '../data/api_client.dart';
import '../data/investments_api.dart';
import '../data/models/investments_models.dart';

/// Independent Investments state — a separate ChangeNotifier, deliberately
/// NOT merged into [AppController] (Banking's controller). Shares only the
/// generic [ApiClient] instance (same token) so login/logout stay a single
/// source of truth; everything else here is Investments-only.
class InvestmentsController extends ChangeNotifier {
  InvestmentsController({required ApiClient apiClient})
      : _api = InvestmentsApi(apiClient);

  final InvestmentsApi _api;

  /// Exposed for pages that need one-off calls not modeled as shared
  /// reactive state (trade uploads, paginated trade lists, allocation) —
  /// mirrors AppController's `api` getter.
  InvestmentsApi get api => _api;

  InvestmentsPortfolioDto? portfolio;
  List<InvestmentsAccountDto> accounts = [];
  List<InvestmentsAccountAssetsDto> assetsByAccount = [];
  bool loading = false;
  String? error;

  /// True while a manual price refresh is in flight — drives the muted
  /// "Refresh Prices" action's disabled/spinner state on the Home screen.
  /// Purely a client-side UX guard against double-tapping the same button;
  /// the backend has its own authoritative per-user in-flight lock (a
  /// concurrent call while this is already true would hit that and throw a
  /// 409, but the button being disabled means the user can't trigger that
  /// from this screen).
  bool refreshingPrices = false;

  /// Loads Pots-tab + Assets-tab data together (Total Portfolio Value,
  /// Pots, plain Accounts, and Assets-grouped-by-Account). Called once when
  /// the user first enters the Investments section — see
  /// InvestmentsSectionRoot's lazy-load-on-first-active logic.
  Future<void> loadHome() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      final results = await Future.wait([
        _api.fetchPortfolio(),
        _api.fetchAccounts(),
        _api.fetchAssetsGroupedByAccount(),
      ]);
      portfolio = results[0] as InvestmentsPortfolioDto;
      accounts = results[1] as List<InvestmentsAccountDto>;
      assetsByAccount = results[2] as List<InvestmentsAccountAssetsDto>;
    } catch (e) {
      error = e.toString();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// Quiet refresh (no full-screen loading flag) after a mutation — mirrors
  /// AppController.resetBudget's pattern of refreshing in the background.
  Future<void> _quietRefresh() async {
    try {
      final results = await Future.wait([
        _api.fetchPortfolio(),
        _api.fetchAccounts(),
        _api.fetchAssetsGroupedByAccount(),
      ]);
      portfolio = results[0] as InvestmentsPortfolioDto;
      accounts = results[1] as List<InvestmentsAccountDto>;
      assetsByAccount = results[2] as List<InvestmentsAccountAssetsDto>;
      notifyListeners();
    } catch (_) {
      // Best-effort — the mutating call itself already succeeded; a failed
      // background refresh just means the UI stays slightly stale until
      // the next successful load.
    }
  }

  /// Throws on failure (e.g. duplicate name) — callers (the create sheet)
  /// catch and show an inline error, matching Banking's sheet pattern.
  Future<void> createAccount({required String name, String? brokerName}) async {
    await _api.createAccount(name: name, brokerName: brokerName);
    await _quietRefresh();
  }

  /// Public re-fetch, exposed for pages that mutate trades (upload confirm,
  /// allocation) elsewhere and need Pot/Asset current-values to reflect the
  /// change once they navigate back to Home.
  Future<void> refreshHome() => _quietRefresh();

  Future<void> renameAccount({required String accountId, required String name}) async {
    InvestmentsAccountDto? existing;
    for (final a in accounts) {
      if (a.id == accountId) {
        existing = a;
        break;
      }
    }
    if (existing == null) {
      throw StateError('Account not found locally — refresh and try again.');
    }
    await _api.renameAccount(accountId: accountId, name: name, version: existing.version);
    await _quietRefresh();
  }

  /// Manual, user-triggered NAV refresh (Mutual Fund/ETF assets only — see
  /// PriceRefresh spec). Throws on failure (the calling widget shows a
  /// SnackBar with the message); on success, always re-fetches Pot/Asset
  /// current values so the refreshed prices are reflected immediately
  /// without the user having to leave and re-enter the section.
  ///
  /// Never called automatically (not on page load, not on section entry,
  /// not during statement upload) — only from the explicit button tap.
  Future<InvestmentsPriceRefreshResultDto> refreshPrices() async {
    refreshingPrices = true;
    notifyListeners();
    try {
      final result = await _api.refreshPrices();
      // Best-effort: the refresh itself already succeeded even if this
      // background re-fetch fails, so don't let it turn a successful
      // refresh into an error the user sees.
      await _quietRefresh();
      return result;
    } finally {
      refreshingPrices = false;
      notifyListeners();
    }
  }
}
