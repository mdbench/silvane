import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:sembast/sembast.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:crypto/crypto.dart';
import 'main.dart';

class SilverGitScreen extends StatefulWidget {
  final String searchQuery;
  const SilverGitScreen({super.key, required this.searchQuery});

  @override
  State<SilverGitScreen> createState() => _SilverGitScreenState();

  // --- Static Server State & Methods (accessible globally) ---
  static HttpServer? _gitServer;
  static bool _isServerRunning = false;
  static bool _hasInitializedGitServer = false;
  
  static String _jwtSecret = 'silvane_secure_jwt_secret_key_2026_default';
  static final int _gitPort = 41900;
  static const String _dbKeySilverGitRunning = 'silver_git_server_running';
  static const String _dbKeyJwtSecret = 'silver_git_jwt_secret';

  /// Loads the persisted JWT secret from Sembast storage on boot, or creates one if it doesn't exist.
  static Future<void> _loadJwtSecretHeadless() async {
    try {
      final store = StoreRef<String, dynamic>.main();
      final savedSecret = await store.record(_dbKeyJwtSecret).get(sembastDb) as String?;
      if (savedSecret != null && savedSecret.isNotEmpty) {
        _jwtSecret = savedSecret;
      } else {
        _jwtSecret = 'silvane_secure_jwt_secret_key_2026_${DateTime.now().millisecondsSinceEpoch}';
        await store.record(_dbKeyJwtSecret).put(sembastDb, _jwtSecret);
      }
    } catch (e) {
      debugPrint('[SilverGit] Failed to load persisted JWT secret: $e');
    }
  }

  static String generateJwtToken() {
    final header = base64Url.encode(utf8.encode(jsonEncode({'alg': 'HS256', 'typ': 'JWT'}))).replaceAll('=', '');
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final payload = base64Url.encode(utf8.encode(jsonEncode({
      'sub': 'kiosk',
      'iat': now,
      'exp': now + 86400 * 365,
    }))).replaceAll('=', '');

    final signatureInput = '$header.$payload';
    final hmac = Hmac(sha256, utf8.encode(_jwtSecret));
    final digest = hmac.convert(utf8.encode(signatureInput));
    final signature = base64Url.encode(digest.bytes).replaceAll('=', '');

    return '$header.$payload.$signature';
  }

  static Future<void> resetJwtSecret() async {
    _jwtSecret = 'silvane_secure_jwt_secret_key_2026_${DateTime.now().millisecondsSinceEpoch}';
    try {
      final store = StoreRef<String, dynamic>.main();
      await store.record(_dbKeyJwtSecret).put(sembastDb, _jwtSecret);
    } catch (e) {
      debugPrint('[SilverGit] Failed to persist reset JWT secret: $e');
    }
  }

