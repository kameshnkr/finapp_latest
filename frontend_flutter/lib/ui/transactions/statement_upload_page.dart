import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/app_theme.dart';
import '../../data/models/models.dart';
import '../../state/app_controller.dart';
import 'transaction_flow_screens.dart';

class StatementUploadPage extends StatefulWidget {
  const StatementUploadPage({super.key});

  @override
  State<StatementUploadPage> createState() => _StatementUploadPageState();
}

enum _UploadStage { selectAccount, processing, completed, failed }

class _StatementUploadPageState extends State<StatementUploadPage>
    with SingleTickerProviderStateMixin {
  _UploadStage _stage = _UploadStage.selectAccount;

  String? _selectedAccountId;
  String? _selectedAccountName;
  String? _pickedFileName;

  String _jobId = '';
  String _statusMessage = '';
  // null = indeterminate, 0.0–1.0 = determinate
  double? _progress;
  String _progressLabel = '';
  StatementJobResultDto? _result;
  String _errorMessage = '';

  Timer? _pollTimer;

  // Continuous spin animation for the processing indicator
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

  // ── File pick + upload ───────────────────────────────────────────────────

  Future<void> _pickAndUpload() async {
    final accountId = _selectedAccountId;
    if (accountId == null) return;

    // Capture before any async gap
    final app = context.read<AppController>();

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
      allowMultiple: false,
      withData: true, // required on web; fine on native too
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.single;
    final fileBytes = file.bytes;
    if (fileBytes == null || fileBytes.isEmpty) {
      _showError('Could not read file data. Please try again.');
      return;
    }

    setState(() {
      _stage = _UploadStage.processing;
      _pickedFileName = file.name;
      _statusMessage = 'Uploading...';
    });

    try {
      final job = await app.api.uploadStatement(
        accountId: accountId,
        fileBytes: fileBytes,
        fileName: file.name,
      );
      _jobId = job.jobId;
      _startPolling();
    } catch (e) {
      _showError(e.toString());
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _pollStatus();
    });
  }

  Future<void> _pollStatus() async {
    if (_jobId.isEmpty) return;
    try {
      final app = context.read<AppController>();
      final job = await app.api.getStatementStatus(_jobId);

      if (!mounted) return;

      if (job.status == 'COMPLETED') {
        _pollTimer?.cancel();
        await app.refreshTransactions();
        setState(() {
          _stage = _UploadStage.completed;
          _result = job.result;
        });
      } else if (job.status == 'FAILED') {
        _pollTimer?.cancel();
        setState(() {
          _stage = _UploadStage.failed;
          _errorMessage = job.errorMessage ?? 'Processing failed';
        });
      } else {
        final msg = job.message ?? _labelFor(job.status);
        final parsed = _parseProgress(msg, job.status);
        setState(() {
          _statusMessage = msg;
          _progress = parsed.$1;
          _progressLabel = parsed.$2;
        });
      }
    } catch (_) {
      // Polling errors are transient — keep retrying
    }
  }

  String _labelFor(String status) {
    switch (status) {
      case 'UPLOADING':
        return 'Uploading...';
      case 'PROCESSING':
        return 'Extracting transactions...';
      case 'VALIDATING':
        return 'Validating data...';
      case 'SAVING':
        return 'Saving drafts...';
      default:
        return status;
    }
  }

  /// Returns (progress 0–1 or null, label string) from a backend status message.
  /// Handles:
  ///   "Extracting transactions... (page 3 of 9)"     → 3/9
  ///   "Extracting transactions... (pages 4–6 of 9)"  → 6/9 (end of batch)
  ///   "Validating data..."                            → 0.92
  ///   "Saving drafts..."                              → 0.97
  (double?, String) _parseProgress(String message, String status) {
    // Extraction is capped at 85% so the bar never hits 100% while still processing.
    // The remaining 15% is filled by VALIDATING (92%) and SAVING (97%).
    const extractionCap = 0.85;

    // Single page: "page 3 of 9"
    final single = RegExp(r'page (\d+) of (\d+)').firstMatch(message);
    if (single != null) {
      final cur = int.parse(single.group(1)!);
      final total = int.parse(single.group(2)!);
      final ratio = (cur / total * extractionCap).clamp(0.0, extractionCap);
      final pct = (ratio * 100).round();
      return (ratio, 'Page $cur of $total · $pct%');
    }
    // Batch range: "pages 4–6 of 9"
    final range = RegExp(r'pages (\d+)[–\-](\d+) of (\d+)').firstMatch(message);
    if (range != null) {
      final end = int.parse(range.group(2)!);
      final total = int.parse(range.group(3)!);
      final ratio = (end / total * extractionCap).clamp(0.0, extractionCap);
      final pct = (ratio * 100).round();
      return (ratio, 'Pages ${range.group(1)}–$end of $total · $pct%');
    }
    // Fixed stages
    if (status == 'VALIDATING') return (0.92, 'Validating · 92%');
    if (status == 'SAVING')     return (0.97, 'Saving · 97%');
    // Uploading / unknown — indeterminate
    return (null, '');
  }

  void _showError(String msg) {
    setState(() {
      _stage = _UploadStage.failed;
      _errorMessage = msg;
    });
  }

  void _resetToStart() {
    _pollTimer?.cancel();
    setState(() {
      _stage = _UploadStage.selectAccount;
      _pickedFileName = null;
      _jobId = '';
      _statusMessage = '';
      _progress = null;
      _progressLabel = '';
      _result = null;
      _errorMessage = '';
    });
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    switch (_stage) {
      case _UploadStage.selectAccount:
        return _buildSelectAccount();
      case _UploadStage.processing:
        return _buildProcessing();
      case _UploadStage.completed:
        return _buildCompleted();
      case _UploadStage.failed:
        return _buildFailed();
    }
  }

  // ── Stage: select account ────────────────────────────────────────────────

  Widget _buildSelectAccount() {
    final app = context.watch<AppController>();
    final accounts = app.accounts;
    final cs = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: cs.primaryContainer.withAlpha(60),
                    borderRadius: BorderRadius.circular(AppRadii.md),
                    border: Border.all(color: cs.primary.withAlpha(40)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: cs.primaryContainer,
                          borderRadius: BorderRadius.circular(AppRadii.sm),
                        ),
                        child: Icon(Icons.upload_file_rounded,
                            color: cs.primary, size: 22),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Upload Bank Statement',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'PDF format · max 20 MB',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(color: cs.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 24),
                Text(
                  'Select Account',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                ),
                const SizedBox(height: 10),

                // Account list
                ...accounts.map((a) => _AccountTile(
                      account: a,
                      isSelected: _selectedAccountId == a.id,
                      onTap: () => setState(() {
                        _selectedAccountId = a.id;
                        _selectedAccountName = a.name;
                      }),
                    )),
              ],
            ),
          ),
        ),

        // Bottom action
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_selectedAccountId != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _SelectedBadge(name: _selectedAccountName ?? ''),
                ),
              FilledButton.icon(
                onPressed:
                    _selectedAccountId != null ? _pickAndUpload : null,
                icon: const Icon(Icons.upload_file_rounded, size: 18),
                label: const Text('Pick PDF & Upload'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadii.md)),
                  textStyle: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 15),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Stage: processing ────────────────────────────────────────────────────

  Widget _buildProcessing() {
    final cs = Theme.of(context).colorScheme;
    final statusText = _statusMessage.isEmpty
        ? 'Processing...'
        : _statusMessage.replaceAll(RegExp(r'\s*\(.*?\)'), '');

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Spinning icon + status label
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
                      statusText,
                      key: ValueKey(statusText),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Progress bar — animates smoothly between values
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.0, end: _progress ?? 0.0),
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeInOut,
              builder: (context, value, _) => ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  // If no progress data yet, show indeterminate
                  value: _progress == null ? null : value,
                  minHeight: 8,
                  backgroundColor: cs.surfaceContainerHighest,
                  color: cs.primary,
                ),
              ),
            ),
            const SizedBox(height: 8),

            // File name (left) · progress label (right)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                if (_pickedFileName != null)
                  Flexible(
                    child: Text(
                      _pickedFileName!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  )
                else
                  const SizedBox.shrink(),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: _progressLabel.isNotEmpty
                      ? Text(
                          _progressLabel,
                          key: ValueKey(_progressLabel),
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: cs.primary,
                                fontWeight: FontWeight.w600,
                              ),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),

            const SizedBox(height: 24),
            Text(
              'This may take a moment. Please keep the app open.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  // ── Stage: completed ─────────────────────────────────────────────────────

  Widget _buildCompleted() {
    final cs = Theme.of(context).colorScheme;
    final result = _result;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: AppColors.gain.withAlpha(24),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_circle_rounded,
                  size: 44, color: AppColors.gain),
            ),
            const SizedBox(height: 20),
            Text(
              'Statement processed successfully.',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              'Transactions have been added to your drafts.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
              textAlign: TextAlign.center,
            ),

            // Stats
            if (result != null) ...[
              const SizedBox(height: 20),
              _ResultStats(result: result),
            ],

            // Validation warning
            if (result?.validationStatus == 'REVIEW_REQUIRED') ...[
              const SizedBox(height: 16),
              _ValidationWarning(),
            ],

            // File cleanup hint
            if (_pickedFileName != null) ...[
              const SizedBox(height: 16),
              _FileCleanupHint(fileName: _pickedFileName!),
            ],

            const SizedBox(height: 28),

            // CTA
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () {
                  // Remove the AddDraftFlowScreen from the stack and
                  // push DraftsFlowScreen directly — same entry point as
                  // tapping "Drafts" in the bottom bar.
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute<void>(
                        builder: (_) => const DraftsFlowScreen()),
                    (route) => route.isFirst,
                  );
                },
                icon: const Icon(Icons.inbox_outlined, size: 18),
                label: const Text('Go to Drafts'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadii.md)),
                  textStyle: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 15),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _resetToStart,
              child: const Text('Upload another statement'),
            ),
          ],
        ),
      ),
    );
  }

  // ── Stage: failed ────────────────────────────────────────────────────────

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
              decoration: BoxDecoration(
                color: AppColors.loss.withAlpha(20),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.error_outline_rounded,
                  size: 44, color: AppColors.loss),
            ),
            const SizedBox(height: 20),
            Text(
              'Processing failed',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: cs.errorContainer.withAlpha(60),
                borderRadius: BorderRadius.circular(AppRadii.sm),
              ),
              child: Text(
                _errorMessage,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.error,
                    ),
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
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadii.md)),
                  textStyle: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 15),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Sub-widgets ──────────────────────────────────────────────────────────────

