import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

class ScanResult {
  final List<double> prices;
  final String? detectedName;
  final String rawText;
  ScanResult({required this.prices, required this.detectedName, required this.rawText});
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
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final shot = await ctrl.takePicture();
      final croppedPath = await _cropToGuide(shot.path);
      final input = InputImage.fromFilePath(croppedPath ?? shot.path);
      final recognized = await recognizer.processImage(input);
      final result = _parse(recognized);
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _processing = false;
        _error = 'Error al procesar: $e';
      });
    } finally {
      await recognizer.close();
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

  ScanResult _parse(RecognizedText recognized) {
    // Strict: prices explicitly prefixed with "$". Group 2 catches superscript
    // cents that OCR often splits onto a separate line (e.g. "$ 23,⁹⁰").
    final dollarPrice = RegExp(r'\$\s*(\d[\d.,]*\d|\d)(?:[,\s]{1,3}(\d{2}))?');
    // Loose: any number with thousands/decimal separators, even without "$",
    // for labels where OCR drops the dollar sign. Plain integers (barcodes,
    // dates, codes) are excluded because they need at least one separator.
    final loosePrice = RegExp(
      r'(?:^|[^\d.,])(\d{1,3}(?:[.,]\d{3})+(?:[.,]\d{1,2})?|\d{1,6}[.,]\d{1,2})(?:[^\d.,]|$)',
    );
    // Track each detected price with the maximum line height seen for it —
    // taller line = bigger font = more likely to be the headline price.
    final priceHeights = <double, double>{};
    final nameCandidates = <_NameCandidate>[];
    final digitsOnly = RegExp(r'^[\d.,\s]+$');

    void notePrice(double? v, double h) {
      if (v == null || v <= 0 || v >= 1e9) return;
      final prev = priceHeights[v] ?? 0;
      if (h > prev) priceHeights[v] = h;
    }

    for (final block in recognized.blocks) {
      final blockMaxH = block.lines.isEmpty
          ? 0.0
          : block.lines
              .map((l) => l.boundingBox.height.toDouble())
              .reduce((a, b) => a > b ? a : b);
      final blockNormalized = _normalizeOcrDigits(block.text);
      for (final line in block.lines) {
        final text = line.text.trim();
        if (text.isEmpty) continue;
        final h = line.boundingBox.height.toDouble();
        final normalized = _normalizeOcrDigits(text);
        bool hadPrice = false;
        for (final m in dollarPrice.allMatches(normalized)) {
          notePrice(_parsePrice(m.group(1)!, cents: m.group(2)), h);
          hadPrice = true;
        }
        for (final m in loosePrice.allMatches(normalized)) {
          notePrice(_parsePrice(m.group(1)!), h);
          hadPrice = true;
        }
        if (!hadPrice && !digitsOnly.hasMatch(text)) {
          nameCandidates.add(_NameCandidate(text, h));
        }
      }
      // Block-level matches catch prices split across lines (superscript cents).
      for (final m in dollarPrice.allMatches(blockNormalized)) {
        notePrice(_parsePrice(m.group(1)!, cents: m.group(2)), blockMaxH);
      }
      for (final m in loosePrice.allMatches(blockNormalized)) {
        notePrice(_parsePrice(m.group(1)!), blockMaxH);
      }
    }
    // Cross-block fallback (uses height 0 so these rank last).
    final recognizedNormalized = _normalizeOcrDigits(recognized.text);
    for (final m in dollarPrice.allMatches(recognizedNormalized)) {
      notePrice(_parsePrice(m.group(1)!, cents: m.group(2)), 0);
    }

    // Supermarket "superscript cents" recovery: when the integer part (like
    // "23,") and the 2-digit cents ("90") end up on distant lines due to
    // visual noise, pair them up and expose every combination as a chip.
    final orphanInts = <(int, double)>[];
    final orphanCents = <(String, double)>[];
    final intCommaLine = RegExp(r'^\$?\s*(\d{1,6}),\s*$');
    final centsLine = RegExp(r'^(\d{2})$');
    for (final block in recognized.blocks) {
      for (final line in block.lines) {
        final t = _normalizeOcrDigits(line.text.trim());
        final h = line.boundingBox.height.toDouble();
        final im = intCommaLine.firstMatch(t);
        final cm = centsLine.firstMatch(t);
        if (im != null) {
          orphanInts.add((int.parse(im.group(1)!), h));
        } else if (cm != null) {
          orphanCents.add((cm.group(1)!, h));
        }
      }
    }
    for (final (iv, ih) in orphanInts) {
      for (final (cs, ch) in orphanCents) {
        final combined = double.tryParse('$iv.$cs');
        if (combined != null && combined > 0) {
          notePrice(combined, ih > ch ? ih : ch);
        }
      }
    }

    // Sort prices by visual prominence (tallest first), tie-break by value desc.
    final sorted = priceHeights.entries.toList()
      ..sort((a, b) {
        final c = b.value.compareTo(a.value);
        if (c != 0) return c;
        return b.key.compareTo(a.key);
      });
    final prices = sorted.map((e) => e.key).toList();
    final name = _guessName(nameCandidates);
    return ScanResult(prices: prices, detectedName: name, rawText: recognized.text);
  }

  // Fix common OCR confusions when a letter appears adjacent to digits:
  // O/o/D/Q → 0, I/l/| → 1, S → 5, B → 8. Applies only next to other
  // digits so we don't mangle regular words.
  String _normalizeOcrDigits(String s) {
    return s
        .replaceAllMapped(
          RegExp(r'(?<=\d)[OoDQ]|[OoDQ](?=\d)'),
          (_) => '0',
        )
        .replaceAllMapped(
          RegExp(r'(?<=\d)[Il|]|[Il|](?=\d)'),
          (_) => '1',
        )
        .replaceAllMapped(
          RegExp(r'(?<=\d)[Ss]|[Ss](?=\d)'),
          (_) => '5',
        )
        .replaceAllMapped(
          RegExp(r'(?<=\d)B|B(?=\d)'),
          (_) => '8',
        );
  }

  // Parses a price string like "2.69", "1.234,50", "1,234.56", "1.600.900",
  // "16.090,0" — auto-detects AR (., decimal=,) vs US (,, decimal=.) locale.
  // If [cents] is provided (from superscript capture), uses it directly.
  double? _parsePrice(String raw, {String? cents}) {
    if (cents != null && cents.isNotEmpty) {
      final clean = raw.replaceAll(RegExp(r'[.,\s]'), '');
      if (clean.isEmpty) return null;
      return double.tryParse('$clean.$cents');
    }
    final dotIdx = raw.lastIndexOf('.');
    final commaIdx = raw.lastIndexOf(',');
    String intStr;
    String decStr = '0';

    if (dotIdx < 0 && commaIdx < 0) {
      intStr = raw;
    } else if (dotIdx >= 0 && commaIdx >= 0) {
      // Both separators present: the rightmost one is the decimal.
      if (dotIdx > commaIdx) {
        intStr = raw.substring(0, dotIdx).replaceAll(',', '');
        decStr = raw.substring(dotIdx + 1);
      } else {
        intStr = raw.substring(0, commaIdx).replaceAll('.', '');
        decStr = raw.substring(commaIdx + 1);
      }
    } else {
      final sep = dotIdx >= 0 ? '.' : ',';
      final lastIdx = dotIdx >= 0 ? dotIdx : commaIdx;
      final count = sep.allMatches(raw).length;
      final afterLast = raw.substring(lastIdx + 1);
      if (count > 1 || afterLast.length == 3) {
        // Multiple occurrences or 3 trailing digits → thousands separator.
        intStr = raw.replaceAll(sep, '');
      } else {
        // Single separator with 1–2 trailing digits → decimal.
        intStr = raw.substring(0, lastIdx);
        decStr = afterLast;
      }
    }

    intStr = intStr.replaceAll(RegExp(r'\D'), '');
    decStr = decStr.replaceAll(RegExp(r'\D'), '');
    if (intStr.isEmpty) return null;
    if (decStr.isEmpty) decStr = '0';
    return double.tryParse('$intStr.$decStr');
  }

  String? _guessName(List<_NameCandidate> candidates) {
    final noise = RegExp(
      r'^(oferta|promo|promoción|promocion|precio|precios|descuento|descto|desc\.?|dcto\.?|dto\.?|lleva|pague|antes|ahora|hoy|nuevo|nueva|ref\w*|cod\.?|código|codigo|lpp|rnpd|sku|gratis|origen|scanning|scan\b|peso\s+neto|solo\s|familiar|cuidados|x\s*\d|\d+\s*x|\d+%)',
      caseSensitive: false,
    );
    final repeatedPattern = RegExp(r'(.{2})\1{2,}');
    final letterRegex = RegExp(r'[A-Za-zÁÉÍÓÚÑáéíóúñ]');
    bool dominatedByOneChar(String s) {
      final letters = s.replaceAll(RegExp(r'\s'), '').toUpperCase();
      if (letters.length < 4) return false;
      final counts = <String, int>{};
      for (final ch in letters.split('')) {
        counts[ch] = (counts[ch] ?? 0) + 1;
      }
      final maxCount = counts.values.reduce((a, b) => a > b ? a : b);
      return maxCount / letters.length > 0.5;
    }

    final filtered = candidates
        .where((c) => c.text.length >= 4)
        .where((c) => !noise.hasMatch(c.text))
        .where((c) => !repeatedPattern.hasMatch(c.text))
        .where((c) => !dominatedByOneChar(c.text))
        .where((c) => letterRegex.allMatches(c.text).length >= 3)
        .toList();
    if (filtered.isEmpty) return null;
    // Prefer largest font (tallest bounding box); tie-break by length.
    filtered.sort((a, b) {
      final cmp = b.height.compareTo(a.height);
      if (cmp != 0) return cmp;
      return b.text.length.compareTo(a.text.length);
    });
    return filtered.first.text;
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

class _NameCandidate {
  final String text;
  final double height;
  _NameCandidate(this.text, this.height);
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
