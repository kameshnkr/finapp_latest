import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../state/app_controller.dart';
import '../transactions/transaction_flow_screens.dart';
import 'budget_tab.dart';
import 'accounts_tab.dart';

// ══════════════════════════════════════════════════════════════════════════════
// HomeScreen — shell with Banking / Investments global switcher + bottom nav
// ══════════════════════════════════════════════════════════════════════════════

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  /// 0 = Home  1 = Reports  2 = Profile
  int _navIndex = 0;

  bool _isBanking = true;

  late final TabController _homeSubTab; // Budgets / Accounts

  @override
  void initState() {
    super.initState();
    _homeSubTab = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _homeSubTab.dispose();
    super.dispose();
  }

  // ── Navigation ────────────────────────────────────────────────────────────

  /// Bottom-nav has 5 visual buttons; index 2 is the centre + FAB.
  /// Logical page indices: 0=Home  1=Reports  2=Profile.
  /// Buttons 1 (Transactions) and 2 (+) push routes; they are never "active".
  void _onNavTap(int buttonIndex) {
    switch (buttonIndex) {
      case 0: // Home
        if (_navIndex != 0) setState(() => _navIndex = 0);
      case 1: // Transactions → opens on Drafts tab
        Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const TransactionsScreen(initialTab: 1),
          ),
        );
      case 2: // + → opens on Add Draft tab
        Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const TransactionsScreen(initialTab: 0),
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
    final app = context.watch<AppController>();
    final draftCount = app.drafts.length;

    return Scaffold(
      appBar: _buildAppBar(app, draftCount),
      body: IndexedStack(
        index: _navIndex,
        children: [
          // ── 0: Home (Banking ↔ Investments) ─────────────────────────────
          _HomeContentView(
            isBanking: _isBanking,
            homeSubTab: _homeSubTab,
          ),
          // ── 1: Reports ────────────────────────────────────────────────
          const _ReportsPlaceholder(),
          // ── 2: Profile ────────────────────────────────────────────────
          _ProfileView(onLogout: () async => app.logout()),
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(4, 0, 4, 10),
        child: _BottomNavBar(
          currentPageIndex: _navIndex,
          draftCount: draftCount,
          onTap: _onNavTap,
        ),
      ),
    );
  }

  // ── AppBar factory ────────────────────────────────────────────────────────

  PreferredSizeWidget _buildAppBar(AppController app, int draftCount) {
    if (_navIndex == 0) {
      return AppBar(
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _GlobalSwitcher(
            isBanking: _isBanking,
            onChanged: (v) => setState(() => _isBanking = v),
          ),
        ),
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.search_rounded),
            tooltip: 'Search',
            onPressed: () {},
          ),
        ],
        bottom: _isBanking
            ? PreferredSize(
                preferredSize: const Size.fromHeight(48),
                child: TabBar(
                  controller: _homeSubTab,
                  indicatorSize: TabBarIndicatorSize.tab,
                  splashBorderRadius: BorderRadius.circular(8),
                  tabs: const [
                    Tab(text: 'Budgets'),
                    Tab(text: 'Accounts'),
                  ],
                ),
              )
            : null,
      );
    }

    // Reports / Profile
    const titles = ['', 'Reports', 'Profile'];
    return AppBar(title: Text(titles[_navIndex]));
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Global Banking / Investments Switcher
// ══════════════════════════════════════════════════════════════════════════════

class _GlobalSwitcher extends StatelessWidget {
  const _GlobalSwitcher({
    required this.isBanking,
    required this.onChanged,
  });

  final bool isBanking;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withAlpha(180),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SwitcherPill(
            icon: Icons.account_balance_rounded,
            label: 'Banking',
            active: isBanking,
            onTap: () => onChanged(true),
          ),
          _SwitcherPill(
            icon: Icons.bar_chart_rounded,
            label: 'Investments',
            active: !isBanking,
            onTap: () => onChanged(false),
          ),
        ],
      ),
    );
  }
}

