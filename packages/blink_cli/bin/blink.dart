import 'dart:io';

import 'package:blink_cli/blink_cli.dart';

Future<void> main(List<String> args) async {
  final runner = BlinkCliRunner();
  final code = await runner.run(args);
  exitCode = code;
}
