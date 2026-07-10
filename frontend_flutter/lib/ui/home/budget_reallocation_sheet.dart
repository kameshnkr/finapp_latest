import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../core/snack_utils.dart';
import '../../data/models/models.dart';
import '../../state/app_controller.dart';
import '../../utils/amount_formatter.dart';

/// Guided reallocation sheet.
///
/// Opened from the Edit Account sheet when the user taps "Modify" on a budget.
/// Shows the target budget, a target-amount input, and — for an increase — a
/// distribution table to pull funds from other budgets / unallocated.
class BudgetReallocationSheet extends StatefulWidget {
  const BudgetReallocationSheet({
    super.key,
    required this.account,
    required this.targetBudgetId,
  });

  final AccountDto account;
  final String targetBudgetId;

  @override
  State<BudgetReallocationSheet> createState() =>
      _BudgetReallocationSheetState();
}

class _BudgetReallocationSheetState extends State<BudgetReallocationSheet> {
  late final TextEditingController _targetCtrl;
  late final TextEditingController _unallocDeductCtrl;
  final Map<String, TextEditingController> _deductCtrls = {};
  bool _saving = false;
  bool _hasMoreBelow = false;
  bool _hasMoreAbove = false;
  // Tracks whether the user has manually typed in the unallocated field.
  // Auto-fill only runs when this is false, so it always reflects the full
  // delta rather than freezing on the first character typed in the target.
  bool _unallocUserEdited = false;

  // ── Derived from widget data ──────────────────────────────────────────────

  AllocationDto get _targetAlloc => widget.account.allocations.firstWhere(
        (a) => a.budgetId == widget.targetBudgetId,
        orElse: () => AllocationDto(
            budgetId: widget.targetBudgetId,
            budgetName: '',
            amount: '0'),
      );

  List<AllocationDto> get _sourceAllocs => widget.account.allocations
      .where((a) => a.budgetId != widget.targetBudgetId)
      .toList();

  double get _currentAlloc => double.tryParse(_targetAlloc.amount) ?? 0;

  double get _accountBalance =>
      double.tryParse(widget.account.totalBalance) ?? 0;

  double get _totalAllocated {
    double s = 0;
    for (final a in widget.account.allocations) {
      s += double.tryParse(a.amount) ?? 0;
    }
    return s;
  }

  double get _currentUnallocated => _accountBalance - _totalAllocated;

  // ── Live calculations ─────────────────────────────────────────────────────

  double get _parsedTarget =>
      double.tryParse(_targetCtrl.text.trim()) ?? _currentAlloc;

  double get _delta =>
      double.parse((_parsedTarget - _currentAlloc).toStringAsFixed(2));

  bool get _isNoChange => _delta.abs() < 0.005;
  bool get _isIncrease => _delta > 0.005;
  bool get _isDecrease => _delta < -0.005;

  double get _unallocDeduct =>
      double.tryParse(_unallocDeductCtrl.text.trim()) ?? 0;

  double get _budgetDeductTotal {
    double s = 0;
    for (final c in _deductCtrls.values) {
      s += double.tryParse(c.text.trim()) ?? 0;
    }
    return s;
  }

  double get _totalDeducted => _unallocDeduct + _budgetDeductTotal;

  /// Remaining amount still to distribute.
  /// For increase: delta - totalDeducted (positive = need more).
  /// For decrease: freed - totalAdded  (positive = still to distribute).
  double get _remaining =>
      double.parse((_delta.abs() - _totalDeducted).toStringAsFixed(2));

  // ── Validation ────────────────────────────────────────────────────────────

  String? get _targetError {
    if (_parsedTarget < 0) return 'Target allocation cannot be negative';
    return null;
  }

  String? get _unallocError {
    if (_unallocDeduct < 0) return 'Cannot be negative';
    // For increase only: can't deduct more than is available in unallocated.
    if (_isIncrease && _unallocDeduct > _currentUnallocated + 0.005) {
      return 'Only ₹${compactAmount(_currentUnallocated)} available';
    }
    return null;
  }

