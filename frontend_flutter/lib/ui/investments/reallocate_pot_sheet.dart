import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/snack_utils.dart';
import '../../data/models/investments_models.dart';
import '../../state/investments_controller.dart';
import '../../utils/amount_formatter.dart';
import '../../utils/api_error_utils.dart';
import '../widgets/expandable_name_text.dart';
import 'pot_icons.dart';

double _round2(double v) => (v * 100).round() / 100;
double _round6(double v) => (v * 1e6).round() / 1e6;

typedef _Movement = ({
  String accountAssetId,
  String fromPotId,
  String toPotId,
  String units,
});

/// Three ways to move money between exactly two Pots — modeled after
/// transferring money between bank accounts (familiar + simple), never a
/// multi-Pot distribute.
///
/// - [send]: move an amount OUT of this Pot, into another Pot.
/// - [receive]: pull an amount IN to this Pot, from another Pot.
/// - [adjustTo]: declare what this Pot's final balance should be; the app
///   works out whether that means sending the excess away or receiving the
///   shortfall from the other Pot you pick.
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

/// Pot "Transfer" flow — a full-screen page between exactly this Pot and
/// one other Pot the user picks, replacing the earlier "set a target value,
/// distribute across many Pots" design.
///
/// Flow: pick Send / Receive / Adjust To, enter an amount (or target
/// balance), pick the single other Pot involved, then (step 2) fine-tune
/// exactly which underlying holdings fund that amount — defaults to a
/// proportional-to-current-weight split so most users never need to touch
/// it.
///
/// Pushed as a full-screen route (not a bottom sheet) so the asset
/// breakdown always gets the entire screen height, rather than whatever a
/// sheet leaves below the status bar.
///
/// Deliberately NOT `fullscreenDialog: true` — on iOS that flag switches
/// to Cupertino's modal-presentation transition (the new page slides up
/// from the bottom over the old one, which keeps peeking out from behind
/// with rounded top corners), which looks exactly like a bottom sheet
/// again, loading screen included. The default push transition (slide in
/// from the right / platform-appropriate) reads as a genuine new page.
Future<void> showReallocatePotSheet(
  BuildContext context, {
  required String potId,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => ReallocatePotSheet(potId: potId)),
  );
}

class ReallocatePotSheet extends StatefulWidget {
  const ReallocatePotSheet({super.key, required this.potId});

  /// The Pot whose "Transfer" button was tapped — always shown in the
  /// header, and always one side of the move (the other side is whichever
  /// Pot the user picks below).
  final String potId;

  @override
  State<ReallocatePotSheet> createState() => _ReallocatePotSheetState();
}

class _AssetRow {
  _AssetRow({
    required this.accountAssetId,
    required this.assetName,
    required this.accountName,
    required this.available,
    required this.availableUnits,
    required this.ctrl,
  });

  final String accountAssetId;
  final String assetName;
  final String accountName;
  final double available;

  /// Exact current units actually held (in whichever Pot is funding this
  /// move — the "giver") for this asset — used to clamp the final
  /// movement so a rupee amount that rounds up slightly when converted
  /// back to units (e.g. because [available] was itself rounded to the
  /// nearest cent) can never request more units than genuinely exist. See
  /// `_buildMovements`.
  final double availableUnits;
  final TextEditingController ctrl;
}

class _ReallocatePotSheetState extends State<ReallocatePotSheet> {
  /// Shared height for the amount/target field and the other-Pot field
  /// beside it, so the two line up exactly despite one being a real
  /// `TextField` and the other a custom tappable row.
  static const double _fieldHeight = 44;

  /// Shared width for the "Available" column (both its header label and
  /// every row's value) in Step 2's asset breakdown — keeping this one
  /// constant in sync between the header and `_buildAssetRow` is what
  /// keeps "Available"/"Transfer" centered directly above their actual
  /// columns instead of drifting out of alignment.
  static const double _availableColWidth = 64;

  bool _loading = true;
  String? _loadError;
  InvestmentsReallocationDataDto? _data;
  final Map<String, double> _priceByAssetId = {};
  final Map<String, String> _iconKeyByPotId = {};

