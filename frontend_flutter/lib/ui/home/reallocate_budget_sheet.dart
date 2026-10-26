import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/snack_utils.dart';
import '../../data/models/models.dart';
import '../../state/app_controller.dart';
import '../../utils/amount_formatter.dart';
import '../../utils/api_error_utils.dart';
import '../widgets/expandable_name_text.dart';

double _round2(double v) => (v * 100).round() / 100;

typedef _Movement = ({
  String accountId,
  String fromBudgetId,
  String toBudgetId,
  String amount,
});

/// Three ways to move money between exactly two Budgets — ported verbatim
/// from the Investments Pot "Transfer" flow's [_Mode]
/// (`reallocate_pot_sheet.dart`). Budget ≈ Pot here.
///
/// - [send]: move an amount OUT of this Budget, into another Budget.
/// - [receive]: pull an amount IN to this Budget, from another Budget.
/// - [adjustTo]: declare what this Budget's final funds-available should
///   be; the app works out whether that means sending the excess away or
///   receiving the shortfall from the other Budget you pick.
enum _Mode { send, receive, adjustTo }

extension on _Mode {
  String get label => switch (this) {
    _Mode.send => 'Send',
    _Mode.receive => 'Receive',
    _Mode.adjustTo => 'Adjust To',
  };

  IconData get icon => switch (this) {
    _Mode.send => Icons.call_made_rounded,
    _Mode.receive => Icons.call_received_rounded,
    _Mode.adjustTo => Icons.tune_rounded,
  };
}

/// Budget "Reallocate Funds" flow — a full-screen page between exactly this
/// Budget and one other Budget the user picks, letting them choose which
/// underlying Accounts fund the move (rather than the existing per-account
/// Accounts-tab flow, which requires picking an account FIRST). Direct port
/// of `reallocate_pot_sheet.dart`'s structure — Budget ≈ Pot, Account ≈
/// account-asset. See
/// backend/logics/banking_logics/banking_budget_funds_reallocation.log.
///
/// Flow: pick Send / Receive / Adjust To, enter an amount (or target
/// funds-available), pick the single other Budget involved, then (step 2)
/// fine-tune exactly which underlying Accounts fund that amount — defaults
/// to a proportional-to-current-weight split so most users never need to
/// touch it.
///
/// Pushed as a full-screen route (not a bottom sheet), deliberately NOT
/// `fullscreenDialog: true` — see the doc-comment on
/// `showReallocatePotSheet` for why that flag must stay off.
///
/// Deliberately independent of [AppController.api]'s existing
/// `reallocateAllocation` (the per-account Accounts-tab flow powering
/// `BudgetReallocationSheet`) — that flow, and the "Unallocated" bucket it
/// exposes, are never touched by this one.
Future<void> showReallocateBudgetSheet(
  BuildContext context, {
  required String budgetId,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => ReallocateBudgetSheet(budgetId: budgetId),
    ),
  );
}

class ReallocateBudgetSheet extends StatefulWidget {
  const ReallocateBudgetSheet({super.key, required this.budgetId});

  /// The Budget whose "Reallocate Funds" button was tapped — always shown
  /// in the header, and always one side of the move (the other side is
  /// whichever Budget the user picks below).
  final String budgetId;

  @override
  State<ReallocateBudgetSheet> createState() => _ReallocateBudgetSheetState();
}

class _AllocationRow {
  _AllocationRow({
    required this.accountId,
    required this.accountName,
    required this.available,
    required this.ctrl,
  });

  final String accountId;
  final String accountName;

  /// This account's current allocated amount (₹) to the GIVER Budget —
  /// plain rupees, no unit/price conversion needed (unlike Investments'
  /// units-based positions).
  final double available;
  final TextEditingController ctrl;
}

class _ReallocateBudgetSheetState extends State<ReallocateBudgetSheet> {
  /// Shared height for the amount/target field and the other-Budget field
  /// beside it, so the two line up exactly despite one being a real
  /// `TextField` and the other a custom tappable row.
  static const double _fieldHeight = 44;

  /// Shared width for the "Available" column (both its header label and
  /// every row's value) in Step 2's account breakdown — keeping this one
  /// constant in sync between the header and `_buildAccountRow` is what
  /// keeps "Available"/"Transfer" centered directly above their actual
  /// columns instead of drifting out of alignment.
  static const double _availableColWidth = 64;

  bool _loading = true;
  String? _loadError;
  BankingReallocationDataDto? _data;

  _Mode _mode = _Mode.send;
  final TextEditingController _amountCtrl = TextEditingController();
  final List<_AllocationRow> _allocRows = [];
  String? _otherBudgetId;
  bool _saving = false;

  /// Scrolls the Step 2 account-breakdown list.
  final ScrollController _scrollCtrl = ScrollController();

  /// Scrolls Step 1's mode/amount card + preview column — keeps the
  /// "Transferring ₹X from A to B" preview pulled into view above the
  /// keyboard (see [_revealStep1Preview]).
  final ScrollController _step1ScrollCtrl = ScrollController();

