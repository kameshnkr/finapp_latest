import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_controller.dart';
import 'add_draft_page.dart';
import 'drafts_page.dart';
import 'settled_page.dart';
import 'statement_upload_page.dart';

// ══════════════════════════════════════════════════════════════════════════════
// Unified Transactions Screen  (Add Draft › Drafts › Settled)
// ══════════════════════════════════════════════════════════════════════════════

class TransactionsScreen extends StatefulWidget {
  const TransactionsScreen({super.key, this.initialTab = 1});

  /// 0 = Add Draft   1 = Drafts   2 = Settled
  final int initialTab;

  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends State<TransactionsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(
      length: 3,
      vsync: this,
      initialIndex: widget.initialTab.clamp(0, 2),
    );
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final draftCount = context.watch<AppController>().drafts.length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Transactions'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48 + 3),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TabBar(
                controller: _tabCtrl,
                indicatorSize: TabBarIndicatorSize.tab,
                splashBorderRadius: BorderRadius.circular(8),
                tabs: [
                  // ── 0: Add Draft ──────────────────────────────────────
                  const Tab(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.add_circle_outline_rounded, size: 15),
                        SizedBox(width: 6),
                        Text('Add Draft'),
                      ],
                    ),
                  ),
                  // ── 1: Drafts ─────────────────────────────────────────
                  Tab(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.pending_actions_rounded, size: 15),
                        const SizedBox(width: 6),
                        const Text('Drafts'),
                        if (draftCount > 0) ...[
                          const SizedBox(width: 5),
                          _CountChip(draftCount),
                        ],
                      ],
                    ),
                  ),
                  // ── 2: Settled ────────────────────────────────────────
                  const Tab(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.task_alt_rounded, size: 15),
                        SizedBox(width: 6),
                        Text('Settled'),
                      ],
                    ),
                  ),
                ],
              ),
              const _LoadingBar(),
            ],
          ),
        ),
      ),
      body: SafeArea(
        child: TabBarView(
          controller: _tabCtrl,
          children: const [
            _AddDraftContent(),
            DraftsPage(),
            SettledPage(),
          ],
        ),
      ),
    );
  }
}

// ── Add Draft tab content  (Manual / Statement toggle + page) ─────────────────

class _AddDraftContent extends StatefulWidget {
  const _AddDraftContent();

  @override
  State<_AddDraftContent> createState() => _AddDraftContentState();
}

class _AddDraftContentState extends State<_AddDraftContent> {
  bool _isStatement = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Toggle constrained to hug its own content width (not full row)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 28, 16, 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ModeToggle(
                isStatement: _isStatement,
                onChanged: (v) => setState(() => _isStatement = v),
              ),
            ],
          ),
        ),
        Expanded(
          child: _isStatement
              ? const StatementUploadPage()
              : const AddDraftPage(),
        ),
      ],
    );
  }
}


/// Thin top-of-screen loading bar driven by AppController.loading.
class _LoadingBar extends StatelessWidget implements PreferredSizeWidget {
  const _LoadingBar();

  @override
  Size get preferredSize => const Size.fromHeight(3);

  @override
  Widget build(BuildContext context) {
    final loading = context.select<AppController, bool>((a) => a.loading);
    return loading
        ? const LinearProgressIndicator(minHeight: 3)
        : const SizedBox.shrink();
  }
}

class DraftsFlowScreen extends StatelessWidget {
  const DraftsFlowScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Drafts'),
        bottom: const _LoadingBar(),
      ),
      body: const SafeArea(child: DraftsPage()),
    );
  }
}

class AddDraftFlowScreen extends StatefulWidget {
  const AddDraftFlowScreen({super.key});

  @override
  State<AddDraftFlowScreen> createState() => _AddDraftFlowScreenState();
}

class _AddDraftFlowScreenState extends State<AddDraftFlowScreen> {
  @override
  Widget build(BuildContext context) {
    // Delegates to TransactionsScreen landing on the Add Draft tab.
    return const TransactionsScreen(initialTab: 0);
  }
}

// ── Mode toggle (Manual / Statement) ─────────────────────────────────────────

class _ModeToggle extends StatelessWidget {
  const _ModeToggle({required this.isStatement, required this.onChanged});

  final bool isStatement;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      height: 34,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Tab(
            label: 'Manual',
            icon: Icons.edit_outlined,
            active: !isStatement,
            onTap: () => onChanged(false),
          ),
          _Tab(
            label: 'Statement',
            icon: Icons.upload_file_outlined,
            active: isStatement,
            onTap: () => onChanged(true),
          ),
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeInOut,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? cs.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: active ? cs.onPrimary : cs.onSurfaceVariant,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: active ? cs.onPrimary : cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class StatementUploadFlowScreen extends StatelessWidget {
  const StatementUploadFlowScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Upload Statement'),
        bottom: const _LoadingBar(),
      ),
      body: const SafeArea(child: StatementUploadPage()),
    );
  }
}

class SettledFlowScreen extends StatelessWidget {
  const SettledFlowScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settled'),
        bottom: const _LoadingBar(),
      ),
      body: const SafeArea(child: SettledPage()),
    );
  }
}

class _CountChip extends StatelessWidget {
  const _CountChip(this.count);
  final int count;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: cs.error,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        count > 50 ? '50+' : '$count',
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: cs.onError,
        ),
      ),
    );
  }
}
