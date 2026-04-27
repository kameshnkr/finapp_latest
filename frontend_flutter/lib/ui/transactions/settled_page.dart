import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import 'package:provider/provider.dart';

import '../../data/models/models.dart';
import '../../state/app_controller.dart';
import '../../core/date_utils.dart' as du;
import '../../core/snack_utils.dart';
import '../../utils/amount_formatter.dart';
import '../widgets/date_filter_bar.dart';
// ── Date-section helpers ───────────────────────────────────────────────────────

class _DateHeader {
  const _DateHeader({
    required this.dateKey,
    required this.totalCredit,
    required this.totalDebit,
  });
  final String dateKey;
  final double totalCredit;
  final double totalDebit;
}

/// Builds a flat list of [_DateHeader] and [TransactionDto] objects, grouped by
/// transaction date with a header preceding each group.
List<Object> _buildFlatItems(List<TransactionDto> txs) {
  final result = <Object>[];
  final grouped = <String, List<TransactionDto>>{};
  final dateOrder = <String>[];

  for (final tx in txs) {
    final key = tx.transactionDate ?? tx.createdAt.substring(0, 10);
    if (!grouped.containsKey(key)) {
      grouped[key] = [];
      dateOrder.add(key);
    }
    grouped[key]!.add(tx);
  }

  for (final date in dateOrder) {
    final group = grouped[date]!;
    double credit = 0, debit = 0;
    for (final tx in group) {
      final amt = double.tryParse(tx.amount) ?? 0;
      if (tx.direction == 'credit') {
        credit += amt;
      } else {
        debit += amt;
      }
    }
    result.add(_DateHeader(dateKey: date, totalCredit: credit, totalDebit: debit));
    result.addAll(group);
  }
  return result;
}

class SettledPage extends StatefulWidget {
  const SettledPage({super.key});

  @override
  State<SettledPage> createState() => _SettledPageState();
}

class _SettledPageState extends State<SettledPage> {
  String? _editingId;
  final ScrollController _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    Future.microtask(() {
      if (mounted) context.read<AppController>().resetDateRange();
    });
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    final pos = _scrollCtrl.position;
    if (pos.pixels >= pos.maxScrollExtent - 200) {
      context.read<AppController>().loadMoreSettled();
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final list = app.settled;
    final cs = Theme.of(context).colorScheme;

    final flatItems = _buildFlatItems(list);
    final itemCount =
        flatItems.length + (app.settledPage.isLoadingMore ? 1 : 0);

    return Column(
      children: [
        // ── Filter row ────────────────────────────────────────────────────
        FilterRow(app: app),

        if (list.isEmpty && !app.settledPage.isLoadingMore)
          Expanded(
            child: Center(
              child: app.loading
                  ? const CircularProgressIndicator()
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.task_alt_rounded,
                            size: 48, color: cs.onSurfaceVariant.withAlpha(100)),
                        const SizedBox(height: 10),
                        Text('No settled transactions',
                            style: TextStyle(
                                color: cs.onSurfaceVariant,
                                fontWeight: FontWeight.w500)),
                      ],
              ),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              controller: _scrollCtrl,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
              itemCount: itemCount,
              itemBuilder: (context, i) {
                if (i == flatItems.length) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 14),
                    child: Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  );
                }
                final item = flatItems[i];
                if (item is _DateHeader) {
                  return _DateSectionHeader(header: item);
                }
                final t = item as TransactionDto;
                final editing = _editingId == t.id;
                return _SettledCard(
                  tx: t,
                  accounts: app.accounts,
                  budgets: app.budgets,
                  editing: editing,
                  onEdit: () => setState(() => _editingId = t.id),
                  onCancel: () => setState(() => _editingId = null),
                  onSaved: () => setState(() => _editingId = null),
                );
              },
            ),
          ),
      ],
    );
  }
}

// ── Date Section Header ────────────────────────────────────────────────────────

