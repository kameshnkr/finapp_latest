import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../data/models/models.dart';
import '../../core/snack_utils.dart';
import '../../state/app_controller.dart';
import '../../utils/amount_formatter.dart';

class BudgetDetailScreen extends StatefulWidget {
  const BudgetDetailScreen({super.key, required this.budgetId});

  final String budgetId;

  @override
  State<BudgetDetailScreen> createState() => _BudgetDetailScreenState();
}

class _BudgetDetailScreenState extends State<BudgetDetailScreen> {
  List<BudgetSnapshotDto> _snapshots = [];
  bool _snapshotsLoaded = false;

  String get budgetId => widget.budgetId;

  BudgetDto? _find(List<BudgetDto> budgets) {
    for (final b in budgets) {
      if (b.id == budgetId) return b;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
  }

  Future<void> _loadSnapshots() async {
    final app = context.read<AppController>();
    try {
      final snaps = await app.api.fetchBudgetSnapshots(budgetId);
      if (mounted) setState(() { _snapshots = snaps; _snapshotsLoaded = true; });
    } catch (_) {
      if (mounted) setState(() => _snapshotsLoaded = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final b = _find(app.budgets);
    if (b == null) {
      return const Scaffold(body: Center(child: Text('Budget not found')));
    }

    final planned   = double.tryParse(b.estimated) ?? 0;
    final spent     = double.tryParse(b.spent) ?? 0;
    final available = double.tryParse(b.fundsAvailable) ?? 0;
    final hasPlanned = planned > 0;
    final pct        = hasPlanned ? (spent / planned).clamp(0.0, 1.0).toDouble() : 0.0;
    final overBudget = spent > planned && hasPlanned;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(b.name,
                  overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 6),
            InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => _showEditSheet(context, b),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(Icons.edit_outlined,
                    size: 16,
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
        actions: [],
      ),
      body: ListView(
        padding: AppInsets.screen,
        children: [
          // ── Summary card — mirrors list card layout ─────────────────────
          _BudgetSummaryCard(
            budget: b,
            planned: planned,
            spent: spent,
            available: available,
            hasPlanned: hasPlanned,
            pct: pct,
            overBudget: overBudget,
          ),
          const SizedBox(height: 6),

          // ── Snapshot history button ──────────────────────────────────────
          _ShowHistoryButton(
            budgetId: budgetId,
            onLoad: (snaps) => setState(() {
              _snapshots = snaps;
              _snapshotsLoaded = true;
            }),
            snapshots: _snapshots,
            loaded: _snapshotsLoaded,
          ),

          const SizedBox(height: 14),

          // ── Schedule info row (read-only) ───────────────────────────────
          _ScheduleRow(
            budget: b,
            onEdit: () => _showEditSheet(context, b),
            onReset: () => _showResetConfirmation(context, b),
          ),
          const SizedBox(height: 24),

          // ── Categories header ───────────────────────────────────────────
          Row(
            children: [
              Text(
                'Categories',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              if (b.categories.isNotEmpty) ...[
                const SizedBox(width: 8),
                _CountBadge(count: b.categories.length),
              ],
              const Spacer(),
              TextButton.icon(
                onPressed: () => _showAddCategorySheet(context, b.id),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add New'),
                style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // ── Categories with connector tree lines ────────────────────────
          if (b.categories.isEmpty)
            _EmptyCategoriesHint()
          else
            _CategoryConnectorList(
              budgetId: b.id,
              categories: b.categories,
            ),

          const SizedBox(height: 16),
        ],
      ),
    );
  }

  void _showResetConfirmation(BuildContext context, BudgetDto budget) {
    final cs = Theme.of(context).colorScheme;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset budget?'),
        content: Text(
          budget.resetType == 'scheduled'
              ? 'This will start a new period from today and clear all spending. '
                'The next period end will follow your existing schedule.'
              : 'This will clear all spending and start fresh from today.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: cs.error),
            onPressed: () async {
              Navigator.pop(ctx); // close confirm dialog
              // Show blocking loader
              showDialog<void>(
                context: context,
                barrierDismissible: false,
                builder: (_) => const PopScope(
                  canPop: false,
                  child: Center(
                    child: Card(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(),
                            SizedBox(height: 16),
                            Text('Resetting budget…'),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
              final app = context.read<AppController>();
              try {
                await app.resetBudget(budget.id);
              } catch (e) {
                if (context.mounted) {
                  Navigator.pop(context); // close loader
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Reset failed: $e')),
                  );
                  return;
                }
              }
              if (context.mounted) {
                Navigator.pop(context); // close loader
                // Invalidate snapshot cache so next open re-fetches
                setState(() { _snapshots = []; _snapshotsLoaded = false; });
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Budget reset successfully'),
                    duration: Duration(seconds: 2),
                  ),
                );
              }
            },
            child: const Text('Reset'),
          ),
        ],
      ),
    );
  }

  void _showEditSheet(BuildContext context, BudgetDto budget) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _BudgetEditSheet(budget: budget),
    );
  }

  void _showAddCategorySheet(BuildContext context, String budgetId) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AddCategorySheet(budgetId: budgetId),
    );
  }
}

