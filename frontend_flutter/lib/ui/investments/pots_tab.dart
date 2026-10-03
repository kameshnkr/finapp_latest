import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../data/models/investments_models.dart';
import '../../state/investments_controller.dart';
import '../../utils/amount_formatter.dart';
import '../widgets/expandable_name_text.dart';
import 'investments_pot_sheets.dart';

/// Pots tab — primary Investments view. Answers "how much money do I
/// currently have allocated toward each goal?". Deliberately shows ONLY
/// current value: no invested amount, gain/loss, or units anywhere here
/// (explicit simplification per spec).
class PotsTab extends StatelessWidget {
  const PotsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<InvestmentsController>();
    final portfolio = controller.portfolio;

    if (portfolio == null) {
      return Center(
        child: controller.loading
            ? const CircularProgressIndicator()
            : Text(
                controller.error == null ? 'No portfolio data yet.' : 'Error: ${controller.error}',
                style: const TextStyle(color: Colors.grey),
              ),
      );
    }

    final totalValue = double.tryParse(portfolio.totalPortfolioValue) ?? 0;

    return ListView(
      padding: AppInsets.screen,
      children: [
        _TotalPortfolioHeader(totalValue: totalValue),
        const SizedBox(height: 14),
        ...portfolio.pots.map((p) => _PotCard(pot: p)),
        const SizedBox(height: 4),
        const _InfoBanner(),
      ],
    );
  }
}

class _TotalPortfolioHeader extends StatelessWidget {
  const _TotalPortfolioHeader({required this.totalValue});

  final double totalValue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    // Deliberately NOT a Card — plain on the page background, mirroring
    // Banking's Budget tab header (Unallocated info + "Add New Budget") row
    // exactly, per the reference design. Left padding matches the x-offset
    // where each _PotCard's own icon starts (16 outer + 16 card-inner), so
    // this header lines up with the Pot rows below instead of sitting
    // further left than everything else on the page.
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 4, 2),
      // IntrinsicHeight lets the VerticalDivider below stretch to match the
      // tallest sibling (the title+amount Column) instead of collapsing to
      // zero height. Both halves are wrapped in equal-flex Expanded so the
      // divider lands at the row's true horizontal center, rather than
      // hugging whichever side has less content.
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              // No boxed icon here — a small inline glyph beside the label
              // (same treatment as Banking's Budget tab "Unallocated" row)
              // reads cleaner in a slim, unboxed header than a colored icon
              // tile competing with the two-line title+amount block.
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    // start — icon's top edge lines up with the title
                    // text's top edge, instead of centering against it.
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Same glyph size as each _PotCard's icon, but muted
                      // grey (not blue) since this is a plain label, not a
                      // Pot's own identity. Nudged down slightly (top
                      // padding) so it sits visually level with the title
                      // text, since the glyph's own bounding box has extra
                      // headroom above its visible shape.
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Icon(Icons.pie_chart_rounded, size: 19, color: cs.onSurfaceVariant),
                      ),
                      const SizedBox(width: 7),
                      Text(
                        'Total Portfolio',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: cs.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  // Indented by icon width (19) + gap (7) so the amount
                  // lines up under "Total Portfolio" itself, not under the
                  // icon above it.
                  Padding(
                    padding: const EdgeInsets.only(left: 26),
                    child: Text(
                      '₹${compactAmount(totalValue)}',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: AppColors.amount,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            VerticalDivider(
              width: 24,
              thickness: 1,
              indent: 2,
              endIndent: 2,
              color: AppColors.cardBorder,
            ),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => showCreateInvestmentsPotSheet(context),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add New Pot'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: AppColors.amount,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PotCard extends StatefulWidget {
  const _PotCard({required this.pot});

  final InvestmentsPotDto pot;

  @override
  State<_PotCard> createState() => _PotCardState();
}

class _PotCardState extends State<_PotCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final pot = widget.pot;
    final value = double.tryParse(pot.currentValue) ?? 0;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // Single tap target for the whole card: reveals the full Pot name
        // (the edit icon below keeps its own independent tap, same
        // well-established nested-gesture behavior used elsewhere).
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: cs.primaryContainer.withAlpha(90),
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: Icon(Icons.savings_rounded, size: 19, color: cs.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Flexible(
                          child: ExpandableNameText(
                            pot.name,
                            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                            expanded: _expanded,
                          ),
                        ),
                        const SizedBox(width: 4),
                        // Edit icon sits right next to the Pot's name — kept
                        // subtle (small, faint) so it doesn't compete with
                        // the Pot's name for attention. Its own InkWell wins
                        // over the card's tap when tapped precisely on it
                        // (standard nested-gesture behavior).
                        InkWell(
                          onTap: () => showEditInvestmentsPotSheet(
                            context,
                            potId: pot.id,
                            currentName: pot.name,
                            currentDescription: pot.description,
                          ),
                          borderRadius: BorderRadius.circular(6),
                          child: Padding(
                            padding: const EdgeInsets.all(2),
                            child: Icon(Icons.edit_outlined, size: 13, color: cs.onSurfaceVariant.withAlpha(140)),
                          ),
                        ),
                      ],
                    ),
                    if (pot.description != null && pot.description!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        pot.description!,
                        style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '₹${compactAmount(value)}',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: AppColors.amount,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoBanner extends StatelessWidget {
  const _InfoBanner();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
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
              'Track all your investments segregated into goal-wise Pots.\n'
              'Add investment statements to keep your portfolio up to date.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                    height: 1.4,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
