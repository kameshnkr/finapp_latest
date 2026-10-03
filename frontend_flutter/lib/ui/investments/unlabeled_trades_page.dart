import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../core/snack_utils.dart';
import '../../data/models/investments_models.dart';
import '../../state/investments_controller.dart';
import 'allocate_sheet.dart';
import 'trade_list_tile.dart';

/// Un-labeled trades — every trade with allocation_status = UNALLOCATED.
///
/// Two entry points into labeling, mirroring the spec's literal bottom
/// controls:
///   - Tap any row directly → it becomes the single "active" trade; the
///     "Label Single Trade" bar button opens the allocate sheet for just it.
///   - "Label Multiple Trades" switches into an explicit multi-select mode
///     (checkboxes, Banking-style); the resulting bar button opens the same
///     allocate sheet for every checked trade.
/// Either way, the sheet itself decides which allocation options are legal
/// purely from `selected.length` — so a multi-select of exactly one trade
/// still offers "Allocate to Multiple Pots", matching the spec's rule that
/// the option set depends on *how many trades ended up selected*, not on
/// which button was used to select them.
class UnlabeledTradesPage extends StatefulWidget {
  const UnlabeledTradesPage({super.key});

  @override
  State<UnlabeledTradesPage> createState() => _UnlabeledTradesPageState();
}

class _UnlabeledTradesPageState extends State<UnlabeledTradesPage> {
  final List<InvestmentsTradeDto> _trades = [];
  String? _cursor;
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  bool _selectMode = false;
  final Set<String> _selected = {};
  String? _activeId; // single-select (non-multi-select mode) target

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
      final page = await api.fetchUnlabeledTrades();
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
      final page = await api.fetchUnlabeledTrades(cursor: _cursor);
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

  void _removeLabeled(Set<String> ids) {
    setState(() {
      _trades.removeWhere((t) => ids.contains(t.id));
      _selected.removeAll(ids);
      _activeId = null;
      _selectMode = false;
    });
  }

  Future<void> _openAllocate(List<InvestmentsTradeDto> selected) async {
    if (selected.isEmpty) return;
    final controller = context.read<InvestmentsController>();
    final labeledIds = await showAllocateSheet(context, trades: selected);
    if (!mounted) return;
    if (labeledIds != null && labeledIds.isNotEmpty) {
      _removeLabeled(labeledIds);
      showTopSnack(context, 'Labeled ${labeledIds.length} trade(s)');
      await controller.refreshHome();
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

    InvestmentsTradeDto? activeTrade;
    if (_activeId != null) {
      for (final t in _trades) {
        if (t.id == _activeId) {
          activeTrade = t;
          break;
        }
      }
    }
    final selectedTrades = _trades.where((t) => _selected.contains(t.id)).toList();

    return Column(
      children: [
        if (_selectMode)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: [
                Text('${_selected.length} selected',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                TextButton(
                  onPressed: () => setState(() {
                    _selectMode = false;
                    _selected.clear();
                  }),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
        Expanded(
          child: _trades.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.inbox_outlined, size: 48, color: cs.onSurfaceVariant.withAlpha(100)),
                      const SizedBox(height: 10),
                      Text('No unlabeled trades',
                          style: TextStyle(color: cs.onSurfaceVariant, fontWeight: FontWeight.w500)),
                    ],
                  ),
                )
              : ListView.builder(
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
                    final isSelected = _selected.contains(t.id);
                    final isActive = t.id == _activeId;
                    return TradeListTile(
                      trade: t,
                      selectMode: _selectMode,
                      selected: isSelected,
                      highlighted: !_selectMode && isActive,
                      onTap: () => setState(() {
                        if (_selectMode) {
                          if (isSelected) {
                            _selected.remove(t.id);
                          } else {
                            _selected.add(t.id);
                          }
                        } else {
                          _activeId = isActive ? null : t.id;
                        }
                      }),
                    );
                  },
                ),
        ),
        // ── Bottom controls ──────────────────────────────────────────────
        SafeArea(
          minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: _selectMode
              ? SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: selectedTrades.isEmpty ? null : () => _openAllocate(selectedTrades),
                    icon: const Icon(Icons.label_outline_rounded, size: 18),
                    label: Text('Label Selected (${selectedTrades.length})'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.md)),
                    ),
                  ),
                )
              : Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: activeTrade == null ? null : () => _openAllocate([activeTrade!]),
                        icon: const Icon(Icons.label_outline_rounded, size: 17),
                        label: const Text('Label Single Trade'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 48),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.md)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _trades.isEmpty
                            ? null
                            : () => setState(() {
                                  _selectMode = true;
                                  _activeId = null;
                                }),
                        icon: const Icon(Icons.checklist_rounded, size: 17),
                        label: const Text('Label Multiple Trades'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 48),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.md)),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}