// ── Snapshot history carousel ─────────────────────────────────────────────────

class _ShowHistoryButton extends StatefulWidget {
  const _ShowHistoryButton({
    required this.budgetId,
    required this.onLoad,
    required this.snapshots,
    required this.loaded,
  });
  final String budgetId;
  final void Function(List<BudgetSnapshotDto>) onLoad;
  final List<BudgetSnapshotDto> snapshots;
  final bool loaded;

  @override
  State<_ShowHistoryButton> createState() => _ShowHistoryButtonState();
}

class _ShowHistoryButtonState extends State<_ShowHistoryButton> {
  bool _loading = false;

  Future<void> _show() async {
    List<BudgetSnapshotDto> snaps = widget.snapshots;

    if (!widget.loaded) {
      setState(() => _loading = true);
      try {
        final app = context.read<AppController>();
        snaps = await app.api.fetchBudgetSnapshots(widget.budgetId);
        widget.onLoad(snaps);
      } catch (_) {
        widget.onLoad([]);
      } finally {
        if (mounted) setState(() => _loading = false);
      }
    }

    if (!mounted) return;

    if (snaps.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No previous periods yet'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    showDialog<void>(
      context: context,
      builder: (_) => _SnapshotDialog(snapshots: List.from(snaps.reversed)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: _loading ? null : _show,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_loading)
            SizedBox(
              width: 11,
              height: 11,
              child: CircularProgressIndicator(strokeWidth: 1.5, color: cs.primary),
            )
          else
            Icon(Icons.history_rounded, size: 13, color: cs.primary),
          const SizedBox(width: 5),
          Text(
            'View previous periods',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: cs.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _SnapshotDialog extends StatefulWidget {
  const _SnapshotDialog({required this.snapshots});
  /// Ordered oldest → newest (newest is rightmost).
  final List<BudgetSnapshotDto> snapshots;

  @override
  State<_SnapshotDialog> createState() => _SnapshotDialogState();
}

class _SnapshotDialogState extends State<_SnapshotDialog> {
  late final ScrollController _sc;
  static const double _cardW   = 300;
  static const double _cardGap = 10;

  @override
  void initState() {
    super.initState();
    _sc = ScrollController();
    // Scroll to the rightmost (latest) card after first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_sc.hasClients) {
        _sc.jumpTo(_sc.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _sc.dispose();
    super.dispose();
  }

  void _scrollBy(double dx) {
    _sc.animateTo(
      (_sc.offset + dx).clamp(0, _sc.position.maxScrollExtent),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final step  = _cardW + _cardGap;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 40),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Previous periods',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                  iconSize: 18,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  style: IconButton.styleFrom(foregroundColor: cs.onSurfaceVariant),
                ),
              ],
            ),
            const SizedBox(height: 14),
            if (widget.snapshots.length == 1)
              _SnapshotCard(
                snapshot: widget.snapshots.first,
                fillWidth: true,
              )
            else
              SizedBox(
                height: 130,
                child: ListView.separated(
                  controller: _sc,
                  scrollDirection: Axis.horizontal,
                  itemCount: widget.snapshots.length,
                  padding: EdgeInsets.zero,
                  separatorBuilder: (_, __) => const SizedBox(width: _cardGap),
                  itemBuilder: (_, i) =>
                      _SnapshotCard(snapshot: widget.snapshots[i]),
                ),
              ),
            const SizedBox(height: 12),
            if (widget.snapshots.length > 1)
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _NavButton(
                  icon: Icons.chevron_left_rounded,
                  onTap: () => _scrollBy(-step),
                ),
                const SizedBox(width: 8),
                _NavButton(
                  icon: Icons.chevron_right_rounded,
                  onTap: () => _scrollBy(step),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Icon(icon, size: 20, color: cs.onSurfaceVariant),
      ),
    );
  }
}

class _SnapshotCard extends StatelessWidget {
  const _SnapshotCard({required this.snapshot, this.fillWidth = false});
  final BudgetSnapshotDto snapshot;
  final bool fillWidth;

