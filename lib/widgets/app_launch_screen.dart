import 'package:flutter/material.dart';
import 'package:wild/widgets/app_loading_indicator.dart';

/// The same approved book artwork used by the native launch screen and login.
class AppLaunchScreen extends StatelessWidget {
  const AppLaunchScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: Image.asset(
              'lib/assets/app_brand.png',
              width: 104,
              height: 104,
              fit: BoxFit.contain,
              semanticLabel: 'LiteTale',
            ),
          ),
          const Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.only(bottom: 48),
              child: AppLoadingIndicator(size: 24),
            ),
          ),
        ],
      ),
    ),
  );
}
