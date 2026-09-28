// Run with: flutter run -d emulator-5554 -t tools/ptq_visual_demo.dart
// Manual QA surface for Android platform-view gestures and native screenshots.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wild/widgets/page_curl_view.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
  ]);
  runApp(const _CurlDemo());
}

class _CurlDemo extends StatefulWidget {
  const _CurlDemo();

  @override
  State<_CurlDemo> createState() => _CurlDemoState();
}

class _CurlDemoState extends State<_CurlDemo> {
  int page = 1;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: const Color(0xFF171717),
      body: PageCurlView(
        pageCount: 3,
        index: page,
        paperColor: const Color(0xFF171717),
        paperDecoration: const BoxDecoration(color: Color(0xFF171717)),
        onPageChanged: (value) => setState(() => page = value),
        pageBuilder: (_, index) => Padding(
          padding: const EdgeInsets.fromLTRB(30, 60, 30, 30),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '第 $index 页 · 文字扭曲验收',
                style: const TextStyle(color: Color(0xFFD9D9D9), fontSize: 18),
              ),
              const SizedBox(height: 20),
              for (var line = 0; line < 7; line++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    '那是个空气清新、名产丰富的乡间小镇。为了抛弃这个国家，我决定即刻采取行动。第 ${index * 10 + line} 行文字。',
                    style: const TextStyle(
                      color: Color(0xFFD9D9D9),
                      fontSize: 17,
                      height: 1.2,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
