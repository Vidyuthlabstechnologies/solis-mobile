import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Finger signature capture. Points are stored normalized to 0..1 so the
/// signature can be redrawn at any size; a pen lift is stored as (-1, -1).
///
/// The pad claims every drag that starts on it at once, so a downward stroke
/// can never be taken by a surrounding scroll view or a bottom sheet's
/// drag-to-dismiss.
class SignaturePad extends StatefulWidget {
  final ValueChanged<List<List<double>>> onChanged;
  final double height;

  const SignaturePad({super.key, required this.onChanged, this.height = 180});

  @override
  State<SignaturePad> createState() => SignaturePadState();
}

class SignaturePadState extends State<SignaturePad> {
  final List<Offset?> _points = [];
  Size _size = Size.zero;

  /// Number of pen-down points (for tests and "is it signed" checks).
  int get pointCount => _points.whereType<Offset>().length;

  void _add(Offset? p) {
    setState(() => _points.add(p));
    widget.onChanged([
      for (final q in _points) q == null ? [-1, -1] : [q.dx / _size.width, q.dy / _size.height],
    ]);
  }

  void clear() {
    setState(_points.clear);
    widget.onChanged(const []);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          label: 'Signature area. Sign with your finger.',
          child: Container(
            height: widget.height,
            decoration: BoxDecoration(
              color: cs.surfaceContainerLowest,
              border: Border.all(color: cs.outline),
              borderRadius: BorderRadius.circular(12),
            ),
            child: LayoutBuilder(builder: (context, c) {
              _size = Size(c.maxWidth, c.maxHeight);
              return RawGestureDetector(
                behavior: HitTestBehavior.opaque,
                gestures: {
                  _ImmediatePanRecognizer: GestureRecognizerFactoryWithHandlers<_ImmediatePanRecognizer>(
                    _ImmediatePanRecognizer.new,
                    (r) => r
                      ..onStart = ((d) => _add(d.localPosition))
                      ..onUpdate = ((d) {
                        final p = d.localPosition;
                        if (p.dx >= 0 && p.dy >= 0 && p.dx <= _size.width && p.dy <= _size.height) _add(p);
                      })
                      ..onEnd = ((_) => _add(null)),
                  ),
                },
                child: CustomPaint(
                  painter: _SignaturePainter(_points, cs.onSurface),
                  child: _points.isEmpty
                      ? Center(child: Text('Sign here', style: TextStyle(color: cs.onSurfaceVariant)))
                      : const SizedBox.expand(),
                ),
              );
            }),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: _points.isEmpty ? null : clear,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Clear'),
          ),
        ),
      ],
    );
  }
}

/// A pan recognizer that wins the gesture arena on pointer down, so the
/// surrounding scroll view and sheet never see the stroke.
class _ImmediatePanRecognizer extends PanGestureRecognizer {
  _ImmediatePanRecognizer() : super(debugOwner: null);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

class _SignaturePainter extends CustomPainter {
  final List<Offset?> points;
  final Color color;
  _SignaturePainter(this.points, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (var i = 0; i < points.length - 1; i++) {
      final a = points[i], b = points[i + 1];
      if (a != null && b != null) canvas.drawLine(a, b, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SignaturePainter old) => true;
}
