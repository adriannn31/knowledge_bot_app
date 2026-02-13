import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';

void main() => runApp(const KnowledgeBot());

class KnowledgeBot extends StatefulWidget {
  const KnowledgeBot({super.key});
  @override
  State<KnowledgeBot> createState() => _KnowledgeBotState();
}

class _KnowledgeBotState extends State<KnowledgeBot> {
  bool _isDarkMode = true; // Default to dark for that "Pro" look

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: _isDarkMode ? Brightness.dark : Brightness.light,
        colorSchemeSeed: Colors.blueAccent,
        useMaterial3: true,
        fontFamily: 'Inter',
      ),
      home: ChatDashboard(
        isDarkMode: _isDarkMode,
        toggleTheme: () => setState(() => _isDarkMode = !_isDarkMode),
      ),
    );
  }
}

class ChatDashboard extends StatefulWidget {
  final bool isDarkMode;
  final VoidCallback toggleTheme;
  const ChatDashboard({super.key, required this.isDarkMode, required this.toggleTheme});

  @override
  State<ChatDashboard> createState() => _ChatDashboardState();
}

class _ChatDashboardState extends State<ChatDashboard> {
  // HARDCODED KEY FOR TESTING BRANCH
  final String _apiKey = "sk_g3YUTaubxZF5SBq4ZVBHaZETOltj7nfU"; 
  
  final List<Map<String, String>> _messages = [];
  final List<String> _files = ["System_Architecture.pdf", "User_Guide_v2.docx"];
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  
  String _knowledgeContext = ""; // Simulated RAG context
  bool _isTyping = false;

  void _uploadFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.any);
    if (result != null) {
      setState(() {
        String name = result.files.single.name;
        _files.add(name);
        _knowledgeContext += "\n[Context from $name: This is a simulated document content about $name.]";
      });
      _showToast("File Indexed Successfully");
    }
  }

  void _showToast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  Future<void> _sendMessage(String text) async {
    if (text.trim().isEmpty) return;
    setState(() {
      _messages.add({"role": "user", "content": text});
      _isTyping = true;
    });
    _controller.clear();

    try {
      final response = await http.post(
        Uri.parse("https://gen.pollinations.ai/v1/chat/completions"),
        headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $_apiKey'},
        body: jsonEncode({
          'model': 'openai',
          'messages': [
            {"role": "system", "content": "You are a Professional AI with access to these documents: $_files. Context: $_knowledgeContext"},
            ..._messages.length > 8 ? _messages.sublist(_messages.length - 8) : _messages
          ],
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() => _messages.add({"role": "assistant", "content": data['choices'][0]['message']['content']}));
      }
    } catch (e) {
      setState(() => _messages.add({"role": "assistant", "content": "Error reaching server."}));
    } finally {
      setState(() => _isTyping = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: _buildDrawer(),
      appBar: AppBar(
        title: const Text("KNOWLEDGE BOT", style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1.2)),
        actions: [
          IconButton(icon: Icon(widget.isDarkMode ? Icons.light_mode : Icons.dark_mode), onPressed: widget.toggleTheme),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              itemCount: _messages.length,
              itemBuilder: (context, i) => _buildMessageRow(_messages[i]),
            ),
          ),
          if (_isTyping) const LinearProgressIndicator(),
          _buildInputArea(),
        ],
      ),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      child: Column(
        children: [
          const DrawerHeader(
            decoration: BoxDecoration(color: Colors.blueAccent),
            child: Center(child: Text("DASHBOARD", style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold))),
          ),
          ListTile(
            leading: const Icon(Icons.upload_file),
            title: const Text("Upload Document"),
            onTap: _uploadFile,
          ),
          const Divider(),
          const Padding(padding: EdgeInsets.all(16.0), child: Text("INDEXED KNOWLEDGE", style: TextStyle(color: Colors.grey))),
          Expanded(
            child: ListView.builder(
              itemCount: _files.length,
              itemBuilder: (context, i) => ListTile(
                leading: const Icon(Icons.description_outlined),
                title: Text(_files[i], style: const TextStyle(fontSize: 13)),
                trailing: IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => setState(() => _files.removeAt(i))),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageRow(Map<String, String> msg) {
    bool isUser = msg['role'] == 'user';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!isUser) CircleAvatar(backgroundColor: Colors.blueAccent.withOpacity(0.2), child: const Icon(Icons.auto_awesome, size: 18)),
          const SizedBox(width: 10),
          Flexible(
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isUser ? Colors.blueAccent : (widget.isDarkMode ? Colors.white10 : Colors.grey[100]),
                borderRadius: BorderRadius.circular(18),
              ),
              child: MarkdownBody(
                data: msg['content']!,
                styleSheet: MarkdownStyleSheet(
                  p: TextStyle(color: isUser ? Colors.white : (widget.isDarkMode ? Colors.white : Colors.black87)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputArea() {
    return Container(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              decoration: InputDecoration(
                hintText: "Ask about your data...",
                filled: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(30), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              ),
              onSubmitted: _sendMessage,
            ),
          ),
          const SizedBox(width: 10),
          FloatingActionButton(onPressed: () => _sendMessage(_controller.text), child: const Icon(Icons.send_rounded)),
        ],
      ),
    );
  }
}