import 'package:flutter/material.dart';

/// Renders [text] ellipsis-truncated to a single line when [expanded] is
/// false, or fully wrapped onto as many lines as needed when [expanded] is
/// true.
///
/// Purely presentational — deliberately holds NO gesture handling or state
/// of its own. The expand/collapse state is owned by the surrounding
/// card/row (e.g. via its own `onTap`, or an `ExpansionTile`'s
/// `onExpansionChanged`), so that there is exactly ONE tap target per card
/// that reveals the full name together with whatever else that same tap
/// reveals (e.g. a Pot allocation breakdown) — rather than the name having
/// its own independent tap zone that only reveals the name and nothing else.
class ExpandableNameText extends StatelessWidget {
  const ExpandableNameText(
    this.text, {
    super.key,
    this.style,
    this.expanded = false,
  });

  final String text;
  final TextStyle? style;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: style,
      maxLines: expanded ? null : 1,
      overflow: expanded ? TextOverflow.visible : TextOverflow.ellipsis,
      softWrap: expanded,
    );
  }
}
