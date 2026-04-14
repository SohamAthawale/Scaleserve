import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const scaleServeBrandStillAsset =
    'assets/branding/Screenshot 2026-04-14 at 3.13.22\u202fPM.png';
const scaleServeBrandVideoAsset =
    'assets/branding/original-f95aa1e1f118f9069c1ba55f4e125876.mp4';

class ScaleServeBrandPalette {
  static const Color obsidian = Color(0xFF050505);
  static const Color carbon = Color(0xFF0B0D0B);
  static const Color graphite = Color(0xFF141713);
  static const Color lime = Color(0xFFA2FF5A);
  static const Color limeHighlight = Color(0xFFA2FF5A);
  static const Color mist = Color(0xFFF5F6F0);
  static const Color cloud = Color(0xFFF2F4EE);
  static const Color steel = Color(0xFF646C63);

  static const LinearGradient brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [obsidian, carbon, graphite],
    stops: [0, 0.55, 1],
  );

  static const LinearGradient accentGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [lime, lime],
    stops: [0, 1],
  );

  static const LinearGradient shellGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [obsidian, obsidian, carbon],
    stops: [0, 0.55, 1],
  );
}

ColorScheme scaleServeColorScheme() {
  return const ColorScheme.light(
    primary: ScaleServeBrandPalette.lime,
    onPrimary: ScaleServeBrandPalette.obsidian,
    primaryContainer: Color(0xFFE6F7D6),
    onPrimaryContainer: ScaleServeBrandPalette.obsidian,
    secondary: ScaleServeBrandPalette.obsidian,
    onSecondary: ScaleServeBrandPalette.mist,
    secondaryContainer: Color(0xFFF0F3EA),
    onSecondaryContainer: ScaleServeBrandPalette.obsidian,
    tertiary: Color(0xFF6A7563),
    onTertiary: Colors.white,
    surface: Color(0xFFFAFBF7),
    onSurface: Color(0xFF0D100D),
    surfaceContainerHighest: Color(0xFFE5EAE1),
    onSurfaceVariant: ScaleServeBrandPalette.steel,
    outline: Color(0xFFA6AEA3),
    outlineVariant: Color(0xFFD4DAD0),
    error: Color(0xFFC7422F),
    onError: Colors.white,
    shadow: Color(0x26000000),
  );
}

class ScaleServeShellBackground extends StatelessWidget {
  const ScaleServeShellBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: ScaleServeBrandPalette.shellGradient,
      ),
      child: child,
    );
  }
}

class ScaleServeBrandLockupImage extends StatelessWidget {
  const ScaleServeBrandLockupImage({
    super.key,
    this.height,
    this.width,
    this.fit = BoxFit.contain,
  });

  final double? height;
  final double? width;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      scaleServeBrandStillAsset,
      height: height,
      width: width,
      fit: fit,
      filterQuality: FilterQuality.high,
    );
  }
}

class ScaleServeBrandVideoPanel extends StatelessWidget {
  const ScaleServeBrandVideoPanel({
    super.key,
    this.aspectRatio = 908 / 500,
    this.borderRadius = 24,
    this.fit = BoxFit.cover,
  });

  final double aspectRatio;
  final double borderRadius;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: AspectRatio(
        aspectRatio: aspectRatio,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: ScaleServeBrandPalette.obsidian),
            const ScaleServeBrandLockupImage(fit: BoxFit.cover),
            if (defaultTargetPlatform == TargetPlatform.macOS)
              AppKitView(
                viewType: 'scaleserve.brand_video',
                creationParams: <String, Object?>{
                  'asset': scaleServeBrandVideoAsset,
                  'gravity': fit == BoxFit.contain ? 'fit' : 'fill',
                },
                creationParamsCodec: const StandardMessageCodec(),
              ),
          ],
        ),
      ),
    );
  }
}

class ScaleServeBrandMark extends StatelessWidget {
  const ScaleServeBrandMark({super.key, this.size = 56, this.withTile = false});

  final double size;
  final bool withTile;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _ScaleServeBrandMarkPainter(withTile: withTile),
      ),
    );
  }
}

class ScaleServeWordmarkLockup extends StatelessWidget {
  const ScaleServeWordmarkLockup({
    super.key,
    this.markSize = 52,
    this.title = 'scale',
    this.subtitle,
    this.titleStyle,
    this.subtitleStyle,
    this.withTile = false,
  });

  final double markSize;
  final String title;
  final String? subtitle;
  final TextStyle? titleStyle;
  final TextStyle? subtitleStyle;
  final bool withTile;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        ScaleServeBrandMark(size: markSize, withTile: withTile),
        const SizedBox(width: 16),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    titleStyle ??
                    theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w900,
                      letterSpacing: -1.2,
                    ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style:
                      subtitleStyle ??
                      theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.45,
                      ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class ScaleServeFeatureBadge extends StatelessWidget {
  const ScaleServeFeatureBadge({
    super.key,
    required this.icon,
    required this.label,
    this.backgroundColor,
    this.foregroundColor,
    this.borderColor,
  });

  final IconData icon;
  final String label;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = foregroundColor ?? theme.colorScheme.onSurface;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color:
            backgroundColor ??
            theme.colorScheme.surface.withValues(alpha: 0.88),
        border: Border.all(
          color:
              borderColor ?? theme.colorScheme.outline.withValues(alpha: 0.18),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _ScaleServeBrandMarkPainter extends CustomPainter {
  const _ScaleServeBrandMarkPainter({required this.withTile});

  final bool withTile;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    if (withTile) {
      final roundedRect = RRect.fromRectAndRadius(
        rect,
        Radius.circular(size.width * 0.28),
      );
      canvas.drawRRect(
        roundedRect,
        Paint()
          ..shader = ScaleServeBrandPalette.brandGradient.createShader(rect),
      );
    }

    final topBlade = Path()
      ..moveTo(size.width * 0.26, size.height * 0.24)
      ..lineTo(size.width * 0.62, size.height * 0.24)
      ..lineTo(size.width * 0.48, size.height * 0.39)
      ..lineTo(size.width * 0.12, size.height * 0.39)
      ..close();

    final bottomBlade = Path()
      ..moveTo(size.width * 0.16, size.height * 0.54)
      ..lineTo(size.width * 0.52, size.height * 0.54)
      ..lineTo(size.width * 0.38, size.height * 0.69)
      ..lineTo(size.width * 0.02, size.height * 0.69)
      ..close();

    final markRect = Rect.fromLTWH(
      size.width * 0.02,
      size.height * 0.20,
      size.width * 0.60,
      size.height * 0.50,
    );
    final markPaint = Paint()
      ..shader = ScaleServeBrandPalette.accentGradient.createShader(markRect);

    canvas.drawPath(topBlade, markPaint);
    canvas.drawPath(bottomBlade, markPaint);

    final seamPath = Path()
      ..moveTo(size.width * 0.33, size.height * 0.39)
      ..lineTo(size.width * 0.40, size.height * 0.39)
      ..lineTo(size.width * 0.50, size.height * 0.54)
      ..lineTo(size.width * 0.43, size.height * 0.54)
      ..close();
    canvas.drawPath(
      seamPath,
      Paint()
        ..color = ScaleServeBrandPalette.obsidian.withValues(
          alpha: withTile ? 0.96 : 0.90,
        ),
    );
  }

  @override
  bool shouldRepaint(covariant _ScaleServeBrandMarkPainter oldDelegate) {
    return oldDelegate.withTile != withTile;
  }
}