  String _periodLabel() {
    final start = snapshot.periodStart != null
        ? DateTime.parse(snapshot.periodStart!)
        : null;
    final end = snapshot.periodEnd != null
        ? DateTime.parse(snapshot.periodEnd!).subtract(const Duration(seconds: 1))
        : null;
    if (start == null) return 'Unknown period';
    final fmt = (DateTime d) => '${_mon(d.month)} ${d.day}';
    if (end == null) return 'From ${fmt(start)}';
    return '${fmt(start)} – ${fmt(end)}';
  }

  static String _mon(int m) => const [
    '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ][m];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;

    final estimated      = double.tryParse(snapshot.estimated) ?? 0;
    final spent          = double.tryParse(snapshot.spent) ?? 0;
    final available      = double.tryParse(snapshot.fundsAvailable) ?? 0;
    final hasPlanned     = estimated > 0;
    final pct            = hasPlanned ? (spent / estimated).clamp(0.0, 1.0) : 0.0;
    final overBudget     = spent > estimated && hasPlanned;
    final estimatedColor = AppColors.number;
    final spentColor     = spent == 0 ? cs.onSurfaceVariant : AppColors.loss;
    final availableColor = available < 0 ? AppColors.loss : AppColors.amount;
    final barColor       = AppColors.loss.withAlpha(200);
    final dividerColor   = cs.outlineVariant.withAlpha(80);

    return Container(
      width: fillWidth ? double.infinity : 300,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant.withAlpha(120)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Period label
          Text(
            _periodLabel(),
            style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          // ── [Estimated+Spent] · [bar] | [Funds Available] ──────────────
          // Fixed height matches two _StatRow heights + gap (~48px).
          SizedBox(
            height: 48,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _StatRow(
                        label: 'Estimated',
                        value: hasPlanned ? compactAmount(estimated) : '—',
                        valueColor: estimatedColor,
                      ),
                      _StatRow(
                        label: 'Spent',
                        value: compactAmount(spent),
                        valueColor: spentColor,
                      ),
                    ],
                  ),
                ),
                // Bar fills exactly the 48px height.
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(5),
                    child: SizedBox(
                      width: 10,
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
                ),
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(width: 0.5, height: 48, color: dividerColor),
                      const SizedBox(width: 10),
                      Flexible(
                        child: _StatColumn(
                          label: 'Funds',
                          value: compactAmount(available),
                          valueColor: availableColor,
                          icon: Icons.account_balance_wallet_outlined,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // % label below the bar.
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Row(
              children: [
                const Expanded(child: SizedBox()),
                Text(
                  hasPlanned ? '${(pct * 100).round()}%' : '—',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: overBudget ? Colors.red.shade700 : cs.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Expanded(child: SizedBox()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Budget summary card (mirrors list card layout) ────────────────────────────

class _BudgetSummaryCard extends StatefulWidget {
  const _BudgetSummaryCard({
    required this.budget,
    required this.planned,
    required this.spent,
    required this.available,
    required this.hasPlanned,
    required this.pct,
    required this.overBudget,
  });

  final BudgetDto budget;
  final double planned;
  final double spent;
  final double available;
  final bool hasPlanned;
  final double pct;
  final bool overBudget;

  @override
  State<_BudgetSummaryCard> createState() => _BudgetSummaryCardState();
}

class _BudgetSummaryCardState extends State<_BudgetSummaryCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;

    final estimatedColor = AppColors.number;
    final spentColor     = widget.spent == 0 ? cs.onSurfaceVariant : AppColors.loss;
    final availableColor = widget.available < 0 ? AppColors.loss : AppColors.amount;
    final barColor       = AppColors.loss.withAlpha(200);
    final dividerColor   = cs.outlineVariant.withAlpha(80);

    final acctLabel = widget.budget.allocationCount == 0
        ? null
        : '${widget.budget.allocationCount} account${widget.budget.allocationCount == 1 ? '' : 's'}';

    // Compute Fixed / Variable breakdown from category list.
    double fixedEst = 0, fixedSp = 0, varEst = 0, varSp = 0;
    for (final c in widget.budget.categories) {
      final est = double.tryParse(c.estimated) ?? 0;
      final sp  = double.tryParse(c.spent) ?? 0;
      if (c.categoryType == 'fixed') {
        fixedEst += est; fixedSp += sp;
      } else {
        varEst += est; varSp += sp;
      }
    }
    final hasCategories = widget.budget.categories.isNotEmpty;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── [Estimated+Spent] | [bar] | [Funds Available] ─────────────
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Left: Estimated + Spent + breakdown toggle
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _StatRow(
                        label: 'Estimated',
                        value: widget.hasPlanned ? compactAmount(widget.planned) : '—',
                        valueColor: estimatedColor,
                      ),
                      const SizedBox(height: 8),
                      _StatRow(
                        label: 'Spent',
                        value: compactAmount(widget.spent),
                        valueColor: spentColor,
                      ),
                      if (hasCategories) ...[
                        const SizedBox(height: 6),
                        // Indent to align with the value column, not the label column.
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(width: 72),
                            GestureDetector(
                              onTap: () => setState(() => _expanded = !_expanded),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                              Text(
                                'Breakdown',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: cs.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(width: 2),
                              Icon(
                                _expanded
                                    ? Icons.keyboard_arrow_up_rounded
                                    : Icons.keyboard_arrow_down_rounded,
                                size: 14,
                                color: cs.primary,
                              ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                // Centre: vertical bar
                _VerticalBar(
                  pct: widget.pct,
                  hasPlanned: widget.hasPlanned,
                  overBudget: widget.overBudget,
                  barColor: barColor,
                ),
                // Right: Funds Available
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                          width: 0.5, height: 48, color: dividerColor),
                      const SizedBox(width: 14),
                      _StatColumn(
                        label: 'Funds Available',
                        value: compactAmount(widget.available),
                        valueColor: availableColor,
                        subtitle: acctLabel,
                        icon: Icons.account_balance_wallet_outlined,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            // ── Fixed / Variable breakdown (expanded) ──────────────────────
            if (_expanded && hasCategories)
              _BreakdownSection(
                fixedEst: fixedEst,
                fixedSp: fixedSp,
                varEst: varEst,
                varSp: varSp,
              ),
            // ── Period row (always at the bottom) ──────────────────────────
            _PeriodRow(budget: widget.budget),
          ],
        ),
      ),
    );
  }
}

// ── Fixed / Variable breakdown section ───────────────────────────────────────

class _BreakdownSection extends StatelessWidget {
  const _BreakdownSection({
    required this.fixedEst,
    required this.fixedSp,
    required this.varEst,
    required this.varSp,
  });

  final double fixedEst;
  final double fixedSp;
  final double varEst;
  final double varSp;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final muted = cs.onSurfaceVariant;

    final labelStyle = theme.textTheme.labelSmall?.copyWith(color: muted);
    final typeStyle  = theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600);
    final valStyle   = theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600);

    Widget valueText(double v, {bool isSpent = false}) {
      final color = isSpent
          ? (v > 0 ? AppColors.loss : muted)
          : AppColors.number;
      return Text(compactAmount(v), style: valStyle?.copyWith(color: color));
    }

    // Fixed column widths — keeps the table within the left portion of the
    // card and away from the Funds Available section on the right.
    const double typeW  = 72;
    const double valueW = 76;

    Widget cell(String text, {TextStyle? style, TextAlign align = TextAlign.right}) =>
        Text(text, style: style, textAlign: align);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        Container(height: 0.5, color: cs.outlineVariant.withAlpha(100)),
        const SizedBox(height: 10),
        // Header row
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: typeW),
            SizedBox(width: valueW, child: cell('Estimated', style: labelStyle, align: TextAlign.right)),
            const SizedBox(width: 16),
            SizedBox(width: valueW, child: cell('Spent', style: labelStyle, align: TextAlign.right)),
          ],
        ),
        const SizedBox(height: 7),
        // Fixed row
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: typeW, child: Text('Fixed', style: typeStyle)),
            SizedBox(width: valueW, child: Align(alignment: Alignment.centerRight, child: valueText(fixedEst))),
            const SizedBox(width: 16),
            SizedBox(width: valueW, child: Align(alignment: Alignment.centerRight, child: valueText(fixedSp, isSpent: true))),
          ],
        ),
        const SizedBox(height: 5),
        // Variable row
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: typeW, child: Text('Variable', style: typeStyle)),
            SizedBox(width: valueW, child: Align(alignment: Alignment.centerRight, child: valueText(varEst))),
            const SizedBox(width: 16),
            SizedBox(width: valueW, child: Align(alignment: Alignment.centerRight, child: valueText(varSp, isSpent: true))),
          ],
        ),
      ],
    );
  }
}

