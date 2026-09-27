import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../state/investments_controller.dart';
import '../widgets/coming_soon_placeholder.dart';
import '../widgets/profile_view.dart';
import 'assets_tab.dart';
import 'pots_tab.dart';
import 'refresh_prices_action.dart';
import 'trades_screen.dart';

// ══════════════════════════════════════════════════════════════════════════════
// InvestmentsSectionRoot — fully independent section: owns its own bottom
// nav bar, nav-index state, and push targets. No code/state is shared with
// Banking's section beyond the [globalSwitcher] widget it's handed (built
// once by HomeScreen) and the app-level [onLogout] callback.
// ══════════════════════════════════════════════════════════════════════════════

class InvestmentsSectionRoot extends StatefulWidget {
  const InvestmentsSectionRoot({
    super.key,
    required this.globalSwitcher,
    required this.onLogout,
    required this.isActive,
  });

  /// Built once by HomeScreen (owns the Banking/Investments toggle state) and
  /// placed identically in both sections' Home AppBar.
  final Widget globalSwitcher;
  final VoidCallback onLogout;

  /// True only while this is the currently-visible top-level section.
  /// Used solely to lazily trigger the first data load the moment the user
  /// actually enters Investments — NOT on app start, since this widget is
  /// always built (kept alive) by HomeScreen's outer IndexedStack regardless
  /// of which section is currently shown.
  final bool isActive;

  @override
  State<InvestmentsSectionRoot> createState() => _InvestmentsSectionRootState();
}

