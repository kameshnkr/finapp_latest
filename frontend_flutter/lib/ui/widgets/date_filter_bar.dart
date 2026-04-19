import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_controller.dart';

/// Small filter icon + active-range label shown at the top-right of a page.
/// Tapping opens the full [DateRangeFilterSheet].
class FilterRow extends StatelessWidget {
  const FilterRow({super.key, required this.app});
  final AppController app;

  static const _presets = [30, 90, 365];

  bool _isDefault() {
    for (final days in _presets) {
      final expected = app.rangeTo.subtract(Duration(days: days));
      if (expected.difference(app.rangeFrom).abs() < const Duration(hours: 2)) {
        return true;
      }
    }
    return false;
  }

  String _label() {
    final f = app.rangeFrom.toLocal();
    final t = app.rangeTo.toLocal();
    const m = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final fromStr = f.year == t.year
        ? '${f.day} ${m[f.month - 1]}'
        : '${f.day} ${m[f.month - 1]} ${f.year}';
    return '$fromStr – ${t.day} ${m[t.month - 1]} ${t.year}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isCustom = !_isDefault();
    final iconColor = isCustom ? cs.primary : cs.onSurfaceVariant.withAlpha(160);

    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 2),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => showDateRangeFilterSheet(context, app),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isCustom) ...[
                    Text(
                      _label(),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: cs.primary,
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                  Icon(
                    Icons.filter_alt_rounded,
                    size: 16,
                    color: iconColor,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

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
      builder: (_) => DateRangeFilterSheet(
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

// ── Date range bottom sheet ────────────────────────────────────────────────────

/// A named quick-select preset that resolves to a concrete [DateTimeRange].
class _QuickPreset {
  const _QuickPreset(this.label, this.resolve);
  final String label;
  final DateTimeRange Function() resolve;
}

List<_QuickPreset> _buildQuickPresets() {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);

  DateTime firstOfMonth(int year, int month) => DateTime(year, month, 1);
  DateTime lastOfMonth(int year, int month) =>
      DateTime(year, month + 1, 1).subtract(const Duration(days: 1));

  return [
    _QuickPreset('This Month', () => DateTimeRange(
      start: firstOfMonth(today.year, today.month),
      end: today,
    )),
    _QuickPreset('Last Month', () {
      final y = today.month == 1 ? today.year - 1 : today.year;
      final m = today.month == 1 ? 12 : today.month - 1;
      return DateTimeRange(start: firstOfMonth(y, m), end: lastOfMonth(y, m));
    }),
    _QuickPreset('Last 3 Months', () => DateTimeRange(
      start: today.subtract(const Duration(days: 90)),
      end: today,
    )),
    _QuickPreset('Last 6 Months', () => DateTimeRange(
      start: today.subtract(const Duration(days: 180)),
      end: today,
    )),
    _QuickPreset('This Year', () => DateTimeRange(
      start: DateTime(today.year, 1, 1),
      end: today,
    )),
    _QuickPreset('Last Year', () => DateTimeRange(
      start: DateTime(today.year - 1, 1, 1),
      end: DateTime(today.year - 1, 12, 31),
    )),
  ];
}

/// Opens the date-range filter bottom sheet and applies the result to [app].
Future<void> showDateRangeFilterSheet(
    BuildContext context, AppController app) async {
  final result = await showModalBottomSheet<DateTimeRange>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => DateRangeFilterSheet(
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

class DateRangeFilterSheet extends StatefulWidget {
  const DateRangeFilterSheet({
    super.key,
    required this.initialFrom,
    required this.initialTo,
  });

  final DateTime initialFrom;
  final DateTime initialTo;

  @override
  State<DateRangeFilterSheet> createState() => _DateRangeFilterSheetState();
}

class _DateRangeFilterSheetState extends State<DateRangeFilterSheet> {
  late DateTime _from;
  late DateTime _to;

  static final _quickPresets = _buildQuickPresets();

  @override
  void initState() {
    super.initState();
    _from = widget.initialFrom;
    _to = widget.initialTo;
  }

  void _applyQuick(_QuickPreset preset) =>
      Navigator.pop(context, preset.resolve());

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final txt = Theme.of(context).textTheme;

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        20, 16, 20, MediaQuery.of(context).viewInsets.bottom + 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Handle bar
          Center(
            child: Container(
              width: 36, height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                  color: cs.outlineVariant,
                  borderRadius: BorderRadius.circular(2)),
            ),
          ),

          Text('Select range',
              style: txt.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 14),

          // ── Quick-select grid (3 columns) ─────────────────────────────
          GridView.count(
            crossAxisCount: 3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 7, crossAxisSpacing: 7,
            childAspectRatio: 3.0,
            children: _quickPresets.map((p) => OutlinedButton(
              onPressed: () => _applyQuick(p),
              style: OutlinedButton.styleFrom(
                padding: EdgeInsets.zero,
                side: BorderSide(color: cs.outlineVariant),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
                foregroundColor: cs.onSurface,
                textStyle: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w500),
              ),
              child: Text(p.label),
            )).toList(),
          ),

          // ── Divider ───────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Row(children: [
              Expanded(child: Divider(color: cs.outlineVariant)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text('or exact dates',
                    style: txt.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
              ),
              Expanded(child: Divider(color: cs.outlineVariant)),
            ]),
          ),

          // ── Inline From / To wheel pickers ────────────────────────────
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 6),
                      child: Text('From',
                          style: txt.labelSmall?.copyWith(
                              color: cs.primary, fontWeight: FontWeight.w600,
                              letterSpacing: 0.5)),
                    ),
                    _WheelDatePicker(
                      initial: _from,
                      onChanged: (d) => setState(() => _from = d),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 6),
                      child: Text('To',
                          style: txt.labelSmall?.copyWith(
                              color: cs.primary, fontWeight: FontWeight.w600,
                              letterSpacing: 0.5)),
                    ),
                    _WheelDatePicker(
                      initial: _to,
                      onChanged: (d) => setState(() => _to = d),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),

          // Actions
          Row(children: [
            OutlinedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: () => Navigator.pop(
                  context, DateTimeRange(start: _from, end: _to)),
              icon: const Icon(Icons.check_rounded, size: 16),
              label: const Text('Apply'),
            ),
          ]),
        ],
      ),
    );
  }
}