  _Mode _mode = _Mode.send;
  final TextEditingController _amountCtrl = TextEditingController();
  final List<_AssetRow> _assetRows = [];
  String? _otherPotId;
  bool _saving = false;

  /// Scrolls the Step 2 asset-breakdown list. Previously supplied by
  /// `DraggableScrollableSheet`'s builder when this was a bottom sheet;
  /// now owned directly since this is a full-screen page.
  final ScrollController _scrollCtrl = ScrollController();

  /// Scrolls Step 1's mode/amount card + preview column — used to keep the
  /// "Transferring ₹X from A to B" preview pulled into view above the
  /// keyboard (see [_revealStep1Preview]) instead of leaving it cut off
  /// below the fold once the keyboard shrinks the available height.
  final ScrollController _step1ScrollCtrl = ScrollController();

  /// 1 = pick mode/amount/other Pot (no asset breakdown visible yet). 2 =
  /// the asset breakdown, full-height — split into two steps so the
  /// breakdown gets the whole sheet's vertical space instead of fighting
  /// the mode selector/amount card for room, especially with the keyboard
  /// open. See investments_pot_amounts_different_approach.log.
  int _step = 1;
  bool _hasMoreBelow = false;
  bool _hasMoreAbove = false;

  /// Tracks which Pot the asset breakdown was last built from, so we only
  /// rebuild it (and reset any manual edits) when the "giver" Pot actually
  /// changes — e.g. switching modes, picking a different other Pot, or an
  /// Adjust To target flipping which side is giving.
  String? _lastGiverPotId;

  /// True once the user has manually typed in ANY asset-breakdown field —
  /// auto-fill (proportional split of the move amount across the giver
  /// Pot's own holdings) only runs while this is false.
  bool _assetsUserEdited = false;

