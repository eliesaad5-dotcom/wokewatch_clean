# Copilot instructions for WokeWatch (wokewatch_clean)

Short, actionable guidance to help an AI agent be productive in this repository.

- Project type: Flutter mobile app (multi-platform). Main app entry is `lib/main.dart`.
- Main responsibilities: fetch movie data from TheMovieDB (http), store local ratings in SharedPreferences, and sync ratings to Supabase (`movie_ratings` table) when available.

Key places to look
- `lib/main.dart` — single-file app containing app bootstrapping, `RatingProvider`, screens (Startup/Search/Ratings/Recommended), `MovieDetailScreen`, and `RatingDialog`. Most code lives here; refactor tasks should split components into `lib/screens`, `lib/providers`, `lib/services`.
- `pubspec.yaml` — lists runtime deps: `supabase_flutter`, `provider`, `shared_preferences`, `http`.
- `test/widget_test.dart` — current widget test appears outdated (it references `MyApp` while the app uses `WokeWatchApp`). Update tests before relying on CI.

Architecture & data flow (concrete)
- App is a monolith now — UI, state, and network logic all in `lib/main.dart`.
- Network: uses `package:http` to call TheMovieDB endpoints (see `_fetchPopularMovies`, `_searchMovies`, `_fetchMovieDetails`). The TMDB API key is hard-coded in `lib/main.dart` as `apiKey`.
- Local persistence: `RatingProvider.loadRatings` / `saveRating` use `SharedPreferences` with keys prefixed by `rating_` (example key: `rating_12345`). Use that pattern when reading/writing local ratings.
- Cloud sync: `RatingProvider.saveRating` upserts to Supabase table `movie_ratings` with fields: `movie_id`, `user_id`, `title`, `wokeness`, `quality`, `categories`, `comments`, `updated_at`. Anonymous sign-in occurs in `RatingProvider.initAuth()`.

Developer workflows & commands
- Install deps / get packages:

```powershell
flutter pub get
```

- Run on desktop/emulator/device (example):

```powershell
flutter run -d windows
# or
flutter run -d emulator-5554
```

- Build release artifact (Android):

```powershell
flutter build apk --release
```

- Run tests:

```powershell
flutter test
```

Notes on tests: `test/widget_test.dart` currently imports `package:wokewatch_clean/main.dart` and calls `MyApp()`; change the test to use `WokeWatchApp()` or add a `MyApp` wrapper to main before expecting green tests.

Project-specific conventions and gotchas
- Provider: global `RatingProvider` is registered at app root and immediately calls `initAuth()` and `loadRatings()`; when modifying authentication or initialization order, preserve that startup behavior.
- SharedPreferences keys: only keys starting with `rating_` are considered ratings — use that exact prefix when adding helpers or migrations.
- Supabase usage: `Supabase.initialize(...)` is called in `main()` with hard-coded `url` and `anonKey` in `lib/main.dart`. If you need to change credentials, update `main.dart` or refactor to environment-based config — tests & CI expect initialization to be called before `runApp`.
- Hard-coded secrets: The TMDB `apiKey` and Supabase anon key are in repo. Treat them as existing values (changing them may break live demo data).

Integration points
- TheMovieDB REST API (see `https://api.themoviedb.org/3/...` usage in `lib/main.dart`). Rate limiting and API failures are surfaced to the UI via try/catch and `debugPrint` statements.
- Supabase (auth + Postgres): table `movie_ratings` is used for community stats and upserts. Community-average calculations are done client-side by pulling `wokeness` and `quality` columns and averaging.

Where to make changes (examples)
- Move network code into `lib/services/tmdb_service.dart` and supabase logic into `lib/services/supabase_service.dart`.
- When adding new fields to ratings, update both local `SharedPreferences` encoding and the `upsert` payload in `RatingProvider.saveRating`.

Debugging tips
- Use `flutter run` to view console logs; look for `debugPrint` output from `Load ratings error`, `Cloud sync error`, `Movie details error`, etc.
- If community stats are missing, inspect Supabase table `movie_ratings` and verify the `movie_id` string type — the client queries with `.eq('movie_id', movieId)` and sometimes uses `movieId.toString()`.

If you modify app structure
- Keep `RatingProvider` behavior: anonymous sign-in, local load, then defer cloud sync until `saveRating` is called.
- Preserve SharedPreferences key format to avoid orphaned data.

Quick checklist for PR reviewers (AI or human)
- Do new UI screens keep network calls out of widget build methods (use initState or services)?
- Are SharedPreferences read/writes using the `rating_` prefix?
- Did you update `pubspec.yaml` for any added packages and run `flutter pub get`?
- Run `flutter test` — update `test/widget_test.dart` to `WokeWatchApp()` if you refactor the entrypoint.

Questions for the repo owner
- Do you want hard-coded keys moved to a secure config (env / CI secrets)?
- Preferred code organization if we split `lib/main.dart` into modules?

---
If anything here is unclear or you want the instructions extended (e.g., CI steps, preferred PR labels, or example refactor diff), tell me which area to expand.