class _SwitcherPill extends StatelessWidget {
  const _SwitcherPill({
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

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: active ? cs.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          boxShadow: active
              ? [
                  BoxShadow(
                    color: cs.primary.withAlpha(50),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
              : [],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 15,
              color: active ? cs.onPrimary : cs.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                color: active ? cs.onPrimary : cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Bottom Navigation Bar
// ══════════════════════════════════════════════════════════════════════════════

class _BottomNavBar extends StatelessWidget {
  const _BottomNavBar({
    required this.currentPageIndex,
    required this.draftCount,
    required this.onTap,
  });

  final int currentPageIndex;
  final int draftCount;
  final void Function(int) onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Page 0=Home→button 0, Page 1=Reports→button 3, Page 2=Profile→button 4
    // Buttons 1 (Transactions) and 2 (+) push routes and are never "active".
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
                child: _NavItem(
                  icon: Icons.home_rounded,
                  label: 'Home',
                  active: activeButton == 0,
                  onTap: () => onTap(0),
                ),
              ),
              Expanded(
                child: _NavItem(
                  icon: Icons.receipt_long_rounded,
                  label: 'Transactions',
                  active: activeButton == 1,
                  badgeCount: draftCount,
                  onTap: () => onTap(1),
                ),
              ),
              // Spacer gap where the FAB floats above
              const SizedBox(width: 60),
              Expanded(
                child: _NavItem(
                  icon: Icons.bar_chart_rounded,
                  label: 'Reports',
                  active: activeButton == 3,
                  onTap: () => onTap(3),
                ),
              ),
              Expanded(
                child: _NavItem(
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

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    this.badgeCount = 0,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  final int badgeCount;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color =
        active ? cs.primary : cs.onSurfaceVariant.withAlpha(160);

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
              Badge(
                isLabelVisible: badgeCount > 0,
                offset: const Offset(8, -4),
                label: Text(
                  badgeCount > 50 ? '50+' : '$badgeCount',
                  style: const TextStyle(fontSize: 9),
                ),
                child: Icon(icon, size: 22, color: color),
              ),
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

// ══════════════════════════════════════════════════════════════════════════════
// Home content view  (Banking tabs OR Investments placeholder)
// ══════════════════════════════════════════════════════════════════════════════

class _HomeContentView extends StatelessWidget {
  const _HomeContentView({
    required this.isBanking,
    required this.homeSubTab,
  });

  final bool isBanking;
  final TabController homeSubTab;

  @override
  Widget build(BuildContext context) {
    return IndexedStack(
      index: isBanking ? 0 : 1,
      children: [
        TabBarView(
          controller: homeSubTab,
          children: const [BudgetTab(), AccountsTab()],
        ),
        const _InvestmentsPlaceholder(),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Investments Placeholder
// ══════════════════════════════════════════════════════════════════════════════

class _InvestmentsPlaceholder extends StatelessWidget {
  const _InvestmentsPlaceholder();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: cs.primaryContainer.withAlpha(80),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.trending_up_rounded,
              size: 42,
              color: cs.primary,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            'Investments',
            style: tt.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Coming soon',
            style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Reports Placeholder
// ══════════════════════════════════════════════════════════════════════════════

class _ReportsPlaceholder extends StatelessWidget {
  const _ReportsPlaceholder();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: cs.primaryContainer.withAlpha(80),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.bar_chart_rounded, size: 42, color: cs.primary),
          ),
          const SizedBox(height: 18),
          Text(
            'Reports',
            style: tt.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Work in progress',
            style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// Profile View
// ══════════════════════════════════════════════════════════════════════════════

class _ProfileView extends StatelessWidget {
  const _ProfileView({required this.onLogout});

  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
      children: [
        // Avatar + name
        Center(
          child: Column(
            children: [
              CircleAvatar(
                radius: 38,
                backgroundColor: cs.primaryContainer,
                child: Icon(
                  Icons.person_rounded,
                  size: 38,
                  color: cs.primary,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'My Profile',
                style: tt.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 28),
            ],
          ),
        ),
        _ProfileItem(
          icon: Icons.person_outline_rounded,
          label: 'Profile',
          onTap: () {},
        ),

        _ProfileItem(
          icon: Icons.settings_outlined,
          label: 'Settings',
          onTap: () {},
        ),
        const SizedBox(height: 8),
        _ProfileItem(
          icon: Icons.logout_rounded,
          label: 'Logout',
          color: cs.error,
          onTap: onLogout,
        ),
      ],
    );
  }
}

class _ProfileItem extends StatelessWidget {
  const _ProfileItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final effectiveColor = color ?? cs.onSurface;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.md),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          child: Row(
            children: [
              Icon(icon, size: 20, color: effectiveColor),
              const SizedBox(width: 14),
              Text(
                label,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w500,
                      color: effectiveColor,
                    ),
              ),
              const Spacer(),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: cs.outlineVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

