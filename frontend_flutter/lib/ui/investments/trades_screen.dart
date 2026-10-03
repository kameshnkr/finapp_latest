import 'package:flutter/material.dart';

import 'add_trade_page.dart';
import 'labeled_trades_page.dart';
import 'unlabeled_trades_page.dart';

/// Investments' Trades screen — Add / Un-labeled / Labeled sub-tabs, pushed
/// from the Investments bottom nav ("Trades" → Un-labeled, "Add" → Add).
/// Independently structured from Banking's TransactionsScreen (no manual
/// entry mode — Investments trades only ever arrive via the two-file
/// upload flow), but mirrors its overall tabbed-screen shape.
class InvestmentsTradesScreen extends StatefulWidget {
  const InvestmentsTradesScreen({super.key, this.initialTab = 1});

  /// 0 = Add   1 = Un-labeled   2 = Labeled
  final int initialTab;

  @override
  State<InvestmentsTradesScreen> createState() => _InvestmentsTradesScreenState();
}

class _InvestmentsTradesScreenState extends State<InvestmentsTradesScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabCtrl;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 3, vsync: this, initialIndex: widget.initialTab.clamp(0, 2));
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trades'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: TabBar(
            controller: _tabCtrl,
            indicatorSize: TabBarIndicatorSize.tab,
            splashBorderRadius: BorderRadius.circular(8),
            tabs: const [
              Tab(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add_circle_outline_rounded, size: 15),
                    SizedBox(width: 6),
                    Text('Add'),
                  ],
                ),
              ),
              Tab(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.pending_actions_rounded, size: 15),
                    SizedBox(width: 6),
                    Text('Un-labeled'),
                  ],
                ),
              ),
              Tab(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.task_alt_rounded, size: 15),
                    SizedBox(width: 6),
                    Text('Labeled'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      body: SafeArea(
        child: TabBarView(
          controller: _tabCtrl,
          children: [
            AddTradePage(onUploadCompleted: () => _tabCtrl.animateTo(1)),
            const UnlabeledTradesPage(),
            const LabeledTradesPage(),
          ],
        ),
      ),
    );
  }
}
