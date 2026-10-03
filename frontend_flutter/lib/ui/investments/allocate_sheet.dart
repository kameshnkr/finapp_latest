import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../data/models/investments_models.dart';
import '../../state/investments_controller.dart';
import '../../utils/api_error_utils.dart';

/// Opens the Pot-allocation flow for [trades] and returns the set of
/// transaction ids that were successfully labeled, or null if the user
/// cancelled without labeling anything.
///
/// Supports exactly the 3 flows the spec allows (server-side enforces the
/// same rules — this is a UX convenience, not the source of truth):
///   1. N trades → 1 Pot     (100% each)
///   2. 1 trade  → 1 Pot     (100%)
///   3. 1 trade  → N Pots    (percentages summing to 100)
/// "N trades → N Pots" is never offered — "Allocate to Multiple Pots" is
/// shown disabled with an explanatory caption whenever trades.length > 1.
Future<Set<String>?> showAllocateSheet(
  BuildContext context, {
  required List<InvestmentsTradeDto> trades,
}) {
  return showModalBottomSheet<Set<String>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _AllocateSheet(trades: trades),
  );
}

enum _Step { chooseMode, singlePot, multiPot }

class _AllocateSheet extends StatefulWidget {
  const _AllocateSheet({required this.trades});
  final List<InvestmentsTradeDto> trades;

  @override
  State<_AllocateSheet> createState() => _AllocateSheetState();
}

class _AllocateSheetState extends State<_AllocateSheet> {
  _Step _step = _Step.chooseMode;
  bool _submitting = false;
  String? _error;

  // Single-pot mode
  String? _selectedPotId;

  // Multi-pot mode (single trade only)
  final Map<String, double> _percentages = {}; // potId -> %

  bool get _isMultiTrade => widget.trades.length > 1;

  double get _percentageSum => _percentages.values.fold(0.0, (a, b) => a + b);

