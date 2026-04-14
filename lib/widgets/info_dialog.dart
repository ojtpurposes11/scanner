import 'package:flutter/material.dart';

/// Info dialog — shows step-by-step guide on how to search a plate.
class InfoDialog extends StatelessWidget {
  const InfoDialog();

  @override
  Widget build(BuildContext context) {
    final steps = [
      _Step(
        number: '1',
        icon: Icons.camera_alt_rounded,
        title: 'Camera Scan',
        description:
            'Tap "Camera Scan" on the dashboard. Point your camera at the plate, frame it inside the scan box, then tap the shutter button. The app reads and searches the plate automatically.',
      ),
      _Step(
        number: '2',
        icon: Icons.mic_rounded,
        title: 'Audio Search',
        description:
            'Tap "Audio Search" then speak the plate number clearly — letter by letter if needed (e.g. "A B C 1 2 3 4"). The app will transcribe it and run the search.',
      ),
      _Step(
        number: '3',
        icon: Icons.keyboard_rounded,
        title: 'Type Search',
        description:
            'Tap "Type Search", type the plate number or conduction sticker (6–7 characters, letters and numbers only), then tap the Search button or press Enter.',
      ),
      _Step(
        number: '4',
        icon: Icons.fact_check_rounded,
        title: 'Reading the Result',
        description:
            'A result sheet pops up showing all matching records — owner name, case number, branch, and more. If no match is found, you can search again right away using the same method.',
      ),
      _Step(
        number: '5',
        icon: Icons.repeat_rounded,
        title: 'Search Again',
        description:
            'After viewing a result, tap the red button to repeat the same search method — no need to go back to the dashboard. Switch methods anytime from the dashboard.',
      ),
    ];

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Header ──────────────────────────────────
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 20, 16, 20),
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
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: const Icon(Icons.help_outline_rounded,
                        color: Colors.white, size: 22),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('How to Search',
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                color: Colors.white)),
                        SizedBox(height: 2),
                        Text('Step-by-step guide',
                            style: TextStyle(
                                fontSize: 12,
                                color: Colors.white70)),
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

            // ── Steps ───────────────────────────────────
            Flexible(
              child: ListView.separated(
                padding: const EdgeInsets.all(20),
                shrinkWrap: true,
                itemCount: steps.length,
                separatorBuilder: (_, __) => const SizedBox(height: 16),
                itemBuilder: (_, i) => _StepCard(step: steps[i]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Step model ───────────────────────────────────────────────────

class _Step {
  final String number;
  final IconData icon;
  final String title;
  final String description;
  const _Step({
    required this.number,
    required this.icon,
    required this.title,
    required this.description,
  });
}

// ── Step card ────────────────────────────────────────────────────

class _StepCard extends StatelessWidget {
  final _Step step;
  const _StepCard({required this.step});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: const BoxDecoration(
            color: Color(0xFFFF0000),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(step.number,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w800)),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(step.icon, size: 15, color: const Color(0xFFCC0000)),
                  const SizedBox(width: 6),
                  Text(step.title,
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF1A1A1A))),
                ],
              ),
              const SizedBox(height: 4),
              Text(step.description,
                  style: TextStyle(
                      fontSize: 12.5,
                      color: Colors.grey[600],
                      height: 1.5)),
            ],
          ),
        ),
      ],
    );
  }
}