import "dart:convert";

import "package:campus_dual_android/scripts/auth_strategy.dart";
import "package:campus_dual_android/scripts/campus_dual_manager.models.dart";
import "package:flutter/material.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:flutter_secure_storage/flutter_secure_storage.dart";
import "package:webview_flutter/webview_flutter.dart";

enum Type { int, double, string, bool, stringList }

class StorageManager {
  dynamic _getData(SharedPreferences source, String key, {Type? type}) {
    if (type != null) {
      switch (type) {
        case Type.int:
          return source.getInt(key);
        case Type.double:
          return source.getDouble(key);
        case Type.string:
          return source.getString(key);
        case Type.bool:
          return source.getBool(key);
        case Type.stringList:
          return source.getStringList(key);
      }
    }

    if (source.containsKey(key)) {
      return source.get(key);
    }
  }

  Future<void> _saveData(
      SharedPreferences source, String key, dynamic value) async {
    if (value is int) {
      await source.setInt(key, value);
    }
    if (value is double) {
      await source.setDouble(key, value);
    }
    if (value is String) {
      await source.setString(key, value);
    }
    if (value is bool) {
      await source.setBool(key, value);
    }
    if (value is List<String>) {
      await source.setStringList(key, value);
    }
  }

  // On first launch after reinstall, clear leftover secure storage entries.
  // TODO: pin android:allowBackup=false on the manifest.
  Future<void> fixFirstLaunchIssues() async {
    final disk = await SharedPreferences.getInstance();
    if (_getData(disk, "first_run", type: Type.bool) ?? true) {
      const secureDisk = FlutterSecureStorage();
      await secureDisk.deleteAll();
      _saveData(disk, "first_run", false);
    }
  }

  Future<void> clearAll() async {
    final theme = await loadTheme();
    final evaluationRules = await loadObjectList("evaluationRules");
    final useFuzzyColors = await loadBool("useFuzzyColor");

    final disk = await SharedPreferences.getInstance();
    disk.clear();
    try {
      const secureDisk = FlutterSecureStorage();
      await secureDisk.deleteAll();
    } catch (e) {
      // macOS dev runs without keychain entitlements can't delete entries.
    }

    saveTheme(theme);
    if (evaluationRules != null) {
      saveObjectList("evaluationRules", evaluationRules);
    }
    if (useFuzzyColors != null) {
      saveBool("useFuzzyColor", useFuzzyColors);
    }
  }

  /// Wipe the in-app WebView's on-disk cookie jar.
  /// SharedPreferences alone is not enough; the WebView has its own store.
  Future<bool> clearWebViewCookies() async {
    debugPrint("[cda] StorageManager.clearWebViewCookies: starting");
    try {
      final had = await WebViewCookieManager().clearCookies();
      debugPrint(
          "[cda] StorageManager.clearWebViewCookies: completed had=$had");
      return had;
    } catch (e) {
      debugPrint("[cda] StorageManager.clearWebViewCookies: threw $e");
      return false;
    }
  }

  /// Persist captured fep.campus-dual.de session cookies for replay.
  /// Cookies exceed the 4 KB per-value limit of secure storage on Android.
  Future<void> saveApiCookies(List<Map<String, String>> cookies) async {
    final disk = await SharedPreferences.getInstance();
    await _saveData(disk, "apiCookies", jsonEncode(cookies));
  }

  Future<List<Map<String, String>>?> loadApiCookies() async {
    final disk = await SharedPreferences.getInstance();
    final raw = _getData(disk, "apiCookies", type: Type.string);
    if (raw == null) return null;
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded
        .map((e) => (e as Map<String, dynamic>).map(
              (k, v) => MapEntry(k, v.toString()),
            ))
        .toList();
  }

  Future<void> clearApiCookies() async {
    final disk = await SharedPreferences.getInstance();
    await disk.remove("apiCookies");
  }

  /// Persist the user's seminar group (e.g. "3IT24-1"). The Stundenplan
  /// scraper uses it as the `AktWert` query parameter on
  /// stundenplan.ba-dresden.de.
  Future<void> saveSeminarGroup(String value) async {
    final disk = await SharedPreferences.getInstance();
    await _saveData(disk, "seminarGroup", value);
  }

  Future<String?> loadSeminarGroup() async {
    final disk = await SharedPreferences.getInstance();
    return _getData(disk, "seminarGroup", type: Type.string);
  }

