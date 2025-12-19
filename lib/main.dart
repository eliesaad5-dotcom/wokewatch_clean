import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart' as gads;
import 'package:app_tracking_transparency/app_tracking_transparency.dart'
    as att;
import 'package:in_app_purchase/in_app_purchase.dart' as iap;
import 'package:package_info_plus/package_info_plus.dart';

const String kTmdbApiKey = '043ba3f5be27c72f26817fdfa9536d35';

bool _isAppleProvider(String name) {
  final lower = name.toLowerCase();
  return lower.contains('apple tv');
}

String _normalizeProviderName(String name) {
  final lower = name.toLowerCase();
  if (lower.contains('netflix')) return 'Netflix';
  if (lower.contains('amazon prime')) return 'Amazon Prime Video';
  if (lower == 'prime video') return 'Amazon Prime Video';
  if (lower.contains('hbo max') || lower == 'max') return 'Max';
  if (lower.contains('disney+')) return 'Disney+';
  if (lower.contains('disney plus')) return 'Disney+';
  if (lower.contains('hulu')) return 'Hulu';
  if (lower.contains('paramount+')) return 'Paramount+';
  if (lower.contains('paramount plus')) return 'Paramount+';
  if (lower.contains('peacock')) return 'Peacock';
  if (lower.contains('amc+') || lower.contains('amc plus')) return 'AMC+';
  if (lower.contains('apple tv')) return 'Apple TV+';
  return name;
}

Widget _appleProviderAvatar({double iconSize = 14}) {
  return CircleAvatar(
    backgroundColor: Colors.black,
    child: Icon(
      Icons.apple,
      color: Colors.white,
      size: iconSize,
    ),
  );
}

Widget _appleProviderIcon({double size = 18, Color color = Colors.white}) {
  return Icon(Icons.apple, color: color, size: size);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: 'https://nlgrfrbzhtmypckmxbcf.supabase.co',
    anonKey:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5sZ3JmcmJ6aHRteXBja214YmNmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjA1NTQyMDcsImV4cCI6MjA3NjEzMDIwN30.Jd2tG_uXALNQgjds6N8jahN1p79s36_thIvaI_GhxUU',
  );

  // Privacy: Request tracking (iOS) and consent (UMP), then initialize ads
  // Privacy: Request tracking (iOS) and consent (UMP), then initialize ads
  if (_AdsSupport.isSupportedPlatform) {
    try {
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        await Future.delayed(const Duration(milliseconds: 250));
        try {
          await att.AppTrackingTransparency.requestTrackingAuthorization();
        } catch (_) {}
      }
      await _ConsentManager.requestConsent();
      try {
        final prefs = await SharedPreferences.getInstance();
        final testIds = prefs.getStringList('ad_test_device_ids') ?? const [];
        await gads.MobileAds.instance.updateRequestConfiguration(
          gads.RequestConfiguration(
            testDeviceIds: testIds,
            // Maximize fill for production by allowing all content ratings
            maxAdContentRating: gads.MaxAdContentRating.ma,
          ),
        );
      } catch (e) {
        debugPrint('Ad request configuration error: $e');
      }
      await gads.MobileAds.instance.initialize();
    } catch (_) {}
  }

  runApp(const WokeWatchApp());
}

final supabase = Supabase.instance.client;

class RatingProvider extends ChangeNotifier {
  Map<String, dynamic> userRatings = {};
  // Watchlist items: {id, kind, title, poster_path?}
  final List<Map<String, dynamic>> watchlist = [];
  bool isSupabaseConnected = false;
  String? userId;
  // Server feature detection: whether table has optional columns (woke_free, recommended)
  bool?
      _serverSupportsSignals; // null unknown, true supported, false unsupported
  // Enriched user info for profile UI
  User? supabaseUser;
  String? email;
  String? displayName;
  String? avatarUrl;
  String? authProvider; // e.g. 'google', 'email', 'anonymous'
  bool adsRemovedEntitlement = false;
  bool devSupporterEntitlement = false;
  // Reactive count of pending offline ratings (outbox)
  int offlinePendingCount = 0;

  void _captureUser() {
    final u = supabase.auth.currentUser;
    supabaseUser = u;
    userId = u?.id;
    isSupabaseConnected = u != null;

    // Provider detection (google/email/anonymous)
    dynamic providerFromAppMeta;
    try {
      providerFromAppMeta = u?.appMetadata["provider"];
    } catch (_) {}
    String? provider =
        providerFromAppMeta is String ? providerFromAppMeta : null;
    if (provider == null) {
      try {
        // identities may include provider names
        if ((u?.identities ?? []).isNotEmpty) {
          final first = u!.identities!.first;
          final prov = (first.toJson())["provider"];
          if (prov is String) provider = prov;
        }
      } catch (_) {}
    }
    authProvider = provider;

    // Common profile fields
    email = u?.email;
    try {
      final meta = u?.userMetadata ?? {};
      displayName = (meta['full_name'] ?? meta['name'])?.toString();
      avatarUrl = (meta['avatar_url'] ?? meta['picture'])?.toString();
    } catch (_) {}
  }

  bool get isGuest => (authProvider == 'anonymous') || !isSupabaseConnected;

  Future<void> initAuth() async {
    try {
      final session = supabase.auth.currentSession;
      _captureUser();
      unawaited(refreshPendingOutboxCount());
      if (session != null) {
        debugPrint(
            'Supabase: session active for user $userId (provider: ${authProvider ?? 'unknown'})');
        // Attempt to flush any queued offline ratings now that we confirm a session.
        unawaited(flushOutbox());
        // Fetch any cloud ratings to repopulate local store after reinstall/login.
        unawaited(fetchCloudRatings());
        unawaited(syncWatchlistFromCloud());
        // Load remote entitlements (remove ads, supporter) and attempt local restore of purchases.
        unawaited(loadEntitlements());
        unawaited(restorePurchases());
      } else {
        debugPrint('Supabase: no active session');
      }
    } catch (e) {
      debugPrint('Supabase auth error: $e');
      isSupabaseConnected = false;
    }
    notifyListeners();
  }

  // Explicit auth flows (triggered from UI)
  Future<void> continueAsGuest() async {
    try {
      final res = await supabase.auth.signInAnonymously();
      userId = res.user?.id ?? supabase.auth.currentUser?.id;
      _captureUser();
      // Attempt to flush any queued ratings now that we have a session
      // Fire-and-forget to avoid blocking UI
      unawaited(flushOutbox());
      notifyListeners();
    } catch (e) {
      debugPrint('Anonymous sign-in failed: $e');
    }
  }

  Future<void> signInWithGoogle() async {
    try {
      // On web, redirect back to the current origin (http://localhost:<port> or your domain)
      // so the Supabase web SDK can recover the session from the URL.
      // On mobile, use the deep link configured for supabase_flutter.
      final redirect =
          kIsWeb ? Uri.base.origin : 'io.supabase.flutter://login-callback/';

      await supabase.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: redirect,
        // Force account chooser/consent so user sees a prompt instead of silent SSO
        queryParams: const {
          'prompt': 'consent select_account',
        },
      );
      // Session will be updated via supabase; refresh flags shortly after.
      await Future.delayed(const Duration(milliseconds: 300));
      await initAuth();
      // Flush any queued ratings after sign-in
      unawaited(flushOutbox());
    } catch (e) {
      debugPrint('Google sign-in failed: $e');
    }
  }

  Future<void> signInWithApple() async {
    try {
      final redirect =
          kIsWeb ? Uri.base.origin : 'io.supabase.flutter://login-callback/';
      await supabase.auth.signInWithOAuth(
        OAuthProvider.apple,
        redirectTo: redirect,
        // Apple typically doesn't need extra query params; scopes controlled in Supabase settings
      );
      await Future.delayed(const Duration(milliseconds: 300));
      await initAuth();
      unawaited(flushOutbox());
    } catch (e) {
      debugPrint('Apple sign-in failed: $e');
    }
  }

  Future<void> signInWithEmailPassword(String email, String password) async {
    try {
      await supabase.auth.signInWithPassword(email: email, password: password);
      await initAuth();
      unawaited(flushOutbox());
    } catch (e) {
      debugPrint('Email sign-in failed: $e');
    }
  }

  Future<void> signUpWithEmailPassword(String email, String password) async {
    try {
      await supabase.auth.signUp(email: email, password: password);
      await initAuth();
      unawaited(flushOutbox());
    } catch (e) {
      debugPrint('Email sign-up failed: $e');
    }
  }

  Future<void> signOut() async {
    await supabase.auth.signOut();
    userId = null;
    isSupabaseConnected = false;
    supabaseUser = null;
    email = null;
    displayName = null;
    avatarUrl = null;
    authProvider = null;
    notifyListeners();
  }

  // -------- Offline outbox for rating sync --------
  static const String _kOutboxKey = 'rating_outbox';
  Timer? _outboxRetryTimer;

  Future<List<Map<String, dynamic>>> _loadOutbox() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kOutboxKey);
      if (raw == null || raw.isEmpty) return [];
      final list = (json.decode(raw) as List)
          .cast<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      return list;
    } catch (_) {
      return [];
    }
  }

  Future<void> refreshPendingOutboxCount() async {
    offlinePendingCount = (await _loadOutbox()).length;
    notifyListeners();
  }

  Future<void> _removeFromOutbox(String movieId) async {
    final items = await _loadOutbox();
    final before = items.length;
    items.removeWhere((e) => (e['movie_id'] ?? '').toString() == movieId);
    if (items.length != before) {
      await _saveOutbox(items);
      await refreshPendingOutboxCount();
    }
  }

  int _normalizeScore(dynamic value, {int fallback = 5}) {
    if (value is num) {
      final int rounded = value.round();
      if (rounded >= 1 && rounded <= 10) {
        return rounded;
      }
    } else if (value is String) {
      final double? parsed = double.tryParse(value);
      if (parsed != null) {
        final int rounded = parsed.round();
        if (rounded >= 1 && rounded <= 10) {
          return rounded;
        }
      }
    }
    return fallback;
  }

  void _normalizeRatingData(Map<String, dynamic> rating) {
    rating['wokeness'] = _normalizeScore(rating['wokeness']);
    rating['quality'] = _normalizeScore(rating['quality']);
    final categories = rating['categories'];
    if (categories is Map) {
      rating['categories'] = Map<String, dynamic>.from(categories);
    } else if (categories is List) {
      final map = <String, bool>{};
      for (final item in categories) {
        final key = item?.toString();
        if (key != null && key.isNotEmpty) {
          map[key] = true;
        }
      }
      rating['categories'] = map;
    } else {
      rating['categories'] = <String, bool>{};
    }
  }

  bool _isMovieIdConflict(Object error) {
    final msg = error.toString().toLowerCase();
    return msg.contains('movie_ratings_movie_id_key');
  }

  Future<void> _saveOutbox(List<Map<String, dynamic>> items) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kOutboxKey, json.encode(items));
    } catch (_) {}
  }

  Future<void> _enqueueOutbox(String movieId, Map<String, dynamic> rating,
      {Duration initialDelay = const Duration(seconds: 8)}) async {
    final items = await _loadOutbox();
    // replace any existing entry for this movieId with the latest version
    items.removeWhere((e) => (e['movie_id'] ?? '') == movieId);
    items.add({
      'movie_id': movieId,
      'rating': rating,
      'attempts': (0),
      'queued_at': DateTime.now().toIso8601String(),
    });
    await _saveOutbox(items);
    await refreshPendingOutboxCount();
    _scheduleOutboxFlush(delay: initialDelay);
  }

  void _scheduleOutboxFlush({Duration delay = const Duration(seconds: 1)}) {
    _outboxRetryTimer?.cancel();
    _outboxRetryTimer = Timer(delay, () async {
      await flushOutbox();
    });
  }

  Future<void> flushOutbox() async {
    try {
      final hasSession = await _ensureSessionForSync();
      if (!hasSession) {
        debugPrint('[sync] flush skipped — no session yet');
        _scheduleOutboxFlush(delay: const Duration(seconds: 10));
        return;
      }
      final items = await _loadOutbox();
      if (items.isEmpty) {
        await refreshPendingOutboxCount();
        return;
      }
      final remaining = <Map<String, dynamic>>[];
      for (final item in items) {
        final movieId = (item['movie_id'] ?? '').toString();
        final rating = Map<String, dynamic>.from(item['rating'] ?? {});
        _normalizeRatingData(rating);
        final attempts = (item['attempts'] as int?) ?? 0;
        final queuedAt = item['queued_at'];
        try {
          Map<String, dynamic> payload = {
            'movie_id': movieId,
            'user_id': supabase.auth.currentUser?.id ?? userId,
            'title': rating['title'],
            'wokeness': rating['wokeness'],
            'quality': rating['quality'],
            'categories': rating['categories'],
            'comments': rating['comments'] ?? '',
            'updated_at': DateTime.now().toIso8601String(),
          };
          if (_serverSupportsSignals != false) {
            payload['woke_free'] = rating['woke_free'];
            payload['recommended'] = rating['recommended'];
          }
          try {
            await supabase
                .from('movie_ratings')
                .upsert(payload, onConflict: 'movie_id,user_id');
          } catch (err) {
            final s = err.toString().toLowerCase();
            if (s.contains('woke_free') || s.contains('recommended')) {
              _serverSupportsSignals = false;
              payload.remove('woke_free');
              payload.remove('recommended');
              try {
                await supabase
                    .from('movie_ratings')
                    .upsert(payload, onConflict: 'movie_id,user_id');
              } catch (signalErr) {
                if (_isMovieIdConflict(signalErr)) {
                  await supabase
                      .from('movie_ratings')
                      .upsert(payload, onConflict: 'movie_id');
                } else {
                  rethrow;
                }
              }
            } else if (_isMovieIdConflict(err)) {
              await supabase
                  .from('movie_ratings')
                  .upsert(payload, onConflict: 'movie_id');
            } else {
              rethrow;
            }
          }
          debugPrint('Outbox sync success for movie_id=$movieId');
          // Mark local rating as cloud-synced
          final local = userRatings[movieId];
          if (local is Map<String, dynamic>) {
            local['cloud_synced'] = true;
            try {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString('rating_$movieId', json.encode(local));
            } catch (_) {}
          }
        } catch (err) {
          debugPrint('Outbox sync error for $movieId: $err');
          // Keep for retry up to some limit
          if (attempts + 1 < 6) {
            remaining.add({
              'movie_id': movieId,
              'rating': rating,
              'attempts': attempts + 1,
              'queued_at': queuedAt ?? DateTime.now().toIso8601String(),
            });
          }
        }
      }
      await _saveOutbox(remaining);
      if (remaining.isNotEmpty) {
        // Exponential backoff up to ~5 min
        final nextDelay = Duration(
            seconds: (8 * (1 << (remaining.first['attempts'] as int)))
                .clamp(8, 300));
        _scheduleOutboxFlush(delay: nextDelay);
      }
      await refreshPendingOutboxCount();
    } catch (e) {
      debugPrint('[sync] flush exception: $e');
      _scheduleOutboxFlush(delay: const Duration(seconds: 12));
    }
  }

  // Expose a simple count of queued offline ratings for UI surfaces
  Future<int> pendingOutboxCount() async {
    final items = await _loadOutbox();
    return items.length;
  }

  Future<void> loadRatings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      userRatings.clear();
      final keys = prefs.getKeys().where((k) => k.startsWith('rating_'));
      for (String key in keys) {
        final movieId = key.replaceFirst('rating_', '');
        final data = prefs.getString(key);
        if (data != null) userRatings[movieId] = json.decode(data);
      }
      // Load watchlist
      final wlRaw = prefs.getString('watchlist_items');
      watchlist.clear();
      if (wlRaw != null && wlRaw.isNotEmpty) {
        try {
          final list = json.decode(wlRaw) as List<dynamic>;
          for (final item in list) {
            if (item is Map) {
              final map = Map<String, dynamic>.from(item);
              final id = map['id']?.toString();
              final kind = map['kind']?.toString();
              final title = map['title']?.toString();
              if (id != null && kind != null && title != null) {
                final poster = map['poster_path']?.toString();
                final entry = {
                  'id': id,
                  'kind': kind,
                  'title': title,
                };
                if (poster != null && poster.isNotEmpty) {
                  entry['poster_path'] = poster;
                }
                watchlist.add(entry);
              }
            }
          }
        } catch (e) {
          debugPrint('Watchlist decode error: $e');
        }
      }
      adsRemovedEntitlement = prefs.getBool('ads_removed') ?? false;
      devSupporterEntitlement = prefs.getBool('dev_supporter') ?? false;
      notifyListeners();
      await refreshPendingOutboxCount();
    } catch (e) {
      debugPrint('Load ratings error: $e');
    }
  }

  Future<void> updateLocalEntitlements({
    bool? removeAds,
    bool? devSupporter,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    bool changed = false;
    if (removeAds != null) {
      await prefs.setBool('ads_removed', removeAds);
      await prefs.setBool('ads_enabled', !removeAds);
      if (adsRemovedEntitlement != removeAds) {
        adsRemovedEntitlement = removeAds;
        changed = true;
      }
    }
    if (devSupporter != null) {
      await prefs.setBool('dev_supporter', devSupporter);
      if (devSupporterEntitlement != devSupporter) {
        devSupporterEntitlement = devSupporter;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  Future<void> _persistWatchlist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('watchlist_items', json.encode(watchlist));
    } catch (e) {
      debugPrint('Persist watchlist error: $e');
    }
  }

  String _watchlistKey(String id, String kind) => '${kind.toLowerCase()}__$id';

  Future<void> _uploadWatchlistEntry(Map<String, dynamic> entry) async {
    if (!isSupabaseConnected || userId == null) return;
    try {
      await supabase.from('watchlist_items').upsert({
        'user_id': userId!,
        'movie_id': entry['id']?.toString(),
        'kind': (entry['kind'] ?? 'movie').toString(),
        'title': entry['title'],
        'poster_path': entry['poster_path'],
        'updated_at': DateTime.now().toIso8601String(),
      }, onConflict: 'user_id,movie_id,kind');
    } catch (e) {
      debugPrint('Watchlist upload error ${entry['id']}: $e');
    }
  }

  Future<void> _deleteWatchlistEntry(String id, String kind) async {
    if (!isSupabaseConnected || userId == null) return;
    try {
      await supabase
          .from('watchlist_items')
          .delete()
          .eq('user_id', userId!)
          .eq('movie_id', id)
          .eq('kind', kind);
    } catch (e) {
      debugPrint('Watchlist delete error $id: $e');
    }
  }

  Future<void> syncWatchlistFromCloud() async {
    if (!isSupabaseConnected || userId == null) return;
    try {
      final rows = await supabase
          .from('watchlist_items')
          .select('movie_id, kind, title, poster_path')
          .eq('user_id', userId!);
      final remoteEntries = <Map<String, dynamic>>[];
      for (final row in rows) {
        final id = (row['movie_id'] ?? '').toString();
        final kind = (row['kind'] ?? 'movie').toString();
        final title = (row['title'] ?? '').toString();
        if (id.isEmpty || title.isEmpty) continue;
        final entry = {
          'id': id,
          'kind': kind,
          'title': title,
        };
        final poster = row['poster_path']?.toString();
        if (poster != null && poster.isNotEmpty) {
          entry['poster_path'] = poster;
        }
        remoteEntries.add(entry);
      }

      var mergedLocalKeys = watchlist
          .map((e) => _watchlistKey(
              e['id']?.toString() ?? '', e['kind']?.toString() ?? 'movie'))
          .toSet();
      bool changed = false;
      for (final entry in remoteEntries) {
        final key =
            _watchlistKey(entry['id'].toString(), entry['kind'].toString());
        if (!mergedLocalKeys.contains(key)) {
          watchlist.add(entry);
          mergedLocalKeys.add(key);
          changed = true;
        }
      }
      if (changed) {
        await _persistWatchlist();
        notifyListeners();
      }

      final remoteKeys = remoteEntries
          .map((e) => _watchlistKey(e['id'].toString(), e['kind'].toString()))
          .toSet();
      for (final entry in watchlist) {
        final key =
            _watchlistKey(entry['id'].toString(), entry['kind'].toString());
        if (!remoteKeys.contains(key)) {
          unawaited(_uploadWatchlistEntry(entry));
        }
      }
      mergedLocalKeys = watchlist
          .map((e) => _watchlistKey(e['id'].toString(), e['kind'].toString()))
          .toSet();
      for (final entry in remoteEntries) {
        final key =
            _watchlistKey(entry['id'].toString(), entry['kind'].toString());
        if (!mergedLocalKeys.contains(key)) {
          unawaited(_deleteWatchlistEntry(
              entry['id'].toString(), entry['kind'].toString()));
        }
      }
    } catch (e) {
      debugPrint('Watchlist cloud sync error: $e');
    }
  }

  bool isInWatchlist(String id, String kind) {
    return watchlist.any((e) => e['id'] == id && e['kind'] == kind);
  }

  Future<void> addToWatchlist(String id, String kind, String title,
      {String? posterPath}) async {
    if (isInWatchlist(id, kind)) return;
    final entry = {'id': id, 'kind': kind, 'title': title};
    if (posterPath != null && posterPath.isNotEmpty) {
      entry['poster_path'] = posterPath;
    }
    watchlist.add(entry);
    await _persistWatchlist();
    notifyListeners();
    unawaited(_uploadWatchlistEntry(entry));
  }

  Future<void> updateWatchlistPoster(
      String id, String kind, String posterPath) async {
    bool updated = false;
    for (final item in watchlist) {
      if ((item['id'] ?? '') == id && (item['kind'] ?? '') == kind) {
        if (item['poster_path'] != posterPath) {
          item['poster_path'] = posterPath;
          updated = true;
        }
        break;
      }
    }
    if (updated) {
      await _persistWatchlist();
      notifyListeners();
      final entry = watchlist.firstWhere(
          (item) => (item['id'] ?? '') == id && (item['kind'] ?? '') == kind,
          orElse: () => {});
      if (entry.isNotEmpty) {
        unawaited(_uploadWatchlistEntry(entry));
      }
    }
  }

  Future<bool> removeFromWatchlist(String id, String kind) async {
    final before = watchlist.length;
    watchlist.removeWhere((e) => e['id'] == id && e['kind'] == kind);
    final changed = watchlist.length != before;
    if (changed) {
      await _persistWatchlist();
      notifyListeners();
      unawaited(_deleteWatchlistEntry(id, kind));
    }
    return changed;
  }

  Future<bool> quickSignal({
    required String movieId,
    required String title,
    bool? wokeFree,
    bool? recommended,
  }) async {
    final existing = userRatings[movieId] is Map<String, dynamic>
        ? Map<String, dynamic>.from(userRatings[movieId])
        : <String, dynamic>{};
    final ratingData = {
      'title': title,
      'wokeness': existing['wokeness'] ?? 5,
      'quality': existing['quality'] ?? 5,
      'categories': existing['categories'] ?? <String, bool>{},
      'comments': existing['comments'] ?? '',
      'woke_free': wokeFree ?? existing['woke_free'] ?? false,
      'recommended': recommended ?? existing['recommended'],
    };
    return await saveRating(movieId, ratingData);
  }

  // Fetch all ratings from cloud for current user and merge into local store.
  // overwriteLocal: if true replaces local entries even if they exist; otherwise keeps newest by updated_at.
  Future<void> fetchCloudRatings({bool overwriteLocal = false}) async {
    if (!isSupabaseConnected || userId == null) return;
    try {
      final rows = await supabase
          .from('movie_ratings')
          .select(
              'movie_id,title,wokeness,quality,categories,comments,woke_free,recommended,updated_at')
          .eq('user_id', userId!);
      final prefs = await SharedPreferences.getInstance();
      for (final r in rows) {
        final mid = r['movie_id']?.toString();
        if (mid == null || mid.isEmpty) continue;
        final existing = userRatings[mid];
        bool accept = overwriteLocal || existing == null;
        if (!accept && existing != null) {
          DateTime? localUpdated =
              DateTime.tryParse(existing['updated_at']?.toString() ?? '');
          DateTime? remoteUpdated =
              DateTime.tryParse(r['updated_at']?.toString() ?? '');
          if (localUpdated == null ||
              (remoteUpdated != null && remoteUpdated.isAfter(localUpdated))) {
            accept = true;
          }
        }
        if (accept) {
          final data = {
            'title': r['title'],
            'wokeness': r['wokeness'],
            'quality': r['quality'],
            'categories': r['categories'],
            'comments': r['comments'],
            'woke_free': r['woke_free'],
            'recommended': r['recommended'],
            'updated_at': r['updated_at'] ?? DateTime.now().toIso8601String(),
          };
          userRatings[mid] = data;
          try {
            await prefs.setString('rating_$mid', json.encode(data));
          } catch (_) {}
        }
      }
      notifyListeners();
      debugPrint('Cloud ratings fetch merged: ${rows.length} rows');
    } catch (e) {
      debugPrint('Fetch cloud ratings error: $e');
    }
  }

  // Ensure we have a valid (non-expired) session before cloud syncing.
  // Returns true if a session exists after this call.
  Future<bool> _ensureSessionForSync({bool forceReauth = false}) async {
    try {
      final now = DateTime.now();
      final session = supabase.auth.currentSession;
      final dynamic rawExpiresAt = session?.expiresAt;
      DateTime? expires;
      if (rawExpiresAt is DateTime) {
        expires = rawExpiresAt;
      } else if (rawExpiresAt is int) {
        // Supabase may provide seconds since epoch; convert conservatively
        final int ms =
            rawExpiresAt > 1000000000000 ? rawExpiresAt : rawExpiresAt * 1000;
        expires = DateTime.fromMillisecondsSinceEpoch(ms);
      }

      final bool expired = expires != null && expires.isBefore(now);

      if (!forceReauth && session != null && !expired) {
        _captureUser();
        return true;
      }

      // Try refresh first if we have a session
      if (!forceReauth && session != null) {
        try {
          await supabase.auth.refreshSession();
          _captureUser();
          if (supabase.auth.currentSession != null) return true;
        } catch (_) {
          // fall through to anon sign-in
        }
      }

      // If no session (or refresh failed), try anonymous sign-in
      try {
        debugPrint('Auth: obtaining session for cloud sync (anonymous)…');
        final res = await supabase.auth.signInAnonymously();
        userId = res.user?.id ?? supabase.auth.currentUser?.id;
        _captureUser();
        return supabase.auth.currentSession != null;
      } catch (e) {
        debugPrint('Auth: anonymous sign-in failed: $e');
        _captureUser();
        return false;
      }
    } catch (e) {
      debugPrint('Auth ensure-session error: $e');
      _captureUser();
      return false;
    }
  }

  Future<bool> saveRating(
      String movieId, Map<String, dynamic> ratingData) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Stamp a local updated_at for merge conflict resolution with cloud copies.
      ratingData['updated_at'] = DateTime.now().toIso8601String();
      ratingData['cloud_synced'] = false;
      _normalizeRatingData(ratingData);
      await prefs.setString('rating_$movieId', json.encode(ratingData));
      userRatings[movieId] = ratingData;
      notifyListeners();

      // Ensure session (refresh or anonymous) before trying to sync
      bool hasSession = await _ensureSessionForSync();
      Future<void> markSynced({bool removeFromQueue = true}) async {
        ratingData['cloud_synced'] = true;
        try {
          await prefs.setString('rating_$movieId', json.encode(ratingData));
        } catch (_) {}
        userRatings[movieId] = ratingData;
        if (removeFromQueue) {
          await _removeFromOutbox(movieId);
        } else {
          await refreshPendingOutboxCount();
        }
        notifyListeners();
      }

      Map<String, dynamic> buildPayload() {
        final map = <String, dynamic>{
          'movie_id': movieId,
          'user_id': supabase.auth.currentUser?.id ?? userId,
          'title': ratingData['title'],
          'wokeness': ratingData['wokeness'],
          'quality': ratingData['quality'],
          'categories': ratingData['categories'],
          'comments': ratingData['comments'] ?? '',
          'updated_at':
              ratingData['updated_at'] ?? DateTime.now().toIso8601String(),
        };
        if (_serverSupportsSignals != false) {
          // include new fields only if server supports or unknown (we'll detect on error)
          map['woke_free'] = ratingData['woke_free'];
          map['recommended'] = ratingData['recommended'];
        }
        return map;
      }

      Future<bool> tryUpsert({int attempt = 1}) async {
        final payload = buildPayload();
        await supabase
            .from('movie_ratings')
            .upsert(payload, onConflict: 'movie_id,user_id');
        _captureUser();
        debugPrint(
            '[sync] success movie_id=$movieId attempt=$attempt user_id=${supabase.auth.currentUser?.id ?? userId}');
        await markSynced();
        return true;
      }

      if (hasSession) {
        try {
          return await tryUpsert();
        } catch (e) {
          final s = e.toString().toLowerCase();
          final authIssue = s.contains('jwt') ||
              s.contains('auth') ||
              s.contains('unauthorized') ||
              s.contains('permission');
          final missingSignals =
              s.contains('woke_free') || s.contains('recommended');
          final movieConflict = _isMovieIdConflict(e);
          debugPrint('[sync] error first attempt movie_id=$movieId: $e');
          if (missingSignals) {
            // Server likely missing columns; disable and retry without them once
            _serverSupportsSignals = false;
            try {
              await supabase
                  .from('movie_ratings')
                  .upsert(buildPayload(), onConflict: 'movie_id,user_id');
              _captureUser();
              debugPrint('[sync] success without signals movie_id=$movieId');
              await markSynced();
              return true;
            } catch (e3) {
              debugPrint(
                  '[sync] retry without signals failed movie_id=$movieId: $e3');
            }
          }
          if (movieConflict) {
            try {
              await supabase
                  .from('movie_ratings')
                  .upsert(buildPayload(), onConflict: 'movie_id');
              _captureUser();
              debugPrint(
                  '[sync] success using movie_id key movie_id=$movieId (conflict fallback)');
              await markSynced();
              return true;
            } catch (conflictErr) {
              debugPrint(
                  '[sync] fallback movie_id upsert failed movie_id=$movieId: $conflictErr');
            }
          }
          if (authIssue) {
            // Force re-auth (fresh anon) then retry once
            final reauthed = await _ensureSessionForSync(forceReauth: true);
            if (reauthed) {
              try {
                return await tryUpsert(attempt: 2);
              } catch (e2) {
                debugPrint(
                    '[sync] error second attempt movie_id=$movieId: $e2');
              }
            }
          }
        }
      }
      // At this point cloud sync failed or no session. Enqueue for outbox retry.
      debugPrint(
          '[sync] enqueue outbox movie_id=$movieId user_id=${supabase.auth.currentUser?.id ?? userId}');
      try {
        // Use shorter initial delay for more responsive syncing (flashcards etc.)
        await _enqueueOutbox(movieId, ratingData,
            initialDelay: const Duration(seconds: 2));
        unawaited(flushOutbox());
        // Fire off an immediate lightweight retry after short delay (non-blocking)
        Future.delayed(const Duration(seconds: 3), () async {
          try {
            final sessionOk = await _ensureSessionForSync();
            if (!sessionOk) return;
            final payload = buildPayload();
            try {
              await supabase
                  .from('movie_ratings')
                  .upsert(payload, onConflict: 'movie_id,user_id');
            } catch (laterErr) {
              if (_isMovieIdConflict(laterErr)) {
                await supabase
                    .from('movie_ratings')
                    .upsert(payload, onConflict: 'movie_id');
              } else {
                rethrow;
              }
            }
            debugPrint(
                '[sync] late success movie_id=$movieId removing from outbox');
            final items = await _loadOutbox();
            items.removeWhere((e) => (e['movie_id'] ?? '') == movieId);
            await _saveOutbox(items);
            await markSynced(removeFromQueue: false);
          } catch (lateErr) {
            debugPrint('[sync] late retry failed movie_id=$movieId: $lateErr');
          }
        });
      } catch (e) {
        debugPrint('Outbox enqueue failed (non-fatal): $e');
      }
      return false; // local only (will flush later)
    } catch (e) {
      debugPrint('Save error: $e');
      return false;
    }
  }

  Future<Map<String, dynamic>> getCommunityStats(String movieId) async {
    try {
      final response = await supabase
          .from('movie_ratings')
          .select('wokeness, quality, woke_free, recommended')
          .eq('movie_id', movieId);

      if (response.isEmpty) {
        return {'avg_wokeness': 0.0, 'avg_quality': 0.0, 'count': 0};
      }

      final wokenessList = response
          .map((r) => r['wokeness'] as int?)
          .where((w) => w != null)
          .map((w) => w!)
          .toList();
      final qualityList = response
          .map((r) => r['quality'] as int?)
          .where((q) => q != null)
          .map((q) => q!)
          .toList();

      int wokeFreeCount = 0;
      int recommendedCount = 0;
      for (final r in response) {
        final wf = r['woke_free'];
        if (wf == true || wf == 1) wokeFreeCount++;
        final rec = r['recommended'];
        if (rec == true || rec == 1) recommendedCount++;
      }

      final avgWoke = wokenessList.isNotEmpty
          ? wokenessList.reduce((a, b) => a + b) / wokenessList.length
          : 0.0;
      final avgQuality = qualityList.isNotEmpty
          ? qualityList.reduce((a, b) => a + b) / qualityList.length
          : 0.0;

      return {
        'avg_wokeness': avgWoke,
        'avg_quality': avgQuality,
        'count': response.length,
        'percent_woke_free': response.isNotEmpty
            ? (wokeFreeCount * 100.0 / response.length)
            : 0.0,
        'percent_recommended': response.isNotEmpty
            ? (recommendedCount * 100.0 / response.length)
            : 0.0,
      };
    } catch (e) {
      debugPrint('Community stats error: $e');
      return {'avg_wokeness': 0.0, 'avg_quality': 0.0, 'count': 0};
    }
  }

  // Sync ad entitlement (remove_ads) to Supabase (best-effort)
  Future<void> syncAdEntitlement(
      {required bool removeAds, bool devSupporter = false}) async {
    if (!isSupabaseConnected || userId == null) return;
    try {
      await supabase.from('user_entitlements').upsert({
        'user_id': userId,
        'remove_ads': removeAds,
        'dev_supporter': devSupporter,
        'updated_at': DateTime.now().toIso8601String(),
      }, onConflict: 'user_id');
    } catch (e) {
      debugPrint('Entitlement sync error (non-fatal): $e');
    }
  }

  // Load entitlements for current user from Supabase (if any) and persist locally.
  Future<void> loadEntitlements() async {
    if (!isSupabaseConnected || userId == null) return;
    try {
      final data = await supabase
          .from('user_entitlements')
          .select()
          .eq('user_id', userId!)
          .limit(1);
      if (data.isNotEmpty) {
        final row = data.first;
        final removeAds = row['remove_ads'] == true || row['remove_ads'] == 1;
        final supporter =
            row['dev_supporter'] == true || row['dev_supporter'] == 1;
        await updateLocalEntitlements(
          removeAds: removeAds,
          devSupporter: supporter,
        );
        debugPrint(
            'Loaded entitlements: removeAds=$removeAds supporter=$supporter');
      }
    } catch (e) {
      debugPrint('Entitlement load error: $e');
    }
  }

  // Trigger platform restore flow (especially iOS) to emit purchase updates to the stream.
  Future<void> restorePurchases() async {
    try {
      await iap.InAppPurchase.instance.restorePurchases();
      debugPrint('Restore purchases requested');
    } catch (e) {
      debugPrint('Restore purchases error: $e');
    }
  }
}

