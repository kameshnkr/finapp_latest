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
  String _resetType = 'manual';
  // 1–28 = that day of the month; 29 = sentinel for "last day of month"
  int _resetDaySelection = 1;
  final _name = TextEditingController();
  bool _seeded = false;

  BudgetDto? _find(List<BudgetDto> budgets) {
    for (final b in budgets) {
      if (b.id == widget.budgetId) return b;
    }
    return null;
  }

  double _sumCategoryPlanned(List<CategoryDto> cats) {
    var s = 0.0;
    for (final c in cats) {
      s += double.tryParse(c.estimated) ?? 0;
    }
    return s;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final b = _find(app.budgets);
    if (b == null) {
      return const Scaffold(body: Center(child: Text('Budget not found')));
    }
    if (!_seeded) {
      _name.text = b.name;
      _resetType = b.resetType;
      if (b.resetType == 'scheduled' && b.resetSchedule != null) {
        final sched = b.resetSchedule!;
        final isLastDay = sched['is_last_day_of_month'] as bool? ?? false;
        _resetDaySelection = isLastDay ? 29 : ((sched['date'] as num?)?.toInt() ?? 1);
      } else {
        _resetDaySelection = 1;
      }
      _seeded = true;
    }

    final plannedSum = _sumCategoryPlanned(b.categories);
    final spent = double.tryParse(b.spent) ?? 0;
    final double pct = plannedSum == 0
        ? 0.0
        : (spent / plannedSum).clamp(0.0, 1.0).toDouble();

    return Scaffold(
      appBar: AppBar(
        title: Text(b.name),
        actions: [
          TextButton(
            onPressed: () async {
              try {
                await app.api.updateBudgetMeta(
                  b.id,
                  name: _name.text.trim(),
                  resetType: _resetType,
                  resetSchedule: _buildResetSchedule(),
                  version: b.version,
                );
                await app.refreshAccountsBudgets();
                if (!mounted) return;
                showTopSnack(context, 'Saved');
                Navigator.of(context).pop();
              } catch (e) {
                if (!mounted) return;
                showTopSnack(context, 'Error: $e');
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        padding: AppInsets.screen,
        children: [
          _BudgetSummaryBar(
            planned: plannedSum,
            spent: spent,
            fundsAvailable: double.tryParse(b.fundsAvailable) ?? 0,
            pct: pct,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Budget name',
            ),
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
          // ── Categories header: title + add button ─────────────────────
          Row(
            children: [
              Text('Categories',
                  style: Theme.of(context).textTheme.titleMedium),
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
          const SizedBox(height: 8),
          ...b.categories.map(
            (c) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _CategoryEstimateCard(
                key: ValueKey('${c.id}-${c.version}'),
                budgetId: b.id,
                category: c,
              ),
            ),
          ),
        ],
      ),
    );
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

  void _showAddCategorySheet(BuildContext context, String budgetId) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AddCategorySheet(budgetId: budgetId),
    );
  }
}

// ── Budget summary header ──────────────────────────────────────────────────────

class _BudgetSummaryBar extends StatelessWidget {
  const _BudgetSummaryBar({
    required this.planned,
    required this.spent,
    required this.fundsAvailable,
    required this.pct,
  });

  final double planned;
  final double spent;
  final double fundsAvailable;
  final double pct;

  static String _c(double v) => compactAmount(v);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final overBudget = spent > planned && planned > 0;
    final spentColor =
        overBudget ? Colors.red.shade700 : Colors.orange.shade700;
    final availableColor =
        fundsAvailable < 0 ? AppColors.loss : AppColors.amount;
    final barColor = overBudget ? cs.error : cs.primary;
    final hasPlanned = planned > 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Three stat chips
        Row(
          children: [
            _SummaryChip(
                label: 'Estimated',
                value: hasPlanned ? _c(planned) : 'Not set',
                color: cs.primary),
            const SizedBox(width: 8),
            _SummaryChip(
                label: 'Spent',
                value: _c(spent),
                color: spentColor),
            const SizedBox(width: 8),
            _SummaryChip(
                label: 'Available',
                value: _c(fundsAvailable),
                color: availableColor),
          ],
        ),
        const SizedBox(height: 10),
        // Short progress badge — right-aligned, matches budget card style
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            SizedBox(
              width: 72,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: hasPlanned ? pct : 0,
                  minHeight: 4,
                  color: barColor,
                  backgroundColor: cs.surfaceContainerHighest,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              hasPlanned ? '${(pct * 100).toStringAsFixed(0)}%' : '0%',
              style: theme.textTheme.labelSmall?.copyWith(
                color: overBudget ? Colors.red.shade700 : cs.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _SummaryChip extends StatelessWidget {
  const _SummaryChip({
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
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
        decoration: BoxDecoration(
          color: cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: cs.onSurfaceVariant,
                letterSpacing: 0.3,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              value,
              style: theme.textTheme.titleSmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Category cards ─────────────────────────────────────────────────────────────

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
  late final TextEditingController _name;
  late final TextEditingController _estimated;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.category.name);
    _estimated = TextEditingController(text: widget.category.estimated);
  }

  @override
  void didUpdateWidget(covariant _CategoryEstimateCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.category.version != widget.category.version ||
        oldWidget.category.id != widget.category.id) {
      _name.text = widget.category.name;
      _estimated.text = widget.category.estimated;
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
      _editing = false;
      _name.text = widget.category.name;
      _estimated.text = widget.category.estimated;
    });
  }

  Future<void> _save() async {
    final app = context.read<AppController>();
    final nameVal = _name.text.trim();
    final est = _estimated.text.trim();
    if (nameVal.isEmpty || est.isEmpty) return;
    try {
      await app.api.upsertCategory(
        widget.budgetId,
        categoryId: widget.category.id,
        name: nameVal,
        estimated: est,
        version: widget.category.version,
      );
      await app.refreshAccountsBudgets();
      if (!mounted) return;
      setState(() => _editing = false);
      showTopSnack(context, 'Category updated');
    } catch (e) {
      if (!mounted) return;
      showTopSnack(context, 'Error: $e');
    }
  }

  Future<void> _delete() async {
    final app = context.read<AppController>();
    final c = widget.category;
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
    final cs = theme.colorScheme;
    final c = widget.category;

    final spent = double.tryParse(c.spent) ?? 0;
    final remaining = double.tryParse(c.remaining) ?? 0;
    final estimated = double.tryParse(c.estimated) ?? 0;
    final remainingColor = remaining < 0 ? Colors.red.shade700 : cs.onSurface;

    return Card(
      child: Padding(
        padding: AppInsets.card,
        child: _editing ? _buildEditMode(theme) : _buildReadMode(
          theme, cs, c, estimated, spent, remaining, remainingColor,
        ),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(c.name,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ),
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 18),
              tooltip: 'Edit',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              style: IconButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              onPressed: () => setState(() => _editing = true),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: Icon(Icons.delete_outline,
                  size: 18, color: cs.error),
              tooltip: 'Delete',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              style: IconButton.styleFrom(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              onPressed: _delete,
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            _StatChip(
              label: 'Planned',
              value: compactAmount(estimated),
              color: cs.primary,
            ),
            const SizedBox(width: 8),
            _StatChip(
              label: 'Spent',
              value: compactAmount(spent),
              color: spent > 0 ? Colors.orange.shade700 : cs.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Edit category',
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        TextField(
          controller: _name,
          decoration: const InputDecoration(
            labelText: 'Category name',
            isDense: true,
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _estimated,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
          ],
          decoration: const InputDecoration(
            labelText: 'Estimated (planned)',
            isDense: true,
          ),
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
              onPressed: _cancelEdit,
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _save,
              child: const Text('Save'),
            ),
          ],
        ),
      ],
    );
  }
}

// ── Add category sheet ─────────────────────────────────────────────────────────

class _AddCategorySheet extends StatefulWidget {
  const _AddCategorySheet({required this.budgetId});
  final String budgetId;

  @override
  State<_AddCategorySheet> createState() => _AddCategorySheetState();
}

class _AddCategorySheetState extends State<_AddCategorySheet> {
  final _name = TextEditingController();
  final _estimated = TextEditingController();
  bool _saving = false;

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
            onSubmitted: (_) =>
                FocusScope.of(context).nextFocus(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _estimated,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
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

// ── Stat chip ──────────────────────────────────────────────────────────────────

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
            style: theme.textTheme.bodyMedium?.copyWith(
                color: color, fontWeight: FontWeight.w600)),
      ],
    );
  }
}