// ── Schedule info row (read-only) ─────────────────────────────────────────────

class _ScheduleRow extends StatelessWidget {
  const _ScheduleRow({required this.budget, required this.onEdit, required this.onReset});
  final BudgetDto budget;
  final VoidCallback onEdit;
  final VoidCallback onReset;

  String _label() {
    if (budget.resetType != 'scheduled') return 'Manual reset';
    final sched = budget.resetSchedule;
    if (sched == null) return 'Scheduled – every month';
    final isLastDay = sched['is_last_day_of_month'] as bool? ?? false;
    if (isLastDay) return 'Resets · Every month on last day';
    final date = (sched['date'] as num?)?.toInt();
    if (date != null) return 'Resets · Every month on ${_ordinal(date)}';
    return 'Scheduled – every month';
  }

  String _ordinal(int n) {
    if (n == 1) return '1st';
    if (n == 2) return '2nd';
    if (n == 3) return '3rd';
    return '${n}th';
  }

  @override
  Widget build(BuildContext context) {
    final cs    = Theme.of(context).colorScheme;
    final muted = cs.onSurfaceVariant;
    final isScheduled = budget.resetType == 'scheduled';

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          isScheduled ? Icons.autorenew_rounded : Icons.loop_rounded,
          size: 14,
          color: muted,
        ),
        const SizedBox(width: 6),
        Text(
          _label(),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: muted),
        ),
        const SizedBox(width: 10),
        InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onEdit,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            child: Text(
              'Edit',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: muted,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        Text('·', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: muted)),
        const SizedBox(width: 4),
        InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onReset,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            child: Text(
              'Reset now',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── Category connector list ───────────────────────────────────────────────────

class _CategoryConnectorList extends StatelessWidget {
  const _CategoryConnectorList({
    required this.budgetId,
    required this.categories,
  });

  final String budgetId;
  final List<CategoryDto> categories;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final lineColor = cs.outlineVariant.withAlpha(160);

    return Column(
      children: [
        for (int i = 0; i < categories.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── Connector column ──────────────────────────────────
                  SizedBox(
                    width: 20,
                    child: CustomPaint(
                      painter: _ConnectorPainter(
                        isFirst: i == 0,
                        isLast: i == categories.length - 1,
                        color: lineColor,
                      ),
                    ),
                  ),
                  // ── Category card ─────────────────────────────────────
                  Expanded(
                    child: _CategoryEstimateCard(
                      key: ValueKey('${categories[i].id}-${categories[i].version}'),
                      budgetId: budgetId,
                      category: categories[i],
                    ),
                  ),
                  // ── Mirror spacing for visual symmetry ────────────────
                  const SizedBox(width: 20),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

// ── Connector line painter ────────────────────────────────────────────────────

class _ConnectorPainter extends CustomPainter {
  _ConnectorPainter({
    required this.isFirst,
    required this.isLast,
    required this.color,
  });

  final bool isFirst;
  final bool isLast;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final midX = size.width * 0.5;
    final midY = size.height * 0.5;

    // Vertical line from top to branch midpoint
    canvas.drawLine(
      Offset(midX, isFirst ? midY : 0),
      Offset(midX, midY),
      paint,
    );

    // Vertical line from branch midpoint downward (only if not last)
    if (!isLast) {
      canvas.drawLine(
        Offset(midX, midY),
        Offset(midX, size.height),
        paint,
      );
    }

    // Horizontal branch to the right
    canvas.drawLine(
      Offset(midX, midY),
      Offset(size.width, midY),
      paint,
    );

    // Small dot at the branch point
    canvas.drawCircle(
      Offset(midX, midY),
      2.5,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_ConnectorPainter old) =>
      old.isFirst != isFirst ||
      old.isLast != isLast ||
      old.color != color;
}

// ── Empty categories hint ─────────────────────────────────────────────────────

class _EmptyCategoriesHint extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 24),
      alignment: Alignment.center,
      child: Text(
        'No categories yet. Tap + Add New to create one.',
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: cs.onSurfaceVariant),
        textAlign: TextAlign.center,
      ),
    );
  }
}