class WokeWatchApp extends StatelessWidget {
  const WokeWatchApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => RatingProvider()
        ..initAuth()
        ..loadRatings(),
      child: MaterialApp(
        title: 'WokeWatch',
        theme: ThemeData.dark().copyWith(
          primaryColor: Colors.red,
          scaffoldBackgroundColor: const Color(0xFF0F0F0F),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xFF0F0F0F),
            foregroundColor: Colors.white,
            elevation: 0,
          ),
          bottomNavigationBarTheme: const BottomNavigationBarThemeData(
            backgroundColor: Color(0xFF1A1A1A),
            selectedItemColor: Colors.red,
            unselectedItemColor: Colors.grey,
          ),
          textTheme: ThemeData.dark().textTheme.apply(
                bodyColor: Colors.white,
                displayColor: Colors.white,
              ),
          cardTheme: CardThemeData(
            color: const Color(0xFF1A1A1A),
            elevation: 4,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        home: const AuthGate(child: MainScreen()),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}

// Auth gate that shows AuthScreen when there's no active session
class AuthGate extends StatefulWidget {
  final Widget child;
  const AuthGate({super.key, required this.child});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late StreamSubscription<AuthState> _sub;
  Session? _session;

  @override
  void initState() {
    super.initState();
    _session = supabase.auth.currentSession;
    _sub = supabase.auth.onAuthStateChange.listen((event) {
      if (!mounted) return;
      setState(() {
        _session = event.session;
      });
      // Also update provider flags
      final provider = context.read<RatingProvider>();
      provider.initAuth();
    });
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_session == null) {
      return const AuthScreen();
    }
    return widget.child;
  }
}

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isBusy = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.read<RatingProvider>();
    return Scaffold(
      appBar: AppBar(title: const Text('Welcome to WokeWatch')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Sign in to sync your ratings across devices',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 24),
                if (defaultTargetPlatform == TargetPlatform.iOS)
                  ElevatedButton.icon(
                    onPressed: _isBusy
                        ? null
                        : () async {
                            setState(() => _isBusy = true);
                            await provider.signInWithApple();
                            if (!mounted) return;
                            setState(() => _isBusy = false);
                          },
                    icon: const Icon(Icons.login),
                    label: const Text('Continue with Apple'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.black,
                      foregroundColor: Colors.white,
                    ),
                  ),
                if (defaultTargetPlatform == TargetPlatform.iOS)
                  const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: _isBusy
                      ? null
                      : () async {
                          setState(() => _isBusy = true);
                          await provider.signInWithGoogle();
                          if (!mounted) return;
                          setState(() => _isBusy = false);
                        },
                  icon: const Icon(Icons.login),
                  label: const Text('Continue with Google'),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _emailController,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _isBusy
                            ? null
                            : () async {
                                setState(() => _isBusy = true);
                                await provider.signInWithEmailPassword(
                                  _emailController.text.trim(),
                                  _passwordController.text,
                                );
                                if (!mounted) return;
                                setState(() => _isBusy = false);
                              },
                        child: const Text('Sign in'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _isBusy
                            ? null
                            : () async {
                                setState(() => _isBusy = true);
                                await provider.signUpWithEmailPassword(
                                  _emailController.text.trim(),
                                  _passwordController.text,
                                );
                                if (!mounted) return;
                                setState(() => _isBusy = false);
                              },
                        child: const Text('Create account'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _isBusy
                      ? null
                      : () async {
                          setState(() => _isBusy = true);
                          await provider.continueAsGuest();
                          if (!mounted) return;
                          setState(() => _isBusy = false);
                        },
                  child: const Text('Continue as guest'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class RatingsScreen extends StatefulWidget {
  const RatingsScreen({super.key});

  @override
  State<RatingsScreen> createState() => _RatingsScreenState();
}

class _RatingsScreenState extends State<RatingsScreen> {
  // Simple in-memory cache to avoid refetching TMDB titles repeatedly
  final Map<String, String> _titleCache = {};
  final String _apiKey = '043ba3f5be27c72f26817fdfa9536d35';

  Future<String> _resolveTitleById(String movieId) async {
    // Cache hit
    if (_titleCache.containsKey(movieId)) return _titleCache[movieId]!;
    // Try Movie/TV fetch by kind
    Future<String?> tryFetch(String kind) async {
      try {
        final uri = Uri.parse(
            'https://api.themoviedb.org/3/$kind/$movieId?api_key=$_apiKey&language=en-US');
        final resp = await http.get(uri);
        if (resp.statusCode == 200) {
          final map = json.decode(resp.body) as Map<String, dynamic>;
          final t = (map['title'] ?? map['name'])?.toString();
          if (t != null && t.trim().isNotEmpty) return t.trim();
        }
      } catch (_) {}
      return null;
    }

    final movieTitle = await tryFetch('movie');
    final title = movieTitle ?? (await tryFetch('tv')) ?? 'Unknown';
    _titleCache[movieId] = title;
    return title;
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<RatingProvider>(
      builder: (context, provider, child) {
        // Convert any legacy/invalid entries safely and sort by updated_at desc
        final List<_LocalRating> ratings = provider.userRatings.entries
            .map((e) => _LocalRating.from(e.key, e.value))
            .where((r) => r != null)
            .cast<_LocalRating>()
            .toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

        return Scaffold(
          appBar: AppBar(title: const Text('Your Ratings')),
          body: RefreshIndicator(
            onRefresh: () async {
              await context.read<RatingProvider>().fetchCloudRatings();
            },
            child: ratings.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: const [
                      SizedBox(height: 160),
                      Center(child: Text('No ratings yet. Rate some movies!')),
                    ],
                  )
                : ListView.separated(
                    itemCount: ratings.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemBuilder: (context, index) {
                      final r = ratings[index];
                      final subtitle =
                          '${r.wokeness}/10 Woke | ${r.quality}/10 Quality';
                      final hasTitle =
                          r.title.trim().isNotEmpty && r.title != 'Unknown';
                      return Card(
                        margin: const EdgeInsets.symmetric(horizontal: 16),
                        child: ListTile(
                          leading: const Icon(Icons.star, color: Colors.amber),
                          title: hasTitle
                              ? Text(r.title)
                              : FutureBuilder<String>(
                                  future: _resolveTitleById(r.movieId),
                                  builder: (context, snapshot) {
                                    final t = snapshot.data;
                                    return Text((t == null || t.isEmpty)
                                        ? 'Unknown'
                                        : t);
                                  },
                                ),
                          subtitle: Text(subtitle),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (r.wokeFree)
                                const Tooltip(
                                  message: 'Marked woke-free',
                                  child: Icon(Icons.verified_outlined,
                                      color: Colors.green),
                                ),
                              if (r.recommended != null) ...[
                                const SizedBox(width: 8),
                                Icon(
                                  r.recommended!
                                      ? Icons.thumb_up
                                      : Icons.thumb_down,
                                  color: r.recommended!
                                      ? Colors.green
                                      : Colors.red,
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        );
      },
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _selectedIndex = 0;

  final List<Widget> _pages = <Widget>[
    const StartupScreen(),
    const SearchScreen(),
    const RatingsScreen(),
    const WatchlistScreen(),
    const FlashcardsScreen(),
    const RecommendedScreen(),
    const ProfileScreen(),
  ];

  void _onItemTapped(int index) {
    setState(() => _selectedIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _pages[_selectedIndex],
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        items: const <BottomNavigationBarItem>[
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
          BottomNavigationBarItem(icon: Icon(Icons.search), label: 'Search'),
          BottomNavigationBarItem(icon: Icon(Icons.star), label: 'Ratings'),
          BottomNavigationBarItem(
              icon: Icon(Icons.bookmark), label: 'Watchlist'),
          BottomNavigationBarItem(icon: Icon(Icons.style), label: 'Flashcards'),
          BottomNavigationBarItem(
              icon: Icon(Icons.recommend), label: 'Recommended'),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Profile'),
        ],
        currentIndex: _selectedIndex,
        onTap: _onItemTapped,
      ),
    );
  }
}

class StartupScreen extends StatefulWidget {
  const StartupScreen({super.key});

  @override
  State<StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<StartupScreen>
    with WidgetsBindingObserver {
  List<dynamic> popularMovies = [];
  // Combined popular titles (movies + TV)
  List<dynamic> newReleases = [];
  bool isLoadingPopular = true;
  bool isLoadingNew = true;
  final String apiKey = '043ba3f5be27c72f26817fdfa9536d35';
  // Streaming providers and results
  String watchRegion = 'US';
  List<Map<String, dynamic>> streamingProviders = [];
  Set<int> selectedProviderIds = {};
  // Grouped streaming results by provider: [{ id, name, logo_path, results: [...] }]
  List<Map<String, dynamic>> streamingByProvider = [];
  final Map<String, Map<String, dynamic>> _tmdbDetailCache = {};
  // Genre filtering for streaming rows
  int? selectedStreamingGenreId; // null means All genres
  final List<Map<String, dynamic>> _genreOptions = const [
    {'id': null, 'name': 'All'},
    {'id': 28, 'name': 'Action'},
    {'id': 35, 'name': 'Comedy'},
    {'id': 18, 'name': 'Drama'},
    {'id': 99, 'name': 'Documentary'},
    {'id': 10751, 'name': 'Family'},
    {'id': 878, 'name': 'Sci-Fi'},
    {'id': 16, 'name': 'Animation'},
    {'id': 53, 'name': 'Thriller'},
    {'id': 9648, 'name': 'Mystery'},
  ];
  // Per-provider "More" pagination limits (default 15)
  final Map<int, int> _providerLimits = {};
  bool isLoadingStreaming = true;
  // Family-friendly
  List<dynamic> familyFriendly = [];
  bool isLoadingFamily = true;
  // Boycott list (avg wokeness > 6)
  List<Map<String, dynamic>> boycottList = [];
  bool isLoadingBoycott = true;
  DateTime? _lastRefreshed;
  // Ads gating (mirrors Settings prefs)
  bool _adsEnabledHome = true;
  bool _adsRemovedHome = false;

  // Safely call setState only when this State is still mounted
  void _safeSetState(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
  }

  // Load ad preference flags (enabled/removed) for home screen banner gating.
  Future<void> _loadAdPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final removed = prefs.getBool('ads_removed');
      _safeSetState(() {
        _adsRemovedHome = removed ?? false;
        // Force ads enabled unless user purchased remove-ads
        _adsEnabledHome = !_adsRemovedHome;
      });
    } catch (e) {
      debugPrint('Load ad prefs error: $e');
    }
  }

  // Unified pull-to-refresh + stale lifecycle refresh. Reloads all major sections.
  Future<void> _refreshAll() async {
    // Mark loading states so spinners appear quickly.
    _safeSetState(() {
      isLoadingPopular = true;
      isLoadingNew = true;
      isLoadingStreaming = true;
      isLoadingFamily = true;
      isLoadingBoycott = true;
    });
    try {
      // Popular + New run in parallel.
      await Future.wait([
        _fetchPopularTitles(),
        _fetchNewReleases(),
        _fetchBoycottList(),
      ]);
      // Reload streaming prefs/providers and results (also refresh family list by region).
      await _reloadStreamingPrefsAndData();
    } catch (e) {
      debugPrint('Refresh all error: $e');
    } finally {
      _safeSetState(() => _lastRefreshed = DateTime.now());
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadAdPrefs();
    _fetchPopularTitles();
    _fetchNewReleases();
    _initStreaming();
    // Family-friendly should run after region prefs are loaded in _initStreaming
    // but call once here as well; _initStreaming will trigger again when prefs load.
    _fetchFamilyFriendly();
    _fetchBoycottList();
    _lastRefreshed = DateTime.now();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Auto-refresh streaming and other lists when returning to foreground if data is stale (> 2 hours)
    if (state == AppLifecycleState.resumed) {
      // Try to push any offline ratings now that app is foregrounded
      // Fire-and-forget to avoid blocking UI thread
      try {
        // ignore: discarded_futures
        unawaited(context.read<RatingProvider>().flushOutbox());
      } catch (_) {}
      final last = _lastRefreshed;
      final isStale = last == null ||
          DateTime.now().difference(last) > const Duration(hours: 2);
      if (isStale) {
        _refreshAll();
      }
    }
  }

  Future<void> _initStreaming() async {
    await _loadStreamingPrefs();
    await _fetchProviders();
    if (selectedProviderIds.isEmpty && streamingProviders.isNotEmpty) {
      // Default to common providers among the fetched list
      final defaults = _defaultProviderIdsFrom(streamingProviders);
      _safeSetState(() => selectedProviderIds = defaults);
    }
    await _fetchStreamingByProviders();
    // Also refresh family-friendly now that watchRegion is known
    await _fetchFamilyFriendly();
  }

  Future<void> _loadStreamingPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final storedRegion = prefs.getString('watch_region');
      final storedProviderIds = prefs.getStringList('default_provider_ids');
      _safeSetState(() {
        watchRegion = (storedRegion != null && storedRegion.isNotEmpty)
            ? storedRegion
            : 'US';
        if (storedProviderIds != null && storedProviderIds.isNotEmpty) {
          selectedProviderIds =
              storedProviderIds.map((e) => int.tryParse(e) ?? -1).toSet();
          selectedProviderIds.removeWhere((e) => e <= 0);
        }
      });
    } catch (e) {
      debugPrint('Load streaming prefs error: $e');
    }
  }

  Future<void> _reloadStreamingPrefsAndData() async {
    await _loadStreamingPrefs();
    await _fetchProviders();
    // Ensure selected set only contains providers available in this region
    final availableIds = streamingProviders.map((e) => e['id'] as int).toSet();
    _safeSetState(() {
      selectedProviderIds =
          selectedProviderIds.where((id) => availableIds.contains(id)).toSet();
      if (selectedProviderIds.isEmpty && streamingProviders.isNotEmpty) {
        selectedProviderIds = _defaultProviderIdsFrom(streamingProviders);
      }
      // Normalize per-provider limits map
      _providerLimits
          .removeWhere((key, value) => !selectedProviderIds.contains(key));
      for (final id in selectedProviderIds) {
        _providerLimits.putIfAbsent(id, () => 15);
      }
    });
    await _fetchStreamingByProviders();
    // Refetch family-friendly for new region
    _safeSetState(() => isLoadingFamily = true);
    await _fetchFamilyFriendly();
  }

  // Fetch available streaming watch providers (filtered to major ones) for region US
  Future<void> _fetchProviders() async {
    try {
      final url = Uri.parse(
          'https://api.themoviedb.org/3/watch/providers/movie?api_key=$apiKey&language=en-US&watch_region=$watchRegion');
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final List<dynamic> results = data['results'] ?? [];
        // Keep only a subset of major providers and normalize names
        final targets = <String>{
          'netflix',
          'amazon prime video',
          'prime video',
          'hbo max',
          'max',
          'disney+',
          'disney plus',
          'hulu',
          'paramount+',
          'paramount plus',
          'peacock',
          'amc+',
          'amc plus',
          'apple tv',
          'apple tv+',
          'apple tv plus',
        };
        final filtered = <Map<String, dynamic>>[];
        final Map<String, dynamic> seenProviders = {};
        for (final r in results) {
          final name = (r['provider_name'] ?? '').toString();
          final lower = name.toLowerCase();
          if (targets.contains(lower)) {
            final normalized = _normalizeProviderName(name);
            final key = normalized.toLowerCase();
            if (!seenProviders.containsKey(key)) {
              final entry = {
                'id': r['provider_id'] as int,
                'name': normalized,
                'logo_path': r['logo_path'],
              };
              seenProviders[key] = entry;
              filtered.add(entry);
            } else {
              final existing = seenProviders[key] as Map<String, dynamic>;
              if ((existing['logo_path'] ?? '').toString().isEmpty &&
                  (r['logo_path'] ?? '').toString().isNotEmpty) {
                existing['logo_path'] = r['logo_path'];
              }
            }
          }
        }
        // Sort so Netflix appears next to Amazon Prime (custom priority first)
        int pri(String n) {
          final s = n.toLowerCase();
          if (s.contains('netflix')) return 1;
          if (s.contains('amazon prime') || s == 'prime video') return 2;
          if (s == 'max' || s.contains('hbo max')) return 3;
          if (s.contains('disney')) return 4; // Disney+ / Disney Plus
          if (s.contains('hulu')) return 5;
          if (s.contains('paramount')) return 6; // Paramount+ / Paramount Plus
          if (s.contains('peacock')) return 7;
          if (s.contains('amc+') || s.contains('amc plus')) return 8;
          if (s.contains('apple tv')) return 9;
          return 99;
        }

        filtered.sort((a, b) {
          final pa = pri(a['name'] as String);
          final pb = pri(b['name'] as String);
          if (pa != pb) return pa.compareTo(pb);
          return (a['name'] as String).compareTo(b['name'] as String);
        });
        _safeSetState(() {
          streamingProviders = filtered;
        });
      }
    } catch (e) {
      debugPrint('Providers fetch error: $e');
    }
  }

  Set<int> _defaultProviderIdsFrom(List<Map<String, dynamic>> providers) {
    final order = [
      'Netflix',
      'Amazon Prime Video',
      'Max',
      'Disney+',
      'Hulu',
      'Paramount+',
      'Peacock',
      'AMC+',
      'Apple TV+',
    ];
    final ids = <int>{};
    for (final target in order) {
      final p = providers.firstWhere(
        (e) => (e['name'] as String).toLowerCase() == target.toLowerCase(),
        orElse: () => {},
      );
      if (p.isNotEmpty) ids.add(p['id'] as int);
      if (ids.length >= 2) break; // default to a couple to start
    }
    // If still empty, include first up to 2
    if (ids.isEmpty && providers.isNotEmpty) {
      ids.add(providers.first['id'] as int);
      if (providers.length > 1) ids.add(providers[1]['id'] as int);
    }
    return ids;
  }

  Future<void> _fetchStreamingByProviders() async {
    _safeSetState(() => isLoadingStreaming = true);
    try {
      if (selectedProviderIds.isEmpty) {
        _safeSetState(() {
          streamingByProvider = [];
          isLoadingStreaming = false;
        });
        return;
      }
      // Build per-provider lists with top items from both movies and TV
      final List<Map<String, dynamic>> groups = [];
      // Resolve provider meta from our list
      final provMetaById = {
        for (final p in streamingProviders) p['id'] as int: p,
      };
      for (final id in selectedProviderIds) {
        final meta = provMetaById[id] ?? {};
        final name = (meta['name'] ?? 'Provider').toString();
        final logoPath = meta['logo_path'];
        final limit = _providerLimits[id] ?? 15;

        final results = <Map<String, dynamic>>[];
        // Determine how many pages to fetch based on limit (each page ~20 items)
        final int pagesToFetch = limit <= 20 ? 1 : (limit <= 40 ? 2 : 3);
        for (int page = 1; page <= pagesToFetch; page++) {
          // Discover movies
          final movieUrl = Uri.parse(
              'https://api.themoviedb.org/3/discover/movie?api_key=$apiKey&watch_region=$watchRegion&with_watch_monetization_types=flatrate&with_watch_providers=$id&sort_by=popularity.desc&page=$page');
          // Discover TV
          final tvUrl = Uri.parse(
              'https://api.themoviedb.org/3/discover/tv?api_key=$apiKey&watch_region=$watchRegion&with_watch_monetization_types=flatrate&with_watch_providers=$id&sort_by=popularity.desc&page=$page');

          try {
            final movieResp = await http.get(movieUrl);
            if (movieResp.statusCode == 200) {
              final data = json.decode(movieResp.body) as Map<String, dynamic>;
              final list = List<Map<String, dynamic>>.from(
                  (data['results'] as List<dynamic>? ?? [])
                      .map((e) => Map<String, dynamic>.from(e as Map)));
              for (final r in list) {
                r['media_type'] = 'movie';
              }
              results.addAll(list);
            }
          } catch (_) {}
          try {
            final tvResp = await http.get(tvUrl);
            if (tvResp.statusCode == 200) {
              final data = json.decode(tvResp.body) as Map<String, dynamic>;
              final list = List<Map<String, dynamic>>.from(
                  (data['results'] as List<dynamic>? ?? [])
                      .map((e) => Map<String, dynamic>.from(e as Map)));
              for (final r in list) {
                r['media_type'] = 'tv';
              }
              results.addAll(list);
            }
          } catch (_) {}
        }

        // De-dupe by (id, media_type) and take top 15 by popularity, applying genre filter if set
        final seen = <String>{};
        results.sort((a, b) => ((b['popularity'] ?? 0) as num)
            .compareTo((a['popularity'] ?? 0) as num));
        final uniqueTop = <Map<String, dynamic>>[];
        for (final r in results) {
          final rid = (r['id'] ?? '').toString();
          final mt = (r['media_type'] ?? '').toString();
          final key = '$mt-$rid';
          if (rid.isEmpty || seen.contains(key)) continue;
          // Genre filter check
          final genres = (r['genre_ids'] as List?)?.cast<int>() ?? const [];
          final bool genreOk = selectedStreamingGenreId == null ||
              genres.contains(selectedStreamingGenreId);
          if (!genreOk) continue;
          seen.add(key);
          uniqueTop.add(r);
          if (uniqueTop.length >= limit) break;
        }

        groups.add({
          'id': id,
          'name': name,
          'logo_path': logoPath,
          'results': uniqueTop,
        });
      }

      _safeSetState(() {
        streamingByProvider = groups;
        isLoadingStreaming = false;
      });
    } catch (e) {
      debugPrint('Streaming discover error: $e');
      _safeSetState(() {
        streamingByProvider = [];
        isLoadingStreaming = false;
      });
    }
  }

  // Fetch trending titles across movies and TV to build a combined "Popular Titles" row
  Future<void> _fetchPopularTitles() async {
    try {
      final url = Uri.parse(
          'https://api.themoviedb.org/3/trending/all/week?api_key=$apiKey&page=1');
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final results = List<dynamic>.from(data['results'] ?? []);
        _safeSetState(() {
          popularMovies = results; // reuse field for UI binding
          isLoadingPopular = false;
        });
      } else {
        _safeSetState(() => isLoadingPopular = false);
      }
    } catch (e) {
      debugPrint('Popular titles error: $e');
      _safeSetState(() => isLoadingPopular = false);
    }
  }

  Future<void> _fetchNewReleases() async {
    try {
      final response = await http.get(Uri.parse(
        'https://api.themoviedb.org/3/movie/now_playing?api_key=$apiKey&language=en-US&region=$watchRegion&page=1',
      ));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        _safeSetState(() {
          newReleases = List<dynamic>.from(data['results'] ?? []);
          isLoadingNew = false;
        });
      }
    } catch (e) {
      debugPrint('New releases error: $e');
      _safeSetState(() => isLoadingNew = false);
    }
  }

  // Fetch family-friendly candidates from TMDB and filter using community signals
  Future<void> _fetchFamilyFriendly() async {
    _safeSetState(() => isLoadingFamily = true);
    try {
      // Use US MPAA ratings and include movies rated G/PG (exclude R and above)
      // Focus on certification rather than genre to broaden family options
      final url = Uri.parse(
          'https://api.themoviedb.org/3/discover/movie?api_key=$apiKey&language=en-US&sort_by=popularity.desc&include_adult=false&certification_country=US&certification.lte=PG-13&page=1');
      final response = await http.get(url);
      if (response.statusCode != 200) {
        _safeSetState(() {
          familyFriendly = [];
          isLoadingFamily = false;
        });
        return;
      }
      final data = json.decode(response.body) as Map<String, dynamic>;
      final List<dynamic> results = List<dynamic>.from(data['results'] ?? []);

      // Community filter: low wokeness, high quality, some votes
      const minCount = 5;
      const maxWoke = 3.0;
      const minQuality = 7.0;
      final List<dynamic> ok = [];

      for (final r in results.take(30)) {
        final id = r['id'];
        if (id == null) continue;
        try {
          final rows = await supabase
              .from('movie_ratings')
              .select('wokeness, quality')
              .eq('movie_id', id.toString());
          if (rows.isNotEmpty) {
            final wList = rows
                .map((e) => e['wokeness'] as int?)
                .where((e) => e != null)
                .map((e) => e!.toDouble())
                .toList();
            final qList = rows
                .map((e) => e['quality'] as int?)
                .where((e) => e != null)
                .map((e) => e!.toDouble())
                .toList();
            final count = math.max(wList.length, qList.length);
            if (count >= minCount) {
              final avgW = wList.isNotEmpty
                  ? wList.reduce((a, b) => a + b) / wList.length
                  : 10.0;
              final avgQ = qList.isNotEmpty
                  ? qList.reduce((a, b) => a + b) / qList.length
                  : 0.0;
              if (avgW <= maxWoke && avgQ >= minQuality) {
                ok.add(r);
              }
            }
          }
        } catch (_) {}
      }

      _safeSetState(() {
        familyFriendly = ok;
        isLoadingFamily = false;
      });
    } catch (e) {
      debugPrint('Family-friendly fetch error: $e');
      _safeSetState(() {
        familyFriendly = [];
        isLoadingFamily = false;
      });
    }
  }

  Future<Map<String, dynamic>?> _fetchTmdbDetails(String movieId) async {
    if (_tmdbDetailCache.containsKey(movieId)) {
      return _tmdbDetailCache[movieId];
    }
    for (final type in ['movie', 'tv']) {
      try {
        final uri = Uri.https('api.themoviedb.org', '/3/$type/$movieId', {
          'api_key': apiKey,
          'language': 'en-US',
        });
        final resp = await http.get(uri);
        if (resp.statusCode == 200) {
          final data = json.decode(resp.body) as Map<String, dynamic>;
          data['media_type'] = type;
          _tmdbDetailCache[movieId] = data;
          return data;
        }
      } catch (e) {
        debugPrint('Boycott detail fetch error ($movieId/$type): $e');
      }
    }
    return null;
  }

  Future<void> _fetchBoycottList() async {
    _safeSetState(() => isLoadingBoycott = true);
    try {
      final rows = await supabase
          .from('movie_ratings')
          .select('movie_id,title,wokeness,quality,updated_at')
          .order('updated_at', ascending: false)
          .limit(600);

      final aggregates = <String, _BoycottAggregate>{};
      for (final row in rows) {
        final movieId = row['movie_id']?.toString();
        if (movieId == null || movieId.isEmpty) continue;
        final agg = aggregates.putIfAbsent(
          movieId,
          () => _BoycottAggregate(
            movieId: movieId,
            title: (row['title'] ?? '').toString(),
          ),
        );
        agg.addSample(
          wokeness: row['wokeness'] as num?,
          quality: row['quality'] as num?,
          newTitle: (row['title'] ?? '').toString(),
        );
      }

      final flagged = aggregates.values
          .where((agg) => agg.sampleCount >= 5 && agg.avgWokeness > 6.0)
          .toList()
        ..sort((a, b) {
          final wokeCompare = b.avgWokeness.compareTo(a.avgWokeness);
          if (wokeCompare != 0) return wokeCompare;
          return b.sampleCount.compareTo(a.sampleCount);
        });

      final top = flagged.take(15).toList();
      final detailResults = await Future.wait(
        top.map((agg) => _fetchTmdbDetails(agg.movieId)),
        eagerError: false,
      );

      final List<Map<String, dynamic>> resolved = [];
      for (var i = 0; i < top.length; i++) {
        final agg = top[i];
        final detail = detailResults[i];
        final base = detail != null
            ? Map<String, dynamic>.from(detail)
            : <String, dynamic>{
                'id': int.tryParse(agg.movieId) ?? agg.movieId,
                'title': agg.title ?? 'Unknown',
                'media_type': 'movie',
              };
        base['ww_avg_wokeness'] = agg.avgWokeness;
        base['ww_avg_quality'] = agg.avgQuality;
        base['ww_rating_count'] = agg.sampleCount;
        base['ww_movie_id'] = agg.movieId;
        resolved.add(base);
      }

      _safeSetState(() {
        boycottList = resolved;
        isLoadingBoycott = false;
      });
    } catch (e) {
      debugPrint('Boycott list error: $e');
      _safeSetState(() {
        boycottList = [];
        isLoadingBoycott = false;
      });
    }
  }

  Widget _buildSection(String title, List<dynamic> movies, bool isLoading) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style:
                  const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          // Optional subtitles for specific sections
          if (title == 'Popular Titles') ...[
            const SizedBox(height: 6),
            const Text(
              'Movies and series trending across theaters and streaming.',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ] else if (title == 'Family Friendly') ...[
            const SizedBox(height: 6),
            const Text(
              'Coming soon — curated picks based on community recommendations.',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
          const SizedBox(height: 16),
          isLoading
              ? const Center(child: CircularProgressIndicator())
              : SizedBox(
                  height: 240, // Overall height for the horizontal list
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: movies.length,
                    itemBuilder: (context, index) {
                      final movie = movies[index];
                      return GestureDetector(
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (context) =>
                                  MovieDetailScreen(movie: movie)),
                        ),
                        child: Container(
                          width: 140,
                          margin: const EdgeInsets.only(right: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Constrain image to a fixed aspect box so children
                              // below can't push it out of bounds.
                              ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: SizedBox(
                                  width: 140,
                                  height: 180,
                                  child: Image.network(
                                    'https://image.tmdb.org/t/p/w300${movie['poster_path'] ?? ''}',
                                    width: 140,
                                    height: 180,
                                    fit: BoxFit.cover,
                                    errorBuilder: (context, error, stack) =>
                                        Container(
                                      width: 140,
                                      height: 180,
                                      color: Colors.grey[800],
                                      child: const Icon(Icons.movie),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              // Title placed in a flexible box so long titles wrap
                              // and don't force parent to expand vertically.
                              SizedBox(
                                width: 140,
                                child: Text(
                                  (movie['title'] ?? movie['name'] ?? '')
                                      .toString(),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
        ],
      ),
    );
  }

  Widget _buildBoycottSection() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Boycott List',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              if (isLoadingBoycott)
                const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Community picks averaging above 6/10 on wokeness – proceed with caution.',
            style: TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(height: 16),
          if (isLoadingBoycott)
            const SizedBox(height: 120)
          else if (boycottList.isEmpty)
            const Text(
                'No boycott suggestions yet. Check back after people rate.',
                style: TextStyle(color: Colors.white70))
          else
            SizedBox(
              height: 260,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: boycottList.length,
                itemBuilder: (context, index) {
                  final movie = boycottList[index];
                  final poster = movie['poster_path'];
                  final displayTitle =
                      (movie['title'] ?? movie['name'] ?? 'Unknown').toString();
                  final avgWoke =
                      (movie['ww_avg_wokeness'] as num?)?.toDouble() ?? 0;
                  final avgQuality =
                      (movie['ww_avg_quality'] as num?)?.toDouble() ?? 0;
                  final ratingCount =
                      (movie['ww_rating_count'] as num?)?.toInt() ?? 0;
                  final displayCount = ratingCount.clamp(0, 999).toInt();
                  return GestureDetector(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (context) =>
                              MovieDetailScreen(movie: movie)),
                    ),
                    child: Container(
                      width: 150,
                      margin: const EdgeInsets.only(right: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Stack(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: SizedBox(
                                  width: 150,
                                  height: 200,
                                  child: poster != null
                                      ? Image.network(
                                          'https://image.tmdb.org/t/p/w300$poster',
                                          fit: BoxFit.cover,
                                        )
                                      : Container(
                                          color: Colors.grey[800],
                                          child: const Center(
                                              child: Icon(Icons.movie)),
                                        ),
                                ),
                              ),
                              Positioned(
                                top: 8,
                                left: 8,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Colors.red.shade700.withOpacity(0.9),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    'Woke ${avgWoke.toStringAsFixed(1)}',
                                    style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            displayTitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Quality ${avgQuality.toStringAsFixed(1)} • $displayCount reviews',
                            style: const TextStyle(
                                fontSize: 12, color: Colors.white70),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStreamingSection() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Streaming now',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              if (isLoadingStreaming)
                const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
          const SizedBox(height: 8),
          // Provider chips
          if (streamingProviders.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: streamingProviders.map((p) {
                  final id = p['id'] as int;
                  final name = p['name'] as String;
                  final selected = selectedProviderIds.contains(id);
                  final lp = p['logo_path'];
                  Widget? avatar;
                  if (_isAppleProvider(name)) {
                    avatar = _appleProviderAvatar();
                  } else if (lp != null && (lp as String).isNotEmpty) {
                    avatar = CircleAvatar(
                      backgroundColor: Colors.transparent,
                      backgroundImage:
                          NetworkImage('https://image.tmdb.org/t/p/w45$lp'),
                    );
                  } else {
                    avatar = CircleAvatar(
                      backgroundColor: Colors.grey[800],
                      child: Text(name.isNotEmpty ? name[0] : '?'),
                    );
                  }
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      avatar: avatar,
                      label: Text(name),
                      selected: selected,
                      onSelected: (val) async {
                        _safeSetState(() {
                          if (val) {
                            selectedProviderIds.add(id);
                            _providerLimits.putIfAbsent(id, () => 15);
                          } else {
                            selectedProviderIds.remove(id);
                            _providerLimits.remove(id);
                          }
                        });
                        await _fetchStreamingByProviders();
                      },
                    ),
                  );
                }).toList(),
              ),
            )
          else
            const Text('Loading providers...'),
          const SizedBox(height: 12),
          // (Removed diagnostics tile)
          // Genre filter chips
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: _genreOptions.map((g) {
                final gid = g['id'];
                final name = g['name'] as String;
                final bool selected =
                    (gid == null && selectedStreamingGenreId == null) ||
                        (gid != null && gid == selectedStreamingGenreId);
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(name),
                    selected: selected,
                    onSelected: (val) async {
                      _safeSetState(() {
                        if (!val) {
                          selectedStreamingGenreId = null; // revert to All
                        } else {
                          selectedStreamingGenreId = gid as int?; // may be null
                        }
                      });
                      await _fetchStreamingByProviders();
                    },
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 12),
          // Results list
          if (isLoadingStreaming)
            const Center(child: CircularProgressIndicator())
          else if (streamingByProvider.isEmpty)
            const Text('No results for the selected services.',
                style: TextStyle(color: Colors.grey))
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final group in streamingByProvider)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                if (_isAppleProvider(
                                    (group['name'] ?? '').toString()))
                                  Padding(
                                    padding: const EdgeInsets.only(right: 6),
                                    child: _appleProviderIcon(size: 18),
                                  )
                                else if ((group['logo_path'] ?? '') != '')
                                  Padding(
                                    padding: const EdgeInsets.only(right: 6),
                                    child: Image.network(
                                      'https://image.tmdb.org/t/p/w45${group['logo_path']}',
                                      width: 20,
                                      height: 20,
                                      errorBuilder: (c, e, s) =>
                                          const SizedBox(),
                                    ),
                                  ),
                                Text(
                                  (group['name'] ?? 'Provider').toString(),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                            Builder(builder: (context) {
                              final int pid = (group['id'] as int? ?? -1);
                              final int limit = _providerLimits[pid] ?? 15;
                              final int shown =
                                  (group['results'] as List).length;
                              final bool canMore = limit < 60 && shown >= limit;
                              if (!canMore) return const SizedBox.shrink();
                              return TextButton(
                                onPressed: () async {
                                  _safeSetState(() {
                                    final next =
                                        ((_providerLimits[pid] ?? 15) + 15);
                                    _providerLimits[pid] =
                                        next > 60 ? 60 : next;
                                  });
                                  await _fetchStreamingByProviders();
                                },
                                child: const Text('More'),
                              );
                            }),
                          ],
                        ),
                        const SizedBox(height: 6),
                        SizedBox(
                          height: 240,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            itemCount:
                                (group['results'] as List<dynamic>).length,
                            itemBuilder: (context, index) {
                              final movie =
                                  (group['results'] as List<dynamic>)[index]
                                      as Map<String, dynamic>;
                              return GestureDetector(
                                onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (context) =>
                                          MovieDetailScreen(movie: movie)),
                                ),
                                child: Container(
                                  width: 140,
                                  margin: const EdgeInsets.only(right: 12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(12),
                                        child: SizedBox(
                                          width: 140,
                                          height: 180,
                                          child: Image.network(
                                            'https://image.tmdb.org/t/p/w300${movie['poster_path'] ?? ''}',
                                            width: 140,
                                            height: 180,
                                            fit: BoxFit.cover,
                                            errorBuilder:
                                                (context, error, stack) =>
                                                    Container(
                                              width: 140,
                                              height: 180,
                                              color: Colors.grey[800],
                                              child: const Icon(Icons.movie),
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      SizedBox(
                                        width: 140,
                                        child: Text(
                                          (movie['title'] ??
                                                  movie['name'] ??
                                                  '')
                                              .toString(),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.bold),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('WokeWatch', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.red[700],
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings),
            onPressed: () async {
              final changed = await Navigator.push<bool>(
                context,
                MaterialPageRoute(
                  builder: (context) => SettingsScreen(
                    initialRegion: watchRegion,
                    apiKey: apiKey,
                  ),
                ),
              );
              if (changed == true) {
                await _reloadStreamingPrefsAndData();
                _safeSetState(() => isLoadingNew = true);
                await _fetchNewReleases();
                await _loadAdPrefs();
              }
            },
          )
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refreshAll,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Column(
            children: [
              // Ensure pull-to-refresh works even if content is short
              const SizedBox(height: 0),
              _buildSection('Popular Titles', popularMovies, isLoadingPopular),
              _buildSection('In Theaters', newReleases, isLoadingNew),
              _buildStreamingSection(),
              _buildBoycottSection(),
              _buildSection('Family Friendly', familyFriendly, isLoadingFamily),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
      bottomNavigationBar: (_AdsSupport.isSupportedPlatform &&
              _adsEnabledHome &&
              !_adsRemovedHome)
          ? const _HomeBannerAdBar()
          : null,
    );
  }
}

class SettingsScreen extends StatefulWidget {
  final String initialRegion;
  final String apiKey;
  const SettingsScreen(
      {super.key, required this.initialRegion, required this.apiKey});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _regions = const [
    'US',
    'GB',
    'CA',
    'AU',
    'DE',
    'FR',
    'ES',
    'IT',
    'IN',
    'BR',
    'MX'
  ];
  late String _region;
  List<Map<String, dynamic>> _providers = [];
  Set<int> _selectedProviderIds = {};
  bool _loadingProviders = true;
  bool _adsEnabled = true;
  bool _adsRemoved = false;
  bool _devSupporter = false;
  // Developer AdMob test device management removed in production UI

  @override
  void initState() {
    super.initState();
    _region = widget.initialRegion;
    _hydrate();
  }

  Future<void> _hydrate() async {
    await _loadPrefs();
    await _fetchProviders();
  }

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final storedRegion = prefs.getString('watch_region');
      final storedProviderIds = prefs.getStringList('default_provider_ids');
      final removed = prefs.getBool('ads_removed');
      final supporter = prefs.getBool('dev_supporter');
      setState(() {
        if (storedRegion != null && storedRegion.isNotEmpty) {
          _region = storedRegion;
        }
        if (storedProviderIds != null && storedProviderIds.isNotEmpty) {
          _selectedProviderIds = storedProviderIds
              .map((e) => int.tryParse(e) ?? -1)
              .where((e) => e > 0)
              .toSet();
        }
        _adsRemoved = removed ?? false;
        _devSupporter = supporter ?? false;
        // Force ads enabled unless user purchased remove-ads
        _adsEnabled = !_adsRemoved;
      });
    } catch (e) {
      debugPrint('Settings load prefs error: $e');
    }
  }

  void _syncEntitlementsWithProvider(RatingProvider provider) {
    final newAdsRemoved = provider.adsRemovedEntitlement;
    final newSupporter = provider.devSupporterEntitlement;
    if (newAdsRemoved != _adsRemoved || newSupporter != _devSupporter) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _adsRemoved = newAdsRemoved;
          _adsEnabled = !_adsRemoved;
          _devSupporter = newSupporter;
        });
      });
    }
  }

  Future<void> _fetchProviders() async {
    setState(() => _loadingProviders = true);
    try {
      final url = Uri.parse(
          'https://api.themoviedb.org/3/watch/providers/movie?api_key=${widget.apiKey}&language=en-US&watch_region=$_region');
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final List<dynamic> results = data['results'] ?? [];
        final targets = <String>{
          'netflix',
          'amazon prime video',
          'prime video',
          'hbo max',
          'max',
          'disney+',
          'disney plus',
          'hulu',
          'paramount+',
          'paramount plus',
          'peacock',
          'amc+',
          'amc plus',
          'apple tv',
          'apple tv+',
          'apple tv plus',
        };
        final filtered = <Map<String, dynamic>>[];
        final Map<String, dynamic> seenProviders = {};
        for (final r in results) {
          final name = (r['provider_name'] ?? '').toString();
          final lower = name.toLowerCase();
          if (targets.contains(lower)) {
            final normalized = _normalizeProviderName(name);
            final key = normalized.toLowerCase();
            if (!seenProviders.containsKey(key)) {
              final entry = {
                'id': r['provider_id'] as int,
                'name': normalized,
                'logo_path': r['logo_path'],
              };
              seenProviders[key] = entry;
              filtered.add(entry);
            } else {
              final existing = seenProviders[key] as Map<String, dynamic>;
              if ((existing['logo_path'] ?? '').toString().isEmpty &&
                  (r['logo_path'] ?? '').toString().isNotEmpty) {
                existing['logo_path'] = r['logo_path'];
              }
            }
          }
        }
        int pri(String n) {
          final s = n.toLowerCase();
          if (s.contains('netflix')) return 1;
          if (s.contains('amazon prime') || s == 'prime video') return 2;
          if (s == 'max' || s.contains('hbo max')) return 3;
          if (s.contains('disney')) return 4;
          if (s.contains('hulu')) return 5;
          if (s.contains('paramount')) return 6;
          if (s.contains('peacock')) return 7;
          if (s.contains('amc+') || s.contains('amc plus')) return 8;
          if (s.contains('apple tv')) return 9;
          return 99;
        }

        filtered.sort((a, b) {
          final pa = pri(a['name'] as String);
          final pb = pri(b['name'] as String);
          if (pa != pb) return pa.compareTo(pb);
          return (a['name'] as String).compareTo(b['name'] as String);
        });
        setState(() {
          _providers = filtered;
          // Remove selections that are not in the new provider list
          final available = _providers.map((e) => e['id'] as int).toSet();
          _selectedProviderIds = _selectedProviderIds
              .where((id) => available.contains(id))
              .toSet();
        });
      }
    } catch (e) {
      debugPrint('Settings providers fetch error: $e');
    } finally {
      setState(() => _loadingProviders = false);
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('watch_region', _region);
      await prefs.setStringList('default_provider_ids',
          _selectedProviderIds.map((e) => e.toString()).toList());
      await prefs.setBool('ads_enabled', _adsEnabled);
      await prefs.setBool('ads_removed', _adsRemoved);
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      debugPrint('Settings save error: $e');
      if (!mounted) return;
      Navigator.pop(context, false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<RatingProvider>();
    _syncEntitlementsWithProvider(auth);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('Save', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Account section — offer Google sign-in when user is guest or not connected
          const Text('Account',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          if (auth.offlinePendingCount > 0)
            Card(
              child: ListTile(
                leading: const Icon(Icons.sync_problem),
                title: Text(
                    'Pending sync: ${auth.offlinePendingCount} rating${auth.offlinePendingCount == 1 ? '' : 's'}'),
                subtitle: const Text('Saved locally — will upload when online'),
                trailing: TextButton(
                  onPressed: () async {
                    await auth.flushOutbox();
                    await auth.refreshPendingOutboxCount();
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                            'Sync attempted. Remaining: ${auth.offlinePendingCount}'),
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  },
                  child: const Text('Sync now'),
                ),
              ),
            ),
          if (!auth.isSupabaseConnected || auth.authProvider == 'anonymous')
            Card(
              child: ListTile(
                leading: const Icon(Icons.login),
                title: const Text('Sign in with Google'),
                subtitle: const Text('Link your guest session to sync data'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  try {
                    await context.read<RatingProvider>().signInWithGoogle();
                  } catch (_) {}
                },
              ),
            )
          else
            Card(
              child: ListTile(
                leading: const Icon(Icons.verified_user),
                title: const Text('You are signed in'),
                subtitle: Text(
                  auth.authProvider == 'google'
                      ? 'Provider: Google'
                      : (auth.authProvider ?? 'Provider: Unknown'),
                ),
              ),
            ),
          const SizedBox(height: 16),
          const Text('Region',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _region,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              filled: true,
            ),
            items: _regions
                .map((r) => DropdownMenuItem(value: r, child: Text(r)))
                .toList(),
            onChanged: (val) async {
              if (val == null) return;
              setState(() {
                _region = val;
                _selectedProviderIds.clear();
              });
              await _fetchProviders();
            },
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Default Streaming Providers',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              if (_loadingProviders)
                const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
          const SizedBox(height: 8),
          if (_providers.isEmpty && !_loadingProviders)
            const Text('No providers available for this region.',
                style: TextStyle(color: Colors.grey))
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _providers.map((p) {
                final id = p['id'] as int;
                final name = p['name'] as String;
                final lp = p['logo_path'];
                final selected = _selectedProviderIds.contains(id);
                Widget? avatar;
                if (_isAppleProvider(name)) {
                  avatar = _appleProviderAvatar();
                } else if (lp != null && (lp as String).isNotEmpty) {
                  avatar = CircleAvatar(
                    backgroundColor: Colors.transparent,
                    backgroundImage:
                        NetworkImage('https://image.tmdb.org/t/p/w45$lp'),
                  );
                } else {
                  avatar = CircleAvatar(
                    backgroundColor: Colors.grey[800],
                    child: Text(name.isNotEmpty ? name[0] : '?'),
                  );
                }
                return FilterChip(
                  avatar: avatar,
                  label: Text(name),
                  selected: selected,
                  onSelected: (val) {
                    setState(() {
                      if (val) {
                        _selectedProviderIds.add(id);
                      } else {
                        _selectedProviderIds.remove(id);
                      }
                    });
                  },
                );
              }).toList(),
            ),
          const SizedBox(height: 16),
          const Text(
            'Tip: Choose 1-3 favorite services. You can still toggle providers on the Home tab.',
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 24),
          // Notice about ads and remove-ads option
          if (!_adsRemoved)
            const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('Ads support development'),
              subtitle: Text(
                  'You can remove ads permanently with a one‑time purchase.'),
            ),
          const SizedBox(height: 8),
          // Developer AdMob test tools removed to avoid clutter
          ListTile(
            leading: Icon(_adsRemoved ? Icons.verified : Icons.block),
            title: Text(_adsRemoved ? 'Ads removed' : 'Remove ads'),
            subtitle: Text(_adsRemoved
                ? 'Thanks for supporting WokeWatch!'
                : 'One-time purchase to remove ads'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              if (_adsRemoved) return;
              final ok = await _IapManager.instance.purchaseRemoveAds(context);
              if (!mounted) return;
              if (ok) {
                setState(() {
                  _adsRemoved = true;
                  _adsEnabled = false;
                });
                try {
                  await context
                      .read<RatingProvider>()
                      .updateLocalEntitlements(removeAds: true);
                } catch (_) {}
                // Sync to Supabase (best-effort)
                try {
                  await context.read<RatingProvider>().syncAdEntitlement(
                        removeAds: true,
                        devSupporter: _devSupporter,
                      );
                } catch (_) {}
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('Purchase successful — ads removed')));
              }
            },
          ),
          const SizedBox(height: 8),
          // Optional support purchase (does not remove ads)
          ListTile(
            leading: Icon(
              _devSupporter ? Icons.favorite : Icons.favorite_border,
              color: Colors.pinkAccent,
            ),
            title: Text(_devSupporter
                ? 'Thank you for supporting!'
                : 'Support development'),
            subtitle: Text(
              _devSupporter
                  ? 'Supporter badge unlocked'
                  : 'One-time tip to support future updates',
            ),
            trailing: _devSupporter ? null : const Icon(Icons.chevron_right),
            onTap: () async {
              if (_devSupporter) return;
              final ok = await _IapManager.instance.purchaseDevSupport(context);
              if (!mounted) return;
              if (ok) {
                setState(() {
                  _devSupporter = true;
                });
                try {
                  await context
                      .read<RatingProvider>()
                      .updateLocalEntitlements(devSupporter: true);
                } catch (_) {}
                // Best-effort cloud sync of entitlement
                try {
                  await context.read<RatingProvider>().syncAdEntitlement(
                        removeAds: _adsRemoved,
                        devSupporter: true,
                      );
                } catch (_) {}
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text(
                          'Thanks for supporting! Supporter badge added.')),
                );
              }
            },
          ),
          const SizedBox(height: 8),
          const Divider(),
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AboutScreen()),
              );
            },
          ),
          const SizedBox(height: 12),
          FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (context, snap) {
              if (!snap.hasData) return const SizedBox.shrink();
              final info = snap.data!;
              final versionLabel =
                  '${info.version} (Build ${info.buildNumber})';
              return ListTile(
                leading: const Icon(Icons.tag),
                title: const Text('Version'),
                subtitle: Text(versionLabel),
                dense: true,
              );
            },
          ),
          const SizedBox(height: 12),
        ],
      ),
      bottomNavigationBar:
          (_adsEnabled && !_adsRemoved && _AdsSupport.isSupportedPlatform)
              ? const _SettingsBannerAdBar()
              : null,
    );
  }
}

// Platform/ads capability gate
class _AdsSupport {
  static bool get isSupportedPlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
}

// Consent/UMP manager
class _ConsentManager {
  static bool _requested = false;
  static gads.ConsentStatus? _status;
  static bool get nonPersonalizedOnly => _status != gads.ConsentStatus.obtained;

  static Future<void> requestConsent() async {
    if (_requested) return;
    _requested = true;
    try {
      final params = gads.ConsentRequestParameters(
        tagForUnderAgeOfConsent: false,
      );
      final completer = Completer<void>();
      gads.ConsentInformation.instance.requestConsentInfoUpdate(
        params,
        () {
          completer.complete();
        },
        (gads.FormError error) {
          completer.complete();
        },
      );
      await completer.future;

      final isAvailable =
          await gads.ConsentInformation.instance.isConsentFormAvailable();
      if (isAvailable) {
        final loadDone = Completer<void>();
        gads.ConsentForm.loadConsentForm(
          (gads.ConsentForm form) {
            // Show immediately
            form.show((gads.FormError? _) {
              loadDone.complete();
            });
          },
          (gads.FormError error) {
            loadDone.complete();
          },
        );
        await loadDone.future;
      }
      _status = await gads.ConsentInformation.instance.getConsentStatus();
    } catch (e) {
      debugPrint('Consent flow error: $e');
    }
  }
}

// Simple IAP manager for non-consumable "remove_ads"
class _IapManager {
  _IapManager._();
  static final _IapManager instance = _IapManager._();

  // Support both legacy underscore and current hyphen product IDs.
  static const List<String> _kRemoveAdsIds = ['remove_ads', 'remove-ads'];
  // Matches Play Console Product ID shown earlier
  static const String _kDevSupportId = 'supportdev';

  // Simple diagnostic to log store availability and product discovery.
  Future<void> diagnoseBilling() async {
    try {
      final available = await iap.InAppPurchase.instance.isAvailable();
      debugPrint('[IAP] isAvailable = $available');
      final removeResp = await iap.InAppPurchase.instance
          .queryProductDetails(_kRemoveAdsIds.toSet());
      debugPrint(
          '[IAP] remove ads found: ${removeResp.productDetails.map((e) => e.id).join(', ')}');
      if (removeResp.notFoundIDs.isNotEmpty) {
        debugPrint(
            '[IAP] remove ads not found IDs: ${removeResp.notFoundIDs.join(', ')}');
      }
      final supportResp = await iap.InAppPurchase.instance
          .queryProductDetails({_kDevSupportId});
      debugPrint(
          '[IAP] supportdev found count: ${supportResp.productDetails.length}');
      if (supportResp.notFoundIDs.isNotEmpty) {
        debugPrint(
            '[IAP] supportdev not found IDs: ${supportResp.notFoundIDs.join(', ')}');
      }
    } catch (e) {
      debugPrint('[IAP] diagnose error: $e');
    }
  }

  Future<bool> purchaseRemoveAds(BuildContext context) async {
    try {
      final available = await iap.InAppPurchase.instance.isAvailable();
      if (!available) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Billing unavailable: install from Play test track build (uninstall any sideloaded build), ensure Play Store updated.')));
        return false;
      }

      final resp = await iap.InAppPurchase.instance
          .queryProductDetails(_kRemoveAdsIds.toSet());
      if (resp.productDetails.isEmpty) {
        final notFound = resp.notFoundIDs.join(', ');
        final hint = _kRemoveAdsIds.contains('remove-ads')
            ? 'Hyphen ID (remove-ads) is unsupported on Play; only remove_ads should exist.'
            : '';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Remove ads product not discovered. Not found: $notFound. $hint Reinstall from Play track after product ACTIVE; wait propagation (up to 24h).')));
        return false;
      }
      // Choose first matching detail.
      final product = resp.productDetails.first;

      final completer = Completer<bool>();
      late final StreamSubscription<List<iap.PurchaseDetails>> sub;
      sub = iap.InAppPurchase.instance.purchaseStream.listen(
        (purchases) async {
          for (final p in purchases) {
            if (_kRemoveAdsIds.contains(p.productID)) {
              if (p.status == iap.PurchaseStatus.purchased ||
                  p.status == iap.PurchaseStatus.restored) {
                // Complete purchase on Android if needed
                if (p.pendingCompletePurchase) {
                  await iap.InAppPurchase.instance.completePurchase(p);
                }
                await sub.cancel();
                if (!completer.isCompleted) completer.complete(true);
              } else if (p.status == iap.PurchaseStatus.error) {
                await sub.cancel();
                if (!completer.isCompleted) completer.complete(false);
              }
            }
          }
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete(false);
        },
        onError: (_) {
          if (!completer.isCompleted) completer.complete(false);
        },
      );

      final param = iap.PurchaseParam(productDetails: product);
      await iap.InAppPurchase.instance.buyNonConsumable(purchaseParam: param);
      final ok = await completer.future
          .timeout(const Duration(minutes: 2), onTimeout: () => false);
      return ok;
    } catch (e) {
      debugPrint('IAP purchase error: $e');
      return false;
    }
  }

  Future<bool> purchaseDevSupport(BuildContext context) async {
    try {
      final available = await iap.InAppPurchase.instance.isAvailable();
      if (!available) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Billing unavailable: install Play track build, update Play Store app, verify network.')));
        return false;
      }
      final resp = await iap.InAppPurchase.instance
          .queryProductDetails({_kDevSupportId});
      if (resp.productDetails.isEmpty) {
        final notFound = resp.notFoundIDs.join(', ');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Support product not discovered. Not found: $notFound. Confirm ACTIVE state and reinstall from Play test track.')));
        return false;
      }
      final product = resp.productDetails.first;
      final completer = Completer<bool>();
      late final StreamSubscription<List<iap.PurchaseDetails>> sub;
      sub = iap.InAppPurchase.instance.purchaseStream.listen(
        (purchases) async {
          for (final p in purchases) {
            if (p.productID == _kDevSupportId) {
              if (p.status == iap.PurchaseStatus.purchased ||
                  p.status == iap.PurchaseStatus.restored) {
                if (p.pendingCompletePurchase) {
                  await iap.InAppPurchase.instance.completePurchase(p);
                }
                await sub.cancel();
                if (!completer.isCompleted) completer.complete(true);
              } else if (p.status == iap.PurchaseStatus.error) {
                await sub.cancel();
                if (!completer.isCompleted) completer.complete(false);
              }
            }
          }
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete(false);
        },
        onError: (_) {
          if (!completer.isCompleted) completer.complete(false);
        },
      );
      final param = iap.PurchaseParam(productDetails: product);
      await iap.InAppPurchase.instance.buyNonConsumable(purchaseParam: param);
      final ok = await completer.future
          .timeout(const Duration(minutes: 2), onTimeout: () => false);
      return ok;
    } catch (e) {
      debugPrint('IAP dev support purchase error: $e');
      return false;
    }
  }

  Future<bool> restorePurchases(BuildContext context) async {
    try {
      final available = await iap.InAppPurchase.instance.isAvailable();
      if (!available) return false;

      final completer = Completer<bool>();
      late final StreamSubscription<List<iap.PurchaseDetails>> sub;
      sub = iap.InAppPurchase.instance.purchaseStream.listen(
        (purchases) async {
          for (final p in purchases) {
            final isEntitlement = (_kRemoveAdsIds.contains(p.productID) ||
                p.productID == _kDevSupportId);
            if (isEntitlement &&
                (p.status == iap.PurchaseStatus.purchased ||
                    p.status == iap.PurchaseStatus.restored)) {
              if (p.pendingCompletePurchase) {
                await iap.InAppPurchase.instance.completePurchase(p);
              }
              // Continue listening to capture both products; mark success when any found
              if (!completer.isCompleted) completer.complete(true);
            }
          }
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete(false);
        },
        onError: (_) {
          if (!completer.isCompleted) completer.complete(false);
        },
      );

      await iap.InAppPurchase.instance.restorePurchases();
      final ok = await completer.future
          .timeout(const Duration(minutes: 2), onTimeout: () => false);
      await sub.cancel();
      return ok;
    } catch (e) {
      debugPrint('IAP restore error: $e');
      return false;
    }
  }
}

