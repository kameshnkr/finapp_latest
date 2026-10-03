import 'package:flutter/material.dart';

import 'pot_icons.dart';

/// Modal bottom sheet for picking one of the fixed Pot icons
/// ([kInvestmentsPotIcons]). Tapping an icon immediately pops the sheet with
/// that icon's key; dismissing without tapping one resolves to null (caller
/// treats null as "no change").
Future<String?> showPotIconPicker(
  BuildContext context, {
  required String currentIconKey,
}) {
  return showModalBottomSheet<String>(
    context: context,
    // Default (non-scroll-controlled) bottom sheets cap their height well
    // below the full screen, which isn't enough for a 26-icon grid — it
    // was overflowing. isScrollControlled lets it grow up to the
    // constraint below instead.
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _PotIconPickerSheet(currentIconKey: currentIconKey),
  );
}

class _PotIconPickerSheet extends StatelessWidget {
  const _PotIconPickerSheet({required this.currentIconKey});

  final String currentIconKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final entries = kInvestmentsPotIcons.entries.toList(growable: false);

    // Cap the sheet at 70% of the screen height — tall enough to show the
    // whole grid comfortably on most phones without covering the full
    // screen, but if a future, larger icon pool doesn't fit even then, the
    // SingleChildScrollView below lets it scroll instead of overflowing.
    final maxHeight = MediaQuery.of(context).size.height * 0.7;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Choose an icon',
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 16),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 5,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 1,
                ),
                itemCount: entries.length,
                itemBuilder: (context, i) {
                  final key = entries[i].key;
                  final icon = entries[i].value;
                  final selected = key == currentIconKey;
                  return InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => Navigator.of(context).pop(key),
                    child: Container(
                      decoration: BoxDecoration(
                        color: selected
                            ? cs.primary.withAlpha(40)
                            : cs.surfaceContainerHighest.withAlpha(120),
                        borderRadius: BorderRadius.circular(12),
                        border: selected ? Border.all(color: cs.primary, width: 2) : null,
                      ),
                      alignment: Alignment.center,
                      child: Icon(icon, size: 22, color: selected ? cs.primary : cs.onSurfaceVariant),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
