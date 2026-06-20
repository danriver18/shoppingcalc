import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

typedef AiVisionResult = ({List<double> prices, String? name, String rawText});

const String _openAiUrl = 'https://api.openai.com/v1/chat/completions';
const String _model = 'gpt-4o-mini';
const Duration _timeout = Duration(seconds: 20);

const String _systemPrompt = '''
You are a vision parser for supermarket product labels (mainly Argentine, sometimes US).
You receive a cropped photo of a single shelf label and must extract the product name and visible prices.

Return ONLY a valid JSON object, with this exact shape and keys:
{"name": "string", "price": 0.0, "alternatives": [0.0]}

Rules:
- "name": the best product/brand text visible on the label, as the shopper would say it. Keep accents. Trim leading/trailing whitespace.
- Do NOT leave "name" empty if any product, brand, variant, flavor, size, or category text is visible. Return your best useful name even when part of it is partially readable.
- If product text is split across lines, combine the meaningful parts into one short name.
- Prefer text visually associated with the headline/current price. Drop generic noise like "Precios Cuidados", "Oferta", "Promo", "Antes/Ahora", barcodes, weights, codes, dates, SKU, store labels, and legal text.
- Use empty string only when there is no usable product/brand/category text at all.
- "price": the headline price the customer pays TODAY (the biggest, most prominent number on the label, usually the "AHORA" or sale price). Plain decimal number — never a string, never include "\$".
- "alternatives": every OTHER price visible on the label (regular/old price, per-kilo, per-unit, club price, etc), each as a plain decimal number. Empty array if there is only one price.
- Argentine number format: "." is thousands, "," is decimal. "\$1.234,56" => 1234.56. "\$ 23,⁹⁰" (superscript cents) => 23.90.
- US format: "," is thousands, "." is decimal. "\$2.69" => 2.69.
- Always return plain decimals (1234.56), never strings, never with separators.
- If a price is unreadable or you are not sure, leave it OUT. Do not invent.
- If no price is visible, set price to 0 and alternatives to [].
''';

Future<AiVisionResult?> parseLabelWithAI(File jpeg, String apiKey) async {
  if (apiKey.isEmpty) return null;
  try {
    final bytes = await jpeg.readAsBytes();
    final b64 = base64Encode(bytes);

    final body = jsonEncode({
      'model': _model,
      'temperature': 0,
      'max_tokens': 300,
      'response_format': {'type': 'json_object'},
      'messages': [
        {'role': 'system', 'content': _systemPrompt},
        {
          'role': 'user',
          'content': [
            {
              'type': 'text',
              'text': 'Extract the product name and prices from this label.',
            },
            {
              'type': 'image_url',
              'image_url': {
                'url': 'data:image/jpeg;base64,$b64',
                'detail': 'high',
              },
            },
          ],
        },
      ],
    });

    final response = await http
        .post(
          Uri.parse(_openAiUrl),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          },
          body: body,
        )
        .timeout(_timeout);

    if (response.statusCode != 200) return null;

    final decoded =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final choices = decoded['choices'] as List?;
    if (choices == null || choices.isEmpty) return null;
    final message = (choices.first as Map)['message'] as Map?;
    final content = message?['content'] as String?;
    if (content == null || content.isEmpty) return null;

    final parsed = jsonDecode(content) as Map<String, dynamic>;
    final rawName = (parsed['name'] as String?)?.trim();
    final mainPrice = _toDouble(parsed['price']);
    final altsRaw = (parsed['alternatives'] as List?) ?? const [];
    final alts = altsRaw
        .map(_toDouble)
        .whereType<double>()
        .where((p) => p > 0)
        .toList();

    final prices = <double>[];
    if (mainPrice != null && mainPrice > 0) prices.add(mainPrice);
    for (final p in alts) {
      if (!prices.contains(p)) prices.add(p);
    }

    return (
      prices: prices,
      name: (rawName == null || rawName.isEmpty) ? null : rawName,
      rawText: content,
    );
  } catch (_) {
    return null;
  }
}

double? _toDouble(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.replaceAll(',', '.'));
  return null;
}
