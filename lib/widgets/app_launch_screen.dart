import 'package:flutter/material.dart';
import 'package:wild/theme/ios_system_colors.dart';
import 'package:wild/widgets/apple_glass_chrome.dart';
import 'package:wild/widgets/app_loading_indicator.dart';

/// The same approved book artwork used by the native launch screen and login.
class AppLaunchScreen extends StatelessWidget {
  const AppLaunchScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final apple = usesAppleGlass;
    final brightness = MediaQuery.platformBrightnessOf(context);
    final artwork = Image.asset(
      'lib/assets/app_brand.png',
      width: 104,
      height: 104,
      fit: BoxFit.contain,
      semanticLabel: 'LiteTale',
    );
    // Use the same canvas and centred mark as LaunchScreen.storyboard. Only
    // the loading indicator needs the safe area on iOS.
    final content = Stack(
      fit: StackFit.expand,
      children: [
        Center(
          child:
              apple
                  ? ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: artwork,
                  )
                  : artwork,
        ),
        SafeArea(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 48),
              child: AppLoadingIndicator(
                size: 24,
                color:
                    apple
                        ? IosSystemColors.color('ios-blue', brightness)
                        : null,
              ),
            ),
          ),
        ),
      ],
    );
    return Scaffold(
      backgroundColor:
          apple ? IosSystemColors.color('background', brightness) : null,
      body: apple ? content : SafeArea(child: content),
    );
  }
}
