import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/investments_models.dart';
import '../../state/investments_controller.dart';
import '../../utils/api_error_utils.dart';

/// Small, muted, manual-only "Refresh Prices" action for the Investments
/// Home AppBar (see PriceRefresh spec — never triggered automatically: not
/// on page load, not on section entry, not during statement upload).
///
/// Deliberately styled like [IconButton]'s other muted AppBar actions
/// (matches the existing Search icon) rather than a prominent primary
/// button, since this is a secondary, occasional-use affordance.
class RefreshPricesAction extends StatelessWidget {
  const RefreshPricesAction({super.key});

  @override
  Widget build(BuildContext context) {
    final refreshing = context.select<InvestmentsController, bool>((c) => c.refreshingPrices);

    return IconButton(
      tooltip: refreshing ? 'Refreshing prices…' : 'Refresh Prices',
      // Disabled while a refresh is already in flight — the button-level
      // guard the spec asks for ("prevent duplicate refresh requests from
      // being triggered simultaneously"); the backend also independently
      // enforces a per-user in-flight lock as a backstop.
      onPressed: refreshing ? null : () => _run(context),
      icon: refreshing
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.sync_rounded),
    );
  }

  Future<void> _run(BuildContext context) async {
    final controller = context.read<InvestmentsController>();
    final messenger = ScaffoldMessenger.of(context);
    // Captured before the await — never touch `context` again afterwards.
    final errorColor = Theme.of(context).colorScheme.error;
    try {
      final result = await controller.refreshPrices();
      messenger.showSnackBar(SnackBar(content: Text(_successMessage(result))));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Price refresh failed: ${friendlyApiError(e)}'),
          backgroundColor: errorColor,
        ),
      );
    }
  }

  String _successMessage(InvestmentsPriceRefreshResultDto r) {
    if (r.eligibleCount == 0) {
      return 'No Mutual Fund/ETF holdings to refresh yet.';
    }
    if (r.updatedCount > 0) {
      final skipped = r.alreadyCurrentCount > 0 ? ' (${r.alreadyCurrentCount} already up to date)' : '';
      return 'Updated ${r.updatedCount} of ${r.eligibleCount} price${r.eligibleCount == 1 ? '' : 's'}$skipped.';
    }
    if (r.alreadyCurrentCount == r.eligibleCount) {
      return 'Prices are already up to date.';
    }
    if (r.notFoundIsins.isNotEmpty) {
      return 'No NAV data found for ${r.notFoundIsins.length} holding${r.notFoundIsins.length == 1 ? '' : 's'}.';
    }
    return 'No prices needed updating.';
  }
}
