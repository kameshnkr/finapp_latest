import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/models/models.dart';
import '../../core/snack_utils.dart';
import '../../state/app_controller.dart';
import '../../utils/amount_formatter.dart';
import 'account_balance_adjust_sheet.dart';
import 'budget_reallocation_sheet.dart';

class AccountEditSheet extends StatefulWidget {
  const AccountEditSheet({super.key, required this.accountId});

  final String accountId;

  @override
  State<AccountEditSheet> createState() => _AccountEditSheetState();
}

class _AccountEditSheetState extends State<AccountEditSheet> {
  late final TextEditingController _name = TextEditingController();
  bool _saving = false;

  // Seed text controllers once per account version to stay fresh after
  // a reallocation updates the account in the controller.
  int _seededVersion = -1;

  AccountDto? _findAccount(List<AccountDto> accounts) {
    for (final a in accounts) {
      if (a.id == widget.accountId) return a;
    }
    return null;
  }

  void _seedIfNeeded(AccountDto account) {
    if (_seededVersion != account.version) {
      _name.text = account.name;
      _seededVersion = account.version;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  double _totalAllocated(List<AllocationDto> allocs) {
    double s = 0;
    for (final a in allocs) {
      s += double.tryParse(a.amount) ?? 0;
    }
    return s;
  }

  Future<void> _save(AccountDto account) async {
    final nameVal = _name.text.trim();
    if (nameVal.isEmpty) return;

    final allocs = account.allocations
        .map((a) => {'budgetId': a.budgetId, 'amount': a.amount})
        .toList();

    final app = context.read<AppController>();
    setState(() => _saving = true);
    try {
      await app.api.updateAccount(
        account.id,
        name: nameVal,
        totalBalance: account.totalBalance,
        version: account.version,
        allocations: allocs,
      );
      await app.refreshAccountsBudgets();
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      showTopSnack(context, 'Error: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final accounts = context.watch<AppController>().accounts;
    final account = _findAccount(accounts);

    if (account == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
      return const SizedBox.shrink();
    }

    _seedIfNeeded(account);

    final balance = double.tryParse(account.totalBalance) ?? 0;
    final totalAlloc = _totalAllocated(account.allocations);
    final unallocated = balance - totalAlloc;
    final isOver = unallocated < -0.001;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollCtrl) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Progress / drag handle ──────────────────────────────────
            if (_saving)
              LinearProgressIndicator(minHeight: 3, color: cs.primary)
            else
              const SizedBox(height: 3),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: cs.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),

            // ── Title row ───────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Edit Account',
                        style: theme.textTheme.titleLarge
                            ?.copyWith(fontWeight: FontWeight.w600)),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 4),
                  FilledButton(
                    onPressed: _saving ? null : () => _save(account),
                    child: const Text('Save'),
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Divider(height: 1, color: cs.outlineVariant),

            // ── FIXED FORM AREA ─────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Account name — label + field inline
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 96,
                        child: _SectionLabel(label: 'Name'),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _name,
                          textCapitalization: TextCapitalization.words,
                          decoration: const InputDecoration(
                            isDense: true,
                            hintText: 'e.g. HDFC Savings',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // Total balance — read-only display + Adjust button
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 96,
                        child: _SectionLabel(label: 'Balance'),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '₹ ${account.totalBalance}',
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(width: 4),
                      TextButton.icon(
                        onPressed: () =>
                            showAccountBalanceAdjustSheet(context, account),
                        icon: const Icon(Icons.tune, size: 13),
                        label: const Text('Adjust'),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding:
                              const EdgeInsets.symmetric(horizontal: 8),
                          textStyle:
                              theme.textTheme.labelSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const Spacer(),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // Allocations header
                  _SectionLabel(label: 'Allocations'),
                  const SizedBox(height: 6),
                ],
              ),
            ),

            // ── SCROLLABLE BUDGET LIST ──────────────────────────────────
            Expanded(
                child: Container(
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest.withAlpha(60),
                  border: Border(
                    top: BorderSide(color: cs.outlineVariant.withAlpha(140)),
                    bottom: BorderSide(color: cs.outlineVariant.withAlpha(140)),
                  ),
                ),
                child: Stack(
                  children: [
                    Scrollbar(
                      controller: scrollCtrl,
                      thumbVisibility: true,
                      child: ListView(
                        controller: scrollCtrl,
                        padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
                        children: [
                        // Unallocated row — always first in the list
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Row(
                            children: [
                              Icon(
                                isOver
                                    ? Icons.warning_amber_rounded
                                    : Icons.account_balance_wallet_outlined,
                                size: 14,
                                color: isOver ? cs.error : cs.onSurfaceVariant,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  isOver ? 'Over-allocated' : 'Unallocated',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w500,
                                    color: isOver ? cs.error : cs.onSurfaceVariant,
                                  ),
                                ),
                              ),
                              Text(
                                '₹${compactAmount(unallocated)}',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: isOver
                                      ? cs.error
                                      : unallocated < 0
                                          ? Colors.red.shade700
                                          : cs.onSurfaceVariant,
                                ),
                              ),
                              SizedBox(
                                width: 80,
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Container(
                                    margin: const EdgeInsets.only(left: 4),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: isOver
                                          ? cs.errorContainer.withAlpha(80)
                                          : cs.primaryContainer.withAlpha(80),
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: Text(
                                      isOver ? 'over-spent' : 'free',
                                      style: theme.textTheme.labelSmall
                                          ?.copyWith(
                                        color:
                                            isOver ? cs.error : cs.primary,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (account.allocations.isEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text('No budgets allocated yet.',
                                style: TextStyle(color: cs.onSurfaceVariant)),
                          )
                        else
                          ...account.allocations.map((a) {
                              final amt = double.tryParse(a.amount) ?? 0;
                              final isNeg = amt < 0;
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        a.budgetName,
                                        style: theme.textTheme.bodyMedium
                                            ?.copyWith(
                                                fontWeight: FontWeight.w500),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      '₹${compactAmount(amt)}',
                                      style:
                                          theme.textTheme.bodyMedium?.copyWith(
                                        fontWeight: FontWeight.w600,
                                        color: isNeg
                                            ? Colors.red.shade700
                                            : cs.onSurfaceVariant,
                                      ),
                                    ),
                                    SizedBox(
                                      width: 80,
                                      child: TextButton.icon(
                                        onPressed: () => _openReallocation(
                                            context, account, a),
                                        icon: const Icon(Icons.tune, size: 13),
                                        label: const Text('Adjust'),
                                        style: TextButton.styleFrom(
                                          visualDensity: VisualDensity.compact,
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 8),
                                          textStyle: theme.textTheme.labelSmall
                                              ?.copyWith(
                                                  fontWeight: FontWeight.w600),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }).toList(),
                        ],  // ListView children
                      ),    // ListView
                    ),      // Scrollbar
                          // Top fade
                          Positioned(
                            top: 0, left: 0, right: 0, height: 20,
                            child: IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      cs.surfaceContainerHighest.withAlpha(120),
                                      cs.surfaceContainerHighest.withAlpha(0),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          // Bottom fade
                          Positioned(
                            bottom: 0, left: 0, right: 0, height: 28,
                            child: IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.bottomCenter,
                                    end: Alignment.topCenter,
                                    colors: [
                                      cs.surfaceContainerHighest.withAlpha(140),
                                      cs.surfaceContainerHighest.withAlpha(0),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                  ],   // Stack children
                ),     // Stack
              ),       // Container
            ),         // Expanded
          ],
        );
      },
    );
  }

  void _openReallocation(
      BuildContext context, AccountDto account, AllocationDto allocation) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => BudgetReallocationSheet(
        account: account,
        targetBudgetId: allocation.budgetId,
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      label.toUpperCase(),
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.primary,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.0,
      ),
    );
  }
}

// ── Helper used by accounts_tab to open the edit sheet ────────────────────────

void showEditAccountSheet(BuildContext context, String accountId) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => AccountEditSheet(accountId: accountId),
  );
}
