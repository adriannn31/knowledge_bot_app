import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter_markdown/flutter_markdown.dart';

void main() {
  runApp(const KnowledgeBot());
}

class KnowledgeBot extends StatelessWidget {
  const KnowledgeBot({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Knowledge Bot',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const ApiKeyWrapper(),
    );
  }
}

class ApiKeyWrapper extends StatefulWidget {
  const ApiKeyWrapper({super.key});

  @override
  State<ApiKeyWrapper> createState() => _ApiKeyWrapperState();
}

class _ApiKeyWrapperState extends State<ApiKeyWrapper> {
  String? _key;

  @override
  void initState() {
    super.initState();
    Future.delayed(Duration.zero, _promptKey);
  }

  void _promptKey() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        String input = "";
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: const Column(
            children: [
              Icon(Icons.shield_moon_outlined, color: Colors.indigo, size: 42),
              SizedBox(height: 12),
              Text("System Access", style: TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("Enter your secure credential to begin the session.",
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14, color: Colors.black54)),
              const SizedBox(height: 20),
              TextField(
                obscureText: true,
                style: const TextStyle(letterSpacing: 2),
                decoration: InputDecoration(
                  hintText: "API Key",
                  hintStyle: const TextStyle(letterSpacing: 0),
                  filled: true,
                  fillColor: const Color(0xFFF5F7FA),
                  prefixIcon: const Icon(Icons.vpn_key_outlined),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(15),
                      borderSide: BorderSide.none),
                ),
                onChanged: (v) => input = v,
              ),
            ],
          ),
          actions: [
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.indigo,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 15),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () {
                  if (input.trim().isNotEmpty) {
                    setState(() => _key = input.trim());
                    Navigator.pop(context);
                  }
                },
                child: const Text("Initialize",
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            )
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_key == null)
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return ChatScreen(apiKey: _key!);
  }
}

class ChatScreen extends StatefulWidget {
  final String apiKey;
  const ChatScreen({super.key, required this.apiKey});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final List<Map<String, String>> _messages = [];
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isTyping = false;

  // ✅ FIX 1: Correct base URL — no CORS proxy needed for mobile.
  // For Flutter Web, re-enable the proxyUrl line below.
  static const String _baseUrl = 'https://gen.pollinations.ai/v1/chat/completions';
  // static const String _proxyUrl = 'https://corsproxy.io/?';  // ← uncomment for Web

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage(String text) async {
    if (text.trim().isEmpty) return;
    setState(() {
      _messages.add({"role": "user", "content": text});
      _isTyping = true;
    });
    _controller.clear();
    _scrollToBottom();

    try {
      final response = await http.post(
        Uri.parse(_baseUrl), // swap to _proxyUrl + _baseUrl for Flutter Web
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${widget.apiKey}',
        },
        body: jsonEncode({
          // ✅ FIX 2: Use 'openai' — it's a valid free model on Pollinations
          // Other options: 'openai-large', 'mistral', 'claude-hybridspace'
          'model': 'openai',
          'messages': _messages,
          // ✅ FIX 3: Removed 'jsonMode' — not a standard field, can cause errors
        }),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        // ✅ FIX 4: Added null-safe access with a fallback message
        final reply =
            data['choices']?[0]?['message']?['content'] ?? '(No response)';
        setState(() {
          _messages.add({"role": "assistant", "content": reply});
        });
      } else {
        setState(() {
          _messages.add({
            "role": "assistant",
            "content":
                "⚠️ Error ${response.statusCode}: ${response.reasonPhrase ?? 'Request failed'}.\n\nDouble-check your API key and try again."
          });
        });
      }
    } catch (e) {
      setState(() {
        _messages.add({
          "role": "assistant",
          "content":
              "⚠️ Connection failed: ${e.toString()}\n\nCheck your internet connection or CORS proxy settings."
        });
      });
    } finally {
      setState(() => _isTyping = false);
      _scrollToBottom();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text("Knowledge Bot",
            style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        backgroundColor: Colors.white,
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length,
              itemBuilder: (context, i) {
                bool isUser = _messages[i]['role'] == 'user';
                return Align(
                  alignment:
                      isUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width * 0.75),
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: isUser ? Colors.indigo : const Color(0xFFF1F3F9),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: MarkdownBody(
                      data: _messages[i]['content']!,
                      styleSheet: MarkdownStyleSheet(
                        p: TextStyle(
                            color:
                                isUser ? Colors.white : Colors.black87,
                            fontSize: 15),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (_isTyping)
            const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20),
                child: LinearProgressIndicator(minHeight: 1)),
          Container(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: InputDecoration(
                      hintText: "Type a message...",
                      filled: true,
                      fillColor: Colors.grey[100],
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(25),
                          borderSide: BorderSide.none),
                    ),
                    onSubmitted: _sendMessage,
                  ),
                ),
                const SizedBox(width: 8),
                CircleAvatar(
                  backgroundColor: Colors.indigo,
                  child: IconButton(
                    icon: const Icon(Icons.send, color: Colors.white, size: 20),
                    onPressed: () => _sendMessage(_controller.text),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}