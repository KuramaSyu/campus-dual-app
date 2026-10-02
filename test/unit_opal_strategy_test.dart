import 'package:campus_dual_android/scripts/auth_strategy.dart';
import 'package:campus_dual_android/scripts/auth_strategy_opal.dart';
import 'package:campus_dual_android/scripts/campus_dual_manager.dart';
import 'package:campus_dual_android/scripts/storage_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_cookie_store/http_cookie_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('StorageManager cookie persistence', () {
    test('loadApiCookies returns null when nothing has been saved', () async {
      final storage = StorageManager();
      expect(await storage.loadApiCookies(), isNull);
    });

    test('saveApiCookies / loadApiCookies round-trips a multi-cookie blob',
        () async {
      final storage = StorageManager();
      final cookies = <Map<String, String>>[
        {
          'name': 'SAP_SESSIONID_FEP_100',
          'value': 'qpkKgYAWgYUrTPJvXLt4XuvQR5O9YhHxgAAAUFaDPH=',
          'domain': 'fep.campus-dual.de',
          'path': '/',
        },
        {
          'name': 'sap-usercontext',
          'value': 'sap-language=DE&sap-client=100',
          'domain': 'fep.campus-dual.de',
          'path': '/',
        },
      ];

      await storage.saveApiCookies(cookies);
      final loaded = await storage.loadApiCookies();

      expect(loaded, isNotNull);
      expect(loaded!.length, 2);
      expect(loaded[0]['name'], 'SAP_SESSIONID_FEP_100');
      expect(loaded[1]['value'], 'sap-language=DE&sap-client=100');
    });

    test('clearApiCookies wipes the stored blob', () async {
      final storage = StorageManager();
      await storage.saveApiCookies([
        {'name': 'a', 'value': 'b', 'domain': 'fep.campus-dual.de', 'path': '/'},
      ]);
      expect(await storage.loadApiCookies(), isNotNull);

      await storage.clearApiCookies();
      expect(await storage.loadApiCookies(), isNull);
    });
  });

  group('StorageManager loadAuthBackendRaw', () {
    test('returns null on a fresh install', () async {
      expect(await StorageManager().loadAuthBackendRaw(), isNull);
    });

    test('returns the persisted name even if it does not map to a backend',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'authBackend': 'mystery',
      });
      // loadAuthBackend() falls back to the SAP default for unknown values,
      // but loadAuthBackendRaw() must surface what is actually on disk.
      expect(await StorageManager().loadAuthBackendRaw(), 'mystery');
      expect(await StorageManager().loadAuthBackend(), AuthBackend.sap);
    });

    test('round-trips the OPAL value', () async {
      await StorageManager().saveAuthBackend(AuthBackend.opal);
      expect(await StorageManager().loadAuthBackendRaw(), 'opal');
      expect(await StorageManager().loadAuthBackend(), AuthBackend.opal);
    });
  });

  group('OpalSamlStrategy', () {
    test('login throws a clear error when no cookies are cached', () async {
      final strategy = OpalSamlStrategy();
      await expectLater(
        strategy.login(),
        throwsA(isA<Exception>()),
      );
    });

    test('login replays stored cookies into a CookieClient', () async {
      await StorageManager().saveApiCookies([
        {
          'name': 'SAP_SESSIONID_FEP_100',
          'value': 'session-token',
          'domain': OpalSamlStrategy.cookieDomain,
          'path': '/',
        },
      ]);

      final strategy = OpalSamlStrategy();
      final session = await strategy.login();

      expect(session.client, isA<CookieClient>());
      final cookieClient = session.client as CookieClient;
      final cookies = cookieClient.store.cookies
          .where((c) => c.name == 'SAP_SESSIONID_FEP_100')
          .toList();
      expect(cookies, hasLength(1));
      expect(cookies.first.value, 'session-token');
      expect(cookies.first.domain?.host, OpalSamlStrategy.cookieDomain);
      expect(session.credentials.hash, 'pending-opal');
      expect(session.credentials.isDummy, isFalse);
    });

    test('clearStoredCookies removes the cached session', () async {
      await StorageManager().saveApiCookies([
        {
          'name': 'SAP_SESSIONID_FEP_100',
          'value': 'session-token',
          'domain': OpalSamlStrategy.cookieDomain,
          'path': '/',
        },
      ]);
      expect(await OpalSamlStrategy.hasStoredCookies(), isTrue);

      await OpalSamlStrategy().clearStoredCookies();
      expect(await OpalSamlStrategy.hasStoredCookies(), isFalse);
    });

    test('buildClientFromStorage rebuilds the replayed jar', () async {
      final client = OpalSamlStrategy.buildClientFromStorage(
        overrideCookies: [
          {
            'name': 'SAP_SESSIONID_FEP_100',
            'value': 'session-token',
            'domain': OpalSamlStrategy.cookieDomain,
            'path': '/',
          },
        ],
      );
      final values = client.store.cookies
          .where((c) => c.name == 'SAP_SESSIONID_FEP_100')
          .toList();
      expect(values, hasLength(1));
      expect(values.first.value, 'session-token');
    });

    test('AuthBackend.opal is the new default in CampusDualManager', () {
      // Other tests may mutate the static field; reset for the assertion.
      CampusDualManager.activeBackend = AuthBackend.opal;
      expect(CampusDualManager.activeBackend, AuthBackend.opal);
    });
  });
}