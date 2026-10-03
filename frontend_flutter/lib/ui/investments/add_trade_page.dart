import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../data/models/investments_models.dart';
import '../../state/investments_controller.dart';
import 'investments_upload_help_page.dart';

/// Add Trade — select an Investment Account, upload the two mandatory
/// files (Holdings Statement + Trade Book), then poll the async
/// parse→reconcile→save job. If reconciliation finds per-asset unit
/// mismatches, review them and either accept the proposed dummy trade or
/// skip, before the upload is finally committed.
///
/// Mirrors Banking's statement_upload_page.dart stage-machine/polling
/// pattern, but independently implemented: two files instead of one, an
/// array of per-asset mismatches instead of one scalar delta, and its own
/// job endpoints (investmentsUploadRouter) — Banking's statement job
/// tables/endpoints are never touched.
class AddTradePage extends StatefulWidget {
  const AddTradePage({super.key, this.onUploadCompleted});

  /// Called once a job reaches COMPLETED — lets the host screen (e.g. flip
  /// to the Un-labeled tab) react without this widget needing to know about
  /// tab navigation itself.
  final VoidCallback? onUploadCompleted;

  @override
  State<AddTradePage> createState() => _AddTradePageState();
}

enum _Stage { selectAccount, processing, awaitingConfirmation, completed, failed }

class _AddTradePageState extends State<AddTradePage> with SingleTickerProviderStateMixin {
  _Stage _stage = _Stage.selectAccount;

  String? _accountId;
  String? _accountName;
  PlatformFile? _holdingsFile;
  PlatformFile? _tradeBookFile;

  String _jobId = '';
  String _statusMessage = '';
  InvestmentsUploadConfirmationDataDto? _confirmationData;
  InvestmentsUploadResultDto? _completedResult;
  String _errorMessage = '';

  /// accountAssetId -> user's create-dummy choice. Defaults to true when
  /// canCreateDummy, matching Banking's create-dummy-by-default UX.
  final Map<String, bool> _dummyChoices = {};
  bool _isConfirming = false;
  bool _isRejecting = false;

  Timer? _pollTimer;

  late final AnimationController _spinController = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat();

  @override
  void dispose() {
    _spinController.dispose();
    _pollTimer?.cancel();
    super.dispose();
  }

  // ── File pick ─────────────────────────────────────────────────────────────

  Future<void> _pickFile(bool isHoldings) async {
    if (_accountId == null) {
      _showInfoSnack(
        'Select an Investment Account above first — we need to know which account to import these trades/holdings into before you upload the files.',
      );
      return;
    }
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx', 'xls', 'csv'],
      allowMultiple: false,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.single;
    if (file.bytes == null || file.bytes!.isEmpty) {
      _showTransientError('Could not read file data. Please try again.');
      return;
    }
    setState(() {
      if (isHoldings) {
        _holdingsFile = file;
      } else {
        _tradeBookFile = file;
      }
    });
  }

  void _showTransientError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  /// A guidance/info snackbar (distinct from `_showTransientError`'s plain
  /// error styling) — used when the user is blocked from an action for a
  /// reason that isn't a failure, just a missing prerequisite step.
  void _showInfoSnack(String msg) {
    if (!mounted) return;
    final cs = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(Icons.info_outline_rounded, color: cs.onInverseSurface, size: 18),
            const SizedBox(width: 10),
            Expanded(child: Text(msg)),
          ],
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ── Upload + polling ──────────────────────────────────────────────────────