// ── Count badge ───────────────────────────────────────────────────────────────

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: cs.primaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$count',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: cs.onPrimaryContainer,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

// ── Category cards ────────────────────────────────────────────────────────────

class _CategoryEstimateCard extends StatefulWidget {
  const _CategoryEstimateCard({
    super.key,
    required this.budgetId,
    required this.category,
  });

  final String budgetId;
  final CategoryDto category;

  @override
  State<_CategoryEstimateCard> createState() => _CategoryEstimateCardState();
}

class _CategoryEstimateCardState extends State<_CategoryEstimateCard> {
  bool _editing = false;
  bool _saving  = false;
  late final TextEditingController _name;
  late final TextEditingController _estimated;
  late String _categoryType;

  @override
  void initState() {
    super.initState();
    _name          = TextEditingController(text: widget.category.name);
    _estimated     = TextEditingController(text: widget.category.estimated);
    _categoryType  = widget.category.categoryType;
  }

  @override
  void didUpdateWidget(covariant _CategoryEstimateCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.category.version != widget.category.version ||
        oldWidget.category.id != widget.category.id) {
      _name.text     = widget.category.name;
      _estimated.text = widget.category.estimated;
      _categoryType  = widget.category.categoryType;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _estimated.dispose();
    super.dispose();
  }

