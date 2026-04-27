import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import 'package:provider/provider.dart';
import '../widgets/date_filter_bar.dart';

import '../../core/date_utils.dart' as du;
import '../../core/snack_utils.dart';
import '../../data/models/models.dart';
import '../../state/app_controller.dart';
import '../../utils/amount_formatter.dart';
// ── Date-section helpers ───────────────────────────────────────────────────────

class _DateHeader {
  const _DateHeader({
    required this.dateKey,
    required this.totalCredit,
    required this.totalDebit,
    required this.txIds,
  });
  final String dateKey;
  final double totalCredit;
  final double totalDebit;
  /// IDs of all transactions in this date group (used for checkbox state).
  final List<String> txIds;
}

/// Builds a flat list for a reverse:true ListView.
/// Within each date group the transactions come first, header last — so with
/// reverse rendering the header appears visually above the transactions.
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
    // Header after transactions so it renders above them in reverse list.
    result.addAll(group);
    result.add(_DateHeader(
      dateKey: date,
      totalCredit: credit,
      totalDebit: debit,
      txIds: group.map((tx) => tx.id).toList(),
    ));
  }
  return result;
}

class _DateSectionHeader extends StatelessWidget {
  const _DateSectionHeader({
    required this.header,
    this.selectMode = false,
    this.allGroupSelected = false,
    this.onToggle,
  });

