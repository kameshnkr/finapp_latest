import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../core/snack_utils.dart';
import '../../data/models/models.dart';
import '../../state/app_controller.dart';
import '../../utils/amount_formatter.dart';
import '../widgets/app_numpad.dart';
import '../widgets/app_textpad.dart';

enum _Stage { amount, account, note }

class AddDraftPage extends StatefulWidget {
  const AddDraftPage({super.key});

  @override
  State<AddDraftPage> createState() => _AddDraftPageState();
}

class _AddDraftPageState extends State<AddDraftPage> {
  _Stage _stage = _Stage.amount;
  String _amount = '';
  String? _direction;
  String? _accountId;
  String _note = '';

  void _reset() => setState(() {
        _stage = _Stage.amount;
        _amount = '';
        _direction = null;
        _accountId = null;
        _note = '';
      });

  Future<void> _submit() async {
    final app = context.read<AppController>();
    final accId = _accountId;
    final dir = _direction;
    if (accId == null || dir == null || _amount.isEmpty) return;
    try {
      await app.api.createDraft(
        accountId: accId,
        direction: dir,
        amount: _normalizeAmount(_amount),
        note: _note.isEmpty ? null : _note,
      );
      await app.refreshTransactions();
      if (!mounted) return;
      showTopSnack(context, 'Saved to Drafts');
      _reset();
    } catch (e) {
      if (!mounted) return;
      showTopSnack(context, 'Error: $e');
    }
  }

  String _normalizeAmount(String raw) {
    var s = raw;
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
    if (s.isEmpty) return '0';
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final accounts = app.accounts;
    final cs = Theme.of(context).colorScheme;
    final theme = Theme.of(context);

    final hasDigits = RegExp(r'\d').hasMatch(_amount);
    final amountColor = _direction == 'debit'
        ? Colors.red.shade700
        : _direction == 'credit'
            ? AppColors.gain
            : cs.onSurface;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Amount display panel ─────────────────────────────────────────
        Expanded(
          flex: 2,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
              // Step dots
              _StepDots(stage: _stage),
              const SizedBox(height: 12),

              // Big amount
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Text('₹',
                        style: theme.textTheme.titleLarge?.copyWith(
                            color: cs.onSurfaceVariant,
                            fontWeight: FontWeight.w300)),
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      _amount.isEmpty ? '0' : _amount,
                      style: theme.textTheme.headlineLarge?.copyWith(
                        color: amountColor,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -1,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // Context chips — visible after each step is filled
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 6,
                children: [
                  if (_direction != null)
                    _ContextChip(
                      label:
                          _direction == 'debit' ? '─ Debited' : '+ Credited',
                      color: _direction == 'debit'
                          ? Colors.red.shade700
                          : AppColors.gain,
                      bgColor: _direction == 'debit'
                          ? AppColors.loss.withAlpha(20)
                          : AppColors.gain.withAlpha(20),
                    ),
                  if (_accountId != null)
                    _ContextChip(
                      label: _accountName(accounts),
                      color: cs.primary,
                      bgColor: cs.primaryContainer.withAlpha(80),
                    ),
                  if (_note.isNotEmpty)
                    _ContextChip(
                      label: _note,
                      color: cs.onSurfaceVariant,
                      bgColor: cs.surfaceContainerHighest,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),

        // ── Control surface ──────────────────────────────────────────────
        Expanded(
          flex: 3,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
              child: _buildControl(
                accounts: accounts,
                hasDigits: hasDigits,
                cs: cs,
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _accountName(List<AccountDto> accounts) {
    if (_accountId == null) return '';
    for (final a in accounts) {
      if (a.id == _accountId) return a.name;
    }
    return _accountId!;
  }

  Widget _buildControl({
    required List<AccountDto> accounts,
    required bool hasDigits,
    required ColorScheme cs,
  }) {
    switch (_stage) {
      case _Stage.amount:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppNumpad(
              onKey: (k) {
                setState(() {
                  if (_amount.contains('.') && k == '.') return;
                  _amount += k;
                });
              },
              onBackspace: () => setState(() {
                if (_amount.isNotEmpty) {
                  _amount = _amount.substring(0, _amount.length - 1);
                }
              }),
            ),
            const SizedBox(height: 10),
            // Debit / Credit — full-width, color-filled
            Row(
              children: [
                Expanded(
                  child: _DirectionButton(
                    label: 'Credited',
                    icon: Icons.arrow_downward_rounded,
                    enabled: hasDigits,
                    textColor: AppColors.gain,
                    fillColor: AppColors.gain.withAlpha(20),
                    borderColor: AppColors.gain.withAlpha(80),
                    onPressed: () => setState(() {
                      _direction = 'credit';
                      _stage = _Stage.account;
                    }),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _DirectionButton(
                    label: 'Debited',
                    icon: Icons.arrow_upward_rounded,
                    enabled: hasDigits,
                    textColor: Colors.red.shade700,
                    fillColor: Colors.red.shade50,
                    borderColor: Colors.red.shade200,
                    onPressed: () => setState(() {
                      _direction = 'debit';
                      _stage = _Stage.account;
                    }),
                  ),
                ),
              ],
            ),
          ],
        );

      case _Stage.account:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Select Account',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                      letterSpacing: 0.5,
                      fontWeight: FontWeight.w600)),
            ),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: accounts
                      .map((a) => _AccountTile(
                            account: a,
                            onTap: () => setState(() {
                              _accountId = a.id;
                              _stage = _Stage.note;
                            }),
                          ))
                      .toList(),
                ),
              ),
            ),
          ],
        );

      case _Stage.note:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Add a note',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                      letterSpacing: 0.5,
                      fontWeight: FontWeight.w600)),
            ),
            const SizedBox(height: 8),
            AppTextpad(
              onChar: (c) => setState(() => _note += c),
              onBackspace: () => setState(() {
                if (_note.isNotEmpty) {
                  _note = _note.substring(0, _note.length - 1);
                }
              }),
              onGo: _submit,
            ),
          ],
        );
    }
  }
}