// ── Inline wheel date picker ───────────────────────────────────────────────────

class _WheelDatePicker extends StatefulWidget {
  const _WheelDatePicker({required this.initial, required this.onChanged});

  final DateTime initial;
  final ValueChanged<DateTime> onChanged;

  @override
  State<_WheelDatePicker> createState() => _WheelDatePickerState();
}

class _WheelDatePickerState extends State<_WheelDatePicker> {
  static const _months = [
    'Jan','Feb','Mar','Apr','May','Jun',
    'Jul','Aug','Sep','Oct','Nov','Dec',
  ];

  static final _years = () {
    final now = DateTime.now().year;
    return List.generate(now - 2019, (i) => 2020 + i);
  }();

  // 3 visible rows: peek · selected · peek
  static const double _itemH  = 40.0;
  static const double _wheelH = _itemH * 3;

  late int _day, _month, _year;
  late FixedExtentScrollController _dayCtrl, _monthCtrl, _yearCtrl;

  @override
  void initState() {
    super.initState();
    _day   = widget.initial.day;
    _month = widget.initial.month;
    _year  = widget.initial.year;
    _dayCtrl   = FixedExtentScrollController(initialItem: _day - 1);
    _monthCtrl = FixedExtentScrollController(initialItem: _month - 1);
    _yearCtrl  = FixedExtentScrollController(
        initialItem: (_years.indexOf(_year)).clamp(0, _years.length - 1));
  }

  @override
  void dispose() {
    _dayCtrl.dispose();
    _monthCtrl.dispose();
    _yearCtrl.dispose();
    super.dispose();
  }

  void _notify() {
    final maxDay = DateTime(_year, _month + 1, 0).day;
    widget.onChanged(DateTime(_year, _month, _day.clamp(1, maxDay)));
  }

  Widget _wheel({
    required int count,
    required FixedExtentScrollController ctrl,
    required Widget Function(int i) builder,
    required void Function(int i) onChanged,
  }) {
    return SizedBox(
      height: _wheelH,
      child: ListWheelScrollView.useDelegate(
        controller: ctrl,
        itemExtent: _itemH,
        // flat — no 3-D curve
        diameterRatio: 100,
        perspective: 0.001,
        // dims rows that are not in the centre
        overAndUnderCenterOpacity: 0.22,
        physics: const FixedExtentScrollPhysics(),
        onSelectedItemChanged: (i) { onChanged(i); _notify(); },
        childDelegate: ListWheelChildBuilderDelegate(
          childCount: count,
          builder: (_, i) => Center(child: builder(i)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs   = Theme.of(context).colorScheme;
    final divC = cs.outline.withOpacity(0.25);

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        color: cs.surfaceContainerLow,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // ── Selection lines (top & bottom of centre row) ──────────
            Positioned(
              top:    (_wheelH / 2) - (_itemH / 2),
              left: 0, right: 0,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Divider(height: 1, thickness: 1, color: divC),
                SizedBox(height: _itemH - 2),
                Divider(height: 1, thickness: 1, color: divC),
              ]),
            ),
            // ── Wheels ────────────────────────────────────────────────
            Row(children: [
              // Day
              Expanded(
                child: _wheel(
                  count: 31,
                  ctrl: _dayCtrl,
                  builder: (i) => Text(
                    '${i + 1}'.padLeft(2, '0'),
                    style: TextStyle(fontSize: 15,
                        fontWeight: FontWeight.w600, color: cs.onSurface),
                  ),
                  onChanged: (i) => _day = i + 1,
                ),
              ),
              // Month
              Expanded(
                flex: 2,
                child: _wheel(
                  count: 12,
                  ctrl: _monthCtrl,
                  builder: (i) => Text(
                    _months[i],
                    style: TextStyle(fontSize: 15,
                        fontWeight: FontWeight.w600, color: cs.onSurface),
                  ),
                  onChanged: (i) => _month = i + 1,
                ),
              ),
              // Year
              Expanded(
                flex: 2,
                child: _wheel(
                  count: _years.length,
                  ctrl: _yearCtrl,
                  builder: (i) => Text(
                    '${_years[i]}',
                    style: TextStyle(fontSize: 15,
                        fontWeight: FontWeight.w600, color: cs.onSurface),
                  ),
                  onChanged: (i) => _year = _years[i],
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
