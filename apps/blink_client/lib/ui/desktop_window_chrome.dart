import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import 'package:blink_client/app/blink_theme.dart';

/// Standard height of the unified desktop top strip (`docs/ui.md`).
const double kBlinkWindowChromeHeaderHeight = 44.0;

/// Width of each Windows 11-proportioned caption button (`─`, `□`/`❐`, `×`).
const double kBlinkWindowCaptionButtonWidth = 46.0;

/// Total width reserved at the top-right for the three caption controls (`3 × 46`).
const double kBlinkWindowCaptionWidth = kBlinkWindowCaptionButtonWidth * 3;

/// Top inset reserved in the leading icon rail for native macOS traffic lights.
const double kBlinkMacTrafficLightTopInset = 28.0;

/// Inherited desktop window chrome metrics and callbacks for immersive
/// borderless windows (`TitleBarStyle.hidden`).
class BlinkWindowChromeScope extends InheritedWidget {
  const BlinkWindowChromeScope({
    required this.enabled,
    required this.trailingCaptionInset,
    this.leadingTrafficLightInset = 0.0,
    this.onStartDrag,
    this.onToggleMaximize,
    this.onShowSystemMenu,
    this.onMaximizeButtonBoundsChanged,
    required super.child,
    super.key,
  });

  /// Whether custom immersive window chrome (drag areas / caption controls) is active.
  final bool enabled;

  /// Trailing width reserved in the top `44px` main-panel header row (`138.0` on
  /// Windows/Linux when enabled; `0.0` on macOS, mobile, or tests without custom chrome).
  final double trailingCaptionInset;

  /// Top inset reserved above the leading icon rail brand mark (`28.0` on macOS
  /// when enabled; `0.0` elsewhere).
  final double leadingTrafficLightInset;

  /// Starts a native OS window drag gesture.
  final VoidCallback? onStartDrag;

  /// Toggles native window maximize/restore (e.g. on title-bar double click).
  final VoidCallback? onToggleMaximize;

  /// Opens the native OS window system menu at a window-local logical [Offset].
  final ValueChanged<Offset>? onShowSystemMenu;

  /// Reports the logical client-area bounds of the custom Maximize button so
  /// Windows 11 can surface native Snap Layouts on hover (`null` clears).
  final ValueChanged<Rect?>? onMaximizeButtonBoundsChanged;

  static BlinkWindowChromeScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BlinkWindowChromeScope>();

  /// Returns the trailing header inset reserved for desktop caption controls,
  /// or `0.0` when no trailing caption controls are active.
  static double trailingInsetOf(BuildContext context) =>
      maybeOf(context)?.trailingCaptionInset ?? 0.0;

  /// Returns the top inset reserved for leading native window controls (macOS),
  /// or `0.0` otherwise.
  static double leadingTrafficLightInsetOf(BuildContext context) =>
      maybeOf(context)?.leadingTrafficLightInset ?? 0.0;

  @override
  bool updateShouldNotify(covariant BlinkWindowChromeScope oldWidget) =>
      enabled != oldWidget.enabled ||
      trailingCaptionInset != oldWidget.trailingCaptionInset ||
      leadingTrafficLightInset != oldWidget.leadingTrafficLightInset ||
      onStartDrag != oldWidget.onStartDrag ||
      onToggleMaximize != oldWidget.onToggleMaximize ||
      onShowSystemMenu != oldWidget.onShowSystemMenu ||
      onMaximizeButtonBoundsChanged != oldWidget.onMaximizeButtonBoundsChanged;
}

/// Makes an immersive top header background draggable to move the desktop window,
/// double-clickable to toggle maximize/restore, and right-clickable to open the
/// native window system menu.
///
/// Places the drag/double-click/system-menu [GestureDetector] as a **background
/// sibling** inside a [Stack] behind [child] rather than an ancestor, so
/// interactive descendants (buttons, menus, text fields) absorb pointer events
/// before the drag layer enters the gesture arena — guaranteeing `0ms` button
/// click latency and ensuring rapid double-clicks on toolbar buttons never
/// trigger window maximize/restore.
///
/// Callers should keep opaque header background `Container(color/decoration)`
/// wrappers **outside** [BlinkWindowDragArea] and wrap non-interactive header
/// labels (such as `Expanded(child: Text(...))`) in [IgnorePointer] so empty
/// header space falls through cleanly to the background drag layer. When
/// immersive desktop chrome is disabled, returns [child] directly.
class BlinkWindowDragArea extends StatelessWidget {
  const BlinkWindowDragArea({
    required this.child,
    this.enabled = true,
    super.key,
  });

  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled) {
      return child;
    }
    final scope = BlinkWindowChromeScope.maybeOf(context);
    if (scope == null || !scope.enabled) {
      return child;
    }

    final showMenuOnRelease = defaultTargetPlatform == TargetPlatform.windows;
    final showSystemMenu = scope.onShowSystemMenu;

    return Stack(
      fit: StackFit.passthrough,
      children: <Widget>[
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => scope.onStartDrag?.call(),
            onDoubleTap: () => scope.onToggleMaximize?.call(),
            onSecondaryTapDown: showSystemMenu == null || showMenuOnRelease
                ? null
                : (details) => showSystemMenu(details.globalPosition),
            onSecondaryTapUp: showSystemMenu == null || !showMenuOnRelease
                ? null
                : (details) => showSystemMenu(details.globalPosition),
          ),
        ),
        child,
      ],
    );
  }
}

