import 'package:installed_apps/installed_apps.dart';
import 'package:installed_apps/app_info.dart';
import 'package:url_launcher/url_launcher.dart';

class AppLauncherService {
  List<AppInfo>? _cachedApps;

  /// Load installed apps in the background.
  /// Errors are caught so startup does not crash.
  Future<void> warmUp() async {
    try {
      await getInstalledApps();
    } catch (_) {
      // Apps can still be loaded again when requested.
    }
  }

  /// Get installed apps, using the cache when available.
  Future<List<AppInfo>> getInstalledApps() async {
    _cachedApps ??= await InstalledApps.getInstalledApps(false, false);
    return _cachedApps!;
  }

  /// Clear the installed-app cache.
  void clearCache() {
    _cachedApps = null;
  }

  /// Find installed apps matching a query.
  Future<List<AppInfo>> searchApps(String query) async {
    final apps = await getInstalledApps();
    final lowerQuery = query.trim().toLowerCase();

    return apps.where((app) {
      return app.name.toLowerCase().contains(lowerQuery);
    }).toList();
  }

  /// Open an app by name, preferring an exact match.
  Future<String> openApp(String appName) async {
    final query = appName.trim();

    if (query.isEmpty) {
      return 'Please specify which app to open.';
    }

    try {
      final matches = await searchApps(query);

      if (matches.isEmpty) {
        return 'Could not find app "$query". Try another name.';
      }

      AppInfo? target;

      for (final app in matches) {
        if (app.name.toLowerCase() == query.toLowerCase()) {
          target = app;
          break;
        }
      }

      target ??= matches.first;

      await InstalledApps.startApp(target.packageName);
      return 'Opened ${target.name}';
    } catch (e) {
      return 'Could not open "$query": $e';
    }
  }

  /// Open an app by its exact Android package name.
  Future<String> openPackage(String packageName) async {
    final query = packageName.trim();

    if (query.isEmpty) {
      return 'No app package was provided.';
    }

    try {
      await InstalledApps.startApp(query);
      return 'Launched $query';
    } catch (e) {
      return 'Error launching $query: $e';
    }
  }

  /// Search for apps on Google Play.
  Future<String> openPlayStoreSearch(String query) async {
    final searchQuery = query.trim();

    if (searchQuery.isEmpty) {
      return 'Please specify what to search for on Google Play.';
    }

    final uri = Uri.https(
      'play.google.com',
      '/store/search',
      <String, String>{
        'q': searchQuery,
        'c': 'apps',
      },
    );

    return openUrl(uri.toString());
  }

  /// Open an HTTP or HTTPS URL externally.
  Future<String> openUrl(String url) async {
    try {
      final uri = Uri.parse(url);

      if (uri.scheme != 'http' && uri.scheme != 'https') {
        return 'Only HTTP and HTTPS links are supported.';
      }

      if (uri.host.isEmpty) {
        return 'The web address is invalid.';
      }

      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );

      if (launched) {
        return 'Opened $url';
      }

      return 'Could not open $url';
    } catch (e) {
      return 'Error opening URL: $e';
    }
  }
}
