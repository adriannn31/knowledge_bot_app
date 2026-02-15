import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:read_pdf_text/read_pdf_text.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

// ─────────────────────────────────────────────
//  STORAGE MANAGER
//  Centralises all SharedPreferences I/O so
//  the widget tree never calls getInstance()
//  directly.
// ─────────────────────────────────────────────

class StorageManager {
  static SharedPreferences? _prefs;

  /// Call once at app startup.
  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  static SharedPreferences get _p {
    assert(_prefs != null, 'StorageManager.init() must be called first');
    return _prefs!;
  }

  // ── Messages ──────────────────────────────
  static List<Map<String, String>> loadMessages() {
    final s = _p.getString('chat_messages');
    if (s == null) return [];
    return (jsonDecode(s) as List).map((e) => Map<String, String>.from(e)).toList();
  }

  static Future<void> saveMessages(List<Map<String, String>> msgs) =>
      _p.setString('chat_messages', jsonEncode(msgs));

  static Future<void> clearMessages() => _p.remove('chat_messages');

  // ── Shared Memory ──────────────────────────
  static String loadSharedMemory() => _p.getString('shared_memory') ?? '';

  static Future<void> saveSharedMemory(String v) =>
      _p.setString('shared_memory', v);

  // ── Chat Sessions ──────────────────────────
  static List<Map<String, String>> loadChatSessions() {
    final s = _p.getString('chat_sessions');
    if (s == null) return [];
    return (jsonDecode(s) as List).map((e) => Map<String, String>.from(e)).toList();
  }

  static Future<void> saveChatSessions(List<Map<String, String>> sessions) =>
      _p.setString('chat_sessions', jsonEncode(sessions));

  // ── API Key ────────────────────────────────
  static String loadApiKey() => _p.getString('api_key') ?? '';
  static Future<void> saveApiKey(String key) => _p.setString('api_key', key);
  static Future<void> clearApiKey() => _p.remove('api_key');

  // ── Memory Profiles ────────────────────────
  static List<Map<String, String>> loadMemoryProfiles() {
    final s = _p.getString('memory_profiles');
    if (s == null) return [];
    return (jsonDecode(s) as List).map((e) => Map<String, String>.from(e)).toList();
  }

  static int loadActiveProfileIndex() =>
      _p.getInt('active_profile_index') ?? -1;

  static Future<void> saveMemoryProfiles(
      List<Map<String, String>> profiles, int activeIndex) async {
    await _p.setString('memory_profiles', jsonEncode(profiles));
    await _p.setInt('active_profile_index', activeIndex);
  }
}


void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");
  await StorageManager.init();
  runApp(const KnowledgeBot());
}


class KnowledgeBot extends StatefulWidget {
  const KnowledgeBot({super.key});

  @override
  State<KnowledgeBot> createState() => _KnowledgeBotState();
}

class _KnowledgeBotState extends State<KnowledgeBot> {
  bool _isDarkMode = true;

  void toggleTheme() => setState(() => _isDarkMode = !_isDarkMode);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Nexus',
      theme: ThemeData(
        brightness: _isDarkMode ? Brightness.dark : Brightness.light,
        colorSchemeSeed: Colors.deepPurple,
        useMaterial3: true,
        scaffoldBackgroundColor:
            _isDarkMode ? const Color(0xFF0D0D0D) : const Color(0xFFF2F4F8),
        appBarTheme: AppBarTheme(
          backgroundColor:
              _isDarkMode ? const Color(0xFF161616) : Colors.white,
          elevation: 0,
          shadowColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          titleTextStyle: TextStyle(
              color: _isDarkMode ? Colors.white : Colors.black87,
              fontWeight: FontWeight.w700,
              fontSize: 18,
              letterSpacing: 0.3),
          iconTheme: IconThemeData(
              color: _isDarkMode ? Colors.white70 : Colors.black54),
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      home: ChatDashboard(isDarkMode: _isDarkMode, onToggleTheme: toggleTheme),
    );
  }
}

// ─────────────────────────────────────────────
//  CONSTANTS
// ─────────────────────────────────────────────

const int kMaxContextTokens = 12000;
int _estimateTokens(String text) => (text.length / 4).ceil();

// Regex to extract all code blocks from markdown (``` ... ```)
final RegExp _codeBlockRegex =
    RegExp(r'```(?:\w+)?\n([\s\S]*?)```', multiLine: true);

// ─────────────────────────────────────────────
//  MAIN SCREEN
// ─────────────────────────────────────────────

class ChatDashboard extends StatefulWidget {
  final bool isDarkMode;
  final VoidCallback onToggleTheme;
  const ChatDashboard(
      {super.key, required this.isDarkMode, required this.onToggleTheme});

  @override
  State<ChatDashboard> createState() => _ChatDashboardState();
}

