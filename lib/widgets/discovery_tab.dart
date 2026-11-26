import 'package:flutter/widgets.dart';

/// Keeps only visited discovery tabs alive, including their Cubit, filter and
/// scroll position. The parent keys the tab set by source/session revision.
class DiscoveryTab extends StatefulWidget {
  const DiscoveryTab({super.key, required this.child});
  final Widget child;
  @override
  State<DiscoveryTab> createState() => _DiscoveryTabState();
}

class _DiscoveryTabState extends State<DiscoveryTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
