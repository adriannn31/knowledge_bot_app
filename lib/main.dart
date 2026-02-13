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
              Icon(Icons.lock_person_outlined, color: Colors.indigo, size: 42),
              SizedBox(height: 12),
              Text("Secure Access", style: TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("Establish a secure connection by entering your system credential.",
                  textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: Colors.black54)),
              const SizedBox(height: 20),
              TextField(
                obscureText: true, // Hides the key as dots
                style: const TextStyle(letterSpacing: 2),
                decoration: InputDecoration(
                  hintText: "Enter Key",
                  hintStyle: const TextStyle(letterSpacing: 0),
                  filled: true,
                  fillColor: Color(0xFFF5F7FA),
                  prefixIcon: const Icon(Icons.key_outlined),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: BorderSide.none),
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
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () {
                  if (input.trim().isNotEmpty) {
                    setState(() => _key = input.trim());
                    Navigator.pop(context);
                  }
                },
                child: const Text("Initialize Session", style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            )
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_key == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
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

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(_scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
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
      // Using Pollinations backend but without UI branding
      final response = await http.post(
        Uri.parse('https://text.pollinations.ai/openai'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${widget.apiKey}',
        },
        body: jsonEncode({
          'messages': _messages,
          'model': 'openai',
          'cache': false,
        }),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _messages.add({
            "role": "assistant", 
            "content": data['choices'][0]['message']['content']
          });
        });
      } else {
        setState(() {
          _messages.add({
            "role": "assistant", 
            "content": "⚠️ Session Error: Could not verify credentials. (Code: ${response.statusCode})"
          });
        });
      }
    } catch (e) {
      setState(() {
        _messages.add({
          "role": "assistant", 
          "content": "⚠️ Network timeout. Please try again."
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
        title: const Text("Knowledge Bot", style: TextStyle(fontWeight: FontWeight.bold)), 
        centerTitle: true,
        elevation: 0,
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
                  alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: isUser ? Colors.indigo : Color(0xFFF1F3F9),
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(16),
                        topRight: const Radius.circular(16),
                        bottomLeft: Radius.circular(isUser ? 16 : 0),
                        bottomRight: Radius.circular(isUser ? 0 : 16),
                      ),
                    ),
                    child: MarkdownBody(
                      data: _messages[i]['content']!,
                      styleSheet: MarkdownStyleSheet(
                        p: TextStyle(color: isUser ? Colors.white : Colors.black87, fontSize: 15),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (_isTyping) const Padding(padding: EdgeInsets.symmetric(horizontal: 20), child: LinearProgressIndicator(minHeight: 1)),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: Colors.grey.shade200))),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: InputDecoration(
                      hintText: "Ask anything...", 
                      filled: true,
                      fillColor: Colors.grey[100],
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(25), borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                    ),
                    onSubmitted: _sendMessage,
                  ),
                ),
                const SizedBox(width: 8),
                CircleAvatar(
                  backgroundColor: Colors.indigo,
                  child: IconButton(
                    icon: const Icon(Icons.send, color: Colors.white, size: 20), 
                    onPressed: () => _sendMessage(_controller.text)
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