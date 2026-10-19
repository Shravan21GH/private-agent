import 'package:installed_apps/installed_apps.dart';
import 'package:installed_apps/app_info.dart';
import 'package:url_launcher/url_launcher.dart';

class AppLauncherService {
  List<AppInfo>? _cachedApps;

  /// Get all installed apps (cached), including system apps.
  Future<List<AppInfo>> getInstalledApps() async {
    _cachedApps ??= await InstalledApps.getInstalledApps(false, false);
    return _cachedApps!;
  }

  /// Preload installed apps in the background.
  Future<void> warmUp() async {
    try {
      await getInstalledApps();
    } catch (_) {
      // App discovery can be retried when needed.
    }
  }

  /// Clear app cache.
  void clearCache() {
    _cachedApps = null;
  }

  /// Find apps matching a query.
  Future<List<AppInfo>> searchApps(String query) async {
    final apps = await getInstalledApps();
    final lowerQuery = query.trim().toLowerCase();

    return apps.where((app) {
      return app.name.toLowerCase().contains(lowerQuery);
    }).toList();
  }

  /// Open an app by name (fuzzy match).
  Future<String> openApp(String appName) async {
    final cleanedName = appName.trim();

    if (cleanedName.isEmpty) {
      return 'Which app should I open?';
    }

    final matches = await searchApps(cleanedName);

    if (matches.isEmpty) {
      return 'Could not find app "$cleanedName". Try being more specific.';
    }

    // Try exact match first.
    AppInfo? target;

    for (final app in matches) {
      if (app.name.toLowerCase() == cleanedName.toLowerCase()) {
        target = app;
        break;
      }
    }

    target ??= matches.first;

    try {
      await InstalledApps.startApp(target.packageName);
      return 'Opened ${target.name}';
    } catch (e) {
      return 'Error opening ${target.name}: $e';
    }
  }

  /// Open an app by exact package name.
  Future<String> openPackage(String packageName) async {
    final cleanedPackage = packageName.trim();

    if (cleanedPackage.isEmpty) {
      return 'No app package was provided.';
    }

    try {
      await InstalledApps.startApp(cleanedPackage);
      return 'Launched $cleanedPackage';
    } catch (e) {
      return 'Error launching $cleanedPackage: $e';
    }
  }

  /// Search for apps on Google Play.
  Future<String> openPlayStoreSearch(String query) async {
    final searchQuery = query.trim();

    if (searchQuery.isEmpty) {
      return 'What app should I search for?';
    }

    final uri = Uri.https(
      'play.google.com',
      '/store/search',
      {
        'q': searchQuery,
        'c': 'apps',
      },
    );

    return openUrl(uri.toString());
  }

  /// Open a URL in an external application.
  Future<String> openUrl(String url) async {
    try {
      final uri = Uri.parse(url.trim());

      if (uri.scheme != 'http' && uri.scheme != 'https') {
        return 'Only HTTP and HTTPS links can be opened.';
      }

      if (await canLaunchUrl(uri)) {
        final opened = await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        );

        if (opened) {
          return 'Opened $url';
        }
      }

      return 'Cannot open $url';
    } catch (e) {
      return 'Error opening URL: $e';
    }
  }
}