  void _cancelEdit() {
    setState(() {
      _editing       = false;
      _name.text     = widget.category.name;
      _estimated.text = widget.category.estimated;
      _categoryType  = widget.category.categoryType;
    });
  }

  Future<void> _save() async {
    final nameVal = _name.text.trim();
    final est     = _estimated.text.trim();
    if (nameVal.isEmpty || est.isEmpty) return;
    setState(() => _saving = true);
    final app = context.read<AppController>();
    try {
      await app.api.upsertCategory(
        widget.budgetId,
        categoryId: widget.category.id,
        name: nameVal,
        estimated: est,
        categoryType: _categoryType,
        version: widget.category.version,
      );
      await app.refreshAccountsBudgets();
      if (!mounted) return;
      setState(() { _editing = false; _saving = false; });
      showTopSnack(context, 'Category updated');
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showTopSnack(context, 'Error: $e');
    }
  }

  Future<void> _delete() async {
    final app = context.read<AppController>();
    final c   = widget.category;
    try {
      await app.api.deleteCategory(widget.budgetId, c.id);
      await app.refreshAccountsBudgets();
    } catch (e) {
      if (!mounted) return;
      showTopSnack(context, 'Error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    final c     = widget.category;

    final spent     = double.tryParse(c.spent) ?? 0;
    final remaining = double.tryParse(c.remaining) ?? 0;
    final estimated = double.tryParse(c.estimated) ?? 0;
    final remainingColor = remaining < 0 ? Colors.red.shade700 : cs.onSurface;

    return Card(
      child: Padding(
        padding: AppInsets.card,
        child: _editing
            ? _buildEditMode(theme)
            : _buildReadMode(theme, cs, c, estimated, spent, remaining, remainingColor),
      ),
    );
  }

  Widget _buildReadMode(
    ThemeData theme,
    ColorScheme cs,
    CategoryDto c,
    double estimated,
    double spent,
    double remaining,
    Color remainingColor,
  ) {
    final pct = estimated > 0
        ? (spent / estimated).clamp(0.0, 1.0)
        : 0.0;
    final overSpent = remaining < 0;
    final barColor  = overSpent ? cs.error : cs.primary;

    final isFixed = c.categoryType == 'fixed';
    final badgeBg = isFixed
        ? cs.primaryContainer.withAlpha(180)
        : cs.surfaceContainerHighest;
    final badgeFg = isFixed ? cs.onPrimaryContainer : cs.onSurfaceVariant;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Name + type badge + action icons
        Row(
          children: [
            Expanded(
              child: Text(
                c.name,
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: badgeBg,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                isFixed ? 'Fixed' : 'Variable',
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 10,
                  color: badgeFg,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 6),
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 17),
              tooltip: 'Edit',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              style: IconButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              onPressed: () => setState(() => _editing = true),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: Icon(Icons.delete_outline, size: 17, color: cs.error),
              tooltip: 'Delete',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              style: IconButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              onPressed: _delete,
            ),
          ],
        ),
        const SizedBox(height: 8),
        // Stats row
        Row(
          children: [
            _StatChip(
              label: 'Planned',
              value: compactAmount(estimated),
              color: cs.primary,
            ),
            const SizedBox(width: 24),
            // Spent stat with inline % pill
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Spent',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: cs.onSurfaceVariant)),
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      compactAmount(spent),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: spent > 0
                            ? Colors.orange.shade700
                            : cs.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (estimated > 0 && pct > 0) ...[
                      const SizedBox(width: 5),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          color: overSpent
                              ? cs.errorContainer
                              : cs.primaryContainer.withAlpha(180),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          '${((spent / estimated * 100).round()).clamp(0, 100)}%',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: overSpent
                                ? cs.onErrorContainer
                                : cs.primary,
                            fontWeight: FontWeight.w600,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
            const SizedBox(width: 24),
            _StatChip(
              label: 'Remaining',
              value: compactAmount(remaining),
              color: remainingColor,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildEditMode(ThemeData theme) {
    final cs = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_saving) LinearProgressIndicator(minHeight: 3, color: cs.primary),
        const SizedBox(height: 2),
        Text('Edit category',
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        TextField(
          controller: _name,
          enabled: !_saving,
          decoration: const InputDecoration(
            labelText: 'Category name',
            isDense: true,
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _estimated,
          enabled: !_saving,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
          ],
          decoration: const InputDecoration(
            labelText: 'Estimated (planned)',
            isDense: true,
          ),
        ),
        const SizedBox(height: 10),
        _CategoryTypeToggle(
          value: _categoryType,
          onChanged: _saving ? (_) {} : (v) => setState(() => _categoryType = v),
        ),
        const SizedBox(height: 6),
        Text(
          'Spent ${widget.category.spent} · Remaining ${widget.category.remaining}',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            OutlinedButton(
              onPressed: _saving ? null : _cancelEdit,
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: const Text('Save'),
            ),
          ],
        ),
      ],
    );
  }
}

// ── Budget edit bottom sheet ──────────────────────────────────────────────────

class _BudgetEditSheet extends StatefulWidget {
  const _BudgetEditSheet({required this.budget});
  final BudgetDto budget;

  @override
  State<_BudgetEditSheet> createState() => _BudgetEditSheetState();
}

class _BudgetEditSheetState extends State<_BudgetEditSheet> {
  late String _resetType;
  late int _resetDaySelection;
  late final TextEditingController _name;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _name      = TextEditingController(text: widget.budget.name);
    _resetType = widget.budget.resetType;
    if (_resetType == 'scheduled' && widget.budget.resetSchedule != null) {
      final sched    = widget.budget.resetSchedule!;
      final isLastDay = sched['is_last_day_of_month'] as bool? ?? false;
      _resetDaySelection =
          isLastDay ? 29 : ((sched['date'] as num?)?.toInt() ?? 1);
    } else {
      _resetDaySelection = 1;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Map<String, dynamic>? _buildResetSchedule() {
    if (_resetType != 'scheduled') return null;
    final isLastDay = _resetDaySelection == 29;
    return {
      'type': 'every_month_on_date',
      'date': isLastDay ? null : _resetDaySelection,
      'is_last_day_of_month': isLastDay,
    };
  }

  List<DropdownMenuItem<int>> _buildResetDayItems() {
    return [
      for (int d = 1; d <= 28; d++)
        DropdownMenuItem(value: d, child: Text(_ordinal(d))),
      const DropdownMenuItem(value: 29, child: Text('Last day of month')),
    ];
  }

  String _ordinal(int n) {
    if (n == 1) return '1st';
    if (n == 2) return '2nd';
    if (n == 3) return '3rd';
    return '${n}th';
  }

  Future<void> _save() async {
    final nameVal = _name.text.trim();
    if (nameVal.isEmpty) return;
    setState(() => _saving = true);
    final app = context.read<AppController>();
    try {
      await app.api.updateBudgetMeta(
        widget.budget.id,
        name: nameVal,
        resetType: _resetType,
        resetSchedule: _buildResetSchedule(),
        version: widget.budget.version,
      );
      await app.refreshAccountsBudgets();
      if (!mounted) return;
      Navigator.of(context).pop();
      showTopSnack(context, 'Saved');
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
    final cs    = theme.colorScheme;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20, 8, 20,
        MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_saving) LinearProgressIndicator(minHeight: 3, color: cs.primary),
          const SizedBox(height: 4),
          Text('Edit Budget',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Budget name'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _resetType,
            decoration: const InputDecoration(labelText: 'Reset Schedule'),
            items: const [
              DropdownMenuItem(value: 'manual', child: Text('Manual')),
              DropdownMenuItem(
                  value: 'scheduled', child: Text('Scheduled – Every Month')),
            ],
            onChanged: (v) => setState(() => _resetType = v ?? 'manual'),
          ),
          if (_resetType == 'scheduled') ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              value: _resetDaySelection,
              decoration: const InputDecoration(labelText: 'Reset on'),
              items: _buildResetDayItems(),
              onChanged: (v) =>
                  setState(() => _resetDaySelection = v ?? 1),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: const Text('Save Changes'),
          ),
        ],
      ),
    );
  }
}

