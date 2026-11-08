import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:dhara/core/services/vision.dart';
import 'package:dhara/dev/treeguard_bench_screen.dart';

/// Regression: the debug launcher once used a Tooltip and Navigator.of() from
/// inside MaterialApp.builder, which sits above the Navigator and its Overlay.
/// Building it threw, and in debug builds Flutter painted a translucent red
/// ErrorWidget over every screen of the app. This mounts it exactly the way
/// main.dart does.
void main() {
  Widget app() {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('normal screen')),
        ),
      ],
    );
    return ProviderScope(
      overrides: [
        visionProvider.overrideWithValue(
          Vision(labelSource: (_) async => const []),
        ),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        builder: (context, child) => TreeGuardDebugLauncher(
          navigatorKey: router.routerDelegate.navigatorKey,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    );
  }

  testWidgets(
    'launcher in MaterialApp.builder builds without an error overlay',
    (t) async {
      await t.pumpWidget(app());
      await t.pumpAndSettle();

      expect(t.takeException(), isNull);
      expect(find.byType(ErrorWidget), findsNothing);
      expect(find.text('normal screen'), findsOneWidget);
      expect(find.byIcon(Icons.science_outlined), findsOneWidget);
    },
  );

  testWidgets(
    'tapping the launcher opens the bench through the app navigator',
    (t) async {
      await t.pumpWidget(app());
      await t.pumpAndSettle();

      await t.tap(find.byIcon(Icons.science_outlined));
      // Not pumpAndSettle(): the bench screen's own first load calls the real
      // path_provider plugin (no platform to answer it under `flutter test`)
      // and shows an indeterminate CircularProgressIndicator while waiting,
      // both of which keep scheduling frames forever and never let
      // pumpAndSettle converge. The route's push animation is enough for the
      // bench's static AppBar title to be on screen.
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));

      expect(t.takeException(), isNull);
      expect(find.byType(ErrorWidget), findsNothing);
      expect(find.text('TreeGuard test bench (debug)'), findsOneWidget);
    },
  );
}