class _DateSectionHeader extends StatelessWidget {
  const _DateSectionHeader({required this.header});
  final _DateHeader header;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
      child: Row(
        children: [
          Text(
            du.sectionLabel(header.dateKey),
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: cs.onSurfaceVariant,
              letterSpacing: 0.3,
            ),
          ),
          const Spacer(),
          if (header.totalCredit > 0.005) ...[
            Text(
              '+₹${compactAmount(header.totalCredit)}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.gain,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
          ],
          if (header.totalDebit > 0.005)
            Text(
              '−₹${compactAmount(header.totalDebit)}',
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

// ── Settled Card ───────────────────────────────────────────────────────────────

class _SettledCard extends StatefulWidget {
  const _SettledCard({
    required this.tx,
    required this.accounts,
    required this.budgets,
    required this.editing,
    required this.onEdit,
    required this.onCancel,
    required this.onSaved,
  });

  final TransactionDto tx;
  final List<AccountDto> accounts;
  final List<BudgetDto> budgets;
  final bool editing;
  final VoidCallback onEdit;
  final VoidCallback onCancel;
  final VoidCallback onSaved;

  @override
  State<_SettledCard> createState() => _SettledCardState();
}

class _SettledCardState extends State<_SettledCard> {
  late String _accountId;
  late String _direction;
  late String _amount;
  late String _type;
  String? _budgetId;
  String? _categoryId;
  late String _note;
  late int _version;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _syncFromTx();
  }

  @override
  void didUpdateWidget(covariant _SettledCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tx.id != widget.tx.id ||
        oldWidget.editing != widget.editing) {
      _syncFromTx();
    }
  }

  void _syncFromTx() {
    final t = widget.tx;
    _accountId = t.accountId;
    _direction = t.direction;
    _amount = t.amount;
    _type = t.transactionType ?? 'expense';
    _budgetId = t.budgetId;
    _categoryId = t.categoryId;
    _note = t.note ?? '';
    _version = t.version;
  }

  BudgetDto? _budget() {
    if (_budgetId == null) return null;
    for (final b in widget.budgets) {
      if (b.id == _budgetId) return b;
    }
    return null;
  }

  Future<void> _save() async {
    // Category is required only when a budget is explicitly selected.
    if ((_type == 'expense' || _type == 'expense_refund') &&
        _budgetId != null &&
        _categoryId == null) {
      showTopSnack(context, 'Select a category');
      return;
    }
    setState(() => _saving = true);
    final app = context.read<AppController>();
    try {
      await app.api.updateSettled(
        widget.tx.id,
        accountId: _accountId,
        direction: _direction,
        amount: _amount,
        transactionType: _type,
        version: _version,
        budgetId: (_type == 'expense' ||
                _type == 'expense_refund' ||
                _type == 'transfer')
            ? _budgetId
            : null,
        categoryId:
            (_type == 'expense' || _type == 'expense_refund') ? _categoryId : null,
        note: _note.isEmpty ? null : _note,
      );
      await app.refreshAll();
      if (!mounted) return;
      showTopSnack(context, 'Saved');
      widget.onSaved();
    } catch (e) {
      if (!mounted) return;
      showTopSnack(context, 'Error: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _accountName([String? id]) {
    final lookupId = id ?? widget.tx.accountId;
    for (final a in widget.accounts) {
      if (a.id == lookupId) return a.name;
    }
    return lookupId;
  }

  String _budgetName([String? id]) {
    final lookupId = id ?? widget.tx.budgetId;
    if (lookupId == null) return '—';
    for (final b in widget.budgets) {
      if (b.id == lookupId) return b.name;
    }
    return lookupId;
  }

  String _categoryName([String? id]) {
    final lookupId = id ?? widget.tx.categoryId;
    if (lookupId == null) return '—';
    for (final b in widget.budgets) {
      for (final c in b.categories) {
        if (c.id == lookupId) return c.name;
      }
    }
    return lookupId;
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.tx;
    final isDebit = t.direction == 'debit';
    final isAdjustment = t.transactionType == 'balance_adjustment';
    final cs = Theme.of(context).colorScheme;

    // Balance-adjustment cards use a neutral muted accent and no edit action.
    final accentColor = isAdjustment
        ? cs.outlineVariant
        : (isDebit ? AppColors.loss : AppColors.gain);

    final card = AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      margin: const EdgeInsets.only(bottom: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Material(
          color: cs.surfaceContainerLowest,
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Left accent bar
                Container(width: 4, color: accentColor),
                // Card body
                Expanded(
                  child: widget.editing
                      ? _EditBody(
                          tx: t,
                          accounts: widget.accounts,
                          budgets: widget.budgets,
                          accountId: _accountId,
                          direction: _direction,
                          amount: _amount,
                          type: _type,
                          budgetId: _budgetId,
                          categoryId: _categoryId,
                          note: _note,
                          budget: _budget(),
                          saving: _saving,
                          onAccountChanged: (v) =>
                              setState(() => _accountId = v),
                          onDirectionChanged: (v) =>
                              setState(() => _direction = v),
                          onAmountChanged: (v) => _amount = v,
                          onTypeChanged: (v) => setState(() {
                            _type = v;
                            if (_type == 'transfer') {
                              _categoryId = null;
                            }
                          }),
                          onBudgetChanged: (v) => setState(() {
                            _budgetId = v;
                            _categoryId = null;
                          }),
                          onCategoryChanged: (v) =>
                              setState(() => _categoryId = v),
                          onNoteChanged: (v) => _note = v,
                          onSave: _save,
                          onCancel: widget.onCancel,
                        )
                      : _ReadBody(
                          tx: t,
                          accentColor: accentColor,
                          accountName: _accountName(),
                          budgetName: _budgetName(),
                          categoryName: _categoryName(),
                          // Adjustment transactions are read-only system records.
                          onEdit: isAdjustment ? null : widget.onEdit,
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    // Render adjustment cards at reduced opacity to convey secondary status.
    return isAdjustment ? Opacity(opacity: 0.6, child: card) : card;
  }
}

// ── Read view ──────────────────────────────────────────────────────────────────

class _ReadBody extends StatelessWidget {
  const _ReadBody({
    required this.tx,
    required this.accentColor,
    required this.accountName,
    required this.budgetName,
    required this.categoryName,
    this.onEdit,
  });

  final TransactionDto tx;
  final Color accentColor;
  final String accountName;
  final String budgetName;
  final String categoryName;
  /// Null for balance-adjustment transactions (non-editable).
  final VoidCallback? onEdit;

  String _typeLabel(String? type) {
    switch (type) {
      case 'expense':
        return 'Expense';
      case 'expense_refund':
        return 'Refund';
      case 'transfer':
        return 'Transfer';
      case 'balance_adjustment':
        return 'Adjustment';
      default:
        return type ?? '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDebit = tx.direction == 'debit';

    // Build budget › category › note text for row 2.
    final secondaryParts = <String>[];
    if (budgetName != '—' && budgetName.isNotEmpty) secondaryParts.add(budgetName);
    if (categoryName != '—' && categoryName.isNotEmpty) secondaryParts.add(categoryName);
    final note = tx.note;
    if (note != null && note.isNotEmpty) secondaryParts.add(note);
    final secondaryLine = secondaryParts.join(' › ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Row 1: amount  account                       edit icon
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                '${isDebit ? '−' : '+'} ₹${tx.amount}',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: accentColor,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  accountName,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: cs.onSurfaceVariant),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (onEdit != null) ...[
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: onEdit,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Icon(Icons.edit_outlined,
                        size: 12, color: cs.onSurfaceVariant),
                  ),
                ),
              ],
            ],
          ),

          const SizedBox(height: 4),

          // Row 2: [type badge]  budget · category · note      date
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _TypeBadge(label: _typeLabel(tx.transactionType)),
              if (secondaryLine.isNotEmpty) ...[
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    secondaryLine,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: cs.onSurfaceVariant),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ] else
                const Spacer(),
              const SizedBox(width: 6),
              Text(
                du.formatDate(tx.transactionDate),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: cs.onSurfaceVariant.withAlpha(150)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TypeBadge extends StatelessWidget {
  const _TypeBadge({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: cs.secondaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 11,
              color: cs.onSecondaryContainer,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2)),
    );
  }
}

class _InfoPill extends StatelessWidget {
  const _InfoPill({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: cs.onSurfaceVariant),
        const SizedBox(width: 3),
        Text(label,
            style: TextStyle(
                fontSize: 12,
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w500)),
      ],
    );
  }
}

// ── Edit view ──────────────────────────────────────────────────────────────────

class _EditBody extends StatelessWidget {
  const _EditBody({
    required this.tx,
    required this.accounts,
    required this.budgets,
    required this.accountId,
    required this.direction,
    required this.amount,
    required this.type,
    required this.budgetId,
    required this.categoryId,
    required this.note,
    required this.budget,
    required this.saving,
    required this.onAccountChanged,
    required this.onDirectionChanged,
    required this.onAmountChanged,
    required this.onTypeChanged,
    required this.onBudgetChanged,
    required this.onCategoryChanged,
    required this.onNoteChanged,
    required this.onSave,
    required this.onCancel,
  });

  final TransactionDto tx;
  final List<AccountDto> accounts;
  final List<BudgetDto> budgets;
  final String accountId;
  final String direction;
  final String amount;
  final String type;
  final String? budgetId;
  final String? categoryId;
  final String note;
  final BudgetDto? budget;
  final bool saving;
  final void Function(String) onAccountChanged;
  final void Function(String) onDirectionChanged;
  final void Function(String) onAmountChanged;
  final void Function(String) onTypeChanged;
  final void Function(String?) onBudgetChanged;
  final void Function(String?) onCategoryChanged;
  final void Function(String) onNoteChanged;
  final VoidCallback onSave;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Edit indicator
          Row(
            children: [
              Icon(Icons.edit_outlined, size: 14, color: cs.primary),
              const SizedBox(width: 4),
              Text('Editing',
                  style: TextStyle(
                      fontSize: 12,
                      color: cs.primary,
                      fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 12),
          if (saving)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: LinearProgressIndicator(
                  borderRadius: BorderRadius.circular(2)),
            ),

          // Transaction fields
          Row(
            children: [
              Expanded(
                flex: 2,
                child: DropdownButtonFormField<String>(
                  initialValue: accountId,
                  items: accounts
                      .map((a) =>
                          DropdownMenuItem(value: a.id, child: Text(a.name)))
                      .toList(),
                  onChanged: (v) => onAccountChanged(v!),
                  decoration: const InputDecoration(
                      labelText: 'Account', isDense: true),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: direction,
                  items: const [
                    DropdownMenuItem(
                        value: 'debit', child: Text('Debit')),
                    DropdownMenuItem(
                        value: 'credit', child: Text('Credit')),
                  ],
                  onChanged: (v) => onDirectionChanged(v!),
                  decoration: const InputDecoration(
                      labelText: 'Direction', isDense: true),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextFormField(
            initialValue: amount,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
                labelText: 'Amount',
                prefixText: '₹ ',
                isDense: true),
            onChanged: onAmountChanged,
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: type,
            items: const [
              DropdownMenuItem(value: 'expense', child: Text('Expense')),
              DropdownMenuItem(
                  value: 'expense_refund', child: Text('Expense Refund')),
              DropdownMenuItem(
                  value: 'transfer', child: Text('Transfer')),
            ],
            onChanged: (v) => onTypeChanged(v!),
            decoration:
                const InputDecoration(labelText: 'Type', isDense: true),
          ),
          if (type == 'expense' ||
              type == 'expense_refund' ||
              type == 'transfer') ...[
            const SizedBox(height: 10),
            DropdownButtonFormField<String?>(
              value: budgetId,
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('Unallocated'),
                ),
                ...budgets.map((b) =>
                    DropdownMenuItem<String?>(value: b.id, child: Text(b.name))),
              ],
              onChanged: onBudgetChanged,
              decoration: const InputDecoration(
                  labelText: 'Budget', isDense: true),
            ),
            if ((type == 'expense' || type == 'expense_refund') &&
                budget != null) ...[
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: categoryId,
                items: budget!.categories
                    .map((c) =>
                        DropdownMenuItem(value: c.id, child: Text(c.name)))
                    .toList(),
                onChanged: onCategoryChanged,
                decoration: const InputDecoration(
                    labelText: 'Category', isDense: true),
              ),
            ],
          ],
          const SizedBox(height: 10),
          TextFormField(
            initialValue: note,
            decoration: const InputDecoration(
                labelText: 'Note', isDense: true),
            onChanged: onNoteChanged,
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              OutlinedButton(
                onPressed: saving ? null : onCancel,
                child: const Text('Cancel'),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: saving ? null : onSave,
                icon: const Icon(Icons.check_rounded, size: 16),
                label: const Text('Save'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