// A minimal banner ad bar for Settings page (test ad unit)
class _SettingsBannerAdBar extends StatefulWidget {
  const _SettingsBannerAdBar();
  @override
  State<_SettingsBannerAdBar> createState() => _SettingsBannerAdBarState();
}

class _SettingsBannerAdBarState extends State<_SettingsBannerAdBar>
    with WidgetsBindingObserver {
  gads.BannerAd? _banner;
  bool _loaded = false;
  Timer? _retryTimer;
  int _retryCount = 0;
  String? _lastError;
  bool get _isRelease => kReleaseMode;
  gads.AdSize? _adSize;

  // Production Banner Ad Unit IDs
  static const String _adUnitAndroid = 'ca-app-pub-2724939370784936/8741427425';
  static const String _adUnitIOS = 'ca-app-pub-2724939370784936/6691188000';
  // Google Test Banner Ad Unit IDs removed for Settings (always use production)

  String get _adUnitId {
    final ios = defaultTargetPlatform == TargetPlatform.iOS;
    // Always use production unit for Settings banner (no test fallback)
    return ios ? _adUnitIOS : _adUnitAndroid;
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    // Exponential backoff up to 60s
    final delay = Duration(
        seconds: [2 * (1 << _retryCount), 60].reduce((a, b) => a < b ? a : b));
    _retryTimer = Timer(delay, () {
      if (!mounted) return;
      _loadBanner();
    });
    _retryCount = (_retryCount + 1).clamp(0, 5);
  }

  Future<void> _loadBanner() async {
    _banner?.dispose();
    // Use anchored adaptive banner to improve fill; fallback to standard banner
    gads.AdSize size;
    try {
      final width = MediaQuery.of(context).size.width.truncate();
      final adaptive =
          await gads.AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(
              width);
      size = adaptive ?? gads.AdSize.banner;
    } catch (_) {
      size = gads.AdSize.banner;
    }
    _adSize = size;
    _banner = gads.BannerAd(
      size: size,
      adUnitId: _adUnitId,
      listener: gads.BannerAdListener(
        onAdLoaded: (ad) {
          if (!mounted) return;
          debugPrint('BannerAd loaded successfully');
          _retryTimer?.cancel();
          _retryCount = 0;
          _lastError = null;
          setState(() => _loaded = true);
        },
        onAdFailedToLoad: (ad, error) {
          ad.dispose();
          if (mounted) setState(() => _loaded = false);
          debugPrint(
              'BannerAd failed to load: code=${error.code} message=${error.message} domain=${error.domain} responseInfo=${error.responseInfo}');
          _lastError = 'code=${error.code} ${error.message}';
          // No automatic switch to test unit; just retry with backoff
          if (mounted) _scheduleRetry();
        },
      ),
      request: gads.AdRequest(
        nonPersonalizedAds: _ConsentManager.nonPersonalizedOnly,
      ),
    )..load();
  }

  @override
  void initState() {
    super.initState();
    if (_AdsSupport.isSupportedPlatform) {
      WidgetsBinding.instance.addObserver(this);
      () async {
        _loadBanner();
      }();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_AdsSupport.isSupportedPlatform) return;
    try {
      final width = MediaQuery.of(context).size.width.truncate();
      if (_adSize == null || _adSize!.width != width) {
        _loadBanner();
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _retryTimer?.cancel();
    _banner?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _AdsSupport.isSupportedPlatform) {
      // If we return to the app and no ad is loaded, try again
      if (!_loaded) {
        _loadBanner();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // In release, hide the space until an ad loads (no placeholder); in dev show a small helper.
    final notReady =
        !_AdsSupport.isSupportedPlatform || _banner == null || !_loaded;
    if (notReady) {
      if (_isRelease) return const SizedBox.shrink();
      return SafeArea(
        child: SizedBox(
          height: (_adSize?.height ?? 50).toDouble(),
          child: InkWell(
            onTap: _loadBanner,
            child: Center(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    'Ad loading… ',
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                  if (_lastError != null)
                    Flexible(
                      child: Text(
                        '($_lastError)',
                        overflow: TextOverflow.ellipsis,
                        style:
                            const TextStyle(color: Colors.grey, fontSize: 10),
                      ),
                    ),
                  const SizedBox(width: 8),
                  // No manual 'Use test ad' button; production-only here
                  const SizedBox(width: 8),
                  const Icon(Icons.refresh, size: 14, color: Colors.grey),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return SafeArea(
      child: SizedBox(
          height: (_adSize?.height ?? 50).toDouble(),
          child: Center(child: gads.AdWidget(ad: _banner!))),
    );
  }
}

// Home banner bar reusing the same banner implementation as Settings
class _HomeBannerAdBar extends StatelessWidget {
  const _HomeBannerAdBar();
  @override
  Widget build(BuildContext context) => const _ProdBannerAdBar();
}

// Production-only banner for Home screen (no test unit, no debug UI)
class _ProdBannerAdBar extends StatefulWidget {
  const _ProdBannerAdBar();
  @override
  State<_ProdBannerAdBar> createState() => _ProdBannerAdBarState();
}

class _ProdBannerAdBarState extends State<_ProdBannerAdBar>
    with WidgetsBindingObserver {
  gads.BannerAd? _banner;
  bool _loaded = false;
  Timer? _retryTimer;
  int _retryCount = 0;
  gads.AdSize? _adSize;

  // Production Banner Ad Unit IDs (same as settings banner)
  static const String _adUnitAndroid = 'ca-app-pub-2724939370784936/8741427425';
  static const String _adUnitIOS = 'ca-app-pub-2724939370784936/6691188000';

  String get _adUnitId {
    final ios = defaultTargetPlatform == TargetPlatform.iOS;
    return ios ? _adUnitIOS : _adUnitAndroid;
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    final delay = Duration(
        seconds: [2 * (1 << _retryCount), 60].reduce((a, b) => a < b ? a : b));
    _retryTimer = Timer(delay, () {
      if (!mounted) return;
      _loadBanner();
    });
    _retryCount = (_retryCount + 1).clamp(0, 5);
  }

  Future<void> _loadBanner() async {
    _banner?.dispose();
    // Compute an anchored adaptive banner size to improve fill; fallback to standard banner
    gads.AdSize size;
    try {
      final width = MediaQuery.of(context).size.width.truncate();
      final adaptive =
          await gads.AdSize.getCurrentOrientationAnchoredAdaptiveBannerAdSize(
              width);
      size = adaptive ?? gads.AdSize.banner;
    } catch (_) {
      size = gads.AdSize.banner;
    }
    _adSize = size;
    _banner = gads.BannerAd(
      size: size,
      adUnitId: _adUnitId,
      listener: gads.BannerAdListener(
        onAdLoaded: (ad) {
          if (!mounted) return;
          _retryTimer?.cancel();
          _retryCount = 0;
          setState(() => _loaded = true);
        },
        onAdFailedToLoad: (ad, error) {
          ad.dispose();
          if (mounted) setState(() => _loaded = false);
          // Always use production units; just retry with backoff on failures
          if (mounted) _scheduleRetry();
        },
      ),
      request: gads.AdRequest(
        nonPersonalizedAds: _ConsentManager.nonPersonalizedOnly,
      ),
    )..load();
  }

  @override
  void initState() {
    super.initState();
    if (_AdsSupport.isSupportedPlatform) {
      WidgetsBinding.instance.addObserver(this);
      _loadBanner();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_AdsSupport.isSupportedPlatform) return;
    try {
      final width = MediaQuery.of(context).size.width.truncate();
      if (_adSize == null || _adSize!.width != width) {
        // Orientation/width changed; reload with fresh adaptive size
        _loadBanner();
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _retryTimer?.cancel();
    _banner?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _AdsSupport.isSupportedPlatform) {
      if (!_loaded) _loadBanner();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_AdsSupport.isSupportedPlatform || _banner == null || !_loaded) {
      return const SizedBox.shrink();
    }
    return SafeArea(
      child: SizedBox(
          height: (_adSize?.height ?? 50).toDouble(),
          child: Center(child: gads.AdWidget(ad: _banner!))),
    );
  }
}

// About screen with TMDb attribution and link
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Image.asset(
                        'assets/images/tmdb_logo.png',
                        width: 48,
                        errorBuilder: (context, error, stack) => const Icon(
                          Icons.image_not_supported,
                          color: Colors.white54,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                          'This product uses the TMDb API but is not endorsed or certified by TMDb.',
                          style: TextStyle(fontSize: 14),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Movie data and images are provided by TMDb; availability may vary by region. User ratings and comments are user-generated.',
                    style: TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final uri = Uri.parse('https://www.themoviedb.org');
                        try {
                          await launchUrl(uri,
                              mode: LaunchMode.externalApplication);
                        } catch (_) {}
                      },
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('Visit TMDb'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () async {
                        final ok = await _IapManager.instance
                            .restorePurchases(context);
                        if (ok) {
                          try {
                            final prefs = await SharedPreferences.getInstance();
                            await prefs.setBool('ads_removed', true);
                            await prefs.setBool('ads_enabled', false);
                            await prefs.setBool('dev_supporter', true);
                          } catch (_) {}
                          try {
                            await context
                                .read<RatingProvider>()
                                .syncAdEntitlement(
                                  removeAds: true,
                                  devSupporter: true,
                                );
                          } catch (_) {}
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Purchases restored when found')),
                          );
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('No purchases to restore')),
                          );
                        }
                      },
                      icon: const Icon(Icons.restore, size: 18),
                      label: const Text('Restore purchases'),
                      style:
                          TextButton.styleFrom(foregroundColor: Colors.white70),
                    ),
                  )
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Profile tab: show a larger ad (Medium Rectangle) inside the content
class _ProfileAdGate extends StatefulWidget {
  const _ProfileAdGate();
  @override
  State<_ProfileAdGate> createState() => _ProfileAdGateState();
}

class _ProfileAdGateState extends State<_ProfileAdGate> {
  bool _adsEnabled = true;
  bool _adsRemoved = false;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        _adsEnabled = prefs.getBool('ads_enabled') ?? true;
        _adsRemoved = prefs.getBool('ads_removed') ?? false;
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (!_AdsSupport.isSupportedPlatform || !_adsEnabled || _adsRemoved) {
      return const SizedBox.shrink();
    }
    return const Center(child: _ProfileMrecAd());
  }
}

class _ProfileMrecAd extends StatefulWidget {
  const _ProfileMrecAd();
  @override
  State<_ProfileMrecAd> createState() => _ProfileMrecAdState();
}

class _ProfileMrecAdState extends State<_ProfileMrecAd>
    with WidgetsBindingObserver {
  gads.BannerAd? _ad;
  bool _loaded = false;
  Timer? _retryTimer;
  int _retryCount = 0;

  // Android MREC ad unit (provided by you)
  static const String _adUnitAndroid = 'ca-app-pub-2724939370784936/1377591072';
  static const String _adUnitIOS = 'ca-app-pub-2724939370784936/9089358892';

  String get _adUnitId {
    if (defaultTargetPlatform == TargetPlatform.iOS) return _adUnitIOS;
    return _adUnitAndroid;
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    final delay = Duration(
        seconds: [2 * (1 << _retryCount), 60].reduce((a, b) => a < b ? a : b));
    _retryTimer = Timer(delay, () {
      if (!mounted) return;
      _load();
    });
    _retryCount = (_retryCount + 1).clamp(0, 5);
  }

  void _load() {
    _ad?.dispose();
    _ad = gads.BannerAd(
      size: gads.AdSize.mediumRectangle,
      adUnitId: _adUnitId,
      listener: gads.BannerAdListener(
        onAdLoaded: (ad) {
          if (!mounted) return;
          debugPrint('Profile MREC loaded');
          _retryTimer?.cancel();
          _retryCount = 0;
          setState(() => _loaded = true);
        },
        onAdFailedToLoad: (ad, error) {
          ad.dispose();
          if (mounted) setState(() => _loaded = false);
          debugPrint(
              'Profile MREC failed: code=${error.code} message=${error.message}');
          if (mounted) _scheduleRetry();
        },
      ),
      request: gads.AdRequest(
        nonPersonalizedAds: _ConsentManager.nonPersonalizedOnly,
      ),
    )..load();
  }

  @override
  void initState() {
    super.initState();
    if (_AdsSupport.isSupportedPlatform) {
      WidgetsBinding.instance.addObserver(this);
      _load();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _retryTimer?.cancel();
    _ad?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _AdsSupport.isSupportedPlatform) {
      if (!_loaded) _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 260,
      child: !_loaded || _ad == null
          ? const SizedBox.shrink()
          : Center(child: gads.AdWidget(ad: _ad!)),
    );
  }
}

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  List<dynamic> suggestions = [];
  final TextEditingController _controller = TextEditingController();
  bool isSearching = false;
  Timer? _debounce;
  final String apiKey = '043ba3f5be27c72f26817fdfa9536d35';
  String _region = 'US';
  // Optional trending cache for fuzzy fallback
  List<dynamic>? _trendingIndex;
  DateTime? _trendingFetchedAt;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onSearchChanged);
    _loadRegion();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (_controller.text.length >= 2) {
        _searchMovies(_controller.text);
      } else {
        setState(() => suggestions = []);
      }
    });
  }

  Future<void> _loadRegion() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final r = prefs.getString('watch_region');
      if (!mounted) return;
      setState(() {
        _region = (r != null && r.isNotEmpty) ? r : 'US';
      });
    } catch (_) {}
  }

  // --- Fuzzy helpers -------------------------------------------------------
  String _norm(String s) {
    final lower = s.toLowerCase();
    return lower
        .replaceAll(RegExp(r"[^a-z0-9\s]"), "")
        .replaceAll(RegExp(r"\s+"), " ")
        .trim();
  }

  int _levenshtein(String a, String b) {
    a = _norm(a);
    b = _norm(b);
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    final m = a.length;
    final n = b.length;
    final dp = List<int>.generate(n + 1, (j) => j);
    for (int i = 1; i <= m; i++) {
      int prev = dp[0];
      dp[0] = i;
      for (int j = 1; j <= n; j++) {
        final temp = dp[j];
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        dp[j] = [
          dp[j] + 1, // deletion
          dp[j - 1] + 1, // insertion
          prev + cost // substitution
        ].reduce((x, y) => x < y ? x : y);
        prev = temp;
      }
    }
    return dp[n];
  }

  double _similarity(String query, String title) {
    final a = _norm(query);
    final b = _norm(title);
    if (a.isEmpty || b.isEmpty) return 0.0;
    if (b.startsWith(a)) return 1.0;
    final d = _levenshtein(a, b);
    final maxLen = a.length > b.length ? a.length : b.length;
    return 1.0 - (d / maxLen);
  }

  Future<List<dynamic>> _getTrendingIndex() async {
    final now = DateTime.now();
    if (_trendingIndex != null &&
        _trendingFetchedAt != null &&
        now.difference(_trendingFetchedAt!).inMinutes < 30) {
      return _trendingIndex!;
    }
    try {
      final url = Uri.parse(
          'https://api.themoviedb.org/3/trending/all/week?api_key=$apiKey&page=1');
      final resp = await http.get(url);
      if (resp.statusCode == 200) {
        final data = json.decode(resp.body) as Map<String, dynamic>;
        final results = List<dynamic>.from(data['results'] ?? []);
        _trendingIndex = results;
        _trendingFetchedAt = now;
        return results;
      }
    } catch (_) {}
    return _trendingIndex ?? <dynamic>[];
  }

  Future<void> _searchMovies(String query) async {
    setState(() => isSearching = true);
    try {
      // Use multi search so recent TV or alternative titles are found.
      // Filter to movie or tv results and favor region-aware results.
      final url = Uri.parse(
          'https://api.themoviedb.org/3/search/multi?api_key=$apiKey&query=${Uri.encodeComponent(query)}&language=en-US&include_adult=false&region=$_region');
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final List<dynamic> results = List<dynamic>.from(data['results'] ?? []);
        // Keep movies and TV only; re-rank by fuzzy similarity + popularity
        List<dynamic> filtered = results
            .where((r) =>
                r is Map &&
                ((r['media_type'] == 'movie') || (r['media_type'] == 'tv')))
            .toList();
        double scoreOf(Map<String, dynamic> m) {
          final title = (m['title'] ?? m['name'] ?? '').toString();
          final sim = _similarity(query, title);
          final pop = ((m['popularity'] ?? 0) as num).toDouble();
          return sim * 0.85 + (pop / 1000.0) * 0.15;
        }

        filtered.sort((a, b) => scoreOf(b as Map<String, dynamic>)
            .compareTo(scoreOf(a as Map<String, dynamic>)));

        // Fallback with trending fuzzy matches if few or weak
        double bestSim = 0.0;
        for (final r in filtered.take(1)) {
          final t = ((r as Map)['title'] ?? r['name'] ?? '').toString();
          final s = _similarity(query, t);
          if (s > bestSim) bestSim = s;
        }
        if (filtered.length < 3 || bestSim < 0.45) {
          final trending = await _getTrendingIndex();
          final scored = trending
              .where((r) =>
                  r is Map &&
                  ((r['media_type'] == 'movie') || (r['media_type'] == 'tv')))
              .map((r) => r as Map<String, dynamic>)
              .map((m) => {
                    'item': m,
                    'score': _similarity(
                        query, (m['title'] ?? m['name'] ?? '').toString()),
                  })
              .where((e) => (e['score'] as double) >= 0.35)
              .toList();
          scored.sort(
              (a, b) => (b['score'] as double).compareTo(a['score'] as double));
          final topTrending = scored
              .take(10)
              .map((e) => e['item'] as Map<String, dynamic>)
              .toList();
          final seen = <String>{
            for (final r in filtered) '${(r as Map)['media_type']}-${(r)['id']}'
          };
          for (final r in topTrending) {
            final key = '${(r['media_type'])}-${(r['id'])}';
            if (!seen.contains(key)) {
              filtered.add(r);
              seen.add(key);
            }
          }
        }
        if (mounted) {
          setState(() {
            suggestions = filtered;
          });
        }
      }
    } catch (e) {
      debugPrint('Search error: $e');
    } finally {
      if (mounted) setState(() => isSearching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Search Movies')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _controller,
              decoration: InputDecoration(
                hintText: 'Search movies...',
                prefixIcon: isSearching
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.search),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                filled: true,
                fillColor: Colors.grey[900],
              ),
            ),
          ),
          Expanded(
            child: suggestions.isEmpty
                ? const Center(
                    child: Text('Start searching...',
                        style: TextStyle(color: Colors.grey)))
                : ListView.builder(
                    itemCount: suggestions.length,
                    itemBuilder: (context, index) {
                      final movie = suggestions[index];
                      return ListTile(
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.network(
                            'https://image.tmdb.org/t/p/w92${movie['poster_path'] ?? ''}',
                            width: 50,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stack) =>
                                const Icon(Icons.movie),
                          ),
                        ),
                        title: Text(
                            (movie['title'] ?? movie['name'] ?? '').toString()),
                        subtitle: Text(
                          ((movie['release_date'] ?? movie['first_air_date'])
                                  ?.toString()
                                  .split('-')
                                  .first) ??
                              '',
                        ),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (context) =>
                                  MovieDetailScreen(movie: movie)),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// (Removed duplicate old RatingsScreen; see the Stateful version above.)

class _LocalRating {
  final String movieId;
  final String title;
  final int wokeness; // 1..10
  final int quality; // 1..10
  final bool wokeFree; // optional flag
  final bool? recommended; // true/false/null
  final DateTime updatedAt;

  _LocalRating({
    required this.movieId,
    required this.title,
    required this.wokeness,
    required this.quality,
    required this.wokeFree,
    required this.recommended,
    required this.updatedAt,
  });

  static _LocalRating? from(String movieId, dynamic raw) {
    try {
      if (raw is String && raw.trim().isNotEmpty) {
        // Some legacy saves may have written a JSON string inside a string
        final decoded = json.decode(raw);
        return from(movieId, decoded);
      }
      if (raw is! Map) return null;
      final map = Map<String, dynamic>.from(raw);

      String title = ((map['title'] ?? map['name'])?.toString() ?? '').trim();
      if (title.isEmpty) title = 'Unknown';
      // Accept ints/doubles/strings for scores; clamp to 1..10
      int parseScore(dynamic v) {
        if (v is num) return v.clamp(1, 10).toInt();
        if (v is String) {
          final n = int.tryParse(v) ?? double.tryParse(v)?.toInt();
          if (n != null) return n.clamp(1, 10);
        }
        return 5;
      }

      final int w = parseScore(map['wokeness'] ?? map['woke'] ?? 5);
      final int q = parseScore(map['quality'] ?? 5);

      bool wokeFree = false;
      final wf = map['woke_free'];
      if (wf == true ||
          wf == 1 ||
          (wf is String && wf.toLowerCase() == 'true')) {
        wokeFree = true;
      }

      bool? recommended;
      final rec = map['recommended'];
      if (rec == true ||
          rec == 1 ||
          (rec is String && rec.toLowerCase() == 'true')) {
        recommended = true;
      } else if (rec == false ||
          rec == 0 ||
          (rec is String && rec.toLowerCase() == 'false')) {
        recommended = false;
      }

      DateTime updatedAt = DateTime.now();
      final u = map['updated_at'];
      if (u is String) {
        updatedAt = DateTime.tryParse(u) ?? updatedAt;
      }

      return _LocalRating(
        movieId: movieId,
        title: title,
        wokeness: w,
        quality: q,
        wokeFree: wokeFree,
        recommended: recommended,
        updatedAt: updatedAt,
      );
    } catch (_) {
      return null;
    }
  }
}

class RecommendedScreen extends StatefulWidget {
  const RecommendedScreen({super.key});

  @override
  State<RecommendedScreen> createState() => _RecommendedScreenState();
}

class _RecommendedScreenState extends State<RecommendedScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _items = [];
  final String apiKey = '043ba3f5be27c72f26817fdfa9536d35';

  @override
  void initState() {
    super.initState();
    _loadRecommended();
  }

  Future<void> _loadRecommended() async {
    setState(() {
      _loading = true;
      _error = null;
      _items = [];
    });
    try {
      // 1) Pull raw ratings (movie_id, wokeness, quality)
      final List<dynamic> rows = await supabase
          .from('movie_ratings')
          .select('movie_id, title, wokeness, quality');

      if (rows.isEmpty) {
        setState(() {
          _loading = false;
          _items = [];
        });
        return;
      }

      // 2) Aggregate client-side by movie_id
      final Map<String, _Agg> agg = {};
      for (final r in rows) {
        final id = (r['movie_id'] ?? '').toString();
        if (id.isEmpty) continue;
        final w = (r['wokeness'] as num?)?.toDouble();
        final q = (r['quality'] as num?)?.toDouble();
        final title = (r['title'] ?? '') as String;
        final a = agg.putIfAbsent(id, () => _Agg(id, title));
        if (w != null) a.woke.add(w);
        if (q != null) a.quality.add(q);
        if (w != null && q != null && q > 5.0 && w < 3.0) {
          a.qualifyingCount++;
        }
      }

      // 3) Build scored list
      final List<_Scored> scored = [];
      agg.forEach((_, a) {
        if (a.quality.isEmpty && a.woke.isEmpty) return;
        final avgQ = a.quality.isNotEmpty
            ? a.quality.reduce((x, y) => x + y) / a.quality.length
            : 0.0;
        final avgW = a.woke.isNotEmpty
            ? a.woke.reduce((x, y) => x + y) / a.woke.length
            : 0.0;
        final count = a.count;
        scored.add(
            _Scored(a.movieId, a.title, avgQ, avgW, count, a.qualifyingCount));
      });

      // Require community averages and total count thresholds
      // At least 10 total reviews, avg quality > 5, avg wokeness < 3
      const minCount = 10;
      final filtered = scored
          .where((s) =>
              s.count >= minCount && s.avgQuality > 5.0 && s.avgWokeness < 3.0)
          .toList();

      // 4) Sort by highest quality then lowest wokeness, ties by count
      filtered.sort((a, b) {
        final byQ = b.avgQuality.compareTo(a.avgQuality);
        if (byQ != 0) return byQ;
        final byW = a.avgWokeness.compareTo(b.avgWokeness);
        if (byW != 0) return byW;
        return b.count.compareTo(a.count);
      });

      // 5) Limit and fetch TMDB details for UI
      final top = filtered.take(20).toList();
      final List<Map<String, dynamic>> items = [];
      for (final s in top) {
        try {
          final resp = await http.get(Uri.parse(
              'https://api.themoviedb.org/3/movie/${s.movieId}?api_key=$apiKey&language=en-US'));
          Map<String, dynamic>? details;
          if (resp.statusCode == 200) {
            details = json.decode(resp.body) as Map<String, dynamic>;
          }
          items.add({
            'movie_id': s.movieId,
            'title': details?['title'] ?? s.title,
            'poster_path': details?['poster_path'],
            'release_date': details?['release_date'],
            'avg_quality': s.avgQuality,
            'avg_wokeness': s.avgWokeness,
            'count': s.count,
          });
        } catch (_) {
          items.add({
            'movie_id': s.movieId,
            'title': s.title,
            'poster_path': null,
            'release_date': null,
            'avg_quality': s.avgQuality,
            'avg_wokeness': s.avgWokeness,
            'count': s.count,
          });
        }
      }

      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load recommendations: $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Recommended')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(_error!, textAlign: TextAlign.center),
                  ),
                )
              : _items.isEmpty
                  ? const Center(
                      child: Text('Not enough community ratings yet.'))
                  : RefreshIndicator(
                      onRefresh: _loadRecommended,
                      child: ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: _items.length,
                        itemBuilder: (context, index) {
                          final it = _items[index];
                          final title = (it['title'] ?? '') as String;
                          final year = (it['release_date'] is String &&
                                  (it['release_date'] as String).isNotEmpty)
                              ? (it['release_date'] as String).split('-')[0]
                              : '';
                          final posterPath = it['poster_path'] as String?;
                          final avgQ = (it['avg_quality'] as num).toDouble();
                          final avgW = (it['avg_wokeness'] as num).toDouble();
                          final count = it['count'] as int;
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 8),
                            leading: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: posterPath != null
                                  ? Image.network(
                                      'https://image.tmdb.org/t/p/w92$posterPath',
                                      width: 50,
                                      fit: BoxFit.cover,
                                      errorBuilder: (c, e, s) =>
                                          const Icon(Icons.movie),
                                    )
                                  : const SizedBox(
                                      width: 50,
                                      height: 75,
                                      child: Center(child: Icon(Icons.movie)),
                                    ),
                            ),
                            title: Text(title),
                            subtitle: Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                if (year.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 4),
                                    child: Text(year,
                                        style: const TextStyle(
                                            color: Colors.grey)),
                                  ),
                                Chip(
                                  label: Text(
                                    'Quality ${avgQ.toStringAsFixed(1)}',
                                  ),
                                  backgroundColor:
                                      Colors.orange.withValues(alpha: 0.2),
                                  visualDensity: VisualDensity.compact,
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                                Chip(
                                  label: Text(
                                    'Wokeness ${avgW.toStringAsFixed(1)}',
                                  ),
                                  backgroundColor:
                                      Colors.green.withValues(alpha: 0.2),
                                  visualDensity: VisualDensity.compact,
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                                Chip(
                                  label: Text('$count ratings'),
                                  visualDensity: VisualDensity.compact,
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                              ],
                            ),
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => MovieDetailScreen(
                                    movie: {
                                      'id': it['movie_id'],
                                      'title': it['title'],
                                      'poster_path': it['poster_path'],
                                      'release_date': it['release_date'],
                                    },
                                  ),
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),
    );
  }
}

