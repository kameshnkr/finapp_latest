import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_controller.dart';

/// Compact horizontal date-range selector.
///
/// Presets (30D / 90D / 1Y) apply immediately.
/// The custom chip opens a bottom-sheet date picker with an
/// "Apply" button at the bottom-right for easy mobile access.
class DateFilterBar extends StatelessWidget {
  const DateFilterBar({super.key});

  static const _presets = [
    (label: '30D', days: 30),
    (label: '90D', days: 90),
    (label: '1Y', days: 365),
  ];

  bool _isPreset(DateTime from, DateTime to, int days) {
    final expected = to.subtract(Duration(days: days));
    return expected.difference(from).abs() < const Duration(hours: 2);
  }

  String _formatRange(DateTime fromUtc, DateTime toUtc) {
    final f = fromUtc.toLocal();
    final t = toUtc.toLocal();
    const m = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final fromStr = f.year == t.year
        ? '${f.day} ${m[f.month - 1]}'
        : '${f.day} ${m[f.month - 1]} ${f.year}';
    final toStr = '${t.day} ${m[t.month - 1]} ${t.year}';
    return '$fromStr – $toStr';
  }

  Future<void> _pickCustomRange(BuildContext context, AppController app) async {
    final result = await showModalBottomSheet<DateTimeRange>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _DateRangeSheet(
        initialFrom: app.rangeFrom.toLocal(),
        initialTo: app.rangeTo.toLocal(),
      ),
    );
    if (result != null) {
      final newTo = DateTime(
        result.end.year, result.end.month, result.end.day, 23, 59, 59,
      ).toUtc();
      app.setDateRange(result.start.toUtc(), newTo);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final from = app.rangeFrom;
    final to = app.rangeTo;
    final anyPreset = _presets.any((p) => _isPreset(from, to, p.days));

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      child: Row(
        children: [
          ..._presets.map((p) {
            final active = _isPreset(from, to, p.days);
            return Padding(
              padding: const EdgeInsets.only(right: 6),
              child: FilterChip(
                label: Text(p.label),
                selected: active,
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                onSelected: (_) {
                  final newTo = DateTime.now().toUtc();
                  final newFrom = newTo.subtract(Duration(days: p.days));
                  app.setDateRange(newFrom, newTo);
                },
              ),
            );
          }),
          FilterChip(
            avatar: const Icon(Icons.calendar_month_outlined, size: 14),
            label: Text(anyPreset ? 'Custom' : _formatRange(from, to)),
            selected: !anyPreset,
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            onSelected: (_) => _pickCustomRange(context, app),
          ),
        ],
      ),
    );
  }
}

// ── Custom date-range bottom sheet ─────────────────────────────────────────────

class _DateRangeSheet extends StatefulWidget {
  const _DateRangeSheet({
    required this.initialFrom,
    required this.initialTo,
  });

  final DateTime initialFrom;
  final DateTime initialTo;

  @override
  State<_DateRangeSheet> createState() => _DateRangeSheetState();
}

class _DateRangeSheetState extends State<_DateRangeSheet> {
  late DateTime _from;
  late DateTime _to;

  @override
  void initState() {
    super.initState();
    _from = widget.initialFrom;
    _to = widget.initialTo;
  }

  Future<void> _pickFrom() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _from,
      firstDate: DateTime(2020),
      lastDate: _to,
      helpText: 'Start date',
    );
    if (picked != null) setState(() => _from = picked);
  }

  Future<void> _pickTo() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _to,
      firstDate: _from,
      lastDate: DateTime.now(),
      helpText: 'End date',
    );
    if (picked != null) setState(() => _to = picked);
  }

  String _fmt(DateTime d) {
    const m = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${d.day} ${m[d.month - 1]} ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final txt = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Handle bar
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: cs.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          Text('Custom range',
              style: txt.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 20),

          // From row
          _DateRow(
            label: 'From',
            value: _fmt(_from),
            onTap: _pickFrom,
          ),
          const SizedBox(height: 12),

          // To row
          _DateRow(
            label: 'To',
            value: _fmt(_to),
            onTap: _pickTo,
          ),
          const SizedBox(height: 28),

          // Actions — Cancel left, Apply bottom-right
          Row(
            children: [
              OutlinedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: () => Navigator.pop(
                  context,
                  DateTimeRange(start: _from, end: _to),
                ),
                icon: const Icon(Icons.check_rounded, size: 16),
                label: const Text('Apply'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DateRow extends StatelessWidget {
  const _DateRow({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          border: Border.all(color: cs.outlineVariant),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Text(label,
                style: TextStyle(
                    fontSize: 13,
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w500)),
            const Spacer(),
            Text(value,
                style: TextStyle(
                    fontSize: 14,
                    color: cs.onSurface,
                    fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            Icon(Icons.edit_calendar_outlined, size: 16, color: cs.primary),
          ],
        ),
      ),
    );
  }
}