  /// Asset names (keyed by `accountAssetId`) currently shown fully
  /// (untruncated) instead of ellipsis-clipped — tapping a row's name
  /// toggles its membership here, same pattern as the Pots/Assets tabs.
  final Set<String> _expandedAssetIds = {};
  bool _giverPotNameExpanded = false;

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
    for (final r in _assetRows) {
      r.ctrl.dispose();
    }
    super.dispose();
  }

  /// Scrolls Step 1 so its bottom-most content (the preview card, once
  /// shown — the placeholder text otherwise) is fully visible above the
  /// keyboard. Called after every amount keystroke (jump, no animation —
  /// it should just stay pinned while typing, not visibly re-animate on
  /// every digit) and after picking the other Pot (animated — a bigger,
  /// deliberate layout change worth the motion). A no-op once already at
  /// the bottom, and harmless if the content is short enough to need no
  /// scrolling at all (`maxScrollExtent` is then 0).
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
      final controller = context.read<InvestmentsController>();
      final data = await controller.api.fetchReallocationData();
      if (!mounted) return;
      for (final p in data.pots) {
        for (final pos in p.positions) {
          _priceByAssetId[pos.accountAssetId] = double.tryParse(pos.price) ?? 0;
        }
      }
      for (final p in controller.portfolio?.pots ?? const []) {
        _iconKeyByPotId[p.id] = p.iconKey;
      }
      setState(() {
        _data = data;
        _loading = false;
      });
      // Default mode is Send, whose giver is always this Pot itself — build
      // the initial breakdown right away so it's ready the moment an
      // amount is entered.
      _syncAssetRowsForGiver();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.toString();
        _loading = false;
      });
    }
  }

  // ── Derived from loaded data ─────────────────────────────────────────────

  InvestmentsReallocationPotDto? _findPot(String id) {
    for (final p in _data?.pots ?? const <InvestmentsReallocationPotDto>[]) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// This Pot — the one whose "Transfer" button opened this sheet. Always
  /// one side of the move; which side depends on [_mode] (and, for Adjust
  /// To, the computed direction).
  InvestmentsReallocationPotDto? get _sourcePot => _findPot(widget.potId);

  InvestmentsReallocationPotDto? get _otherPot =>
      _otherPotId != null ? _findPot(_otherPotId!) : null;

  List<InvestmentsReallocationPotDto> get _otherPots =>
      (_data?.pots ?? const <InvestmentsReallocationPotDto>[])
          .where((p) => p.id != widget.potId)
          .toList();

  double _potValue(InvestmentsReallocationPotDto p) =>
      double.tryParse(p.currentValue) ?? 0;

  double get _sourceValue => _sourcePot != null ? _potValue(_sourcePot!) : 0;

  // ── Direction (who's giving, who's receiving) ────────────────────────────

  /// Raw text typed into the single primary field — interpreted as "amount
  /// to move" (Send/Receive) or "desired final balance for this Pot"
  /// (Adjust To).
  double get _rawInput => double.tryParse(_amountCtrl.text.trim()) ?? 0;

  /// true: this Pot is giving money away. false: this Pot is receiving.
  /// null: direction not yet known (Adjust To with nothing typed yet, or a
  /// target that exactly matches the current balance — nothing to move).
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

  /// The Pot actually funding this move — whichever side ends up smaller.
  /// Its positions are what the asset breakdown is built from.
  InvestmentsReallocationPotDto? get _giverPot {
    final isGiver = _selfIsGiver;
    if (isGiver == null) return null;
    return isGiver ? _sourcePot : _otherPot;
  }

  /// The Pot on the other end of [_giverPot] — whichever side ends up
  /// bigger. Used for the Step 1 "after transfer" preview and Step 2's
  /// headline; the breakdown itself never touches this Pot's positions.
  InvestmentsReallocationPotDto? get _receiverPot {
    final isGiver = _selfIsGiver;
    if (isGiver == null) return null;
    return isGiver ? _otherPot : _sourcePot;
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

  double get _assetSum => _assetRows.fold(
    0.0,
    (s, r) => s + (double.tryParse(r.ctrl.text.trim()) ?? 0),
  );

  double get _remaining => _round2(_amount - _assetSum);

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
        final cap = _otherPot != null ? _potValue(_otherPot!) : null;
        if (cap != null && _rawInput > cap + 0.005) {
          return 'Only ₹${compactAmount(cap)} available in that Pot';
        }
        return null;
      case _Mode.adjustTo:
        if (_selfIsGiver == false) {
          final cap = _otherPot != null ? _potValue(_otherPot!) : null;
          if (cap != null && _amount > cap + 0.005) {
            return 'That Pot only has ₹${compactAmount(cap)} available';
          }
        }
        return null;
    }
  }

  String? _assetError(_AssetRow row) {
    final v = double.tryParse(row.ctrl.text.trim()) ?? 0;
    if (v < 0) return 'Cannot be negative';
    if (v > row.available + 0.005) {
      return 'Only ₹${compactAmount(row.available)} available';
    }
    return null;
  }

  bool get _canSubmit {
    if (_data == null || _loading || _saving) return false;
    if (_otherPotId == null) return false;
    if (_selfIsGiver == null) return false;
    if (_amount <= 0.005) return false;
    if (_primaryFieldError != null) return false;
    if (_assetRows.isEmpty) return false;
    if (_remaining.abs() > 0.015) return false;
    for (final r in _assetRows) {
      if (_assetError(r) != null) return false;
    }
    return true;
  }

  /// Gates Step 1's "Next" button — everything needed to KNOW the move
  /// (mode, amount/target, other Pot) must be valid; the actual per-asset
  /// breakdown is only reachable on Step 2.
  bool get _canProceedToStep2 => _showBreakdown && _primaryFieldError == null;

  // ── Callbacks ─────────────────────────────────────────────────────────────

  void _onModeChanged(_Mode mode) {
    if (mode == _mode) return;
    setState(() {
      _mode = mode;
      _otherPotId = null;
      if (_amountCtrl.text.isNotEmpty) {
        _amountCtrl.value = const TextEditingValue(
          text: '',
          selection: TextSelection.collapsed(offset: 0),
        );
      }
      _syncAssetRowsForGiver();
    });
  }

  void _onAmountChanged() {
    if (!mounted) return;
    _syncAssetRowsForGiver();
    if (_amount <= 0.005) {
      _assetsUserEdited = false;
      for (final r in _assetRows) {
        _setAssetSilently(r.ctrl, '');
      }
    } else if (!_assetsUserEdited) {
      _autoFillAssetsProportionally();
    }
    setState(() {});
    // Keeps the preview card (when already showing, i.e. the other Pot was
    // already picked) pinned above the keyboard as the amount keeps
    // changing — jump, not animate, so it doesn't visibly re-scroll on
    // every keystroke.
    _revealStep1Preview();
  }

  /// Called whenever the user physically types in ANY asset field — freezes
  /// auto-fill for the rest of this session.
  void _onAssetChanged() {
    _assetsUserEdited = true;
    if (mounted) setState(() {});
  }

  /// Rebuilds [_assetRows] from [_giverPot]'s own positions whenever the
  /// giver actually changes (mode switch, other-Pot pick, or an Adjust To
  /// target flipping direction). A no-op if the giver hasn't changed, so
  /// in-progress manual edits survive unrelated rebuilds (e.g. re-typing
  /// the same amount).
  void _syncAssetRowsForGiver() {
    final giver = _giverPot;
    final giverId = giver?.id;
    if (giverId == _lastGiverPotId) return;
    _lastGiverPotId = giverId;
    for (final r in _assetRows) {
      r.ctrl.dispose();
    }
    _assetRows.clear();
    _assetsUserEdited = false;
    if (giver == null) return;
    for (final pos in giver.positions) {
      final v = double.tryParse(pos.value) ?? 0;
      if (v <= 0.001) continue;
      final ctrl = TextEditingController();
      ctrl.addListener(_onAssetChanged);
      _assetRows.add(
        _AssetRow(
          accountAssetId: pos.accountAssetId,
          assetName: pos.assetName,
          accountName: pos.accountName,
          available: v,
          availableUnits: double.tryParse(pos.units) ?? 0,
          ctrl: ctrl,
        ),
      );
    }
  }

  void _autoFillAssetsProportionally() {
    final total = _assetRows.fold(0.0, (s, r) => s + r.available);
    if (total <= 0) return;
    final amt = _amount;
    double allocated = 0;
    for (var i = 0; i < _assetRows.length; i++) {
      final r = _assetRows[i];
      final share = i == _assetRows.length - 1
          ? max(0.0, _round2(amt - allocated))
          : _round2(amt * (r.available / total));
      allocated += share;
      _setAssetSilently(r.ctrl, _ctrlValue(share));
    }
  }

  /// Programmatically sets a field's text without marking it as user-edited
  /// (so auto-fill can keep updating it) and with an explicit, valid cursor
  /// position — the plain `.text =` setter leaves the selection at an
  /// "unset" marker that some platforms resolve by selecting the entire
  /// field on its first focus.
  void _setAssetSilently(TextEditingController ctrl, String value) {
    if (ctrl.text == value) return;
    ctrl.removeListener(_onAssetChanged);
    ctrl.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    ctrl.addListener(_onAssetChanged);
  }

  void _reset() {
    _mode = _Mode.send;
    _assetsUserEdited = false;
    _otherPotId = null;
    _step = 1;
    if (_amountCtrl.text.isNotEmpty) {
      _amountCtrl.value = const TextEditingValue(
        text: '',
        selection: TextSelection.collapsed(offset: 0),
      );
    }
    _lastGiverPotId = null;
    _syncAssetRowsForGiver();
    setState(() {});
  }

  /// Step 1 -> Step 2. Nothing about the already-entered mode/amount/other
  /// Pot (or any manual asset edits made on a previous visit to Step 2)
  /// is touched — this is a pure view switch within the same state.
  void _goToStep2() {
    if (!_canProceedToStep2) return;
    setState(() => _step = 2);
  }

  /// Step 2 -> Step 1, to tweak the amount/mode/other Pot. Preserves
  /// everything (including any manual per-asset edits) so returning to
  /// Step 2 picks up right where it left off.
  void _goBackToStep1() {
    setState(() => _step = 1);
  }

  // ── Movement plan + submit ──────────────────────────────────────────────

  List<_Movement> _buildMovements() {
    final movements = <_Movement>[];
    final other = _otherPotId;
    final isGiver = _selfIsGiver;
    if (other == null || isGiver == null) return movements;
    final fromId = isGiver ? widget.potId : other;
    final toId = isGiver ? other : widget.potId;
    for (final r in _assetRows) {
      final v = double.tryParse(r.ctrl.text.trim()) ?? 0;
      if (v <= 0.001) continue;
      final price = _priceByAssetId[r.accountAssetId] ?? 0;
      if (price <= 0) continue;
      double units;
      if ((r.available - v).abs() <= 0.005) {
        // The user is moving this position's FULL balance (the entered
        // amount matches `available`, which is itself a rupee value
        // rounded to the nearest cent). Use the exact units on record
        // directly instead of round-tripping through rupees/price —
        // that conversion can round either up (overshoots the true
        // units, which the backend's strict sufficiency check rejects)
        // or down (leaves a tiny fractional-unit residue behind, so the
        // giver Pot never actually reaches ₹0). Using the exact units
        // guarantees a clean, complete drain.
        units = r.availableUnits;
      } else {
        // Partial transfer — compute from the entered rupee amount, but
        // still clamp against the true available units as a safety net
        // in case rounding pushes it slightly over.
        units = min(_round6(v / price), r.availableUnits);
      }
      if (units <= 0) continue;
      movements.add((
        accountAssetId: r.accountAssetId,
        fromPotId: fromId,
        toPotId: toId,
        units: units.toStringAsFixed(6),
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
    final controller = context.read<InvestmentsController>();
    setState(() => _saving = true);
    try {
      await controller.reallocate(movements: movements);
      if (!mounted) return;
      Navigator.of(context).pop();
      showTopSnack(context, 'Pot allocation updated');
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

  /// Always "Transfer" — matches the "Transfer" affordance that opened this
  /// sheet, so the action keeps one consistent name end-to-end regardless
  /// of which of the three modes is active. Only its enabled state + the
  /// trailing amount change as the form fills in.
  String get _ctaLabel {
    if (_otherPotId == null || _amount <= 0.005) return 'Transfer';
    return 'Transfer ₹${compactAmount(_amount)}';
  }

  String get _primaryFieldLabel =>
      _mode == _Mode.adjustTo ? 'Target Amount' : 'Amount';

  String get _otherPotFieldLabel {
    switch (_mode) {
      case _Mode.send:
        return 'To Pot';
      case _Mode.receive:
        return 'From Pot';
      case _Mode.adjustTo:
        final isGiver = _selfIsGiver;
        if (isGiver == true) return 'To Pot';
        if (isGiver == false) return 'From Pot';
        return 'Other Pot';
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

  bool get _otherPotFieldEnabled {
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
  /// actually amounts to — the ₹ amount is bolded, same treatment as every
  /// other info-note amount in this sheet (the preview card, the Step 2
  /// headline), while the surrounding sentence stays plain/muted.
  Widget? _buildAdjustToNote(ThemeData theme, ColorScheme cs) {
    if (_mode != _Mode.adjustTo) return null;
    if (_amountCtrl.text.trim().isEmpty) return null;
    final baseStyle = theme.textTheme.labelSmall?.copyWith(
      color: cs.onSurfaceVariant,
    );
    final isGiver = _selfIsGiver;
    if (isGiver == null) {
      return Text('This Pot is already at this amount.', style: baseStyle);
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
          TextSpan(text: isGiver ? 'to another Pot' : 'from another Pot'),
        ],
      ),
    );
  }

  bool get _showBreakdown => _otherPotId != null && _giverPot != null;

  String get _placeholderMessage {
    if (_amountCtrl.text.trim().isEmpty) {
      return _mode == _Mode.adjustTo
          ? 'Enter a target amount for this Pot.'
          : 'Enter an amount to transfer.';
    }
    if (_mode == _Mode.adjustTo && _selfIsGiver == null) {
      return 'This Pot is already at that amount.';
    }
    switch (_mode) {
      case _Mode.send:
        return 'Select a Pot to transfer to.';
      case _Mode.receive:
        return 'Select a Pot to transfer from.';
      case _Mode.adjustTo:
        return _selfIsGiver == true
            ? 'Select a Pot to send the extra amount to.'
            : 'Select a Pot to receive the amount from.';
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      // Explicit (matches the Flutter default) — the body, including the
      // sticky bottom CTA, must shrink to stay above the keyboard rather
      // than letting the keyboard overlay it.
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
                  // Split into two rows — the title line shares its row with
                  // Reset/Cancel (both short, fixed-width, never a problem), while
                  // the Pot name + amount subtitle gets a row all to itself so a
                  // long Pot name has the full sheet width before truncating,
                  // instead of fighting two buttons for space on narrow screens.
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
                        // Back (Step 2 -> Step 1) lives top-LEFT, opposite side
                        // from Reset/Cancel, which already occupy the top-right —
                        // only shown on Step 2, since Step 1 has nowhere "back"
                        // to go (Cancel already covers leaving the sheet
                        // entirely).
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
                            'Transfer Funds',
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
                            resolvePotIcon(_iconKeyByPotId[widget.potId]),
                            size: 14,
                            color: cs.primary,
                          ),
                        ),
                        const SizedBox(width: 4),
                        // Wraps to a 2nd line instead of ellipsis-truncating when
                        // a long Pot name + the current balance don't both fit on
                        // one line — only an extreme combination (very long name
                        // AND a very large balance) would still overflow past
                        // that, which the ellipsis then catches as a last resort.
                        Flexible(
                          child: Text(
                            '${_sourcePot?.name ?? ''} · ₹${_formatAmt(_sourceValue)}',
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
                  // Step 1 (pick mode/amount/other Pot) and Step 2 (the
                  // asset breakdown) are two mutually-exclusive views of the
                  // SAME state — swapping between them never loses anything
                  // already entered. Split specifically so Step 2's
                  // breakdown gets the whole remaining screen height
                  // instead of sharing it with the mode selector/amount
                  // card, which was starving it of room (especially with
                  // the keyboard open). See
                  // investments_pot_amounts_different_approach.log.
                  Expanded(
                    child: _step == 1
                        ? _buildStep1Body(theme, cs)
                        : _buildStep2Body(theme, cs, _scrollCtrl),
                  ),

                  // ── STICKY BOTTOM: Next (Step 1) or remaining + Transfer
                  // (Step 2) ───────────────────────────────────────────────
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
  /// Target] [→ or ←] [Other Pot]" row. The source Pot's name + current
  /// balance are shown in the sheet's header only (not repeated here), so
  /// the asset breakdown below gets more vertical space.
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
                // A faint divider-weight border between segments instead of
                // the default strong outline — the selected segment's
                // filled background alone is enough to show the active
                // mode, so the border shouldn't compete for attention.
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
                // Grey (inert) while the To/From Pot field is still
                // disabled — matches that field's own disabled look.
                // Switches to primary blue the moment that field
                // activates, echoing its own "needs your input" state
                // instead of staying neutral while the field beside it is
                // clearly inviting a tap.
                child: Icon(
                  _arrowIcon,
                  size: 16,
                  color: _otherPotFieldEnabled ? cs.primary : cs.outlineVariant,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _otherPotFieldLabel,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 2),
                    _buildOtherPotField(theme, cs),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Tappable field styled to match the amount `TextField` beside it
  /// (same height/border/radius), opening a polished bottom-sheet picker
  /// instead of a plain `DropdownButton` popup. Disabled (muted, inert)
  /// until an amount (or, in Adjust To, a target) has been entered.
  Widget _buildOtherPotField(ThemeData theme, ColorScheme cs) {
    final enabled = _otherPotFieldEnabled;
    final selected = _otherPot;
    // Disabled, "enabled but nothing picked yet", and "picked" all need to
    // look clearly distinct. Disabled gets a flat grey fill. Enabled-but-
    // empty now gets the same treatment as a focused `TextField` — a
    // `cs.primary` border + a faint primary-tinted fill — so it visibly
    // reads as "needs your input" rather than inert, matching the Amount
    // field's active look instead of blending in with disabled fields.
    // Once a Pot is picked, it settles back to a neutral border since the
    // field has done its job and shouldn't keep demanding attention.
    final emptyAndEnabled = enabled && selected == null;
    return InkWell(
      onTap: enabled ? _pickOtherPot : null,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: _fieldHeight,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          // Once a Pot is picked, fill solid white — same as the Amount
          // `TextField`'s theme fill — instead of staying transparent
          // (which let the grey card show through and made this box read
          // as visually shorter/thinner than the Amount field next to it,
          // even though both are forced to the exact same `_fieldHeight`).
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
                resolvePotIcon(_iconKeyByPotId[selected.id]),
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

  /// Polished other-Pot picker — a rounded bottom sheet listing every
  /// eligible Pot (icon, name, current value, a check mark on the current
  /// selection), replacing the default unstyled `DropdownButton` popup.
  /// Its title adapts to the current mode/direction.
  Future<void> _pickOtherPot() async {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final title = switch (_otherPotFieldLabel) {
      'To Pot' => 'Transfer To',
      'From Pot' => 'Transfer From',
      _ => 'Select Pot',
    };
    // Only a "From Pot" pick (Receive, or an Adjust To that resolves to
    // receiving) is capped by the other Pot's own balance — a "To Pot" pick
    // has no such ceiling, since any Pot can always receive money. Pots
    // below the required amount stay visible in the list (never filtered
    // out) but can't be tapped to select, per the deduct-first flow's
    // existing safety net (the amount field already errors if an
    // already-selected Pot later turns out insufficient).
    final needsSufficientBalance = _otherPotFieldLabel == 'From Pot';
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
                  itemCount: _otherPots.length,
                  separatorBuilder: (_, _) => Divider(
                    height: 1,
                    indent: 20,
                    endIndent: 20,
                    color: cs.outlineVariant.withAlpha(100),
                  ),
                  itemBuilder: (context, i) {
                    final p = _otherPots[i];
                    final isSelected = p.id == _otherPotId;
                    final potValue = _potValue(p);
                    final isInsufficient =
                        needsSufficientBalance &&
                        potValue < requiredAmount - 0.005;
                    return InkWell(
                      onTap: () {
                        if (isInsufficient) {
                          showTopSnack(
                            ctx,
                            'That Pot only has ₹${compactAmount(potValue)} '
                            '— not enough to cover ₹${compactAmount(requiredAmount)}.',
                          );
                          return;
                        }
                        Navigator.of(ctx).pop(p.id);
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
                                  resolvePotIcon(_iconKeyByPotId[p.id]),
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
                                      p.name,
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
                                '₹${compactAmount(potValue)}',
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
        _otherPotId = picked;
        _syncAssetRowsForGiver();
        if (_amount > 0.005 && !_assetsUserEdited) {
          _autoFillAssetsProportionally();
        }
      });
      // Picking the other Pot is usually what completes the move and
      // makes the preview card appear for the first time — animate it
      // into view above the keyboard (if still open) rather than leaving
      // it cut off below the fold.
      _revealStep1Preview(animate: true);
    }
  }

  /// Step 1's body: the mode selector + amount/pot card, then either the
  /// placeholder hint (nothing usable entered yet) or the "before/after"
  /// preview once both the amount and the other Pot are resolved. Wrapped
  /// in a scroll view (rather than relying on a fixed-height Column) so a
  /// very small screen with the keyboard open never overflows — unlike
  /// Step 2, there's no dedicated list here that needs the space, so this
  /// doesn't need its own `Expanded` + custom scroll chrome.
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
  /// resolved — a sanity-check moment before committing to review the
  /// underlying asset breakdown on Step 2.
  Widget _buildTransferPreview(ThemeData theme, ColorScheme cs) {
    final giver = _giverPot;
    final receiver = _receiverPot;
    if (giver == null || receiver == null) return const SizedBox.shrink();
    final giverAfter = _potValue(giver) - _amount;
    final receiverAfter = _potValue(receiver) + _amount;
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
          _buildAfterRow(theme, cs, giver.name, _potValue(giver), giverAfter),
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
            _potValue(receiver),
            receiverAfter,
          ),
        ],
      ),
    );
  }

  /// `potName    ₹current → ₹after` — showing both the current and
  /// resulting value (not just the after value) so the size of the
  /// change is clear at a glance, without having to mentally subtract
  /// against the header subtitle's current balance. Rendered as its own
  /// light "strip" (white fill + subtle shadow) so the name (left) and
  /// the value (right) read as a single grouped row rather than loose
  /// text floating on the card's own tinted background.
  Widget _buildAfterRow(
    ThemeData theme,
    ColorScheme cs,
    String potName,
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
              potName,
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

  /// Step 2's body: a sticky header (the resolved move + "ASSET
  /// BREAKDOWN" section label) above the full-height scrollable asset
  /// list — unchanged from the original single-screen list/fade/chevron
  /// mechanics, just no longer sharing the sheet with the mode selector
  /// and amount/pot card (those only live on Step 1 now).
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
                'ASSET BREAKDOWN',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: cs.primary,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Choose asset portions to transfer from',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 6),
              // The table header itself: the giver Pot's name takes the
              // place of a plain "Name" column label — reading as
              // "<Pot name> | Available | Transfer" — so the Pot the list
              // is broken down from is baked right into the table instead
              // of sitting in a separate sentence above it. Ellipsis-
              // truncated so a long name can't push the Available/Transfer
              // columns out of place; tapping it expands the name onto its
              // own wrapped line instead.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(
                  () => _giverPotNameExpanded = !_giverPotNameExpanded,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: ExpandableNameText(
                        _giverPot?.name ?? '',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: cs.onSurface,
                          fontWeight: FontWeight.w400,
                        ),
                        expanded: _giverPotNameExpanded,
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
                        for (final r in _assetRows)
                          _buildAssetRow(theme: theme, cs: cs, row: r),
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

  /// Builds `'Transferring ₹X from A to B'` as rich text — "Transferring"
  /// and the "from"/"to" connectors are plain (muted grey, regular
  /// weight), while the amount and both Pot names are bolded (amount in
  /// the base colour, Pot names in near-black), so the numbers and the two
  /// Pots involved are the only things that stand out, subtly, without
  /// pulling the eye away from the sheet's other (coloured) buttons/
  /// controls. Shared by Step 1's
  /// preview card and Step 2's headline so both screens read identically.
  /// Returns an empty [SizedBox] if shown before the move is fully
  /// resolved (shouldn't happen on Step 2, which requires exactly that to
  /// be reachable).
  Widget _buildTransferHeadline(
    ThemeData theme,
    ColorScheme cs, {
    required TextStyle? baseStyle,
  }) {
    final giver = _giverPot;
    final receiver = _receiverPot;
    if (giver == null || receiver == null) return const SizedBox.shrink();
    final keywordStyle = baseStyle?.copyWith(
      color: cs.onSurfaceVariant,
      fontWeight: FontWeight.w400,
    );
    final potNameStyle = baseStyle?.copyWith(
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
          TextSpan(text: giver.name, style: potNameStyle),
          const TextSpan(text: ' to '),
          TextSpan(text: receiver.name, style: potNameStyle),
        ],
      ),
    );
  }

  /// Sticky bottom CTA — "Next" (Step 1, just advances the view) or the
  /// remaining-indicator + actual "Transfer ₹X" submit button (Step 2).
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

  /// Single-line asset row: Name/Account  ₹Xk available  [field]  →
  ///
  /// The trailing arrow is always "outward" (→), regardless of mode —
  /// this breakdown is always built from the GIVER Pot's own holdings
  /// (this Pot for Send, the picked Pot for Receive / a receiving Adjust
  /// To), so every row always reads as "this amount leaves this holding,"
  /// never the other way round. Unlike the main field's [_arrowIcon]
  /// (which does flip to show the overall move's direction relative to
  /// THIS Pot), there's nothing direction-dependent to show here.
  Widget _buildAssetRow({
    required ThemeData theme,
    required ColorScheme cs,
    required _AssetRow row,
  }) {
    final error = _assetError(row);
    final isExpanded = _expandedAssetIds.contains(row.accountAssetId);
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
                      _expandedAssetIds.remove(row.accountAssetId);
                    } else {
                      _expandedAssetIds.add(row.accountAssetId);
                    }
                  }),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ExpandableNameText(
                        row.assetName,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                        expanded: isExpanded,
                      ),
                      Text(
                        row.accountName,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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

  /// Only shown when the breakdown is incomplete or over — the CTA button
  /// being enabled already signals the "fully allocated" state.
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