  String? _sourceError(String budgetId) {
    final ctrl = _deductCtrls[budgetId];
    if (ctrl == null) return null;
    final v = double.tryParse(ctrl.text.trim()) ?? 0;
    if (v < 0) return 'Cannot be negative';
    // For increase only: can't deduct more than the source budget holds.
    if (_isIncrease) {
      final srcAlloc = double.tryParse(
              widget.account.allocations
                  .firstWhere((a) => a.budgetId == budgetId,
                      orElse: () => AllocationDto(
                          budgetId: budgetId, budgetName: '', amount: '0'))
                  .amount) ??
          0;
      if (v > max(0, srcAlloc) + 0.005) {
        return 'Only ₹${compactAmount(max(0, srcAlloc))} available';
      }
    }
    return null;
  }

  bool get _canSubmit {
    if (_isNoChange) return false;
    if (_targetError != null) return false;
    if (_isIncrease || _isDecrease) {
      if (_remaining.abs() > 0.015) return false;
      if (_unallocError != null) return false;
      for (final a in _sourceAllocs) {
        if (_sourceError(a.budgetId) != null) return false;
      }
    }
    return true;
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();

    _targetCtrl = TextEditingController(text: _formatAmt(_currentAlloc));
    _unallocDeductCtrl = TextEditingController(text: '');

    for (final a in _sourceAllocs) {
      _deductCtrls[a.budgetId] = TextEditingController(text: '')
        ..addListener(_onSourceChanged);
    }

    _targetCtrl.addListener(_onTargetChanged);
    // Use a separate listener so we can distinguish user edits from auto-fills.
    _unallocDeductCtrl.addListener(_onUnallocUserChanged);
  }

