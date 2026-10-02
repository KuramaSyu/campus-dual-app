import 'dart:async';
import 'dart:io';

import 'package:campus_dual_android/background/widget.dart';
import 'package:campus_dual_android/screens/homepage.dart';
import 'package:campus_dual_android/screens/login.dart';
import 'package:campus_dual_android/screens/login_webview.dart';
import 'package:campus_dual_android/scripts/campus_dual_manager.dart';
import 'package:campus_dual_android/scripts/auth_strategy.dart';
import 'package:campus_dual_android/scripts/event_bus.dart';
import 'package:campus_dual_android/scripts/storage_manager.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:home_widget/home_widget.dart';
import 'theme/themes.dart';
import "package:campus_dual_android/scripts/campus_dual_manager.models.dart";
import 'globals.dart';

// All debug logs are prefixed with [cda] for grep.

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  debugPrint("[cda] main() start");

  // Reinstall fix; secure storage may throw on macOS dev runs.
  try {
    await StorageManager().fixFirstLaunchIssues();
    debugPrint("[cda] main: fixFirstLaunchIssues ok");
  } catch (e) {
    debugPrint("[cda] main: fixFirstLaunchIssues threw: $e");
  }

  // Load the CA cert; missing asset must not block the login screen.
  late ByteData certData;
  try {
    certData =
        await PlatformAssetBundle().load('assets/ca/GEANT TLS RSA 1.crt');
    debugPrint("[cda] main: cert loaded bytes=${certData.lengthInBytes}");
  } catch (e) {
    debugPrint("[cda] main: cert load threw: $e");
    certData = ByteData(0);
  }

  ThemeMode initTheme;
  try {
    initTheme = await StorageManager().loadTheme();
    debugPrint("[cda] main: theme=$initTheme");
  } catch (e) {
    debugPrint("[cda] main: loadTheme threw: $e");
    initTheme = ThemeMode.system;
  }

  // Same rationale as fixFirstLaunchIssues; an uncaught throw escapes
  // and runApp never runs, leaving a black window.
  UserCredentials? creds;
  try {
    creds = await StorageManager().loadUserAuthData();
    debugPrint("[cda] main: creds loaded present=${creds != null}");
  } catch (e) {
    debugPrint("[cda] main: loadUserAuthData threw: $e");
    creds = null;
  }

  if (certData.lengthInBytes > 0) {
    SecurityContext.defaultContext
        .setTrustedCertificatesBytes(certData.buffer.asUint8List());
    debugPrint("[cda] main: trusted cert installed");
  } else {
    debugPrint("[cda] main: SKIPPED trusted cert install (no bytes)");
  }
  CampusDualManager.userCreds = creds;

  // Insecure HTTP toggle; non-essential, swallow errors.
  try {
    bool useUntrustedHTTP =
        await StorageManager().loadBool("useUntrustedHTTP") ?? false;
    CampusDualManager.insecureMode = useUntrustedHTTP;
    debugPrint("[cda] main: insecureMode=$useUntrustedHTTP");
  } catch (e) {
    debugPrint("[cda] main: loadBool(useUntrustedHTTP) threw: $e");
  }

  // Restore the auth backend; new installs default to OPAL.
  try {
    final raw = await StorageManager().loadAuthBackendRaw();
    debugPrint("[cda] main: loadAuthBackendRaw raw=$raw");
    if (raw == null) {
      CampusDualManager.activeBackend = AuthBackend.opal;
      await StorageManager().saveAuthBackend(AuthBackend.opal);
      debugPrint("[cda] main: first launch, defaulting to OPAL and saving");
    } else {
      CampusDualManager.activeBackend =
          await StorageManager().loadAuthBackend();
      debugPrint(
          "[cda] main: restored activeBackend=${CampusDualManager.activeBackend}");
    }
  } catch (e) {
    debugPrint("[cda] main: auth backend load threw: $e");
  }
  debugPrint(
      "[cda] main: AuthBackend active: ${CampusDualManager.activeBackend}");

  tz.initializeTimeZones();

  debugPrint("[cda] main: runApp MyApp initTheme=$initTheme");
  runApp(
    MyApp(initTheme: initTheme),
  );
}

final navigatorKey = GlobalKey<NavigatorState>();

