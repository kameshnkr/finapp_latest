import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../core/date_utils.dart' as du;
import '../../data/models/investments_models.dart';
import '../../utils/amount_formatter.dart';

/// Groups a list of trades into a flat list suitable for a single
/// ListView.builder: a [TradeDateSectionHeader] widget before each date's
/// trades, plus a [TradeMonthDivider] widget whenever the month changes
/// between two consecutive date groups. Assumes [trades] is already ordered
/// by transactionDate descending — true for every backend trades query
/// (both Unlabeled and Labeled use `ORDER BY transaction_date DESC, id
/// DESC`), so same-date trades are always contiguous.
///
/// Mirrors Banking's SettledPage day-header pattern exactly (same
/// [du.sectionLabel] labels — "Today"/"Yesterday"/"Wed, 30 Sep" — same
/// daily-total idea, just BUY/SELL totals here instead of credit/debit) so
/// the two sections of the app feel consistent. The month divider is the
/// one addition Banking's page doesn't have, since a single Investments
/// Account's trade history can realistically span many months.
///
/// Returned items are the actual header/divider *widgets* (not separate
/// data classes) so both UnlabeledTradesPage and LabeledTradesPage can
/// share this one function without each needing its own
/// "wrap data into widget" step.
List<Object> buildTradeDateSections(List<InvestmentsTradeDto> trades) {
  final result = <Object>[];
  final grouped = <String, List<InvestmentsTradeDto>>{};
  final dateOrder = <String>[];

  for (final t in trades) {
    final key = t.transactionDate;
    if (!grouped.containsKey(key)) {
      grouped[key] = [];
      dateOrder.add(key);
    }
    grouped[key]!.add(t);
  }

  String? lastMonthKey;
  for (final date in dateOrder) {
    final group = grouped[date]!;
    double buyTotal = 0, sellTotal = 0;
    for (final t in group) {
      final amt = double.tryParse(t.amount) ?? 0;
      if (t.isBuy) {
        buyTotal += amt;
      } else {
        sellTotal += amt;
      }
    }

    final monthKey = date.length >= 7 ? date.substring(0, 7) : date;
    if (lastMonthKey != null && monthKey != lastMonthKey) {
      result.add(TradeMonthDivider(monthLabel: _monthLabel(date)));
    }
    lastMonthKey = monthKey;

    result.add(
      TradeDateSectionHeader(
        dateKey: date,
        buyTotal: buyTotal,
        sellTotal: sellTotal,
      ),
    );
    result.addAll(group);
  }
  return result;
}

const _kMonthNames = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// "2026-07-06" → "July 2026". Deliberately self-contained here rather than
/// added to the shared core/date_utils.dart — this exact "full month name +
/// year" format isn't needed anywhere in Banking, so keeping it local avoids
/// touching shared code for an Investments-only need.
String _monthLabel(String dateKey) {
  final parts = dateKey.split('-');
  if (parts.length < 2) return dateKey;
  final monthIndex = int.tryParse(parts[1]);
  if (monthIndex == null || monthIndex < 1 || monthIndex > 12) return dateKey;
  return '${_kMonthNames[monthIndex - 1]} ${parts[0]}';
}

/// Day header for a group of same-date trades — label + that day's total
/// BUY/SELL amounts, styled identically to Banking's day header.
class TradeDateSectionHeader extends StatelessWidget {
  const TradeDateSectionHeader({
    super.key,
    required this.dateKey,
    required this.buyTotal,
    required this.sellTotal,
  });

  final String dateKey;
  final double buyTotal;
  final double sellTotal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
      child: Row(
        children: [
          Text(
            du.sectionLabel(dateKey),
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: cs.onSurfaceVariant,
              letterSpacing: 0.3,
            ),
          ),
          const Spacer(),
          if (buyTotal > 0.005) ...[
            Text(
              'Buy ₹${compactAmount(buyTotal)}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.gain,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (buyTotal > 0.005 && sellTotal > 0.005) const SizedBox(width: 8),
          if (sellTotal > 0.005)
            Text(
              'Sell ₹${compactAmount(sellTotal)}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.loss,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
    );
  }
}

/// Labeled section break ("── July 2026 ──") inserted whenever consecutive
/// date groups fall in different calendar months — the month name centered
/// on the line reads far more clearly than a bare rule, and is a bit more
/// prominent than a normal card border so a long trade history visually
/// breaks into month-sized chunks.
class TradeMonthDivider extends StatelessWidget {
  const TradeMonthDivider({super.key, required this.monthLabel});

  final String monthLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final lineColor = cs.outline.withAlpha(60);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: 28, child: Divider(height: 1, thickness: 0.75, color: lineColor)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                monthLabel,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w500,
                  color: cs.onSurfaceVariant.withAlpha(180),
                  letterSpacing: 0.2,
                ),
              ),
            ),
            SizedBox(width: 28, child: Divider(height: 1, thickness: 0.75, color: lineColor)),
          ],
        ),
      ),
    );
  }
}
