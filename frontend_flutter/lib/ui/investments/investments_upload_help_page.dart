import 'package:flutter/material.dart';

import '../../core/app_theme.dart';

/// "How to download your files" guide — opened from a help icon next to the
/// Upload Files section of [AddTradePage]. Per-broker, since the exact
/// screens/menu names differ broker to broker; deliberately only lists
/// brokers we actually have a verified guide for today (currently just
/// Zerodha/Coin) rather than listing other broker names with an empty
/// guide, which would be more confusing than just omitting them.
///
/// Opened via a normal push (not a bottom sheet) specifically so it reads
/// like its own dedicated screen with a real close button, since the
/// content (multiple expandable, multi-step guides) is a bit much for a
/// transient sheet.
class InvestmentsUploadHelpPage extends StatelessWidget {
  const InvestmentsUploadHelpPage({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('How to download your files'),
        leading: const CloseButton(),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: cs.primaryContainer.withAlpha(70),
              borderRadius: BorderRadius.circular(AppRadii.md),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded, size: 18, color: cs.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Each broker exports Holdings and Trade Book files from a different place in their app. '
                    "We'll keep adding more brokers here over time.",
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurface),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          for (final guide in _brokerGuides) ...[
            _BrokerGuideCard(guide: guide),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

class _BrokerGuide {
  const _BrokerGuide({
    required this.name,
    required this.navigatePath,
    required this.holdingsSteps,
    required this.tradesSteps,
  });

  final String name;

  /// Common starting navigation path shared by both files.
  final String navigatePath;
  final String holdingsSteps;
  final String tradesSteps;
}

const _brokerGuides = <_BrokerGuide>[
  _BrokerGuide(
    name: 'Zerodha / Coin',
    navigatePath: 'Coin app → Account → Console → Reports → ☰ (menu, top-right)',
    holdingsSteps: 'Portfolio → Holdings → use the "Download XLSX" option at the bottom-right corner.',
    tradesSteps: 'Go to Reports → Tradebook → tap the date-range strip → set Segment to "Mutual Funds" '
        '(or whichever segment your assets belong to), leave Symbol empty, and pick a date range of at '
        'least 2 months that covers all your recent trades/SIPs → Next → use the "Download XLSX" option '
        'at the top-right corner.',
  ),
];

class _BrokerGuideCard extends StatelessWidget {
  const _BrokerGuideCard({required this.guide});

  final _BrokerGuide guide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: Icon(Icons.menu_book_rounded, color: cs.primary),
          title: Text(
            'How to download Holdings & Trades files from ${guide.name}',
            style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
          ),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Divider(height: 1, color: cs.outlineVariant),
            const SizedBox(height: 12),
            _GuideStep(label: 'Navigate to', text: guide.navigatePath),
            const SizedBox(height: 12),
            _GuideStep(label: 'Holdings File', text: guide.holdingsSteps),
            const SizedBox(height: 12),
            _GuideStep(label: 'Trade Book File', text: guide.tradesSteps),
          ],
        ),
      ),
    );
  }
}

class _GuideStep extends StatelessWidget {
  const _GuideStep({required this.label, required this.text});

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(color: cs.primary, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 3),
        Text(
          text,
          style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurface, height: 1.35),
        ),
      ],
    );
  }
}
