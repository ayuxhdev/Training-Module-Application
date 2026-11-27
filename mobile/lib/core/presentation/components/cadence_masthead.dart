import 'package:flutter/material.dart';

import '../../theme/cadence_tokens.dart';
import 'gardens_need_logo.dart';

/// Editorial Masthead: original mark on white, never recolored or stretched.
class CadenceMasthead extends StatelessWidget implements PreferredSizeWidget {
  final Widget action;
  const CadenceMasthead({super.key, required this.action});
  static const logoAsset = GardensNeedLogo.asset;
  @override
  Size get preferredSize => const Size.fromHeight(96);
  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    child: SafeArea(
      bottom: false,
      child: Container(
        height: preferredSize.height,
        padding: const EdgeInsets.symmetric(
          horizontal: CadenceTokens.pagePadding,
        ),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: CadenceTokens.line)),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final showProductLabel =
                constraints.maxWidth >= 340 &&
                MediaQuery.textScalerOf(context).scale(12) <= 16;
            return Row(
              children: [
                const GardensNeedLogo(
                  width: 144,
                  height: 72,
                  whitePlate: false,
                  label: "Garden's Need Training Module",
                ),
                if (showProductLabel) ...[
                  const SizedBox(width: 12),
                  const SizedBox(
                    height: 28,
                    child: VerticalDivider(width: 1, color: CadenceTokens.line),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Training\nModule',
                      style: TextStyle(
                        color: CadenceTokens.muted,
                        fontSize: 12,
                        height: 1.4,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ] else
                  const Spacer(),
                const SizedBox(width: 12),
                IconButtonTheme(
                  data: IconButtonThemeData(
                    style: IconButton.styleFrom(
                      foregroundColor: CadenceTokens.ink,
                      backgroundColor: CadenceTokens.canvas,
                      minimumSize: const Size(48, 48),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                  child: action,
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}
