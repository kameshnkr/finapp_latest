import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../data/models/models.dart';
import '../../state/app_controller.dart';
import '../../utils/amount_formatter.dart';
import 'budget_detail_screen.dart';
import 'budget_editor_sheet.dart';

class BudgetTab extends StatelessWidget {
  const BudgetTab({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final budgets = app.budgets;
    final accounts = app.accounts;

    // Total unallocated = Σ(totalBalance - Σ allocations) across all accounts.
    double totalUnallocated = 0;
    for (final a in accounts) {
      final balance = double.tryParse(a.totalBalance) ?? 0;
      final allocated = a.allocations.fold<double>(
        0,
        (sum, alloc) => sum + (double.tryParse(alloc.amount) ?? 0),
      );
      totalUnallocated += balance - allocated;
    }

    final cs = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final availableColor =
        totalUnallocated < 0 ? AppColors.loss : AppColors.amount;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Unallocated summary + Add button ───────────────────────────────
        if (!app.loading)
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 8, 4),
          child: Row(
            children: [
              // Compact unallocated info
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.inbox_outlined,
                      size: 13, color: cs.onSurfaceVariant),
                  const SizedBox(width: 5),
                  Text(
                    'Unallocated',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    compactAmount(totalUnallocated),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: availableColor,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () => showCreateBudgetSheet(context),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add New Budget'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
        ),
        // ── Scrollable budget list ─────────────────────────────────────────
        Expanded(
          child: budgets.isEmpty
              ? Center(
                  child: app.loading
                      ? const CircularProgressIndicator()
                      : const Text('No budgets yet.',
                          style: TextStyle(color: Colors.grey)),
                )
              : ListView.builder(
                  padding: AppInsets.screen,
                  itemCount: budgets.length,
                  itemBuilder: (context, i) => _BudgetCard(budget: budgets[i]),
                ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _BudgetCard extends StatelessWidget {
  const _BudgetCard({required this.budget});

  final BudgetDto budget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final b = budget;

    final planned = double.tryParse(b.estimated) ?? 0;
    final spent = double.tryParse(b.spent) ?? 0;
    final available = double.tryParse(b.fundsAvailable) ?? 0;
    final hasPlanned = planned > 0;
    final double pct =
        hasPlanned ? (spent / planned).clamp(0.0, 1.0).toDouble() : 0.0;
    final overBudget = spent > planned && hasPlanned;

    final estimatedColor = AppColors.number;
    final spentColor =
        spent == 0 ? cs.onSurfaceVariant : AppColors.loss;
    final availableColor =
        available < 0 ? AppColors.loss : AppColors.amount;
    final barColor = AppColors.loss.withAlpha(200);
    final dividerColor = cs.outlineVariant.withAlpha(80);

    final acctLabel = b.allocationCount == 0
        ? null
        : '${b.allocationCount} account${b.allocationCount == 1 ? '' : 's'}';

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => BudgetDetailScreen(budgetId: b.id),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Name row ──────────────────────────────────────────────
              Row(
                children: [
                  Expanded(
                    child: Text(b.name,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                  ),
                  Icon(Icons.fullscreen,
                      size: 20, color: cs.onSurfaceVariant),
                ],
              ),
              const SizedBox(height: 12),

              // ── [Estimated+Spent] · [bar] | [Funds Available] ─────────
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Left half: Estimated + Spent (right-aligned to centre)
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _StatRow(
                          label: 'Estimated',
                          value: hasPlanned ? compactAmount(planned) : '—',
                          valueColor: estimatedColor,
                          bold: true,
                        ),
                        const SizedBox(height: 8),
                        _StatRow(
                          label: 'Spent',
                          value: compactAmount(spent),
                          valueColor: spentColor,
                          bold: true,
                        ),
                      ],
                    ),
                  ),
                  // Vertical bar pinned at exact centre
                  _VerticalBar(
                    pct: pct,
                    hasPlanned: hasPlanned,
                    overBudget: overBudget,
                    barColor: barColor,
                  ),
                  // Right half: Funds Available (centered in right half)
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 0.5,
                          height: 48,
                          color: dividerColor,
                        ),
                        const SizedBox(width: 14),
                        _StatColumn(
                          label: 'Funds Available',
                          value: compactAmount(available),
                          valueColor: availableColor,
                          bold: true,
                          subtitle: acctLabel,
                          icon: Icons.account_balance_wallet_outlined,
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              // ── Period / schedule info ─────────────────────────────────
              _PeriodRow(budget: b),
            ],
          ),
        ),
      ),
    );
  }

}

