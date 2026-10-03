import 'ptq_curl_test.dart' as single_page;
import 'tablet_reader_test.dart' as tablet;

// Exercise both production paths in the same APK after native geometry edits.
void main() {
  single_page.main();
  tablet.main();
}
