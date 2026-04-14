import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_controller.dart';
import 'add_draft_page.dart';
import 'drafts_page.dart';
import 'settled_page.dart';
import 'statement_upload_page.dart';

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
  bool _isStatement = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _ModeToggle(
          isStatement: _isStatement,
          onChanged: (v) => setState(() => _isStatement = v),
        ),
        bottom: const _LoadingBar(),
      ),
      body: SafeArea(
        child: _isStatement
            ? const StatementUploadPage()
            : const AddDraftPage(),
      ),
    );
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