// ── Step dots ──────────────────────────────────────────────────────────────────

class _StepDots extends StatelessWidget {
  const _StepDots({required this.stage});
  final _Stage stage;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final labels = ['Amount', 'Account', 'Note'];
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(3, (i) {
        final done = i < stage.index;
        final active = i == stage.index;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (i > 0)
              Container(
                width: 20,
                height: 1,
                margin: const EdgeInsets.only(bottom: 14),
                color: done ? cs.primary.withAlpha(120) : cs.outlineVariant,
              ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: active ? 8 : 6,
                  height: active ? 8 : 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: done || active ? cs.primary : cs.outlineVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  labels[i],
                  style: TextStyle(
                    fontSize: 10,
                    color: active
                        ? cs.primary
                        : done
                            ? cs.primary.withAlpha(140)
                            : cs.onSurfaceVariant.withAlpha(120),
                    fontWeight:
                        active ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ],
        );
      }),
    );
  }
}

// ── Context chip (locked info pill) ───────────────────────────────────────────

class _ContextChip extends StatelessWidget {
  const _ContextChip({
    required this.label,
    required this.color,
    required this.bgColor,
  });

  final String label;
  final Color color;
  final Color bgColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withAlpha(60)),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w600)),
    );
  }
}

// ── Direction button (Debit / Credit) ─────────────────────────────────────────

class _DirectionButton extends StatelessWidget {
  const _DirectionButton({
    required this.label,
    required this.icon,
    required this.enabled,
    required this.textColor,
    required this.fillColor,
    required this.borderColor,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final bool enabled;
  final Color textColor;
  final Color fillColor;
  final Color borderColor;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: enabled ? 1.0 : 0.4,
      duration: const Duration(milliseconds: 150),
      child: Material(
        color: enabled ? fillColor : Colors.grey.shade100,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: enabled ? onPressed : null,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: enabled ? borderColor : Colors.grey.shade200),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 18, color: enabled ? textColor : Colors.grey),
                const SizedBox(width: 6),
                Text(label,
                    style: TextStyle(
                      color: enabled ? textColor : Colors.grey,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    )),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Account tile (shown during account selection) ─────────────────────────────

class _AccountTile extends StatelessWidget {
  const _AccountTile({required this.account, required this.onTap});

  final AccountDto account;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final balance = double.tryParse(account.totalBalance) ?? 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      account.name.isNotEmpty
                          ? account.name[0].toUpperCase()
                          : '?',
                      style: TextStyle(
                        color: cs.onPrimaryContainer,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(account.name,
                      style: Theme.of(context)
                          .textTheme
                          .bodyLarge
                          ?.copyWith(fontWeight: FontWeight.w500)),
                ),
                Text(
                  '₹${compactAmount(balance)}',
                  style: TextStyle(
                      color: cs.primary,
                      fontWeight: FontWeight.w700,
                      fontSize: 15),
                ),
                const SizedBox(width: 6),
                Icon(Icons.chevron_right, size: 18, color: cs.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
