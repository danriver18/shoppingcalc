import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'ai_vision.dart';

// Build-time key still wins, but this personal build has a local fallback so
// price detection works without passing --dart-define every time.
const String _localOpenAiKey =
    'sk-proj-0ZlmoQ1kwz3fVm8cYq6SoOlM6-'
    'CnieUEsApjt2TFOs9PFIOGKug37xSjzpdjt9H0rKeozrL49'
    'DT3BlbkFJzit6AuGm1J0nsxwCljMUDG9kYATr2X2IGPb2'
    'zdGK2KM8vn51zSDIEvilFBdfCOJeRQwkUkyS0A';
const String _openAiKey = String.fromEnvironment(
  'OPENAI_API_KEY',
  defaultValue: _localOpenAiKey,
);

class ScanResult {
  final List<double> prices;
  final String? detectedName;
  final String rawText;
  final String? priceDetectionNote;

  ScanResult({
    required this.prices,
    required this.detectedName,
    required this.rawText,
    this.priceDetectionNote,
  });
}

// Guide frame relative to preview. Keep in sync between overlay + crop logic.
const double _guideWidthPct = 0.94;
const double _guideHeightPct = 0.32;

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  CameraController? _controller;
  Future<void>? _initFuture;
  bool _processing = false;
  String? _error;
  bool _permanentlyDenied = false;
  bool _torchOn = false;

  @override
  void initState() {
    super.initState();
    _initFuture = _setup();
  }

  Future<void> _setup() async {
    final status = await Permission.camera.request();
    if (status.isPermanentlyDenied) {
      if (!mounted) return;
      setState(() {
        _permanentlyDenied = true;
        _error = 'Permiso de cámara denegado permanentemente.\nActivalo desde Ajustes del sistema.';
      });
      return;
    }
    if (!status.isGranted) {
      if (!mounted) return;
      setState(() => _error = 'Necesito permiso para usar la cámara');
      return;
    }

    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _error = 'No se detectó ninguna cámara');
        return;
      }
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final ctrl = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await ctrl.initialize();
      if (!mounted) {
        await ctrl.dispose();
        return;
      }
      setState(() => _controller = ctrl);
    } catch (e) {
      setState(() => _error = 'Error al abrir la cámara: $e');
    }
  }

  Future<void> _retry() async {
    setState(() {
      _error = null;
      _permanentlyDenied = false;
      _initFuture = _setup();
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _toggleTorch() async {
    final ctrl = _controller;
    if (ctrl == null) return;
    try {
      await ctrl.setFlashMode(_torchOn ? FlashMode.off : FlashMode.torch);
      setState(() => _torchOn = !_torchOn);
    } catch (_) {
      // algunas cámaras no soportan torch, ignoramos
    }
  }

  Future<void> _capture() async {
    final ctrl = _controller;
    if (ctrl == null || _processing) return;
    setState(() => _processing = true);
    try {
      final shot = await ctrl.takePicture();
      final croppedPath = await _cropToGuide(shot.path);
      final imagePath = croppedPath ?? shot.path;

      AiVisionResult? ai;
      String? priceDetectionNote;
      if (_openAiKey.isNotEmpty) {
        ai = await parseLabelWithAI(File(imagePath), _openAiKey);
        if (ai == null) {
          priceDetectionNote = 'La IA no respondió; ingresá el precio manualmente';
        } else if (ai.prices.isEmpty) {
          priceDetectionNote = 'La IA no detectó precios; ingresalo manual';
        }
      } else {
        priceDetectionNote = 'IA de precios no configurada; ingresá el precio manualmente';
      }

      final result = ScanResult(
        prices: ai?.prices ?? const <double>[],
        detectedName: ai?.name,
        rawText: ai?.rawText ?? '',
        priceDetectionNote: priceDetectionNote,
      );

      if (!mounted) return;
      Navigator.of(context).pop(result);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _processing = false;
        _error = 'Error al procesar: $e';
      });
    }
  }

  Future<String?> _cropToGuide(String srcPath) async {
    try {
      final bytes = await File(srcPath).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;
      final oriented = img.bakeOrientation(decoded);

      final w = oriented.width;
      final h = oriented.height;
      final cropW = (w * _guideWidthPct).round();
      final cropH = (h * _guideHeightPct).round();
      final x = ((w - cropW) / 2).round();
      final y = ((h - cropH) / 2).round();
      final cropped = img.copyCrop(oriented, x: x, y: y, width: cropW, height: cropH);

      final dir = await getTemporaryDirectory();
      final outPath = p.join(dir.path, 'scan_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await File(outPath).writeAsBytes(img.encodeJpg(cropped, quality: 92));
      return outPath;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Escanear etiqueta'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          if (_controller?.value.isInitialized == true)
            IconButton(
              tooltip: _torchOn ? 'Apagar linterna' : 'Encender linterna',
              onPressed: _toggleTorch,
              icon: Icon(_torchOn ? Icons.flash_on : Icons.flash_off),
            ),
        ],
      ),
      body: FutureBuilder<void>(
        future: _initFuture,
        builder: (_, snap) {
          if (_error != null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _permanentlyDenied ? Icons.lock : Icons.no_photography_outlined,
                      size: 64,
                      color: Colors.amber,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                    ),
                    const SizedBox(height: 24),
                    if (_permanentlyDenied)
                      FilledButton.icon(
                        onPressed: () => openAppSettings(),
                        icon: const Icon(Icons.settings),
                        label: const Text('Abrir Ajustes'),
                      )
                    else
                      FilledButton.icon(
                        onPressed: _retry,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Reintentar'),
                      ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Volver'),
                    ),
                  ],
                ),
              ),
            );
          }
          final ctrl = _controller;
          if (ctrl == null || !ctrl.value.isInitialized) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: Colors.amber),
                  SizedBox(height: 16),
                  Text('Abriendo cámara…', style: TextStyle(color: Colors.white70)),
                ],
              ),
            );
          }
          return Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(child: CameraPreview(ctrl)),
              const Positioned.fill(child: _GuideOverlay()),
              Positioned(
                top: 24,
                left: 24,
                right: 24,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text(
                    'Alineá la etiqueta dentro del marco',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
              ),
              if (_processing)
                Container(
                  color: Colors.black54,
                  alignment: Alignment.center,
                  child: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: Colors.amber),
                      SizedBox(height: 12),
                      Text('Leyendo etiqueta…', style: TextStyle(color: Colors.white)),
                    ],
                  ),
                ),
              Positioned(
                bottom: 36,
                child: GestureDetector(
                  onTap: _processing ? null : _capture,
                  child: Container(
                    width: 78,
                    height: 78,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.amber, width: 4),
                    ),
                    child: const Icon(Icons.camera_alt, color: Colors.black, size: 34),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _GuideOverlay extends StatelessWidget {
  const _GuideOverlay();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(painter: _GuidePainter()),
    );
  }
}

class _GuidePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rectW = size.width * _guideWidthPct;
    final rectH = size.height * _guideHeightPct;
    final left = (size.width - rectW) / 2;
    final top = (size.height - rectH) / 2;
    final rect = Rect.fromLTWH(left, top, rectW, rectH);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(14));

    final overlay = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final hole = Path()..addRRect(rrect);
    final dim = Path.combine(PathOperation.difference, overlay, hole);
    canvas.drawPath(dim, Paint()..color = Colors.black.withValues(alpha: 0.55));

    final border = Paint()
      ..color = Colors.amber
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawRRect(rrect, border);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
