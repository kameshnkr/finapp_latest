import 'package:flutter/material.dart';

class AppNumpad extends StatelessWidget {
  const AppNumpad({
    super.key,
    required this.onKey,
    this.onBackspace,
  });

  final void Function(String key) onKey;
  final VoidCallback? onBackspace;

  static const _rows = [
    ['1', '2', '3'],
    ['4', '5', '6'],
    ['7', '8', '9'],
    ['.', '0', '⌫'],
  ];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: _rows
          .map(
            (row) => Row(
              children: row
                  .map(
                    (k) => Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: _NumKey(
                          label: k,
                          isBackspace: k == '⌫',
                          isSpecial: k == '.',
                          cs: cs,
                          onTap: () {
                            if (k == '⌫') {
                              onBackspace?.call();
                            } else {
                              onKey(k);
                            }
                          },
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          )
          .toList(),
    );
  }
}

class _NumKey extends StatelessWidget {
  const _NumKey({
    required this.label,
    required this.isBackspace,
    required this.isSpecial,
    required this.cs,
    required this.onTap,
  });

  final String label;
  final bool isBackspace;
  final bool isSpecial;
  final ColorScheme cs;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final bgColor = isBackspace
        ? cs.errorContainer.withAlpha(180)
        : isSpecial
            ? cs.surfaceContainerHigh
            : cs.surfaceContainerLowest;

    final textColor = isBackspace
        ? cs.onErrorContainer
        : isSpecial
            ? cs.onSurfaceVariant
            : cs.onSurface;

    return Material(
      color: bgColor,
      borderRadius: BorderRadius.circular(14),
      elevation: isBackspace ? 0 : 2,
      shadowColor: Colors.black.withAlpha(40),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: SizedBox(
          height: 46,
          child: Center(
            child: isBackspace
                ? Icon(Icons.backspace_outlined,
                    size: 18, color: textColor)
                : Text(
                    label,
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: textColor,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
