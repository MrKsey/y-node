import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'core/theme.dart';
import 'l10n/strings.dart';
import 'state/app_state.dart';
import 'ui/onboarding_screen.dart';
import 'ui/root_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState();
  await state.init();
  runApp(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const YNodeApp(),
    ),
  );
}

class YNodeApp extends StatelessWidget {
  const YNodeApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Only the two values that actually shape the app are watched: a rebuild of
    // MaterialApp tears down the whole theme and navigator, and the live tunnel
    // numbers change every second while traffic flows.
    final themeMode = context.select<AppState, ThemeMode>((s) => s.themeMode);
    final onboarded = context.select<AppState, bool>((s) => s.onboarded);
    return MaterialApp(
      title: 'Y-Node',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      locale: const Locale('en'),
      supportedLocales: const [Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: onboarded ? const RootShell() : const OnboardingScreen(),
    );
  }
}

/// Rebuilds when anything in [AppState] changes, and hands the current
/// translation table to [builder].
class Localised extends StatelessWidget {
  const Localised({super.key, required this.builder});

  final Widget Function(BuildContext context, L10n l10n) builder;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return builder(context, state.l10n);
  }
}