class MyApp extends StatefulWidget {
  const MyApp({super.key, required this.initTheme});

  final ThemeMode initTheme;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  var themes = Themes();
  late ThemeMode themeMode;

  void _onThemeChange(dynamic args) {
    setState(() {
      themeMode =
          themeMode == ThemeMode.light ? ThemeMode.dark : ThemeMode.light;
      StorageManager().saveTheme(themeMode);
    });
  }

  void _onLogout(dynamic args) {
    debugPrint("[cda] _onLogout: entered, userCreds -> null");
    // Drop in-memory creds so in-flight scrapers see the change immediately.
    CampusDualManager.userCreds = null;
    // Wipe SharedPreferences, secure storage, and the WebView cookie jar.
    // WKWebView persists cookies across launches; without this the next
    // launch hands the launchpad the stale session cookie.
    () async {
      debugPrint("[cda] _onLogout: clearAll starting");
      await StorageManager().clearAll();
      debugPrint("[cda] _onLogout: clearAll done");
      debugPrint("[cda] _onLogout: clearWebViewCookies starting");
      final hadCookies = await StorageManager().clearWebViewCookies();
      debugPrint("[cda] _onLogout: clearWebViewCookies done had=$hadCookies");
      // home_widget has no macOS plugin; don't surface that as an error.
      try {
        updateWidget();
        debugPrint("[cda] _onLogout: updateWidget called");
      } catch (e) {
        debugPrint("[cda] _onLogout: updateWidget threw $e (no-op)");
      }
    }();
    // MaterialApp.home doesn't swap on rebuild; force-route the navigator
    // to the right login screen for the active backend.
    // Defer so the lock is gone (Logout fires from a button onPressed,
    // mid-frame; pushAndRemoveUntil asserts _debugLocked is false).
    final next = CampusDualManager.activeBackend == AuthBackend.opal
        ? const LoginWebView()
        : const Login();
    debugPrint(
        "[cda] _onLogout: scheduling pushAndRemoveUntil target=${next.runtimeType}");
    scheduleMicrotask(() {
      debugPrint(
          "[cda] _onLogout: microtask running, navKey.currentState=${navigatorKey.currentState}");
      navigatorKey.currentState?.pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => next),
        (_) => false,
      );
      debugPrint("[cda] _onLogout: microtask pushAndRemoveUntil returned");
    });
  }

  void _onLogin(dynamic args) {
    debugPrint("[cda] _onLogin: entered args=${args.runtimeType}");
    if (args is UserCredentials) {
      StorageManager().saveUserAuthData(args);
      setState(() {
        CampusDualManager.userCreds = args;
        debugPrint("[cda] _onLogin: setState userCreds set");
      });
    } else {
      debugPrint("[cda] _onLogin: invalid arg type, throwing");
      throw Exception("Invalid argument type");
    }
  }

  @override
  void initState() {
    super.initState();

    HomeWidget.registerInteractivityCallback(backgroundCallback);
    listenWidgetLaunchStream(
        HomeWidget.widgetClicked, HomeWidget.initiallyLaunchedFromHomeWidget());

    themeMode = widget.initTheme;
    mainBus.onBus(event: "ToggleTheme", onEvent: _onThemeChange);
    mainBus.onBus(event: "Logout", onEvent: _onLogout);
    mainBus.onBus(event: "Login", onEvent: _onLogin);
  }

  @override
  void dispose() {
    mainBus.offBus(event: "ToggleTheme", callBack: _onThemeChange);
    mainBus.offBus(event: "Logout", callBack: _onLogout);
    mainBus.offBus(event: "Login", callBack: _onLogin);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    final home = CampusDualManager.userCreds != null
        ? const HomePage()
        : CampusDualManager.activeBackend == AuthBackend.opal
            ? const LoginWebView()
            : const Login();
    debugPrint(
        "[cda] MyApp.build: home=${home.runtimeType} creds=${CampusDualManager.userCreds != null} backend=${CampusDualManager.activeBackend}");
    return MaterialApp(
      title: 'Campus Dual',
      scaffoldMessengerKey: snackbarKey,
      themeMode: themeMode, //can also be ThemeMode.light or ThemeMode.dark
      theme: themes.cleanLight,
      darkTheme: themes.cleanDark,
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      home: home,
    );
  }
}
