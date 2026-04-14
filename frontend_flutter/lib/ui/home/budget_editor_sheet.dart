import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/snack_utils.dart';
import '../../state/app_controller.dart';

enum _CreateType { budget, account }

/// Shows a bottom sheet to create a new budget or account.
Future<void> showCreateBudgetSheet(BuildContext context) =>
    _show(context, _CreateType.budget);

Future<void> showCreateAccountSheet(BuildContext context) =>
    _show(context, _CreateType.account);

Future<void> _show(BuildContext context, _CreateType type) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CreateSheet(type: type),
    );

class _CreateSheet extends StatefulWidget {
  const _CreateSheet({required this.type});
  final _CreateType type;

  @override
  State<_CreateSheet> createState() => _CreateSheetState();
}

class _CreateSheetState extends State<_CreateSheet> {
  final _name = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String get _title =>
      widget.type == _CreateType.budget ? 'New Budget' : 'New Account';

  String get _hint =>
      widget.type == _CreateType.budget ? 'e.g. Monthly Groceries' : 'e.g. HDFC Savings';

  Future<void> _create() async {
    final n = _name.text.trim();
    if (n.isEmpty) return;
    final app = context.read<AppController>();
    setState(() => _saving = true);
    try {
      if (widget.type == _CreateType.budget) {
        await app.api.createBudget(name: n);
      } else {
        await app.api.createAccount(n);
      }
      await app.refreshAccountsBudgets();
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      showTopSnack(context, 'Error: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20, 8, 20,
        MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_saving) LinearProgressIndicator(minHeight: 3),
          const SizedBox(height: 4),
          Text(_title,
              style:
                  theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(hintText: _hint),
            onSubmitted: (_) => _create(),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving ? null : _create,
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }
}
