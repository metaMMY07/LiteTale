import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';

/// Places the iOS title bar above the body, with an opt-in for the detail header.
class IosTopBarScaffold extends StatelessWidget {
  const IosTopBarScaffold({
    super.key,
    this.appBar,
    required this.body,
    this.backgroundColor,
    this.floatingActionButton,
    this.bottomNavigationBar,
    this.extendBodyBehindAppBar = false,
  });

  final PreferredSizeWidget? appBar;
  final Widget body;
  final Color? backgroundColor;
  final Widget? floatingActionButton;
  final Widget? bottomNavigationBar;
  final bool extendBodyBehindAppBar;

  @override
  Widget build(BuildContext context) {
    final bar = appBar;
    final apple = usesAppleGlass && bar != null;
    return Scaffold(
      extendBodyBehindAppBar: apple && extendBodyBehindAppBar,
      backgroundColor: backgroundColor,
      floatingActionButton: floatingActionButton,
      bottomNavigationBar: bottomNavigationBar,
      appBar:
          apple
              ? PreferredSize(
                preferredSize: bar.preferredSize,
                child: AnnotatedRegion<SystemUiOverlayStyle>(
                  value:
                      Theme.of(context).brightness == Brightness.dark
                          ? SystemUiOverlayStyle.light
                          : SystemUiOverlayStyle.dark,
                  child: bar,
                ),
              )
              : bar,
      body: body,
    );
  }
}
