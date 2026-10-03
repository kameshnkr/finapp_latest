import 'package:flutter/material.dart';

/// Fixed pool of selectable Pot icons.
///
/// Keys MUST exactly match the backend's allow-list
/// (backend/src/constants/investmentsPotIcons.ts) — the backend only ever
/// stores/validates these string keys, never the [IconData] itself. Keep
/// both lists in sync (same keys) whenever the pool changes.
///
/// Deliberately all plain Material [IconData] (flat, single-color,
/// platform-independent) — no emoji glyphs. An earlier attempt at an emoji
/// override for 'gold' (🪙, then 🏅) looked inconsistent next to the rest of
/// this grid and rendered unpredictably differently per platform/OS font,
/// so every entry here stays a standard Material icon for a uniform look.
const Map<String, IconData> kInvestmentsPotIcons = {
  'savings': Icons.savings_rounded,
  'home': Icons.home_rounded,
  // Classic office/apartment building silhouette (Material's closest
  // equivalent to the 🏢 emoji) — reads clearly as "real estate".
  'real_estate': Icons.apartment_rounded,
  'car': Icons.directions_car_rounded,
  'travel': Icons.flight_rounded,
  'beach': Icons.beach_access_rounded,
  // Graduation cap — the standard, unambiguous "education" symbol; pairs
  // with 'child_care' below for a "Child Education" Pot.
  'school': Icons.school_rounded,
  // Parent-and-child silhouette — clearer "child/family" signal than the
  // previous baby-face smiley, which didn't read as finance-related at all.
  'child_care': Icons.family_restroom_rounded,
  'health': Icons.health_and_safety_rounded,
  'retirement': Icons.elderly_rounded,
  // Solid gem/jewel shape — reads as "precious item/valuable", unlike a
  // coin or $/₹ glyph which reads as generic cash rather than gold
  // specifically. Material has no literal gold-bar/bullion icon, so this is
  // the closest non-monetary-looking match available.
  'gold': Icons.diamond_rounded,
  'currency': Icons.currency_rupee_rounded,
  // Upward stock-chart line — standard "equity/growth" symbol (e.g.
  // "Equity Long Term").
  'trending_up': Icons.trending_up_rounded,
  // Classical bank/pillars building — standard "debt/fixed-income/bonds"
  // symbol (e.g. "Debt Long Term"), distinct from the plain 'wallet' icon.
  'account_balance': Icons.account_balance_rounded,
  'wallet': Icons.account_balance_wallet_rounded,
  'shield': Icons.shield_rounded,
  'gift': Icons.card_giftcard_rounded,
  'celebration': Icons.celebration_rounded,
  'pets': Icons.pets_rounded,
  'business': Icons.business_center_rounded,
  'laptop': Icons.laptop_mac_rounded,
  'phone': Icons.smartphone_rounded,
  'fitness': Icons.fitness_center_rounded,
  'star': Icons.star_rounded,
  'flag': Icons.flag_rounded,
  'charity': Icons.volunteer_activism_rounded,
};

const String kDefaultPotIconKey = 'savings';

/// Resolves a stored icon key to its [IconData], falling back to the
/// default for any unknown/legacy/null key — defensive, never throws on
/// unexpected data (e.g. an icon key added to the backend's allow-list by a
/// server deploy that shipped ahead of a matching app update).
IconData resolvePotIcon(String? iconKey) =>
    kInvestmentsPotIcons[iconKey] ?? kInvestmentsPotIcons[kDefaultPotIconKey]!;
