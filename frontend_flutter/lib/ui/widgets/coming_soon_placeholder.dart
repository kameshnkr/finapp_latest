import 'package:flutter/material.dart';

/// Generic centered icon + title + subtitle placeholder. Extracted (no
/// behavior change) from what were previously private, duplicated
/// `_ReportsPlaceholder`/`_InvestmentsPlaceholder` widgets in
/// `home_screen.dart` — shared shell-level UI, not owned by either the
/// Banking or Investments section.
class ComingSoonPlaceholder extends StatelessWidget {
  const ComingSoonPlaceholder({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle = 'Coming soon',
  });

  final IconData icon;
  final String title;
  final String subtitle;

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
            child: Icon(icon, size: 42, color: cs.primary),
          ),
          const SizedBox(height: 18),
          Text(
            title,
            style: tt.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