class _Agg {
  final String movieId;
  final String title;
  final List<double> woke = [];
  final List<double> quality = [];
  int qualifyingCount = 0; // quality>5 AND wokeness<3
  _Agg(this.movieId, this.title);
  int get count => math.max(woke.length, quality.length);
}

class _Scored {
  final String movieId;
  final String title;
  final double avgQuality;
  final double avgWokeness;
  final int count;
  final int qualifyingCount;
  _Scored(this.movieId, this.title, this.avgQuality, this.avgWokeness,
      this.count, this.qualifyingCount);
}

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<RatingProvider>();
    String humanizeProvider(String? p) {
      switch (p) {
        case 'google':
          return 'Google';
        case 'email':
          return 'Email';
        case 'anonymous':
          return 'Guest';
        default:
          return p ?? 'Unknown';
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 30,
                  backgroundImage: (provider.avatarUrl != null &&
                          provider.avatarUrl!.isNotEmpty)
                      ? NetworkImage(provider.avatarUrl!)
                      : null,
                  child: (provider.avatarUrl == null ||
                          provider.avatarUrl!.isEmpty)
                      ? const Icon(Icons.person)
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        provider.displayName ??
                            (provider.isGuest ? 'Guest user' : 'User'),
                        style: Theme.of(context).textTheme.titleLarge,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        provider.email ??
                            (provider.isGuest ? 'Not signed in' : ''),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(
                  avatar: const Icon(Icons.lock_open, size: 18),
                  label: Text(
                    provider.isSupabaseConnected ? 'Connected' : 'Offline',
                  ),
                ),
                // Supporter badge (one-time support purchase)
                FutureBuilder<bool>(
                  future: SharedPreferences.getInstance()
                      .then((p) => p.getBool('dev_supporter') ?? false),
                  builder: (context, snap) {
                    final supported = snap.data == true;
                    if (!supported) return const SizedBox.shrink();
                    return const Chip(
                      avatar: Icon(Icons.favorite,
                          size: 18, color: Colors.pinkAccent),
                      label: Text('Supporter'),
                    );
                  },
                ),
                if (provider.authProvider != null)
                  Chip(
                      avatar: const Icon(Icons.badge, size: 18),
                      label: Text(
                          'Provider: ${humanizeProvider(provider.authProvider)}'))
                else if (provider.isGuest)
                  const Chip(
                    avatar: Icon(Icons.person_outline, size: 18),
                    label: Text('Guest'),
                  ),
              ],
            ),
            const SizedBox(height: 24),
            Text('User ID:', style: Theme.of(context).textTheme.titleMedium),
            SelectableText(provider.userId ?? 'Not signed in'),
            const SizedBox(height: 24),
            if (provider.isSupabaseConnected)
              Row(
                children: [
                  ElevatedButton(
                    onPressed: () async {
                      await provider.signOut();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Signed out')),
                        );
                      }
                    },
                    child: const Text('Sign out'),
                  ),
                ],
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Sign in to sync your ratings:'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 12,
                    children: [
                      ElevatedButton.icon(
                        onPressed: () =>
                            context.read<RatingProvider>().signInWithGoogle(),
                        icon: const Icon(Icons.login),
                        label: const Text('Sign in with Google'),
                      ),
                    ],
                  ),
                ],
              ),
            const SizedBox(height: 24),
            // Monetization: Medium Rectangle (MREC) ad on Profile (gated)
            const _ProfileAdGate(),
          ],
        ),
      ),
    );
  }
}