// ── Add category sheet ────────────────────────────────────────────────────────

class _AddCategorySheet extends StatefulWidget {
  const _AddCategorySheet({required this.budgetId});
  final String budgetId;

  @override
  State<_AddCategorySheet> createState() => _AddCategorySheetState();
}

class _AddCategorySheetState extends State<_AddCategorySheet> {
  final _name      = TextEditingController();
  final _estimated = TextEditingController();
  String _categoryType = 'variable';
  bool _saving         = false;

  @override
  void dispose() {
    _name.dispose();
    _estimated.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final n = _name.text.trim();
    if (n.isEmpty) return;
    final est = _estimated.text.trim();
    setState(() => _saving = true);
    final app = context.read<AppController>();
    try {
      await app.api.upsertCategory(
        widget.budgetId,
        name: n,
        estimated: est.isEmpty ? '0' : est,
        categoryType: _categoryType,
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
    final cs    = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20, 8, 20,
        MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_saving) LinearProgressIndicator(minHeight: 3, color: cs.primary),
          const SizedBox(height: 4),
          Text('New Category',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(hintText: 'e.g. Groceries'),
            onSubmitted: (_) => FocusScope.of(context).nextFocus(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _estimated,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
            ],
            decoration: const InputDecoration(
              hintText: '0',
              labelText: 'Estimated amount (optional)',
              prefixText: '₹ ',
            ),
            onSubmitted: (_) => _create(),
          ),
          const SizedBox(height: 12),
          _CategoryTypeToggle(
            value: _categoryType,
            onChanged: (v) => setState(() => _categoryType = v),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving ? null : _create,
            child: const Text('Add Category'),
          ),
        ],
      ),
    );
  }
}

