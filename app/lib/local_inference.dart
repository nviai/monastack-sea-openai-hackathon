import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

class LocalInferenceStatus implements Exception {
  const LocalInferenceStatus(this.status);
  final int status;
}

typedef LocalGenerate = Future<String> Function(
  String credential,
  String prompt,
);

/// Explicit opt-in text generation; it does not read workspace records.
class LocalInference extends StatefulWidget {
  const LocalInference({super.key, this.generate});
  final LocalGenerate? generate;
  @override
  State<LocalInference> createState() => _LocalInferenceState();
}

class _LocalInferenceState extends State<LocalInference> {
  final credential = TextEditingController();
  final prompt = TextEditingController();
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  String? output;
  String? error;
  bool busy = false;
  @override
  void dispose() {
    client.close(force: true);
    credential.dispose();
    prompt.dispose();
    super.dispose();
  }

  Future<String> request(String token, String input) async {
    final port = int.tryParse(
      Platform.environment['MONASTACK_INFERENCE_PORT'] ?? '47831',
    );
    if (port == null || port < 1 || port > 65535) {
      throw const FormatException('Invalid inference port');
    }
    final req = await client
        .postUrl(Uri.parse('http://127.0.0.1:$port/v1/generate'))
        .timeout(const Duration(seconds: 3));
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    req.headers.contentType = ContentType.json;
    final payload = utf8.encode(
      jsonEncode({'prompt': input, 'max_tokens': 64}),
    );
    req.contentLength = payload.length;
    req.add(payload);
    final res = await req.close().timeout(const Duration(seconds: 60));
    final raw = await utf8.decoder
        .bind(res)
        .join()
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      throw LocalInferenceStatus(res.statusCode);
    }
    return (jsonDecode(raw) as Map<String, dynamic>)['text'] as String;
  }

  Future<void> generate() async {
    final token = credential.text.trim();
    final input = prompt.text.trim();
    if (token.isEmpty || input.isEmpty || busy) return;
    setState(() {
      busy = true;
      error = null;
      output = null;
    });
    try {
      final result = await (widget.generate ?? request)(token, input);
      if (mounted) setState(() => output = result);
    } catch (failure) {
      debugPrint(
        'Local inference request failed: ${failure.runtimeType}${failure is LocalInferenceStatus ? ' ${failure.status}' : ''}',
      );
      if (mounted) {
        setState(
          () => error = failure is LocalInferenceStatus
              ? 'Local inference service returned ${failure.status}.'
              : 'Local model unavailable, busy, or credential rejected.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 620,
      height: 570,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Local text model',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  tooltip: 'Close',
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const Text(
              'Explicit local service · no workspace records are added automatically · output may be inaccurate',
              style: TextStyle(color: Colors.black54),
            ),
            TextField(
              controller: credential,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Local inference token',
              ),
            ),
            TextField(
              controller: prompt,
              maxLength: 4000,
              minLines: 3,
              maxLines: 5,
              decoration: const InputDecoration(labelText: 'Prompt'),
            ),
            Row(
              children: [
                FilledButton(
                  onPressed: busy ? null : generate,
                  child: Text(busy ? 'Generating…' : 'Generate'),
                ),
                if (error != null)
                  Expanded(
                    child: Text(
                      error!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                child: SelectableText(
                  output ?? 'No generation requested.',
                  key: const ValueKey('local-model-output'),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
