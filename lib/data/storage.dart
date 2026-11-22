import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences wrapper. Writes are retained in an in-memory overlay until
/// initialization succeeds, and remain readable there if the platform write
/// fails (e.g. during boot or in widget tests).
class StorageService {
  SharedPreferences? _prefs;
  static final Object _removed = Object();
  final Map<String, Object> _pending = {};
  Future<void> _writeQueue = Future<void>.value();

  Future<void> init() async {
    try {
      _prefs = await SharedPreferences.getInstance();
    } catch (error) {
      debugPrint('[storage] 初始化失败：$error');
      return;
    }
    // 初始化前收到的写入一直保存在内存覆盖层中，拿到磁盘后按序补写。
    for (final entry in _pending.entries.toList()) {
      await _queueWrite(entry.key, entry.value);
    }
  }

  bool get ready => _prefs != null;

  String getString(String key, [String fallback = '']) {
    if (_pending.containsKey(key)) {
      final value = _pending[key];
      return value is String ? value : fallback;
    }
    try {
      return _prefs?.getString(key) ?? fallback;
    } catch (error) {
      debugPrint('[storage] getString 失败：$key -> $error');
      return fallback;
    }
  }

  Future<void> setString(String key, String value) async {
    await _queueWrite(key, value);
  }

  bool getBool(String key, [bool fallback = false]) {
    if (_pending.containsKey(key)) {
      final value = _pending[key];
      return value is bool ? value : fallback;
    }
    try {
      return _prefs?.getBool(key) ?? fallback;
    } catch (error) {
      debugPrint('[storage] getBool 失败：$key -> $error');
      return fallback;
    }
  }

  Future<void> setBool(String key, bool value) async {
    await _queueWrite(key, value);
  }

  double getDouble(String key, [double fallback = 0]) {
    if (_pending.containsKey(key)) {
      final value = _pending[key];
      return value is double ? value : fallback;
    }
    try {
      return _prefs?.getDouble(key) ?? fallback;
    } catch (error) {
      debugPrint('[storage] getDouble 失败：$key -> $error');
      return fallback;
    }
  }

  Future<void> setDouble(String key, double value) async {
    await _queueWrite(key, value);
  }

  List<Map<String, dynamic>> getJsonList(String key) {
    final raw = getString(key);
    if (raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        final result = <Map<String, dynamic>>[];
        for (final value in decoded) {
          if (value is! Map) continue;
          try {
            result.add(Map<String, dynamic>.from(value));
          } catch (error) {
            // 单个无效对象不能让同一数组里的其它有效记录一起丢失。
            debugPrint('[storage] $key 跳过损坏条目：$error');
          }
        }
        return result;
      }
      // 能解码但不是数组：视为坏数据，打印警告并降级为空（保持接口不崩溃）。
      debugPrint('[storage] $key 内容不是 JSON 数组，已降级为空');
    } catch (error) {
      // 坏 JSON：返回空不崩溃，但打印警告便于排查，避免静默丢数据无感知。
      debugPrint('[storage] $key 内容损坏（非法 JSON），已降级为空：$error');
    }
    return [];
  }

  Future<void> setJsonList(String key, List<Map<String, dynamic>> value) async {
    try {
      await setString(key, jsonEncode(value));
    } catch (error) {
      // JSON 序列化失败时保留原值，不覆盖现有持久化数据。
      debugPrint('[storage] setJsonList 序列化失败：$key -> $error');
    }
  }

  Future<void> remove(String key) async {
    await _queueWrite(key, _removed);
  }

  Future<void> _queueWrite(String key, Object value) {
    // 先更新覆盖层：即使尚未 init 或平台写盘失败，本进程仍保有最新值。
    _pending[key] = value;
    final write = _writeQueue.then((_) => _flushKey(key, value));
    _writeQueue = write.catchError((Object error) {
      debugPrint('[storage] 写入队列失败：$key -> $error');
    });
    return _writeQueue;
  }

  Future<void> _flushKey(String key, Object requested) async {
    // 队列等待期间若同一 key 有更新值，旧写入跳过，避免旧快照覆盖新状态。
    if (!identical(_pending[key], requested)) return;
    final prefs = _prefs;
    if (prefs == null) {
      debugPrint('[storage] 暂存写入（尚未初始化）：$key');
      return;
    }
    try {
      if (identical(requested, _removed)) {
        if (!await prefs.remove(key)) {
          throw StateError('SharedPreferences.remove 返回 false');
        }
      } else if (requested is String) {
        if (!await prefs.setString(key, requested)) {
          throw StateError('SharedPreferences.setString 返回 false');
        }
      } else if (requested is bool) {
        if (!await prefs.setBool(key, requested)) {
          throw StateError('SharedPreferences.setBool 返回 false');
        }
      } else if (requested is double) {
        if (!await prefs.setDouble(key, requested)) {
          throw StateError('SharedPreferences.setDouble 返回 false');
        }
      }
      if (identical(_pending[key], requested)) _pending.remove(key);
    } catch (error) {
      // 不抛给 UI，且覆盖层继续提供可读的最新值；后续 init 可重试。
      debugPrint('[storage] 写入失败：$key -> $error');
    }
  }
}
