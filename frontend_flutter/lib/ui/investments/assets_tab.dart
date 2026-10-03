import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../data/models/investments_models.dart';
import '../../state/investments_controller.dart';
import '../../utils/amount_formatter.dart';
import '../widgets/expandable_name_text.dart';
import 'investments_account_sheets.dart';

/// Assets tab — the detailed holdings view. Assets are grouped by
/// Investment Account; the Account itself is a non-collapsible visual
/// divider (never expandable), while each Asset row is individually
/// collapsible (default collapsed). Expanding an Asset shows its read-only
/// Pot allocation breakdown — no reallocation action here (asset-level
/// reallocation is parked for a later phase, per an earlier design
/// decision).
class AssetsTab extends StatelessWidget {
  const AssetsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<InvestmentsController>();
    final accounts = controller.assetsByAccount;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
          child: Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => showCreateInvestmentsAccountSheet(context),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add New Account'),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                foregroundColor: AppColors.amount,
              ),
            ),
          ),
        ),
        Expanded(
          child: accounts.isEmpty
              ? Center(
                  child: controller.loading
                      ? const CircularProgressIndicator()
                      : Text(
                          controller.error == null
                              ? 'No accounts yet.'
                              : 'Error: ${controller.error}',
                          style: const TextStyle(color: Colors.grey),
                        ),
                )
              : ListView.builder(
                  padding: AppInsets.screen,
                  itemCount: accounts.length,
                  itemBuilder: (context, i) => _AccountGroup(account: accounts[i]),
                ),
        ),
      ],
    );
  }
}

class _AccountGroup extends StatelessWidget {
  const _AccountGroup({required this.account});

  final InvestmentsAccountAssetsDto account;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _AccountHeader(account: account),
          const SizedBox(height: 8),
          if (account.assets.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                'No assets yet.',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            )
          else
            ...account.assets.map((a) => _AssetRow(asset: a)),
        ],
      ),
    );
  }
}

/// Non-collapsible visual grouping/divider — never expandable (per spec,
/// meaning it never reveals a children list like an Asset row does). Tapping
/// anywhere on the header (other than the rename icon, which keeps its own
/// independent tap) still toggles the account name between truncated and
/// fully-wrapped, since that's the only "reveal" behavior this row has.
class _AccountHeader extends StatefulWidget {
  const _AccountHeader({required this.account});

  final InvestmentsAccountAssetsDto account;

  @override
  State<_AccountHeader> createState() => _AccountHeaderState();
}

class _AccountHeaderState extends State<_AccountHeader> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final account = widget.account;

    final broker = account.brokerName;
    final identifier = account.accountIdentifier;
    final String subtitle;
    if (broker != null && broker.isNotEmpty) {
      subtitle = identifier != null && identifier.isNotEmpty ? '$broker · $identifier' : broker;
    } else {
      subtitle = 'Broker: Not added';
    }

    return InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      borderRadius: BorderRadius.circular(8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 4,
            height: 34,
            margin: const EdgeInsets.only(top: 2, right: 10),
            decoration: BoxDecoration(
              color: cs.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExpandableNameText(
                  account.accountName,
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                  expanded: _expanded,
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => showRenameInvestmentsAccountSheet(
              context,
              accountId: account.accountId,
              currentName: account.accountName,
            ),
            icon: const Icon(Icons.edit_outlined, size: 18),
            tooltip: 'Rename account',
            style: IconButton.styleFrom(foregroundColor: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// Individually collapsible Asset row — default collapsed. Expanding shows
/// the read-only Pot allocation breakdown (view-only; no reallocation UI)
/// AND, via the same single tap, reveals the full (untruncated) asset name
/// — one tap target doing both, rather than the name having its own
/// separate reveal zone.
class _AssetRow extends StatefulWidget {
  const _AssetRow({required this.asset});

  final InvestmentsAssetDto asset;

  @override
  State<_AssetRow> createState() => _AssetRowState();
}

class _AssetRowState extends State<_AssetRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final asset = widget.asset;

    final units = double.tryParse(asset.units) ?? 0;
    final price = asset.latestPrice == null ? null : double.tryParse(asset.latestPrice!);
    final currentValue = double.tryParse(asset.currentValue) ?? 0;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Theme(
        // Remove the default divider ExpansionTile draws around itself so
        // it blends into the surrounding Card exactly like other cards.
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          onExpansionChanged: (expanded) => setState(() => _expanded = expanded),
          tilePadding: const EdgeInsets.fromLTRB(16, 4, 12, 4),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          title: ExpandableNameText(
            asset.name,
            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            expanded: _expanded,
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(
              spacing: 10,
              runSpacing: 2,
              children: [
                _MetaText(_assetClassLabel(asset.assetClass)),
                _MetaText('${_formatUnits(units)} units'),
                if (price != null) _MetaText('₹${compactAmount(price)}'),
              ],
            ),
          ),
          trailing: Text(
            '₹${compactAmount(currentValue)}',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: AppColors.amount,
            ),
          ),
          children: [
            Divider(height: 1, color: cs.outlineVariant),
            const SizedBox(height: 10),
            Row(
              children: [
                Text(
                  'Current Value',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  '₹${compactAmount(currentValue)}',
                  style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ...asset.potAllocations.map((alloc) => _PotAllocationRow(allocation: alloc)),
          ],
        ),
      ),
    );
  }
}

class _PotAllocationRow extends StatelessWidget {
  const _PotAllocationRow({required this.allocation});

  final InvestmentsPotAllocationDto allocation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final pct = double.tryParse(allocation.percentage) ?? 0;
    final amount = double.tryParse(allocation.amount) ?? 0;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              allocation.potName,
              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 52,
            child: Text(
              '${pct.toStringAsFixed(pct == pct.roundToDouble() ? 0 : 1)}%',
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 84,
            child: Text(
              '₹${compactAmount(amount)}',
              textAlign: TextAlign.right,
              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetaText extends StatelessWidget {
  const _MetaText(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
    );
  }
}

String _assetClassLabel(String assetClass) {
  switch (assetClass) {
    case 'MUTUAL_FUND':
      return 'Mutual Fund';
    case 'STOCK':
      return 'Stock';
    case 'ETF':
      return 'ETF';
    default:
      return 'Other';
  }
}

String _formatUnits(double units) {
  if (units == units.roundToDouble()) return units.toStringAsFixed(0);
  return units.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}
