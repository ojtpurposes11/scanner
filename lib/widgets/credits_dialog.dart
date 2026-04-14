import 'package:flutter/material.dart';

/// Credits dialog — shown when the ⓘ info icon is tapped.
/// Displays app information and the team behind it.
class CreditsDialog extends StatelessWidget {
  const CreditsDialog();

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 60),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Header ──────────────────────────────────
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 24, 16, 24),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFFCC0000), Color(0xFFFF2222)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    padding: const EdgeInsets.all(6),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.asset(
                        'assets/logo.png',
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Convergent Plate Scanner',
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                                color: Colors.white)),
                        SizedBox(height: 3),
                        Text('Version 2.0',
                            style: TextStyle(
                                fontSize: 12, color: Colors.white70)),
                      ],
                    ),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Icon(Icons.close_rounded,
                        color: Colors.white.withValues(alpha: 0.8), size: 22),
                  ),
                ],
              ),
            ),

            // ── Credits body ─────────────────────────────
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _CreditRow(
                    icon: Icons.groups_rounded,
                    label: 'Developed By',
                    value: 'Convergent IT Interns',
                  ),
                  _CreditRow(
                    icon: Icons.business_rounded,
                    label: 'Organization',
                    value: 'Convergent',
                  ),
                  _CreditRow(
                    icon: Icons.calendar_today_rounded,
                    label: 'Established',
                    value: '2026',
                  ),
                  _CreditRow(
                    icon: Icons.shield_outlined,
                    label: 'Purpose',
                    value:
                        'Vehicle plate tracking & lookup for field collectors across multiple data sources.',
                  ),
                  _CreditRow(
                    icon: Icons.cloud_outlined,
                    label: 'Backend',
                    value: 'Firebase Firestore — real-time cloud sync',
                  ),
                  _CreditRow(
                    icon: Icons.table_chart_outlined,
                    label: 'Data Sources',
                    value:
                        'Excel (.xlsx) databases uploaded and merged into a single searchable record.',
                  ),
                  const SizedBox(height: 20),
                  // Footer
                  Center(
                    child: Text(
                      '© 2026 Convergent. All rights reserved.',
                      style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey[400]),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CreditRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _CreditRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: const Color(0xFFFF0000)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey[500],
                        fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(value,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1A1A1A),
                        height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}