  /// 1 = pick mode/amount/other Budget (no account breakdown visible yet).
  /// 2 = the account breakdown, full-height.
  int _step = 1;
  bool _hasMoreBelow = false;
  bool _hasMoreAbove = false;

  /// Tracks which Budget the account breakdown was last built from, so we
  /// only rebuild it (and reset any manual edits) when the "giver" Budget
  /// actually changes.
  String? _lastGiverBudgetId;

  /// True once the user has manually typed in ANY account-breakdown field —
  /// auto-fill (proportional split of the move amount across the giver
  /// Budget's own allocations) only runs while this is false.
  bool _allocsUserEdited = false;

  /// Account names (keyed by `accountId`) currently shown fully
  /// (untruncated) instead of ellipsis-clipped — tapping a row's name
  /// toggles its membership here, same pattern as Investments' asset rows.
  final Set<String> _expandedAccountIds = {};
  bool _giverBudgetNameExpanded = false;

  @override
  void initState() {
    super.initState();
    _amountCtrl.addListener(_onAmountChanged);
    _load();
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _scrollCtrl.dispose();
    _step1ScrollCtrl.dispose();
    for (final r in _allocRows) {
      r.ctrl.dispose();
    }
    super.dispose();
  }

  /// Scrolls Step 1 so its bottom-most content (the preview card, once
  /// shown — the placeholder text otherwise) is fully visible above the
  /// keyboard. See `reallocate_pot_sheet.dart`'s identical helper for the
  /// full rationale on jump-vs-animate.
  void _revealStep1Preview({bool animate = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_step1ScrollCtrl.hasClients) return;
      final target = _step1ScrollCtrl.position.maxScrollExtent;
      if (animate) {
        _step1ScrollCtrl.animateTo(
          target,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      } else {
        _step1ScrollCtrl.jumpTo(target);
      }
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final app = context.read<AppController>();
      final data = await app.api.fetchBankingReallocationData();
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
      });
      // Default mode is Send, whose giver is always this Budget itself —
      // build the initial breakdown right away so it's ready the moment an
      // amount is entered.
      _syncAllocRowsForGiver();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.toString();
        _loading = false;
      });
    }
  }

  // ── Derived from loaded data ─────────────────────────────────────────────

  BankingReallocationBudgetDto? _findBudget(String id) {
    for (final b in _data?.budgets ?? const <BankingReallocationBudgetDto>[]) {
      if (b.id == id) return b;
    }
    return null;
  }

  /// This Budget — the one whose "Reallocate Funds" button opened this
  /// sheet. Always one side of the move; which side depends on [_mode]
  /// (and, for Adjust To, the computed direction).
  BankingReallocationBudgetDto? get _sourceBudget =>
      _findBudget(widget.budgetId);

  BankingReallocationBudgetDto? get _otherBudget =>
      _otherBudgetId != null ? _findBudget(_otherBudgetId!) : null;

  /// Every other real Budget — never includes an "Unallocated" pseudo-
  /// option (unlike the existing per-account flow), per the confirmed
  /// design: this flow only ever moves funds between actual Budgets.
  List<BankingReallocationBudgetDto> get _otherBudgets =>
      (_data?.budgets ?? const <BankingReallocationBudgetDto>[])
          .where((b) => b.id != widget.budgetId)
          .toList();

  double _budgetValue(BankingReallocationBudgetDto b) =>
      double.tryParse(b.fundsAvailable) ?? 0;

  double get _sourceValue =>
      _sourceBudget != null ? _budgetValue(_sourceBudget!) : 0;

  // ── Direction (who's giving, who's receiving) ────────────────────────────

  /// Raw text typed into the single primary field — interpreted as "amount
  /// to move" (Send/Receive) or "desired final funds-available for this
  /// Budget" (Adjust To).
  double get _rawInput => double.tryParse(_amountCtrl.text.trim()) ?? 0;

  /// true: this Budget is giving money away. false: this Budget is
  /// receiving. null: direction not yet known.
  bool? get _selfIsGiver {
    switch (_mode) {
      case _Mode.send:
        return true;
      case _Mode.receive:
        return false;
      case _Mode.adjustTo:
        if (_amountCtrl.text.trim().isEmpty) return null;
        final delta = _round2(_rawInput - _sourceValue);
        if (delta.abs() <= 0.005) return null;
        return delta < 0;
    }
  }

  /// The Budget actually funding this move — whichever side ends up
  /// smaller. Its allocations are what the account breakdown is built from.
  BankingReallocationBudgetDto? get _giverBudget {
    final isGiver = _selfIsGiver;
    if (isGiver == null) return null;
    return isGiver ? _sourceBudget : _otherBudget;
  }

  /// The Budget on the other end of [_giverBudget] — whichever side ends
  /// up bigger. Used for the Step 1 "after transfer" preview and Step 2's
  /// headline; the breakdown itself never touches this Budget's
  /// allocations.
  BankingReallocationBudgetDto? get _receiverBudget {
    final isGiver = _selfIsGiver;
    if (isGiver == null) return null;
    return isGiver ? _otherBudget : _sourceBudget;
  }

  // ── Live calculations ────────────────────────────────────────────────────

  /// The actual amount being moved, regardless of mode.
  double get _amount {
    switch (_mode) {
      case _Mode.send:
      case _Mode.receive:
        return _rawInput;
      case _Mode.adjustTo:
        if (_selfIsGiver == null) return 0;
        return (_rawInput - _sourceValue).abs();
    }
  }

  double get _allocSum => _allocRows.fold(
    0.0,
    (s, r) => s + (double.tryParse(r.ctrl.text.trim()) ?? 0),
  );

  double get _remaining => _round2(_amount - _allocSum);

  // ── Validation ────────────────────────────────────────────────────────────

  /// Error for the single primary field (amount or target), whichever is
  /// showing for the current mode.
  String? get _primaryFieldError {
    if (_amountCtrl.text.trim().isEmpty) return null;
    if (_rawInput < 0) return 'Amount cannot be negative';
    switch (_mode) {
      case _Mode.send:
        if (_rawInput > _sourceValue + 0.005) {
          return 'Only ₹${compactAmount(_sourceValue)} available';
        }
        return null;
      case _Mode.receive:
        final cap = _otherBudget != null ? _budgetValue(_otherBudget!) : null;
        if (cap != null && _rawInput > cap + 0.005) {
          return 'Only ₹${compactAmount(cap)} available in that Budget';
        }
        return null;
      case _Mode.adjustTo:
        if (_selfIsGiver == false) {
          final cap = _otherBudget != null ? _budgetValue(_otherBudget!) : null;
          if (cap != null && _amount > cap + 0.005) {
            return 'That Budget only has ₹${compactAmount(cap)} available';
          }
        }
        return null;
    }
  }

  String? _allocError(_AllocationRow row) {
    final v = double.tryParse(row.ctrl.text.trim()) ?? 0;
    if (v < 0) return 'Cannot be negative';
    if (v > row.available + 0.005) {
      return 'Only ₹${compactAmount(row.available)} available';
    }
    return null;
  }

  bool get _canSubmit {
    if (_data == null || _loading || _saving) return false;
    if (_otherBudgetId == null) return false;
    if (_selfIsGiver == null) return false;
    if (_amount <= 0.005) return false;
    if (_primaryFieldError != null) return false;
    if (_allocRows.isEmpty) return false;
    if (_remaining.abs() > 0.015) return false;
    for (final r in _allocRows) {
      if (_allocError(r) != null) return false;
    }
    return true;
  }

  /// Gates Step 1's "Next" button — everything needed to KNOW the move
  /// (mode, amount/target, other Budget) must be valid; the actual
  /// per-account breakdown is only reachable on Step 2.
  bool get _canProceedToStep2 => _showBreakdown && _primaryFieldError == null;

  // ── Callbacks ─────────────────────────────────────────────────────────────

  void _onModeChanged(_Mode mode) {
    if (mode == _mode) return;
    setState(() {
      _mode = mode;
      _otherBudgetId = null;
      if (_amountCtrl.text.isNotEmpty) {
        _amountCtrl.value = const TextEditingValue(
          text: '',
          selection: TextSelection.collapsed(offset: 0),
        );
      }
      _syncAllocRowsForGiver();
    });
  }

  void _onAmountChanged() {
    if (!mounted) return;
    _syncAllocRowsForGiver();
    if (_amount <= 0.005) {
      _allocsUserEdited = false;
      for (final r in _allocRows) {
        _setAllocSilently(r.ctrl, '');
      }
    } else if (!_allocsUserEdited) {
      _autoFillAllocationsProportionally();
    }
    setState(() {});
    _revealStep1Preview();
  }

  /// Called whenever the user physically types in ANY account field —
  /// freezes auto-fill for the rest of this session.
  void _onAllocChanged() {
    _allocsUserEdited = true;
    if (mounted) setState(() {});
  }

  /// Rebuilds [_allocRows] from [_giverBudget]'s own allocations whenever
  /// the giver actually changes (mode switch, other-Budget pick, or an
  /// Adjust To target flipping direction). A no-op if the giver hasn't
  /// changed, so in-progress manual edits survive unrelated rebuilds.
  void _syncAllocRowsForGiver() {
    final giver = _giverBudget;
    final giverId = giver?.id;
    if (giverId == _lastGiverBudgetId) return;
    _lastGiverBudgetId = giverId;
    for (final r in _allocRows) {
      r.ctrl.dispose();
    }
    _allocRows.clear();
    _allocsUserEdited = false;
    if (giver == null) return;
    for (final a in giver.allocations) {
      final v = double.tryParse(a.amount) ?? 0;
      if (v <= 0.001) continue;
      final ctrl = TextEditingController();
      ctrl.addListener(_onAllocChanged);
      _allocRows.add(
        _AllocationRow(
          accountId: a.accountId,
          accountName: a.accountName,
          available: v,
          ctrl: ctrl,
        ),
      );
    }
  }

  void _autoFillAllocationsProportionally() {
    final total = _allocRows.fold(0.0, (s, r) => s + r.available);
    if (total <= 0) return;
    final amt = _amount;
    double allocated = 0;
    for (var i = 0; i < _allocRows.length; i++) {
      final r = _allocRows[i];
      final share = i == _allocRows.length - 1
          ? max(0.0, _round2(amt - allocated))
          : _round2(amt * (r.available / total));
      allocated += share;
      _setAllocSilently(r.ctrl, _ctrlValue(share));
    }
  }

  /// Programmatically sets a field's text without marking it as user-edited
  /// (so auto-fill can keep updating it) and with an explicit, valid
  /// cursor position.
  void _setAllocSilently(TextEditingController ctrl, String value) {
    if (ctrl.text == value) return;
    ctrl.removeListener(_onAllocChanged);
    ctrl.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    ctrl.addListener(_onAllocChanged);
  }

  void _reset() {
    _mode = _Mode.send;
    _allocsUserEdited = false;
    _otherBudgetId = null;
    _step = 1;
    if (_amountCtrl.text.isNotEmpty) {
      _amountCtrl.value = const TextEditingValue(
        text: '',
        selection: TextSelection.collapsed(offset: 0),
      );
    }
    _lastGiverBudgetId = null;
    _syncAllocRowsForGiver();
    setState(() {});
  }

  /// Step 1 -> Step 2. Nothing about the already-entered mode/amount/other
  /// Budget (or any manual allocation edits made on a previous visit to
  /// Step 2) is touched — this is a pure view switch within the same
  /// state.
  void _goToStep2() {
    if (!_canProceedToStep2) return;
    setState(() => _step = 2);
  }

  /// Step 2 -> Step 1, to tweak the amount/mode/other Budget. Preserves
  /// everything (including any manual per-account edits) so returning to
  /// Step 2 picks up right where it left off.
  void _goBackToStep1() {
    setState(() => _step = 1);
  }

  // ── Movement plan + submit ──────────────────────────────────────────────

  List<_Movement> _buildMovements() {
    final movements = <_Movement>[];
    final other = _otherBudgetId;
    final isGiver = _selfIsGiver;
    if (other == null || isGiver == null) return movements;
    final fromId = isGiver ? widget.budgetId : other;
    final toId = isGiver ? other : widget.budgetId;
    for (final r in _allocRows) {
      final v = double.tryParse(r.ctrl.text.trim()) ?? 0;
      if (v <= 0.001) continue;
      // Plain rupees, no unit/price conversion needed (unlike Investments)
      // — just clamp against the true available amount as a safety net in
      // case of float drift.
      final amount = min(_round2(v), r.available);
      if (amount <= 0) continue;
      movements.add((
        accountId: r.accountId,
        fromBudgetId: fromId,
        toBudgetId: toId,
        amount: amount.toStringAsFixed(2),
      ));
    }
    return movements;
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    final movements = _buildMovements();
    if (movements.isEmpty) {
      showTopSnack(context, 'Nothing to move.');
      return;
    }
    final app = context.read<AppController>();
    setState(() => _saving = true);
    try {
      await app.api.executeBankingReallocation(movements: movements);
      await app.refreshAccountsBudgets();
      if (!mounted) return;
      Navigator.of(context).pop();
      showTopSnack(context, 'Budget allocation updated');
    } catch (e) {
      if (!mounted) return;
      showTopSnack(context, 'Error: ${friendlyApiError(e)}');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _formatAmt(double v) =>
      v == v.truncateToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  /// Returns empty string for zero so fields show the hint placeholder.
  String _ctrlValue(double v) => v.abs() < 0.005 ? '' : _formatAmt(v);

  /// Always "Reallocate" — matches the "Reallocate Funds" affordance that
  /// opened this sheet. Only its enabled state + the trailing amount
  /// change as the form fills in.
  String get _ctaLabel {
    if (_otherBudgetId == null || _amount <= 0.005) return 'Reallocate';
    return 'Reallocate ₹${compactAmount(_amount)}';
  }

  String get _primaryFieldLabel =>
      _mode == _Mode.adjustTo ? 'Target Amount' : 'Amount';

  String get _otherBudgetFieldLabel {
    switch (_mode) {
      case _Mode.send:
        return 'To Budget';
      case _Mode.receive:
        return 'From Budget';
      case _Mode.adjustTo:
        final isGiver = _selfIsGiver;
        if (isGiver == true) return 'To Budget';
        if (isGiver == false) return 'From Budget';
        return 'Other Budget';
    }
  }

  IconData get _arrowIcon {
    switch (_mode) {
      case _Mode.send:
        return Icons.east_rounded;
      case _Mode.receive:
        return Icons.west_rounded;
      case _Mode.adjustTo:
        final isGiver = _selfIsGiver;
        if (isGiver == true) return Icons.east_rounded;
        if (isGiver == false) return Icons.west_rounded;
        return Icons.sync_alt_rounded;
    }
  }

  bool get _otherBudgetFieldEnabled {
    switch (_mode) {
      case _Mode.send:
      case _Mode.receive:
        return _rawInput > 0.005;
      case _Mode.adjustTo:
        return _amountCtrl.text.trim().isNotEmpty;
    }
  }

  /// Small note shown under the target field in Adjust To mode only,
  /// translating the typed target into the plain-English Send/Receive it
  /// actually amounts to — amount bolded, same treatment as every other
  /// info-note amount in this sheet.
  Widget? _buildAdjustToNote(ThemeData theme, ColorScheme cs) {
    if (_mode != _Mode.adjustTo) return null;
    if (_amountCtrl.text.trim().isEmpty) return null;
    final baseStyle = theme.textTheme.labelSmall?.copyWith(
      color: cs.onSurfaceVariant,
    );
    final isGiver = _selfIsGiver;
    if (isGiver == null) {
      return Text('This Budget is already at this amount.', style: baseStyle);
    }
    final amountStyle = baseStyle?.copyWith(
      color: cs.onSurface,
      fontWeight: FontWeight.w800,
    );
    return Text.rich(
      TextSpan(
        style: baseStyle,
        children: [
          TextSpan(text: isGiver ? 'Send ' : 'Receive '),
          TextSpan(text: '₹${compactAmount(_amount)} ', style: amountStyle),
          TextSpan(text: isGiver ? 'to another Budget' : 'from another Budget'),
        ],
      ),
    );
  }

  bool get _showBreakdown => _otherBudgetId != null && _giverBudget != null;

  String get _placeholderMessage {
    if (_amountCtrl.text.trim().isEmpty) {
      return _mode == _Mode.adjustTo
          ? 'Enter a target amount for this Budget.'
          : 'Enter an amount to transfer.';
    }
    if (_mode == _Mode.adjustTo && _selfIsGiver == null) {
      return 'This Budget is already at that amount.';
    }
    switch (_mode) {
      case _Mode.send:
        return 'Select a Budget to transfer to.';
      case _Mode.receive:
        return 'Select a Budget to transfer from.';
      case _Mode.adjustTo:
        return _selfIsGiver == true
            ? 'Select a Budget to send the extra amount to.'
            : 'Select a Budget to receive the amount from.';
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: (_loading || _loadError != null)
            ? _buildLoadingOrError(cs)
            : Column(
                children: [
                  if (_saving)
                    LinearProgressIndicator(minHeight: 3, color: cs.primary)
                  else
                    const SizedBox(height: 3),
                  const SizedBox(height: 10),

                  // ── Title row ────────────────────────────────────────
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      _step == 2 ? 10 : 20,
                      0,
                      12,
                      0,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        if (_step == 2) ...[
                          IconButton(
                            onPressed: _goBackToStep1,
                            icon: const Icon(Icons.arrow_back_rounded),
                            tooltip: 'Back',
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 32,
                              minHeight: 32,
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        Expanded(
                          child: Text(
                            'Reallocate Funds',
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        TextButton(
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: _reset,
                          child: const Text('Reset'),
                        ),
                        TextButton(
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.only(left: 8),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Cancel'),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 2, 20, 0),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Icon(
                            Icons.account_balance_wallet_outlined,
                            size: 14,
                            color: cs.primary,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            '${_sourceBudget?.name ?? ''} · ₹${_formatAmt(_sourceValue)}',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: cs.primary,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  Divider(height: 1, color: cs.outlineVariant),

                  // ── Step-dependent body ─────────────────────────────────
                  Expanded(
                    child: _step == 1
                        ? _buildStep1Body(theme, cs)
                        : _buildStep2Body(theme, cs, _scrollCtrl),
                  ),

                  // ── STICKY BOTTOM: Next (Step 1) or remaining +
                  // Reallocate (Step 2) ───────────────────────────────────
                  _buildBottomBar(theme, cs),
                ],
              ),
      ),
    );
  }

  // ── Section builders ──────────────────────────────────────────────────────

  Widget _buildLoadingOrError(ColorScheme cs) {
    return Column(
      children: [
        Expanded(
          child: Center(
            child: _loadError != null
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Error: $_loadError', textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: _load,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  )
                : const CircularProgressIndicator(),
          ),
        ),
      ],
    );
  }

  /// Mode selector (Send / Receive / Adjust To) plus the "[Amount or
  /// Target] [→ or ←] [Other Budget]" row.
  Widget _buildSourceAndTransferCard(ThemeData theme, ColorScheme cs) {
    final adjustToNote = _buildAdjustToNote(theme, cs);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<_Mode>(
              segments: _Mode.values
                  .map(
                    (m) => ButtonSegment(
                      value: m,
                      icon: Icon(m.icon, size: 14),
                      label: Text(m.label),
                    ),
                  )
                  .toList(),
              selected: {_mode},
              showSelectedIcon: false,
              style: SegmentedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                textStyle: const TextStyle(fontSize: 12),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                side: BorderSide(color: cs.outlineVariant.withAlpha(110)),
                selectedBackgroundColor: cs.primary,
                selectedForegroundColor: cs.onPrimary,
              ),
              onSelectionChanged: (sel) => _onModeChanged(sel.first),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _primaryFieldLabel,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 2),
                    SizedBox(
                      height: _fieldHeight,
                      child: TextField(
                        controller: _amountCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                          signed: false,
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                            RegExp(r'^\d*\.?\d{0,2}'),
                          ),
                        ],
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          prefixText: '₹ ',
                          hintText: '0',
                          enabledBorder: _primaryFieldError != null
                              ? OutlineInputBorder(
                                  borderSide: BorderSide(
                                    color: cs.error,
                                    width: 1.5,
                                  ),
                                  borderRadius: BorderRadius.circular(8),
                                )
                              : null,
                          focusedBorder: _primaryFieldError != null
                              ? OutlineInputBorder(
                                  borderSide: BorderSide(
                                    color: cs.error,
                                    width: 2,
                                  ),
                                  borderRadius: BorderRadius.circular(8),
                                )
                              : null,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 10,
                          ),
                        ),
                      ),
                    ),
                    if (_primaryFieldError != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        _primaryFieldError!,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: cs.error,
                        ),
                      ),
                    ] else if (adjustToNote != null) ...[
                      const SizedBox(height: 3),
                      adjustToNote,
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(top: 32),
                child: Icon(
                  _arrowIcon,
                  size: 16,
                  color: _otherBudgetFieldEnabled
                      ? cs.primary
                      : cs.outlineVariant,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _otherBudgetFieldLabel,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 2),
                    _buildOtherBudgetField(theme, cs),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Tappable field styled to match the amount `TextField` beside it,
  /// opening a polished bottom-sheet picker. Disabled (muted, inert) until
  /// an amount (or, in Adjust To, a target) has been entered.
  Widget _buildOtherBudgetField(ThemeData theme, ColorScheme cs) {
    final enabled = _otherBudgetFieldEnabled;
    final selected = _otherBudget;
    final emptyAndEnabled = enabled && selected == null;
    return InkWell(
      onTap: enabled ? _pickOtherBudget : null,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: _fieldHeight,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: !enabled
              ? cs.surfaceContainerHighest.withAlpha(90)
              : (emptyAndEnabled ? cs.primary.withAlpha(14) : Colors.white),
          border: Border.all(
            color: !enabled
                ? cs.outlineVariant
                : (emptyAndEnabled ? cs.primary : cs.outline),
            width: emptyAndEnabled ? 1.5 : 1,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            if (selected != null) ...[
              Icon(
                Icons.account_balance_wallet_outlined,
                size: 14,
                color: cs.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text(
                selected?.name ?? 'Select',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: selected != null
                      ? null
                      : (emptyAndEnabled
                            ? cs.primary
                            : cs.onSurfaceVariant.withAlpha(140)),
                  fontWeight: emptyAndEnabled ? FontWeight.w600 : null,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 18,
              color: enabled ? cs.primary : cs.onSurfaceVariant.withAlpha(140),
            ),
          ],
        ),
      ),
    );
  }

  /// Polished other-Budget picker — a rounded bottom sheet listing every
  /// OTHER Budget (never an "Unallocated" pseudo-option), icon/name/
  /// funds-available/a check mark on the current selection.
  Future<void> _pickOtherBudget() async {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final title = switch (_otherBudgetFieldLabel) {
      'To Budget' => 'Transfer To',
      'From Budget' => 'Transfer From',
      _ => 'Select Budget',
    };
    // Only a "From Budget" pick (Receive, or an Adjust To that resolves to
    // receiving) is capped by the other Budget's own funds-available — a
    // "To Budget" pick has no such ceiling. Budgets below the required
    // amount stay visible (never filtered out) but can't be tapped.
    final needsSufficientBalance = _otherBudgetFieldLabel == 'From Budget';
    final requiredAmount = _amount;
    final picked = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
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
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              Divider(height: 1, color: cs.outlineVariant),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: _otherBudgets.length,
                  separatorBuilder: (_, _) => Divider(
                    height: 1,
                    indent: 20,
                    endIndent: 20,
                    color: cs.outlineVariant.withAlpha(100),
                  ),
                  itemBuilder: (context, i) {
                    final b = _otherBudgets[i];
                    final isSelected = b.id == _otherBudgetId;
                    final budgetValue = _budgetValue(b);
                    final isInsufficient =
                        needsSufficientBalance &&
                        budgetValue < requiredAmount - 0.005;
                    return InkWell(
                      onTap: () {
                        if (isInsufficient) {
                          showTopSnack(
                            ctx,
                            'That Budget only has ₹${compactAmount(budgetValue)} '
                            '— not enough to cover ₹${compactAmount(requiredAmount)}.',
                          );
                          return;
                        }
                        Navigator.of(ctx).pop(b.id);
                      },
                      child: Opacity(
                        opacity: isInsufficient ? 0.45 : 1.0,
                        child: Container(
                          color: isSelected
                              ? cs.primaryContainer.withAlpha(60)
                              : null,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 34,
                                height: 34,
                                decoration: BoxDecoration(
                                  color: cs.primaryContainer.withAlpha(90),
                                  borderRadius: BorderRadius.circular(9),
                                ),
                                alignment: Alignment.center,
                                child: Icon(
                                  Icons.account_balance_wallet_outlined,
                                  size: 17,
                                  color: cs.primary,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      b.name,
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.w500,
                                          ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    if (isInsufficient)
                                      Text(
                                        'Not enough balance',
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(color: cs.error),
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '₹${compactAmount(budgetValue)}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: isInsufficient
                                      ? cs.error
                                      : cs.onSurfaceVariant,
                                ),
                              ),
                              if (isSelected) ...[
                                const SizedBox(width: 8),
                                Icon(
                                  Icons.check_circle_rounded,
                                  size: 18,
                                  color: cs.primary,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 4),
            ],
          ),
        );
      },
    );
    if (picked != null && mounted) {
      setState(() {
        _otherBudgetId = picked;
        _syncAllocRowsForGiver();
        if (_amount > 0.005 && !_allocsUserEdited) {
          _autoFillAllocationsProportionally();
        }
      });
      _revealStep1Preview(animate: true);
    }
  }

  /// Step 1's body: the mode selector + amount/budget card, then either
  /// the placeholder hint or the "before/after" preview once both the
  /// amount and the other Budget are resolved.
  Widget _buildStep1Body(ThemeData theme, ColorScheme cs) {
    return SingleChildScrollView(
      controller: _step1ScrollCtrl,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSourceAndTransferCard(theme, cs),
          if (_showBreakdown) ...[
            const SizedBox(height: 14),
            _buildTransferPreview(theme, cs),
          ] else ...[
            const SizedBox(height: 28),
            Center(
              child: Text(
                _placeholderMessage,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// The "Transferring ₹X from A to B" + "After Transfer: A will have ₹Y,
  /// B will have ₹Z" preview card shown on Step 1 once the move is fully
  /// resolved.
  Widget _buildTransferPreview(ThemeData theme, ColorScheme cs) {
    final giver = _giverBudget;
    final receiver = _receiverBudget;
    if (giver == null || receiver == null) return const SizedBox.shrink();
    final giverAfter = _budgetValue(giver) - _amount;
    final receiverAfter = _budgetValue(receiver) + _amount;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.primaryContainer.withAlpha(50),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.primary.withAlpha(60)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTransferHeadline(
            theme,
            cs,
            baseStyle: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'AFTER TRANSFER',
            style: theme.textTheme.labelSmall?.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 6),
          _buildAfterRow(
            theme,
            cs,
            giver.name,
            _budgetValue(giver),
            giverAfter,
          ),
          // Small down arrow between the two strips — purely visual,
          // centered across the card — conveying "funds flow from the
          // strip above into the strip below" at a glance, reinforcing
          // the giver -> receiver direction already stated in the
          // headline above.
          Align(
            alignment: Alignment.center,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Icon(
                Icons.south_rounded,
                size: 13,
                color: cs.onSurfaceVariant.withAlpha(140),
              ),
            ),
          ),
          _buildAfterRow(
            theme,
            cs,
            receiver.name,
            _budgetValue(receiver),
            receiverAfter,
          ),
        ],
      ),
    );
  }

  /// `budgetName    ₹current → ₹after` — showing both the current and
  /// resulting funds-available (not just the after value) so the size of
  /// the change is clear at a glance, without having to mentally subtract
  /// against the header subtitle's current balance.
  Widget _buildAfterRow(
    ThemeData theme,
    ColorScheme cs,
    String budgetName,
    double before,
    double after,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: cs.shadow.withAlpha(18),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              budgetName,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurface,
                fontWeight: FontWeight.w700,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text.rich(
            TextSpan(
              style: theme.textTheme.bodySmall,
              children: [
                TextSpan(
                  text: '₹${compactAmount(before)} ',
                  style: TextStyle(
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w400,
                  ),
                ),
                TextSpan(
                  text: '\u2192 ',
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
                TextSpan(
                  text: '₹${compactAmount(after)}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Step 2's body: a sticky header (the resolved move + "ACCOUNT
  /// BREAKDOWN" section label) above the full-height scrollable account
  /// list.
  Widget _buildStep2Body(
    ThemeData theme,
    ColorScheme cs,
    ScrollController scrollCtrl,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildTransferHeadline(
                theme,
                cs,
                baseStyle: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'ACCOUNT BREAKDOWN',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: cs.primary,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Choose account portions to transfer from',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 6),
              // The table header itself: the giver Budget's name takes the
              // place of a plain "Name" column label — reading as
              // "<Budget name> | Available | Transfer" — so the Budget the
              // list is broken down from is baked right into the table
              // instead of sitting in a separate sentence above it.
              // Non-bold so it reads as a quiet column label rather than
              // restating the headline sentence above with equal visual
              // weight. Ellipsis-truncated so a long name can't push the
              // Available/Transfer columns out of place; tapping it
              // expands the name onto its own wrapped line instead.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(
                  () => _giverBudgetNameExpanded = !_giverBudgetNameExpanded,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: ExpandableNameText(
                        _giverBudget?.name ?? '',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: cs.onSurface,
                          fontWeight: FontWeight.w400,
                        ),
                        expanded: _giverBudgetNameExpanded,
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: _availableColWidth,
                      child: Text(
                        'Available',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 110,
                      child: Text(
                        'Transfer',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(width: 4),
                    const SizedBox(
                      width: 13,
                    ), // placeholder matching the arrow icon's width
                  ],
                ),
              ),
              const SizedBox(height: 6),
            ],
          ),
        ),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withAlpha(60),
              border: Border.symmetric(
                horizontal: BorderSide(color: cs.outlineVariant.withAlpha(140)),
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
                        final hasMore =
                            metrics.pixels < metrics.maxScrollExtent - 1.0;
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
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                      children: [
                        for (final r in _allocRows)
                          _buildAccountRow(theme: theme, cs: cs, row: r),
                      ],
                    ),
                  ),
                ),
                // Top fade
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: 20,
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
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOut,
                        ),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: cs.surfaceContainerHighest.withAlpha(220),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: cs.outlineVariant.withAlpha(100),
                            ),
                          ),
                          child: Icon(
                            Icons.keyboard_arrow_up_rounded,
                            size: 16,
                            color: cs.onSurfaceVariant.withAlpha(180),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // Bottom fade
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  height: 28,
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
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOut,
                        ),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: cs.surfaceContainerHighest.withAlpha(220),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: cs.outlineVariant.withAlpha(100),
                            ),
                          ),
                          child: Icon(
                            Icons.keyboard_arrow_down_rounded,
                            size: 16,
                            color: cs.onSurfaceVariant.withAlpha(180),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Builds `'Transferring ₹X from A to B'` as rich text — ported verbatim
  /// from `reallocate_pot_sheet.dart`'s identical helper. Shared by Step
  /// 1's preview card and Step 2's headline.
  Widget _buildTransferHeadline(
    ThemeData theme,
    ColorScheme cs, {
    required TextStyle? baseStyle,
  }) {
    final giver = _giverBudget;
    final receiver = _receiverBudget;
    if (giver == null || receiver == null) return const SizedBox.shrink();
    final keywordStyle = baseStyle?.copyWith(
      color: cs.onSurfaceVariant,
      fontWeight: FontWeight.w400,
    );
    final budgetNameStyle = baseStyle?.copyWith(
      color: cs.onSurface,
      fontWeight: FontWeight.w800,
    );
    final amountStyle = baseStyle?.copyWith(fontWeight: FontWeight.w800);
    return Text.rich(
      TextSpan(
        style: keywordStyle,
        children: [
          const TextSpan(text: 'Transferring '),
          TextSpan(text: '₹${compactAmount(_amount)} ', style: amountStyle),
          const TextSpan(text: 'from '),
          TextSpan(text: giver.name, style: budgetNameStyle),
          const TextSpan(text: ' to '),
          TextSpan(text: receiver.name, style: budgetNameStyle),
        ],
      ),
    );
  }

  /// Sticky bottom CTA — "Next" (Step 1) or the remaining-indicator +
  /// actual "Reallocate ₹X" submit button (Step 2).
  Widget _buildBottomBar(ThemeData theme, ColorScheme cs) {
    if (_step == 1) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: FilledButton(
          onPressed: _canProceedToStep2 ? _goToStep2 : null,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          child: const Text('Next'),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_amount > 0.005 && _remaining.abs() > 0.015) ...[
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
    );
  }

  /// Single-line account row: Account name  ₹Xk available  [field]  →
  ///
  /// The trailing arrow is always "outward" (→), regardless of mode — this
  /// breakdown is always built from the GIVER Budget's own allocations.
  Widget _buildAccountRow({
    required ThemeData theme,
    required ColorScheme cs,
    required _AllocationRow row,
  }) {
    final error = _allocError(row);
    final isExpanded = _expandedAccountIds.contains(row.accountId);
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => setState(() {
                    if (isExpanded) {
                      _expandedAccountIds.remove(row.accountId);
                    } else {
                      _expandedAccountIds.add(row.accountId);
                    }
                  }),
                  child: Row(
                    children: [
                      Icon(
                        Icons.account_balance_outlined,
                        size: 14,
                        color: cs.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: ExpandableNameText(
                          row.accountName,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                          expanded: isExpanded,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: _availableColWidth,
                child: Text(
                  '₹${compactAmount(row.available)}',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 110,
                child: TextField(
                  controller: row.ctrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(
                      RegExp(r'^\d*\.?\d{0,2}'),
                    ),
                  ],
                  textAlign: TextAlign.right,
                  style: theme.textTheme.bodyMedium,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '0',
                    prefixText: '₹ ',
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: cs.outlineVariant),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.east_rounded,
                size: 13,
                color: cs.onSurfaceVariant.withAlpha(160),
              ),
            ],
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 3, right: 2),
              child: Align(
                alignment: Alignment.centerRight,
                child: Text(
                  error,
                  style: theme.textTheme.labelSmall?.copyWith(color: cs.error),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Only shown when the breakdown is incomplete or over.
  Widget _buildRemainingIndicator(ThemeData theme, ColorScheme cs) {
    final rem = _remaining;
    final isOver = rem < -0.015;
    final color = isOver ? cs.error : Colors.orange.shade700;
    final label = isOver
        ? 'Over by ₹${compactAmount(rem.abs())} — reduce amounts'
        : '₹${compactAmount(rem)} still unassigned';

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Icon(Icons.info_outline, size: 13, color: color),
        const SizedBox(width: 4),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: color,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