  final _DateHeader header;
  final bool selectMode;
  final bool allGroupSelected;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return GestureDetector(
      onTap: selectMode ? onToggle : null,
      child: Padding(
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
            if (selectMode) ...[
              const SizedBox(width: 4),
              Transform.scale(
                scale: 0.8,
                child: Checkbox(
                  value: allGroupSelected,
                  visualDensity: VisualDensity.compact,
                  onChanged: (_) => onToggle?.call(),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

enum _Step { type, budget, category }

/// Sentinel passed through onPickBudget when the user selects "Unallocated".
const _kUnallocated = '__unallocated__';

class DraftsPage extends StatefulWidget {
  const DraftsPage({super.key});

  @override
  State<DraftsPage> createState() => _DraftsPageState();
}

class _DraftsPageState extends State<DraftsPage> {
  bool _selectMode = false;
  final Set<String> _selected = {};

  bool _settling = false;
  bool _committing = false;
  _Step _step = _Step.type;
  String? _stype;
  String? _budgetId;
  String? _categoryId;
  String? _activeId;
  bool _isUnallocated = false;

  final ScrollController _scrollCtrl = ScrollController();
  // Guard: only trigger load-more after the user has actually scrolled,
  // preventing an immediate fire on first render (where pixels == 0).
  bool _hasScrolled = false;

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
    if (!_hasScrolled && pos.pixels > 60) {
      _hasScrolled = true;
    }
    // In reverse:true, pixels==0 is the BOTTOM (oldest items).
    // Trigger when the user scrolls back down near the oldest items.
    if (_hasScrolled &&
        pos.pixels <= 120 &&
        pos.maxScrollExtent > 0) {
      context.read<AppController>().loadMoreDrafts();
    }
  }

  void _openSettle(List<TransactionDto> drafts, {String? forId}) {
    if (drafts.isEmpty) return;
    setState(() {
      _settling = true;
      _step = _Step.type;
      _stype = null;
      _budgetId = null;
      _categoryId = null;
      _isUnallocated = false;
      _activeId = _selectMode ? null : (forId ?? drafts.first.id);
    });
    // Scroll to the visual bottom of the reverse:true list (pixels == 0).
    if (!_selectMode && forId == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollCtrl.hasClients) {
          _scrollCtrl.animateTo(
            0,
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  void _closeSettle() {
    setState(() {
      _settling = false;
      _step = _Step.type;
      _stype = null;
      _budgetId = null;
      _categoryId = null;
      _isUnallocated = false;
    });
  }

  void _afterSuccess() {
    setState(() {
      _settling = false;
      _committing = false;
      _step = _Step.type;
      _stype = null;
      _budgetId = null;
      _categoryId = null;
      _isUnallocated = false;
      _selected.clear();
      _selectMode = false;
      _activeId = null;
    });
  }

  void _toggleSelectAll(List<TransactionDto> drafts) {
    setState(() {
      if (_selected.length == drafts.length) {
        _selected.clear();
      } else {
        _selected.addAll(drafts.map((tx) => tx.id));
      }
    });
  }

  void _toggleDateGroup(String dateKey, List<TransactionDto> drafts) {
    final groupIds = drafts
        .where((tx) =>
            (tx.transactionDate ?? tx.createdAt.substring(0, 10)) == dateKey)
        .map((tx) => tx.id)
        .toSet();
    final allSelected = groupIds.every((id) => _selected.contains(id));
    setState(() {
      if (allSelected) {
        _selected.removeAll(groupIds);
      } else {
        _selected.addAll(groupIds);
      }
    });
  }

  List<String> _targetIds(List<TransactionDto> drafts) {
    if (_selectMode && _selected.isNotEmpty) return _selected.toList();
    if (_activeId != null) return [_activeId!];
    if (drafts.isEmpty) return [];
    return [drafts.first.id];
  }

  Future<void> _commit(AppController app, List<String> ids) async {
    final t = _stype;
    if (t == null || ids.isEmpty) return;
    // For transfer, a null budgetId is only valid when the user explicitly
    // chose Unallocated; otherwise the budget step hasn't been completed yet.
    if (t == 'transfer' && _budgetId == null && !_isUnallocated) return;
    try {
      await app.api.settle(
        transactionIds: ids,
        transactionType: t,
        budgetId: _budgetId,
        categoryId: t == 'transfer' ? null : _categoryId,
      );
      await app.refreshAll();
      if (!mounted) return;
      showTopSnack(context, 'Settled');
      _afterSuccess();
    } catch (e) {
      if (!mounted) return;
      setState(() => _committing = false);
      showTopSnack(context, 'Error: $e');
    }
  }

  /// Returns the shared direction of the transactions being settled,
  /// or null if mixed / unknown.
  String? _settleDirection(List<TransactionDto> drafts) {
    final ids = _selectMode && _selected.isNotEmpty
        ? _selected.toList()
        : (_activeId != null ? [_activeId!] : <String>[]);
    if (ids.isEmpty) return null;
    final directions = ids
        .map((id) {
          for (final d in drafts) {
            if (d.id == id) return d.direction;
          }
          return null;
        })
        .whereType<String>()
        .toSet();
    return directions.length == 1 ? directions.first : null;
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final drafts = app.drafts;
    final cs = Theme.of(context).colorScheme;

    return Column(
      children: [
        // ── Filter row ────────────────────────────────────────────────────
        FilterRow(app: app),

        // ── Draft list ────────────────────────────────────────────────────
        Expanded(
          child: drafts.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.inbox_outlined,
                          size: 48,
                          color: cs.onSurfaceVariant.withAlpha(100)),
                      const SizedBox(height: 10),
                      Text('No drafts',
                          style: TextStyle(
                              color: cs.onSurfaceVariant,
                              fontWeight: FontWeight.w500)),
                    ],
                  ),
                )
              : Builder(builder: (context) {
                  final flatItems = _buildFlatItems(drafts);
                  return ListView.builder(
                  controller: _scrollCtrl,
                  reverse: true,
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  // Extra item at index 0 (bottom in reverse:true) shows the
                  // load-more indicator while fetching older drafts.
                  itemCount: flatItems.length +
                      (app.draftsPage.isLoadingMore ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (app.draftsPage.isLoadingMore && i == 0) {
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
                    final itemIndex =
                        i - (app.draftsPage.isLoadingMore ? 1 : 0);
                    final item = flatItems[itemIndex];
                    if (item is _DateHeader) {
                      final allGroupSelected = item.txIds.isNotEmpty &&
                          item.txIds.every((id) => _selected.contains(id));
                      return _DateSectionHeader(
                        header: item,
                        selectMode: _selectMode,
                        allGroupSelected: allGroupSelected,
                        onToggle: () => _toggleDateGroup(item.dateKey, drafts),
                      );
                    }
                    final tx = item as TransactionDto;
                    final isActive = tx.id == _activeId;
                    final isSelected = _selected.contains(tx.id);
                    return _DraftCard(
                      tx: tx,
                      accounts: app.accounts,
                      selectMode: _selectMode,
                      selected: isSelected,
                      isActive: isActive,
                      settling: _settling,
                      settleType: isActive ? _stype : null,
                      settleBudgetName: isActive
                          ? _budgetNameForId(_budgetId, app.budgets)
                          : null,
                      settleCategoryName: isActive
                          ? _categoryNameForId(_budgetId, _categoryId, app.budgets)
                          : null,
                      onTap: _selectMode
                          ? () => setState(() {
                                if (isSelected) {
                                  _selected.remove(tx.id);
                                } else {
                                  _selected.add(tx.id);
                                }
                              })
                          : _settling
                              ? () => setState(() => _activeId = tx.id)
                              : () => _openSettle(drafts, forId: tx.id),
                    );
                  },
                );
                }),
        ),

        // ── Inline settle panel ───────────────────────────────────────────
        if (_settling)
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            child: _committing
                ? _SettleLoadingPanel(key: const ValueKey('loading'))
                : _SettlePanel(
            step: _step,
            stype: _stype,
            budgetId: _budgetId,
            isUnallocated: _isUnallocated,
            budgets: app.budgets,
            direction: _settleDirection(drafts),
            transferSkipsCategory: _stype == 'transfer',
            onTypeSelected: (type) {
              setState(() {
                _stype = type;
                _step = _Step.budget;
              });
            },
            onPickBudget: (id) {
              final pickedUnallocated = id == _kUnallocated;
              final isCommit = _stype == 'transfer' || pickedUnallocated;
              setState(() {
                _budgetId = pickedUnallocated ? null : id;
                _isUnallocated = pickedUnallocated;
                if (isCommit) {
                  _committing = true; // keep _settling=true so loader shows
                } else {
                  _step = _Step.category;
                }
              });
              if (isCommit) {
                final ids = _targetIds(drafts);
                Future.microtask(() {
                  if (!mounted) return;
                  _commit(app, ids);
                });
              }
            },
            onPickCategory: (id) {
              final ids = _targetIds(drafts);
              setState(() {
                _categoryId = id;
                _committing = true; // keep _settling=true so loader shows
              });
              _commit(app, ids);
            },
            onBack: () {
              if (_step == _Step.budget) {
                setState(() {
                  _step = _Step.type;
                  _budgetId = null;
                  _stype = null;
                });
              } else if (_step == _Step.category) {
                setState(() {
                  _step = _Step.budget;
                  _categoryId = null;
                });
              }
            },
            onClose: _closeSettle,
                key: const ValueKey('panel'),
          ),
          ),

        // ── Bottom action bar ─────────────────────────────────────────────
        if (!_settling && drafts.isNotEmpty)
          _BottomActionBar(
            drafts: drafts,
            selectMode: _selectMode,
            selectedCount: _selected.length,
            selectedIds: _selected,
            onSettleSingle: () => _openSettle(drafts),
            onEnableMultiSelect: () => setState(() {
              _selectMode = true;
            }),
            onCancelMultiSelect: () => setState(() {
              _selectMode = false;
              _selected.clear();
            }),
            onSettleSelected: () => _openSettle(drafts),
            onSelectAll: () => _toggleSelectAll(drafts),
            onToggleDateGroup: (key) => _toggleDateGroup(key, drafts),
          ),
      ],
    );
  }

  String? _budgetNameForId(String? id, List<BudgetDto> budgets) {
    if (id == null) return _isUnallocated ? 'Unallocated' : null;
    for (final b in budgets) {
      if (b.id == id) return b.name;
    }
    return null;
  }

  String? _categoryNameForId(
      String? budgetId, String? categoryId, List<BudgetDto> budgets) {
    if (budgetId == null || categoryId == null) return null;
    for (final b in budgets) {
      if (b.id == budgetId) {
        for (final c in b.categories) {
          if (c.id == categoryId) return c.name;
        }
      }
    }
    return null;
  }
}

// ── Bottom Action Bar ──────────────────────────────────────────────────────────

class _BottomActionBar extends StatelessWidget {
  const _BottomActionBar({
    required this.drafts,
    required this.selectMode,
    required this.selectedCount,
    required this.selectedIds,
    required this.onSettleSingle,
    required this.onEnableMultiSelect,
    required this.onCancelMultiSelect,
    required this.onSettleSelected,
    required this.onSelectAll,
    required this.onToggleDateGroup,
  });

  final List<TransactionDto> drafts;
  final bool selectMode;
  final int selectedCount;
  final Set<String> selectedIds;
  final VoidCallback onSettleSingle;
  final VoidCallback onEnableMultiSelect;
  final VoidCallback onCancelMultiSelect;
  final VoidCallback onSettleSelected;
  final VoidCallback onSelectAll;
  final void Function(String dateKey) onToggleDateGroup;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (!selectMode) {
      // ── Normal mode: Settle Single | Settle Multiple ─────────────────
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: drafts.isEmpty ? null : onSettleSingle,
                icon: const Icon(Icons.arrow_circle_right_outlined, size: 16),
                label: const Text('Settle Single'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 46),
                  elevation: 2,
                  shadowColor: Colors.black26,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed: drafts.isEmpty ? null : onEnableMultiSelect,
                icon: const Icon(Icons.checklist_rounded, size: 16),
                label: const Text('Settle Multiple'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 46),
                  elevation: 3,
                  shadowColor: Colors.black38,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          ],
        ),
      );
    }

    // ── Multi-select mode ─────────────────────────────────────────────
    final allSelected = selectedCount == drafts.length && drafts.isNotEmpty;

    // Compute totals and unique-day count for selected transactions.
    double selCredit = 0, selDebit = 0;
    final selDays = <String>{};
    for (final tx in drafts) {
      if (!selectedIds.contains(tx.id)) continue;
      final amt = double.tryParse(tx.amount) ?? 0;
      if (tx.direction == 'credit') selCredit += amt;
      else selDebit += amt;
      selDays.add(tx.transactionDate ?? tx.createdAt.substring(0, 10));
    }

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(top: BorderSide(color: cs.outlineVariant.withAlpha(100))),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Cancel | totals | Select All ─────────────────────────────
          Row(
            children: [
              GestureDetector(
                onTap: onCancelMultiSelect,
                child: Icon(Icons.close_rounded,
                    size: 22, color: cs.onSurfaceVariant),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: selectedCount == 0
                    ? const SizedBox.shrink()
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          RichText(
                            textAlign: TextAlign.center,
                            text: TextSpan(
                              style: TextStyle(
                                fontSize: 12,
                                color: cs.onSurfaceVariant,
                              ),
                              children: [
                                const TextSpan(text: 'Selected  '),
                                if (selCredit > 0.005)
                                  TextSpan(
                                    text: '+₹${compactAmount(selCredit)}',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.gain,
                                    ),
                                  ),
                                if (selCredit > 0.005 && selDebit > 0.005)
                                  const TextSpan(text: '  '),
                                if (selDebit > 0.005)
                                  TextSpan(
                                    text: '−₹${compactAmount(selDebit)}',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: AppColors.loss,
                                    ),
                                  ),
                                if (selDays.isNotEmpty)
                                  TextSpan(
                                    text:
                                        '  over ${selDays.length} ${selDays.length == 1 ? 'day' : 'days'}',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w400),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
              ),
              const SizedBox(width: 12),
              _SelectChip(
                label: 'Select All',
                icon: allSelected
                    ? Icons.check_box_rounded
                    : Icons.check_box_outline_blank_rounded,
                selected: allSelected,
                onTap: onSelectAll,
              ),
            ],
          ),
          const SizedBox(height: 8),
          // ── Settle Selected button ────────────────────────────────────
          FilledButton.icon(
            onPressed: selectedCount > 0 ? onSettleSelected : null,
            icon: const Icon(Icons.check_circle_outline, size: 18),
            label: Text(selectedCount > 0
                ? 'Settle Selected ($selectedCount)'
                : 'Select transactions to settle'),
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 46),
              elevation: 4,
              shadowColor: Colors.black38,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
      ),
    );
  }
}

