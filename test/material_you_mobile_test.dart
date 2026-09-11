import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/pages/auth_cubit.dart';
import 'package:wild/pages/login_page.dart';
import 'package:wild/pages/home/more_page.dart';
import 'package:wild/pages/update_cubit.dart';
import 'package:wild/theme/material_you.dart';

class PreviewAuthCubit extends AuthCubit {
  List<String>? submitted;
  PreviewAuthCubit() {
    emit(const AuthState(status: AuthStatus.unauthenticated));
  }
  @override
  Future<void> loadCheckcode() async {}
  @override
  Future<void> login(String username, String password, String checkcode) async {
    submitted = [username, password, checkcode];
  }
}

void main() {
  for (final brightness in Brightness.values) {
    test('wallpaper colors retain distinct tonal surfaces in $brightness', () {
      final wallpaper = ColorScheme.fromSeed(
        seedColor: Colors.orange,
        brightness: brightness,
      );
      final theme = materialYouTheme(brightness, dynamicScheme: wallpaper);
      expect(
        theme.colorScheme.surfaceContainerLow,
        isNot(theme.colorScheme.surface),
      );
      expect(theme.colorScheme.brightness, brightness);
      final foreground = theme.colorScheme.onSurface.computeLuminance();
      final background = theme.colorScheme.surface.computeLuminance();
      final contrast =
          (foreground > background)
              ? (foreground + 0.05) / (background + 0.05)
              : (background + 0.05) / (foreground + 0.05);
      expect(contrast, greaterThan(4.5));
    });
  }
  for (final size in [const Size(320, 640), const Size(640, 360)]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'login stays scrollable at $size in $brightness with keyboard',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          tester.view.viewInsets = const FakeViewPadding(bottom: 180);
          addTearDown(tester.view.reset);
          final auth = PreviewAuthCubit();
          addTearDown(auth.close);
          await tester.pumpWidget(
            BlocProvider<AuthCubit>.value(
              value: auth,
              child: MaterialApp(
                theme: materialYouTheme(brightness),
                home: const LoginPage(),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextFormField).at(0), 'reader');
          await tester.enterText(find.byType(TextFormField).at(1), 'password');
          await tester.enterText(find.byType(TextFormField).at(2), '1234');
          await tester.ensureVisible(find.byType(FilledButton));
          await tester.tap(find.byType(FilledButton));
          await tester.pumpAndSettle();
          expect(auth.submitted, ['reader', 'password', '1234']);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('personal page supports narrow screens and large text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.reset);
    final auth = PreviewAuthCubit();
    final updates = UpdateCubit();
    addTearDown(auth.close);
    addTearDown(updates.close);
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<AuthCubit>.value(value: auth),
          BlocProvider<UpdateCubit>.value(value: updates),
        ],
        child: MaterialApp(
          theme: materialYouTheme(Brightness.dark),
          builder:
              (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(1.5)),
                child: child!,
              ),
          home: const MorePage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('关于 LiteTale'), 200);
    expect(tester.takeException(), isNull);
  });
}
