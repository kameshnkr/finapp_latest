import 'package:flutter/material.dart';

class AppTextpad extends StatelessWidget {
  const AppTextpad({
    super.key,
    required this.onChar,
    required this.onBackspace,
    required this.onGo,
  });

  final void Function(String ch) onChar;
  final VoidCallback onBackspace;
  final VoidCallback onGo;

  static const _rows = [
    ['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p'],
    ['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l'],
    ['z', 'x', 'c', 'v', 'b', 'n', 'm', ' '],
  ];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ..._rows.map(
          (row) => Padding(
            padding: const EdgeInsets.only(bottom: 5),
            child: Row(
              children: row
                  .map(
                    (c) => Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Material(
                          color: cs.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: () => onChar(c),
                            child: SizedBox(
                              height: 38,
                              child: Center(
                                child: Text(
                                  c == ' ' ? '␣' : c,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: cs.onSurface,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            Material(
              color: cs.errorContainer.withAlpha(160),
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: onBackspace,
                child: const SizedBox(
                  width: 52,
                  height: 44,
                  child: Center(
                    child: Icon(Icons.backspace_outlined, size: 18),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                onPressed: onGo,
                icon: const Icon(Icons.check_rounded, size: 18),
                label: const Text('Save Draft'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
