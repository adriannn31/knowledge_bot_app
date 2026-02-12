import 'package:flutter/material.dart';
import 'package:http/http.dart' as http; // Make sure this is in your pubspec.yaml
import 'dart:convert';

class ChatScreen extends StatefulWidget {
  // This line defines the variable coming from main.dart
  final String apiKey; 

  // This updates the constructor to require the key
  const ChatScreen({super.key, required this.apiKey}); 

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final List<Map<String, String>> _messages = [];

  Future<void> _sendMessage(String text) async {
    setState(() {
      _messages.add({"role": "user", "content": text});
    });

    try {
      // Use widget.apiKey to access the key passed from the StatefulWidget
      final response = await http.post(
        Uri.parse('https://text.pollinations.ai/'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${widget.apiKey}', 
        },
        body: jsonEncode({
          'messages': _messages,
          'model': 'openai',
        }),
      );

      if (response.statusCode == 200) {
        setState(() {
          _messages.add({"role": "assistant", "content": response.body});
        });
      }
    } catch (e) {
      debugPrint("Error: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Knowledge Bot")),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final isUser = _messages[index]["role"] == "user";
                return ListTile(
                  title: Align(
                    alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      color: isUser ? Colors.blue[100] : Colors.grey[300],
                      child: Text(_messages[index]["content"]!),
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                Expanded(child: TextField(controller: _controller)),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: () {
                    if (_controller.text.isNotEmpty) {
                      _sendMessage(_controller.text);
                      _controller.clear();
                    }
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}