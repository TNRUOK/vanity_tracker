import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';

class PaoGuideScreen extends StatelessWidget {
  const PaoGuideScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFDFBF9),
      appBar: AppBar(
        title: const Text('Cosmetic PAO Guide'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Hero Intro Banner
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppTheme.primaryRose, Color(0xFFC73E66)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.primaryRose.withValues(alpha: 0.3),
                    blurRadius: 15,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.av_timer_rounded, color: Colors.white, size: 28),
                      SizedBox(width: 10),
                      Text(
                        'What is PAO?',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 10),
                  Text(
                    'Period After Opening (PAO) indicates the recommended number of months a cosmetic product remains safe and effective to use after its protective seal is first broken and exposed to air.',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      height: 1.5,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Reading Open Jar Symbols
            const Text(
              'How to Read Open-Jar Symbols',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppTheme.textDark),
            ),
            const SizedBox(height: 6),
            const Text(
              'Look for the small open-jar icon printed on the back or bottom of cosmetic packaging with a number followed by "M" (Months).',
              style: TextStyle(fontSize: 13, color: AppTheme.textMuted, height: 1.4),
            ),
            const SizedBox(height: 14),

            _buildPaoSymbolCard(
              symbol: '3M',
              category: 'Ultra Short Shelf-Life (3 Months)',
              color: const Color(0xFFE63946),
              bgColor: const Color(0xFFFDE8E9),
              examples: 'Mascaras, liquid eyeliners, natural lash serums',
              whyItMatters:
                  'High moisture combined with frequent mucosal eye contact makes mascara tubes prime environments for rapid bacterial accumulation. Replace promptly every 3 months.',
            ),
            const SizedBox(height: 12),

            _buildPaoSymbolCard(
              symbol: '6M',
              category: 'Active & Liquid Formulations (6 Months)',
              color: const Color(0xFFF4A261),
              bgColor: const Color(0xFFFEF3E8),
              examples: 'Vitamin C serums, retinol, active chemical exfoliants, liquid concealers',
              whyItMatters:
                  'Potent active antioxidants and retinoids degrade rapidly upon exposure to ambient air and light, decreasing effectiveness and potentially causing skin irritation.',
            ),
            const SizedBox(height: 12),

            _buildPaoSymbolCard(
              symbol: '12M',
              category: 'Standard Skincare & Lotions (12 Months)',
              color: const Color(0xFF2A9D8F),
              bgColor: const Color(0xFFE6F5F3),
              examples: 'Hydrating moisturizers, gentle cleansers, hydrating toners, daily sunscreens (SPF)',
              whyItMatters:
                  'Water-based emulsions remain stable under typical preservative systems for about a year. Expired sunscreens lose UV filter efficacy and must not be used.',
            ),
            const SizedBox(height: 12),

            _buildPaoSymbolCard(
              symbol: '24M+',
              category: 'Anhydrous & Powder Products (24+ Months)',
              color: const Color(0xFF457B9D),
              bgColor: const Color(0xFFEBF2F7),
              examples: 'Pressed powder, powder blush, bronzers, solid lipsticks, mineral eyeshadows',
              whyItMatters:
                  'Without water or liquid media, bacteria struggle to multiply. Dry powders can last 2 to 3 years if brushes are kept sanitized and dry.',
            ),
            const SizedBox(height: 24),

            // Why shelf life varies
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0xFFF1ECE8)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.tune_rounded, color: AppTheme.primaryRose, size: 22),
                      SizedBox(width: 8),
                      Text(
                        'Why Real Shelf Life Varies',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textDark),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _buildBulletPoint('Packaging design', 'Airless vacuum pumps prevent air ingress, lasting far longer than wide-mouth jars where fingers introduce microbes.'),
                  _buildBulletPoint('Storage climate', 'Hot, humid bathrooms degrade preservatives faster. Store active serums in cool, dry areas away from direct sunlight.'),
                  _buildBulletPoint('Preservative systems', 'Clean/preservative-free products often have significantly shorter PAO limits than standard laboratory formulations.'),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Factory Sealed vs PAO Interaction
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0xFFF1ECE8)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.all_inclusive_rounded, color: Color(0xFF8B5CF6), size: 22),
                      SizedBox(width: 8),
                      Text(
                        'Sealed Batch vs PAO Expiry',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textDark),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Even unopened products degrade over time. That is why manufacturers print stamped sealed batch expiration dates (e.g. "EXP 12/2026").',
                    style: TextStyle(fontSize: 13, color: AppTheme.textDark, height: 1.4),
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF5F3FF),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.tips_and_updates_rounded, color: Color(0xFF8B5CF6), size: 18),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'How Vanity Tracker Calculates It:\nYour Effective Expiry Date is always the earlier of your PAO expiration and the stamped sealed batch date. Whichever comes first is when you should finish or replace the product.',
                            style: TextStyle(fontSize: 12, color: Color(0xFF4C1D95), height: 1.4, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Safety Disclaimer
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF3C7),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFFDE68A)),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline_rounded, color: Color(0xFFB45309), size: 20),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Important Disclaimer: PAO periods shown here are general educational benchmarks. Always defer to the exact label and manufacturer guidelines printed on your product packaging. Discontinue use immediately if a product changes color, smell, or consistency, or causes any skin irritation.',
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFF92400E),
                        height: 1.4,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildPaoSymbolCard({
    required String symbol,
    required String category,
    required Color color,
    required Color bgColor,
    required String examples,
    required String whyItMatters,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFF1ECE8)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: color.withValues(alpha: 0.3)),
            ),
            child: Center(
              child: Text(
                symbol,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                  color: color,
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  category,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: color),
                ),
                const SizedBox(height: 4),
                Text(
                  'Examples: $examples',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textDark),
                ),
                const SizedBox(height: 4),
                Text(
                  whyItMatters,
                  style: const TextStyle(fontSize: 12, color: AppTheme.textMuted, height: 1.35),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBulletPoint(String title, String desc) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('• ', style: TextStyle(fontWeight: FontWeight.w900, color: AppTheme.primaryRose)),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: const TextStyle(fontSize: 13, color: AppTheme.textDark, height: 1.35),
                children: [
                  TextSpan(text: '$title: ', style: const TextStyle(fontWeight: FontWeight.w700)),
                  TextSpan(text: desc),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
