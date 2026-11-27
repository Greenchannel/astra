import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'data/models/models.dart';
import 'state/astra_controller.dart';
import 'ui/home_shell.dart';
import 'ui/theme.dart';

class AstraScope extends InheritedNotifier<AstraController> {
  const AstraScope({
    super.key,
    required AstraController controller,
    required super.child,
  }) : super(notifier: controller);

  static AstraController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AstraScope>();
    assert(scope != null, 'AstraScope was not found above this context.');
    return scope!.notifier!;
  }
}

class AstraBootstrap extends StatefulWidget {
  const AstraBootstrap({super.key, required this.controller});

  final AstraController controller;

  @override
  State<AstraBootstrap> createState() => _AstraBootstrapState();
}

class _AstraBootstrapState extends State<AstraBootstrap> {
  Object? _initError;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      await widget.controller.init();
    } catch (error) {
      if (mounted) setState(() => _initError = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final mode = switch (controller.settings.theme) {
          ThemePreference.light => ThemeMode.light,
          ThemePreference.dark => ThemeMode.dark,
          ThemePreference.system => ThemeMode.system,
        };
        return AstraScope(
          controller: controller,
          child: MaterialApp(
            title: 'Astra',
            debugShowCheckedModeBanner: false,
            theme: buildAstraTheme(Brightness.light),
            darkTheme: buildAstraTheme(Brightness.dark),
            themeMode: mode,
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [
              Locale('zh', 'CN'),
              Locale('en'),
            ],
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: _initError != null
                ? _StartupError(error: _initError!)
                : controller.ready
                    ? const HomeShell()
                    : const _StartupSplash(),
          ),
        );
      },
    );
  }
}

class _StartupSplash extends StatelessWidget {
  const _StartupSplash();

  @override
  Widget build(BuildContext context) {
    final palette = AstraPalette.of(context);
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: palette.accentSoft,
                borderRadius: BorderRadius.circular(18),
              ),
              alignment: Alignment.center,
              child: Text(
                '✦',
                style: TextStyle(fontSize: 26, color: palette.accent),
              ),
            ),
            const SizedBox(height: 18),
            Text('Astra', style: Theme.of(context).textTheme.displaySmall),
            const SizedBox(height: 18),
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                color: palette.accent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StartupError extends StatelessWidget {
  const _StartupError({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    final palette = AstraPalette.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline, size: 38, color: palette.danger),
                const SizedBox(height: 14),
                Text(
                  '启动失败',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                SelectableText(
                  '$error',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: palette.muted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
