import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import '../../data/models/investments_models.dart';
import '../../utils/amount_formatter.dart';

/// Shared compact trade row for Un-labeled/Labeled lists. Shows exactly the
/// fields the spec calls for: Asset, BUY/SELL, Units, Price, Amount, Trade
/// date, Account. Selection visuals (checkbox / highlight) are driven by the
/// host page; this widget itself holds no selection state.
class TradeListTile extends StatelessWidget {
  const TradeListTile({
    super.key,
    required this.trade,
    required this.onTap,
    this.selectMode = false,
    this.selected = false,
    this.highlighted = false,
    this.trailing,
  });

  final InvestmentsTradeDto trade;
  final VoidCallback onTap;
  final bool selectMode;
  final bool selected;
  /// Non-selectMode "this is the currently tapped single trade" highlight.
  final bool highlighted;
  /// Optional extra widget appended below the row (e.g. an expand chevron
  /// content area) — used by LabeledTradesPage for the allocation detail.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isBuy = trade.isBuy;
    final typeColor = isBuy ? AppColors.gain : AppColors.loss;
    final units = double.tryParse(trade.units) ?? 0;
    final price = double.tryParse(trade.price) ?? 0;
    final amount = double.tryParse(trade.amount) ?? 0;
    final active = selected || highlighted;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: active ? cs.primaryContainer.withAlpha(50) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.md),
        side: BorderSide(color: active ? cs.primary.withAlpha(120) : AppColors.cardBorder),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.md),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (selectMode) ...[
                    Checkbox(value: selected, onChanged: (_) => onTap(), visualDensity: VisualDensity.compact),
                    const SizedBox(width: 4),
                  ],
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: typeColor.withAlpha(18),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      trade.transactionType,
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: typeColor),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      trade.assetName,
                      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '₹${compactAmount(amount)}',
                    style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Padding(
                padding: EdgeInsets.only(left: selectMode ? 44 : 0),
                child: Text(
                  '${trade.transactionDate} · ${_formatUnits(units)} units @ ₹${compactAmount(price)} · ${trade.accountName}',
                  style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }
}

String _formatUnits(double units) {
  if (units == units.roundToDouble()) return units.toStringAsFixed(0);
  return units.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}
