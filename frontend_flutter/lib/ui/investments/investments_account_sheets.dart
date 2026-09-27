import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/snack_utils.dart';
import '../../state/investments_controller.dart';

/// Bottom sheet to add a new Investment Account. Only name is required;
/// broker name is optional (per spec — account_identifier is never
/// user-entered, only ever backfilled from a statement upload).
Future<void> showCreateInvestmentsAccountSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _InvestmentsAccountSheet(),
    );

/// Bottom sheet to rename an existing Investment Account (rename action
/// belongs to the Account Header only — never exposed on individual Asset
/// rows, per spec).
Future<void> showRenameInvestmentsAccountSheet(
  BuildContext context, {
  required String accountId,
  required String currentName,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _InvestmentsAccountSheet(
        accountId: accountId,
        initialName: currentName,
      ),
    );

class _InvestmentsAccountSheet extends StatefulWidget {
  const _InvestmentsAccountSheet({this.accountId, this.initialName});

  /// Null → create mode. Non-null → rename mode for this Account.
  final String? accountId;
  final String? initialName;

  @override
  State<_InvestmentsAccountSheet> createState() => _InvestmentsAccountSheetState();
}

class _InvestmentsAccountSheetState extends State<_InvestmentsAccountSheet> {
  late final _name = TextEditingController(text: widget.initialName ?? '');
  final _broker = TextEditingController();
  bool _saving = false;

  bool get _isRename => widget.accountId != null;

  @override
  void dispose() {
    _name.dispose();
    _broker.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final n = _name.text.trim();
    if (n.isEmpty) return;

    final controller = context.read<InvestmentsController>();
    setState(() => _saving = true);
    try {
      if (_isRename) {
        await controller.renameAccount(accountId: widget.accountId!, name: n);
      } else {
        final b = _broker.text.trim();
        await controller.createAccount(name: n, brokerName: b.isEmpty ? null : b);
      }
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
        20,
        8,
        20,
        MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_saving) const LinearProgressIndicator(minHeight: 3),
          const SizedBox(height: 4),
          Text(
            _isRename ? 'Rename Account' : 'New Investment Account',
            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(hintText: 'e.g. My Demat Account 1'),
            onSubmitted: (_) => _save(),
          ),
          if (!_isRename) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _broker,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(hintText: 'Broker name (optional)'),
              onSubmitted: (_) => _save(),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_isRename ? 'Save' : 'Create'),
          ),
        ],
      ),
    );
  }
}
