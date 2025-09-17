import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PreferencesManager {
  static const String _backupFileName = 'shared_prefs_backup.json';
  static SharedPreferences? _prefs;

  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    debugPrint(
      'PreferencesManager initialized with keys: ${_prefs!.getKeys()}',
    );
  }

  static Future<bool> setBool(String key, bool value) async {
    final result = await _prefs!.setBool(key, value);
    await _backupPreferences();
    return result;
  }

  static Future<bool> setString(String key, String value) async {
    final result = await _prefs!.setString(key, value);
    await _backupPreferences();
    return result;
  }

  static bool? getBool(String key) => _prefs!.getBool(key);
  static String? getString(String key) => _prefs!.getString(key);

  static Future<bool> setCookies(Map<String, String> cookies) async {
    if (_prefs == null) {
      await init();
    }
    for (var entry in cookies.entries) {
      await _prefs!.setString('cookie_${entry.key}', entry.value);
    }
    await _backupPreferences();
    return true;
  }

  static Map<String, String> getCookies() {
    if (_prefs == null) {
      debugPrint('Warning: _prefs not initialized in getCookies');
      return {};
    }
    final cookies = <String, String>{};
    final keys = _prefs!.getKeys();
    for (var key in keys) {
      if (key.startsWith('cookie_')) {
        final cookieName = key.substring(7);
        final value = _prefs!.getString(key);
        if (value != null) {
          cookies[cookieName] = value;
        }
      }
    }
    return cookies;
  }

  // New: Check if user is logged in
  static bool isLoggedIn() {
    final cookies = getCookies();
    return cookies.containsKey('xf_user') && cookies.containsKey('xf_session');
  }

  // New: Clear cookies (for logout)
  static Future<void> clearCookies() async {
    final keys = _prefs!.getKeys();
    for (var key in keys) {
      if (key.startsWith('cookie_')) {
        await _prefs!.remove(key);
      }
    }
    await _backupPreferences();
  }

  static Future<void> _backupPreferences() async {
    try {
      final prefsMap = _prefs!.getKeys().fold<Map<String, dynamic>>({}, (
        map,
        key,
      ) {
        map[key] = _prefs!.get(key);
        return map;
      });

      final jsonString = jsonEncode(prefsMap);
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/$_backupFileName');
      await file.writeAsString(jsonString);
      debugPrint('Preferences backed up to ${file.path}');
    } catch (e) {
      debugPrint('Error backing up preferences: $e');
    }
  }
}
