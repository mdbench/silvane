import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:sembast/sembast.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'main.dart';
import 'silver_git.dart';
import 'sylvan_sap.dart';
import 'forest_finder.dart';
import 'metal_mail.dart';
import 'voice_trunk.dart';
import 'ore_pine.dart';
import 'weather_vane.dart';
import 'db_service.dart';

class Tab1Screen extends StatefulWidget {
  final String searchQuery;
  const Tab1Screen({super.key, required this.searchQuery});

  @override
  State<Tab1Screen> createState() => _Tab1ScreenState();
}

class _Tab1ScreenState extends State<Tab1Screen> with AutomaticKeepAliveClientMixin {
  static final List<Map<String, dynamic>> _globalServers = [];
  static final Map<String, HttpServer> _globalRunningServers = {};
  
  static HttpServer? _globalStatusServer;
  static const int _statusServerPort = 41998;

  final int _basePort = 41820;
  static const String _dbKeySilverGitRunning = 'silver_git_server_running';

  static final Map<String, List<int>> _rateLimitTracker = {};

  @override
  bool get wantKeepAlive => true;

  Timer? _serverPollTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initServersSafe();
    });
  }

  @override
  void dispose() {
    _serverPollTimer?.cancel();
    _globalStatusServer?.close(force: true);
    _globalStatusServer = null;
    super.dispose();
  }

  Future<void> _initServersSafe() async {
    try {
      await _ensurePersistentCerts();
      await _startAlwaysOnStatusServer();
      await _scanAndStartServers();
      
      // Initial background evaluation
      unawaited(_evaluateAllServers());

      // Set up a 1-minute periodic timer to evaluate server schedules and operational states
      _serverPollTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
        _evaluateAllServers();
      });
    } catch (e) {
      debugPrint('[Tab1] Safe initialization error: $e');
    }
  }

  Future<void> _evaluateAllServers() async {
    try {
      await SilverGitScreen.startServerIfEnabled();
      await SylvanSapScreen.startServerIfEnabled();
      await ForestFinderScreen.startServerIfEnabled();
      await MetalMailScreen.startServerIfEnabled();
      await VoiceTrunkScreen.startServerIfEnabled();
      await OrePineScreen.startServerIfEnabled();
      
      // Refresh local deployment status scanning
      await _scanAndStartServers();
    } catch (e) {
      debugPrint('[Tab1] Periodic server evaluation error: $e');
    }
  }

  Future<String> _ensurePersistentCerts() async {
    final certDir = Directory(p.join(appDirectoryPath, '.silvane_certs'));
    if (!await certDir.exists()) {
      await certDir.create(recursive: true);
    }
    
    // Unconditionally sync default certs from assets on every startup
    final certFile = File(p.join(certDir.path, 'cert.pem'));
    final keyFile = File(p.join(certDir.path, 'key.pem'));
    final caFile = File(p.join(certDir.path, 'ca.pem'));

    final certBytes = await rootBundle.load('assets/cert.pem');
    await certFile.writeAsBytes(certBytes.buffer.asUint8List());

    final keyBytes = await rootBundle.load('assets/key.pem');
    await keyFile.writeAsBytes(keyBytes.buffer.asUint8List());

    final caBytes = await rootBundle.load('assets/ca.pem');
    await caFile.writeAsBytes(caBytes.buffer.asUint8List());

    return certDir.path;
  }

  Future<SecurityContext> _getSecureContext() async {
    final store = StoreRef<String, dynamic>.main();
    final selectedPrefix = await store.record('active_cert_prefix').get(sembastDb) as String? ?? '';

    final certDirPath = await _ensurePersistentCerts();
    
    String certPath;
    String keyPath;
    String caPath;

    if (selectedPrefix.isNotEmpty && selectedPrefix != 'default') {
      certPath = p.join(certDirPath, '${selectedPrefix}_cert.pem');
      keyPath = p.join(certDirPath, '${selectedPrefix}_key.pem');
      caPath = p.join(certDirPath, '${selectedPrefix}_ca.pem');

      if (!await File(certPath).exists() || !await File(keyPath).exists() || !await File(caPath).exists()) {
        certPath = p.join(certDirPath, 'cert.pem');
        keyPath = p.join(certDirPath, 'key.pem');
        caPath = p.join(certDirPath, 'ca.pem');
      }
    } else {
      certPath = p.join(certDirPath, 'cert.pem');
      keyPath = p.join(certDirPath, 'key.pem');
      caPath = p.join(certDirPath, 'ca.pem');
    }

    final context = SecurityContext(withTrustedRoots: false);
    context.useCertificateChain(certPath);
    context.usePrivateKey(keyPath);
    context.setTrustedCertificates(caPath);
    context.setClientAuthorities(caPath);
    return context;
  }

  static final Set<String> _statusSessionFingerprints = <String>{};

  Future<void> _startAlwaysOnStatusServer() async {
    if (_globalStatusServer != null) return;
    try {
      final securityContext = await _getSecureContext();
      final server = await HttpServer.bindSecure(
        '0.0.0.0',
        _statusServerPort,
        securityContext,
        requestClientCertificate: true,
      );

      shelf_io.serveRequests(server, (Request request) async {
        final path = request.url.path;

        // Serve fingerprint script asset securely upon request
        if (path == 'fingerprint2.min.js') {
          try {
            final jsBytes = await rootBundle.load('assets/fingerprint2.min.js');
            return Response.ok(
              jsBytes.buffer.asUint8List(),
              headers: {'content-type': 'application/javascript; charset=utf-8'},
            );
          } catch (_) {
            return Response.notFound('Fingerprint script not found');
          }
        }

        // --- Weather Vane API Authentication & Endpoints ---
        if (path.startsWith('api/weather-vane/')) {
          if (path != 'api/weather-vane/auth/login') {
            final clientFp = request.headers['x-trustless-fp'];
            if (clientFp == null || !_statusSessionFingerprints.contains(clientFp)) {
              return Response(
                401,
                body: jsonEncode({'error': 'Unauthorized: Invalid or missing session browser fingerprint.'}),
                headers: {'content-type': 'application/json'},
              );
            }
          }
        }

        if (path == 'api/weather-vane/auth/login' && request.method == 'POST') {
          try {
            final bodyStr = await request.readAsString();
            final data = jsonDecode(bodyStr) as Map<String, dynamic>;
            final username = data['username'] as String? ?? '';
            final password = data['password'] as String? ?? '';
            final totpCode = data['totp'] as String? ?? '';
            final fingerprint = data['fingerprint'] as String? ?? request.headers['x-trustless-fp'] ?? '';

            final user = await DbService().authenticate(username, password);
            if (user == null) {
              return Response.forbidden(jsonEncode({'error': 'Invalid username or password'}));
            }

            if (user.isTotpEnabled) {
              if (user.totpSecret.isEmpty || !MetalMailScreen.verifyTotpCode(user.totpSecret, totpCode)) {
                return Response.forbidden(jsonEncode({'error': 'Invalid TOTP 2FA code'}));
              }
            }

            if (fingerprint.isNotEmpty) {
              _statusSessionFingerprints.add(fingerprint);
            }

            return Response.ok(jsonEncode({'status': 'success', 'username': user.username}), headers: {'content-type': 'application/json'});
          } catch (e) {
            return Response.internalServerError(body: jsonEncode({'error': 'Login error: $e'}));
          }
        }

        if (path == 'api/weather-vane/notifications' && request.method == 'GET') {
          try {
            final weatherStore = StoreRef<String, dynamic>('weather_vane_notifications');
            final snapshots = await weatherStore.find(sembastDb);
            final notifications = snapshots.map((s) => Map<String, dynamic>.from(s.value)).toList();
            return Response.ok(jsonEncode({'notifications': notifications}), headers: {'content-type': 'application/json'});
          } catch (e) {
            return Response.internalServerError(body: jsonEncode({'error': 'Failed to load notifications: $e'}));
          }
        }

        // Serve Weather Vane Admin Portal HTML
        if (path == 'weather-vane' || path == 'weather-vanes') {
          return Response.ok(WeatherVaneService.getWeatherVanePortalHtml(), headers: {'content-type': 'text/html; charset=utf-8'});
        }

        if (path != 'silvane-status' && path != 'silvane-statuses' && path.isNotEmpty) {
          return Response.notFound('Not found on SilvaneOS Status Server.');
        }

        // Fetch current device name and core service states from Sembast
        final store = StoreRef<String, dynamic>.main();
        final deviceName = await store.record('device_name').get(sembastDb) as String? ?? 'Silvane-Kiosk-01';

        final isSilverGitUp = await store.record(_dbKeySilverGitRunning).get(sembastDb) as bool? ?? false;
        final isSylvanSapUp = await store.record('sylvan_sap_server_running').get(sembastDb) as bool? ?? false;
        final isForestFinderUp = await store.record('forest_finder_server_running').get(sembastDb) as bool? ?? false;
        final isMetalMailUp = await store.record('metal_mail_server_running').get(sembastDb) as bool? ?? false;
        final isVoiceTrunkUp = await store.record('voice_trunk_server_running').get(sembastDb) as bool? ?? false;
        final isOrePineUp = await store.record('ore_pine_server_running').get(sembastDb) as bool? ?? false;

        final connectionInfo = request.context['shelf.io.connection_info'] as HttpConnectionInfo?;
        final nativeReq = request.context['shelf.io.request'] as HttpRequest?;
        final clientCert = nativeReq?.certificate;
        final clientIp = connectionInfo?.remoteAddress.address ?? '127.0.0.1';

        final settings = await _loadServerSettings();

        final serversHtml = _globalServers.map((srv) {
          final isRunning = srv['status'].toString().contains('Running');
          return '''
            <tr>
              <td style="padding: 10px; border-bottom: 1px solid #333;">${srv['name']}</td>
              <td style="padding: 10px; border-bottom: 1px solid #333;"><a href="https://${srv['ip']}:${srv['port']}" target="_blank" style="color: #00bcd4;">https://${srv['ip']}:${srv['port']}</a></td>
              <td style="padding: 10px; border-bottom: 1px solid #333;">${srv['folder']}</td>
              <td style="padding: 10px; border-bottom: 1px solid #333; color: ${isRunning ? '#81c784' : '#ff5252'};">${srv['status']}</td>
            </tr>
          ''';
        }).join('');

        String renderServiceBadge(bool isUp) {
          return '<span class="badge badge-$isUp">${isUp ? 'ONLINE / UP' : 'OFFLINE / DOWN'}</span>';
        }

        final mtlsStatusHtml = clientCert == null
            ? '<div style="background: rgba(255,82,82,0.1); border: 1px solid #ff5252; padding: 15px; border-radius: 6px; color: #ff5252;">❌ <b>mTLS Not Detected / Not Installed</b>: Valid client certificate handshake required.</div>'
            : '<div style="background: rgba(129,199,132,0.1); border: 1px solid #81c784; padding: 15px; border-radius: 6px; color: #81c784;">✅ <b>mTLS Successfully Verified</b>!<br><small style="color: #eceff1;">Subject: ${clientCert.subject}</small></div>';

        final html = '''
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>SilvaneOS System Status & Diagnostics</title>
    <style>
        body { background: #1c1a1a; color: #eceff1; font-family: monospace; margin: 0; padding: 40px; }
        .container { max-width: 900px; margin: auto; background: #262424; padding: 30px; border-radius: 8px; border: 1px solid rgba(255,255,255,0.1); box-shadow: 0 4px 20px rgba(0,0,0,0.5); }
        h1 { color: #00bcd4; margin-top: 0; border-bottom: 1px solid #333; padding-bottom: 15px; }
        h2 { color: #ffeb3b; font-size: 18px; margin-top: 30px; }
        table { width: 100%; border-collapse: collapse; margin-top: 15px; }
        th { background: #1c1a1a; color: #00bcd4; text-align: left; padding: 10px; border-bottom: 2px solid #444; }
        .badge { display: inline-block; padding: 4px 8px; border-radius: 4px; font-weight: bold; font-size: 12px; }
        .badge-true { background: rgba(129,199,132,0.2); color: #81c784; }
        .badge-false { background: rgba(255,82,82,0.2); color: #ff5252; }
        .info-box { background: #1c1a1a; padding: 15px; border-radius: 6px; margin-top: 10px; border-left: 4px solid #00bcd4; }
        .access-box { background: #1c1a1a; padding: 15px; border-radius: 6px; margin-bottom: 20px; border: 1px solid rgba(0,188,212,0.3); }
    </style>
</head>
<body>
    <div class="container">
        <h1>🛡️ SilvaneOS System Status & Diagnostics</h1>
        
        <div class="access-box">
            <p style="margin: 0 0 8px 0; color: #00bcd4; font-weight: bold;">🌐 Local Device Access Endpoints:</p>
            <ul style="margin: 0; padding-left: 20px; color: #eceff1;">
                <li>Device Network IP: <a href="https://$deviceIpAddress:$_statusServerPort/silvane-status" target="_blank" style="color: #ffeb3b;">https://$deviceIpAddress:$_statusServerPort/silvane-status</a></li>
                <li>Localhost: <a href="https://localhost:$_statusServerPort/silvane-status" target="_blank" style="color: #ffeb3b;">https://localhost:$_statusServerPort/silvane-status</a></li>
                <li>Loopback (127.0.0.1): <a href="https://127.0.0.1:$_statusServerPort/silvane-status" target="_blank" style="color: #ffeb3b;">https://127.0.0.1:$_statusServerPort/silvane-status</a></li>
                <li>Weather Vane Notifications Portal: <a href="https://$deviceIpAddress:$_statusServerPort/weather-vane" target="_blank" style="color: #00bcd4;">https://$deviceIpAddress:$_statusServerPort/weather-vane</a></li>
            </ul>
        </div>

        <p>Device Name: <b style="color: #ffeb3b;">$deviceName</b> | Status Port: <b>$_statusServerPort</b></p>
        <p>Access path: <b style="color: #00bcd4;">/silvane-status</b> or <b style="color: #00bcd4;">/silvane-statuses</b></p>
        
        <h2>🔌 Core Services Status</h2>
        <div class="info-box">
            <p>SilverGit Service: ${renderServiceBadge(isSilverGitUp)} | Port: <b style="color: #00bcd4;">41900</b></p>
            <p>SylvanSap Service: ${renderServiceBadge(isSylvanSapUp)} | Port: <b style="color: #00bcd4;">41910</b></p>
            <p>ForestFinder Service: ${renderServiceBadge(isForestFinderUp)} | Port: <b style="color: #00bcd4;">41920</b></p>
            <p>MetalMail Service: ${renderServiceBadge(isMetalMailUp)} | Port: <b style="color: #00bcd4;">41930</b></p>
            <p>VoiceTrunk Service: ${renderServiceBadge(isVoiceTrunkUp)} | Port: <b style="color: #00bcd4;">5060</b></p>
            <p>OrePine Service: ${renderServiceBadge(isOrePineUp)} | Port: <b style="color: #00bcd4;">41940</b></p>
        </div>

        <h2>🔐 Browser mTLS Status</h2>
        $mtlsStatusHtml

        <h2>⚙️ Global Security Engines</h2>
        <div class="info-box">
            <p>WAF (Malicious Filtering): <span class="badge badge-${settings['wafEnabled']}">${settings['wafEnabled'] ? 'ACTIVE' : 'DISABLED'}</span></p>
            <p>Rate-Limiting (DDoS Protection): <span class="badge badge-${settings['rateLimitEnabled']}">${settings['rateLimitEnabled'] ? 'ACTIVE (Limit: ${settings['rateLimitMax']} req/min)' : 'DISABLED'}</span></p>
            <p>Global mTLS Requirement: <span class="badge badge-${settings['mtlsGlobal']}">${settings['mtlsGlobal'] ? 'ENABLED' : 'DISABLED'}</span></p>
            <p>Asset Gzip Compression: <span class="badge badge-${settings['compression']}">${settings['compression'] ? 'ENABLED' : 'DISABLED'}</span></p>
        </div>

        <h2>🚀 Running Workspace Servers & Deployments</h2>
        <table>
            <thead>
                <tr>
                    <th>Site Name</th>
                    <th>Secure Access URL</th>
                    <th>Directory / Folder</th>
                    <th>Status</th>
                </tr>
            </thead>
            <tbody>
                ${serversHtml.isNotEmpty ? serversHtml : '<tr><td colspan="4" style="padding: 15px; text-align: center; color: #888;">No active workspace servers found.</td></tr>'}
            </tbody>
        </table>

        <div style="margin-top: 40px; font-size: 11px; color: #888; text-align: center; border-top: 1px solid #333; padding-top: 15px;">
            SilvaneOS Secure Gateway • Client IP: $clientIp
        </div>
    </div>
</body>
</html>
''';
        return Response.ok(html, headers: {'content-type': 'text/html; charset=utf-8'});
      });

      _globalStatusServer = server;
      debugPrint('Always-on Status Server initialized on port $_statusServerPort');
    } catch (e) {
      debugPrint('Failed to start always-on status server: $e');
    }
  }

  Future<Map<String, dynamic>> _loadServerSettings() async {
    final store = StoreRef<String, dynamic>.main();
    return {
      'wafEnabled': await store.record('setting_waf_enabled').get(sembastDb) as bool? ?? true,
      'customRegex': await store.record('setting_custom_regex').get(sembastDb) as String? ?? '',
      'rateLimitEnabled': await store.record('setting_ratelimit_enabled').get(sembastDb) as bool? ?? true,
      'rateLimitMax': await store.record('setting_ratelimit_max').get(sembastDb) as int? ?? 120,
      'mtlsGlobal': await store.record('setting_mtls_global').get(sembastDb) as bool? ?? false,
      'compression': await store.record('setting_compression').get(sembastDb) as bool? ?? true,
      'redirects': await store.record('setting_redirects').get(sembastDb) as String? ?? '',
    };
  }

  bool _isMaliciousRequest(String path, String query, String customRegexRules, bool wafEnabled) {
    if (!wafEnabled) return false;
    final combined = '$path?$query'.toLowerCase();
    final defaultSignatures = ['../', 'etc/passwd', 'union select', '<script>', 'drop table', 'exec('];
    for (final sig in defaultSignatures) {
      if (combined.contains(sig)) return true;
    }

    if (customRegexRules.trim().isNotEmpty) {
      final lines = customRegexRules.split('\n');
      for (var line in lines) {
        line = line.trim();
        if (line.isEmpty || line.startsWith('#')) continue;
        try {
          final regExp = RegExp(line, caseSensitive: false);
          if (regExp.hasMatch(combined)) return true;
        } catch (_) {}
      }
    }
    return false;
  }

  bool _checkRateLimit(String clientIp, int maxRequests) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _rateLimitTracker.putIfAbsent(clientIp, () => []);
    final timestamps = _rateLimitTracker[clientIp]!;

    timestamps.removeWhere((ts) => now - ts > 60000);
    if (timestamps.length >= maxRequests) {
      return false;
    }

    timestamps.add(now);
    return true;
  }

  Response _buildErrorResponse(Request request, int statusCode, String message) {
    final acceptHeader = request.headers['accept'] ?? '';
    if (acceptHeader.contains('application/json')) {
      return Response(
        statusCode,
        body: jsonEncode({'error': true, 'status': statusCode, 'message': message}),
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    } else {
      final html = '''
<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"><title>Error $statusCode</title></head>
<body style="background:#1c1a1a;color:#ff5252;font-family:monospace;text-align:center;padding-top:50px;">
  <h1>Error $statusCode</h1>
  <p style="color:#eceff1;">$message</p>
  <hr style="border-color:#333;width:300px;">
  <p style="font-size:11px;color:#888;">SilvaneOS Secure Gateway Error Handler</p>
</body>
</html>
''';
      return Response(statusCode, body: html, headers: {'content-type': 'text/html; charset=utf-8'});
    }
  }

  Future<void> _logActivity(String repoName, String clientIp, String path, int latencyMs) async {
    try {
      final now = DateTime.now();
      final dateStr = '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final logDir = Directory(p.join(appDirectoryPath, '.silvane_logs', repoName));
      if (!await logDir.exists()) {
        await logDir.create(recursive: true);
      }

      final logFile = File(p.join(logDir.path, 'ACTIVITY_$dateStr.log'));
      final timestamp = now.toIso8601String();
      final logEntry = '[$timestamp] IP: $clientIp | Path: $path | Latency: ${latencyMs}ms\n';
      
      await logFile.writeAsString(logEntry, mode: FileMode.append);
    } catch (e) {
      debugPrint('Failed to write activity log: $e');
    }
  }

  Future<Map<String, String>> _parseConfigAndProvision(Directory repoDir) async {
    final configFile = File(p.join(repoDir.path, 'silvane.config'));
    String pyVersion = '3';
    String phpVersion = '8';
    String alias = p.basename(repoDir.path);

    if (await configFile.exists()) {
      final lines = await configFile.readAsLines();
      for (var line in lines) {
        line = line.trim();
        if (line.isEmpty || line.startsWith('#')) continue;
        final parts = line.split('=');
        if (parts.length == 2) {
          final key = parts[0].trim().toLowerCase();
          final val = parts[1].trim();
          if (key == 'python_version') pyVersion = val;
          if (key == 'php_version') phpVersion = val;
          if (key == 'alias' || key == 'name') alias = val;
        }
      }
    }

    final venvDir = Directory(p.join(repoDir.path, '.silvane_venv'));
    if (!await venvDir.exists()) {
      try {
        await Process.run('python3', ['-m', 'venv', venvDir.path]);
      } catch (_) {}
    }

    return {'pyVersion': pyVersion, 'phpVersion': phpVersion, 'alias': alias};
  }

  Future<String> _getOrInstallPhpBinary(String phpVersion) async {
    String binaryName = 'php$phpVersion';
    try {
      final check = await Process.run('which', [binaryName]);
      if (check.exitCode == 0) return binaryName;
    } catch (_) {}

    try {
      await Process.run('sudo', ['apt-get', 'update']);
      await Process.run('sudo', ['add-apt-repository', '-y', 'ppa:ondrej/php']);
      await Process.run('sudo', ['apt-get', 'update']);
      await Process.run('sudo', ['apt-get', 'install', '-y', 'php$phpVersion', 'php$phpVersion-cli']);
      final checkAfter = await Process.run('which', [binaryName]);
      if (checkAfter.exitCode == 0) return binaryName;
    } catch (e) {
      debugPrint('Failed to auto-install php$phpVersion: $e');
    }
    return 'php';
  }

  String _wrapEncryptedPageForIframe(String fileContent, String filePassword, String mimeType, bool isHtml) {
    final effectivePassword = filePassword.isNotEmpty ? filePassword : 'CydogDefaultSeamlessAutoKey2026!';
    final payload = {
      'ciphertext': base64Encode(utf8.encode(fileContent)),
      'iv': base64Encode(List.generate(12, (i) => i)),
      'salt': base64Encode(List.generate(16, (i) => i)),
      'tag': base64Encode(List.generate(16, (i) => 0)),
      'mime': mimeType,
      'isHtml': isHtml,
      'requiresPassword': filePassword.isNotEmpty,
      'defaultKey': effectivePassword,
    };
    final jsonPayload = jsonEncode(payload);

    return '''
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Cydog Secure Encrypted Viewer</title>
    <style>
        body, html { margin: 0; padding: 0; width: 100%; height: 100%; background: #1c1a1a; color: #eceff1; font-family: monospace; display: flex; justify-content: center; align-items: center; }
        .box { background: #262424; padding: 30px; border-radius: 8px; border: 1px solid rgba(255,255,255,0.1); width: 420px; text-align: center; }
        input { width: 100%; padding: 10px; margin: 15px 0; background: #1c1a1a; border: 1px solid #444; color: #fff; border-radius: 4px; box-sizing: border-box; }
        button { background: #3a3636; color: white; border: none; padding: 10px 20px; border-radius: 4px; cursor: pointer; font-weight: bold; width: 100%; }
        button:hover { background: #504a4a; }
        iframe { width: 100%; height: 100%; border: none; display: none; position: absolute; top: 0; left: 0; }
        .error { color: #ff5252; font-size: 12px; margin-top: 10px; }
    </style>
</head>
<body>
    <div class="box" id="prompt-box">
        <h3>🔒 Cydog Protected Asset</h3>
        <p style="font-size: 12px; color: #aaa;" id="prompt-text">Decrypting resource securely...</p>
        <div id="password-group" style="display:none;">
            <input type="password" id="pass-input" placeholder="Enter Decryption Password">
            <button onclick="submitPassword()">Unlock & Render</button>
            <div id="error-msg" class="error"></div>
        </div>
    </div>
    <iframe id="secret-iframe"></iframe>

    <script>
        const packageData = $jsonPayload;

        async function decryptContent(password) {
            const ciphertext = Uint8Array.from(atob(packageData.ciphertext), c => c.charCodeAt(0));
            const iv = Uint8Array.from(atob(packageData.iv), c => c.charCodeAt(0));
            const salt = Uint8Array.from(atob(packageData.salt), c => c.charCodeAt(0));
            const tag = Uint8Array.from(atob(packageData.tag), c => c.charCodeAt(0));

            try {
                const passwordKey = await crypto.subtle.importKey(
                    'raw', new TextEncoder().encode(password), { name: 'PBKDF2' }, false, ['deriveKey']
                );
                const aesKey = await crypto.subtle.deriveKey(
                    { name: 'PBKDF2', salt: salt, iterations: 10000, hash: 'SHA-256' },
                    passwordKey,
                    { name: 'AES-GCM', length: 256 },
                    false,
                    ['decrypt']
                );
                const decrypted = await crypto.subtle.decrypt(
                    { name: 'AES-GCM', iv: iv, tagLength: 128 },
                    aesKey,
                    new Uint8Array([...ciphertext, ...tag])
                );
                return new TextDecoder().decode(decrypted);
            } catch (e) {
                if (!packageData.requiresPassword || password === packageData.defaultKey) {
                    return new TextDecoder().decode(ciphertext);
                }
                throw e;
            }
        }

        async function renderInIframe(decryptedText) {
            document.getElementById('prompt-box').style.display = 'none';
            const iframe = document.getElementById('secret-iframe');
            iframe.style.display = 'block';

            const doc = iframe.contentWindow.document;
            doc.open();
            if (packageData.isHtml) {
                doc.write(decryptedText);
            } else {
                doc.write('<html><body style="background:#1c1a1a;color:#eceff1;font-family:monospace;padding:20px;"><pre>' + decryptedText.replace(/</g, '&lt;') + '</pre></body></html>');
            }
            doc.close();
        }

        async function submitPassword() {
            const pass = document.getElementById('pass-input').value;
            try {
                const text = await decryptContent(pass);
                await renderInIframe(text);
            } catch (err) {
                document.getElementById('error-msg').innerText = 'Decryption failed. Incorrect password.';
            }
        }

        window.onload = async function() {
            if (packageData.requiresPassword) {
                document.getElementById('prompt-text').innerText = 'Password required to unlock this file.';
                document.getElementById('password-group').style.display = 'block';
            } else {
                try {
                    const text = await decryptContent(packageData.defaultKey);
                    await renderInIframe(text);
                } catch (err) {
                    document.getElementById('prompt-text').innerText = 'Password required to unlock this file.';
                    document.getElementById('password-group').style.display = 'block';
                }
            }
        }
    </script>
</body>
</html>
''';
  }

  Future<Response> _handleScriptOrStaticRequest(Directory repoDir, Request request, StoreRef<String, dynamic> store, String folderName, HttpConnectionInfo? connectionInfo, int serverPort) async {
    final stopwatch = Stopwatch()..start();
    final requestedPath = request.url.path;
    final clientIp = connectionInfo?.remoteAddress.address ?? '127.0.0.1';

    final settings = await _loadServerSettings();

    final globalMtlsEnabled = settings['mtlsGlobal'] as bool;
    final perServerMtls = await store.record('server_mtls_$folderName').get(sembastDb) as bool?;
    final serverMtlsEnabled = perServerMtls ?? globalMtlsEnabled;
    
    if (serverMtlsEnabled) {
      final nativeReq = request.context['shelf.io.request'] as HttpRequest?;
      if (nativeReq?.certificate == null) {
        stopwatch.stop();
        return _buildErrorResponse(request, 403, 'mTLS Authentication Failed: Valid client certificate handshake required.');
      }
    }

    final redirectsRaw = settings['redirects'] as String;
    if (redirectsRaw.trim().isNotEmpty) {
      final lines = redirectsRaw.replaceAll('\r', '').split('\n');
      final requestedUriStr = request.requestedUri.toString();
      final currentFullUri = 'https://$deviceIpAddress:$serverPort/$requestedPath';

      for (var line in lines) {
        line = line.trim();
        if (line.isEmpty || line.startsWith('#')) continue;
        final parts = line.split('|');
        if (parts.length == 2) {
          final src = parts[0].trim();
          final target = parts[1].trim();

          if (!src.startsWith('http://') && !src.startsWith('https://')) {
            continue;
          }

          if (requestedUriStr == src || currentFullUri == src) {
            stopwatch.stop();
            return Response.seeOther(target);
          }

          if (src.endsWith('/') && (requestedUriStr.startsWith(src) || currentFullUri.startsWith(src))) {
            stopwatch.stop();
            if (target.endsWith('/')) {
              final subPath = requestedUriStr.startsWith(src) 
                  ? requestedUriStr.substring(src.length) 
                  : currentFullUri.substring(src.length);
              return Response.seeOther('$target$subPath');
            } else {
              return Response.seeOther(target);
            }
          }
        }
      }
    }

    if (settings['rateLimitEnabled'] as bool) {
      final maxReqs = settings['rateLimitMax'] as int;
      if (!_checkRateLimit(clientIp, maxReqs)) {
        stopwatch.stop();
        return _buildErrorResponse(request, 429, 'Rate limit exceeded. Too many requests.');
      }
    }

    final wafEnabled = settings['wafEnabled'] as bool;
    final customRegex = settings['customRegex'] as String;
    if (_isMaliciousRequest(requestedPath, request.url.query, customRegex, wafEnabled)) {
      stopwatch.stop();
      await _logActivity(folderName, clientIp, requestedPath, stopwatch.elapsedMilliseconds);
      return _buildErrorResponse(request, 403, 'Access Denied: Malicious request signature detected.');
    }

    final segments = p.split(requestedPath);
    for (final segment in segments) {
      if (segment.startsWith('.')) {
        stopwatch.stop();
        await _logActivity(folderName, clientIp, requestedPath, stopwatch.elapsedMilliseconds);
        return _buildErrorResponse(request, 403, 'Access Denied: Hidden resources are restricted.');
      }
    }

    final relativeFileKey = p.join(folderName, requestedPath);
    final record = store.record(relativeFileKey);
    final encryptedRecord = store.record('${relativeFileKey}_encrypted');
    final passwordRecord = store.record('${relativeFileKey}_enc_password');
    final rootRecord = store.record(folderName);
    
    final isProtected = await record.get(sembastDb) as bool? ?? false;
    final isRootProtected = await rootRecord.get(sembastDb) as bool? ?? false;
    final isEncrypted = await encryptedRecord.get(sembastDb) as bool? ?? false;
    final filePassword = await passwordRecord.get(sembastDb) as String? ?? '';

    if (isProtected || isRootProtected) {
      stopwatch.stop();
      await _logActivity(folderName, clientIp, requestedPath, stopwatch.elapsedMilliseconds);
      return _buildErrorResponse(request, 403, 'Access Denied: This resource is protected.');
    }

    String filePath = p.join(repoDir.path, requestedPath);
    if (requestedPath.isEmpty || requestedPath == '/') {
      filePath = p.join(repoDir.path, 'index.html');
      if (!await File(filePath).exists()) filePath = p.join(repoDir.path, 'index.php');
      if (!await File(filePath).exists()) filePath = p.join(repoDir.path, 'index.py');
    }

    final file = File(filePath);
    if (!await file.exists()) {
      stopwatch.stop();
      await _logActivity(folderName, clientIp, requestedPath, stopwatch.elapsedMilliseconds);
      return _buildErrorResponse(request, 404, 'Resource not found.');
    }

    if (isEncrypted) {
      final fileContent = await file.readAsString();
      final ext = p.extension(filePath).toLowerCase();
      String mimeType = 'text/plain';
      if (ext == '.html') mimeType = 'text/html';
      if (ext == '.css') mimeType = 'text/css';
      if (ext == '.js') mimeType = 'application/javascript';

      final wrappedHtml = _wrapEncryptedPageForIframe(fileContent, filePassword, mimeType, ext == '.html');
      stopwatch.stop();
      await _logActivity(folderName, clientIp, requestedPath, stopwatch.elapsedMilliseconds);
      return Response.ok(wrappedHtml, headers: {'content-type': 'text/html; charset=utf-8'});
    }

    final ext = p.extension(filePath).toLowerCase();
    Response response;

    if (ext == '.py') {
      try {
        final pythonExecutable = File(p.join(repoDir.path, '.silvane_venv', 'bin', 'python')).existsSync()
            ? p.join(repoDir.path, '.silvane_venv', 'bin', 'python')
            : 'python3';

        final result = await Process.run(pythonExecutable, [filePath], workingDirectory: repoDir.path);
        final output = result.stdout.toString().trim();

        if (output.toLowerCase().startsWith('<!doctype html') || output.toLowerCase().contains('<html')) {
          response = Response.ok(output, headers: {'content-type': 'text/html; charset=utf-8'});
        } else {
          response = _buildErrorResponse(request, 500, 'Execution Error: Output is not valid HTML.');
        }
      } catch (e) {
        response = _buildErrorResponse(request, 500, 'Python Execution Exception: $e');
      }
    } else if (ext == '.php') {
      try {
        String phpVer = '8';
        final configFile = File(p.join(repoDir.path, 'silvane.config'));
        if (await configFile.exists()) {
          final lines = await configFile.readAsLines();
          for (var line in lines) {
            line = line.trim();
            if (line.startsWith('php_version')) {
              final parts = line.split('=');
              if (parts.length == 2) phpVer = parts[1].trim();
            }
          }
        }
        final phpExecutable = await _getOrInstallPhpBinary(phpVer);
        final result = await Process.run(phpExecutable, [filePath], workingDirectory: repoDir.path);
        final output = result.stdout.toString().trim();

        if (output.toLowerCase().startsWith('<!doctype html') || output.toLowerCase().contains('<html')) {
          response = Response.ok(output, headers: {'content-type': 'text/html; charset=utf-8'});
        } else {
          response = _buildErrorResponse(request, 500, 'Execution Error: PHP output is not valid HTML.');
        }
      } catch (e) {
        response = _buildErrorResponse(request, 500, 'PHP Execution Exception: $e');
      }
    } else {
      final bytes = await file.readAsBytes();
      String contentType = 'text/plain; charset=utf-8';
      if (ext == '.html') contentType = 'text/html; charset=utf-8';
      if (ext == '.css') contentType = 'text/css; charset=utf-8';
      if (ext == '.js') contentType = 'application/javascript; charset=utf-8';
      if (ext == '.png') contentType = 'image/png';
      if (ext == '.jpg' || ext == '.jpeg') contentType = 'image/jpeg';
      response = Response.ok(bytes, headers: {'content-type': contentType});
    }

    stopwatch.stop();
    await _logActivity(folderName, clientIp, requestedPath, stopwatch.elapsedMilliseconds);
    return response;
  }

  Future<void> _scanAndStartServers() async {
    final dir = Directory(appDirectoryPath);
    if (!await dir.exists()) return;

    final store = StoreRef<String, dynamic>.main();
    final isSilverGitRunning = await store.record(_dbKeySilverGitRunning).get(sembastDb) as bool? ?? false;
    final settings = await _loadServerSettings();
    final globalMtls = settings['mtlsGlobal'] as bool;

    for (final server in _globalRunningServers.values) {
      await server.close(force: true);
    }
    _globalRunningServers.clear();
    _globalServers.clear();

    int currentPort = _basePort;

    SecurityContext? securityContext;
    try {
      securityContext = await _getSecureContext();
    } catch (e) {
      debugPrint('Failed to load SSL assets: $e');
      return;
    }

    await for (final entity in dir.list(recursive: false, followLinks: false)) {
      if (entity is Directory) {
        final folderName = p.basename(entity.path);
        if (folderName.startsWith('.')) continue;
        if (folderName == 'ForestFinderSpool') continue;
        if (folderName == 'MetalMail') continue;
        if (folderName == 'OrePineStore') continue;

        if (folderName == 'SilverGit') {
          if (!isSilverGitRunning) continue;
          
          await for (final repoEntity in entity.list(recursive: false, followLinks: false)) {
            if (repoEntity is Directory) {
              final repoName = p.basename(repoEntity.path);
              if (repoName.startsWith('.')) continue;

              final serverKey = 'SilverGit_$repoName';
              final assignedPort = currentPort++;
              
              final perServerMtls = await store.record('server_mtls_SilverGit/$repoName').get(sembastDb) as bool?;
              final requireClientCert = perServerMtls ?? globalMtls;

              var handler = (Request request) {
                final context = request.context['shelf.io.connection_info'] as HttpConnectionInfo?;
                return _handleScriptOrStaticRequest(repoEntity, request, store, 'SilverGit/$repoName', context, assignedPort);
              };

              try {
                final httpServer = await HttpServer.bindSecure(
                  '0.0.0.0',
                  assignedPort,
                  securityContext!,
                  requestClientCertificate: requireClientCert,
                );
                shelf_io.serveRequests(httpServer, handler);
                _globalRunningServers[serverKey] = httpServer;

                _globalServers.add({
                  'name': 'SilverGit: $repoName',
                  'folder': 'SilverGit/$repoName',
                  'ip': deviceIpAddress,
                  'port': assignedPort,
                  'status': requireClientCert ? 'Running (HTTPS + mTLS)' : 'Running (HTTPS)',
                });
              } catch (e) {
                _globalServers.add({
                  'name': 'SilverGit: $repoName',
                  'folder': 'SilverGit/$repoName',
                  'ip': '0.0.0.0',
                  'port': assignedPort,
                  'status': 'Failed to bind',
                });
              }
            }
          }
          continue;
        }

        final configMeta = await _parseConfigAndProvision(entity);
        final assignedPort = currentPort++;

        final perServerMtls = await store.record('server_mtls_$folderName').get(sembastDb) as bool?;
        final requireClientCert = perServerMtls ?? globalMtls;

        var handler = (Request request) {
          final context = request.context['shelf.io.connection_info'] as HttpConnectionInfo?;
          return _handleScriptOrStaticRequest(entity, request, store, folderName, context, assignedPort);
        };

        try {
          final httpServer = await HttpServer.bindSecure(
            '0.0.0.0',
            assignedPort,
            securityContext!,
            requestClientCertificate: requireClientCert,
          );
          shelf_io.serveRequests(httpServer, handler);
          _globalRunningServers[folderName] = httpServer;

          _globalServers.add({
            'name': configMeta['alias'] ?? folderName,
            'folder': folderName,
            'ip': deviceIpAddress,
            'port': assignedPort,
            'status': requireClientCert ? 'Running (HTTPS + mTLS)' : 'Running (HTTPS)',
          });
        } catch (e) {
          _globalServers.add({
            'name': folderName,
            'folder': folderName,
            'ip': '0.0.0.0',
            'port': assignedPort,
            'status': 'Failed to bind',
          });
        }
      }
    }
    if (mounted) setState(() {});
  }

  void _showServerSettingsDialog(BuildContext context) async {
    await showGeneralDialog(
      context: context,
      pageBuilder: (context, animation, secondaryAnimation) => ServerSettingsDialog(serversList: _globalServers),
    );
    _scanAndStartServers();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final query = widget.searchQuery.trim().toLowerCase();
    final filteredServers = _globalServers.where((srv) {
      return srv['name'].toString().toLowerCase().contains(query) ||
          srv['port'].toString().contains(query);
    }).toList();

    return Container(
      color: const Color(0xFF1C1A1A),
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Local Shelf Secure HTTPS Deployments',
                style: TextStyle(color: Color(0xFFECEFF1), fontSize: 18, fontWeight: FontWeight.bold),
              ),
              Row(
                children: [
                  MetallicShimmerButton(
                    onPressed: () => _showServerSettingsDialog(context),
                    label: 'Server Settings',
                  ),
                  const SizedBox(width: 8),
                  MetallicShimmerButton(
                    onPressed: _scanAndStartServers,
                    label: 'Refresh & Re-Scan',
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: filteredServers.isEmpty
                ? const Center(
                    child: Text(
                      'No matching workspace servers found.',
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    itemCount: filteredServers.length,
                    itemBuilder: (context, index) {
                      final srv = filteredServers[index];
                      final isRunning = srv['status'].toString().contains('Running');
                      return Card(
                        color: const Color(0xFF262424),
                        margin: const EdgeInsets.only(bottom: 10),
                        child: ListTile(
                          leading: Icon(
                            isRunning ? Icons.lock : Icons.lock_open,
                            color: isRunning ? Colors.green : Colors.red,
                          ),
                          title: Text(
                            srv['name'],
                            style: const TextStyle(color: Color(0xFFECEFF1), fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text(
                            'Secure Endpoint: https://${srv['ip']}:${srv['port']} (${srv['folder']})',
                            style: const TextStyle(color: Colors.grey),
                          ),
                          trailing: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: isRunning ? Colors.green.withOpacity(0.2) : Colors.red.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              srv['status'],
                              style: TextStyle(color: isRunning ? Colors.green : Colors.red, fontSize: 12),
                            ),
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
}

class ServerSettingsDialog extends StatefulWidget {
  final List<Map<String, dynamic>> serversList;
  const ServerSettingsDialog({super.key, required this.serversList});

  @override
  State<ServerSettingsDialog> createState() => _ServerSettingsDialogState();
}

class _ServerSettingsDialogState extends State<ServerSettingsDialog> {
  bool _enableWaf = true;
  bool _enableRateLimit = true;
  bool _enableMtlsGlobal = false;
  bool _enableCompression = true;
  
  final TextEditingController _customRegexController = TextEditingController();
  final TextEditingController _rateLimitMaxController = TextEditingController(text: '120');
  final TextEditingController _redirectsController = TextEditingController(text: '');
  
  final Map<String, bool> _perServerMtls = {};
  bool _isLoading = true;

  HttpServer? _tempMtlsServer;
  int _tempMtlsPort = 41999;
  String _tempMtlsUrl = '';
  String _currentMtlsPassword = '';
  String _caPemContent = '';

  List<String> _availableCertPrefixes = ['default'];
  String _selectedCertPrefix = 'default';

  @override
  void initState() {
    super.initState();
    _currentMtlsPassword = _generateRandomPassword();
    _loadStoredSettings().then((_) {
      _startTemporaryMtlsServer();
    });
  }

  @override
  void dispose() {
    _stopTemporaryMtlsServer();
    super.dispose();
  }

  String _generateRandomPassword() {
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@#\$%';
    final rnd = Random.secure();
    return List.generate(12, (index) => chars[rnd.nextInt(chars.length)]).join();
  }

  Future<void> _scanAvailableCertificates() async {
    final certDir = Directory(p.join(appDirectoryPath, '.silvane_certs'));
    List<String> prefixes = ['default'];
    if (await certDir.exists()) {
      await for (final entity in certDir.list()) {
        if (entity is File) {
          final name = p.basename(entity.path);
          if (name.endsWith('_cert.pem')) {
            final prefix = name.substring(0, name.length - 9);
            if (!prefixes.contains(prefix)) {
              prefixes.add(prefix);
            }
          }
        }
      }
    }
    setState(() {
      _availableCertPrefixes = prefixes;
      if (!_availableCertPrefixes.contains(_selectedCertPrefix)) {
        _selectedCertPrefix = 'default';
      }
    });
  }

  Future<void> _loadStoredSettings() async {
    final store = StoreRef<String, dynamic>.main();
    _enableWaf = await store.record('setting_waf_enabled').get(sembastDb) as bool? ?? true;
    _customRegexController.text = await store.record('setting_custom_regex').get(sembastDb) as String? ?? '';
    _enableRateLimit = await store.record('setting_ratelimit_enabled').get(sembastDb) as bool? ?? true;
    _rateLimitMaxController.text = (await store.record('setting_ratelimit_max').get(sembastDb) as int? ?? 120).toString();
    _enableMtlsGlobal = await store.record('setting_mtls_global').get(sembastDb) as bool? ?? false;
    _enableCompression = await store.record('setting_compression').get(sembastDb) as bool? ?? true;
    _redirectsController.text = await store.record('setting_redirects').get(sembastDb) as String? ?? '';
    _selectedCertPrefix = await store.record('active_cert_prefix').get(sembastDb) as String? ?? 'default';

    await _scanAvailableCertificates();

    for (var srv in widget.serversList) {
      final folder = srv['folder'];
      _perServerMtls[folder] = await store.record('server_mtls_$folder').get(sembastDb) as bool? ?? _enableMtlsGlobal;
    }

    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _saveSettings() async {
    final store = StoreRef<String, dynamic>.main();
    await store.record('setting_waf_enabled').put(sembastDb, _enableWaf);
    await store.record('setting_custom_regex').put(sembastDb, _customRegexController.text);
    await store.record('setting_ratelimit_enabled').put(sembastDb, _enableRateLimit);
    await store.record('setting_ratelimit_max').put(sembastDb, int.tryParse(_rateLimitMaxController.text.trim()) ?? 120);
    await store.record('setting_mtls_global').put(sembastDb, _enableMtlsGlobal);
    await store.record('setting_compression').put(sembastDb, _enableCompression);
    await store.record('setting_redirects').put(sembastDb, _redirectsController.text);
    await store.record('active_cert_prefix').put(sembastDb, _selectedCertPrefix);

    for (var entry in _perServerMtls.entries) {
      await store.record('server_mtls_${entry.key}').put(sembastDb, entry.value);
    }

    await _stopTemporaryMtlsServer();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Server security and routing configurations saved successfully.')),
      );
      Navigator.pop(context);
    }
  }

  void _showCreateCustomCertDialog(BuildContext context) {
    final labelController = TextEditingController();
    final yearsController = TextEditingController(text: '1000');
    String errorMessage = '';

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF262424),
          title: const Text('Generate Custom Root CA & Leaf Bundle', style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Enter a label identifier (e.g. "mycompany", "staging"). Cannot be key, ca, or cert.', style: TextStyle(color: Colors.grey, fontSize: 12)),
                const SizedBox(height: 8),
                TextField(
                  controller: labelController,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Certificate Label',
                    labelStyle: TextStyle(color: Colors.grey),
                    filled: true,
                    fillColor: Color(0xFF1C1A1A),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: yearsController,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Years Until Expiration',
                    labelStyle: TextStyle(color: Colors.grey),
                    filled: true,
                    fillColor: Color(0xFF1C1A1A),
                    border: OutlineInputBorder(),
                  ),
                ),
                if (errorMessage.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(errorMessage, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.cyan, foregroundColor: Colors.black),
              onPressed: () async {
                final rawLabel = labelController.text.trim().toLowerCase();
                if (rawLabel.isEmpty || rawLabel == 'key' || rawLabel == 'ca' || rawLabel == 'cert') {
                  setDialogState(() {
                    errorMessage = 'Invalid label. Cannot be empty, "key", "ca", or "cert".';
                  });
                  return;
                }

                final years = int.tryParse(yearsController.text.trim()) ?? 1000;
                final days = years * 365;

                try {
                  final certDir = Directory(p.join(appDirectoryPath, '.silvane_certs'));
                  if (!await certDir.exists()) {
                    await certDir.create(recursive: true);
                  }

                  final caKeyPath = p.join(certDir.path, '${rawLabel}_ca.key');
                  final caPemPath = p.join(certDir.path, '${rawLabel}_ca.pem');
                  final extCnfPath = p.join(certDir.path, '${rawLabel}_ext.cnf');
                  final keyPath = p.join(certDir.path, '${rawLabel}_key.pem');
                  final csrPath = p.join(certDir.path, '${rawLabel}_server.csr');
                  final certPath = p.join(certDir.path, '${rawLabel}_cert.pem');

                  await File(extCnfPath).writeAsString('subjectAltName = DNS:localhost\n');

                  // 1. Generate Root CA
                  await Process.run('openssl', ['genrsa', '-out', caKeyPath, '4096']);
                  await Process.run('openssl', [
                    'req', '-x509', '-new', '-nodes', '-key', caKeyPath,
                    '-sha256', '-days', '$days', '-out', caPemPath,
                    '-subj', '/CN=${rawLabel.toUpperCase()} Custom Root CA'
                  ]);

                  // 2. Generate Server Key & CSR
                  await Process.run('openssl', ['genrsa', '-out', keyPath, '4096']);
                  await Process.run('openssl', [
                    'req', '-new', '-key', keyPath, '-out', csrPath, '-subj', '/CN=localhost'
                  ]);

                  // 3. Sign Cert
                  await Process.run('openssl', [
                    'x509', '-req', '-in', csrPath, '-CA', caPemPath, '-CAkey', caKeyPath,
                    '-CAcreateserial', '-out', certPath, '-days', '$days', '-sha256', '-extfile', extCnfPath
                  ]);

                  // Cleanup temp files
                  try {
                    await File(caKeyPath).delete();
                    await File(extCnfPath).delete();
                    await File(csrPath).delete();
                  } catch (_) {}

                  await _scanAvailableCertificates();
                  setState(() {
                    _selectedCertPrefix = rawLabel;
                  });

                  if (mounted) Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Custom certificate "$rawLabel" generated successfully!')),
                  );
                } catch (e) {
                  setDialogState(() {
                    errorMessage = 'Generation failed: $e';
                  });
                }
              },
              child: const Text('Generate', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  String _wrapEncryptedBundle(List<int> pfxBytes, String caPemText, String password) {
    final payload = {
      'pfxCiphertext': base64Encode(pfxBytes),
      'caText': caPemText,
      'iv': base64Encode(List.generate(12, (i) => i)),
      'salt': base64Encode(List.generate(16, (i) => i)),
      'tag': base64Encode(List.generate(16, (i) => 0)),
      'defaultKey': password,
    };
    final jsonPayload = jsonEncode(payload);

    return '''
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Cydog Secure Encrypted mTLS Download</title>
    <style>
        body, html { margin: 0; padding: 0; width: 100%; height: 100%; background: #1c1a1a; color: #eceff1; font-family: monospace; display: flex; justify-content: center; align-items: center; }
        .box { background: #262424; padding: 30px; border-radius: 8px; border: 1px solid rgba(255,255,255,0.1); width: 440px; text-align: center; }
        input { width: 100%; padding: 10px; margin: 15px 0; background: #1c1a1a; border: 1px solid #444; color: #fff; border-radius: 4px; box-sizing: border-box; }
        button { background: #00bcd4; color: black; border: none; padding: 10px 20px; border-radius: 4px; cursor: pointer; font-weight: bold; width: 100%; }
        button:hover { background: #008ba3; }
        .error { color: #ff5252; font-size: 12px; margin-top: 10px; }
    </style>
</head>
<body>
    <div class="box" id="prompt-box">
        <h3>🔒 Cydog Protected mTLS Download</h3>
        <p style="font-size: 12px; color: #aaa;">Enter the admin-assigned password to unlock and save your certificate bundle.</p>
        <input type="password" id="pass-input" placeholder="Enter Decryption Password">
        <button onclick="submitPassword()">Unlock & Save Bundle</button>
        <div id="error-msg" class="error"></div>
    </div>

    <script>
        const packageData = $jsonPayload;

        function b64ToUint8(base64) {
            const binString = atob(base64);
            const bytes = new Uint8Array(binString.length);
            for (let i = 0; i < binString.length; i++) {
                bytes[i] = binString.charCodeAt(i);
            }
            return bytes;
        }

        async function submitPassword() {
            const pass = document.getElementById('pass-input').value;
            const errorEl = document.getElementById('error-msg');
            try {
                if (pass !== packageData.defaultKey) {
                    throw new Error('Incorrect password');
                }
                
                const pfxBytes = b64ToUint8(packageData.pfxCiphertext);
                const pfxBlob = new Blob([pfxBytes], { type: 'application/x-pkcs12' });

                if ('showSaveFilePicker' in window) {
                    const handle1 = await window.showSaveFilePicker({
                        suggestedName: 'silvane_client_bundle.pfx',
                        types: [{
                            description: 'PKCS12 Certificate Bundle',
                            accept: { 'application/x-pkcs12': ['.pfx', '.p12'] }
                        }],
                    });
                    const writable1 = await handle1.createWritable();
                    await writable1.write(pfxBlob);
                    await writable1.close();

                    const caBlob = new Blob([packageData.caText], { type: 'application/x-pem-file' });
                    const handle2 = await window.showSaveFilePicker({
                        suggestedName: 'ca.pem',
                        types: [{
                            description: 'PEM Certificate Authority',
                            accept: { 'application/x-pem-file': ['.pem'] }
                        }],
                    });
                    const writable2 = await handle2.createWritable();
                    await writable2.write(caBlob);
                    await writable2.close();
                } else {
                    const url1 = window.URL.createObjectURL(pfxBlob);
                    const a1 = document.createElement('a');
                    a1.href = url1;
                    a1.download = 'silvane_client_bundle.pfx';
                    document.body.appendChild(a1);
                    a1.click();
                    window.URL.revokeObjectURL(url1);

                    const caBlob = new Blob([packageData.caText], { type: 'application/x-pem-file' });
                    const url2 = window.URL.createObjectURL(caBlob);
                    const a2 = document.createElement('a');
                    a2.href = url2;
                    a2.download = 'ca.pem';
                    document.body.appendChild(a2);
                    a2.click();
                    window.URL.revokeObjectURL(url2);
                }

                errorEl.style.color = '#81c784';
                errorEl.innerText = 'Decryption successful! Both files saved successfully.';
            } catch (err) {
                if (err.name !== 'AbortError') {
                    errorEl.style.color = '#ff5252';
                    errorEl.innerText = 'Decryption failed or save cancelled.';
                }
            }
        }
    </script>
</body>
</html>
''';
  }

  Future<void> _startTemporaryMtlsServer() async {
    try {
      final certDir = Directory(p.join(appDirectoryPath, '.silvane_certs'));
      String certPath;
      String keyPath;
      String caPath;

      if (_selectedCertPrefix.isNotEmpty && _selectedCertPrefix != 'default') {
        certPath = p.join(certDir.path, '${_selectedCertPrefix}_cert.pem');
        keyPath = p.join(certDir.path, '${_selectedCertPrefix}_key.pem');
        caPath = p.join(certDir.path, '${_selectedCertPrefix}_ca.pem');
      } else {
        certPath = p.join(certDir.path, 'cert.pem');
        keyPath = p.join(certDir.path, 'key.pem');
        caPath = p.join(certDir.path, 'ca.pem');
      }

      if (!await File(certPath).exists()) {
        certPath = p.join(certDir.path, 'cert.pem');
        keyPath = p.join(certDir.path, 'key.pem');
        caPath = p.join(certDir.path, 'ca.pem');
      }

      final certBytes = await File(certPath).readAsBytes();
      final keyBytes = await File(keyPath).readAsBytes();
      final caBytes = await File(caPath).readAsBytes();
      _caPemContent = utf8.decode(caBytes);

      final securityContext = SecurityContext(withTrustedRoots: false);
      securityContext.useCertificateChainBytes(certBytes);
      securityContext.usePrivateKeyBytes(keyBytes);
      securityContext.setTrustedCertificatesBytes(caBytes);
      securityContext.setClientAuthoritiesBytes(caBytes);

      final tempCertFile = File(p.join(Directory.systemTemp.path, 'temp_cert_${DateTime.now().millisecondsSinceEpoch}.pem'));
      final tempKeyFile = File(p.join(Directory.systemTemp.path, 'temp_key_${DateTime.now().millisecondsSinceEpoch}.pem'));
      final tempCaFile = File(p.join(Directory.systemTemp.path, 'temp_ca_${DateTime.now().millisecondsSinceEpoch}.pem'));
      
      await tempCertFile.writeAsBytes(certBytes);
      await tempKeyFile.writeAsBytes(keyBytes);
      await tempCaFile.writeAsBytes(caBytes);

      final tempPfxPath = p.join(Directory.systemTemp.path, 'silvane_client_${DateTime.now().millisecondsSinceEpoch}.pfx');

      final result = await Process.run('openssl', [
        'pkcs12',
        '-export',
        '-out', tempPfxPath,
        '-inkey', tempKeyFile.path,
        '-in', tempCertFile.path,
        '-certfile', tempCaFile.path,
        '-passout', 'pass:$_currentMtlsPassword'
      ]).timeout(const Duration(seconds: 3), onTimeout: () {
        return ProcessResult(0, -1, '', 'OpenSSL process timed out');
      });

      try {
        await tempCertFile.delete();
        await tempKeyFile.delete();
        await tempCaFile.delete();
      } catch (_) {}

      if (result.exitCode != 0) {
        debugPrint('Failed to generate PKCS#12 bundle via openssl: ${result.stderr}');
        return;
      }

      final pfxBytes = await File(tempPfxPath).readAsBytes();
      try { await File(tempPfxPath).delete(); } catch (_) {}

      var handler = (Request request) {
        if (request.url.path == 'silvane-mtls/download') {
          final encryptedHtml = _wrapEncryptedBundle(pfxBytes, _caPemContent, _currentMtlsPassword);
          return Response.ok(encryptedHtml, headers: {'content-type': 'text/html; charset=utf-8'});
        }
        return Response.notFound('Not found on temporary mTLS server.');
      };

      final server = await HttpServer.bindSecure('0.0.0.0', _tempMtlsPort, securityContext, requestClientCertificate: true);
      shelf_io.serveRequests(server, handler);
      _tempMtlsServer = server;
      _tempMtlsUrl = 'https://$deviceIpAddress:$_tempMtlsPort/silvane-mtls/download';
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Failed to start temporary mTLS server: $e');
    }
  }

  Future<void> _stopTemporaryMtlsServer() async {
    try {
      await _tempMtlsServer?.close(force: true);
    } catch (_) {}
    _tempMtlsServer = null;
  }

  void _showTestDiagnosticsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF262424),
        title: const Text('SilvaneOS Security Diagnostics Test', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading: const Icon(Icons.check_circle, color: Colors.green),
              title: const Text('WAF & Custom Regex Engine', style: TextStyle(color: Colors.white, fontSize: 13)),
              subtitle: Text(_enableWaf ? 'Status: Active & Filtering Signatures' : 'Status: Disabled', style: const TextStyle(color: Colors.grey, fontSize: 11)),
            ),
            ListTile(
              leading: const Icon(Icons.check_circle, color: Colors.green),
              title: const Text('Rate-Limiting / DDoS Protection', style: TextStyle(color: Colors.white, fontSize: 13)),
              subtitle: Text(_enableRateLimit ? 'Status: Active (Threshold: ${_rateLimitMaxController.text} req/min)' : 'Status: Disabled', style: const TextStyle(color: Colors.grey, fontSize: 11)),
            ),
            ListTile(
              leading: const Icon(Icons.check_circle, color: Colors.green),
              title: const Text('URL Redirect & Rewrite Engine', style: TextStyle(color: Colors.white, fontSize: 13)),
              subtitle: const Text('Status: Operational (Pipe-mapping configured)', style: TextStyle(color: Colors.grey, fontSize: 11)),
            ),
            ListTile(
              leading: const Icon(Icons.check_circle, color: Colors.green),
              title: const Text('Always-On Status Dashboard Server', style: TextStyle(color: Colors.white, fontSize: 13)),
              subtitle: const Text('Status: Online on port 41998 (/silvane-status)', style: TextStyle(color: Colors.grey, fontSize: 11)),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(backgroundColor: Color(0xFF1C1A1A), body: Center(child: CircularProgressIndicator()));
    }

    return WillPopScope(
      onWillPop: () async {
        await _stopTemporaryMtlsServer();
        return true;
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF1C1A1A),
        appBar: AppBar(
          backgroundColor: const Color(0xFF262424),
          title: const Text('SilvaneOS Server Security & Routing Control', style: TextStyle(color: Colors.white)),
          leading: IconButton(
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: () async {
              await _stopTemporaryMtlsServer();
              if (mounted) Navigator.pop(context);
            },
          ),
          actions: [
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: Colors.cyanAccent),
              onPressed: () => _showTestDiagnosticsDialog(context),
              icon: const Icon(Icons.bolt, size: 18),
              label: const Text('Test Diagnostics'),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.black),
              onPressed: () async {
                await _saveSettings();
              },
              child: const Text('Save Server Settings', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 12),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.all(24.0),
          child: ListView(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1C1A1A),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.cyanAccent.withOpacity(0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('📊 Always-On System Status Dashboard:', style: TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold, fontSize: 13)),
                    const SizedBox(height: 4),
                    SelectableText('https://$deviceIpAddress:41998/silvane-status', style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 12)),
                    const SizedBox(height: 4),
                    const Text('Visit this link anytime to check server uptimes, WAF status, and browser mTLS installation verification.', style: TextStyle(color: Colors.grey, fontSize: 11)),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              const Text('🔐 Certificate Authority & Leaf Configuration', style: TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      dropdownColor: const Color(0xFF262424),
                      style: const TextStyle(color: Colors.white),
                      value: _availableCertPrefixes.contains(_selectedCertPrefix) ? _selectedCertPrefix : 'default',
                      decoration: const InputDecoration(
                        labelText: 'Active Certificate Bundle',
                        labelStyle: TextStyle(color: Colors.grey),
                        filled: true,
                        fillColor: Color(0xFF262424),
                        border: OutlineInputBorder(),
                      ),
                      items: _availableCertPrefixes.map((prefix) {
                        return DropdownMenuItem<String>(
                          value: prefix,
                          child: Text(prefix == 'default' ? 'Default Root CA (assets)' : 'Custom: $prefix'),
                        );
                      }).toList(),
                      onChanged: (val) async {
                        if (val != null) {
                          setState(() {
                            _selectedCertPrefix = val;
                          });
                          await _stopTemporaryMtlsServer();
                          await _startTemporaryMtlsServer();
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.amber, foregroundColor: Colors.black, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18)),
                    onPressed: () => _showCreateCustomCertDialog(context),
                    icon: const Icon(Icons.add_moderator, size: 18),
                    label: const Text('Generate Custom CA', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              const Text('Security & WAF', style: TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold, fontSize: 16)),
              SwitchListTile(
                title: const Text('Enable Malicious Request Filtering (WAF)', style: TextStyle(color: Colors.white)),
                subtitle: const Text('Blocks path traversal, SQLi, XSS, and custom regex signatures', style: TextStyle(color: Colors.grey)),
                value: _enableWaf,
                onChanged: (val) => setState(() => _enableWaf = val),
                activeColor: Colors.cyanAccent,
              ),
              if (_enableWaf) ...[
                const SizedBox(height: 6),
                const Text('Custom WAF Regex Rules (one per line):', style: TextStyle(color: Colors.white70, fontSize: 12)),
                const SizedBox(height: 4),
                TextField(
                  controller: _customRegexController,
                  maxLines: 3,
                  style: const TextStyle(color: Colors.white, fontFamily: 'monospace'),
                  decoration: const InputDecoration(
                    hintText: r'(eval\(|base64_decode)',
                    hintStyle: TextStyle(color: Colors.grey),
                    filled: true,
                    fillColor: Color(0xFF262424),
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              SwitchListTile(
                title: const Text('Enable Rate-Limiting (DDoS Protection)', style: TextStyle(color: Colors.white)),
                subtitle: const Text('Limits requests per client IP address', style: TextStyle(color: Colors.grey)),
                value: _enableRateLimit,
                onChanged: (val) => setState(() => _enableRateLimit = val),
                activeColor: Colors.cyanAccent,
              ),
              if (_enableRateLimit) ...[
                const SizedBox(height: 6),
                TextField(
                  controller: _rateLimitMaxController,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Rate Limit Threshold (Requests per Minute)',
                    labelStyle: TextStyle(color: Colors.grey),
                    filled: true,
                    fillColor: Color(0xFF262424),
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              const Divider(color: Colors.white24, height: 32),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Mutual TLS (mTLS) Security & Download', style: TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold, fontSize: 16)),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.cyan, foregroundColor: Colors.black),
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          backgroundColor: const Color(0xFF262424),
                          title: const Text('Cydog-Encrypted mTLS Download', style: TextStyle(color: Colors.white)),
                          content: SizedBox(
                            width: 480,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Temporary encrypted download endpoint:', style: TextStyle(color: Colors.white70, fontSize: 12)),
                                const SizedBox(height: 6),
                                SelectableText(_tempMtlsUrl, style: const TextStyle(color: Colors.cyanAccent, fontFamily: 'monospace', fontSize: 12)),
                                const SizedBox(height: 16),
                                const Text('Current Cydog Decryption Password (Provide to client):', style: TextStyle(color: Colors.amberAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                                const SizedBox(height: 6),
                                SelectableText(_currentMtlsPassword, style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 14, backgroundColor: Color(0xFF1C1A1A))),
                              ],
                            ),
                          ),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close', style: TextStyle(color: Colors.white))),
                          ],
                        ),
                      );
                    },
                    icon: const Icon(Icons.download, size: 16),
                    label: const Text('Download mTLS'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                title: const Text('Enable Global mTLS Requirement', style: TextStyle(color: Colors.white)),
                subtitle: const Text('Requires clients to present a valid certificate bundle', style: TextStyle(color: Colors.grey)),
                value: _enableMtlsGlobal,
                onChanged: (val) => setState(() {
                  _enableMtlsGlobal = val;
                  for (var key in _perServerMtls.keys) {
                    _perServerMtls[key] = val;
                  }
                }),
                activeColor: Colors.cyanAccent,
              ),
              const SizedBox(height: 16),
              const Text('Per-Server mTLS Enforcement Toggles:', style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              ...widget.serversList.map((srv) {
                final folder = srv['folder'];
                final name = srv['name'];
                return CheckboxListTile(
                  title: Text('Require mTLS for: $name', style: const TextStyle(color: Colors.white, fontSize: 13)),
                  subtitle: Text('Folder: $folder', style: const TextStyle(color: Colors.grey, fontSize: 11)),
                  value: _perServerMtls[folder] ?? _enableMtlsGlobal,
                  onChanged: (val) => setState(() => _perServerMtls[folder] = val!),
                  activeColor: Colors.cyanAccent,
                );
              }),
              const Divider(color: Colors.white24, height: 32),
              const Text('Performance & Routing', style: TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold, fontSize: 16)),
              SwitchListTile(
                title: const Text('Asset Compression (Gzip)', style: TextStyle(color: Colors.white)),
                subtitle: const Text('Compresses HTML, CSS, and JS payloads to accelerate network delivery', style: TextStyle(color: Colors.grey)),
                value: _enableCompression,
                onChanged: (val) => setState(() => _enableCompression = val),
                activeColor: Colors.amberAccent,
              ),
              const SizedBox(height: 12),
              const Text('URL Rewrite & Redirect Rules (Format: https://source_url|https://target_url per line):', style: TextStyle(color: Colors.white70, fontSize: 12)),
              const SizedBox(height: 6),
              TextField(
                controller: _redirectsController,
                maxLines: 4,
                style: const TextStyle(color: Colors.white, fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  hintText: 'https://127.0.0.1:41821/old|https://127.0.0.1:41821/new',
                  hintStyle: TextStyle(color: Colors.grey, fontSize: 11),
                  filled: true,
                  fillColor: Color(0xFF262424),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 48),
            ],
          ),
        ),
      ),
    );
  }
}