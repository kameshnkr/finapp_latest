import 'package:flutter/material.dart';

class SelectionList extends StatelessWidget {
  const SelectionList({
    super.key,
    required this.items,
    required this.onSelect,
  });

  final List<String> items;
  final void Function(int index, String label) onSelect;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: items.length,
      separatorBuilder: (context, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final label = items[i];
        return Material(
          elevation: 3,
          shadowColor: Colors.black26,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => onSelect(i, label),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
              child: Text(label, style: Theme.of(context).textTheme.titleMedium),
            ),
          ),
        );
      },
    );
  }
}