  @override
  void dispose() {
    _targetCtrl.dispose();
    _unallocDeductCtrl.dispose();
    for (final c in _deductCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  // ── Callbacks ─────────────────────────────────────────────────────────────

  void _onTargetChanged() {
    if (!mounted) return;
    if (_isIncrease && !_unallocUserEdited) {
      // Auto-fill unallocated with as much as possible from available funds.
      final autoFill =
          (_currentUnallocated > 0.005 ? min(_currentUnallocated, _delta) : 0.0)
              .clamp(0.0, _delta);
      _setUnallocSilently(_ctrlValue(autoFill));
    } else if (_isDecrease && !_unallocUserEdited) {
      // Auto-fill unallocated with all freed funds (user can redistribute).
      _setUnallocSilently(_ctrlValue(_delta.abs()));
    } else if (_isNoChange) {
      _unallocUserEdited = false;
      _setUnallocSilently('');
      for (final c in _deductCtrls.values) {
        _setSourceSilently(c, '');
      }
    }
    setState(() {});
  }

  /// Called only when the user physically types in the unallocated field.
  void _onUnallocUserChanged() {
    _unallocUserEdited = true;
    if (mounted) setState(() {});
  }

  void _onSourceChanged() {
    if (mounted) setState(() {});
  }

  /// Programmatically sets the unallocated field without marking it as
  /// user-edited, so auto-fill can continue to update it freely.
  void _setUnallocSilently(String value) {
    if (_unallocDeductCtrl.text == value) return;
    _unallocDeductCtrl.removeListener(_onUnallocUserChanged);
    _unallocDeductCtrl.text = value;
    _unallocDeductCtrl.addListener(_onUnallocUserChanged);
  }

  /// Programmatically sets a budget deduct field without triggering rebuilds.
  void _setSourceSilently(TextEditingController ctrl, String value) {
    if (ctrl.text == value) return;
    ctrl.removeListener(_onSourceChanged);
    ctrl.text = value;
    ctrl.addListener(_onSourceChanged);
  }

  // Keep the old name so existing call-sites in _submit still compile.
  void _setControllerSilently(TextEditingController ctrl, String value) =>
      _setSourceSilently(ctrl, value);

  void _reset() {
    _unallocUserEdited = false;
    _setUnallocSilently('');
    for (final c in _deductCtrls.values) {
      _setSourceSilently(c, '');
    }
    // Restore target to the original current allocation
    final initial = _formatAmt(_currentAlloc);
    if (_targetCtrl.text != initial) {
      _targetCtrl.text = initial;
    }
    setState(() {});
  }

  // ── Submit ────────────────────────────────────────────────────────────────

  Future<void> _submit() async {
    if (!_canSubmit) return;
    final app = context.read<AppController>();

    final sources = <Map<String, String>>[];
    for (final a in _sourceAllocs) {
      final v = double.tryParse(_deductCtrls[a.budgetId]!.text.trim()) ?? 0;
      if (v > 0.005) {
        sources.add({
          'budgetId': a.budgetId,
          'deductAmount': v.toStringAsFixed(2),
        });
      }
    }

    setState(() => _saving = true);
    try {
      await app.api.reallocateAllocation(
        widget.account.id,
        targetBudgetId: _targetAlloc.budgetId,
        targetNewAmount: _parsedTarget.toStringAsFixed(2),
        unallocatedDeductAmount: _unallocDeduct.toStringAsFixed(2),
        sources: sources,
        version: widget.account.version,
      );
      await app.refreshAccountsBudgets();
      if (!mounted) return;
      Navigator.of(context).pop();
      showTopSnack(context, 'Allocation updated');
    } catch (e) {
      if (!mounted) return;
      showTopSnack(context, 'Error: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _formatAmt(double v) {
    if (v == v.truncateToDouble()) return v.toStringAsFixed(0);
    return v.toStringAsFixed(2);
  }

  /// Returns empty string for zero so fields show the hint placeholder.
  String _ctrlValue(double v) => v.abs() < 0.005 ? '' : _formatAmt(v);

  String get _ctaLabel {
    if (_isNoChange) return 'No Change';
    if (_isIncrease) return 'Allocate ₹${compactAmount(_delta)}';
    // Decrease: describe where freed funds go.
    final toUnalloc = _unallocDeduct;
    final toBudgets = _budgetDeductTotal;
    if (toBudgets > 0.005 && toUnalloc > 0.005) {
      return 'Free & Redistribute ₹${compactAmount(_delta.abs())}';
    }
    if (toBudgets > 0.005) {
      return 'Redistribute ₹${compactAmount(_delta.abs())}';
    }
    return 'Free ₹${compactAmount(_delta.abs())} → Unallocated';
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 1.0,
      builder: (context, scrollCtrl) {
        return Column(
          children: [
            // ── Progress / drag handle ────────────────────────────────────
            if (_saving)
              LinearProgressIndicator(minHeight: 3, color: cs.primary)
            else
              const SizedBox(height: 3),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: cs.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // ── Title row ────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 12, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Reallocate Funds',
                            style: theme.textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(_targetAlloc.budgetName,
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(color: cs.primary)),
                      ],
                    ),
                  ),
                  TextButton(
                      onPressed: _reset, child: const Text('Reset')),
                  TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel')),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Divider(height: 1, color: cs.outlineVariant),

            // ── STICKY TOP: target card + section label ───────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildTargetCard(theme, cs),
                  if (!_isNoChange) ...[
                    const SizedBox(height: 8),
                    Text(
                      _isIncrease ? 'DEDUCT FROM' : 'DISTRIBUTE TO',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: cs.primary,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.0,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Spacer(),
                        Text(
                          _isIncrease ? 'Available' : 'Current',
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: cs.onSurfaceVariant),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 110,
                          child: Text(
                            _isIncrease ? 'Deduct' : 'Add',
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: cs.onSurfaceVariant),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                  ],
                ],
              ),
            ),

            // ── SCROLLABLE distribution list (increase + decrease) ────────
            if (!_isNoChange)
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest.withAlpha(60),
                    border: Border.symmetric(
                      horizontal: BorderSide(
                          color: cs.outlineVariant.withAlpha(140)),
                    ),
                  ),
                  child: Stack(
                    children: [
                      Scrollbar(
                        controller: scrollCtrl,
                        thumbVisibility: true,
                        child: NotificationListener<Notification>(
                          onNotification: (n) {
                            ScrollMetrics? metrics;
                            if (n is ScrollNotification) {
                              metrics = n.metrics;
                            } else if (n is ScrollMetricsNotification) {
                              metrics = n.metrics;
                            }
                            if (metrics != null) {
                              final hasMore = metrics.pixels <
                                  metrics.maxScrollExtent - 1.0;
                              final hasAbove = metrics.pixels > 1.0;
                              if (hasMore != _hasMoreBelow ||
                                  hasAbove != _hasMoreAbove) {
                                setState(() {
                                  _hasMoreBelow = hasMore;
                                  _hasMoreAbove = hasAbove;
                                });
                              }
                            }
                            return false;
                          },
                          child: ListView(
                            controller: scrollCtrl,
                            padding:
                                const EdgeInsets.fromLTRB(20, 8, 20, 8),
                            children: [
                              _buildSourceRow(
                                theme: theme,
                                cs: cs,
                                isIncrease: _isIncrease,
                                name: 'Unallocated',
                                icon: Icons.account_balance_wallet_outlined,
                                available: _currentUnallocated,
                                ctrl: _unallocDeductCtrl,
                                error: _unallocError,
                                disabled: _isIncrease &&
                                    _currentUnallocated <= 0,
                              ),
                              ..._sourceAllocs.map((a) {
                                final rawAlloc =
                                    double.tryParse(a.amount) ?? 0;
                                final disabled =
                                    _isIncrease && rawAlloc <= 0;
                                return _buildSourceRow(
                                  theme: theme,
                                  cs: cs,
                                  isIncrease: _isIncrease,
                                  name: a.budgetName,
                                  available: rawAlloc,
                                  ctrl: _deductCtrls[a.budgetId]!,
                                  error: disabled
                                      ? null
                                      : _sourceError(a.budgetId),
                                  disabled: disabled,
                                );
                              }),
                            ],
                          ),
                        ),
                      ),
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
                      // Scroll-more-above chevron
                      Positioned(
                        top: 5,
                        left: 0,
                        right: 0,
                        child: AnimatedOpacity(
                          opacity: _hasMoreAbove ? 1.0 : 0.0,
                          duration: const Duration(milliseconds: 200),
                          child: Center(
                            child: GestureDetector(
                              onTap: () => scrollCtrl.animateTo(
                                0,
                                duration:
                                    const Duration(milliseconds: 300),
                                curve: Curves.easeOut,
                              ),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 2),
                                decoration: BoxDecoration(
                                  color: cs.surfaceContainerHighest
                                      .withAlpha(220),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                      color: cs.outlineVariant
                                          .withAlpha(100)),
                                ),
                                child: Icon(
                                  Icons.keyboard_arrow_up_rounded,
                                  size: 16,
                                  color:
                                      cs.onSurfaceVariant.withAlpha(180),
                                ),
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
                      // Scroll-more chevron
                      Positioned(
                        bottom: 5,
                        left: 0,
                        right: 0,
                        child: AnimatedOpacity(
                          opacity: _hasMoreBelow ? 1.0 : 0.0,
                          duration: const Duration(milliseconds: 200),
                          child: Center(
                            child: GestureDetector(
                              onTap: () => scrollCtrl.animateTo(
                                scrollCtrl.position.maxScrollExtent,
                                duration:
                                    const Duration(milliseconds: 300),
                                curve: Curves.easeOut,
                              ),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 2),
                                decoration: BoxDecoration(
                                  color: cs.surfaceContainerHighest
                                      .withAlpha(220),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                      color: cs.outlineVariant
                                          .withAlpha(100)),
                                ),
                                child: Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                  size: 16,
                                  color:
                                      cs.onSurfaceVariant.withAlpha(180),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              const Spacer(),

            // ── STICKY BOTTOM: remaining indicator + CTA ─────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!_isNoChange && _remaining.abs() > 0.015) ...[
                    _buildRemainingIndicator(theme, cs),
                    const SizedBox(height: 6),
                  ],
                  FilledButton(
                    onPressed: (_canSubmit && !_saving) ? _submit : null,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    child: Text(_ctaLabel),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  // ── Section builders ──────────────────────────────────────────────────────

  /// Target card: current value → target input with inline delta indicator.
  Widget _buildTargetCard(ThemeData theme, ColorScheme cs) {
    final deltaColor = _isIncrease ? AppColors.gain : AppColors.loss;
    final deltaIcon = _isIncrease
        ? Icons.arrow_upward_rounded
        : Icons.arrow_downward_rounded;
    final subLabel = !_isNoChange &&
            _isIncrease &&
            _currentAlloc < -0.005
        ? 'covers ₹${compactAmount(_currentAlloc.abs())} deficit  +  ₹${compactAmount(_parsedTarget)} new allocation'
        : null;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Current allocation
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Current',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: cs.onSurfaceVariant)),
                  const SizedBox(height: 2),
                  Text(
                    '₹ ${_targetAlloc.amount}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: _currentAlloc < 0
                          ? Colors.red.shade700
                          : cs.onSurface,
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(
                    left: 14, right: 14, top: 14),
                child: Icon(Icons.east_rounded,
                    size: 16, color: cs.outlineVariant),
              ),
              // Set Target + inline delta
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Set Target',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: cs.onSurfaceVariant)),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _targetCtrl,
                            keyboardType:
                                const TextInputType.numberWithOptions(
                                    decimal: true, signed: false),
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                  RegExp(r'^\d*\.?\d{0,2}')),
                            ],
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                            decoration: InputDecoration(
                              isDense: true,
                              prefixText: '₹ ',
                              hintText: '0',
                              enabledBorder: _targetError != null &&
                                      _targetCtrl.text.isNotEmpty
                                  ? OutlineInputBorder(
                                      borderSide: BorderSide(
                                          color: cs.error, width: 1.5),
                                      borderRadius:
                                          BorderRadius.circular(8),
                                    )
                                  : null,
                              focusedBorder: _targetError != null &&
                                      _targetCtrl.text.isNotEmpty
                                  ? OutlineInputBorder(
                                      borderSide: BorderSide(
                                          color: cs.error, width: 2),
                                      borderRadius:
                                          BorderRadius.circular(8),
                                    )
                                  : null,
                              contentPadding:
                                  const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 7),
                            ),
                          ),
                        ),
                        if (!_isNoChange) ...[
                          const SizedBox(width: 10),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(deltaIcon,
                                  size: 13, color: deltaColor),
                              const SizedBox(width: 3),
                              Text(
                                '₹${compactAmount(_delta.abs())}',
                                style:
                                    theme.textTheme.bodySmall?.copyWith(
                                  color: deltaColor,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                    if (_targetError != null &&
                        _targetCtrl.text.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(_targetError!,
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: cs.error)),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (subLabel != null) ...[
            const SizedBox(height: 6),
            Text(
              subLabel,
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: deltaColor.withAlpha(170)),
            ),
          ],
        ],
      ),
    );
  }

  /// Single-line distribution row: [icon] Name  ₹Xk avail/current  [field]
  Widget _buildSourceRow({
    required ThemeData theme,
    required ColorScheme cs,
    required bool isIncrease,
    required String name,
    required double available,
    required TextEditingController ctrl,
    String? error,
    IconData? icon,
    bool disabled = false,
  }) {
    final availColor =
        available < 0 ? Colors.red.shade700 : cs.onSurfaceVariant;

    return Opacity(
      opacity: disabled ? 0.45 : 1.0,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Icon
                if (icon != null) ...[
                  Icon(icon, size: 14, color: cs.onSurfaceVariant),
                  const SizedBox(width: 5),
                ],
                // Name
                Expanded(
                  child: Text(name,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w500),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
                // Available amount
                Padding(
                  padding: const EdgeInsets.only(left: 8, right: 16),
                  child: Text(
                    '₹${compactAmount(available)}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: availColor),
                  ),
                ),
                // Deduct/Add field — disabled (greyed) when balance <= 0
                  SizedBox(
                  width: 110,
                  child: TextField(
                          enabled: !disabled,
                          controller: ctrl,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(
                                RegExp(r'^\d*\.?\d{0,2}')),
                          ],
                          textAlign: TextAlign.right,
                          style: theme.textTheme.bodyMedium,
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: '0',
                            prefixText: '₹ ',
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 7),
                            errorText: null,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide:
                                  BorderSide(color: cs.outlineVariant),
                            ),
                          ),
                        ),
                ),  // SizedBox
                const SizedBox(width: 4),
                Icon(
                  isIncrease
                      ? Icons.arrow_downward_rounded
                      : Icons.arrow_upward_rounded,
                  size: 13,
                  color: isIncrease
                      ? cs.onSurfaceVariant.withAlpha(160)
                      : AppColors.loss,
                ),
              ],
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 3, right: 2),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(error,
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: cs.error)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Only shown when the distribution is incomplete or over — the Allocate
  /// button being enabled already signals the "fully allocated" state.
  Widget _buildRemainingIndicator(ThemeData theme, ColorScheme cs) {
    final rem = _remaining;
    final isOver = rem < -0.015;
    final color = isOver ? cs.error : Colors.orange.shade700;
    final label = isOver
        ? 'Over by ₹${compactAmount(rem.abs())} — reduce amounts'
        : _isIncrease
            ? 'Still need ₹${compactAmount(rem)} more'
            : '₹${compactAmount(rem)} still to distribute';

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Icon(Icons.info_outline, size: 13, color: color),
        const SizedBox(width: 4),
        Text(label,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: color, fontWeight: FontWeight.w600)),
      ],
    );
  }

}
