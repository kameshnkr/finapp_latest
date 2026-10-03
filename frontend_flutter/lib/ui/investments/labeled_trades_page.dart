import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../data/models/investments_models.dart';
import '../../state/investments_controller.dart';
import '../../utils/amount_formatter.dart';
import 'trade_list_tile.dart';

/// Labeled trades — every trade with allocation_status = ALLOCATED. Kept
/// compact by default; tapping a row expands it in place to reveal its Pot
/// allocation breakdown (Pot / Allocation % / Allocated Units / Allocated
/// Amount — the last derived client-side as allocatedUnits × trade.price,
/// since the backend never persists a per-allocation amount).
class LabeledTradesPage extends StatefulWidget {
  const LabeledTradesPage({super.key});

  @override
  State<LabeledTradesPage> createState() => _LabeledTradesPageState();
}

class _LabeledTradesPageState extends State<LabeledTradesPage> {
  final List<InvestmentsTradeDto> _trades = [];
  String? _cursor;
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  final Set<String> _expanded = {};
  final ScrollController _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    final pos = _scrollCtrl.position;
    if (pos.pixels >= pos.maxScrollExtent - 200) _loadMore();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = context.read<InvestmentsController>().api;
      final page = await api.fetchLabeledTrades();
      if (!mounted) return;
      setState(() {
        _trades
          ..clear()
          ..addAll(page.trades);
        _cursor = page.nextCursor;
        _hasMore = page.hasMore;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _cursor == null) return;
    setState(() => _loadingMore = true);
    try {
      final api = context.read<InvestmentsController>().api;
      final page = await api.fetchLabeledTrades(cursor: _cursor);
      if (!mounted) return;
      setState(() {
        _trades.addAll(page.trades);
        _cursor = page.nextCursor;
        _hasMore = page.hasMore;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 40, color: cs.error),
              const SizedBox(height: 10),
              Text('Error: $_error', textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    if (_trades.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.task_alt_rounded, size: 48, color: cs.onSurfaceVariant.withAlpha(100)),
            const SizedBox(height: 10),
            Text('No labeled trades yet', style: TextStyle(color: cs.onSurfaceVariant, fontWeight: FontWeight.w500)),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: _scrollCtrl,
      padding: AppInsets.screen,
      itemCount: _trades.length + (_loadingMore ? 1 : 0),
      itemBuilder: (context, i) {
        if (i >= _trades.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
          );
        }
        final t = _trades[i];
        final isExpanded = _expanded.contains(t.id);
        return TradeListTile(
          trade: t,
          onTap: () => setState(() {
            if (isExpanded) {
              _expanded.remove(t.id);
            } else {
              _expanded.add(t.id);
            }
          }),
          trailing: isExpanded ? _AllocationDetail(trade: t) : null,
          expanded: isExpanded,
        );
      },
    );
  }
}

class _AllocationDetail extends StatelessWidget {
  const _AllocationDetail({required this.trade});
  final InvestmentsTradeDto trade;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final price = double.tryParse(trade.price) ?? 0;

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Divider(height: 1, color: cs.outlineVariant),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                  child: Text('Pot',
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w700))),
              SizedBox(
                  width: 52,
                  child: Text('%',
                      textAlign: TextAlign.right,
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w700))),
              SizedBox(
                  width: 70,
                  child: Text('Units',
                      textAlign: TextAlign.right,
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w700))),
              SizedBox(
                  width: 84,
                  child: Text('Amount',
                      textAlign: TextAlign.right,
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w700))),
            ],
          ),
          const SizedBox(height: 6),
          for (final alloc in trade.potAllocations) _AllocationRow(allocation: alloc, price: price),
        ],
      ),
    );
  }
}

class _AllocationRow extends StatelessWidget {
  const _AllocationRow({required this.allocation, required this.price});
  final InvestmentsTradeAllocationDto allocation;
  final double price;

  @override
  Widget build(BuildContext context) {
    final pct = double.tryParse(allocation.percentage) ?? 0;
    final units = double.tryParse(allocation.allocatedUnits) ?? 0;
    final amount = units * price;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
              child: Text(allocation.potName,
                  style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis)),
          SizedBox(width: 52, child: Text('${pct.toStringAsFixed(0)}%', textAlign: TextAlign.right, style: const TextStyle(fontSize: 13))),
          SizedBox(width: 70, child: Text(units.toStringAsFixed(2), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13))),
          SizedBox(
              width: 84,
              child: Text('₹${compactAmount(amount)}',
                  textAlign: TextAlign.right, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }
}