class MovieDetailScreen extends StatefulWidget {
  final dynamic movie;
  const MovieDetailScreen({super.key, required this.movie});

  @override
  State<MovieDetailScreen> createState() => _MovieDetailScreenState();
}

class _MovieDetailScreenState extends State<MovieDetailScreen> {
  Map<String, dynamic>? movieDetails;
  List<dynamic> cast = [];
  bool isLoading = true;
  final String apiKey = '043ba3f5be27c72f26817fdfa9536d35';
  // Availability
  String _watchRegion = 'US';
  List<String> _streamingOn = [];
  bool _inTheaters = false;
  String? _director;
  // TV/meta
  bool _isTv = false;
  int? _numSeasons;
  int? _numEpisodes;
  String? _overview;
  String? _contentRating; // e.g., PG-13 / TV-14
  String? _contentRatingReason; // e.g., reasons for R rating

  @override
  void initState() {
    super.initState();
    _fetchMovieDetails();
  }

  Future<void> _fetchMovieDetails() async {
    try {
      final movieId = widget.movie['id'];
      // Heuristic to decide if this is a TV show
      _isTv = (widget.movie['media_type'] == 'tv') ||
          (widget.movie['name'] != null && widget.movie['title'] == null) ||
          (widget.movie['first_air_date'] != null &&
              widget.movie['release_date'] == null);
      final kind = _isTv ? 'tv' : 'movie';
      final response = await http.get(Uri.parse(
        'https://api.themoviedb.org/3/$kind/$movieId?api_key=$apiKey&language=en-US&append_to_response=credits',
      ));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        // Derive director from credits
        String? director;
        try {
          final crew = (data['credits']?['crew'] as List<dynamic>?) ?? [];
          final d = crew.firstWhere(
              (c) =>
                  (c['job'] == 'Director') ||
                  (c['known_for_department'] == 'Directing'),
              orElse: () => null);
          if (d != null) director = d['name'] as String?;
        } catch (_) {}
        if (mounted) {
          setState(() {
            movieDetails = data;
            cast = data['credits']['cast'] ?? [];
            _director = director;
            _overview = (data['overview'] ?? '').toString();
            if (_isTv) {
              _numSeasons = (data['number_of_seasons'] is int)
                  ? data['number_of_seasons'] as int
                  : int.tryParse('${data['number_of_seasons'] ?? ''}');
              _numEpisodes = (data['number_of_episodes'] is int)
                  ? data['number_of_episodes'] as int
                  : int.tryParse('${data['number_of_episodes'] ?? ''}');
            }
            isLoading = false;
          });
        }
        // Load availability info after details present
        await _loadAvailability();
      }
    } catch (e) {
      debugPrint('Movie details error: $e');
      if (mounted) setState(() => isLoading = false);
    }
  }

  void _toggleWatchlist(BuildContext context) async {
    final provider = context.read<RatingProvider>();
    final id = widget.movie['id'].toString();
    final kind = _isTv ? 'tv' : 'movie';
    final title =
        (widget.movie['title'] ?? widget.movie['name'] ?? 'Unknown').toString();
    final posterPath = widget.movie['poster_path']?.toString();
    final inList = provider.isInWatchlist(id, kind);
    if (inList) {
      final removed = await provider.removeFromWatchlist(id, kind);
      if (removed && mounted) {
        // Prompt for rating opportunity
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Finished "$title"?'),
            content: const Text('Would you like to rate it now?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Not now'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  // Navigate to Ratings tab (index 2) or open rating dialog if available
                  // Assuming MainScreen is ancestor; use Navigator to pop then maybe show rating dialog.
                  // Open rating dialog directly if details loaded.
                  _openRatingDialog(title: title, id: id);
                },
                child: const Text('Rate now'),
              ),
            ],
          ),
        );
      }
    } else {
      await provider.addToWatchlist(id, kind, title, posterPath: posterPath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Added to watchlist')),
        );
      }
    }
    if (mounted) setState(() {});
  }

  void _openRatingDialog({required String title, required String id}) {
    // Reuse existing rating dialog logic: find movie details map if available
    final movieMap = {
      'id': int.tryParse(id) ?? id,
      'title': title,
    };
    showDialog(
      context: context,
      builder: (ctx) => RatingDialog(
        movie: movieMap,
        onSaved: () {
          Navigator.pop(ctx);
        },
      ),
    );
  }

  Future<void> _loadAvailability() async {
    try {
      // Determine region preference
      final prefs = await SharedPreferences.getInstance();
      final region = prefs.getString('watch_region');
      if (mounted) {
        setState(() => _watchRegion =
            (region != null && region.isNotEmpty) ? region : 'US');
      } else {
        _watchRegion = (region != null && region.isNotEmpty) ? region : 'US';
      }

      // Strict "in theaters": only for movies
      final inTheaters =
          _isTv ? false : await _isNowPlaying(widget.movie['id'], _watchRegion);

      // Fetch streaming providers for region
      final id = widget.movie['id'];
      final provUrl = Uri.parse(
          'https://api.themoviedb.org/3/${_isTv ? 'tv' : 'movie'}/$id/watch/providers?api_key=$apiKey');
      final provResp = await http.get(provUrl);
      final names = <String>[];
      if (provResp.statusCode == 200) {
        try {
          final data = json.decode(provResp.body) as Map<String, dynamic>;
          final results = (data['results'] ?? {}) as Map<String, dynamic>;
          final regionInfo = results[_watchRegion] as Map<String, dynamic>?;
          final flatrate = (regionInfo?['flatrate'] as List<dynamic>?) ?? [];
          for (final p in flatrate) {
            final n = (p['provider_name'] ?? '').toString();
            if (n.isNotEmpty) names.add(n);
          }
        } catch (_) {}
      }

      // Fetch content rating (US-only certification)
      String? rating;
      String? ratingReason;
      try {
        if (_isTv) {
          final url = Uri.parse(
              'https://api.themoviedb.org/3/tv/$id/content_ratings?api_key=$apiKey');
          final resp = await http.get(url);
          if (resp.statusCode == 200) {
            final data = json.decode(resp.body) as Map<String, dynamic>;
            final List<dynamic> results =
                List<dynamic>.from(data['results'] ?? []);
            Map<String, dynamic> match = results.firstWhere(
              (r) => (r is Map && r['iso_3166_1'] == 'US'),
              orElse: () => <String, dynamic>{},
            );
            final r = match;
            if (r.isNotEmpty) {
              final s = (r['rating'] ?? '').toString().trim();
              if (s.isNotEmpty) rating = s;
            }
          }
        } else {
          final url = Uri.parse(
              'https://api.themoviedb.org/3/movie/$id/release_dates?api_key=$apiKey');
          final resp = await http.get(url);
          if (resp.statusCode == 200) {
            final data = json.decode(resp.body) as Map<String, dynamic>;
            final List<dynamic> results =
                List<dynamic>.from(data['results'] ?? []);
            Map<String, dynamic> country = results.firstWhere(
              (r) => (r is Map && r['iso_3166_1'] == 'US'),
              orElse: () => <String, dynamic>{},
            );
            final List<dynamic> rels = List<dynamic>.from(
                (country['release_dates'] as List<dynamic>?) ?? []);
            // Pick the first non-empty certification
            for (final rd in rels) {
              if (rd is Map) {
                final cert = ((rd['certification'] ?? '').toString()).trim();
                if (cert.isNotEmpty) {
                  rating = cert;
                  if (cert == 'R') {
                    final List<dynamic> desc =
                        (rd['descriptors'] as List<dynamic>?) ?? const [];
                    final note = (rd['note'] ?? '').toString().trim();
                    if (desc.isNotEmpty) {
                      ratingReason = desc.map((e) => e.toString()).join(', ');
                    } else if (note.isNotEmpty) {
                      ratingReason = note;
                    }
                  }
                  break;
                }
              }
            }
          }
        }
      } catch (_) {}

      if (mounted) {
        setState(() {
          _inTheaters = inTheaters;
          _streamingOn = names;
          _contentRating = rating;
          _contentRatingReason = ratingReason;
        });
      }
    } catch (e) {
      debugPrint('Availability load error: $e');
    }
  }

  Future<bool> _isNowPlaying(dynamic movieId, String region) async {
    try {
      final int id =
          (movieId is int) ? movieId : int.tryParse('$movieId') ?? -1;
      if (id <= 0) return false;
      int page = 1;
      int totalPages = 1;
      while (page <= totalPages && page <= 5) {
        // safety cap at 5 pages
        final url = Uri.parse(
            'https://api.themoviedb.org/3/movie/now_playing?api_key=$apiKey&language=en-US&region=$region&page=$page');
        final resp = await http.get(url);
        if (resp.statusCode != 200) break;
        final data = json.decode(resp.body) as Map<String, dynamic>;
        final results = (data['results'] as List<dynamic>? ?? []);
        for (final r in results) {
          if ((r['id'] as int?) == id) return true;
        }
        totalPages = (data['total_pages'] as int?) ?? totalPages;
        if (totalPages <= 1) break;
        page++;
      }
    } catch (e) {
      debugPrint('Now playing check error: $e');
    }
    return false;
  }

  Future<Map<String, dynamic>> _getCommunityStats(String movieId) async {
    try {
      final response = await supabase
          .from('movie_ratings')
          .select('wokeness, quality, woke_free, recommended')
          .eq('movie_id', movieId);

      if (response.isEmpty) {
        return {
          'avg_wokeness': 0.0,
          'avg_quality': 0.0,
          'count': 0,
          'percent_woke_free': 0.0,
          'percent_recommended': 0.0,
        };
      }

      final wokenessList = response
          .map((r) => r['wokeness'] as int?)
          .where((w) => w != null)
          .map((w) => w!)
          .toList();
      final qualityList = response
          .map((r) => r['quality'] as int?)
          .where((q) => q != null)
          .map((q) => q!)
          .toList();

      int wokeFreeCount = 0;
      int recommendedCount = 0;
      for (final r in response) {
        final wf = r['woke_free'];
        if (wf == true || wf == 1) wokeFreeCount++;
        final rec = r['recommended'];
        if (rec == true || rec == 1) recommendedCount++;
      }

      final avgWoke = wokenessList.isNotEmpty
          ? wokenessList.reduce((a, b) => a + b) / wokenessList.length
          : 0.0;
      final avgQuality = qualityList.isNotEmpty
          ? qualityList.reduce((a, b) => a + b) / qualityList.length
          : 0.0;

      return {
        'avg_wokeness': avgWoke,
        'avg_quality': avgQuality,
        'count': response.length,
        'percent_woke_free': response.isNotEmpty
            ? (wokeFreeCount * 100.0 / response.length)
            : 0.0,
        'percent_recommended': response.isNotEmpty
            ? (recommendedCount * 100.0 / response.length)
            : 0.0,
      };
    } catch (e) {
      debugPrint('Community stats error: $e');
      return {
        'avg_wokeness': 0.0,
        'avg_quality': 0.0,
        'count': 0,
        'percent_woke_free': 0.0,
        'percent_recommended': 0.0,
      };
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<RatingProvider>();
    final watchId = widget.movie['id'].toString();
    final watchKind = _isTv ? 'tv' : 'movie';
    final inWatchlist = provider.isInWatchlist(watchId, watchKind);
    return Scaffold(
      appBar: AppBar(
        title: Text((movieDetails?['title'] ??
                movieDetails?['name'] ??
                widget.movie['title'] ??
                widget.movie['name'] ??
                '')
            .toString()),
        backgroundColor: Colors.black,
        actions: [
          IconButton(
            tooltip: inWatchlist ? 'Remove from watchlist' : 'Add to watchlist',
            icon: Icon(
              inWatchlist ? Icons.bookmark_remove : Icons.bookmark_add,
              color: inWatchlist ? Colors.amber : Colors.white,
            ),
            onPressed: () => _toggleWatchlist(context),
          ),
        ],
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Stack(
                    children: [
                      if (movieDetails?['backdrop_path'] != null)
                        Image.network(
                          'https://image.tmdb.org/t/p/w500${movieDetails!['backdrop_path']}',
                          width: double.infinity,
                          height: 200,
                          fit: BoxFit.cover,
                        ),
                      Positioned(
                        bottom: 16,
                        left: 16,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              (movieDetails?['title'] ??
                                      movieDetails?['name'] ??
                                      widget.movie['title'] ??
                                      widget.movie['name'] ??
                                      '')
                                  .toString(),
                              style: const TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white),
                            ),
                            if (!_isTv && movieDetails?['release_date'] != null)
                              Text(
                                'Year: ${movieDetails!['release_date'].split('-')[0]}',
                                style: const TextStyle(color: Colors.white70),
                              ),
                            if (_isTv &&
                                movieDetails?['first_air_date'] != null)
                              Text(
                                'Year: ${movieDetails!['first_air_date'].split('-')[0]}',
                                style: const TextStyle(color: Colors.white70),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  // Plot Summary
                  if ((_overview ?? '').isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Plot Summary',
                              style: TextStyle(
                                  fontSize: 20, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 8),
                          Text(
                            _overview!,
                            style: const TextStyle(color: Colors.white70),
                          ),
                        ],
                      ),
                    ),
                  // Availability section
                  if (movieDetails != null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Availability',
                              style: TextStyle(
                                  fontSize: 20, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 8),
                          // General facts as chips
                          Wrap(
                            spacing: 12,
                            runSpacing: 8,
                            children: [
                              if (!_isTv)
                                Chip(
                                  avatar: Icon(
                                    _inTheaters
                                        ? Icons.local_movies
                                        : Icons.event,
                                    size: 18,
                                  ),
                                  label: Text(
                                      'In Theaters: ${_inTheaters ? 'Yes' : 'No'}'),
                                ),
                              if ((movieDetails!['release_date'] ?? '')
                                      .toString()
                                      .isNotEmpty &&
                                  !_isTv)
                                Chip(
                                  avatar: const Icon(Icons.calendar_today,
                                      size: 18),
                                  label: Text(
                                      'Release: ${movieDetails!['release_date']}'),
                                ),
                              if (_isTv &&
                                  (movieDetails!['first_air_date'] ?? '')
                                      .toString()
                                      .isNotEmpty)
                                Chip(
                                  avatar: const Icon(Icons.calendar_today,
                                      size: 18),
                                  label: Text(
                                      'First air: ${movieDetails!['first_air_date']}'),
                                ),
                              if ((movieDetails!['runtime'] ?? 0) is int &&
                                  (movieDetails!['runtime'] ?? 0) > 0 &&
                                  !_isTv)
                                Chip(
                                  avatar: const Icon(Icons.timer_outlined,
                                      size: 18),
                                  label: Text(
                                      'Runtime: ${movieDetails!['runtime']} min'),
                                ),
                              if ((_director ?? '').isNotEmpty && !_isTv)
                                Chip(
                                  avatar: const Icon(Icons.chair_alt, size: 18),
                                  label: Text('Director: ${_director!}'),
                                ),
                              if ((_contentRating ?? '').isNotEmpty)
                                Chip(
                                  avatar: const Icon(Icons.shield, size: 18),
                                  label:
                                      Text('Rating: ${_contentRating!} (US)'),
                                ),
                              if ((_contentRating ?? '') == 'R' &&
                                  (_contentRatingReason ?? '').isNotEmpty)
                                Chip(
                                  avatar:
                                      const Icon(Icons.info_outline, size: 18),
                                  label:
                                      Text('Reason: ${_contentRatingReason!}'),
                                ),
                              if (_isTv && (_numSeasons != null))
                                Chip(
                                  avatar: const Icon(Icons.tv, size: 18),
                                  label: Text('Seasons: $_numSeasons'),
                                ),
                              if (_isTv && (_numEpisodes != null))
                                Chip(
                                  avatar: const Icon(Icons.tv, size: 18),
                                  label: Text('Episodes: $_numEpisodes'),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          // Streaming providers in a wrap to avoid overflow
                          Row(
                            children: [
                              const Icon(Icons.tv, size: 18),
                              const SizedBox(width: 6),
                              Text('Streaming ($_watchRegion)',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                            ],
                          ),
                          const SizedBox(height: 6),
                          if (_streamingOn.isNotEmpty)
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final name in _streamingOn)
                                  Chip(label: Text(name)),
                              ],
                            )
                          else
                            const Text('Not available',
                                style: TextStyle(color: Colors.grey)),
                        ],
                      ),
                    ),
                  FutureBuilder<Map<String, dynamic>>(
                    future: _getCommunityStats(widget.movie['id'].toString()),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Center(child: CircularProgressIndicator());
                      }

                      final stats = snapshot.data ??
                          {
                            'avg_wokeness': 0.0,
                            'avg_quality': 0.0,
                            'count': 0,
                            'percent_woke_free': 0.0,
                            'percent_recommended': 0.0,
                          };
                      final avgWoke = stats['avg_wokeness'].toStringAsFixed(1);
                      final avgQuality =
                          stats['avg_quality'].toStringAsFixed(1);
                      final count = stats['count'];
                      final percentWokeFree =
                          (stats['percent_woke_free'] is num)
                              ? (stats['percent_woke_free'] as num).toDouble()
                              : 0.0;
                      final percentRecommended =
                          (stats['percent_recommended'] is num)
                              ? (stats['percent_recommended'] as num).toDouble()
                              : 0.0;
                      final myRating = context
                              .watch<RatingProvider>()
                              .userRatings[widget.movie['id'].toString()]
                          as Map<String, dynamic>?;

                      return Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Community Scores',
                                style: TextStyle(
                                    fontSize: 20, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 8),
                            if (count < 20) ...[
                              const Card(
                                color: Color(0xFF1E1E1E),
                                child: Padding(
                                  padding: EdgeInsets.all(12.0),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Icon(Icons.info_outline,
                                          color: Colors.white70),
                                      SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          'Not enough community reviews yet for this title. Consider helping the community by submitting your own review.',
                                          style:
                                              TextStyle(color: Colors.white70),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                            ],
                            if (count >= 20)
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceAround,
                                children: [
                                  Column(
                                    children: [
                                      const Text('Wokeness',
                                          style:
                                              TextStyle(color: Colors.green)),
                                      Text('$avgWoke/10',
                                          style: const TextStyle(
                                              fontSize: 24,
                                              color: Colors.green,
                                              fontWeight: FontWeight.bold)),
                                      Text('$count ratings',
                                          style: const TextStyle(
                                              color: Colors.grey,
                                              fontSize: 12)),
                                    ],
                                  ),
                                  Column(
                                    children: [
                                      const Text('Quality',
                                          style:
                                              TextStyle(color: Colors.orange)),
                                      Text('$avgQuality/10',
                                          style: const TextStyle(
                                              fontSize: 24,
                                              color: Colors.orange,
                                              fontWeight: FontWeight.bold)),
                                      Text('$count ratings',
                                          style: const TextStyle(
                                              color: Colors.grey,
                                              fontSize: 12)),
                                    ],
                                  ),
                                ],
                              ),
                            if (count > 0) ...[
                              const SizedBox(height: 12),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceAround,
                                children: [
                                  Column(
                                    children: [
                                      const Text('Woke-Free',
                                          style: TextStyle(
                                              color: Colors.tealAccent)),
                                      Row(
                                        children: [
                                          const Icon(Icons.verified_outlined,
                                              color: Colors.tealAccent),
                                          const SizedBox(width: 6),
                                          Text(
                                              '${percentWokeFree.toStringAsFixed(0)}%',
                                              style: const TextStyle(
                                                  fontSize: 20,
                                                  color: Colors.tealAccent,
                                                  fontWeight: FontWeight.bold)),
                                        ],
                                      ),
                                    ],
                                  ),
                                  Column(
                                    children: [
                                      const Text('Recommended',
                                          style: TextStyle(
                                              color: Colors.lightBlueAccent)),
                                      Row(
                                        children: [
                                          const Icon(
                                              Icons.thumb_up_alt_outlined,
                                              color: Colors.lightBlueAccent),
                                          const SizedBox(width: 6),
                                          Text(
                                              '${percentRecommended.toStringAsFixed(0)}%',
                                              style: const TextStyle(
                                                  fontSize: 20,
                                                  color: Colors.lightBlueAccent,
                                                  fontWeight: FontWeight.bold)),
                                        ],
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ],
                            const SizedBox(height: 16),
                            const Divider(),
                            const SizedBox(height: 8),
                            const Text('Your Rating',
                                style: TextStyle(
                                    fontSize: 18, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 8),
                            if (myRating != null)
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceAround,
                                children: [
                                  Column(
                                    children: [
                                      const Text('Wokeness',
                                          style:
                                              TextStyle(color: Colors.green)),
                                      Text('${myRating['wokeness']}/10',
                                          style: const TextStyle(
                                              fontSize: 20,
                                              color: Colors.green,
                                              fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                  Column(
                                    children: [
                                      const Text('Quality',
                                          style:
                                              TextStyle(color: Colors.orange)),
                                      Text('${myRating['quality']}/10',
                                          style: const TextStyle(
                                              fontSize: 20,
                                              color: Colors.orange,
                                              fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                ],
                              )
                            else
                              const Text(
                                "You haven't rated this movie yet.",
                                style: TextStyle(color: Colors.grey),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                  // User Reviews entry
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Card(
                      child: ListTile(
                        leading: const Icon(Icons.reviews),
                        title: const Text('User Reviews'),
                        subtitle:
                            const Text('See comments and selected themes'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          final title = (movieDetails?['title'] ??
                                  widget.movie['title'] ??
                                  '')
                              .toString();
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (context) => UserReviewsScreen(
                                movieId: widget.movie['id'].toString(),
                                title: title,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Cast',
                            style: TextStyle(
                                fontSize: 20, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        SizedBox(
                          height: 100,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            itemCount: cast.length,
                            itemBuilder: (context, index) {
                              final actor = cast[index];
                              return Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: Column(
                                  children: [
                                    CircleAvatar(
                                      radius: 30,
                                      backgroundImage: actor['profile_path'] !=
                                              null
                                          ? NetworkImage(
                                              'https://image.tmdb.org/t/p/w200${actor['profile_path']}')
                                          : null,
                                      child: actor['profile_path'] == null
                                          ? const Icon(Icons.person)
                                          : null,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(actor['name'] ?? '',
                                        style: const TextStyle(fontSize: 12)),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      16,
                      16,
                      16 + MediaQuery.of(context).padding.bottom,
                    ),
                    child: ElevatedButton.icon(
                      onPressed: () => showDialog(
                        context: context,
                        builder: (context) => RatingDialog(
                          movie: widget.movie,
                          onSaved: () {
                            if (mounted) {
                              setState(() {}); // triggers stats refresh
                            }
                          },
                        ),
                      ),
                      icon: const Icon(Icons.star),
                      label: const Text('Rate Movie'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        minimumSize: const Size(double.infinity, 50),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class RatingDialog extends StatefulWidget {
  final dynamic movie;
  final VoidCallback? onSaved;
  const RatingDialog({super.key, required this.movie, this.onSaved});

  @override
  State<RatingDialog> createState() => _RatingDialogState();
}

class _RatingDialogState extends State<RatingDialog> {
  double qualityScore = 5.0;
  double wokenessScore = 5.0;
  Map<String, bool> categories = {};
  final TextEditingController _commentsController = TextEditingController();
  bool _wokeFree = false; // user asserts title is free of woke themes
  int? _recommended; // 1 = thumbs up, -1 = thumbs down

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1A1A1A),
      title: Text(widget.movie['title'] ?? 'Rate Movie'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Quality Slider (green)
            const Text('🟢 Quality Score',
                style: TextStyle(
                    color: Colors.green, fontWeight: FontWeight.bold)),
            Slider(
              value: qualityScore,
              min: 1,
              max: 10,
              divisions: 9,
              activeColor: Colors.green,
              onChanged: (value) => setState(() => qualityScore = value),
            ),
            Text('${qualityScore.round()}/10',
                style: const TextStyle(color: Colors.green)),

            const SizedBox(height: 20),

            // Wokeness Slider (red)
            const Text('🔴 Wokeness Score',
                style:
                    TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
            Slider(
              value: wokenessScore,
              min: 1,
              max: 10,
              divisions: 9,
              activeColor: Colors.red,
              onChanged: (value) => setState(() => wokenessScore = value),
            ),
            Text('${wokenessScore.round()}/10',
                style: const TextStyle(color: Colors.red)),

            const SizedBox(height: 20),

            // Categories
            const Text('Woke Themes:',
                style: TextStyle(
                    fontWeight: FontWeight.bold, color: Colors.white)),
            ...const [
              'LGBTQ+/gender ideology',
              'Systemic racism narrative/D.E.I.',
              'Abortion advocacy',
              'Anti-Christianity',
              'Anti-western values',
              'Socialist/Communist propaganda',
              'Anti Law enforcement/Pro-crime',
              'Feminism extremes',
              'Climate alarmism',
              'Other',
            ].map((category) => CheckboxListTile(
                  title: Text(category,
                      style:
                          const TextStyle(fontSize: 12, color: Colors.white70)),
                  value: categories[category] ?? false,
                  onChanged: (value) =>
                      setState(() => categories[category] = value ?? false),
                  activeColor: Colors.purple,
                  controlAffinity: ListTileControlAffinity.leading,
                )),

            const SizedBox(height: 20),

            // Distinct flags section
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF1E2A22),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.green.shade700, width: 1),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CheckboxListTile(
                    title: Text('Mark as Woke-Free',
                        style: TextStyle(
                            color: Colors.green.shade300,
                            fontWeight: FontWeight.w600)),
                    subtitle: const Text(
                        'Check if you found no notable woke themes.',
                        style: TextStyle(color: Colors.white54, fontSize: 12)),
                    value: _wokeFree,
                    onChanged: (val) =>
                        setState(() => _wokeFree = val ?? false),
                    activeColor: Colors.green,
                    controlAffinity: ListTileControlAffinity.leading,
                    secondary: const Icon(Icons.verified_outlined,
                        color: Colors.green),
                  ),
                  const Divider(height: 12, color: Colors.white24),
                  const Text('Recommend?',
                      style: TextStyle(color: Colors.white70)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: InkWell(
                          onTap: () => setState(() => _recommended = 1),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            decoration: BoxDecoration(
                              color: _recommended == 1
                                  ? Colors.green.shade700
                                  : const Color(0xFF303030),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: _recommended == 1
                                    ? Colors.green
                                    : Colors.white24,
                              ),
                            ),
                            child: const Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.thumb_up, color: Colors.white),
                                SizedBox(height: 4),
                                Text('Thumbs Up',
                                    style: TextStyle(
                                        fontSize: 12, color: Colors.white)),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: InkWell(
                          onTap: () => setState(() => _recommended = -1),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            decoration: BoxDecoration(
                              color: _recommended == -1
                                  ? Colors.red.shade700
                                  : const Color(0xFF303030),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: _recommended == -1
                                    ? Colors.red
                                    : Colors.white24,
                              ),
                            ),
                            child: const Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.thumb_down, color: Colors.white),
                                SizedBox(height: 4),
                                Text('Thumbs Down',
                                    style: TextStyle(
                                        fontSize: 12, color: Colors.white)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            TextField(
              controller: _commentsController,
              maxLines: 3,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Comments...',
                hintStyle: const TextStyle(color: Colors.grey),
                filled: true,
                fillColor: Colors.grey[900],
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
        ),
        ElevatedButton(
          onPressed: () async {
            FocusScope.of(context).unfocus();
            final movieId = widget.movie['id'].toString();
            final ratingData = {
              'wokeness': wokenessScore.round(),
              'quality': qualityScore.round(),
              'categories': categories,
              'comments': _commentsController.text.trim(),
              'title': (widget.movie['title'] ?? widget.movie['name'] ?? '')
                  .toString(),
              'updated_at': DateTime.now().toIso8601String(),
              'woke_free': _wokeFree,
              'recommended': _recommended == 1
                  ? true
                  : (_recommended == -1 ? false : null),
            };
            final provider =
                Provider.of<RatingProvider>(context, listen: false);
            final success = await provider.saveRating(movieId, ratingData);
            if (!mounted) return;
            Navigator.pop(context);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  success
                      ? '✅ Rating saved'
                      : '💾 Saved locally — syncing in background…',
                ),
                backgroundColor: success ? Colors.green : Colors.blue,
              ),
            );
            if (!success) {
              // Try to flush immediately to minimize time the rating is offline-only
              // ignore: discarded_futures
              unawaited(provider.flushOutbox());
            }
            // Trigger a refresh in the parent so community stats update
            if (success) {
              widget.onSaved?.call();
            }
          },
          style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
          child: const Text('Save Rating'),
        ),
      ],
    );
  }
}

// Displays compiled user reviews (comments + themes) for a movie
class UserReviewsScreen extends StatefulWidget {
  final String movieId;
  final String title;
  const UserReviewsScreen(
      {super.key, required this.movieId, required this.title});

  @override
  State<UserReviewsScreen> createState() => _UserReviewsScreenState();
}

class _UserReviewsScreenState extends State<UserReviewsScreen> {
  bool _loading = true;
  String? _error;
  List<_ReviewRow> _rows = [];
  Map<String, int> _themeCounts = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _rows = [];
      _themeCounts = {};
    });
    try {
      final List<dynamic> data = await supabase
          .from('movie_ratings')
          .select('user_id, comments, categories, updated_at')
          .eq('movie_id', widget.movieId)
          .order('updated_at', ascending: false);

      final rows = <_ReviewRow>[];
      final counts = <String, int>{};

      for (final r in data) {
        final comment = (r['comments'] ?? '').toString().trim();
        final dynamic cats = r['categories'];
        final List<String> themes = <String>[];
        if (cats is Map) {
          cats.forEach((key, value) {
            if ((value == true) ||
                (value is num && value != 0) ||
                (value is String && value.toLowerCase() == 'true')) {
              final k = key.toString();
              themes.add(k);
            }
          });
        } else if (cats is List) {
          themes.addAll(cats.map((e) => e.toString()));
        } else if (cats is String && cats.isNotEmpty) {
          try {
            final decoded = json.decode(cats);
            if (decoded is Map) {
              decoded.forEach((key, value) {
                if ((value == true) ||
                    (value is num && value != 0) ||
                    (value is String && value.toLowerCase() == 'true')) {
                  themes.add(key.toString());
                }
              });
            } else if (decoded is List) {
              themes.addAll(decoded.map((e) => e.toString()));
            }
          } catch (_) {}
        }

        // Tally themes
        for (final t in themes) {
          counts[t] = (counts[t] ?? 0) + 1;
        }

        if (comment.isEmpty && themes.isEmpty) continue;
        rows.add(_ReviewRow(
          userId: (r['user_id'] ?? '').toString(),
          comment: comment,
          themes: themes,
          updatedAt: DateTime.tryParse((r['updated_at'] ?? '').toString()),
        ));
      }

      // Sort themes by frequency desc
      final sortedCounts = counts.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final mapSorted = <String, int>{};
      for (final e in sortedCounts) {
        mapSorted[e.key] = e.value;
      }

      if (!mounted) return;
      setState(() {
        _rows = rows;
        _themeCounts = mapSorted;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load reviews: $e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('User Reviews — ${widget.title}')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(_error!, textAlign: TextAlign.center),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(16),
                    itemBuilder: (context, i) {
                      if (i == 0) {
                        // Summary header with theme counts
                        if (_themeCounts.isEmpty) {
                          return const Text('No themes yet.',
                              style: TextStyle(color: Colors.grey));
                        }
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Themes',
                                style: TextStyle(
                                    fontSize: 18, fontWeight: FontWeight.bold)),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: _themeCounts.entries
                                  .map((e) => Chip(
                                      label: Text('${e.key} (${e.value})')))
                                  .toList(),
                            ),
                            const SizedBox(height: 8),
                            const Divider(),
                            const Text('Recent Reviews',
                                style: TextStyle(
                                    fontSize: 18, fontWeight: FontWeight.bold)),
                          ],
                        );
                      }
                      final r = _rows[i - 1];
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (r.themes.isNotEmpty)
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final t in r.themes) Chip(label: Text(t)),
                              ],
                            ),
                          if (r.themes.isNotEmpty && r.comment.isNotEmpty)
                            const SizedBox(height: 8),
                          if (r.comment.isNotEmpty) Text(r.comment),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              const Icon(Icons.person, size: 14),
                              const SizedBox(width: 4),
                              Expanded(
                                  child: Text(
                                r.userId.isEmpty
                                    ? 'Anonymous'
                                    : 'User ${r.userId.substring(0, math.min(6, r.userId.length))}',
                                style: const TextStyle(
                                    color: Colors.grey, fontSize: 12),
                              )),
                              if (r.updatedAt != null)
                                Text(
                                  '${r.updatedAt!.toLocal()}'.split('.').first,
                                  style: const TextStyle(
                                      color: Colors.grey, fontSize: 12),
                                ),
                            ],
                          ),
                        ],
                      );
                    },
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemCount: (_rows.length) + 1,
                  ),
                ),
    );
  }
}

class _ReviewRow {
  final String userId;
  final String comment;
  final List<String> themes;
  final DateTime? updatedAt;
  _ReviewRow({
    required this.userId,
    required this.comment,
    required this.themes,
    required this.updatedAt,
  });
}

class _BoycottAggregate {
  final String movieId;
  String? title;
  double wokeSum = 0;
  int wokeCount = 0;
  double qualitySum = 0;
  int qualityCount = 0;

  _BoycottAggregate({required this.movieId, this.title});

  void addSample({num? wokeness, num? quality, String? newTitle}) {
    if (wokeness != null) {
      wokeSum += wokeness.toDouble();
      wokeCount++;
    }
    if (quality != null) {
      qualitySum += quality.toDouble();
      qualityCount++;
    }
    if (newTitle != null &&
        newTitle.isNotEmpty &&
        (title == null || title!.isEmpty)) {
      title = newTitle;
    }
  }

  int get sampleCount => math.max(wokeCount, qualityCount);
  double get avgWokeness => wokeCount == 0 ? 0 : wokeSum / wokeCount;
  double get avgQuality => qualityCount == 0 ? 0 : qualitySum / qualityCount;
}

// Watchlist tab screen implementation
class WatchlistScreen extends StatefulWidget {
  const WatchlistScreen({super.key});

  @override
  State<WatchlistScreen> createState() => _WatchlistScreenState();
}

class _WatchlistScreenState extends State<WatchlistScreen> {
  final Map<String, Future<Map<String, dynamic>>> _statsFutures = {};
  final Map<String, Future<String?>> _posterFutures = {};

  Future<Map<String, dynamic>> _statsFor(
      String movieId, RatingProvider provider) {
    return _statsFutures.putIfAbsent(
        movieId, () => provider.getCommunityStats(movieId));
  }

  void _pruneStatsCache(Iterable<Map<String, dynamic>> items) {
    final ids = items
        .map((e) => (e['id'] ?? '').toString())
        .where((id) => id.isNotEmpty)
        .toSet();
    _statsFutures.removeWhere((key, _) => !ids.contains(key));
  }

  void _promptRemove(BuildContext context, Map<String, dynamic> item) async {
    final provider = context.read<RatingProvider>();
    final id = (item['id'] ?? '').toString();
    final kind = (item['kind'] ?? '').toString();
    final title = (item['title'] ?? 'Unknown').toString();
    if (id.isEmpty || kind.isEmpty) return;
    final removed = await provider.removeFromWatchlist(id, kind);
    if (!removed) return;
    _statsFutures.remove(id);
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Finished "$title"?'),
        content: const Text('Would you like to rate it now?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Not now')),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _openRatingDialog(context, title: title, id: id);
            },
            child: const Text('Rate now'),
          ),
        ],
      ),
    );
  }

  void _openRatingDialog(BuildContext context,
      {required String title, required String id}) {
    final movieMap = {'id': int.tryParse(id) ?? id, 'title': title};
    showDialog(
      context: context,
      builder: (ctx) => RatingDialog(
        movie: movieMap,
        onSaved: () => Navigator.pop(ctx),
      ),
    );
  }

  Future<String?> _fetchPoster(
      {required String id,
      required String kind,
      required RatingProvider provider}) {
    final cacheKey = '$kind-$id';
    final existing = _posterFutures[cacheKey];
    if (existing != null) return existing;

    Future<String?> fetch() async {
      try {
        final typePath = kind == 'tv' ? 'tv' : 'movie';
        final uri = Uri.https('api.themoviedb.org', '/3/$typePath/$id', {
          'api_key': kTmdbApiKey,
          'language': 'en-US',
        });
        final resp = await http.get(uri);
        if (resp.statusCode == 200) {
          final data = json.decode(resp.body) as Map<String, dynamic>;
          final poster = data['poster_path']?.toString();
          if (poster != null && poster.isNotEmpty) {
            await provider.updateWatchlistPoster(id, kind, poster);
            return poster;
          }
        }
      } catch (e) {
        debugPrint('Watchlist poster fetch error ($id): $e');
      } finally {
        // Allow retries if nothing returned
      }
      return null;
    }

    final future = fetch();
    _posterFutures[cacheKey] = future;
    future.then((value) {
      if (value == null) {
        _posterFutures.remove(cacheKey);
      }
    });
    return future;
  }

  Widget _posterWithFetch(
      {required Map<String, dynamic> item, required RatingProvider provider}) {
    final kind = (item['kind'] ?? 'movie').toString();
    final poster = item['poster_path']?.toString();
    final id = (item['id'] ?? '').toString();
    if (poster != null && poster.isNotEmpty) {
      return _buildPoster(poster, kind);
    }
    if (id.isEmpty) return _buildPoster(null, kind);
    return FutureBuilder<String?>(
      future: _fetchPoster(id: id, kind: kind, provider: provider),
      builder: (context, snapshot) {
        final resolved = snapshot.data ?? poster;
        return _buildPoster(resolved, kind);
      },
    );
  }

  Widget _buildPoster(String? posterPath, String kind) {
    const double width = 70;
    const double height = 105;
    final border = BorderRadius.circular(10);
    if (posterPath == null || posterPath.isEmpty) {
      return Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: Colors.blueGrey.shade800,
          borderRadius: border,
        ),
        child:
            Icon(kind == 'tv' ? Icons.tv : Icons.movie, color: Colors.white70),
      );
    }
    return ClipRRect(
      borderRadius: border,
      child: Image.network(
        'https://image.tmdb.org/t/p/w154$posterPath',
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          width: width,
          height: height,
          color: Colors.blueGrey.shade800,
          child: Icon(kind == 'tv' ? Icons.tv : Icons.movie,
              color: Colors.white70),
        ),
      ),
    );
  }

  Widget _buildStats(String movieId, RatingProvider provider) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _statsFor(movieId, provider),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Text('Fetching community data…',
              style: TextStyle(fontSize: 12, color: Colors.grey));
        }
        if (!snapshot.hasData || (snapshot.data?['count'] ?? 0) == 0) {
          return const Text('No community ratings yet',
              style: TextStyle(fontSize: 12, color: Colors.grey));
        }
        final stats = snapshot.data!;
        num avgWokeness = stats['avg_wokeness'] ?? 0;
        num avgQuality = stats['avg_quality'] ?? 0;
        num percentRecommend = stats['percent_recommended'] ?? 0;
        num percentWokeFree = stats['percent_woke_free'] ?? 0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Wokeness ${avgWokeness.toStringAsFixed(1)} • Quality ${avgQuality.toStringAsFixed(1)}',
              style: const TextStyle(fontSize: 12, color: Colors.white),
            ),
            const SizedBox(height: 2),
            Text(
              'Recommend ${percentRecommend.toStringAsFixed(0)}% • Woke-free ${percentWokeFree.toStringAsFixed(0)}%',
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<RatingProvider>(
      builder: (context, provider, _) {
        final items = provider.watchlist;
        _pruneStatsCache(items);
        return Scaffold(
          appBar: AppBar(title: const Text('Watchlist')),
          body: items.isEmpty
              ? const Center(child: Text('Your watchlist is empty'))
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 6),
                  itemBuilder: (context, i) {
                    final item = items[i];
                    final id = (item['id'] ?? '').toString();
                    final title = (item['title'] ?? 'Unknown').toString();
                    final kind = (item['kind'] ?? 'movie').toString();
                    final poster = item['poster_path']?.toString();
                    final kindLabel = kind == 'tv' ? 'TV Series' : 'Movie';
                    return Card(
                      margin: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                      child: InkWell(
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => MovieDetailScreen(
                                movie: {
                                  'id': int.tryParse(id) ?? id,
                                  kind == 'tv' ? 'name' : 'title': title,
                                  'media_type': kind,
                                  if (poster != null) 'poster_path': poster,
                                },
                              ),
                            ),
                          );
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _posterWithFetch(item: item, provider: provider),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      title,
                                      style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(kindLabel,
                                        style: const TextStyle(
                                            fontSize: 12,
                                            color: Colors.white70)),
                                    const SizedBox(height: 8),
                                    if (id.isNotEmpty)
                                      _buildStats(id, provider),
                                  ],
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.check_circle_outline),
                                tooltip: 'Mark watched & remove',
                                onPressed: () => _promptRemove(context, item),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        );
      },
    );
  }
}

