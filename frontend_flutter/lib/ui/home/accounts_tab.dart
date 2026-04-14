import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../data/models/models.dart';
import '../../state/app_controller.dart';
import '../../utils/amount_formatter.dart';
import 'account_edit_sheet.dart';
import 'budget_editor_sheet.dart';

class AccountsTab extends StatelessWidget {
  const AccountsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final accounts = context.watch<AppController>().accounts;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Fixed top bar ──────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
          child: Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => showCreateAccountSheet(context),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add New Account'),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
        ),
        // ── Scrollable list ────────────────────────────────────────────────
        Expanded(
          child: accounts.isEmpty
              ? const Center(
                  child: Text('No accounts yet.',
                      style: TextStyle(color: Colors.grey)),
                )
              : ListView.builder(
                  padding: AppInsets.screen,
                  itemCount: accounts.length,
                  itemBuilder: (context, i) =>
                      _AccountCard(account: accounts[i]),
                ),
        ),
      ],
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.account});

  final AccountDto account;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final a = account;
    final balance = double.tryParse(a.totalBalance) ?? 0;

    double totalAllocated = 0;
    for (final x in a.allocations) {
      totalAllocated += double.tryParse(x.amount) ?? 0;
    }
    final unallocated = balance - totalAllocated;
    final unallocatedColor =
        unallocated < 0 ? AppColors.loss : cs.onSurfaceVariant;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Header: name + balance + edit ─────────────────────────────
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(a.name,
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      // Balance — featured number (same visual weight as
                      // Spent/Available in budget cards)
                      Text(
                        compactAmount(balance),
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: AppColors.amount,
                          letterSpacing: -0.3,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => showEditAccountSheet(context, a.id),
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  tooltip: 'Edit account',
                  style: IconButton.styleFrom(
                    foregroundColor: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),

            // ── Secondary line: Allocated · Unallocated ───────────────────
            // Mirrors "Planned · Spent" in budget cards
            if (a.allocations.isNotEmpty) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  _SecondaryChip(
                    label: 'Allocated',
                    value: compactAmount(totalAllocated),
                    color: cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 16),
                  _SecondaryChip(
                    label: 'Unallocated',
                    value: compactAmount(unallocated),
                    color: unallocatedColor,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Divider(height: 1, color: cs.outlineVariant),
              const SizedBox(height: 10),

              // ── Per-budget allocation list ─────────────────────────────
              ...a.allocations.map((x) {
                final amt = double.tryParse(x.amount) ?? 0;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        margin: const EdgeInsets.only(right: 8, top: 1),
                        decoration: BoxDecoration(
                          color: cs.onSurfaceVariant.withAlpha(140),
                          shape: BoxShape.circle,
                        ),
                      ),
                      Expanded(
                        child: Text(x.budgetName,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: cs.onSurfaceVariant)),
                      ),
                      Text(
                        compactAmount(amt),
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: amt < 0 ? AppColors.loss : cs.onSurface,
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ],
        ),
      ),
    );
  }
}

class _SecondaryChip extends StatelessWidget {
  const _SecondaryChip({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label ',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: cs.onSurfaceVariant)),
        Text(value,
            style: theme.textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            )),
      ],
    );
  }
}
