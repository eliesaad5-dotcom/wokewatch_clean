import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:wokewatch_clean/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    // Avoid real disk IO for SharedPreferences in tests
    SharedPreferences.setMockInitialValues({});
    // Initialize Supabase client so the app's auth gate and provider can read it
    // Note: This uses the same public anon key/url as the app; no network calls
    // are required to construct the client for this smoke test.
    try {
      await Supabase.initialize(
        url: 'https://nlgrfrbzhtmypckmxbcf.supabase.co',
        anonKey:
            'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5sZ3JmcmJ6aHRteXBja214YmNmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjA1NTQyMDcsImV4cCI6MjA3NjEzMDIwN30.Jd2tG_uXALNQgjds6N8jahN1p79s36_thIvaI_GhxUU',
      );
    } catch (_) {
      // Already initialized in another test
    }
  });

  testWidgets('WokeWatchApp boots to AuthScreen (signed out)', (tester) async {
    await tester.pumpWidget(const WokeWatchApp());
    // Let initial async microtasks run
    await tester.pump();
    // We should see the Auth screen title when there's no active session
    expect(find.text('Welcome to WokeWatch'), findsOneWidget);
  });
}
