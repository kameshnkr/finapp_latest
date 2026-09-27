import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../data/models/investments_models.dart';
import '../../state/investments_controller.dart';
import '../../utils/amount_formatter.dart';

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
        _TotalPortfolioCard(totalValue: totalValue),
        const SizedBox(height: 16),
        ...portfolio.pots.map((p) => _PotCard(pot: p)),
        const SizedBox(height: 4),
        const _InfoBanner(),
      ],
    );
  }
}

class _TotalPortfolioCard extends StatelessWidget {
  const _TotalPortfolioCard({required this.totalValue});

  final double totalValue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.pie_chart_rounded, size: 15, color: cs.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(
                  'Total Portfolio',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '₹${compactAmount(totalValue)}',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: AppColors.amount,
                letterSpacing: -0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PotCard extends StatelessWidget {
  const _PotCard({required this.pot});

  final InvestmentsPotDto pot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final value = double.tryParse(pot.currentValue) ?? 0;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
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
                  Text(
                    pot.name,
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
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
