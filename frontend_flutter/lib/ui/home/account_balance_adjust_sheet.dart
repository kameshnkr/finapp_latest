import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../core/snack_utils.dart';
import '../../data/models/models.dart';
import '../../state/app_controller.dart';
import '../../utils/amount_formatter.dart';

/// Guided balance adjustment sheet.
///
/// Opened from the Edit Account sheet "Adjust" button next to the balance.
/// For an increase the user distributes the new funds to budgets / unallocated.
/// For a decrease the user records which budgets / unallocated absorbed the cost.
class AccountBalanceAdjustSheet extends StatefulWidget {
  const AccountBalanceAdjustSheet({super.key, required this.account});

  final AccountDto account;

  @override
  State<AccountBalanceAdjustSheet> createState() =>
      _AccountBalanceAdjustSheetState();
}

class _AccountBalanceAdjustSheetState
    extends State<AccountBalanceAdjustSheet> {
  late final TextEditingController _balanceCtrl;
  late final TextEditingController _unallocCtrl;
  final Map<String, TextEditingController> _distCtrls = {};
  bool _saving = false;
  bool _unallocUserEdited = false;

  // ── Derived ───────────────────────────────────────────────────────────────

  double get _currentBalance =>
      double.tryParse(widget.account.totalBalance) ?? 0;

  double get _parsedBalance =>
      double.tryParse(_balanceCtrl.text.trim()) ?? _currentBalance;

  double get _delta =>
      double.parse((_parsedBalance - _currentBalance).toStringAsFixed(2));

  bool get _isNoChange => _delta.abs() < 0.005;
  bool get _isIncrease => _delta > 0.005;
  bool get _isDecrease => _delta < -0.005;

  double get _totalAllocated {
    double s = 0;
    for (final a in widget.account.allocations) {
      s += double.tryParse(a.amount) ?? 0;
    }
    return s;
  }

  double get _currentUnallocated => _currentBalance - _totalAllocated;

  double get _unallocAmt =>
      double.tryParse(_unallocCtrl.text.trim()) ?? 0;

  double get _budgetDistTotal {
    double s = 0;
    for (final c in _distCtrls.values) {
      s += double.tryParse(c.text.trim()) ?? 0;
    }
    return s;
  }

  double get _totalHandled => _unallocAmt + _budgetDistTotal;

  double get _remaining =>
      double.parse((_delta.abs() - _totalHandled).toStringAsFixed(2));

  // ── Validation ────────────────────────────────────────────────────────────

  String? get _balanceError {
    final t = _balanceCtrl.text.trim();
    if (t.isEmpty) return null;
    if (double.tryParse(t) == null) return 'Invalid amount';
    return null;
  }

  String? get _unallocError {
    if (_unallocAmt < 0) return 'Cannot be negative';
    return null;
  }

  String? _distError(String budgetId) {
    final ctrl = _distCtrls[budgetId];
    if (ctrl == null) return null;
    final v = double.tryParse(ctrl.text.trim()) ?? 0;
    if (v < 0) return 'Cannot be negative';
    // For decrease: can't deduct more than the budget's positive allocation
    if (_isDecrease) {
      final alloc = double.tryParse(
              widget.account.allocations
                  .firstWhere((a) => a.budgetId == budgetId,
                      orElse: () => AllocationDto(
                          budgetId: budgetId, budgetName: '', amount: '0'))
                  .amount) ??
          0;
      if (v > max(0, alloc) + 0.005) {
        return 'Only ₹${compactAmount(max(0, alloc))} available';
      }
    }
    return null;
  }

  bool get _canSubmit {
    if (_isNoChange) return false;
    if (_balanceError != null) return false;
    if (_remaining.abs() > 0.015) return false;
    if (_unallocError != null) return false;
    for (final a in widget.account.allocations) {
      if (_distError(a.budgetId) != null) return false;
    }
    return true;
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _balanceCtrl =
        TextEditingController(text: _formatAmt(_currentBalance));
    _unallocCtrl = TextEditingController(text: '0');

    for (final a in widget.account.allocations) {
      _distCtrls[a.budgetId] = TextEditingController(text: '0')
        ..addListener(_onDistChanged);
    }

    _balanceCtrl.addListener(_onBalanceChanged);
    _unallocCtrl.addListener(_onUnallocUserChanged);
  }

  @override
  void dispose() {
    _balanceCtrl.dispose();
    _unallocCtrl.dispose();
    for (final c in _distCtrls.values) c.dispose();
    super.dispose();
  }

  // ── Callbacks ─────────────────────────────────────────────────────────────

  void _onBalanceChanged() {
    if (!mounted) return;
    if (!_unallocUserEdited) {
      if (_isIncrease) {
        // All new funds default to unallocated
        _setUnallocSilently(_formatAmt(_delta));
      } else if (_isDecrease) {
        // Default: deduct from unallocated first, up to available
        final autoFill =
            min(_currentUnallocated > 0.005 ? _currentUnallocated : 0.0,
                    _delta.abs())
                .clamp(0.0, _delta.abs());
        _setUnallocSilently(_formatAmt(autoFill));
      } else {
        _setUnallocSilently('0');
      }
    }
    if (_isNoChange) {
      _unallocUserEdited = false;
      _setUnallocSilently('0');
      for (final c in _distCtrls.values) _setDistSilently(c, '0');
    }
    setState(() {});
  }

  void _onUnallocUserChanged() {
    _unallocUserEdited = true;
    if (mounted) setState(() {});
  }

  void _onDistChanged() {
    if (mounted) setState(() {});
  }

  void _setUnallocSilently(String value) {
    if (_unallocCtrl.text == value) return;
    _unallocCtrl.removeListener(_onUnallocUserChanged);
    _unallocCtrl.text = value;
    _unallocCtrl.addListener(_onUnallocUserChanged);
  }

  void _setDistSilently(TextEditingController ctrl, String value) {
    if (ctrl.text == value) return;
    ctrl.removeListener(_onDistChanged);
    ctrl.text = value;
    ctrl.addListener(_onDistChanged);
  }

  void _reset() {
    _unallocUserEdited = false;
    _setUnallocSilently('0');
    for (final c in _distCtrls.values) _setDistSilently(c, '0');
    final initial = _formatAmt(_currentBalance);
    if (_balanceCtrl.text != initial) _balanceCtrl.text = initial;
    setState(() {});
  }

  // ── Submit ────────────────────────────────────────────────────────────────

  Future<void> _submit() async {
    if (!_canSubmit) return;
    final app = context.read<AppController>();

    final dists = <Map<String, String>>[];
    for (final a in widget.account.allocations) {
      final v =
          double.tryParse(_distCtrls[a.budgetId]!.text.trim()) ?? 0;
      if (v > 0.005) {
        dists.add({'budgetId': a.budgetId, 'amount': v.toStringAsFixed(2)});
      }
    }

    setState(() => _saving = true);
    try {
      await app.api.adjustBalance(
        widget.account.id,
        newBalance: _parsedBalance.toStringAsFixed(2),
        unallocatedAmount: _unallocAmt.toStringAsFixed(2),
        distributions: dists,
        version: widget.account.version,
      );
      await app.refreshAccountsBudgets();
      if (!mounted) return;
      Navigator.of(context).pop();
      showTopSnack(context, 'Balance updated');
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

  String get _ctaLabel {
    if (_isNoChange) return 'No Change';
    if (_isIncrease) {
      final toBudgets = _budgetDistTotal;
      if (toBudgets > 0.005 && _unallocAmt > 0.005) {
        return 'Confirm +₹${compactAmount(_delta)}';
      }
      if (toBudgets > 0.005) return 'Distribute +₹${compactAmount(_delta)}';
      return 'Add ₹${compactAmount(_delta)} → Unallocated';
    }
    if (_budgetDistTotal > 0.005) {
      return 'Deduct ₹${compactAmount(_delta.abs())} from budgets';
    }
    return 'Deduct ₹${compactAmount(_delta.abs())} from Unallocated';
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
      maxChildSize: 0.95,
      builder: (context, scrollCtrl) {
        return Column(
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
              padding: const EdgeInsets.fromLTRB(20, 0, 12, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Adjust Balance',
                            style: theme.textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(widget.account.name,
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(color: cs.primary)),
                      ],
                    ),
                  ),
                  TextButton(onPressed: _reset, child: const Text('Reset')),
                  TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel')),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Divider(height: 1, color: cs.outlineVariant),

            // ── STICKY TOP: balance card + section label ─────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildBalanceCard(theme, cs),
                  if (!_isNoChange) ...[
                    const SizedBox(height: 16),
                    Text(
                      _isIncrease ? 'DISTRIBUTE TO' : 'DEDUCT FROM',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: cs.primary,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.0,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        const Spacer(),
                        Text(
                          _isIncrease ? 'Current' : 'Available',
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: cs.onSurfaceVariant),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 110,
                          child: Text(
                            _isIncrease ? 'Add' : 'Deduct',
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: cs.onSurfaceVariant),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                  ],
                ],
              ),
            ),

            // ── SCROLLABLE distribution list ─────────────────────────────
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
                        child: ListView(
                          controller: scrollCtrl,
                          padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
                          children: [
                            // Unallocated row
                            _buildDistRow(
                              theme: theme,
                              cs: cs,
                              isIncrease: _isIncrease,
                              name: 'Unallocated',
                              icon: Icons.account_balance_wallet_outlined,
                              available: _currentUnallocated,
                              ctrl: _unallocCtrl,
                              error: _unallocError,
                              disabled: _isDecrease &&
                                  _currentUnallocated <= 0,
                            ),
                            // Budget rows
                            ...widget.account.allocations.map((a) {
                              final rawAlloc =
                                  double.tryParse(a.amount) ?? 0;
                              final disabled =
                                  _isDecrease && rawAlloc <= 0;
                              return _buildDistRow(
                                theme: theme,
                                cs: cs,
                                isIncrease: _isIncrease,
                                name: a.budgetName,
                                available: rawAlloc,
                                ctrl: _distCtrls[a.budgetId]!,
                                error: disabled
                                    ? null
                                    : _distError(a.budgetId),
                                disabled: disabled,
                              );
                            }),
                          ],
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
                    ],
                  ),
                ),
              )
            else
              const Spacer(),

            // ── STICKY BOTTOM: remaining + CTA ───────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!_isNoChange && _remaining.abs() > 0.015) ...[
                    _buildRemainingIndicator(theme, cs),
                    const SizedBox(height: 8),
                  ],
                  FilledButton(
                    onPressed: (_canSubmit && !_saving) ? _submit : null,
                    style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52)),
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

  Widget _buildBalanceCard(ThemeData theme, ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Current balance
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Current',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: cs.onSurfaceVariant)),
                  const SizedBox(height: 4),
                  Text(
                    '₹ ${widget.account.totalBalance}',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Icon(Icons.east_rounded,
                    size: 16, color: cs.outlineVariant),
              ),
              // New balance input
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Set New Balance',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: cs.onSurfaceVariant)),
                    const SizedBox(height: 4),
                    TextField(
                      controller: _balanceCtrl,
                      autofocus: true,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true, signed: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                            RegExp(r'^-?\d*\.?\d{0,2}')),
                      ],
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                      decoration: InputDecoration(
                        isDense: true,
                        prefixText: '₹ ',
                        hintText: '0',
                        enabledBorder:
                            _balanceError != null &&
                                    _balanceCtrl.text.isNotEmpty
                                ? OutlineInputBorder(
                                    borderSide: BorderSide(
                                        color: cs.error, width: 1.5),
                                    borderRadius: BorderRadius.circular(8),
                                  )
                                : null,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 8),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_balanceError != null && _balanceCtrl.text.isNotEmpty) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: Text(_balanceError!,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: cs.error)),
            ),
          ],
          if (!_isNoChange) ...[
            const SizedBox(height: 16),
            _buildDeltaBanner(theme, cs),
          ],
        ],
      ),
    );
  }

  Widget _buildDeltaBanner(ThemeData theme, ColorScheme cs) {
    final color =
        _isIncrease ? AppColors.gain : AppColors.loss;
    final icon = _isIncrease
        ? Icons.arrow_upward_rounded
        : Icons.arrow_downward_rounded;
    final label = _isIncrease ? 'balance increase' : 'balance decrease';
    final amount = '₹${compactAmount(_delta.abs())}';

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 5),
        Text('$label  $amount',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: color, fontWeight: FontWeight.w700)),
      ],
    );
  }

  Widget _buildDistRow({
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
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 14, color: cs.onSurfaceVariant),
                  const SizedBox(width: 5),
                ],
                Expanded(
                  child: Text(name,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w500),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 8, right: 16),
                  child: Text('₹${compactAmount(available)}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: availColor)),
                ),
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
                          horizontal: 10, vertical: 9),
                      errorText: null,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            BorderSide(color: cs.outlineVariant),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  isIncrease
                      ? Icons.arrow_upward_rounded
                      : Icons.arrow_downward_rounded,
                  size: 13,
                  color: isIncrease
                      ? AppColors.gain
                      : cs.onSurfaceVariant.withAlpha(160),
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

  Widget _buildRemainingIndicator(ThemeData theme, ColorScheme cs) {
    final rem = _remaining;
    final isOver = rem < -0.015;
    final color = isOver ? cs.error : Colors.orange.shade700;
    final label = isOver
        ? 'Over by ₹${compactAmount(rem.abs())} — reduce amounts'
        : _isIncrease
            ? '₹${compactAmount(rem)} still to distribute'
            : 'Still need ₹${compactAmount(rem)} more from budgets';

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

void showAccountBalanceAdjustSheet(
    BuildContext context, AccountDto account) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => AccountBalanceAdjustSheet(account: account),
  );
}