  Future<UserCredentials?> loadUserAuthData() async {
    const secureDisk = FlutterSecureStorage();
    final String username = await secureDisk.read(key: "username") ?? "";
    final String password = await secureDisk.read(key: "password") ?? "";
    final String hash = await secureDisk.read(key: "hash") ?? "";
    final bool isDummy =
        bool.tryParse(await secureDisk.read(key: "isDummy") ?? "") ?? false;

    if (username == "" || hash == "" || password == "") {
      return null;
    }
    UserCredentials creds = UserCredentials(username, password, hash, isDummy);
    return creds;
  }

  Future<void> saveUserAuthData(UserCredentials data) async {
    // macOS dev runs throw errSecMissingEntitlement (-34018) on writes;
    // OPAL on macOS relies on the WebView jar so this is best-effort.
    try {
      const secureDisk = FlutterSecureStorage();
      await secureDisk.write(key: "username", value: data.username);
      await secureDisk.write(key: "password", value: data.password);
      await secureDisk.write(key: "hash", value: data.hash);
      await secureDisk.write(key: "isDummy", value: data.isDummy.toString());
    } catch (e) {
      debugPrint(
          "[cda] StorageManager.saveUserAuthData: secure disk unavailable: $e");
    }
  }

  Future<ThemeMode> loadTheme() async {
    final disk = await SharedPreferences.getInstance();
    final isDarkMode = _getData(disk, "isDarkMode");
    if (isDarkMode == null) {
      return ThemeMode.system;
    }
    return isDarkMode ? ThemeMode.dark : ThemeMode.light;
  }

  Future<void> saveTheme(ThemeMode theme) async {
    final disk = await SharedPreferences.getInstance();
    _saveData(disk, "isDarkMode", theme == ThemeMode.dark);
  }

  Future<DateTime?> loadDateTime(String key) async {
    final disk = await SharedPreferences.getInstance();
    final dateTime = _getData(disk, key, type: Type.string);
    if (dateTime == null) {
      return null;
    }
    return DateTime.parse(dateTime);
  }

  Future<void> saveDateTime(String key, DateTime value) async {
    final disk = await SharedPreferences.getInstance();
    _saveData(disk, key, value.toIso8601String());
  }

  Future<Map<String, dynamic>?> loadObject(String key) async {
    final disk = await SharedPreferences.getInstance();
    final jsonData = _getData(disk, key, type: Type.string);
    if (jsonData == null) {
      return null;
    }
    return jsonDecode(jsonData);
  }

  Future<void> saveObject(String key, Object data) async {
    final disk = await SharedPreferences.getInstance();
    _saveData(disk, key, jsonEncode(data));
  }

  Future<List<Map<String, dynamic>>?> loadObjectList(String key) async {
    final disk = await SharedPreferences.getInstance();
    final jsonData =
        _getData(disk, key, type: Type.stringList) as List<String>?;
    if (jsonData == null) {
      return null;
    }
    return jsonData.map((e) => jsonDecode(e) as Map<String, dynamic>).toList();
  }

  Future<void> saveObjectList(String key, List<Object> data) async {
    final disk = await SharedPreferences.getInstance();
    _saveData(disk, key, data.map((e) => jsonEncode(e)).toList());
  }

  Future<int?> loadInt(String key) async {
    final disk = await SharedPreferences.getInstance();
    return _getData(disk, key, type: Type.int);
  }

  Future<void> saveInt(String key, int value) async {
    final disk = await SharedPreferences.getInstance();
    _saveData(disk, key, value);
  }

  Future<bool?> loadBool(String key) async {
    final disk = await SharedPreferences.getInstance();
    return _getData(disk, key, type: Type.bool);
  }

  Future<void> saveBool(String key, bool value) async {
    final disk = await SharedPreferences.getInstance();
    _saveData(disk, key, value);
  }

  Future<AuthBackend> loadAuthBackend() async {
    final raw = await loadAuthBackendRaw();
    return AuthBackend.values.firstWhere(
      (e) => e.name == raw,
      orElse: () => AuthBackend.sap,
    );
  }

  /// Returns the raw saved value or null if nothing has ever been persisted.
  /// Lets callers distinguish "first launch" from "saved as some backend".
  Future<String?> loadAuthBackendRaw() async {
    final disk = await SharedPreferences.getInstance();
    return _getData(disk, "authBackend", type: Type.string);
  }

  Future<void> saveAuthBackend(AuthBackend value) async {
    final disk = await SharedPreferences.getInstance();
    _saveData(disk, "authBackend", value.name);
  }
}
