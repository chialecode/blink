import 'dart:async';

import 'package:blink_core/blink_core.dart';
import 'package:flutter/foundation.dart';

/// Live CJK FTS5 search controller backing the `Ctrl+K` search modal (`INV-02`).
class BlinkSearchController extends ChangeNotifier {
  BlinkSearchController({
    required this.vaultProvider,
    this.debounce = const Duration(milliseconds: 120),
  });

  final VaultManager? Function() vaultProvider;
  final Duration debounce;

  String _query = '';
  PrivacyScope _scope = PrivacyScope.localWithPrivate;
  List<FtsSearchHit> _hits = const <FtsSearchHit>[];
  bool _isSearching = false;
  String? _errorMessage;
  bool _isDisposed = false;
  int _searchEpoch = 0;
  Timer? _debounceTimer;

  String get query => _query;
  PrivacyScope get scope => _scope;
  List<FtsSearchHit> get hits => _hits;
  bool get isSearching => _isSearching;
  String? get errorMessage => _errorMessage;

  void setQuery(String nextQuery) {
    _query = nextQuery;
    _debounceTimer?.cancel();
    if (nextQuery.trim().isEmpty) {
      _hits = const <FtsSearchHit>[];
      _isSearching = false;
      _errorMessage = null;
      _safeNotify();
      return;
    }
    _isSearching = true;
    _safeNotify();
    _debounceTimer = Timer(debounce, () {
      unawaited(searchNow(nextQuery));
    });
  }

  void setScope(PrivacyScope nextScope) {
    if (_scope == nextScope) {
      return;
    }
    _scope = nextScope;
    _safeNotify();
    if (_query.trim().isNotEmpty) {
      unawaited(searchNow(_query));
    }
  }

  void clear() {
    _debounceTimer?.cancel();
    _query = '';
    _hits = const <FtsSearchHit>[];
    _isSearching = false;
    _errorMessage = null;
    _safeNotify();
  }

  Future<List<FtsSearchHit>> searchNow(String rawQuery) async {
    _query = rawQuery;
    final trimmed = rawQuery.trim();
    if (trimmed.isEmpty) {
      _hits = const <FtsSearchHit>[];
      _isSearching = false;
      _errorMessage = null;
      _safeNotify();
      return _hits;
    }

    final vault = vaultProvider();
    if (vault == null || !vault.isOpen) {
      _hits = const <FtsSearchHit>[];
      _isSearching = false;
      _errorMessage = '便携库尚未打开，暂时无法检索。';
      _safeNotify();
      return _hits;
    }

    final epoch = ++_searchEpoch;
    _isSearching = true;
    _errorMessage = null;
    _safeNotify();

    try {
      final results = await vault.search.search(
        trimmed,
        scope: _scope,
        limit: 50,
      );
      if (_isDisposed || epoch != _searchEpoch) {
        return _hits;
      }
      _hits = List<FtsSearchHit>.unmodifiable(results);
      _errorMessage = null;
      return _hits;
    } catch (error) {
      if (_isDisposed || epoch != _searchEpoch) {
        return _hits;
      }
      _hits = const <FtsSearchHit>[];
      _errorMessage = '检索失败：$error';
      return _hits;
    } finally {
      if (!_isDisposed && epoch == _searchEpoch) {
        _isSearching = false;
        _safeNotify();
      }
    }
  }

  void _safeNotify() {
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _debounceTimer?.cancel();
    super.dispose();
  }
}
