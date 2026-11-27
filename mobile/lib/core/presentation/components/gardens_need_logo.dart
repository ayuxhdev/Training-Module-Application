import 'package:flutter/material.dart';

/// The approved wordmark, with a white surface when used over a themed UI.
class GardensNeedLogo extends StatelessWidget {
  const GardensNeedLogo({
    super.key,
    required this.width,
    required this.height,
    this.whitePlate = true,
    this.label = "Garden's Need",
  });

  static const asset = 'assets/brand/gardens_need_logo.png';
  final double width;
  final double height;
  final bool whitePlate;
  final String label;

  @override
  Widget build(BuildContext context) {
    final logo = Image.asset(
      asset,
      width: width,
      height: height,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
    );

    return Semantics(
      image: true,
      label: label,
      child: ExcludeSemantics(
        child: whitePlate
            ? DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Padding(padding: const EdgeInsets.all(4), child: logo),
              )
            : logo,
      ),
    );
  }
}

/// Keeps page titles and navigation controls in their existing AppBar slots.
class GardensNeedHeaderMark extends StatelessWidget {
  const GardensNeedHeaderMark({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsetsDirectional.only(end: 12),
    child: Center(child: GardensNeedLogo(width: 80, height: 36)),
  );
}
