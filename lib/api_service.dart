import 'dart:convert';
import 'package:http/http.dart' as http;

class ApiService {
  final String apiKey;

  // We pass the key into the service when the user "logs in"
  ApiService(this.apiKey);

  Future<String> getChatResponse(List<Map<String, String>> messages) async {
    try {
      final response = await http.post(
        Uri.parse('https://text.pollinations.ai/openai'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
        body: jsonEncode({
          'messages': messages,
          'model': 'openai',
          'cache': false,
        }),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['choices'][0]['message']['content'];
      } else {
        return "⚠️ Error: ${response.statusCode}. Connection failed.";
      }
    } catch (e) {
      return "⚠️ System timeout. Please try again.";
    }
  }
}