  static bool verifyJwtToken(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return false;

      final header = parts[0];
      final payload = parts[1];
      final signature = parts[2];

      final signatureInput = '$header.$payload';
      final hmac = Hmac(sha256, utf8.encode(_jwtSecret));
      final digest = hmac.convert(utf8.encode(signatureInput));
      final expectedSignature = base64Url.encode(digest.bytes).replaceAll('=', '');

      if (signature != expectedSignature) return false;

      String normalizedPayload = payload;
      while (normalizedPayload.length % 4 != 0) {
        normalizedPayload += '=';
      }
      final payloadMap = jsonDecode(utf8.decode(base64Url.decode(normalizedPayload))) as Map<String, dynamic>;
      final exp = payloadMap['exp'] as int?;
      if (exp == null) return false;

      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (now > exp) return false;

      return true;
    } catch (e) {
      debugPrint('[SilverGit] JWT verification error: $e');
      return false;
    }
  }

  /// Public static method to start the SilverGit server in the background on app boot if enabled.
  static Future<void> startServerIfEnabled() async {
    try {
      // 1. Ensure the base directory exists inline
      final dir = Directory(p.join(appDirectoryPath, 'SilverGit'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      final store = StoreRef<String, dynamic>.main();
      
      // 2. Check if persistently enabled by user
      final persistedState = await store.record(_dbKeySilverGitRunning).get(sembastDb) as bool? ?? false;
      if (!persistedState) return;
      
      // 3. Check Hours of Operation configuration from the Sembast 'system_time_config' store
      bool withinHours = true;
      try {
        final timeConfigStore = stringMapStoreFactory.store('system_time_config');
        final configMap = await timeConfigStore.record('config').get(sembastDb);
        if (configMap != null && configMap['schedules'] != null) {
          final schedules = Map<String, dynamic>.from(configMap['schedules'] as Map);
          final scheduleStr = schedules['SilverGit'] ?? '24/7 Active';
          
          if (!scheduleStr.toLowerCase().contains('24/7') && !scheduleStr.toLowerCase().contains('active')) {
            if (scheduleStr.contains('-')) {
              final parts = scheduleStr.split('-');
              if (parts.length == 2) {
                final now = DateTime.now();
                final currentMinutes = now.hour * 60 + now.minute;
                final startParts = parts[0].trim().split(':');
                final endParts = parts[1].trim().split(':');
                if (startParts.length == 2 && endParts.length == 2) {
                  final startMinutes = int.parse(startParts[0]) * 60 + int.parse(startParts[1]);
                  final endMinutes = int.parse(endParts[0]) * 60 + int.parse(endParts[1]);
                  
                  if (startMinutes <= endMinutes) {
                    withinHours = currentMinutes >= startMinutes && currentMinutes <= endMinutes;
                  } else {
                    withinHours = currentMinutes >= startMinutes || currentMinutes <= endMinutes;
                  }
                }
              }
            }
          }
        }
      } catch (_) {}

      // 4. Evaluate combined conditions
      final shouldBeRunning = persistedState && withinHours;

      if (shouldBeRunning && !_isServerRunning) {
        await _loadJwtSecretHeadless();
        await _startServerHeadless();
        debugPrint('[SilverGit] Server started automatically (Enabled & Within Hours).');
      } else if (!shouldBeRunning && _isServerRunning) {
        await _gitServer?.close(force: true);
        _gitServer = null;
        _isServerRunning = false;
        debugPrint('[SilverGit] Server stopped automatically (Disabled or Outside Hours).');
      }
    } catch (e) {
      debugPrint('[SilverGit] Failed to evaluate server state on schedule tick: $e');
    }
  }

  static Future<Directory> _getSilverGitDirHeadless() async {
    final dir = Directory(p.join(appDirectoryPath, 'SilverGit'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<void> _startServerHeadless() async {
    if (_isServerRunning) return;
    try {
      final certBytes = await rootBundle.load('assets/cert.pem');
      final keyBytes = await rootBundle.load('assets/key.pem');

      final securityContext = SecurityContext(withTrustedRoots: false);
      securityContext.useCertificateChainBytes(certBytes.buffer.asUint8List());
      securityContext.usePrivateKeyBytes(keyBytes.buffer.asUint8List());

      shelf.Handler handler = (shelf.Request request) async {
        final authHeader = request.headers['authorization'];
        bool isAuthenticated = false;

        if (authHeader != null && authHeader.startsWith('Bearer ')) {
          final token = authHeader.substring(7);
          if (verifyJwtToken(token)) {
            isAuthenticated = true;
          }
        }

        if (!isAuthenticated) {
          return shelf.Response.forbidden(
            jsonEncode({'error': '403 Forbidden: JWT token has expired or security key was reset'}),
            headers: {'content-type': 'application/json'},
          );
        }
        
        if (request.url.path == 'api/repos') {
          final rootDir = await _getSilverGitDirHeadless();
          final dirs = rootDir.listSync()
              .whereType<Directory>()
              .map((d) => p.basename(d.path))
              .where((name) => !name.startsWith('.'))
              .toList();
          return shelf.Response.ok(jsonEncode({'repositories': dirs}), headers: {'content-type': 'application/json'});
        }

        final segments = request.url.pathSegments;
        if (segments.isNotEmpty) {
          final repoName = segments.first;
          if (repoName.startsWith('.')) {
            return shelf.Response.notFound(jsonEncode({'error': 'Repository not found'}), headers: {'content-type': 'application/json'});
          }

          final rootDir = await _getSilverGitDirHeadless();
          final repoDir = Directory(p.join(rootDir.path, repoName));

          if (await repoDir.exists()) {
            final subPath = '/' + segments.join('/');
            final queryString = request.url.query;

            try {
              final bodyBytes = await request.read().expand((chunk) => chunk).toList();
              
              final process = await Process.start(
                '/usr/lib/git-core/git-http-backend',
                [],
                environment: {
                  'REQUEST_METHOD': request.method,
                  'GIT_PROJECT_ROOT': rootDir.path,
                  'PATH_INFO': subPath,
                  'QUERY_STRING': queryString,
                  'GIT_HTTP_EXPORT_ALL': '1',
                  'CONTENT_TYPE': request.headers['content-type'] ?? '',
                  'REMOTE_USER': 'kiosk',
                },
                runInShell: false,
              );

              if (bodyBytes.isNotEmpty) {
                process.stdin.add(bodyBytes);
              }
              await process.stdin.close();

              final outputBytes = await process.stdout.expand((chunk) => chunk).toList();
              final exitCode = await process.exitCode;

              int headerEndIndex = -1;
              List<int> separator = [13, 10, 13, 10];
              
              for (int i = 0; i <= outputBytes.length - 4; i++) {
                if (outputBytes[i] == 13 && outputBytes[i+1] == 10 && outputBytes[i+2] == 13 && outputBytes[i+3] == 10) {
                  headerEndIndex = i;
                  break;
                }
              }
              if (headerEndIndex == -1) {
                for (int i = 0; i <= outputBytes.length - 2; i++) {
                  if (outputBytes[i] == 10 && outputBytes[i+1] == 10) {
                    headerEndIndex = i;
                    separator = [10, 10];
                    break;
                  }
                }
              }

              final responseHeaders = <String, String>{};
              List<int> responseBody = outputBytes;

              if (headerEndIndex != -1) {
                final headerBytes = outputBytes.sublist(0, headerEndIndex);
                responseBody = outputBytes.sublist(headerEndIndex + separator.length);
                
                final headerString = utf8.decode(headerBytes, allowMalformed: true);
                for (var line in headerString.split(RegExp(r'\r?\n'))) {
                  final colonIndex = line.indexOf(':');
                  if (colonIndex != -1) {
                    final key = line.substring(0, colonIndex).trim().toLowerCase();
                    final value = line.substring(colonIndex + 1).trim();
                    if (key == 'status') continue;
                    responseHeaders[key] = value;
                  }
                }
              }

              if (!responseHeaders.containsKey('content-type')) {
                if (subPath.contains('info/refs')) {
                  responseHeaders['content-type'] = 'application/x-git-upload-pack-advertisement';
                } else if (subPath.contains('git-upload-pack')) {
                  responseHeaders['content-type'] = 'application/x-git-upload-pack-result';
                } else if (subPath.contains('git-receive-pack')) {
                  responseHeaders['content-type'] = 'application/x-git-receive-pack-result';
                } else {
                  responseHeaders['content-type'] = 'application/octet-stream';
                }
              }

              return shelf.Response(
                exitCode == 0 ? 200 : 500,
                body: responseBody,
                headers: responseHeaders,
              );
            } catch (e) {
              return shelf.Response.internalServerError(body: 'Git backend error: $e');
            }
          }
        }

        return shelf.Response.notFound(jsonEncode({'error': 'Repository not found'}), headers: {'content-type': 'application/json'});
      };

      _gitServer = await shelf_io.serve(
        handler,
        '0.0.0.0',
        _gitPort,
        securityContext: securityContext,
      );
      
      _isServerRunning = true;
      debugPrint('[SilverGit] Headless background server started on port $_gitPort.');
    } catch (e) {
      _isServerRunning = false;
      debugPrint('[SilverGit] Headless server start error: $e');
    }
  }
}

class _SilverGitScreenState extends State<SilverGitScreen> with AutomaticKeepAliveClientMixin {
  List<Directory> _repositories = [];
  Directory? _selectedRepo;
  List<FileSystemEntity> _repoFiles = [];
  String? _readmeContent;
  
  List<Map<String, String>> _commitLogs = [];
  Map<String, String>? _selectedCommitDetails;
  bool _isLoadingCommits = false;
  bool _isLoadingFiles = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scanRepositories();
    if (!SilverGitScreen._hasInitializedGitServer) {
      SilverGitScreen._hasInitializedGitServer = true;
      _loadPersistedServerState();
    }
  }

  Future<void> _loadPersistedServerState() async {
    try {
      await SilverGitScreen._loadJwtSecretHeadless();
      final store = StoreRef<String, dynamic>.main();
      final persistedState = await store.record(SilverGitScreen._dbKeySilverGitRunning).get(sembastDb) as bool? ?? false;
      if (persistedState) {
        await _toggleGitServer(true, silent: true);
      }
    } catch (e) {
      debugPrint('Failed to load persisted SilverGit state: $e');
    }
  }

  Future<void> _persistServerState(bool running) async {
    try {
      final store = StoreRef<String, dynamic>.main();
      await store.record(SilverGitScreen._dbKeySilverGitRunning).put(sembastDb, running);
    } catch (e) {
      debugPrint('Failed to save SilverGit state: $e');
    }
  }

  Future<Directory> _getSilverGitDir() async {
    return await SilverGitScreen._getSilverGitDirHeadless();
  }

  Future<void> _scanRepositories() async {
    final rootDir = await _getSilverGitDir();
    final entities = rootDir.listSync();
    final repos = <Directory>[];
    for (var entity in entities) {
      if (entity is Directory) {
        final repoName = p.basename(entity.path);
        if (repoName.startsWith('.')) continue;

        final gitDir = Directory(p.join(entity.path, '.git'));
        if (await gitDir.exists()) {
          try {
            await Process.run('git', ['config', 'http.uploadpack', 'true'], workingDirectory: entity.path);
            await Process.run('git', ['config', 'http.receivepack', 'true'], workingDirectory: entity.path);
            await Process.run('git', ['config', 'receive.denyCurrentBranch', 'updateInstead'], workingDirectory: entity.path);
            final exportOkFile = File(p.join(entity.path, '.git', 'git-daemon-export-ok'));
            if (!await exportOkFile.exists()) {
              await exportOkFile.create();
            }
          } catch (e) {
            debugPrint('Failed to configure repo $repoName:$e');
          }

          repos.add(entity);
        }
      }
    }
    if (mounted) {
      setState(() {
        _repositories = repos;
        if (_selectedRepo == null && repos.isNotEmpty) {
          _selectRepository(repos.first);
        }
      });
    }
  }

  Future<void> _toggleGitServer(bool enable, {bool silent = false}) async {
    if (enable) {
      try {
        await SilverGitScreen._startServerHeadless();
        await _persistServerState(true);
        if (mounted) setState(() {});

        if (!silent && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('SilverGit HTTPS server started on https://$deviceIpAddress:${SilverGitScreen._gitPort}')),
          );
        }
      } catch (e) {
        await _persistServerState(false);
        if (mounted) setState(() {});
      }
    } else {
      await SilverGitScreen._gitServer?.close(force: true);
      SilverGitScreen._gitServer = null;
      SilverGitScreen._isServerRunning = false;
      await _persistServerState(false);
      if (mounted) setState(() {});
      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('SilverGit server stopped.')),
        );
      }
    }
  }

  void _showJwtInstructionsDialog() {
    final token = SilverGitScreen.generateJwtToken();
    final tokenController = TextEditingController(text: token);
    final sampleRemoteCommand = 'git -c http.extraHeader="Authorization: Bearer $token" -c http.sslVerify=false remote add origin https://$deviceIpAddress:${SilverGitScreen._gitPort}/<RepositoryName>';
    final sampleCloneCommand = 'git -c http.extraHeader="Authorization: Bearer $token" -c http.sslVerify=false clone https://$deviceIpAddress:${SilverGitScreen._gitPort}/<RepositoryName>';
    final samplePushCommand = 'git -c http.extraHeader="Authorization: Bearer $token" -c http.sslVerify=false push origin main';
    final sampleSaveConfigCommand = 'git config http.extraHeader "Authorization: Bearer $token"\ngit config http.sslVerify false';

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF262424),
          title: const Row(
            children: [
              Icon(Icons.vpn_key, color: Colors.cyanAccent, size: 20),
              SizedBox(width: 8),
              Text('SilverGit Signed JWT & Instructions', style: TextStyle(color: Colors.white, fontSize: 16)),
            ],
          ),
          content: SizedBox(
            width: 580,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Cryptographically Signed JWT:', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: tokenController,
                    readOnly: true,
                    maxLines: 3,
                    style: const TextStyle(color: Colors.cyanAccent, fontFamily: 'monospace', fontSize: 11),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: const Color(0xFF1C1A1A),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent.shade700, foregroundColor: Colors.white),
                      onPressed: () async {
                        await SilverGitScreen.resetJwtSecret();
                        final newToken = SilverGitScreen.generateJwtToken();
                        setDialogState(() {
                          tokenController.text = newToken;
                        });
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('JWT Secret rotated! Previous SilverGit tokens have been expired.')),
                        );
                      },
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('Reset / Expire Old JWT Key'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('How to Connect Remotely (Push / Pull over HTTPS):', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  const Text(
                    'Ensure "Bearer " prefix is included in authorization headers:',
                    style: TextStyle(color: Colors.grey, fontSize: 11),
                  ),
                  const SizedBox(height: 10),
                  const Text('1. Clone a Repository:', style: TextStyle(color: Colors.amberAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: const Color(0xFF1C1A1A), borderRadius: BorderRadius.circular(6)),
                    child: SelectableText(sampleCloneCommand, style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 11)),
                  ),
                  const SizedBox(height: 10),
                  const Text('2. Add Remote to an Existing Local Folder:', style: TextStyle(color: Colors.amberAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: const Color(0xFF1C1A1A), borderRadius: BorderRadius.circular(6)),
                    child: SelectableText(sampleRemoteCommand, style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 11)),
                  ),
                  const SizedBox(height: 10),
                  const Text('3. Manual One-Time Push Command:', style: TextStyle(color: Colors.amberAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: const Color(0xFF1C1A1A), borderRadius: BorderRadius.circular(6)),
                    child: SelectableText(samplePushCommand, style: const TextStyle(color: Colors.cyanAccent, fontFamily: 'monospace', fontSize: 11)),
                  ),
                  const SizedBox(height: 10),
                  const Text('4. Permanent Local Repo Config (Recommended):', style: TextStyle(color: Colors.lightGreenAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: const Color(0xFF1C1A1A), borderRadius: BorderRadius.circular(6)),
                    child: SelectableText(sampleSaveConfigCommand, style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 11)),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createNewRepository(String name, String description) async {
    if (name.trim().isEmpty) return;
    try {
      final rootDir = await _getSilverGitDir();
      final repoDir = Directory(p.join(rootDir.path, name.trim()));
      if (await repoDir.exists()) {
        throw Exception('Repository already exists.');
      }
      await repoDir.create(recursive: true);

      await Process.run('git', ['init'], workingDirectory: repoDir.path);
      await Process.run('git', ['config', 'user.name', 'SilvaneKiosk'], workingDirectory: repoDir.path);
      await Process.run('git', ['config', 'user.email', 'kiosk@silvane.os'], workingDirectory: repoDir.path);
      await Process.run('git', ['config', 'http.uploadpack', 'true'], workingDirectory: repoDir.path);
      await Process.run('git', ['config', 'http.receivepack', 'true'], workingDirectory: repoDir.path);
      await Process.run('git', ['config', 'receive.denyCurrentBranch', 'updateInstead'], workingDirectory: repoDir.path);

      final exportOkFile = File(p.join(repoDir.path, '.git', 'git-daemon-export-ok'));
      await exportOkFile.create();

      final readmeFile = File(p.join(repoDir.path, 'README.md'));
      await readmeFile.writeAsString('# $name\n\n$description\n\nManaged by SilverGit HTTPS server.');

      await Process.run('git', ['add', 'README.md'], workingDirectory: repoDir.path);
      await Process.run('git', ['commit', '-m', 'chore: initial commit for $name'], workingDirectory: repoDir.path);

      await _scanRepositories();
      if (mounted) Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Successfully created repository "$name".')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error creating repo: $e'), backgroundColor: Colors.red.shade900),
      );
    }
  }

  Future<void> _deleteRepository(Directory repoDir) async {
    try {
      await repoDir.delete(recursive: true);
      setState(() {
        _selectedRepo = null;
        _repoFiles = [];
        _commitLogs = [];
        _readmeContent = null;
        _selectedCommitDetails = null;
      });
      await _scanRepositories();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Repository deleted successfully.')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to delete repository: $e'), backgroundColor: Colors.red.shade900),
      );
    }
  }

  Future<void> _selectRepository(Directory repo) async {
    setState(() {
      _selectedRepo = repo;
      _selectedCommitDetails = null;
      _isLoadingFiles = true;
      _isLoadingCommits = true;
    });

    final files = repo.listSync(recursive: false).where((e) => !p.basename(e.path).startsWith('.git')).toList();
    
    String? readme;
    final readmeFile = File(p.join(repo.path, 'README.md'));
    if (await readmeFile.exists()) {
      readme = await readmeFile.readAsString();
    }

    List<Map<String, String>> logs = [];
    try {
      final result = await Process.run(
        'git',
        ['log', '--pretty=format:%H|%an|%ad|%s', '--date=short', '-n', '25'],
        workingDirectory: repo.path,
      );
      if (result.exitCode == 0 && result.stdout.toString().isNotEmpty) {
        final lines = result.stdout.toString().trim().split('\n');
        for (var line in lines) {
          final parts = line.split('|');
          if (parts.length >= 4) {
            logs.add({
              'hash': parts[0],
              'author': parts[1],
              'date': parts[2],
              'message': parts[3],
            });
          }
        }
      }
    } catch (e) {
      debugPrint('Error loading git log: $e');
    }

    if (mounted) {
      setState(() {
        _repoFiles = files;
        _readmeContent = readme ?? '# No README found\nInitialize or add a README.md file to this repository.';
        _commitLogs = logs;
        _isLoadingFiles = false;
        _isLoadingCommits = false;
      });
    }
  }

  Future<void> _loadCommitDetails(String commitHash) async {
    if (_selectedRepo == null) return;
    try {
      final result = await Process.run(
        'git',
        ['show', commitHash],
        workingDirectory: _selectedRepo!.path,
      );
      if (result.exitCode == 0 && mounted) {
        setState(() {
          _selectedCommitDetails = {
            'hash': commitHash,
            'diff': result.stdout.toString(),
          };
        });
      }
    } catch (e) {
      debugPrint('Failed to load commit diff: $e');
    }
  }

  void _showCreateRepoDialog() {
    final nameController = TextEditingController();
    final descController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF262424),
        title: const Text('Create New SilverGit Repository', style: TextStyle(color: Colors.white)),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Repository Name',
                  labelStyle: TextStyle(color: Colors.white70),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: descController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Description / README Note',
                  labelStyle: TextStyle(color: Colors.white70),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.cyanAccent, foregroundColor: Colors.black),
            onPressed: () => _createNewRepository(nameController.text, descController.text),
            child: const Text('Create Repo'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      backgroundColor: const Color(0xFF1C1A1A),
      body: Row(
        children: [
          Container(
            width: 240,
            color: const Color(0xFF222020),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('SilverGit Repos', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                      IconButton(
                        icon: const Icon(Icons.add, color: Colors.cyanAccent, size: 18),
                        onPressed: _showCreateRepoDialog,
                        tooltip: 'New Repository',
                      ),
                    ],
                  ),
                ),
                Container(
                  margin: const EdgeInsets.all(8),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: SilverGitScreen._isServerRunning ? Colors.cyan.withOpacity(0.1) : Colors.black12,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: SilverGitScreen._isServerRunning ? Colors.cyanAccent.withOpacity(0.3) : Colors.white12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(SilverGitScreen._isServerRunning ? 'Server: Active' : 'Server: Stopped', style: TextStyle(color: SilverGitScreen._isServerRunning ? Colors.cyanAccent : Colors.grey, fontSize: 11, fontWeight: FontWeight.bold)),
                          Switch(
                            value: SilverGitScreen._isServerRunning,
                            onChanged: (val) => _toggleGitServer(val),
                            activeColor: Colors.cyanAccent,
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text('Port: ${SilverGitScreen._gitPort} (HTTPS)', style: const TextStyle(color: Colors.white60, fontSize: 10)),
                      const SizedBox(height: 4),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.cyanAccent,
                            side: const BorderSide(color: Colors.cyanAccent, width: 0.5),
                            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: _showJwtInstructionsDialog,
                          icon: const Icon(Icons.vpn_key, size: 12),
                          label: const Text('View JWT & Instructions', style: TextStyle(fontSize: 10)),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(color: Colors.white12),
                Expanded(
                  child: _repositories.isEmpty
                      ? const Center(child: Text('No repositories found.\nClick "+" to create one.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white38, fontSize: 11)))
                      : ListView.builder(
                          itemCount: _repositories.length,
                          itemBuilder: (context, index) {
                            final repo = _repositories[index];
                            final repoName = p.basename(repo.path);
                            final isSelected = _selectedRepo?.path == repo.path;
                            return ListTile(
                              selected: isSelected,
                              selectedTileColor: Colors.cyan.withOpacity(0.15),
                              leading: const Icon(Icons.folder, color: Colors.amber, size: 18),
                              title: Text(repoName, style: const TextStyle(color: Colors.white, fontSize: 12)),
                              onTap: () => _selectRepository(repo),
                              trailing: IconButton(
                                icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 14),
                                onPressed: () => _deleteRepository(repo),
                                tooltip: 'Delete Repo',
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          const VerticalDivider(width: 1, color: Colors.white12),
          
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: _selectedRepo == null
                  ? const Center(child: Text('Select a repository from the sidebar.', style: TextStyle(color: Colors.grey)))
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(p.basename(_selectedRepo!.path), style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                            Text('JWT Secure HTTPS Endpoint: https://$deviceIpAddress:${SilverGitScreen._gitPort}', style: const TextStyle(color: Colors.cyanAccent, fontSize: 11)),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF262424),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.white12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('README.md', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, fontSize: 12)),
                              const SizedBox(height: 6),
                              Text(_readmeContent ?? '', style: const TextStyle(color: Color(0xFFECEFF1), fontSize: 13)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        const Text('Repository Files & Folders', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                        const SizedBox(height: 8),
                        Expanded(
                          child: _isLoadingFiles
                              ? const Center(child: CircularProgressIndicator())
                              : _repoFiles.isEmpty
                                  ? const Center(child: Text('No files in repository root.', style: TextStyle(color: Colors.grey)))
                                  : ListView.builder(
                                      itemCount: _repoFiles.length,
                                      itemBuilder: (context, index) {
                                        final fileEntity = _repoFiles[index];
                                        final fileName = p.basename(fileEntity.path);
                                        final isDir = fileEntity is Directory;
                                        return ListTile(
                                          leading: Icon(isDir ? Icons.folder : Icons.insert_drive_file, color: isDir ? Colors.amber : Colors.cyanAccent, size: 16),
                                          title: Text(fileName, style: const TextStyle(color: Colors.white, fontSize: 12)),
                                          onTap: () async {
                                            if (!isDir && fileEntity is File) {
                                              final content = await fileEntity.readAsString();
                                              showDialog(
                                                context: context,
                                                builder: (context) => AlertDialog(
                                                  backgroundColor: const Color(0xFF262424),
                                                  title: Text(fileName, style: const TextStyle(color: Colors.white)),
                                                  content: SizedBox(
                                                    width: 500,
                                                    height: 400,
                                                    child: SingleChildScrollView(
                                                      child: Text(content, style: const TextStyle(color: Colors.white70, fontFamily: 'monospace', fontSize: 12)),
                                                    ),
                                                  ),
                                                  actions: [
                                                    TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close', style: TextStyle(color: Colors.white))),
                                                  ],
                                                ),
                                              );
                                            }
                                          },
                                        );
                                      },
                                    ),
                        ),
                      ],
                    ),
            ),
          ),
          const VerticalDivider(width: 1, color: Colors.white12),

          Container(
            width: 320,
            color: const Color(0xFF222020),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.all(12.0),
                  child: Text('Git Commit History', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                ),
                const Divider(color: Colors.white12, height: 1),
                Expanded(
                  child: _selectedRepo == null
                      ? const Center(child: Text('No repository selected.', style: TextStyle(color: Colors.white38, fontSize: 11)))
                      : _isLoadingCommits
                          ? const Center(child: CircularProgressIndicator())
                          : _commitLogs.isEmpty
                              ? const Center(child: Text('No commit history found.', style: TextStyle(color: Colors.white38, fontSize: 11)))
                              : ListView.builder(
                                  itemCount: _commitLogs.length,
                                  itemBuilder: (context, index) {
                                    final commit = _commitLogs[index];
                                    return InkWell(
                                      onTap: () => _loadCommitDetails(commit['hash']!),
                                      child: Container(
                                        padding: const EdgeInsets.all(10),
                                        decoration: BoxDecoration(
                                          border: const Border(bottom: BorderSide(color: Colors.white10)),
                                          color: _selectedCommitDetails?['hash'] == commit['hash'] ? Colors.cyan.withOpacity(0.1) : Colors.transparent,
                                        ),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(commit['message'] ?? '', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                                            const SizedBox(height: 4),
                                            Row(
                                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                              children: [
                                                Text(commit['author'] ?? '', style: const TextStyle(color: Colors.cyanAccent, fontSize: 10)),
                                                Text(commit['date'] ?? '', style: const TextStyle(color: Colors.grey, fontSize: 10)),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                ),
                if (_selectedCommitDetails != null) ...[
                  const Divider(color: Colors.white12),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12.0),
                    child: Text('Commit Diff / Changes', style: TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold, fontSize: 12)),
                  ),
                  SizedBox(
                    height: 150,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(12.0),
                      child: Text(
                        _selectedCommitDetails!['diff'] ?? '',
                        style: const TextStyle(color: Colors.white70, fontFamily: 'monospace', fontSize: 10),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}