import 'package:flutter/widgets.dart';

import 'app.dart';
import 'state/astra_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(AstraBootstrap(controller: AstraController()));
}