class _ChatDashboardState extends State<ChatDashboard>
    with TickerProviderStateMixin {

  String _apiKey = '';

  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final ValueNotifier<bool> _inputHasText = ValueNotifier(false);

  // ─── TYPING DOT ANIMATION ───
  late List<AnimationController> _dotControllers;
  late List<Animation<double>> _dotAnimations;

  List<Map<String, String>> _messages = [];
  final List<Map<String, String>> _filesData = [];
  // ─── CHAT SESSIONS (History) ───
  // Each session: { 'id', 'title', 'timestamp', 'messages': jsonEncoded list }
  List<Map<String, String>> _chatSessions = [];

  bool _isTyping = false;
  String _sharedMemory = '';

  // ─── AUDIO TOOLS ───
  late stt.SpeechToText _speech;
  bool _isListening = false;
  bool _speechAvailable = false;
  bool _isSpeaking = false;

  // ─── DEBUGGER STATE ───
  final Set<int> _debuggingIndexes = {};

  // ─── MEMORY PROFILES ───
  // Each profile: { 'name': String, 'content': String }
  List<Map<String, String>> _memoryProfiles = [];
  int _activeProfileIndex = -1; // -1 = using manual shared memory

  @override
  void initState() {
    super.initState();
    _loadMessages();
    _loadSharedMemory();
    _loadMemoryProfiles();
    _loadChatSessions();
    _initSpeech();
    _controller.addListener(() {
      _inputHasText.value = _controller.text.trim().isNotEmpty;
    });
    _dotControllers = List.generate(3, (i) => AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    ));
    _dotAnimations = _dotControllers.map((c) =>
      Tween<double>(begin: 0, end: -6).animate(
        CurvedAnimation(parent: c, curve: Curves.easeInOut),
      ),
    ).toList();
    // Load API key — show setup screen if not set
    _apiKey = StorageManager.loadApiKey();
    if (_apiKey.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _showApiKeyScreen(canDismiss: false));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _inputHasText.dispose();
    for (final c in _dotControllers) { c.dispose(); }
    super.dispose();
  }

  // ─── API KEY SETUP ───────────────────────────

  void _showApiKeyScreen({bool canDismiss = true}) {
    final keyController = TextEditingController();
    bool _obscure = true;
    bool _loading = false;

    showModalBottomSheet(
      context: context,
      isDismissible: canDismiss,
      enableDrag: canDismiss,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom),
          child: Container(
            decoration: BoxDecoration(
              color: widget.isDarkMode
                  ? const Color(0xFF1A1A2E)
                  : Colors.white,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(28)),
            ),
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Handle
                Center(
                  child: Container(
                    width: 40, height: 4,
                    margin: const EdgeInsets.only(bottom: 24),
                    decoration: BoxDecoration(
                        color: Colors.grey[500],
                        borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                // Icon + title
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                            colors: [Color(0xFF7C3AED), Color(0xFF2563EB)]),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(Icons.key_rounded,
                          color: Colors.white, size: 22),
                    ),
                    const SizedBox(width: 14),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('API Key Required',
                            style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800)),
                        Text('Pollinations API key',
                            style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey[500])),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                // Info box
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF7C3AED).withOpacity(0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: const Color(0xFF7C3AED).withOpacity(0.2)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.lock_outline,
                          size: 16, color: Color(0xFF7C3AED)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Your key is stored only on this device and never shared.',
                          style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[600]),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                // Key input
                TextField(
                  controller: keyController,
                  autofocus: true,
                  obscureText: _obscure,
                  style: TextStyle(
                    fontSize: 15,
                    color: widget.isDarkMode ? Colors.white : Colors.black87,
                    fontFamily: 'monospace',
                    letterSpacing: _obscure ? 2 : 0,
                  ),
                  decoration: InputDecoration(
                    hintText: 'xx_xxxxxxxxxxxxxxxx',
                    hintStyle: TextStyle(
                        color: widget.isDarkMode
                            ? Colors.white24
                            : Colors.black26,
                        fontFamily: 'monospace',
                        letterSpacing: 0),
                    filled: true,
                    fillColor: widget.isDarkMode
                        ? const Color(0xFF252535)
                        : const Color(0xFFF0F0F8),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                    prefixIcon: const Icon(Icons.vpn_key_rounded,
                        size: 18, color: Color(0xFF7C3AED)),
                    suffixIcon: IconButton(
                      icon: Icon(
                          _obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          size: 18,
                          color: Colors.grey[500]),
                      onPressed: () => setSheet(() => _obscure = !_obscure),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Get your free key at gen.pollinations.ai',
                  style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                ),
                const SizedBox(height: 24),
                // Buttons
                Row(
                  children: [
                    if (canDismiss && _apiKey.isNotEmpty) ...[
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(ctx),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      flex: 2,
                      child: ElevatedButton(
                        onPressed: _loading
                            ? null
                            : () async {
                                final key = keyController.text.trim();
                                if (key.isEmpty) {
                                  ScaffoldMessenger.of(context)
                                      .showSnackBar(const SnackBar(
                                    content: Text('Please enter your API key'),
                                    backgroundColor: Colors.red,
                                  ));
                                  return;
                                }
                                setSheet(() => _loading = true);
                                await StorageManager.saveApiKey(key);
                                setState(() => _apiKey = key);
                                if (mounted) Navigator.pop(ctx);
                                ScaffoldMessenger.of(context)
                                    .showSnackBar(const SnackBar(
                                  content: Text('✅ API key saved securely'),
                                  backgroundColor: Color(0xFF7C3AED),
                                ));
                              },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF7C3AED),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        child: _loading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : const Text('Save & Continue',
                                style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 15)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _setTyping(bool value) {
    setState(() => _isTyping = value);
    if (value) {
      // Start each dot with a 150ms stagger
      for (int i = 0; i < _dotControllers.length; i++) {
        Future.delayed(Duration(milliseconds: i * 150), () {
          if (mounted && _isTyping) {
            _dotControllers[i].repeat(reverse: true);
          }
        });
      }
    } else {
      for (final c in _dotControllers) { c.stop(); c.reset(); }
    }
  }

  // ─── PERSISTENCE ────────────────────────────

  Future<void> _loadMessages() async {
    final msgs = StorageManager.loadMessages();
    if (msgs.isNotEmpty) {
      setState(() => _messages = msgs);
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  Future<void> _saveMessages() => StorageManager.saveMessages(_messages);

  Future<void> _loadSharedMemory() async {
    setState(() => _sharedMemory = StorageManager.loadSharedMemory());
  }

  Future<void> _saveSharedMemory(String value) async {
    await StorageManager.saveSharedMemory(value);
    setState(() => _sharedMemory = value);
  }

  // ─── CHAT SESSIONS PERSISTENCE ──────────────

  Future<void> _loadChatSessions() async {
    setState(() => _chatSessions = StorageManager.loadChatSessions());
  }

  Future<void> _saveChatSessionsList() =>
      StorageManager.saveChatSessions(_chatSessions);

  // Save current chat as a named session
  Future<void> _saveCurrentSession(String title) async {
    if (_messages.isEmpty) return;
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final session = {
      'id': id,
      'title': title,
      'timestamp': DateTime.now().toIso8601String(),
      'messages': jsonEncode(_messages),
    };
    setState(() => _chatSessions.insert(0, session)); // newest first
    await _saveChatSessionsList();
  }

  // Restore a session into current chat
  void _restoreSession(Map<String, String> session) {
    final decoded = jsonDecode(session['messages']!) as List<dynamic>;
    setState(() {
      _messages =
          decoded.map((e) => Map<String, String>.from(e)).toList();
    });
    _saveMessages();
    _scrollToBottom();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Restored: ${session['title']}'),
      backgroundColor: Colors.teal,
    ));
  }

  Future<void> _deleteChatSession(String id) async {
    setState(() =>
        _chatSessions.removeWhere((s) => s['id'] == id));
    await _saveChatSessionsList();
  }

  // ─── MEMORY PROFILES PERSISTENCE ────────────

  Future<void> _loadMemoryProfiles() async {
    setState(() {
      _memoryProfiles = StorageManager.loadMemoryProfiles();
      _activeProfileIndex = StorageManager.loadActiveProfileIndex();
    });
  }

  Future<void> _saveMemoryProfiles() =>
      StorageManager.saveMemoryProfiles(_memoryProfiles, _activeProfileIndex);

  void _addMemoryProfile(String name, String content) {
    setState(() => _memoryProfiles.add({'name': name, 'content': content}));
    _saveMemoryProfiles();
  }

  void _deleteMemoryProfile(int index) {
    setState(() {
      _memoryProfiles.removeAt(index);
      if (_activeProfileIndex == index) {
        _activeProfileIndex = -1;
      } else if (_activeProfileIndex > index) {
        _activeProfileIndex--;
      }
    });
    _saveMemoryProfiles();
  }

  void _activateProfile(int index) {
    final profile = _memoryProfiles[index];
    _saveSharedMemory(profile['content'] ?? '');
    setState(() => _activeProfileIndex = index);
    _saveMemoryProfiles();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('✅ Profile "${profile['name']}" activated'),
      backgroundColor: Colors.purple,
    ));
  }

  void _deactivateProfile() {
    setState(() => _activeProfileIndex = -1);
    _saveMemoryProfiles();
  }

  // ─── CONTEXT TOKENS ─────────────────────────

  int get _currentContextTokens {
    int total = _estimateTokens(_sharedMemory);
    for (final msg in _messages) {
      total += _estimateTokens(msg['content'] ?? '');
    }
    for (final f in _filesData) {
      total += _estimateTokens(f['content'] ?? '');
    }
    return total;
  }

  double get _contextUsagePercent =>
      (_currentContextTokens / kMaxContextTokens).clamp(0.0, 1.0);

  // ─── SELF-CORRECTION DEBUGGER ────────────────
  //
  // How it works:
  // 1. User taps the 🐛 Debug button on any bot message containing code
  // 2. All code blocks are extracted from that message
  // 3. The code is sent back to the AI with a special "code reviewer" system
  //    prompt that asks it to find bugs, logic errors, and improvements
  // 4. The AI returns a detailed analysis + corrected code
  // 5. The result is added as a new message in the chat
  // 6. If the fix itself contains code, the Debug button appears again,
  //    allowing unlimited self-correction loops

  bool _hasCodeBlocks(String content) =>
      _codeBlockRegex.hasMatch(content);

  List<String> _extractCodeBlocks(String content) =>
      _codeBlockRegex
          .allMatches(content)
          .map((m) => m.group(1) ?? '')
          .where((c) => c.trim().isNotEmpty)
          .toList();

  Future<void> _debugCode(int messageIndex) async {
    final content = _messages[messageIndex]['content'] ?? '';
    final codeBlocks = _extractCodeBlocks(content);

    if (codeBlocks.isEmpty) return;

    // Mark this message as being debugged (shows spinner on the button)
    setState(() => _debuggingIndexes.add(messageIndex));

    // Build the combined code string if there are multiple blocks
    final combinedCode = codeBlocks
        .asMap()
        .entries
        .map((e) =>
            codeBlocks.length > 1
                ? 'Block ${e.key + 1}:\n${e.value}'
                : e.value)
        .join('\n\n---\n\n');

    // Add a system message to the chat showing the debug was triggered
    setState(() {
      _messages.add({
        'role': 'user',
        'content':
            '🐛 **Auto-Debug triggered** on the code above.\n\nPlease review this code carefully:\n```\n$combinedCode\n```\n\nAnalyze it for:\n1. Syntax errors\n2. Logic bugs\n3. Missing imports or dependencies\n4. Runtime exceptions\n5. Best practice violations\n\nThen provide the complete corrected version.',
        'type': 'text',
        'isDebug': 'true', // Mark as a debug request
      });
    });
    _setTyping(true);
    _saveMessages();
    _scrollToBottom();

    try {
      final debugSystemPrompt = '''You are an expert code debugger and reviewer.
Your job is to:
1. Carefully read the provided code
2. Identify ALL errors: syntax, logic, runtime, type errors, missing imports
3. Explain each issue found clearly and briefly
4. Provide the COMPLETE corrected code — not just the changed parts
5. After the corrected code, add a short "Changes Made" summary

Format your response like this:
## 🔍 Issues Found
[list each issue]

## ✅ Corrected Code
\`\`\`[language]
[full corrected code here]
\`\`\`

## 📝 Changes Made
[brief summary of what was fixed]

If the code has NO errors, say so clearly and explain why it looks correct.''';

      final response = await http
          .post(
            Uri.parse('https://gen.pollinations.ai/v1/chat/completions'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $_apiKey',
            },
            body: jsonEncode({
              'messages': [
                {'role': 'system', 'content': debugSystemPrompt},
                {
                  'role': 'user',
                  'content':
                      'Please debug and fix this code:\n\n```\n$combinedCode\n```'
                },
              ],
              'model': 'openai',
            }),
          )
          .timeout(const Duration(seconds: 60));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final reply = data['choices']?[0]?['message']?['content'] ?? '(No response)';
        setState(() {
          _messages.add({
            'role': 'assistant',
            'content': reply,
            'type': 'text',
            'isDebugResult': 'true',
          });
        });
        _saveMessages();
      } else {
        setState(() {
          _messages.add({
            'role': 'assistant',
            'content':
                '⚠️ Debugger failed with status ${response.statusCode}',
            'type': 'text',
          });
        });
      }
    } catch (e) {
      setState(() {
        _messages.add({
          'role': 'assistant',
          'content': '⚠️ Debugger network error: $e',
          'type': 'text',
        });
      });
    } finally {
      setState(() => _debuggingIndexes.remove(messageIndex));
      _setTyping(false);
      _scrollToBottom();
    }
  }

  // ─── CHAT HISTORY ────────────────────────────

  void _showChatHistory() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          return Container(
            height: MediaQuery.of(context).size.height * 0.8,
            decoration: BoxDecoration(
              color: widget.isDarkMode
                  ? const Color(0xFF1E1E1E)
                  : Colors.white,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Column(
              children: [
                // Handle
                Container(
                  margin: const EdgeInsets.only(top: 12, bottom: 8),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                      color: Colors.grey[400],
                      borderRadius: BorderRadius.circular(2)),
                ),
                // Header
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 8),
                  child: Row(
                    children: [
                      const Icon(Icons.history, color: Colors.teal),
                      const SizedBox(width: 8),
                      const Text('Chat History',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 18)),
                      const Spacer(),
                      // Save current chat button
                      TextButton.icon(
                        icon: const Icon(Icons.save, size: 16),
                        label: const Text('Save Current'),
                        style: TextButton.styleFrom(
                            foregroundColor: Colors.teal),
                        onPressed: _messages.isEmpty
                            ? null
                            : () => _showSaveSessionDialog(
                                onSaved: () => setModalState(() {})),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                // Session list
                Expanded(
                  child: _chatSessions.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.chat_bubble_outline,
                                  size: 60,
                                  color: Colors.grey.withOpacity(0.3)),
                              const SizedBox(height: 12),
                              const Text('No saved chats yet',
                                  style:
                                      TextStyle(color: Colors.grey)),
                              const Text(
                                  'Tap "Save Current" to save this chat',
                                  style: TextStyle(
                                      color: Colors.grey,
                                      fontSize: 12)),
                            ],
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(
                              vertical: 8, horizontal: 12),
                          itemCount: _chatSessions.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 4),
                          itemBuilder: (context, i) {
                            final session = _chatSessions[i];
                            final ts = DateTime.tryParse(
                                    session['timestamp'] ?? '') ??
                                DateTime.now();
                            final msgCount = (jsonDecode(
                                        session['messages'] ?? '[]')
                                    as List)
                                .length;

                            return Container(
                              decoration: BoxDecoration(
                                color: widget.isDarkMode
                                    ? const Color(0xFF2C2C2C)
                                    : Colors.grey[50],
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: ListTile(
                                leading: CircleAvatar(
                                  backgroundColor:
                                      Colors.teal.withOpacity(0.15),
                                  child: const Icon(Icons.chat,
                                      color: Colors.teal, size: 20),
                                ),
                                title: Text(
                                  session['title'] ?? 'Untitled',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 14),
                                ),
                                subtitle: Text(
                                  '$msgCount messages • ${_formatTimestamp(ts)}',
                                  style: const TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey),
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    // Restore button
                                    IconButton(
                                      icon: const Icon(
                                          Icons.restore,
                                          size: 20,
                                          color: Colors.teal),
                                      tooltip: 'Restore this chat',
                                      onPressed: () {
                                        Navigator.pop(context);
                                        _restoreSession(session);
                                      },
                                    ),
                                    // Delete button
                                    IconButton(
                                      icon: const Icon(Icons.delete,
                                          size: 20, color: Colors.red),
                                      tooltip: 'Delete',
                                      onPressed: () {
                                        _deleteChatSession(
                                            session['id']!);
                                        setModalState(() {});
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showSaveSessionDialog({required VoidCallback onSaved}) {
    final firstMsg = _messages
        .firstWhere((m) => m['role'] == 'user',
            orElse: () => {'content': 'Chat'})['content'] ??
        'Chat';
    final autoTitle = firstMsg.length > 40
        ? '${firstMsg.substring(0, 40)}...'
        : firstMsg;

    final titleController = TextEditingController(text: autoTitle);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
        contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
        actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        title: const Row(
          children: [
            Icon(Icons.bookmark_add, color: Colors.teal, size: 22),
            SizedBox(width: 10),
            Text('Save Chat',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Give this chat a name so you can find it later.',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: titleController,
              autofocus: true,
              style: TextStyle(
                fontSize: 15,
                color: widget.isDarkMode ? Colors.white : Colors.black87,
                fontWeight: FontWeight.w500,
              ),
              decoration: InputDecoration(
                hintText: 'e.g. Flutter help, Trip planning...',
                hintStyle: TextStyle(
                    color: widget.isDarkMode
                        ? Colors.white30
                        : Colors.black38,
                    fontSize: 14),
                filled: true,
                fillColor: widget.isDarkMode
                    ? const Color(0xFF252535)
                    : const Color(0xFFF0F0F8),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 12),
              ),
            ),
            const SizedBox(height: 4),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel',
                  style: TextStyle(color: Colors.grey))),
          ElevatedButton.icon(
            icon: const Icon(Icons.bookmark_added, size: 16),
            label: const Text('Save'),
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.teal,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                    horizontal: 20, vertical: 10),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
            onPressed: () async {
              await _saveCurrentSession(
                  titleController.text.trim().isEmpty
                      ? 'Untitled'
                      : titleController.text.trim());
              if (mounted) Navigator.pop(context);
              onSaved();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('Chat saved!'),
                    backgroundColor: Colors.teal),
              );
            },
          ),
        ],
      ),
    );
  }

  String _formatTimestamp(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.day}/${dt.month}/${dt.year}';
  }

  // ─── MEMORY LIBRARY ──────────────────────────

  void _showMemoryLibrary() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          return Container(
            height: MediaQuery.of(context).size.height * 0.8,
            decoration: BoxDecoration(
              color: widget.isDarkMode ? const Color(0xFF1E1E1E) : Colors.white,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Column(
              children: [
                // Handle
                Container(
                  margin: const EdgeInsets.only(top: 12, bottom: 8),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                      color: Colors.grey[400],
                      borderRadius: BorderRadius.circular(2)),
                ),
                // Header
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 8),
                  child: Row(
                    children: [
                      const Icon(Icons.library_books, color: Colors.purple),
                      const SizedBox(width: 8),
                      const Text('Memory Profiles',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 18)),
                      const Spacer(),
                      // Add new profile button
                      TextButton.icon(
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('New'),
                        onPressed: () => _showAddProfileDialog(
                            onAdded: () => setModalState(() {})),
                      ),
                    ],
                  ),
                ),
                // Active profile indicator
                if (_activeProfileIndex >= 0 &&
                    _activeProfileIndex < _memoryProfiles.length)
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.purple.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: Colors.purple.withOpacity(0.3)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.check_circle,
                            size: 14, color: Colors.purple),
                        const SizedBox(width: 6),
                        Text(
                          'Active: ${_memoryProfiles[_activeProfileIndex]['name']}',
                          style: const TextStyle(
                              fontSize: 12, color: Colors.purple),
                        ),
                        const Spacer(),
                        GestureDetector(
                          onTap: () {
                            _deactivateProfile();
                            setModalState(() {});
                          },
                          child: const Text('Deactivate',
                              style: TextStyle(
                                  fontSize: 11, color: Colors.red)),
                        ),
                      ],
                    ),
                  ),
                const Divider(height: 20),
                // Profile list
                Expanded(
                  child: _memoryProfiles.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.psychology_alt,
                                  size: 60,
                                  color: Colors.grey.withOpacity(0.3)),
                              const SizedBox(height: 12),
                              const Text('No profiles yet',
                                  style: TextStyle(color: Colors.grey)),
                              const Text(
                                  'Tap "New" to create one',
                                  style: TextStyle(
                                      color: Colors.grey, fontSize: 12)),
                            ],
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16),
                          itemCount: _memoryProfiles.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 4),
                          itemBuilder: (context, i) {
                            final profile = _memoryProfiles[i];
                            final isActive = _activeProfileIndex == i;
                            return Container(
                              decoration: BoxDecoration(
                                color: isActive
                                    ? Colors.purple.withOpacity(0.08)
                                    : (widget.isDarkMode
                                        ? const Color(0xFF2C2C2C)
                                        : Colors.grey[50]),
                                borderRadius:
                                    BorderRadius.circular(12),
                                border: isActive
                                    ? Border.all(
                                        color: Colors.purple
                                            .withOpacity(0.4))
                                    : null,
                              ),
                              child: ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: isActive
                                      ? Colors.purple
                                      : Colors.grey[700],
                                  radius: 18,
                                  child: Text(
                                    (profile['name'] ?? '?')
                                        .substring(0, 1)
                                        .toUpperCase(),
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold),
                                  ),
                                ),
                                title: Row(
                                  children: [
                                    Text(profile['name'] ?? '',
                                        style: const TextStyle(
                                            fontWeight:
                                                FontWeight.w600)),
                                    if (isActive) ...[
                                      const SizedBox(width: 6),
                                      Container(
                                        padding:
                                            const EdgeInsets.symmetric(
                                                horizontal: 6,
                                                vertical: 2),
                                        decoration: BoxDecoration(
                                          color: Colors.purple,
                                          borderRadius:
                                              BorderRadius.circular(
                                                  10),
                                        ),
                                        child: const Text('ACTIVE',
                                            style: TextStyle(
                                                fontSize: 9,
                                                color: Colors.white,
                                                fontWeight:
                                                    FontWeight.bold)),
                                      ),
                                    ],
                                  ],
                                ),
                                subtitle: Text(
                                  (profile['content'] ?? '').isEmpty
                                      ? 'Empty profile'
                                      : (profile['content']!.length >
                                              60
                                          ? '${profile['content']!.substring(0, 60)}...'
                                          : profile['content']!),
                                  style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey),
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    // Activate/deactivate
                                    IconButton(
                                      icon: Icon(
                                          isActive
                                              ? Icons.radio_button_checked
                                              : Icons.radio_button_unchecked,
                                          size: 20,
                                          color: isActive
                                              ? Colors.purple
                                              : Colors.grey),
                                      tooltip: isActive
                                          ? 'Deactivate'
                                          : 'Activate',
                                      onPressed: () {
                                        if (isActive) {
                                          _deactivateProfile();
                                        } else {
                                          _activateProfile(i);
                                        }
                                        setModalState(() {});
                                      },
                                    ),
                                    // Edit
                                    IconButton(
                                      icon: const Icon(Icons.edit,
                                          size: 18,
                                          color: Colors.grey),
                                      tooltip: 'Edit',
                                      onPressed: () =>
                                          _showEditProfileDialog(
                                              i,
                                              onSaved: () =>
                                                  setModalState(() {})),
                                    ),
                                    // Delete
                                    IconButton(
                                      icon: const Icon(Icons.delete,
                                          size: 18,
                                          color: Colors.red),
                                      tooltip: 'Delete',
                                      onPressed: () {
                                        _deleteMemoryProfile(i);
                                        setModalState(() {});
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showAddProfileDialog({required VoidCallback onAdded}) {
    final nameController = TextEditingController();
    final contentController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('New Memory Profile',
            style: TextStyle(fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: InputDecoration(
                labelText: 'Profile Name',
                hintText: 'e.g. Work Mode, Study Mode',
                filled: true,
                fillColor: const Color(0xFFF5F7FA),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: contentController,
              maxLines: 5,
              decoration: InputDecoration(
                labelText: 'Memory Content',
                hintText:
                    'Facts the AI should remember in this mode...',
                filled: true,
                fillColor: const Color(0xFFF5F7FA),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel',
                  style: TextStyle(color: Colors.grey))),
          ElevatedButton.icon(
            icon: const Icon(Icons.save, size: 16),
            label: const Text('Create'),
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.purple,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
            onPressed: () {
              if (nameController.text.trim().isEmpty) return;
              _addMemoryProfile(
                  nameController.text.trim(), contentController.text);
              Navigator.pop(context);
              onAdded();
            },
          ),
        ],
      ),
    );
  }

  void _showEditProfileDialog(int index,
      {required VoidCallback onSaved}) {
    final profile = _memoryProfiles[index];
    final nameController =
        TextEditingController(text: profile['name']);
    final contentController =
        TextEditingController(text: profile['content']);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Edit Profile',
            style: TextStyle(fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: InputDecoration(
                labelText: 'Profile Name',
                filled: true,
                fillColor: const Color(0xFFF5F7FA),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: contentController,
              maxLines: 5,
              decoration: InputDecoration(
                labelText: 'Memory Content',
                filled: true,
                fillColor: const Color(0xFFF5F7FA),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel',
                  style: TextStyle(color: Colors.grey))),
          ElevatedButton.icon(
            icon: const Icon(Icons.save, size: 16),
            label: const Text('Save'),
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.purple,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
            onPressed: () {
              setState(() {
                _memoryProfiles[index] = {
                  'name': nameController.text.trim(),
                  'content': contentController.text,
                };
                // If this is the active profile, update shared memory too
                if (_activeProfileIndex == index) {
                  _sharedMemory = contentController.text;
                  _saveSharedMemory(contentController.text);
                }
              });
              _saveMemoryProfiles();
              Navigator.pop(context);
              onSaved();
            },
          ),
        ],
      ),
    );
  }

  // ─── SHARED MEMORY DIALOG ────────────────────

  void _showSharedMemoryDialog() {
    final memController = TextEditingController(text: _sharedMemory);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.psychology, color: Colors.indigo),
            SizedBox(width: 8),
            Text('Shared Memory',
                style:
                    TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'These facts are injected into EVERY chat session, even after clearing history.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: memController,
              maxLines: 8,
              decoration: InputDecoration(
                hintText:
                    'e.g. My name is Ali. I am a Flutter developer. I prefer concise answers.',
                filled: true,
                fillColor: const Color(0xFFF5F7FA),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child:
                const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.save, size: 18),
            label: const Text('Save'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.indigo,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () {
              _saveSharedMemory(memController.text);
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('Shared memory saved!'),
                    backgroundColor: Colors.indigo),
              );
            },
          ),
        ],
      ),
    );
  }

  // ─── CONTEXT MANAGER ─────────────────────────

  void _showContextManager() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) {
          final usedTokens = _currentContextTokens;
          final percent = _contextUsagePercent;
          final color = percent > 0.85
              ? Colors.red
              : percent > 0.6
                  ? Colors.orange
                  : Colors.green;

          return Container(
            height: MediaQuery.of(context).size.height * 0.75,
            decoration: BoxDecoration(
              color: widget.isDarkMode
                  ? const Color(0xFF1E1E1E)
                  : Colors.white,
              borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24)),
            ),
            child: Column(
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 12, bottom: 8),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[400],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 8),
                  child: Row(
                    children: [
                      const Icon(Icons.memory, color: Colors.indigo),
                      const SizedBox(width: 8),
                      const Text('Context Manager',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 18)),
                      const Spacer(),
                      TextButton.icon(
                        icon: const Icon(Icons.auto_delete,
                            size: 16, color: Colors.red),
                        label: const Text('Trim Old',
                            style: TextStyle(color: Colors.red)),
                        onPressed: () {
                          if (_messages.length > 4) {
                            setState(() => _messages =
                                _messages.sublist(_messages.length - 4));
                            _saveMessages();
                            setModalState(() {});
                          }
                        },
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment:
                            MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Context Used: ~$usedTokens / $kMaxContextTokens tokens',
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey[600]),
                          ),
                          Text(
                            '${(percent * 100).toStringAsFixed(0)}%',
                            style: TextStyle(
                                fontSize: 12,
                                color: color,
                                fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: LinearProgressIndicator(
                          value: percent,
                          minHeight: 10,
                          backgroundColor: Colors.grey[300],
                          valueColor:
                              AlwaysStoppedAnimation<Color>(color),
                        ),
                      ),
                      const SizedBox(height: 4),
                      if (percent > 0.85)
                        const Text(
                          '⚠️ Context nearly full! Trim old messages.',
                          style:
                              TextStyle(fontSize: 11, color: Colors.red),
                        ),
                    ],
                  ),
                ),
                const Divider(height: 24),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    children: [
                      _contextRow(
                          icon: Icons.psychology,
                          label: 'Shared Memory',
                          tokens: _estimateTokens(_sharedMemory),
                          color: Colors.purple),
                      _contextRow(
                          icon: Icons.description,
                          label:
                              'Uploaded Files (${_filesData.length})',
                          tokens: _filesData.fold(
                              0,
                              (s, f) =>
                                  s +
                                  _estimateTokens(f['content'] ?? '')),
                          color: Colors.blue),
                      _contextRow(
                          icon: Icons.chat,
                          label:
                              'Chat History (${_messages.length} msgs)',
                          tokens: _messages.fold(
                              0,
                              (s, m) =>
                                  s +
                                  _estimateTokens(m['content'] ?? '')),
                          color: Colors.indigo),
                    ],
                  ),
                ),
                const Divider(height: 24),
                Expanded(
                  child: _messages.isEmpty
                      ? const Center(
                          child: Text('No messages yet',
                              style: TextStyle(color: Colors.grey)))
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16),
                          itemCount: _messages.length,
                          separatorBuilder: (_, __) => Divider(
                              height: 1,
                              color: Colors.grey.withOpacity(0.15)),
                          itemBuilder: (context, i) {
                            final msg = _messages[i];
                            final isUser = msg['role'] == 'user';
                            final tokens =
                                _estimateTokens(msg['content'] ?? '');
                            return ListTile(
                              dense: true,
                              leading: CircleAvatar(
                                radius: 14,
                                backgroundColor: isUser
                                    ? Colors.indigo
                                    : Colors.blueGrey,
                                child: Icon(
                                    isUser
                                        ? Icons.person
                                        : Icons.smart_toy,
                                    size: 14,
                                    color: Colors.white),
                              ),
                              title: Text(
                                (msg['content'] ?? '').length > 60
                                    ? '${msg['content']!.substring(0, 60)}...'
                                    : msg['content'] ?? '',
                                style:
                                    const TextStyle(fontSize: 13),
                              ),
                              subtitle: Text('~$tokens tokens',
                                  style: const TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey)),
                              trailing: IconButton(
                                icon: const Icon(
                                    Icons.remove_circle,
                                    color: Colors.red,
                                    size: 18),
                                onPressed: () {
                                  setState(
                                      () => _messages.removeAt(i));
                                  _saveMessages();
                                  setModalState(() {});
                                },
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _contextRow(
      {required IconData icon,
      required String label,
      required int tokens,
      required Color color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
              child:
                  Text(label, style: const TextStyle(fontSize: 13))),
          Text('~$tokens tokens',
              style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey[600],
                  fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  // ─── TTS & STT ──────────────────────────────

  Future<void> _initSpeech() async {
    _speech = stt.SpeechToText();
    try {
      _speechAvailable = await _speech.initialize(
        onError: (val) => debugPrint('Voice Error: $val'),
        onStatus: (val) {
          if (val == 'done' || val == 'notListening') {
            setState(() => _isListening = false);
          }
        },
      );
    } catch (e) {
      debugPrint('Mic init failed: $e');
    }
    setState(() {});
  }

  // TTS replaced with copy-to-clipboard (flutter_tts removed due to compatibility)
  Future<void> _speak(String text) async {
    if (_isSpeaking) {
      setState(() => _isSpeaking = false);
    } else {
      setState(() => _isSpeaking = true);
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('📋 Text copied — paste into any TTS app'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      setState(() => _isSpeaking = false);
    }
  }

  void _toggleListening() async {
    if (!_speechAvailable) {
      await _initSpeech();
      return;
    }
    if (_isListening) {
      await _speech.stop();
      setState(() => _isListening = false);
    } else {
      setState(() => _isListening = true);
      _speech.listen(
        onResult: (val) =>
            setState(() => _controller.text = val.recognizedWords),
      );
    }
  }

  // ─── FILE READING ────────────────────────────

  Future<void> _uploadFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true,
      );

      if (result == null || result.files.isEmpty) return;

      final pickedFile = result.files.single;
      final fileName = pickedFile.name.toLowerCase();
      String content = '';

      if (fileName.endsWith('.pdf')) {
        final path = pickedFile.path;
        if (path == null) {
          throw Exception('PDF path unavailable on this device');
        }
        content = await ReadPdfText.getPDFtext(path);
      } else if (pickedFile.bytes != null) {
        content = String.fromCharCodes(pickedFile.bytes!);
      } else if (pickedFile.path != null) {
        content = await File(pickedFile.path!).readAsString();
      } else {
        throw Exception('Could not read file data');
      }

      if (content.isEmpty) throw Exception('File is empty');

      // Truncate large files
      final originalLength = content.length;
      if (content.length > 8000) {
        content = '${content.substring(0, 8000)}\n... [Truncated — original: $originalLength chars]';
      }

      setState(() =>
          _filesData.add({'name': pickedFile.name, 'content': content}));

      if (mounted) {
        // Show a preview sheet after uploading
        _showFilePreview(pickedFile.name, content);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('❌ Upload failed: $e'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 5),
        ));
      }
    }
  }

  // Shows a bottom sheet preview of the uploaded file
  void _showFilePreview(String fileName, String content) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        height: MediaQuery.of(context).size.height * 0.7,
        decoration: BoxDecoration(
          color:
              widget.isDarkMode ? const Color(0xFF1E1E1E) : Colors.white,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            // Handle
            Container(
              margin: const EdgeInsets.only(top: 12, bottom: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: Colors.grey[400],
                  borderRadius: BorderRadius.circular(2)),
            ),
            // Header
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 20, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.description, color: Colors.indigo),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      fileName,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // Remove file button
                  TextButton.icon(
                    icon: const Icon(Icons.delete, size: 16,
                        color: Colors.red),
                    label: const Text('Remove',
                        style: TextStyle(color: Colors.red)),
                    onPressed: () {
                      setState(() => _filesData
                          .removeWhere((f) => f['name'] == fileName));
                      Navigator.pop(context);
                    },
                  ),
                ],
              ),
            ),
            // Stats row
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  _statChip(
                      '${content.length} chars', Icons.text_fields),
                  const SizedBox(width: 8),
                  _statChip(
                      '~${_estimateTokens(content)} tokens',
                      Icons.memory),
                  const SizedBox(width: 8),
                  _statChip('Active in AI', Icons.check_circle,
                      color: Colors.green),
                ],
              ),
            ),
            const Divider(height: 20),
            // Content preview
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                    horizontal: 20, vertical: 8),
                child: Text(
                  content,
                  style: TextStyle(
                    fontSize: 13,
                    fontFamily: 'monospace',
                    color: widget.isDarkMode
                        ? Colors.grey[300]
                        : Colors.black87,
                  ),
                ),
              ),
            ),
            // Done button
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.indigo,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Done — File is loaded ✓'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statChip(String label, IconData icon,
      {Color color = Colors.indigo}) {
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  fontSize: 11,
                  color: color,
                  fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  // ─── SEND MESSAGE ────────────────────────────

  Future<void> _sendMessage(String text) async {
    if (text.trim().isEmpty) return;
    if (_apiKey.isEmpty) {
      _showApiKeyScreen(canDismiss: false);
      return;
    }

    if (_isListening) {
      await _speech.stop();
      setState(() => _isListening = false);
    }

    _controller.clear();
    setState(() => _messages.add({'role': 'user', 'content': text, 'type': 'text'}));
    _setTyping(true);
    _saveMessages();
    _scrollToBottom();

    // ─── IMAGE COMMAND ───
    if (text.toLowerCase().startsWith('/img') ||
        text.toLowerCase().startsWith('/image') ||
        text.toLowerCase().startsWith('draw ')) {
      String prompt = text
          .replaceFirst(
              RegExp(r'^/img|^/image|^draw', caseSensitive: false),
              '')
          .trim();
      if (prompt.isEmpty) prompt = 'Abstract digital art';

      setState(() => _messages.add({
        'role': 'assistant',
        'content':
            'https://image.pollinations.ai/prompt/${Uri.encodeComponent(prompt)}',
        'type': 'image'
      }));
      _setTyping(false);
      _saveMessages();
      _scrollToBottom();
      return;
    }

    // ─── TEXT GENERATION ───
    try {
      String systemPrompt =
          'You are a helpful expert assistant. Use Markdown for code blocks.';

      if (_sharedMemory.trim().isNotEmpty) {
        systemPrompt +=
            '\n\n[PERSISTENT MEMORY - Always remember this]:\n$_sharedMemory';
      }

      if (_filesData.isNotEmpty) {
        systemPrompt +=
            '\n\n[UPLOADED FILES - Reference when relevant]:';
        for (final f in _filesData) {
          systemPrompt +=
              '\nFILE: ${f['name']}\nCONTENT: ${f['content']}\n';
        }
      }

      final recentMessages =
          _messages.where((m) => m['type'] != 'image').toList();
      final trimmed = recentMessages.length > 8
          ? recentMessages.sublist(recentMessages.length - 8)
          : recentMessages;

      final response = await http
          .post(
            Uri.parse('https://gen.pollinations.ai/v1/chat/completions'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $_apiKey',
            },
            body: jsonEncode({
              'messages': [
                {'role': 'system', 'content': systemPrompt},
                ...trimmed.map((m) =>
                    {'role': m['role'], 'content': m['content']}),
              ],
              'model': 'openai',
            }),
          )
          .timeout(const Duration(seconds: 40));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final reply = data['choices']?[0]?['message']?['content'] ?? '(No response)';
        setState(() => _messages.add({
              'role': 'assistant',
              'content': reply,
              'type': 'text'
            }));
        _saveMessages();
      } else {
        setState(() => _messages.add({
              'role': 'assistant',
              'content': '⚠️ Server Error: ${response.statusCode}',
              'type': 'text'
            }));
      }
    } catch (e) {
      setState(() => _messages.add({
            'role': 'assistant',
            'content': '⚠️ Network Error: $e',
            'type': 'text'
          }));
    } finally {
      _setTyping(false);
      _scrollToBottom();
    }
  }

  // ─── RETRY LAST RESPONSE ─────────────────────
  Future<void> _retryLastResponse() async {
    // Find last user message and remove last bot response
    if (_messages.length < 2) return;
    final lastBot = _messages.last;
    if (lastBot['role'] != 'assistant') return;
    final lastUserMsg = _messages
        .lastWhere((m) => m['role'] == 'user', orElse: () => {});
    if (lastUserMsg.isEmpty) return;
    setState(() => _messages.removeLast()); // remove old bot reply
    await _sendMessage(lastUserMsg['content'] ?? '');
  }

  // ─── ANIMATED TYPING INDICATOR ───────────────
  Widget _buildTypingIndicator() {
    return Padding(
      padding: const EdgeInsets.only(left: 16, bottom: 10),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: widget.isDarkMode
                ? const Color(0xFF1E1E2E)
                : Colors.white,
            borderRadius: BorderRadius.circular(20).copyWith(
              bottomLeft: Radius.zero,
            ),
            border: Border.all(
              color: widget.isDarkMode
                  ? Colors.white.withOpacity(0.06)
                  : Colors.grey.withOpacity(0.12),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.06),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(3, (i) {
              return AnimatedBuilder(
                animation: _dotAnimations[i],
                builder: (context, child) => Transform.translate(
                  offset: Offset(0, _dotAnimations[i].value),
                  child: Container(
                    margin: EdgeInsets.only(right: i < 2 ? 4 : 0),
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: const Color(0xFF7C3AED).withOpacity(0.7),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }

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

  // ─── BUILD ───────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final contextPercent = _contextUsagePercent;
    final contextColor = contextPercent > 0.85
        ? Colors.red
        : contextPercent > 0.6
            ? Colors.orange
            : Colors.green;

    return Scaffold(
      drawer: _buildDrawer(),
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF7C3AED), Color(0xFF2563EB)],
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.bolt, color: Colors.white, size: 16),
            ),
            const SizedBox(width: 10),
            const Text('AI Assistant'),
          ],
        ),
        centerTitle: true,
        actions: [
          GestureDetector(
            onTap: _showContextManager,
            child: Container(
              margin: const EdgeInsets.symmetric(
                  vertical: 12, horizontal: 4),
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: contextColor.withOpacity(0.15),
                borderRadius: BorderRadius.circular(20),
                border:
                    Border.all(color: contextColor.withOpacity(0.4)),
              ),
              child: Row(
                children: [
                  Icon(Icons.memory, size: 14, color: contextColor),
                  const SizedBox(width: 4),
                  Text(
                    '${(contextPercent * 100).toStringAsFixed(0)}%',
                    style: TextStyle(
                        fontSize: 12,
                        color: contextColor,
                        fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear chat',
            onPressed: () async {
              // Offer to save before clearing
              if (_messages.isNotEmpty) {
                showDialog(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                    title: const Text('Clear Chat?'),
                    content: const Text(
                        'Do you want to save this chat to history before clearing?'),
                    actions: [
                      TextButton(
                        onPressed: () async {
                          Navigator.pop(ctx);
                          setState(() {
                            _messages.clear();
                            _filesData.clear();
                          });
                          await StorageManager.clearMessages();
                        },
                        child: const Text('Discard',
                            style: TextStyle(color: Colors.red)),
                      ),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.teal,
                            foregroundColor: Colors.white),
                        onPressed: () async {
                          Navigator.pop(ctx);
                          final firstMsg = _messages.firstWhere(
                              (m) => m['role'] == 'user',
                              orElse: () =>
                                  {'content': 'Chat'})['content'] ??
                              'Chat';
                          final title = firstMsg.length > 40
                              ? '${firstMsg.substring(0, 40)}...'
                              : firstMsg;
                          await _saveCurrentSession(title);
                          setState(() {
                            _messages.clear();
                            _filesData.clear();
                          });
                          await StorageManager.clearMessages();
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('Chat saved & cleared!'),
                                  backgroundColor: Colors.teal),
                            );
                          }
                        },
                        child: const Text('Save & Clear'),
                      ),
                    ],
                  ),
                );
              }
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          // ── NO API KEY WARNING BANNER ──
          if (_apiKey.isEmpty)
            GestureDetector(
              onTap: () => _showApiKeyScreen(canDismiss: false),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 10),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF7C1D1D), Color(0xFF991B1B)],
                  ),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.warning_amber_rounded,
                        size: 16, color: Colors.white),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'API key not set — tap here to add your Pollinations key',
                        style:
                            TextStyle(fontSize: 12, color: Colors.white),
                      ),
                    ),
                    Icon(Icons.chevron_right,
                        size: 16, color: Colors.white70),
                  ],
                ),
              ),
            ),
          if (_sharedMemory.trim().isNotEmpty)
            GestureDetector(
              onTap: _showSharedMemoryDialog,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 6),
                color: Colors.indigo.withOpacity(0.1),
                child: Row(
                  children: [
                    const Icon(Icons.psychology,
                        size: 14, color: Colors.indigo),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Shared memory active: ${_sharedMemory.length > 50 ? '${_sharedMemory.substring(0, 50)}...' : _sharedMemory}',
                        style: const TextStyle(
                            fontSize: 11, color: Colors.indigo),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const Icon(Icons.edit,
                        size: 12, color: Colors.indigo),
                  ],
                ),
              ),
            ),
          Expanded(
            child: _messages.isEmpty
                ? _buildEmptyState()
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16),
                    itemCount: _messages.length,
                    itemBuilder: (context, i) =>
                        _buildBubble(_messages[i], i),
                  ),
          ),
          if (_isTyping) _buildTypingIndicator(),
          _buildInputArea(),
        ],
      ),
    );
  }

  // ─── DRAWER ──────────────────────────────────

  Widget _buildDrawer() {
    return Drawer(
      backgroundColor:
          widget.isDarkMode ? const Color(0xFF1E1E1E) : Colors.white,
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          UserAccountsDrawerHeader(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF7C3AED), Color(0xFF2563EB)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            accountName: const Text('Nexus AI',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            accountEmail:
                Text('Files: ${_filesData.length} | Mode: Online',
                    style: const TextStyle(fontSize: 12)),
            currentAccountPicture: Container(
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.15),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white38, width: 2),
              ),
              child: const Icon(Icons.smart_toy_rounded,
                  size: 32, color: Colors.white),
            ),
          ),
          ListTile(
            leading:
                const Icon(Icons.psychology, color: Colors.purple),
            title: const Text('Shared Memory'),
            subtitle: Text(
              _sharedMemory.isEmpty
                  ? 'Tap to add persistent facts'
                  : 'Active — tap to edit',
              style: TextStyle(
                  color: _sharedMemory.isEmpty
                      ? Colors.grey
                      : Colors.purple),
            ),
            trailing: _sharedMemory.isNotEmpty
                ? const Icon(Icons.circle,
                    size: 10, color: Colors.purple)
                : null,
            onTap: () {
              Navigator.pop(context);
              _showSharedMemoryDialog();
            },
          ),
          // ✅ NEW: Memory Profiles tile
          ListTile(
            leading: const Icon(Icons.library_books, color: Colors.deepPurple),
            title: const Text('Memory Profiles'),
            subtitle: Text(
              _memoryProfiles.isEmpty
                  ? 'Create reusable memory sets'
                  : '${_memoryProfiles.length} profile(s)${_activeProfileIndex >= 0 ? ' • 1 active' : ''}',
              style: TextStyle(
                  color: _activeProfileIndex >= 0
                      ? Colors.deepPurple
                      : Colors.grey),
            ),
            trailing: _activeProfileIndex >= 0
                ? const Icon(Icons.circle, size: 10, color: Colors.deepPurple)
                : null,
            onTap: () {
              Navigator.pop(context);
              _showMemoryLibrary();
            },
          ),
          ListTile(
            leading: const Icon(Icons.memory, color: Colors.teal),
            title: const Text('Context Manager'),
            subtitle: Text(
                '~$_currentContextTokens / $kMaxContextTokens tokens used'),
            onTap: () {
              Navigator.pop(context);
              _showContextManager();
            },
          ),
          // ✅ NEW: Chat History tile
          ListTile(
            leading: const Icon(Icons.history, color: Colors.teal),
            title: const Text('Chat History'),
            subtitle: Text(
              _chatSessions.isEmpty
                  ? 'No saved chats yet'
                  : '${_chatSessions.length} saved chat(s)',
              style: TextStyle(
                  color: _chatSessions.isEmpty
                      ? Colors.grey
                      : Colors.teal),
            ),
            onTap: () {
              Navigator.pop(context);
              _showChatHistory();
            },
          ),
          ListTile(
            leading:
                const Icon(Icons.upload_file, color: Colors.blue),
            title: const Text('Upload Context (PDF/Txt)'),
            subtitle: const Text('Give the bot a brain'),
            onTap: () {
              Navigator.pop(context);
              _uploadFile();
            },
          ),
          ListTile(
            leading:
                const Icon(Icons.image, color: Colors.pinkAccent),
            title: const Text('Image Generation'),
            subtitle: const Text('Type "/img cat in space"'),
            onTap: () => Navigator.pop(context),
          ),

          // ─── NEW: Debugger info tile ───
          ListTile(
            leading: const Icon(Icons.bug_report, color: Colors.orange),
            title: const Text('Self-Correction Debugger'),
            subtitle: const Text(
                'Tap 🐛 on any code response to auto-fix'),
            onTap: () => Navigator.pop(context),
          ),

          const Divider(),
          // API KEY TILE
          ListTile(
            leading: const Icon(Icons.key_rounded, color: Color(0xFF7C3AED)),
            title: const Text('API Key'),
            subtitle: Text(
              _apiKey.isEmpty
                  ? 'Not set — tap to add'
                  : '${_apiKey.substring(0, _apiKey.length > 8 ? 8 : _apiKey.length)}••••••••',
              style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: _apiKey.isEmpty ? Colors.red : Colors.grey),
            ),
            trailing: _apiKey.isNotEmpty
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.check_circle,
                          size: 14, color: Colors.green),
                      const SizedBox(width: 4),
                      const Text('Set',
                          style:
                              TextStyle(fontSize: 11, color: Colors.green)),
                    ],
                  )
                : const Icon(Icons.warning_amber_rounded,
                    size: 16, color: Colors.red),
            onTap: () {
              Navigator.pop(context);
              _showApiKeyScreen(canDismiss: true);
            },
          ),
          ListTile(
            leading: Icon(widget.isDarkMode
                ? Icons.light_mode
                : Icons.dark_mode),
            title: Text(
                widget.isDarkMode ? 'Light Mode' : 'Dark Mode'),
            onTap: widget.onToggleTheme,
          ),
        ],
      ),
    );
  }

  // ─── EMPTY STATE ─────────────────────────────

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Gradient icon
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF7C3AED), Color(0xFF2563EB)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(28),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF7C3AED).withOpacity(0.35),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: const Icon(Icons.auto_awesome,
                  size: 44, color: Colors.white),
            ),
            const SizedBox(height: 24),
            const Text('Nexus',
                style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5)),
            const SizedBox(height: 8),
            Text(
              'Your intelligent knowledge assistant',
              style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey[500]),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            // Feature pills
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                _featurePill('💬 Ask anything', const Color(0xFF7C3AED),
                    hint: 'What can you help me with?'),
                _featurePill('📎 Upload PDFs', const Color(0xFF2563EB),
                    onTap: _uploadFile),
                _featurePill('🎨 /img to draw', const Color(0xFFDB2777),
                    hint: '/img '),
                _featurePill('🧠 Shared Memory', const Color(0xFF059669),
                    onTap: _showSharedMemoryDialog),
                _featurePill('🐛 Auto-Debug', const Color(0xFFD97706),
                    hint: 'Write me a Flutter function to '),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _featurePill(String label, Color color,
      {String? hint, VoidCallback? onTap}) {
    return GestureDetector(
      onTap: () {
        if (onTap != null) {
          onTap();
        } else if (hint != null) {
          _controller.text = hint;
          _controller.selection = TextSelection.fromPosition(
              TextPosition(offset: hint.length));
          _inputHasText.value = hint.trim().isNotEmpty;
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withOpacity(0.25)),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12,
                color: color,
                fontWeight: FontWeight.w600)),
      ),
    );
  }

  // ─── BUBBLE ──────────────────────────────────
  // Now accepts index for the debugger

  Widget _buildBubble(Map<String, String> msg, int index) {
    final isUser = msg['role'] == 'user';
    final isImage = msg['type'] == 'image';
    final isDebugRequest = msg['isDebug'] == 'true';
    final isDebugResult = msg['isDebugResult'] == 'true';
    final content = msg['content'] ?? '';
    final hasCode = _hasCodeBlocks(content);
    final isDebugging = _debuggingIndexes.contains(index);

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.85),
        child: Column(
          crossAxisAlignment: isUser
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            // ── DEBUG RESULT LABEL ──
            if (isDebugResult)
              Container(
                margin: const EdgeInsets.only(bottom: 4),
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: Colors.orange.withOpacity(0.4)),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.bug_report,
                        size: 12, color: Colors.orange),
                    SizedBox(width: 4),
                    Text('Debugger Result',
                        style: TextStyle(
                            fontSize: 11, color: Colors.orange)),
                  ],
                ),
              ),

            // ── DEBUG REQUEST LABEL ──
            if (isDebugRequest)
              Container(
                margin: const EdgeInsets.only(bottom: 4),
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.settings_suggest,
                        size: 12, color: Colors.orange),
                    SizedBox(width: 4),
                    Text('Auto-Debug Request',
                        style: TextStyle(
                            fontSize: 11, color: Colors.orange)),
                  ],
                ),
              ),

            // ── BUBBLE BODY ──
            Container(
              padding: isImage
                  ? const EdgeInsets.all(4)
                  : const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isUser
                    ? (isDebugRequest
                        ? Colors.orange.shade800
                        : const Color(0xFF7C3AED))
                    : (isDebugResult
                        ? (widget.isDarkMode
                            ? const Color(0xFF2A1F00)
                            : const Color(0xFFFFF8E1))
                        : (widget.isDarkMode
                            ? const Color(0xFF1E1E2E)
                            : Colors.white)),
                borderRadius: BorderRadius.circular(20).copyWith(
                  bottomRight: isUser
                      ? Radius.zero
                      : const Radius.circular(20),
                  bottomLeft: isUser
                      ? const Radius.circular(20)
                      : Radius.zero,
                ),
                border: isDebugResult
                    ? Border.all(
                        color: Colors.orange.withOpacity(0.3))
                    : (!isUser && !isDebugResult)
                        ? Border.all(
                            color: widget.isDarkMode
                                ? Colors.white.withOpacity(0.06)
                                : Colors.grey.withOpacity(0.12))
                        : null,
                boxShadow: [
                  BoxShadow(
                      color: isUser
                          ? const Color(0xFF7C3AED).withOpacity(0.3)
                          : Colors.black.withOpacity(0.06),
                      blurRadius: 8,
                      offset: const Offset(0, 2))
                ],
              ),
              child: isImage
                  ? _buildImage(content)
                  : _buildMarkdown(content, isUser),
            ),

            // ── ACTION BUTTONS (Bot only) ──
            if (!isUser)
              Padding(
                padding:
                    const EdgeInsets.only(top: 4, left: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // TTS
                    IconButton(
                      icon: Icon(
                          _isSpeaking
                              ? Icons.stop_circle
                              : Icons.volume_up,
                          size: 18,
                          color: Colors.grey),
                      onPressed: () => _speak(content),
                      tooltip: 'Read Aloud',
                    ),
                    // COPY
                    IconButton(
                      icon: const Icon(Icons.copy,
                          size: 18, color: Colors.grey),
                      onPressed: () {
                        Clipboard.setData(
                            ClipboardData(text: content));
                        ScaffoldMessenger.of(context)
                            .showSnackBar(const SnackBar(
                                content: Text('Copied!'),
                                duration:
                                    Duration(milliseconds: 600)));
                      },
                      tooltip: 'Copy',
                    ),
                    // RETRY — only on the last bot message
                    if (index == _messages.length - 1 && !_isTyping)
                      Tooltip(
                        message: 'Regenerate response',
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: _retryLastResponse,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.grey.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.refresh,
                                    size: 14,
                                    color: Colors.grey[500]),
                                const SizedBox(width: 4),
                                Text('Retry',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey[500])),
                              ],
                            ),
                          ),
                        ),
                      ),

                    // ─── NEW: DEBUG BUTTON ───
                    // Only shows on bot messages that contain code blocks
                    if (hasCode && !isImage)
                      isDebugging
                          ? const SizedBox(
                              width: 32,
                              height: 32,
                              child: Padding(
                                padding: EdgeInsets.all(6),
                                child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.orange),
                              ),
                            )
                          : Tooltip(
                              message:
                                  'Auto-debug & fix this code',
                              child: InkWell(
                                borderRadius:
                                    BorderRadius.circular(8),
                                onTap: () => _debugCode(index),
                                child: Container(
                                  padding:
                                      const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Colors.orange
                                        .withOpacity(0.15),
                                    borderRadius:
                                        BorderRadius.circular(8),
                                    border: Border.all(
                                        color: Colors.orange
                                            .withOpacity(0.4)),
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.bug_report,
                                          size: 14,
                                          color: Colors.orange),
                                      SizedBox(width: 4),
                                      Text('Debug',
                                          style: TextStyle(
                                              fontSize: 12,
                                              color: Colors.orange,
                                              fontWeight:
                                                  FontWeight.w600)),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildImage(String url) {
    // Inline 1x1 transparent PNG — no external package needed
    final transparentPixel = Uint8List.fromList([
      0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,0x00,0x00,0x00,0x0D,0x49,0x48,0x44,0x52,
      0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x01,0x08,0x06,0x00,0x00,0x00,0x1F,0x15,0xC4,
      0x89,0x00,0x00,0x00,0x0A,0x49,0x44,0x41,0x54,0x78,0x9C,0x62,0x00,0x01,0x00,0x00,
      0x05,0x00,0x01,0x0D,0x0A,0x2D,0xB4,0x00,0x00,0x00,0x00,0x49,0x45,0x4E,0x44,0xAE,
      0x42,0x60,0x82,
    ]);
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(
        children: [
          const SizedBox(
              height: 250,
              width: 250,
              child: Center(child: CircularProgressIndicator())),
          FadeInImage.memoryNetwork(
            placeholder: transparentPixel,
            image: url,
            fit: BoxFit.cover,
            imageErrorBuilder: (c, o, s) => Container(
              height: 150,
              width: 150,
              color: Colors.grey[800],
              child: const Icon(Icons.broken_image, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMarkdown(String content, bool isUser) {
    return MarkdownBody(
      data: content,
      selectable: true,
      builders: {'code': CodeElementBuilder()},
      styleSheet: MarkdownStyleSheet(
        p: TextStyle(
          color: isUser
              ? Colors.white
              : (widget.isDarkMode
                  ? Colors.grey[200]
                  : Colors.black87),
          fontSize: 15,
        ),
        code: TextStyle(
          backgroundColor: widget.isDarkMode
              ? const Color(0xFF1E1E1E)
              : Colors.grey[200],
          fontFamily: 'monospace',
        ),
        codeblockDecoration: BoxDecoration(
          color: widget.isDarkMode
              ? const Color(0xFF151515)
              : Colors.grey[100],
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.grey.withOpacity(0.2)),
        ),
      ),
    );
  }

  // ─── INPUT AREA ──────────────────────────────

  Widget _buildInputArea() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── UPLOADED FILES CHIPS ──
        if (_filesData.isNotEmpty)
          Container(
            width: double.infinity,
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: widget.isDarkMode
                ? const Color(0xFF1A1A1A)
                : const Color(0xFFF0F0F0),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: _filesData.asMap().entries.map((entry) {
                final i = entry.key;
                final f = entry.value;
                return GestureDetector(
                  onTap: () => _showFilePreview(
                      f['name'] ?? '', f['content'] ?? ''),
                  child: Chip(
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                  backgroundColor: Colors.indigo.withOpacity(0.15),
                  side: BorderSide(color: Colors.indigo.withOpacity(0.3)),
                  avatar: const Icon(Icons.description,
                      size: 14, color: Colors.indigo),
                  label: Text(
                    f['name'] ?? '',
                    style: const TextStyle(
                        fontSize: 11, color: Colors.indigo),
                  ),
                  deleteIcon: const Icon(Icons.close,
                      size: 14, color: Colors.red),
                  onDeleted: () =>
                      setState(() => _filesData.removeAt(i)),
                  ),
                );
              }).toList(),
            ),
          ),
        // ── INPUT ROW ──
        Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        color: widget.isDarkMode
            ? const Color(0xFF161616)
            : Colors.white,
        border: Border(
            top: BorderSide(color: Colors.grey.withOpacity(0.08))),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 12,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        children: [
          // MIC BUTTON
          GestureDetector(
            onTap: _toggleListening,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: _isListening
                    ? Colors.redAccent
                    : (widget.isDarkMode
                        ? const Color(0xFF2A2A3E)
                        : const Color(0xFFEEEEF5)),
                shape: BoxShape.circle,
              ),
              child: Icon(
                _isListening ? Icons.graphic_eq : Icons.mic,
                color: _isListening
                    ? Colors.white
                    : (widget.isDarkMode
                        ? Colors.white60
                        : Colors.black54),
                size: 20,
              ),
            ),
          ),
          const SizedBox(width: 6),
          // UPLOAD BUTTON
          GestureDetector(
            onTap: _uploadFile,
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: _filesData.isEmpty
                    ? (widget.isDarkMode
                        ? const Color(0xFF2A2A3E)
                        : const Color(0xFFEEEEF5))
                    : const Color(0xFF7C3AED),
                shape: BoxShape.circle,
              ),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(Icons.attach_file,
                      color: _filesData.isEmpty
                          ? (widget.isDarkMode
                              ? Colors.white60
                              : Colors.black54)
                          : Colors.white,
                      size: 20),
                  if (_filesData.isNotEmpty)
                    Positioned(
                      right: -6,
                      top: -6,
                      child: Container(
                        width: 14,
                        height: 14,
                        decoration: const BoxDecoration(
                          color: Colors.orangeAccent,
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: Text(
                            '${_filesData.length}',
                            style: const TextStyle(
                                fontSize: 8,
                                color: Colors.white,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _controller,
              minLines: 1,
              maxLines: 5,
              style: TextStyle(
                  color: widget.isDarkMode ? Colors.white : Colors.black87,
                  fontSize: 15),
              decoration: InputDecoration(
                hintText: 'Ask anything or type /img...',
                hintStyle: TextStyle(
                    color: widget.isDarkMode
                        ? Colors.white30
                        : Colors.black38,
                    fontSize: 14),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(25),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: widget.isDarkMode
                    ? const Color(0xFF252535)
                    : const Color(0xFFF0F0F8),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 20, vertical: 10),
              ),
              onSubmitted: _sendMessage,
            ),
          ),
          const SizedBox(width: 8),
          // SEND BUTTON — dims when empty
          ValueListenableBuilder<bool>(
            valueListenable: _inputHasText,
            builder: (_, hasText, __) => GestureDetector(
              onTap: hasText ? () => _sendMessage(_controller.text) : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  gradient: hasText
                      ? const LinearGradient(
                          colors: [Color(0xFF7C3AED), Color(0xFF2563EB)],
                        )
                      : LinearGradient(
                          colors: [
                            Colors.grey.withOpacity(0.3),
                            Colors.grey.withOpacity(0.3),
                          ],
                        ),
                  shape: BoxShape.circle,
                  boxShadow: hasText
                      ? const [
                          BoxShadow(
                            color: Color(0x557C3AED),
                            blurRadius: 10,
                            offset: Offset(0, 3),
                          )
                        ]
                      : [],
                ),
                child: Icon(Icons.send_rounded,
                    color: hasText ? Colors.white : Colors.grey[500],
                    size: 18),
              ),
            ),
          ),
        ],
      ),
        ), // closes Container (input row)
      ], // closes Column children
    ); // closes Column
  }
}

// ─── SYNTAX HIGHLIGHTER ──────────────────────
// CodeElementBuilder is kept minimal — full syntax highlighting via
// MarkdownStyleSheet codeblockDecoration above is sufficient.
// Extending MarkdownElementBuilder with no overrides uses the default
// rendering, which respects our custom codeblockDecoration styling.
class CodeElementBuilder extends MarkdownElementBuilder {}
