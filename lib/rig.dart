import 'package:flutter/material.dart';

/// The brushed face of the deck and mixer panels: a touch lighter at the top.
const kRigPanelFace = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [Color(0xFF16161D), Color(0xFF0E0E13)],
);

/// The look of the hardware: square corners, small labels in capitals, and
/// lights that show what's on.
const kRigCorner = 3.0;
const kRigAmber = Color(0xFFFF9F1C);
const kRigGreen = Color(0xFF3DDC6A);
const kRigFace = Color(0xFF16161D);

ThemeData rigTheme(ThemeData base) {
  final square = RoundedRectangleBorder(borderRadius: BorderRadius.circular(kRigCorner));
  return base.copyWith(
    visualDensity: VisualDensity.compact,
    chipTheme: base.chipTheme.copyWith(shape: square, showCheckmark: false, backgroundColor: kRigFace, side: const BorderSide(color: Colors.white12)),
    segmentedButtonTheme: SegmentedButtonThemeData(style: ButtonStyle(shape: WidgetStatePropertyAll(square))),
    elevatedButtonTheme: ElevatedButtonThemeData(style: ElevatedButton.styleFrom(shape: square)),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(shape: square)),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(shape: square)),
    popupMenuTheme: PopupMenuThemeData(shape: square, color: kRigFace),
    dialogTheme: DialogThemeData(shape: square, backgroundColor: kRigFace),
    tooltipTheme: TooltipThemeData(decoration: BoxDecoration(color: const Color(0xFF2A2A34), borderRadius: BorderRadius.circular(kRigCorner))),
  );
}

/// A lit button: the light says whether it's on. While [locked] it keeps
/// showing its state but can't be pressed.
class RigToggle extends StatelessWidget {
  final String label;
  final bool on;
  final Color color;
  final bool locked;
  final String? tooltip;
  final ValueChanged<bool>? onChanged;

  const RigToggle({
    super.key,
    required this.label,
    required this.on,
    this.color = kRigAmber,
    this.locked = false,
    this.tooltip,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final button = InkWell(
      onTap: locked || onChanged == null ? null : () => onChanged!(!on),
      borderRadius: BorderRadius.circular(kRigCorner),
      child: Container(
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        decoration: BoxDecoration(
          color: on ? color.withValues(alpha: 0.14) : kRigFace,
          borderRadius: BorderRadius.circular(kRigCorner),
          border: Border.all(color: on ? color : Colors.white12),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: on ? color : Colors.white12,
              shape: BoxShape.circle,
              boxShadow: on ? [BoxShadow(color: color.withValues(alpha: 0.8), blurRadius: 6)] : null,
            ),
          ),
          const SizedBox(width: 7),
          Text(
            label.toUpperCase(),
            style: TextStyle(fontSize: 11, letterSpacing: 0.7, fontWeight: FontWeight.w700, color: on ? Colors.white : Colors.white54),
          ),
        ]),
      ),
    );
    final tip = locked ? 'Locked while your set is being made' : tooltip;
    return tip == null ? button : Tooltip(message: tip, child: button);
  }
}