  Future<void> _upload() async {
    final accountId = _accountId;
    final holdings = _holdingsFile;
    final tradeBook = _tradeBookFile;
    if (accountId == null || holdings == null || tradeBook == null) return;

    final controller = context.read<InvestmentsController>();

    setState(() {
      _stage = _Stage.processing;
      _statusMessage = 'Uploading...';
    });

    try {
      final jobId = await controller.api.uploadTrades(
        accountId: accountId,
        holdingsBytes: holdings.bytes!,
        holdingsFileName: holdings.name,
        tradeBookBytes: tradeBook.bytes!,
        tradeBookFileName: tradeBook.name,
      );
      _jobId = jobId;
      _startPolling();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _stage = _Stage.failed;
        _errorMessage = e.toString();
      });
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _pollStatus());
  }

  Future<void> _pollStatus() async {
    if (_jobId.isEmpty) return;
    try {
      final controller = context.read<InvestmentsController>();
      final job = await controller.api.getUploadStatus(_jobId);
      if (!mounted) return;

      switch (job.status) {
        case 'COMPLETED':
          _pollTimer?.cancel();
          await controller.refreshHome();
          if (!mounted) return;
          setState(() {
            _stage = _Stage.completed;
            _completedResult = job.result;
          });
        case 'FAILED':
          _pollTimer?.cancel();
          setState(() {
            _stage = _Stage.failed;
            _errorMessage = job.errorMessage ?? 'Processing failed';
          });
        case 'AWAITING_CONFIRMATION':
          _pollTimer?.cancel();
          final data = job.confirmationData;
          setState(() {
            _stage = _Stage.awaitingConfirmation;
            _confirmationData = data;
            _dummyChoices.clear();
            for (final m in data?.mismatches ?? const <InvestmentsReconciliationMismatchDto>[]) {
              _dummyChoices[m.accountAssetId] = m.canCreateDummy;
            }
          });
        case 'REJECTED':
          _pollTimer?.cancel();
        default:
          setState(() => _statusMessage = job.message ?? _labelFor(job.status));
      }
    } catch (_) {
      // Transient polling errors — keep retrying.
    }
  }

  String _labelFor(String status) {
    switch (status) {
      case 'UPLOADING':
        return 'Uploading files...';
      case 'PARSING':
        return 'Reading files...';
      case 'RECONCILING':
        return 'Reconciling holdings...';
      case 'SAVING':
        return 'Saving trades...';
      default:
        return status;
    }
  }

  // ── Confirm / Reject ──────────────────────────────────────────────────────

  Future<void> _onConfirm() async {
    if (_isConfirming || _isRejecting) return;
    setState(() => _isConfirming = true);
    try {
      final controller = context.read<InvestmentsController>();
      final resolutions = _dummyChoices.entries
          .map((e) => {'accountAssetId': e.key, 'createDummy': e.value})
          .toList();
      await controller.api.confirmUpload(jobId: _jobId, mismatchResolutions: resolutions);
      final job = await controller.api.getUploadStatus(_jobId);
      await controller.refreshHome();
      if (!mounted) return;
      setState(() {
        _stage = _Stage.completed;
        _completedResult = job.result;
        _isConfirming = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isConfirming = false;
        _errorMessage = e.toString();
        _stage = _Stage.failed;
      });
    }
  }

  Future<void> _onReject() async {
    if (_isRejecting || _isConfirming) return;
    setState(() => _isRejecting = true);
    try {
      final controller = context.read<InvestmentsController>();
      await controller.api.rejectUpload(_jobId);
      if (!mounted) return;
      _resetToStart();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Upload cancelled. No trades were added.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isRejecting = false;
        _errorMessage = e.toString();
        _stage = _Stage.failed;
      });
    }
  }

  void _resetToStart() {
    _pollTimer?.cancel();
    setState(() {
      _stage = _Stage.selectAccount;
      _accountId = null;
      _accountName = null;
      _holdingsFile = null;
      _tradeBookFile = null;
      _jobId = '';
      _statusMessage = '';
      _confirmationData = null;
      _completedResult = null;
      _errorMessage = '';
      _dummyChoices.clear();
      _isConfirming = false;
      _isRejecting = false;
    });
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    switch (_stage) {
      case _Stage.selectAccount:
        return _buildSelectAccount();
      case _Stage.processing:
        return _buildProcessing();
      case _Stage.awaitingConfirmation:
        return _buildAwaitingConfirmation();
      case _Stage.completed:
        return _buildCompleted();
      case _Stage.failed:
        return _buildFailed();
    }
  }

  // ── Stage: select account + pick files ───────────────────────────────────

  Widget _buildSelectAccount() {
    final accounts = context.watch<InvestmentsController>().accounts;
    final cs = Theme.of(context).colorScheme;
    final canUpload = _accountId != null && _holdingsFile != null && _tradeBookFile != null;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Select Investment Account',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
          ),
          const SizedBox(height: 10),
          if (accounts.isEmpty)
            Text('No accounts yet. Add one from the Assets tab first.',
                style: TextStyle(color: cs.onSurfaceVariant))
          else
            ...accounts.map((a) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _SelectableTile(
                    label: a.name,
                    subtitle: a.brokerName,
                    selected: _accountId == a.id,
                    onTap: () => setState(() {
                      _accountId = a.id;
                      _accountName = a.name;
                    }),
                  ),
                )),
          const SizedBox(height: 24),
          Row(
            children: [
              Text(
                'Upload Files',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
              ),
              const SizedBox(width: 6),
              IconButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(builder: (_) => const InvestmentsUploadHelpPage()),
                ),
                icon: const Icon(Icons.help_outline_rounded, size: 19),
                tooltip: 'How to download your Holdings & Trade Book files',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                style: IconButton.styleFrom(foregroundColor: cs.primary),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _FilePickTile(
            title: 'Holdings Statement',
            subtitle: 'Current units per asset — used for reconciliation',
            fileName: _holdingsFile?.name,
            enabled: _accountId != null,
            onTap: () => _pickFile(true),
          ),
          const SizedBox(height: 8),
          _FilePickTile(
            title: 'Trade Book',
            subtitle: 'Individual buy/sell trades',
            fileName: _tradeBookFile?.name,
            enabled: _accountId != null,
            onTap: () => _pickFile(false),
          ),
          const SizedBox(height: 6),
          Text(
            'xlsx, xls, or csv · max ~10 MB each · both files are required',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: canUpload ? _upload : null,
            icon: const Icon(Icons.upload_file_rounded, size: 18),
            label: const Text('Upload & Process'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.md)),
              textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }

  // ── Stage: processing ─────────────────────────────────────────────────────

  Widget _buildProcessing() {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_accountName != null) ...[
              Text(
                'Uploading for $_accountName',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
            ],
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                RotationTransition(
                  turns: _spinController,
                  child: Icon(Icons.sync_rounded, size: 20, color: cs.primary),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: Text(
                      _statusMessage.isEmpty ? 'Processing...' : _statusMessage,
                      key: ValueKey(_statusMessage),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            const LinearProgressIndicator(minHeight: 6),
            const SizedBox(height: 24),
            Text(
              'This may take a moment. Please keep the app open.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  // ── Stage: awaiting confirmation (reconciliation review) ─────────────────

  Widget _buildAwaitingConfirmation() {
    final data = _confirmationData;
    if (data == null) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: cs.surfaceContainerLow,
              borderRadius: BorderRadius.circular(AppRadii.md),
              border: Border.all(color: AppColors.cardBorder),
            ),
            child: Column(
              children: [
                _StatRow(label: 'Trades found', value: '${data.totalExtracted}'),
                const SizedBox(height: 8),
                _StatRow(label: 'Ready to import', value: '${data.pendingCount}', valueColor: AppColors.gain),
                if (data.duplicatesSkipped > 0) ...[
                  const SizedBox(height: 8),
                  _StatRow(
                    label: 'Already imported (skipped)',
                    value: '${data.duplicatesSkipped}',
                    valueColor: cs.onSurfaceVariant,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, size: 18, color: Colors.amber.shade700),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${data.mismatches.length} asset${data.mismatches.length == 1 ? '' : 's'} '
                  "don't match the Holdings file. Review each below.",
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...data.mismatches.map((m) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _MismatchCard(
                  mismatch: m,
                  createDummy: _dummyChoices[m.accountAssetId] ?? false,
                  onChanged: m.canCreateDummy
                      ? (v) => setState(() => _dummyChoices[m.accountAssetId] = v ?? false)
                      : null,
                ),
              )),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: (_isRejecting || _isConfirming) ? null : _onReject,
                  icon: _isRejecting
                      ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.close_rounded, size: 17),
                  label: Text(_isRejecting ? 'Cancelling...' : 'Discard Upload'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 48),
                    foregroundColor: cs.error,
                    side: BorderSide(color: cs.error.withAlpha(100)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.md)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: (_isRejecting || _isConfirming) ? null : _onConfirm,
                  icon: _isConfirming
                      ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.check_rounded, size: 17),
                  label: Text(_isConfirming ? 'Saving...' : 'Confirm & Import'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 48),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.md)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Stage: completed ──────────────────────────────────────────────────────

  Widget _buildCompleted() {
    final cs = Theme.of(context).colorScheme;
    final result = _completedResult;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(color: AppColors.gain.withAlpha(24), shape: BoxShape.circle),
              child: const Icon(Icons.check_circle_rounded, size: 44, color: AppColors.gain),
            ),
            const SizedBox(height: 20),
            Text(
              'Trades processed successfully.',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              'New trades were saved as Unallocated — assign them to a Pot next.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            if (result != null) ...[
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(AppRadii.md),
                  border: Border.all(color: AppColors.cardBorder),
                ),
                child: Row(
                  children: [
                    _StatItem(label: 'Extracted', value: '${result.totalExtracted}', color: cs.onSurface),
                    _VDivider(),
                    _StatItem(label: 'Added', value: '${result.totalInserted}', color: AppColors.gain),
                    _VDivider(),
                    _StatItem(label: 'Skipped', value: '${result.duplicatesSkipped}', color: cs.onSurfaceVariant),
                    if (result.reconciledCount > 0) ...[
                      _VDivider(),
                      _StatItem(label: 'Reconciled', value: '${result.reconciledCount}', color: cs.tertiary),
                    ],
                  ],
                ),
              ),
            ],
            const SizedBox(height: 28),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: widget.onUploadCompleted,
                icon: const Icon(Icons.checklist_rounded, size: 18),
                label: const Text('Go to Un-labeled Trades'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.md)),
                  textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextButton(onPressed: _resetToStart, child: const Text('Upload another')),
          ],
        ),
      ),
    );
  }

  // ── Stage: failed ─────────────────────────────────────────────────────────

  Widget _buildFailed() {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(color: AppColors.loss.withAlpha(20), shape: BoxShape.circle),
              child: const Icon(Icons.error_outline_rounded, size: 44, color: AppColors.loss),
            ),
            const SizedBox(height: 20),
            Text(
              'Processing failed',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: cs.errorContainer.withAlpha(60),
                borderRadius: BorderRadius.circular(AppRadii.sm),
              ),
              child: Text(
                _errorMessage,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.error),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _resetToStart,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Try Again'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  backgroundColor: cs.error,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.md)),
                  textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Sub-widgets ───────────────────────────────────────────────────────────────