class FlashcardsScreen extends StatefulWidget {
  const FlashcardsScreen({super.key});
  @override
  State<FlashcardsScreen> createState() => _FlashcardsScreenState();
}

class _FlashcardsScreenState extends State<FlashcardsScreen>
    with SingleTickerProviderStateMixin {
  final List<dynamic> _cards = [];
  bool _loading = true;
  int _index = 0;
  final String _apiKey = '043ba3f5be27c72f26817fdfa9536d35';
  late AnimationController _controller;
  late Animation<double> _scale;
  bool _wokeFree = false; // selection state for current card
  bool? _recommended; // null none, true up, false down
  final Set<String> _servedIds = <String>{};
  double _dragDelta = 0;
  final math.Random _rng = math.Random();

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _scale = CurvedAnimation(parent: _controller, curve: Curves.easeOutBack);
    _fetchBatch();
  }

  Future<void> _fetchBatch() async {
    if (!mounted) return;
    setState(() => _loading = true);
    List<dynamic> cards = [];
    try {
      cards = await _buildCandidateList();
      if (cards.isEmpty && _servedIds.isNotEmpty) {
        _servedIds.clear();
        cards = await _buildCandidateList();
      }
    } catch (e) {
      debugPrint('Flashcards fetch error: $e');
    }
    if (!mounted) return;
    if (cards.isNotEmpty) {
      cards.shuffle(_rng);
    }
    setState(() {
      _cards
        ..clear()
        ..addAll(cards);
      _index = 0;
      _wokeFree = false;
      _recommended = null;
      _loading = false;
    });
    if (cards.isNotEmpty) {
      _controller.forward(from: 0);
    }
  }

  Future<List<dynamic>> _buildCandidateList() async {
    if (!mounted) return [];
    final ratedIds = context.read<RatingProvider>().userRatings.keys.toSet();
    final prefs = await SharedPreferences.getInstance();
    final providerIds =
        (prefs.getStringList('default_provider_ids') ?? <String>[])
            .where((id) => id.isNotEmpty)
            .toList();
    final region = prefs.getString('watch_region') ?? 'US';
    List<dynamic> candidates = [];
    if (providerIds.isNotEmpty) {
      final joined = providerIds.join('|');
      candidates = [
        ...await _fetchDiscoverForType('movie', joined, region,
            page: _rng.nextInt(4) + 1),
        ...await _fetchDiscoverForType('tv', joined, region,
            page: _rng.nextInt(4) + 1),
      ];
    }
    if (candidates.isEmpty) {
      candidates = await _fetchTrendingFallback(page: _rng.nextInt(10) + 1);
    }
    final filtered = _filterCandidates(candidates, ratedIds);
    filtered.shuffle(_rng);
    return filtered;
  }

  Future<List<dynamic>> _fetchDiscoverForType(
      String type, String providerIds, String region,
      {int page = 1}) async {
    final params = {
      'api_key': _apiKey,
      'sort_by': 'popularity.desc',
      'watch_region': region,
      'with_watch_providers': providerIds,
      'include_adult': 'false',
      'language': 'en-US',
      'page': page.toString(),
    };
    if (type == 'tv') {
      params['include_null_first_air_dates'] = 'false';
    } else {
      params['include_video'] = 'false';
    }
    final uri = Uri.https('api.themoviedb.org', '/3/discover/$type', params);
    final resp = await http.get(uri);
    if (resp.statusCode == 200) {
      final data = json.decode(resp.body) as Map<String, dynamic>;
      final results = (data['results'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map((map) => {
                ...map,
                'media_type_hint': type,
              })
          .toList();
      return results;
    }
    return [];
  }

  Future<List<dynamic>> _fetchTrendingFallback({int page = 1}) async {
    final uri = Uri.https('api.themoviedb.org', '/3/trending/all/day',
        {'api_key': _apiKey, 'page': page.toString()});
    final resp = await http.get(uri);
    if (resp.statusCode == 200) {
      final data = json.decode(resp.body) as Map<String, dynamic>;
      return (data['results'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .toList();
    }
    return [];
  }

  List<dynamic> _filterCandidates(
      List<dynamic> candidates, Set<String> ratedIds) {
    final filtered = <dynamic>[];
    final seen = <String>{};
    for (final raw in candidates) {
      if (raw is! Map<String, dynamic>) continue;
      final map = Map<String, dynamic>.from(raw);
      final id = map['id'];
      if (id == null) continue;
      final idStr = id.toString();
      if (ratedIds.contains(idStr) || _servedIds.contains(idStr)) continue;
      final title = map['title'] ?? map['name'];
      if (title == null) continue;
      final mediaType = map['media_type'] ??
          map['media_type_hint'] ??
          (map['title'] != null ? 'movie' : 'tv');
      final key = '$mediaType-$idStr';
      if (seen.contains(key)) continue;
      filtered.add({
        ...map,
        'media_type': mediaType,
      });
      seen.add(key);
    }
    return filtered;
  }

  void _nextCard() {
    _markServedCurrent();
    if (_index < _cards.length - 1) {
      setState(() {
        _index++;
        _wokeFree = false;
        _recommended = null;
      });
      _controller.forward(from: 0);
    } else {
      _fetchBatch();
    }
  }

  void _previousCard() {
    if (_index <= 0) return;
    setState(() {
      _index--;
      _wokeFree = false;
      _recommended = null;
    });
    _controller.forward(from: 0);
  }

  void _markServedCurrent() {
    if (_cards.isEmpty || _index >= _cards.length) return;
    final id = _cards[_index]['id'];
    if (id == null) return;
    _servedIds.add(id.toString());
    if (_servedIds.length > 500) {
      _servedIds.remove(_servedIds.first);
    }
  }

  void _toggleSelection({bool? wokeFree, bool? recommended}) {
    setState(() {
      if (wokeFree != null) {
        _wokeFree = !_wokeFree;
      }
      if (recommended != null) {
        // toggle mutually exclusive recommended state
        if (_recommended == recommended) {
          _recommended = null;
        } else {
          _recommended = recommended;
        }
      }
    });
  }

  Future<void> _commitAndNext() async {
    if (_index >= _cards.length) return _nextCard();
    if (!_wokeFree && _recommended == null) {
      _nextCard();
      return;
    }
    final card = _cards[_index];
    final id = card['id'].toString();
    final title = (card['title'] ?? card['name'] ?? 'Unknown').toString();
    try {
      final provider = context.read<RatingProvider>();
      final success = await provider.quickSignal(
        movieId: id,
        title: title,
        wokeFree: _wokeFree ? true : null,
        recommended: _recommended,
      );
      if (mounted) {
        final text = success
            ? 'Synced signals for "$title"'
            : 'Saved locally — syncing soon for "$title"';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(text), duration: const Duration(milliseconds: 900)));
      }
      // Trigger an immediate background flush even if the first upsert succeeded
      // so any earlier pending ratings also clear out quickly.
      // ignore: discarded_futures
      unawaited(provider.flushOutbox());
    } catch (e) {
      debugPrint('Flashcards save error: $e');
    }
    _nextCard();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Flashcards'), centerTitle: true),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _cards.isEmpty
              ? Center(
                  child: TextButton(
                    onPressed: _fetchBatch,
                    child: const Text('Reload'),
                  ),
                )
              : GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragStart: (_) => _dragDelta = 0,
                  onHorizontalDragUpdate: (details) {
                    _dragDelta += details.primaryDelta ?? 0;
                  },
                  onHorizontalDragEnd: (details) {
                    const distanceThreshold = 40;
                    const velocityThreshold = 250;
                    final velocity = details.primaryVelocity ?? 0;
                    final distance = _dragDelta;
                    if (velocity.abs() > velocityThreshold) {
                      if (velocity < 0) {
                        _commitAndNext();
                      } else {
                        _previousCard();
                      }
                    } else if (distance.abs() > distanceThreshold) {
                      if (distance < 0) {
                        _commitAndNext();
                      } else {
                        _previousCard();
                      }
                    }
                    _dragDelta = 0;
                  },
                  child: Center(
                    child: ScaleTransition(
                      scale: _scale,
                      child: _buildCard(_cards[_index]),
                    ),
                  ),
                ),
      bottomNavigationBar: !_loading && _cards.isNotEmpty
          ? SafeArea(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        ElevatedButton.icon(
                          onPressed: () => _toggleSelection(wokeFree: true),
                          icon: const Icon(Icons.verified_outlined),
                          label: Text(_wokeFree ? 'Woke-Free ✓' : 'Woke-Free'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _wokeFree
                                ? Colors.green.shade700
                                : Colors.green.shade900.withValues(alpha: 0.6),
                          ),
                        ),
                        ElevatedButton.icon(
                          onPressed: () => _toggleSelection(recommended: true),
                          icon: const Icon(Icons.thumb_up),
                          label: Text(
                              _recommended == true ? 'Thumb Up ✓' : 'Thumb Up'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _recommended == true
                                ? Colors.blue.shade600
                                : Colors.blue.shade800.withValues(alpha: 0.6),
                          ),
                        ),
                        ElevatedButton.icon(
                          onPressed: () => _toggleSelection(recommended: false),
                          icon: const Icon(Icons.thumb_down),
                          label: Text(_recommended == false
                              ? 'Thumb Down ✓'
                              : 'Thumb Down'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _recommended == false
                                ? Colors.red.shade700
                                : Colors.red.shade900.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _commitAndNext,
                        child: Text(_wokeFree || _recommended != null
                            ? 'Save & Next'
                            : 'Next'),
                      ),
                    )
                  ],
                ),
              ),
            )
          : null,
    );
  }

  Widget _buildCard(dynamic card) {
    final title = (card['title'] ?? card['name'] ?? 'Unknown').toString();
    final poster = card['poster_path'];
    final year = ((card['release_date'] ?? card['first_air_date'] ?? '')
            .toString()
            .split('-')
            .first)
        .trim();
    return Container(
      width: MediaQuery.of(context).size.width * 0.75,
      constraints: const BoxConstraints(maxWidth: 400),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          colors: [Color(0xFF1F1F2E), Color(0xFF3A3A5A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: const [
          BoxShadow(
              color: Colors.black54, blurRadius: 16, offset: Offset(0, 8)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: poster != null
                  ? Image.network(
                      'https://image.tmdb.org/t/p/w500$poster',
                      fit: BoxFit.cover,
                    )
                  : Container(
                      color: Colors.grey.shade800,
                      alignment: Alignment.center,
                      child: const Text('No Image'),
                    ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            title,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),          git remote add origin https://github.com/johndoe/wokewatch_clean.git
          if (year.isNotEmpty)
            Text(
              year,
              style: const TextStyle(color: Colors.white70),
            ),
          const SizedBox(height: 8),
          const Text(
            'Swipe for next or mark signals below.',
            style: TextStyle(fontSize: 12, color: Colors.white54),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