// ── Inline label + value row for left-side stats ──────────────────────────────

class _StatRow extends StatelessWidget {
  const _StatRow({
    required this.label,
    required this.value,
    required this.valueColor,
    this.bold = false,
  });

  final String label;
  final String value;
  final Color valueColor;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
        Flexible(
          child: Text(
            value,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: valueColor,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}

// ── Centered stat column (label · value · optional subtitle) ──────────────────

class _StatColumn extends StatelessWidget {
  const _StatColumn({
    required this.label,
    required this.value,
    required this.valueColor,
    this.bold = false,
    this.subtitle,
    this.icon,
  });

  final String label;
  final String value;
  final Color valueColor;
  final bool bold;
  final String? subtitle;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 11, color: cs.onSurfaceVariant),
              const SizedBox(width: 3),
            ],
            Text(
              label,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: cs.onSurfaceVariant, height: 1.2),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: theme.textTheme.titleMedium?.copyWith(
            color: valueColor,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(
            subtitle!,
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(
              color: cs.onSurfaceVariant.withAlpha(150),
              fontSize: 9,
            ),
          ),
        ],
      ],
    );
  }
}

// ── Vertical progress bar ──────────────────────────────────────────────────────

class _VerticalBar extends StatelessWidget {
  const _VerticalBar({
    required this.pct,
    required this.hasPlanned,
    required this.overBudget,
    required this.barColor,
  });

  final double pct;
  final bool hasPlanned;
  final bool overBudget;
  final Color barColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final label = hasPlanned ? '${(pct * 100).round()}%' : '-';
    final labelColor =
        overBudget ? Colors.red.shade700 : cs.onSurfaceVariant;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 10,
          height: 44,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: Stack(
              alignment: Alignment.bottomCenter,
              children: [
                Container(color: cs.surfaceContainerHighest),
                FractionallySizedBox(
                  heightFactor: hasPlanned ? pct.clamp(0.0, 1.0) : 0.0,
                  alignment: Alignment.bottomCenter,
                  child: Container(color: barColor),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: labelColor,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

// ── Period row ─────────────────────────────────────────────────────────────────

String _shortMonth(int month) {
  const m = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  return m[month - 1];
}

String _fmtDate(DateTime d) => '${_shortMonth(d.month)} ${d.day}';

class _PeriodRow extends StatelessWidget {
  const _PeriodRow({required this.budget});

  final BudgetDto budget;

  @override
  Widget build(BuildContext context) {
    final b = budget;
    final cs = Theme.of(context).colorScheme;

    final startDt = b.periodStart != null
        ? DateTime.parse(b.periodStart!).toLocal()
        : null;

    // period_end is exclusive – subtract 1 day to get the last day of the period
    final endDt = b.periodEnd != null
        ? DateTime.parse(b.periodEnd!).toLocal().subtract(const Duration(days: 1))
        : null;

    final isScheduled = b.resetType == 'scheduled';

    String? periodText;
    if (isScheduled && startDt != null && endDt != null) {
      periodText = '${_fmtDate(startDt)} – ${_fmtDate(endDt)}';
    } else if (startDt != null) {
      periodText = 'Since ${_fmtDate(startDt)}';
    }

    if (periodText == null) return const SizedBox.shrink();

    final muteColor = cs.onSurfaceVariant.withAlpha(140);
    const labelStyle = TextStyle(fontSize: 10.5, height: 1.2);

    return Padding(
      padding: const EdgeInsets.only(top: 7),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isScheduled ? Icons.autorenew_rounded : Icons.calendar_today_outlined,
            size: 10,
            color: muteColor,
          ),
          const SizedBox(width: 4),
          Text(
            periodText,
            style: labelStyle.copyWith(color: muteColor),
          ),
          if (isScheduled) ...[
            Text(
              '  ·  Monthly',
              style: labelStyle.copyWith(color: muteColor, letterSpacing: 0.2),
            ),
          ],
        ],
      ),
    );
  }
}
