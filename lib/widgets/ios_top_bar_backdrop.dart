import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';

/// Lets content scroll under the transparent iOS title and controls.
class IosTopBarScaffold extends StatelessWidget {
  const IosTopBarScaffold({
    super.key,
    this.appBar,
    required this.body,
    this.backgroundColor,
    this.floatingActionButton,
    this.bottomNavigationBar,
  });

  final PreferredSizeWidget? appBar;
  final Widget body;
  final Color? backgroundColor;
  final Widget? floatingActionButton;
  final Widget? bottomNavigationBar;

  @override
  Widget build(BuildContext context) {
    final bar = appBar;
    final extend = usesAppleGlass && bar != null;
    return Scaffold(
      extendBodyBehindAppBar: extend,
      backgroundColor: backgroundColor,
      floatingActionButton: floatingActionButton,
      bottomNavigationBar: bottomNavigationBar,
      appBar:
          extend
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
