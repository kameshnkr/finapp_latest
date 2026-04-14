import 'package:flutter/material.dart';

import '../../core/app_theme.dart';
import 'package:provider/provider.dart';

import '../../core/date_utils.dart' as du;
import '../../core/snack_utils.dart';
import '../../data/models/models.dart';
import '../../state/app_controller.dart';
import '../widgets/date_filter_bar.dart';

enum _Step { type, budget, category }

class DraftsPage extends StatefulWidget {
  const DraftsPage({super.key});

  @override
  State<DraftsPage> createState() => _DraftsPageState();
}

class _DraftsPageState extends State<DraftsPage> {
  bool _selectMode = false;
  final Set<String> _selected = {};

  bool _settling = false;
  _Step _step = _Step.type;
  String? _stype;
  String? _budgetId;
  String? _categoryId;
  String? _activeId;

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
      _activeId = _selectMode ? null : (forId ?? drafts.first.id);
    });
  }

  void _closeSettle() {
    setState(() {
      _settling = false;
      _step = _Step.type;
      _stype = null;
      _budgetId = null;
      _categoryId = null;
    });
  }

  void _afterSuccess() {
    setState(() {
      _settling = false;
      _step = _Step.type;
      _stype = null;
      _budgetId = null;
      _categoryId = null;
      _selected.clear();
      _selectMode = false;
      _activeId = null;
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
    if (t == 'transfer' && _budgetId == null) return;
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
        // ── Date filter ───────────────────────────────────────────────────
        const DateFilterBar(),

        // ── Toolbar ──────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              FilterChip(
                label: const Text('Multi-select'),
                selected: _selectMode,
                avatar: Icon(
                  _selectMode
                      ? Icons.check_box_outlined
                      : Icons.check_box_outline_blank,
                  size: 16,
                ),
                showCheckmark: false,
                onSelected: (v) => setState(() {
                  _selectMode = v;
                  if (!v) {
                    _selected.clear();
                    if (_settling) _closeSettle();
                  }
                }),
              ),
              const Spacer(),
              if (_selectMode && _selected.isNotEmpty)
                FilledButton.icon(
                  onPressed: () => _openSettle(drafts),
                  icon: const Icon(Icons.check_circle_outline, size: 18),
                  label: Text('Settle ${_selected.length} Items'),
                ),
            ],
          ),
        ),

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
              : ListView.builder(
                  controller: _scrollCtrl,
                  reverse: true,
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  // Extra item at index 0 (bottom in reverse:true) shows the
                  // load-more indicator while fetching older drafts.
                  itemCount: drafts.length +
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
                    final txIndex =
                        i - (app.draftsPage.isLoadingMore ? 1 : 0);
                    final tx = drafts[txIndex];
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
                ),
        ),

        // ── Inline settle panel ───────────────────────────────────────────
        if (_settling)
          _SettlePanel(
            step: _step,
            stype: _stype,
            budgetId: _budgetId,
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
              setState(() {
                _budgetId = id;
                if (_stype == 'transfer') {
                  _settling = false;
                } else {
                  _step = _Step.category;
                }
              });
              if (_stype == 'transfer') {
                final ids = _targetIds(drafts);
                Future.microtask(() {
                  if (!mounted) return;
                  _commit(app, ids);
                });
              }
            },
            onPickCategory: (id) {
              // Close panel immediately — commit runs silently in background
              final ids = _targetIds(drafts);
              setState(() {
                _categoryId = id;
                _settling = false;
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
          ),

        // ── Start Settling button ─────────────────────────────────────────
        if (!_settling && !_selectMode && drafts.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => _openSettle(drafts),
                icon: const Icon(Icons.receipt_long_outlined, size: 18),
                label: const Text('Start Settling'),
              ),
            ),
          ),
      ],
    );
  }

  String? _budgetNameForId(String? id, List<BudgetDto> budgets) {
    if (id == null) return null;
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

// ── Settle Panel ───────────────────────────────────────────────────────────────

class _SettlePanel extends StatelessWidget {
  const _SettlePanel({
    required this.step,
    required this.stype,
    required this.budgetId,
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
        content = _OptionGrid(
          items: budgets.map((b) => b.name).toList(),
          icons: List.filled(budgets.length, Icons.pie_chart_outline_rounded),
          selectedIndex: budgets.indexWhere((b) => b.id == budgetId),
          onSelect: (i) => onPickBudget(budgets[i].id),
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
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          if (selectMode)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: Checkbox(
                                value: selected,
                                visualDensity: VisualDensity.compact,
                                onChanged: (_) => onTap?.call(),
                              ),
                            ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Amount row
                                Row(
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
                                    if (highlight) const Spacer(),
                                    if (highlight)
                                      _SettlePreviewChips(
                                        type: settleType,
                                        budget: settleBudgetName,
                                        category: settleCategoryName,
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 3),
                                // Account + description/note + date row
                                Row(
                                  children: [
                                    Flexible(
                                      child: _MetaChip(
                                        icon: Icons.account_balance_wallet_outlined,
                                        label: tx.note?.isNotEmpty == true
                                            ? '${_accountName()}  ·  ${tx.note}'
                                            : tx.descriptionReadable?.isNotEmpty == true
                                                ? '${_accountName()}  ·  ${tx.descriptionReadable}'
                                                : tx.description?.isNotEmpty == true
                                                    ? '${_accountName()}  ·  ${tx.description}'
                                                    : _accountName(),
                                        overflow: true,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      du.formatDate(tx.transactionDate),
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                              color: cs.onSurfaceVariant
                                                  .withAlpha(150)),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          if (!selectMode && !settling)
                            Icon(Icons.chevron_right_rounded,
                                size: 16, color: cs.outlineVariant),
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
