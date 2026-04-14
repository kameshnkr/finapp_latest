import 'package:flutter/material.dart';

/// Shows a floating snackbar anchored just below the app bar.
void showTopSnack(BuildContext context, String message) {
  final mq = MediaQuery.of(context);
  final bottomMargin = mq.size.height
      - mq.viewPadding.top
      - kToolbarHeight
      - 64; // reserve space for the snackbar itself

  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.only(
          bottom: bottomMargin.clamp(0.0, double.infinity),
          left: 16,
          right: 16,
        ),
      ),
    );
}
