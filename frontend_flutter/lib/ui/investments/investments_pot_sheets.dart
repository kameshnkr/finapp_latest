import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/snack_utils.dart';
import '../../state/investments_controller.dart';
import 'pot_icon_picker.dart';
import 'pot_icons.dart';

/// Bottom sheet to add a new Pot. Name is required; description and icon
/// are optional (icon defaults to kDefaultPotIconKey) — mirrors
/// showCreateInvestmentsAccountSheet's structure otherwise.
Future<void> showCreateInvestmentsPotSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _InvestmentsPotSheet(),
    );

/// Bottom sheet to edit an existing Pot's name, description, and/or icon.
Future<void> showEditInvestmentsPotSheet(
  BuildContext context, {
  required String potId,
  required String currentName,
  required String? currentDescription,
  required String currentIconKey,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _InvestmentsPotSheet(
        potId: potId,
        initialName: currentName,
        initialDescription: currentDescription,
        initialIconKey: currentIconKey,
      ),
    );

class _InvestmentsPotSheet extends StatefulWidget {
  const _InvestmentsPotSheet({
    this.potId,
    this.initialName,
    this.initialDescription,
    this.initialIconKey,
  });

  /// Null → create mode. Non-null → edit mode for this Pot.
  final String? potId;
  final String? initialName;
  final String? initialDescription;
  final String? initialIconKey;

  @override
  State<_InvestmentsPotSheet> createState() => _InvestmentsPotSheetState();
}

class _InvestmentsPotSheetState extends State<_InvestmentsPotSheet> {
  late final _name = TextEditingController(text: widget.initialName ?? '');
  late final _description = TextEditingController(text: widget.initialDescription ?? '');
  late String _iconKey = widget.initialIconKey ?? kDefaultPotIconKey;
  bool _saving = false;

  bool get _isEdit => widget.potId != null;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _pickIcon() async {
    final picked = await showPotIconPicker(context, currentIconKey: _iconKey);
    if (picked != null && mounted) setState(() => _iconKey = picked);
  }

  Future<void> _save() async {
    final n = _name.text.trim();
    if (n.isEmpty) return;
    final d = _description.text.trim();

    final controller = context.read<InvestmentsController>();
    setState(() => _saving = true);
    try {
      if (_isEdit) {
        await controller.updatePot(
          potId: widget.potId!,
          name: n,
          description: d.isEmpty ? null : d,
          iconKey: _iconKey,
        );
      } else {
        await controller.createPot(name: n, description: d.isEmpty ? null : d, iconKey: _iconKey);
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
    final cs = theme.colorScheme;
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
            _isEdit ? 'Edit Pot' : 'New Pot',
            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 16),
          // Icon preview — tap to open the picker. Centered, standalone row
          // above the Name field so it reads as "this Pot's identity" first.
          Center(
            child: InkWell(
              onTap: _pickIcon,
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Column(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: cs.primaryContainer.withAlpha(90),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      alignment: Alignment.center,
                      child: Icon(resolvePotIcon(_iconKey), size: 26, color: cs.primary),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Tap to change icon',
                      style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(hintText: 'e.g. Retirement'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _description,
            textCapitalization: TextCapitalization.sentences,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(hintText: 'Description (optional)'),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_isEdit ? 'Save' : 'Create'),
          ),
        ],
      ),
    );
  }
}