// ── Category type toggle (Fixed / Variable) ───────────────────────────────────

class _CategoryTypeToggle extends StatelessWidget {
  const _CategoryTypeToggle({
    required this.value,
    required this.onChanged,
  });

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;

    Widget chip(String type, String label) {
      final selected = value == type;
      return GestureDetector(
        onTap: () => onChanged(type),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? cs.primaryContainer : cs.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? cs.primary.withAlpha(120) : cs.outlineVariant.withAlpha(160),
              width: 1,
            ),
          ),
          child: Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: selected ? cs.onPrimaryContainer : cs.onSurfaceVariant,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Type',
          style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(width: 10),
        chip('variable', 'Variable'),
        const SizedBox(width: 8),
        chip('fixed', 'Fixed'),
      ],
    );
  }
}

// ── Shared stat widgets ───────────────────────────────────────────────────────

class _StatRow extends StatelessWidget {
  const _StatRow({
    required this.label,
    required this.value,
    required this.valueColor,
  });

  final String label;
  final String value;
  final Color valueColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 72,
          child: Text(label,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: cs.onSurfaceVariant)),
        ),
        Text(value,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: valueColor,
              fontWeight: FontWeight.w700,
            )),
      ],
    );
  }
}

class _StatColumn extends StatelessWidget {
  const _StatColumn({
    required this.label,
    required this.value,
    required this.valueColor,
    this.subtitle,
    this.icon,
  });

  final String label;
  final String value;
  final Color valueColor;
  final String? subtitle;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs    = theme.colorScheme;
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
            Text(label,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: cs.onSurfaceVariant, height: 1.2)),
          ],
        ),
        const SizedBox(height: 4),
        Text(value,
            style: theme.textTheme.titleMedium?.copyWith(
              color: valueColor,
              fontWeight: FontWeight.w700,
            )),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(subtitle!,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                color: cs.onSurfaceVariant.withAlpha(150),
                fontSize: 9,
              )),
        ],
      ],
    );
  }
}

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
    final cs    = theme.colorScheme;
    final label = hasPlanned ? '${(pct * 100).round()}%' : '-';
    final labelColor =
        overBudget ? Colors.red.shade700 : cs.onSurfaceVariant;

    return Column(
      mainAxisSize: MainAxisSize.min,
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
        Text(label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: labelColor,
              fontWeight: FontWeight.w600,
            )),
      ],
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        Text(value,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: color, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

// ── Period row (reused from list card) ────────────────────────────────────────

String _shortMonth(int month) {
  const m = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  return m[month - 1];
}

String _fmtDate(DateTime d) => '${_shortMonth(d.month)} ${d.day}';

class _PeriodRow extends StatelessWidget {
  const _PeriodRow({required this.budget});
  final BudgetDto budget;

  @override
  Widget build(BuildContext context) {
    final b  = budget;
    final cs = Theme.of(context).colorScheme;

    final startDt = b.periodStart != null
        ? DateTime.parse(b.periodStart!).toLocal()
        : null;
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

    final muteColor  = cs.onSurfaceVariant.withAlpha(140);
    const labelStyle = TextStyle(fontSize: 10.5, height: 1.2);

    return Padding(
      padding: const EdgeInsets.only(top: 7),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isScheduled
                ? Icons.autorenew_rounded
                : Icons.calendar_today_outlined,
            size: 10,
            color: muteColor,
          ),
          const SizedBox(width: 4),
          Text(periodText,
              style: labelStyle.copyWith(color: muteColor)),
          if (isScheduled)
            Text('  ·  Monthly',
                style: labelStyle.copyWith(
                    color: muteColor, letterSpacing: 0.2)),
        ],
      ),
    );
  }
}