class _SelectChip extends StatelessWidget {
  const _SelectChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? cs.primaryContainer : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? cs.primary.withAlpha(120)
                : cs.outlineVariant.withAlpha(80),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon,
                  size: 13,
                  color: selected ? cs.primary : cs.onSurfaceVariant),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: selected ? cs.primary : cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Settle Loading Panel ───────────────────────────────────────────────────────

class _SettleLoadingPanel extends StatelessWidget {
  const _SettleLoadingPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary),
          ),
          const SizedBox(width: 12),
          Text(
            'Saving…',
            style: TextStyle(
              fontSize: 13,
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Settle Panel ───────────────────────────────────────────────────────────────

class _SettlePanel extends StatelessWidget {
  const _SettlePanel({
    super.key,
    required this.step,
    required this.stype,
    required this.budgetId,
    required this.isUnallocated,
    required this.budgets,
    required this.direction,
    required this.transferSkipsCategory,
    required this.onTypeSelected,
    required this.onPickBudget,
    required this.onPickCategory,
    required this.onBack,
    required this.onClose,
  });

  final _Step step;
  final String? stype;
  final String? budgetId;
  final bool isUnallocated;
  final List<BudgetDto> budgets;
  final String? direction;
  /// When true (transfer), flow is Type → Budget only; no category step.
  final bool transferSkipsCategory;
  final void Function(String) onTypeSelected;
  final void Function(String) onPickBudget;
  final void Function(String) onPickCategory;
  final VoidCallback onBack;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    Widget content;
    switch (step) {
      case _Step.type:
        content = _TypeRow(
          selected: stype,
          direction: direction,
          onSelect: onTypeSelected,
        );
        break;

      case _Step.budget:
        // "Unallocated" is prepended as index 0; real budgets follow at index+1.
        final budgetItems = [
          'Unallocated',
          ...budgets.map((b) => b.name),
        ];
        final budgetIcons = [
          Icons.inbox_outlined,
          ...List.filled(budgets.length, Icons.pie_chart_outline_rounded),
        ];
        final selectedBudgetIndex = isUnallocated
            ? 0
            : (budgetId != null
                ? budgets.indexWhere((b) => b.id == budgetId) + 1
                : -1);
        content = _OptionGrid(
          items: budgetItems,
          icons: budgetIcons,
          selectedIndex: selectedBudgetIndex,
          onSelect: (i) => i == 0
              ? onPickBudget(_kUnallocated)
              : onPickBudget(budgets[i - 1].id),
        );
        break;

      case _Step.category:
        BudgetDto? budget;
        for (final b in budgets) {
          if (b.id == budgetId) {
            budget = b;
            break;
          }
        }
        if (budget == null) {
          content = const Center(child: Text('No budget selected'));
        } else {
          content = _OptionGrid(
            items: budget.categories.map((c) => c.name).toList(),
            icons: List.filled(
                budget.categories.length, Icons.label_outline_rounded),
            selectedIndex: -1,
            onSelect: (i) => onPickCategory(budget!.categories[i].id),
          );
        }
        break;
    }

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header row: back + breadcrumb + close
          Row(
            children: [
              if (step != _Step.type)
                GestureDetector(
                  onTap: onBack,
                  child: Row(
                    children: [
                      Icon(Icons.arrow_back_ios_new_rounded,
                          size: 14, color: cs.primary),
                      const SizedBox(width: 2),
                      Text('Back',
                          style: TextStyle(
                              fontSize: 12,
                              color: cs.primary,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              if (step != _Step.type) const SizedBox(width: 10),
              _StepBreadcrumb(
                step: step,
                omitCategory: transferSkipsCategory,
              ),
              const Spacer(),
              GestureDetector(
                onTap: onClose,
                child: Icon(Icons.close_rounded,
                    size: 20, color: cs.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: SingleChildScrollView(child: content),
          ),
        ],
      ),
    );
  }
}

class _StepBreadcrumb extends StatelessWidget {
  const _StepBreadcrumb({required this.step, this.omitCategory = false});
  final _Step step;
  final bool omitCategory;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final labels =
        omitCategory ? ['Type', 'Budget'] : ['Type', 'Budget', 'Category'];
    final activeIndex = omitCategory
        ? (step == _Step.type ? 0 : 1)
        : step.index;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(labels.length, (i) {
        final done = i < activeIndex;
        final active = i == activeIndex;
        return Row(
          children: [
            if (i > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Icon(Icons.chevron_right,
                    size: 14,
                    color: done ? cs.primary : cs.onSurfaceVariant.withAlpha(80)),
              ),
            Text(
              labels[i],
              style: TextStyle(
                fontSize: 12,
                fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                color: active
                    ? cs.primary
                    : done
                        ? cs.primary.withAlpha(160)
                        : cs.onSurfaceVariant.withAlpha(120),
              ),
            ),
          ],
        );
      }),
    );
  }
}

// ── Type Row (compact horizontal, Expense rightmost) ──────────────────────────

class _TypeRow extends StatelessWidget {
  const _TypeRow({
    required this.selected,
    required this.direction,
    required this.onSelect,
  });

  final String? selected;
  final String? direction;
  final void Function(String) onSelect;

  static const _allTypes = [
    ('transfer', 'Transfer', Icons.swap_horiz_rounded),
    ('expense_refund', 'Refund', Icons.add_circle_outline),
    ('expense', 'Expense', Icons.remove_circle_outline),
  ];

  List<(String, String, IconData)> get _types {
    if (direction == 'debit') {
      // debit = money out → Expense or Transfer
      return _allTypes
          .where((t) => t.$1 == 'expense' || t.$1 == 'transfer')
          .toList();
    } else if (direction == 'credit') {
      // credit = money in → Refund or Transfer
      return _allTypes
          .where((t) => t.$1 == 'expense_refund' || t.$1 == 'transfer')
          .toList();
    }
    return List.of(_allTypes);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: _types.map((t) {
        final (key, label, icon) = t;
        final active = selected == key;
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(
              left: key == 'transfer' ? 0 : 6,
            ),
            child: Material(
              color: active ? cs.primary : cs.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(10),
              elevation: active ? 3 : 1,
              shadowColor: Colors.black26,
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => onSelect(key),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon,
                          size: 18,
                          color: active ? cs.onPrimary : cs.primary),
                      const SizedBox(height: 4),
                      Text(label,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: active
                                ? FontWeight.w700
                                : FontWeight.w400,
                            color: active ? cs.onPrimary : cs.onSurface,
                          )),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

// ── Option Grid ────────────────────────────────────────────────────────────────

class _OptionGrid extends StatelessWidget {
  const _OptionGrid({
    required this.items,
    required this.icons,
    required this.selectedIndex,
    required this.onSelect,
  });

  final List<String> items;
  final List<IconData> icons;
  final int selectedIndex;
  final void Function(int) onSelect;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final cells = List.generate(items.length, (i) {
      final active = i == selectedIndex;
      return Material(
        color: active ? cs.primary : cs.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(10),
        elevation: active ? 3 : 1,
        shadowColor: Colors.black26,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => onSelect(i),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (i < icons.length)
                  Icon(icons[i],
                      size: 18,
                      color: active ? cs.onPrimary : cs.primary),
                const SizedBox(height: 4),
                Text(
                  items[i],
                  style: TextStyle(
                    color: active ? cs.onPrimary : cs.onSurface,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    fontSize: 13,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
    });

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: cells
          .map((c) => SizedBox(
                width: (MediaQuery.sizeOf(context).width - 56) / 2,
                child: c,
              ))
          .toList(),
    );
  }
}

// ── Draft Card ─────────────────────────────────────────────────────────────────

class _DraftCard extends StatelessWidget {
  const _DraftCard({
    required this.tx,
    required this.accounts,
    required this.selectMode,
    required this.selected,
    required this.isActive,
    required this.settling,
    this.settleType,
    this.settleBudgetName,
    this.settleCategoryName,
    this.onTap,
  });

  final TransactionDto tx;
  final List<AccountDto> accounts;
  final bool selectMode;
  final bool selected;
  final bool isActive;
  final bool settling;
  final String? settleType;
  final String? settleBudgetName;
  final String? settleCategoryName;
  final VoidCallback? onTap;

  String _accountName() {
    for (final a in accounts) {
      if (a.id == tx.accountId) return a.name;
    }
    return tx.accountId;
  }

  String _noteText() {
    if (tx.note?.isNotEmpty == true) return tx.note!;
    if (tx.descriptionReadable?.isNotEmpty == true) return tx.descriptionReadable!;
    if (tx.description?.isNotEmpty == true) return tx.description!;
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDebit = tx.direction == 'debit';
    final accentColor =
        isDebit ? AppColors.loss : AppColors.gain;
    final highlight = isActive && settling;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: highlight
            ? Border.all(color: cs.primary, width: 2)
            : Border.all(color: Colors.transparent, width: 2),
        boxShadow: highlight
            ? [
                BoxShadow(
                  color: cs.primary.withAlpha(40),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                )
              ]
            : [],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Material(
          color: cs.surfaceContainerLowest,
          child: InkWell(
            onTap: onTap,
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Left accent bar
                  Container(width: 4, color: accentColor),

                  // Card content
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Main content column
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Row 1: amount    description    [settle chips]
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Text(
                                      '${isDebit ? '−' : '+'} ₹${tx.amount}',
                                      style: theme.textTheme.titleMedium
                                          ?.copyWith(
                                        color: accentColor,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: -0.3,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        _noteText(),
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                                color: cs.onSurfaceVariant),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (highlight)
                                      _SettlePreviewChips(
                                        type: settleType,
                                        budget: settleBudgetName,
                                        category: settleCategoryName,
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 3),
                                // Row 2: account with bank icon
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.account_balance_wallet_outlined,
                                        size: 11,
                                        color: cs.onSurfaceVariant.withAlpha(140)),
                                    const SizedBox(width: 4),
                                    Flexible(
                                      child: Text(
                                        _accountName(),
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                                color: cs.onSurfaceVariant),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          // Right column: action icon at top, date at bottom
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                if (selectMode)
                                  Checkbox(
                                    value: selected,
                                    visualDensity: VisualDensity.compact,
                                    onChanged: (_) => onTap?.call(),
                                  )
                                else if (!settling)
                                  Icon(Icons.chevron_right_rounded,
                                      size: 16, color: cs.outlineVariant)
                                else
                                  const SizedBox.shrink(),
                                Text(
                                  du.formatDate(tx.transactionDate),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                      color:
                                          cs.onSurfaceVariant.withAlpha(150)),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.icon, required this.label, this.overflow = false});
  final IconData icon;
  final String label;
  final bool overflow;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 11, color: cs.onSurfaceVariant),
        const SizedBox(width: 3),
        overflow
            ? Flexible(
                child: Text(label,
                    style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w500),
                    overflow: TextOverflow.ellipsis),
              )
            : Text(label,
                style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w500)),
      ],
    );
  }
}

class _SettlePreviewChips extends StatelessWidget {
  const _SettlePreviewChips({this.type, this.budget, this.category});

  final String? type;
  final String? budget;
  final String? category;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final items = <String?>[type, budget, category].whereType<String>().toList();
    if (items.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: 4,
      children: items
          .map((label) => Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(label,
                    style: TextStyle(
                      fontSize: 11,
                      color: cs.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    )),
              ))
          .toList(),
    );
  }
}
