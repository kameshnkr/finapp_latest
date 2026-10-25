import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../data/models/investments_models.dart';
import '../../state/investments_controller.dart';
import '../../utils/amount_formatter.dart';
import '../widgets/expandable_name_text.dart';
import 'investments_pot_sheets.dart';
import 'pot_icons.dart';
import 'reallocate_pot_sheet.dart';

/// Pots tab — primary Investments view. Answers "how much money do I
/// currently have allocated toward each goal?". Deliberately shows ONLY
/// current value: no invested amount, gain/loss, or units anywhere here
/// (explicit simplification per spec).
class PotsTab extends StatefulWidget {
  const PotsTab({super.key});

  @override
  State<PotsTab> createState() => _PotsTabState();
}

class _PotsTabState extends State<PotsTab> {
  /// At most one Pot card is expanded at a time — lifted here (rather than
  /// each card owning its own expand flag) specifically so expanding one
  /// Pot always collapses whichever other one was previously expanded, and
  /// so unrelated interactions elsewhere on this tab (scrolling, tapping
  /// the header/banner) can reliably collapse it too.
  String? _expandedPotId;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_collapseExpanded);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_collapseExpanded);
    _scrollController.dispose();
    super.dispose();
  }

  void _toggleExpanded(String potId) {
    setState(() {
      _expandedPotId = _expandedPotId == potId ? null : potId;
    });
  }

  void _collapseExpanded() {
    if (_expandedPotId != null) setState(() => _expandedPotId = null);
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<InvestmentsController>();
    final portfolio = controller.portfolio;

    if (portfolio == null) {
      return Center(
        child: controller.loading
            ? const CircularProgressIndicator()
            : Text(
                controller.error == null
                    ? 'No portfolio data yet.'
                    : 'Error: ${controller.error}',
                style: const TextStyle(color: Colors.grey),
              ),
      );
    }

    final totalValue = double.tryParse(portfolio.totalPortfolioValue) ?? 0;

    return ListView(
      controller: _scrollController,
      padding: AppInsets.screen,
      children: [
        // A plain tap on the header or banner counts as "anywhere else" —
        // collapses whichever Pot card is currently expanded. Sibling-level
        // (not wrapping the cards), so it never competes with a card's own
        // tap handling.
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: _collapseExpanded,
          child: _TotalPortfolioHeader(totalValue: totalValue),
        ),
        const SizedBox(height: 14),
        ...portfolio.pots.map(
          (p) => _PotCard(
            pot: p,
            canReallocate: portfolio.pots.length > 1,
            expanded: _expandedPotId == p.id,
            onToggle: () => _toggleExpanded(p.id),
            onCollapse: _collapseExpanded,
          ),
        ),
        const SizedBox(height: 4),
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: _collapseExpanded,
          child: const _InfoBanner(),
        ),
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
                        child: Icon(
                          Icons.pie_chart_rounded,
                          size: 19,
                          color: cs.onSurfaceVariant,
                        ),
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

class _PotCard extends StatelessWidget {
  const _PotCard({
    required this.pot,
    required this.canReallocate,
    required this.expanded,
    required this.onToggle,
    required this.onCollapse,
  });

  final InvestmentsPotDto pot;

  /// Hides the "Transfer" affordance entirely (not just disables it) when
  /// the user has only a single Pot total — there's nowhere to send units
  /// to. See investments_pot_amounts_different_approach.log.
  final bool canReallocate;

  /// Controlled from `PotsTab` — at most one card is expanded at a time.
  final bool expanded;

  /// Tapping this card: expand it (collapsing whichever other card was
  /// previously expanded), or collapse it if it's already the one open.
  final VoidCallback onToggle;

  /// Explicitly collapses this (or any) card — wired into the Edit and
  /// Transfer actions below so opening either sheet always leaves the
  /// card collapsed underneath, rather than visually staying expanded.
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final value = double.tryParse(pot.currentValue) ?? 0;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // Single tap target for the whole card: reveals the full Pot name
        // (the edit icon below keeps its own independent tap, same
        // well-established nested-gesture behavior used elsewhere).
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
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
                    child: Icon(
                      resolvePotIcon(pot.iconKey),
                      size: 19,
                      color: cs.primary,
                    ),
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
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                                expanded: expanded,
                              ),
                            ),
                            const SizedBox(width: 4),
                            // Edit icon sits right next to the Pot's name — kept
                            // subtle (small, faint) so it doesn't compete with
                            // the Pot's name for attention. Its own InkWell wins
                            // over the card's tap when tapped precisely on it
                            // (standard nested-gesture behavior).
                            InkWell(
                              onTap: () {
                                onCollapse();
                                showEditInvestmentsPotSheet(
                                  context,
                                  potId: pot.id,
                                  currentName: pot.name,
                                  currentDescription: pot.description,
                                  currentIconKey: pot.iconKey,
                                );
                              },
                              borderRadius: BorderRadius.circular(6),
                              child: Padding(
                                padding: const EdgeInsets.all(2),
                                child: Icon(
                                  Icons.edit_outlined,
                                  size: 13,
                                  color: cs.onSurfaceVariant.withAlpha(140),
                                ),
                              ),
                            ),
                          ],
                        ),
                        if (pot.description != null &&
                            pot.description!.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            pot.description!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
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
              // The "Transfer" action is no longer shown by default — it
              // only reveals once the card is expanded (tap anywhere on the
              // card), as a proper elevated button rather than a small
              // inline affordance competing with the amount for attention.
              // Hidden entirely both when there's nowhere to send units to
              // (single-Pot portfolio) and when this Pot has nothing to
              // transfer out in the first place.
              if (canReallocate && value > 0.005)
                AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.topCenter,
                  child: expanded
                      ? Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Divider(
                                height: 1,
                                color: cs.outlineVariant.withAlpha(130),
                              ),
                              const SizedBox(height: 12),
                              Align(
                                alignment: Alignment.centerRight,
                                child: ElevatedButton.icon(
                                  onPressed: () {
                                    onCollapse();
                                    showReallocatePotSheet(
                                      context,
                                      potId: pot.id,
                                    );
                                  },
                                  icon: const Icon(
                                    Icons.sync_alt_rounded,
                                    size: 18,
                                  ),
                                  label: const Text('Transfer Funds'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: cs.primaryContainer,
                                    foregroundColor: cs.onPrimaryContainer,
                                    elevation: 2,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 18,
                                      vertical: 11,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )
                      : const SizedBox(width: double.infinity),
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