  Future<void> _submitSinglePot(String potId) async {
    setState(() {
      _submitting = true;
      _error = null;
      _selectedPotId = potId;
    });
    try {
      final controller = context.read<InvestmentsController>();
      await controller.api.allocateTrades(
        transactionIds: widget.trades.map((t) => t.id).toList(),
        allocations: [(potId: potId, percentage: 100.0)],
      );
      if (!mounted) return;
      Navigator.of(context).pop(widget.trades.map((t) => t.id).toSet());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = friendlyApiError(e);
      });
    }
  }

  Future<void> _submitMultiPot() async {
    final entries = _percentages.entries.where((e) => e.value > 0).toList();
    if (entries.isEmpty) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final controller = context.read<InvestmentsController>();
      await controller.api.allocateTrades(
        transactionIds: [widget.trades.single.id],
        allocations: entries.map((e) => (potId: e.key, percentage: e.value)).toList(),
      );
      if (!mounted) return;
      Navigator.of(context).pop({widget.trades.single.id});
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = friendlyApiError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 4, 20, MediaQuery.of(context).viewInsets.bottom + 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_step != _Step.chooseMode)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _submitting
                    ? null
                    : () => setState(() {
                          _step = _Step.chooseMode;
                          _error = null;
                        }),
                icon: const Icon(Icons.arrow_back_rounded, size: 16),
                label: const Text('Back'),
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: EdgeInsets.zero),
              ),
            ),
          Text(
            widget.trades.length == 1
                ? 'Allocate ${widget.trades.single.assetName}'
                : 'Allocate ${widget.trades.length} trades',
            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          if (_error != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer.withAlpha(70),
                borderRadius: BorderRadius.circular(AppRadii.sm),
              ),
              child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 13)),
            ),
            const SizedBox(height: 12),
          ],
          switch (_step) {
            _Step.chooseMode => _buildChooseMode(),
            _Step.singlePot => _buildSinglePot(),
            _Step.multiPot => _buildMultiPot(),
          },
        ],
      ),
    );
  }

  Widget _buildChooseMode() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ModeCard(
          icon: Icons.savings_rounded,
          title: 'Allocate to Single Pot',
          subtitle: 'Assign the full trade to one Pot',
          enabled: true,
          onTap: () => setState(() => _step = _Step.singlePot),
        ),
        const SizedBox(height: 10),
        _ModeCard(
          icon: Icons.pie_chart_rounded,
          title: 'Allocate to Multiple Pots',
          subtitle: 'Split by percentage across several Pots',
          enabled: !_isMultiTrade,
          onTap: () => setState(() => _step = _Step.multiPot),
        ),
        if (_isMultiTrade) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              'To allocate a trade to multiple Pots, select a single trade.',
              style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSinglePot() {
    final pots = context.watch<InvestmentsController>().portfolio?.pots ?? const <InvestmentsPotDto>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final p in pots)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _PotTile(
              pot: p,
              selected: _selectedPotId == p.id,
              loading: _submitting && _selectedPotId == p.id,
              enabled: !_submitting,
              onTap: () => _submitSinglePot(p.id),
            ),
          ),
        if (pots.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text('No Pots available.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
      ],
    );
  }

  Widget _buildMultiPot() {
    final pots = context.watch<InvestmentsController>().portfolio?.pots ?? const <InvestmentsPotDto>[];
    final sum = _percentageSum;
    final remaining = 100 - sum;
    final canConfirm = !_submitting && (remaining).abs() < 0.01 && sum > 0;
    final cs = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final p in pots)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _PercentageRow(
              potName: p.name,
              value: _percentages[p.id] ?? 0,
              onChanged: (v) => setState(() => _percentages[p.id] = v),
            ),
          ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text('Total: ${sum.toStringAsFixed(0)}%',
                style: TextStyle(fontWeight: FontWeight.w700, color: remaining.abs() < 0.01 ? AppColors.gain : cs.onSurface)),
            const Spacer(),
            Text(
              remaining.abs() < 0.01 ? 'Ready to confirm' : 'Remaining: ${remaining.toStringAsFixed(0)}%',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: 14),
        FilledButton(
          onPressed: canConfirm ? _submitMultiPot : null,
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.md)),
          ),
          child: _submitting
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Confirm Allocation'),
        ),
      ],
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Material(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadii.md),
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(AppRadii.md),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadii.md),
              border: Border.all(color: AppColors.cardBorder),
            ),
            child: Row(
              children: [
                Icon(icon, color: cs.primary, size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      Text(subtitle, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                    ],
                  ),
                ),
                if (enabled) Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PotTile extends StatelessWidget {
  const _PotTile({
    required this.pot,
    required this.selected,
    required this.loading,
    required this.enabled,
    required this.onTap,
  });

  final InvestmentsPotDto pot;
  final bool selected;
  final bool loading;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: selected ? cs.primaryContainer.withAlpha(80) : cs.surfaceContainerLow,
      borderRadius: BorderRadius.circular(AppRadii.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.md),
        onTap: enabled ? onTap : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.md),
            border: Border.all(color: selected ? cs.primary.withAlpha(100) : AppColors.cardBorder),
          ),
          child: Row(
            children: [
              Expanded(child: Text(pot.name, style: const TextStyle(fontWeight: FontWeight.w600))),
              if (loading)
                const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              else
                Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _PercentageRow extends StatefulWidget {
  const _PercentageRow({required this.potName, required this.value, required this.onChanged});
  final String potName;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  State<_PercentageRow> createState() => _PercentageRowState();
}

class _PercentageRowState extends State<_PercentageRow> {
  late final _ctrl = TextEditingController(text: widget.value == 0 ? '' : widget.value.toStringAsFixed(0));

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(widget.potName, style: const TextStyle(fontWeight: FontWeight.w500))),
        SizedBox(
          width: 84,
          child: TextField(
            controller: _ctrl,
            textAlign: TextAlign.right,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              suffixText: '%',
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            ),
            onChanged: (s) => widget.onChanged(double.tryParse(s) ?? 0),
          ),
        ),
      ],
    );
  }
}