class _AccountTile extends StatelessWidget {
  const _AccountTile({
    required this.account,
    required this.isSelected,
    required this.onTap,
  });

  final AccountDto account;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: isSelected
            ? cs.primaryContainer.withAlpha(80)
            : cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadii.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadii.md),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadii.md),
              border: Border.all(
                color: isSelected
                    ? cs.primary.withAlpha(100)
                    : AppColors.cardBorder,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? cs.primary
                        : cs.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      account.name.isNotEmpty
                          ? account.name[0].toUpperCase()
                          : '?',
                      style: TextStyle(
                        color: isSelected
                            ? cs.onPrimary
                            : cs.onPrimaryContainer,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    account.name,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                  ),
                ),
                if (isSelected)
                  Icon(Icons.check_circle_rounded,
                      color: cs.primary, size: 20)
                else
                  Icon(Icons.radio_button_unchecked,
                      color: cs.outlineVariant, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SelectedBadge extends StatelessWidget {
  const _SelectedBadge({required this.name});
  final String name;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: cs.primaryContainer.withAlpha(60),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: cs.primary.withAlpha(60)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.account_balance_wallet_outlined,
              size: 14, color: cs.primary),
          const SizedBox(width: 6),
          Text(
            name,
            style: TextStyle(
                fontSize: 12,
                color: cs.primary,
                fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _ResultStats extends StatelessWidget {
  const _ResultStats({required this.result});
  final StatementJobResultDto result;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Row(
        children: [
          _StatItem(
            label: 'Extracted',
            value: '${result.totalExtracted}',
            color: cs.onSurface,
          ),
          _Divider(),
          _StatItem(
            label: 'Added',
            value: '${result.totalInserted}',
            color: AppColors.gain,
          ),
          _Divider(),
          _StatItem(
            label: 'Skipped',
            value: '${result.duplicatesSkipped}',
            color: cs.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 32,
      margin: const EdgeInsets.symmetric(horizontal: 12),
      color: AppColors.cardBorder,
    );
  }
}

class _StatItem extends StatelessWidget {
  const _StatItem({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(value,
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: color)),
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

class _ValidationWarning extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.amber.shade50,
        borderRadius: BorderRadius.circular(AppRadii.sm),
        border: Border.all(color: Colors.amber.shade300),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded,
              size: 16, color: Colors.amber.shade700),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Balance check did not match. Please review your drafts.',
              style: TextStyle(
                  fontSize: 12,
                  color: Colors.amber.shade800,
                  fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}

class _FileCleanupHint extends StatelessWidget {
  const _FileCleanupHint({required this.fileName});
  final String fileName;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppRadii.sm),
        border: Border.all(color: AppColors.cardBorder),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded,
              size: 15, color: cs.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fileName,
                  style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurface,
                      fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  'You can delete this file from your device if no longer needed.',
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

