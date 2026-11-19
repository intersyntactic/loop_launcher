import 'package:is_effects/is_effects.dart' show ModelSignInName;
import 'package:is_loop_launcher/is_loop_launcher.dart';
import 'package:test/test.dart';

void main() {
  test('reads sign-in:count pairs, and sets no limit for a sign-in it '
      'does not name', () {
    final limits = LoopLimitPerModelSignIn.parse(
      'cam-chatgpt:4,nick-claude-team:0',
    )!;
    expect(limits.of(ModelSignInName.parse('cam-chatgpt')!), 4);
    expect(limits.of(ModelSignInName.parse('nick-claude-team')!), 0);
    expect(limits.of(ModelSignInName.parse('other')!), isNull);
  });

  test('refuses anything but sign-in:count pairs, each sign-in once', () {
    for (final raw in [
      '',
      'cam-chatgpt',
      'cam-chatgpt:',
      'cam-chatgpt:four',
      'cam-chatgpt:-1',
      'cam-chatgpt:+4',
      'cam-chatgpt: 4',
      'cam-chatgpt:4:5',
      'Cam:4',
      'cam-chatgpt:4,',
      'cam-chatgpt:4, nick-claude-team:4',
      'cam-chatgpt:4,cam-chatgpt:2',
    ]) {
      expect(LoopLimitPerModelSignIn.parse(raw), isNull, reason: raw);
    }
  });
}
