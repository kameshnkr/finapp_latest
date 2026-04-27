import 'package:flutter/material.dart';

/// Shows a brief toast pinned just below the status bar / app bar.
/// Uses an Overlay so it works from any nested widget context.
void showTopSnack(BuildContext context, String message) {
  final overlay = Overlay.of(context, rootOverlay: true);
  late OverlayEntry entry;

  entry = OverlayEntry(
    builder: (_) => _TopToast(message: message),
  );

  overlay.insert(entry);

  Future.delayed(const Duration(milliseconds: 1800), () {
    if (entry.mounted) entry.remove();
  });
}

class _TopToast extends StatefulWidget {
  const _TopToast({required this.message});
  final String message;

  @override
  State<_TopToast> createState() => _TopToastState();
}

class _TopToastState extends State<_TopToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _opacity = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _ctrl.forward();

    // Start fade-out before the entry is removed.
    Future.delayed(const Duration(milliseconds: 1200), () {
      if (mounted) _ctrl.reverse();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final cs = Theme.of(context).colorScheme;

    return Positioned(
      top: mq.viewPadding.top + 8,
      left: 24,
      right: 24,
      child: FadeTransition(
        opacity: _opacity,
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: cs.inverseSurface,
              borderRadius: BorderRadius.circular(10),
              boxShadow: const [
                BoxShadow(
                    color: Colors.black26, blurRadius: 8, offset: Offset(0, 3)),
              ],
            ),
            child: Text(
              widget.message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: cs.onInverseSurface,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
