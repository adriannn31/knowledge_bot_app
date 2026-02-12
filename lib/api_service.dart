import 'dart:convert';
import 'package:http/http.dart' as http;
import 'config.dart';

class ApiService {
  // Use the Pollinations AI OpenAI-compatible endpoint
  final String baseUrl = "https://gen.pollinations.ai/v1/chat/completions";

  Future<String> getBotResponse(String query) async {
    final response = await http.post(
      Uri.parse(baseUrl),
      headers: {
        "Content-Type": "application/json",
        "Authorization": "Bearer $apiKey", // Uses the sk_... key from config.dart
      },
      body: jsonEncode({
        "model": "qwen-character",
        "messages": [
          {"role": "system", "content": "You are a helpful assistant."},
          {"role": "user", "content": query}
        ]
      }),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      // Pollinations/OpenAI structure: choices -> message -> content
      return data["choices"][0]["message"]["content"];
    } else {
      // This will help you see if the API key or JSON is actually the issue
      throw Exception("Failed: ${response.statusCode} - ${response.body}");
    }
  }
}