/// Minimal, crisp Windows 11-proportioned (`138 × 44`, `3 × 46px`) caption
/// controls (`─` Minimize, `□`/`❐` Maximize/Restore, `×` Close) styled solely
/// with [BlinkColorTokens].
class BlinkWindowCaptionButtons extends StatelessWidget {
  const BlinkWindowCaptionButtons({
    required this.isMaximized,
    required this.onMinimize,
    required this.onToggleMaximize,
    required this.onClose,
    this.height = kBlinkWindowChromeHeaderHeight,
    super.key,
  });

  final bool isMaximized;
  final VoidCallback onMinimize;
  final VoidCallback onToggleMaximize;
  final VoidCallback onClose;
  final double height;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    final onBoundsChanged = BlinkWindowChromeScope.maybeOf(context)
        ?.onMaximizeButtonBoundsChanged;

    return SizedBox(
      key: const Key('window_caption_buttons'),
      width: kBlinkWindowCaptionWidth,
      height: height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _CaptionControlButton(
            buttonKey: const Key('window_minimize_button'),
            tooltip: '最小化',
            semanticsLabel: '最小化窗口',
            width: kBlinkWindowCaptionButtonWidth,
            height: height,
            glyph: _CaptionGlyph.minimize,
            normalIconColor: tokens.textSecondary,
            hoverIconColor: tokens.textPrimary,
            hoverBackgroundColor: tokens.borderHairline.withValues(alpha: 0.45),
            pressedBackgroundColor: tokens.borderHairline.withValues(
              alpha: 0.75,
            ),
            onPressed: onMinimize,
          ),
          _MaximizeBoundsReporter(
            onBoundsChanged: onBoundsChanged,
            child: _CaptionControlButton(
              buttonKey: const Key('window_maximize_button'),
              tooltip: isMaximized ? '向下还原' : '最大化',
              semanticsLabel: isMaximized ? '向下还原窗口' : '最大化窗口',
              width: kBlinkWindowCaptionButtonWidth,
              height: height,
              glyph: isMaximized
                  ? _CaptionGlyph.restore
                  : _CaptionGlyph.maximize,
              normalIconColor: tokens.textSecondary,
              hoverIconColor: tokens.textPrimary,
              hoverBackgroundColor: tokens.borderHairline.withValues(
                alpha: 0.45,
              ),
              pressedBackgroundColor: tokens.borderHairline.withValues(
                alpha: 0.75,
              ),
              onPressed: onToggleMaximize,
            ),
          ),
          _CaptionControlButton(
            buttonKey: const Key('window_close_button'),
            tooltip: '关闭',
            semanticsLabel: '关闭窗口',
            width: kBlinkWindowCaptionButtonWidth,
            height: height,
            glyph: _CaptionGlyph.close,
            normalIconColor: tokens.textSecondary,
            hoverIconColor: tokens.canvas,
            hoverBackgroundColor: tokens.statusErr,
            pressedBackgroundColor: tokens.statusErr.withValues(alpha: 0.85),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

enum _CaptionGlyph { minimize, maximize, restore, close }

class _CaptionControlButton extends StatefulWidget {
  const _CaptionControlButton({
    required this.buttonKey,
    required this.tooltip,
    required this.semanticsLabel,
    required this.width,
    required this.height,
    required this.glyph,
    required this.normalIconColor,
    required this.hoverIconColor,
    required this.hoverBackgroundColor,
    required this.pressedBackgroundColor,
    required this.onPressed,
  });

  final Key buttonKey;
  final String tooltip;
  final String semanticsLabel;
  final double width;
  final double height;
  final _CaptionGlyph glyph;
  final Color normalIconColor;
  final Color hoverIconColor;
  final Color hoverBackgroundColor;
  final Color pressedBackgroundColor;
  final VoidCallback onPressed;

  @override
  State<_CaptionControlButton> createState() => _CaptionControlButtonState();
}

class _CaptionControlButtonState extends State<_CaptionControlButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final background = _pressed
        ? widget.pressedBackgroundColor
        : _hovered
        ? widget.hoverBackgroundColor
        : Colors.transparent;
    final iconColor = (_hovered || _pressed)
        ? widget.hoverIconColor
        : widget.normalIconColor;

    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: Semantics(
        button: true,
        label: widget.semanticsLabel,
        child: MouseRegion(
          cursor: SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() {
            _hovered = false;
            _pressed = false;
          }),
          child: GestureDetector(
            key: widget.buttonKey,
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => setState(() => _pressed = true),
            onTapUp: (_) => setState(() => _pressed = false),
            onTapCancel: () => setState(() => _pressed = false),
            onTap: widget.onPressed,
            child: ColoredBox(
              color: background,
              child: SizedBox(
                width: widget.width,
                height: widget.height,
                child: Center(
                  child: CustomPaint(
                    size: const Size(12, 12),
                    painter: _CaptionGlyphPainter(
                      glyph: widget.glyph,
                      color: iconColor,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CaptionGlyphPainter extends CustomPainter {
  const _CaptionGlyphPainter({required this.glyph, required this.color});

  final _CaptionGlyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    switch (glyph) {
      case _CaptionGlyph.minimize:
        final y = size.height / 2;
        canvas.drawLine(Offset(1, y), Offset(size.width - 1, y), paint);
      case _CaptionGlyph.maximize:
        final rect = Rect.fromLTWH(
          1.2,
          1.2,
          size.width - 2.4,
          size.height - 2.4,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(1.2)),
          paint,
        );
      case _CaptionGlyph.restore:
        final front = Rect.fromLTWH(
          1.0,
          3.0,
          size.width - 4.0,
          size.height - 4.0,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(front, const Radius.circular(1.0)),
          paint,
        );
        final backPath = Path()
          ..moveTo(3.2, 3.0)
          ..lineTo(3.2, 1.8)
          ..quadraticBezierTo(3.2, 1.0, 4.0, 1.0)
          ..lineTo(size.width - 1.8, 1.0)
          ..quadraticBezierTo(size.width - 1.0, 1.0, size.width - 1.0, 1.8)
          ..lineTo(size.width - 1.0, size.height - 3.8)
          ..quadraticBezierTo(
            size.width - 1.0,
            size.height - 3.0,
            size.width - 1.8,
            size.height - 3.0,
          )
          ..lineTo(front.right, size.height - 3.0);
        canvas.drawPath(backPath, paint);
      case _CaptionGlyph.close:
        canvas.drawLine(
          const Offset(1.5, 1.5),
          Offset(size.width - 1.5, size.height - 1.5),
          paint,
        );
        canvas.drawLine(
          Offset(size.width - 1.5, 1.5),
          Offset(1.5, size.height - 1.5),
          paint,
        );
    }
  }

  @override
  bool shouldRepaint(covariant _CaptionGlyphPainter oldDelegate) =>
      oldDelegate.glyph != glyph || oldDelegate.color != color;
}

class _MaximizeBoundsReporter extends SingleChildRenderObjectWidget {
  const _MaximizeBoundsReporter({
    required this.onBoundsChanged,
    required Widget super.child,
  });

  final ValueChanged<Rect?>? onBoundsChanged;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMaximizeBoundsReporter(onBoundsChanged);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderMaximizeBoundsReporter renderObject,
  ) {
    renderObject.onBoundsChanged = onBoundsChanged;
  }
}

class _RenderMaximizeBoundsReporter extends RenderProxyBox {
  _RenderMaximizeBoundsReporter(this._onBoundsChanged);

  ValueChanged<Rect?>? _onBoundsChanged;
  Rect? _lastReported;
  bool _scheduled = false;

  set onBoundsChanged(ValueChanged<Rect?>? value) {
    if (_onBoundsChanged == value) {
      return;
    }
    if (_lastReported != null) {
      _onBoundsChanged?.call(null);
      _lastReported = null;
    }
    _onBoundsChanged = value;
    markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    if (_onBoundsChanged == null || _scheduled) {
      return;
    }
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!attached || !hasSize) {
        return;
      }
      final callback = _onBoundsChanged;
      if (callback == null) {
        return;
      }
      final bounds = localToGlobal(Offset.zero) & size;
      if (bounds == _lastReported) {
        return;
      }
      _lastReported = bounds;
      callback(bounds);
    });
  }

  @override
  void detach() {
    if (_lastReported != null) {
      _onBoundsChanged?.call(null);
      _lastReported = null;
    }
    super.detach();
  }
}