class _InvestmentsSectionRootState extends State<InvestmentsSectionRoot>
    with TickerProviderStateMixin {
  /// 0 = Home  1 = Reports  2 = Profile
  int _navIndex = 0;

  late final TabController _homeSubTab; // Pots / Assets
  bool _hasLoadedOnce = false;

  @override
  void initState() {
    super.initState();
    _homeSubTab = TabController(length: 2, vsync: this);
    if (widget.isActive) _loadOnce();
  }

  @override
  void didUpdateWidget(covariant InvestmentsSectionRoot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isActive && widget.isActive) _loadOnce();
  }

  @override
  void dispose() {
    _homeSubTab.dispose();
    super.dispose();
  }

  void _loadOnce() {
    if (_hasLoadedOnce) return;
    _hasLoadedOnce = true;
    context.read<InvestmentsController>().loadHome();
  }

  // ── Navigation ────────────────────────────────────────────────────────────

  /// Bottom-nav has 5 visual buttons; index 2 is the centre + FAB.
  /// Logical page indices: 0=Home  1=Reports  2=Profile.
  /// Buttons 1 (Trades) and 2 (Add) push routes; they are never "active".
  void _onNavTap(int buttonIndex) {
    switch (buttonIndex) {
      case 0: // Home
        if (_navIndex != 0) setState(() => _navIndex = 0);
      case 1: // Trades — opens on the Un-labeled tab.
        Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const InvestmentsTradesScreen(initialTab: 1),
          ),
        );
      case 2: // Add — opens directly on the Add Trade tab.
        Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const InvestmentsTradesScreen(initialTab: 0),
          ),
        );
      case 3: // Reports
        if (_navIndex != 1) setState(() => _navIndex = 1);
      case 4: // Profile
        if (_navIndex != 2) setState(() => _navIndex = 2);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(),
      body: IndexedStack(
        index: _navIndex,
        children: [
          // ── 0: Home (Pots / Assets) ─────────────────────────────────
          TabBarView(
            controller: _homeSubTab,
            children: const [PotsTab(), AssetsTab()],
          ),
          // ── 1: Reports ──────────────────────────────────────────────
          const ComingSoonPlaceholder(
            icon: Icons.bar_chart_rounded,
            title: 'Reports',
            subtitle: 'Work in progress',
          ),
          // ── 2: Profile ──────────────────────────────────────────────
          ProfileView(onLogout: widget.onLogout),
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(4, 0, 4, 10),
        child: _InvestmentsBottomNavBar(
          currentPageIndex: _navIndex,
          onTap: _onNavTap,
        ),
      ),
    );
  }

  // ── AppBar factory ────────────────────────────────────────────────────────

  PreferredSizeWidget _buildAppBar() {
    if (_navIndex == 0) {
      return AppBar(
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: widget.globalSwitcher,
        ),
        centerTitle: false,
        actions: [
          const RefreshPricesAction(),
          IconButton(
            icon: const Icon(Icons.search_rounded),
            tooltip: 'Search',
            onPressed: () {},
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: TabBar(
            controller: _homeSubTab,
            indicatorSize: TabBarIndicatorSize.tab,
            splashBorderRadius: BorderRadius.circular(8),
            tabs: const [
              Tab(text: 'Pots'),
              Tab(text: 'Assets'),
            ],
          ),
        ),
      );
    }

    const titles = ['', 'Reports', 'Profile'];
    return AppBar(title: Text(titles[_navIndex]));
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Bottom Navigation Bar — Investments-owned copy (Home / Trades / Add /
// Reports / Profile). Visually mirrors Banking's bottom nav for consistency,
// but is an entirely independent widget so either section's nav can change
// without touching the other.
// ══════════════════════════════════════════════════════════════════════════════

class _InvestmentsBottomNavBar extends StatelessWidget {
  const _InvestmentsBottomNavBar({
    required this.currentPageIndex,
    required this.onTap,
  });

  final int currentPageIndex;
  final void Function(int) onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Page 0=Home→button 0, Page 1=Reports→button 3, Page 2=Profile→button 4
    // Buttons 1 (Trades) and 2 (Add) push routes and are never "active".
    final activeButton = switch (currentPageIndex) {
      0 => 0,
      1 => 3,
      2 => 4,
      _ => -1,
    };

    return Stack(
      clipBehavior: Clip.none, // allows the FAB to overflow above the bar
      alignment: Alignment.topCenter,
      children: [
        // ── Main bar ───────────────────────────────────────────────────
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppColors.cardBorder),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(18),
                blurRadius: 16,
                offset: const Offset(0, -3),
              ),
            ],
          ),
          height: 68,
          child: Row(
            children: [
              Expanded(
                child: _InvestmentsNavItem(
                  icon: Icons.home_rounded,
                  label: 'Home',
                  active: activeButton == 0,
                  onTap: () => onTap(0),
                ),
              ),
              Expanded(
                child: _InvestmentsNavItem(
                  icon: Icons.sync_alt_rounded,
                  label: 'Trades',
                  active: activeButton == 1,
                  onTap: () => onTap(1),
                ),
              ),
              // Spacer gap where the FAB floats above
              const SizedBox(width: 60),
              Expanded(
                child: _InvestmentsNavItem(
                  icon: Icons.bar_chart_rounded,
                  label: 'Reports',
                  active: activeButton == 3,
                  onTap: () => onTap(3),
                ),
              ),
              Expanded(
                child: _InvestmentsNavItem(
                  icon: Icons.person_outline_rounded,
                  label: 'Profile',
                  active: activeButton == 4,
                  onTap: () => onTap(4),
                ),
              ),
            ],
          ),
        ),

        // ── Popped-out centre FAB ──────────────────────────────────────
        Positioned(
          top: -22, // floats 22 px above the bar top edge
          left: 0,
          right: 0,
          child: Center(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => onTap(2),
                borderRadius: BorderRadius.circular(40),
                splashColor: Colors.white.withAlpha(50),
                highlightColor: Colors.white.withAlpha(30),
                hoverColor: Colors.white.withAlpha(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Color(0xFF5A9BFF), // light blue highlight
                            Color(0xFF1468F2), // primary blue #1468F2
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Color(0x661468F2),
                            blurRadius: 12,
                            offset: const Offset(0, 5),
                          ),
                        ],
                      ),
                      child: Icon(Icons.add, color: cs.onPrimary, size: 30),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Add',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: cs.onSurface.withOpacity(0.6),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _InvestmentsNavItem extends StatelessWidget {
  const _InvestmentsNavItem({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = active ? cs.primary : cs.onSurfaceVariant.withAlpha(160);

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        splashColor: cs.primary.withAlpha(30),
        highlightColor: cs.primary.withAlpha(20),
        hoverColor: cs.primary.withAlpha(15),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 22, color: color),
              const SizedBox(height: 3),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
