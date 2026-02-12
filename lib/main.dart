import 'package:flutter/material.dart';
import 'chat_screen.dart';
// We don't import config.dart here because it might be missing on GitHub.
// We will pass the key into ChatScreen manually.

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Knowledge Bot',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      ),
      home: const Initializer(),
    );
  }
}

class Initializer extends StatefulWidget {
  const Initializer({super.key});

  @override
  State<Initializer> createState() => _InitializerState();
}

class _InitializerState extends State<Initializer> {
  String? activeApiKey;

  @override
  void initState() {
    super.initState();
    // This triggers the popup as soon as the app starts
    Future.delayed(Duration.zero, () => _showKeyDialog());
  }

  void _showKeyDialog() {
    TextEditingController keyController = TextEditingController();
    
    showDialog(
      context: context,
      barrierDismissible: false, // User must enter a key to proceed
      builder: (context) => AlertDialog(
        title: const Text("Enter Pollinations API Key"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("To keep this app free, please use your own API key."),
            const SizedBox(height: 15),
            TextField(
              controller: keyController,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: "Paste your key here",
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              if (keyController.text.isNotEmpty) {
                setState(() {
                  activeApiKey = keyController.text;
                });
                Navigator.pop(context);
              }
            },
            child: const Text("Start Chatting"),
          )
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // If we don't have a key yet, show a loading screen or black background
    if (activeApiKey == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    // Pass the key to your ChatScreen
    return ChatScreen(apiKey: activeApiKey!);
  }
}