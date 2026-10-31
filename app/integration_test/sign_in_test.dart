import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monastack/app/monastack_app.dart';

/// Run by `backend/office-node/tests/sign_in_app.py` against a fresh node.
/// Sets up the company, invites someone, redeems the invitation, signs in
/// with a password, and restores the session from the macOS keychain after
/// the app is rebuilt. Synthetic passwords only.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final setupCode = Platform.environment['MONASTACK_TEST_SETUP_CODE']!;
  const password = 'synthetic password one';
  const invitedPassword = 'synthetic password two';

  testWidgets('company setup, invitation, sign-in and keychain restore', (
    tester,
  ) async {
    Future<void> until(
      bool Function() condition,
      String label, {
      int attempts = 300,
    }) async {
      for (var i = 0; i < attempts && !condition(); i++) {
        tester.binding.scheduleForcedFrame();
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(condition(), isTrue, reason: label);
    }

    bool shown(Finder finder) => finder.evaluate().isNotEmpty;
    void type(String label, String text) =>
        tester
                .widget<TextField>(find.widgetWithText(TextField, label).last)
                .controller!
                .text =
            text;
    // Matches subclasses too (`TextButton.icon` and friends).
    void press<T extends ButtonStyleButton>(String label) => tester
        .widget<T>(
          find
              .ancestor(
                of: find.text(label),
                matching: find.byWidgetPredicate((w) => w is T),
              )
              .last,
        )
        .onPressed!();
    void tooltip(String label) => tester
        .widget<IconButton>(
          find.byWidgetPredicate((w) => w is IconButton && w.tooltip == label),
        )
        .onPressed!();
    Future<void> openTool(String label) async {
      press<TextButton>('Workspace tools');
      await until(() => shown(find.text(label)), 'tool $label listed');
      press<OutlinedButton>(label);
      await tester.pump(const Duration(milliseconds: 300));
    }

    final connected = find.text('Chat · Connected');

    // ------------------------------------------------------------- setup --
    await tester.pumpWidget(const ProviderScope(child: Monastack()));
    await until(
      () => shown(find.text('Set up company')),
      'fresh node offers company setup',
    );
    press<FilledButton>('Set up company');
    await until(() => shown(find.text('Set up your company')), 'setup dialog');
    type('Setup code', setupCode);
    type('Company name', 'Synthetic Co');
    tester
        .widget<DropdownButtonFormField<String>>(
          find.byType(DropdownButtonFormField<String>),
        )
        .onChanged!('an');
    await tester.pump();
    type('Username', 'an.admin');
    type('Password', 'short');
    type('Confirm password', 'short');
    press<FilledButton>('Create company');
    await tester.pump();
    expect(find.text('Use at least 10 characters.'), findsOneWidget);
    type('Password', password);
    type('Confirm password', password);
    press<FilledButton>('Create company');
    await until(() => shown(connected), 'connected as the first admin');
    await until(() => shown(find.text('Synthetic Co')), 'company name shown');
    expect(find.textContaining('· an.admin'), findsOneWidget);
    debugPrint('sign-in app: company set up, signed in as admin');

    // ------------------------------------------------------ invitation --
    await openTool('People & invitations');
    await until(
      () => shown(find.widgetWithText(TextButton, 'Invite')),
      'people listed',
    );
    press<TextButton>('Invite');
    await until(
      () => shown(find.byKey(const Key('issued-code'))),
      'invitation code shown',
    );
    final code = tester
        .widget<SelectableText>(find.byKey(const Key('issued-code')))
        .data!;
    expect(RegExp(r'^[A-Z0-9]{4}(-[A-Z0-9]{4}){3}$').hasMatch(code), isTrue);
    press<FilledButton>('Done');
    await tester.pump(const Duration(milliseconds: 300));
    press<TextButton>('Close');
    await tester.pump(const Duration(milliseconds: 300));

    tooltip('Sign out');
    await until(
      () => shown(find.text('Sign in to Synthetic Co')),
      'signed out to the sign-in form',
    );
    press<TextButton>('I have a code');
    await until(
      () => shown(find.text('Use an invitation or reset code')),
      'invitation dialog',
    );
    type('Code', code);
    type('Username', 'invited');
    type('New password', invitedPassword);
    type('Confirm password', invitedPassword);
    press<FilledButton>('Continue');
    await until(() => shown(connected), 'connected as the invited person');
    expect(find.textContaining('· invited'), findsOneWidget);
    await openTool('Account & devices');
    await until(
      () => shown(find.textContaining('(this device)')),
      'this device listed',
    );
    expect(find.text('People & invitations'), findsNothing);
    press<TextButton>('Close');
    await tester.pump(const Duration(milliseconds: 300));
    debugPrint('sign-in app: invitation redeemed, devices listed');

    // ---------------------------------------------- password sign-in --
    tooltip('Sign out');
    await until(
      () => shown(find.text('Sign in to Synthetic Co')),
      'signed out again',
    );
    type('Username', 'an.admin');
    type('Password', 'wrong password!!');
    press<FilledButton>('Sign in');
    await until(
      () => shown(find.text('Wrong username or password.')),
      'wrong password refused',
    );
    type('Password', password);
    press<FilledButton>('Sign in');
    await until(() => shown(connected), 'signed in with a password');

    // ---------------------------------------- keychain restore on launch --
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const ProviderScope(child: Monastack()));
    await until(() => shown(connected), 'session restored from the keychain');
    expect(find.textContaining('· an.admin'), findsOneWidget);
    debugPrint('sign-in app: session restored from the keychain');

    // Signing out removes the keychain entry: the next launch asks again.
    tooltip('Sign out');
    await until(
      () => shown(find.text('Sign in to Synthetic Co')),
      'signed out before relaunch',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const ProviderScope(child: Monastack()));
    await until(
      () => shown(find.text('Sign in to Synthetic Co')),
      'sign-in form after relaunch',
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(connected, findsNothing, reason: 'no stored session after sign-out');
    debugPrint('sign-in app: sign-out forgot the keychain session');
  });
}
