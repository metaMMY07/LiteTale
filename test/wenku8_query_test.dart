import 'package:flutter_test/flutter_test.dart';
import 'package:wild/utils/wenku8_query.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('search/tag query uses Wenku8 GBK bytes and escapes delimiters', () async {
    expect(await wenku8EncodeQuery('轻小说'), '%C7%E1%D0%A1%CB%B5');
    expect(await wenku8EncodeQuery('校园'), '%D0%A3%D4%B0');
    expect(await wenku8EncodeQuery('A &+/#?'), 'A%20%26%2B%2F%23%3F');
    expect(await wenku8EncodeQuery('奇招百出的维多利亚'), '%C6%E6%D5%D0%B0%D9%B3%F6%B5%C4%CE%AC%B6%E0%C0%FB%D1%C7');
  });

  test('unrepresentable characters fail instead of corrupting search', () {
    expect(wenku8EncodeQuery('🙂'), throwsFormatException);
  });
}
