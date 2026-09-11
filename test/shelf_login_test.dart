import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wild/pages/shelf_login_page.dart';

void main() {
  testWidgets('native shelf login submits trimmed email and hides the password', (tester) async {
    String? submittedEmail;
    await tester.pumpWidget(MaterialApp(home: ShelfLoginPage(login: (email, password) async {
      submittedEmail = email;
      expect(password, 'test-only-password');
      throw StateError('测试登录失败');
    })));
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.first, ' reader@example.com ');
    await tester.enterText(fields.last, 'test-only-password');
    expect(tester.widget<EditableText>(find.byType(EditableText).last).obscureText, isTrue);
    await tester.tap(find.widgetWithText(FilledButton, '登录'));
    await tester.pumpAndSettle();
    expect(submittedEmail, 'reader@example.com');
    expect(find.text('测试登录失败'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNotNull);
  });

  testWidgets('native shelf login stays usable on a narrow screen with keyboard', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: ShelfLoginPage()));
    await tester.ensureVisible(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(find.text('请输入邮箱'), findsOneWidget);
    expect(find.text('请输入密码'), findsOneWidget);
  });
}
