import 'package:flutter/material.dart';

import '../../core/app_theme.dart';

/// App-level profile/account content — not Banking- or Investments-specific
/// (same logged-in user either way), so it's shared shell-level UI reused by
/// both sections' independent "Profile" nav destination. Extracted (no
/// behavior change) from what was previously a private `_ProfileView` in
/// `home_screen.dart`.
class ProfileView extends StatelessWidget {
  const ProfileView({super.key, required this.onLogout});

  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
      children: [
        // Avatar + name
        Center(
          child: Column(
            children: [
              CircleAvatar(
                radius: 38,
                backgroundColor: cs.primaryContainer,
                child: Icon(
                  Icons.person_rounded,
                  size: 38,
                  color: cs.primary,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'My Profile',
                style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 28),
            ],
          ),
        ),
        _ProfileItem(
          icon: Icons.person_outline_rounded,
          label: 'Profile',
          onTap: () {},
        ),
        _ProfileItem(
          icon: Icons.settings_outlined,
          label: 'Settings',
          onTap: () {},
        ),
        const SizedBox(height: 8),
        _ProfileItem(
          icon: Icons.logout_rounded,
          label: 'Logout',
          color: cs.error,
          onTap: onLogout,
        ),
      ],
    );
  }
}

class _ProfileItem extends StatelessWidget {
  const _ProfileItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final effectiveColor = color ?? cs.onSurface;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.md),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          child: Row(
            children: [
              Icon(icon, size: 20, color: effectiveColor),
              const SizedBox(width: 14),
              Text(
                label,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w500,
                      color: effectiveColor,
                    ),
              ),
              const Spacer(),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: cs.outlineVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