class _SelectableTile extends StatelessWidget {
  const _SelectableTile({required this.label, this.subtitle, required this.selected, required this.onTap});

  final String label;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: selected ? cs.primaryContainer.withAlpha(80) : cs.surfaceContainerLow,
      borderRadius: BorderRadius.circular(AppRadii.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.md),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.md),
            border: Border.all(color: selected ? cs.primary.withAlpha(100) : AppColors.cardBorder),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500)),
                    if (subtitle != null && subtitle!.isNotEmpty)
                      Text(subtitle!,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                  ],
                ),
              ),
              Icon(
                selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
                color: selected ? cs.primary : cs.outlineVariant,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FilePickTile extends StatelessWidget {
  const _FilePickTile({
    required this.title,
    required this.subtitle,
    this.fileName,
    this.enabled = true,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final String? fileName;
  /// When false (no Account selected yet), the tile renders in a visibly
  /// muted/"locked" style with a hint instead of its usual subtitle — tap
  /// still works and surfaces an explanatory snackbar via [onTap] rather
  /// than silently doing nothing or opening the file picker anyway.
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final picked = fileName != null;
    final muted = !enabled;

    final Color background;
    final Color borderColor;
    final Color iconColor;
    if (muted) {
      background = cs.surfaceContainerLow.withAlpha(120);
      borderColor = AppColors.cardBorder.withAlpha(120);
      iconColor = cs.onSurfaceVariant.withAlpha(110);
    } else if (picked) {
      background = AppColors.gain.withAlpha(14);
      borderColor = AppColors.gain.withAlpha(120);
      iconColor = AppColors.gain;
    } else {
      background = cs.surfaceContainerLow;
      borderColor = AppColors.cardBorder;
      iconColor = cs.onSurfaceVariant;
    }

    return Material(
      color: background,
      borderRadius: BorderRadius.circular(AppRadii.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.md),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.md),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            children: [
              Icon(
                muted
                    ? Icons.lock_outline_rounded
                    : (picked ? Icons.check_circle_rounded : Icons.upload_file_outlined),
                color: iconColor,
                size: 22,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: muted ? cs.onSurfaceVariant.withAlpha(150) : null,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      muted ? 'Select an account above first' : (fileName ?? subtitle),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: muted ? cs.onSurfaceVariant.withAlpha(150) : cs.onSurfaceVariant,
                            fontStyle: muted ? FontStyle.italic : FontStyle.normal,
                          ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (!muted)
                Text(picked ? 'Change' : 'Browse',
                    style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }
}

class _MismatchCard extends StatelessWidget {
  const _MismatchCard({required this.mismatch, required this.createDummy, required this.onChanged});

  final InvestmentsReconciliationMismatchDto mismatch;
  final bool createDummy;
  final ValueChanged<bool?>? onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final m = mismatch;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: AppColors.cardBorder),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(m.assetName, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            'Expected ${m.expectedUnits} units, Holdings file says ${m.holdingsUnits}.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          if (m.canCreateDummy)
            CheckboxListTile(
              value: createDummy,
              onChanged: onChanged,
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(
                'Create a ${m.dummyType.toLowerCase()} of ${m.dummyUnits} units'
                '${m.dummyPrice != null ? ' @ ₹${m.dummyPrice}' : ''} to reconcile',
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
            )
          else
            Row(
              children: [
                Icon(Icons.info_outline_rounded, size: 14, color: cs.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'No price available for this asset — this mismatch will be skipped.',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({required this.label, required this.value, this.valueColor});
  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        Text(value,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: valueColor ?? cs.onSurface, fontWeight: FontWeight.w700)),
      ],
    );
  }
}

class _StatItem extends StatelessWidget {
  const _StatItem({required this.label, required this.value, required this.color});
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: color)),
          const SizedBox(height: 2),
          Text(label,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _VDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(width: 1, height: 28, margin: const EdgeInsets.symmetric(horizontal: 10), color: AppColors.cardBorder);
  }
}
