import 'package:flutter/material.dart';

/// DeepSeek 式双横线（上一长下一短），用于推出 L2 侧栏。
class L2MenuIcon extends StatelessWidget {
  const L2MenuIcon({super.key, this.color = const Color(0xFF1A1A1A)});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 22,
      height: 18,
      child: CustomPaint(painter: _L2MenuIconPainter(color)),
    );
  }
}

class _L2MenuIconPainter extends CustomPainter {
  _L2MenuIconPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final y1 = size.height * 0.32;
    final y2 = size.height * 0.68;
    canvas.drawLine(Offset(0, y1), Offset(size.width, y1), p);
    canvas.drawLine(Offset(0, y2), Offset(size.width * 0.62, y2), p);
  }

  @override
  bool shouldRepaint(covariant _L2MenuIconPainter old) => old.color != color;
}

/// 豆包式推出侧栏：浅色对齐 Web；[enableEdgeSwipe] 为 false 时仅图标开合（日常页）。
class L2SideDrawer extends StatefulWidget {
  const L2SideDrawer({
    super.key,
    required this.child,
    required this.drawer,
    this.widthFraction = 0.82,
    this.enableEdgeSwipe = true,
    this.open,
    this.onOpenChanged,
  });

  final Widget child;
  final Widget drawer;
  final double widthFraction;
  final bool enableEdgeSwipe;
  final bool? open;
  final ValueChanged<bool>? onOpenChanged;

  @override
  State<L2SideDrawer> createState() => L2SideDrawerState();
}

class L2SideDrawerState extends State<L2SideDrawer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  bool _internalOpen = false;

  bool get isOpen => widget.open ?? _internalOpen;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
      value: (widget.open ?? false) ? 1 : 0,
    );
  }

  @override
  void didUpdateWidget(covariant L2SideDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.open != null && widget.open != oldWidget.open) {
      if (widget.open!) {
        _ctrl.forward();
      } else {
        _ctrl.reverse();
      }
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void open() => _setOpen(true);
  void close() => _setOpen(false);
  void toggle() => _setOpen(!isOpen);

  void _setOpen(bool v) {
    if (widget.open != null) {
      widget.onOpenChanged?.call(v);
      return;
    }
    setState(() => _internalOpen = v);
    if (v) {
      _ctrl.forward();
    } else {
      _ctrl.reverse();
    }
    widget.onOpenChanged?.call(v);
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width * widget.widthFraction;
    return Stack(
      children: [
        widget.child,
        AnimatedBuilder(
          animation: _ctrl,
          builder: (context, _) {
            final t = Curves.easeOutCubic.transform(_ctrl.value);
            if (t <= 0.001) return const SizedBox.shrink();
            return Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    onTap: close,
                    child: ColoredBox(
                      color: Colors.black.withOpacity(0.28 * t),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: w,
                  child: Transform.translate(
                    offset: Offset(-w * (1 - t), 0),
                    child: Material(
                      color: const Color(0xFFF7F7F8),
                      elevation: 8,
                      shadowColor: Colors.black26,
                      child: SafeArea(child: widget.drawer),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
        if (widget.enableEdgeSwipe)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 18,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragUpdate: (d) {
                if (d.delta.dx > 6) open();
              },
            ),
          ),
      ],
    );
  }
}
