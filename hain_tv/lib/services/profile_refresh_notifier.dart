import 'package:flutter/foundation.dart';

class ProfileRefreshNotifier extends ChangeNotifier {
  ProfileRefreshNotifier._();

  static final ProfileRefreshNotifier instance = ProfileRefreshNotifier._();

  void notify() => notifyListeners();
}
