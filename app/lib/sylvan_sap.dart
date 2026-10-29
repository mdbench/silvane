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

class SylvanSapScreen extends StatefulWidget {
  final String searchQuery;
  const SylvanSapScreen({super.key, required this.searchQuery});

  @override
  State<SylvanSapScreen> createState() => _SylvanSapScreenState();

  // --- Static Server State & Methods (accessible globally) ---
  static HttpServer? _sylvanServer;
  static bool _isServerRunning = false;
  static bool _hasInitializedServer = false;
  
  static String _jwtSecret = 'sylvan_sap_secure_jwt_key_2026_default';
  static final int _sylvanPort = 41910;
  static const String _dbKeySylvanRunning = 'sylvan_sap_server_running';
  static const String _dbKeyJwtSecret = 'sylvan_sap_jwt_secret';

  /// Loads the persisted JWT secret from Sembast storage on boot, or creates one if it doesn't exist.
  static Future<void> _loadJwtSecretHeadless() async {
    try {
      final store = StoreRef<String, dynamic>.main();
      final savedSecret = await store.record(_dbKeyJwtSecret).get(sembastDb) as String?;
      if (savedSecret != null && savedSecret.isNotEmpty) {
        _jwtSecret = savedSecret;
      } else {
        _jwtSecret = 'sylvan_sap_secure_jwt_key_2026_${DateTime.now().millisecondsSinceEpoch}';
        await store.record(_dbKeyJwtSecret).put(sembastDb, _jwtSecret);
      }
    } catch (e) {
      debugPrint('[SylvanSap] Failed to load persisted JWT secret: $e');
    }
  }

  static String generateJwtToken() {
    final header = base64Url.encode(utf8.encode(jsonEncode({'alg': 'HS256', 'typ': 'JWT'}))).replaceAll('=', '');
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final payload = base64Url.encode(utf8.encode(jsonEncode({
      'sub': 'sylvan_client',
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
    _jwtSecret = 'sylvan_sap_secure_jwt_key_2026_${DateTime.now().millisecondsSinceEpoch}';
    try {
      final store = StoreRef<String, dynamic>.main();
      await store.record(_dbKeyJwtSecret).put(sembastDb, _jwtSecret);
    } catch (e) {
      debugPrint('[SylvanSap] Failed to persist reset JWT secret: $e');
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
      debugPrint('[SylvanSap] JWT verification error: $e');
      return false;
    }
  }

  /// Public static method to start the SylvanSap server in the background on app boot if enabled.
  static Future<void> startServerIfEnabled() async {
    try {
      // 1. Ensure the base directory exists inline
      final dir = Directory(p.join(appDirectoryPath, 'SylvanSap'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      final store = StoreRef<String, dynamic>.main();
      
      // 2. Check if persistently enabled by user
      final persistedState = await store.record(_dbKeySylvanRunning).get(sembastDb) as bool? ?? false;
      if (!persistedState) return;
      
      // 3. Check Hours of Operation configuration from the Sembast 'system_time_config' store
      bool withinHours = true;
      try {
        final timeConfigStore = stringMapStoreFactory.store('system_time_config');
        final configMap = await timeConfigStore.record('config').get(sembastDb);
        if (configMap != null && configMap['schedules'] != null) {
          final schedules = Map<String, dynamic>.from(configMap['schedules'] as Map);
          final scheduleStr = schedules['SylvanSap'] ?? '24/7 Active';
          
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
        debugPrint('[SylvanSap] Server started automatically (Enabled & Within Hours).');
      } else if (!shouldBeRunning && _isServerRunning) {
        await _sylvanServer?.close(force: true);
        _sylvanServer = null;
        _isServerRunning = false;
        debugPrint('[SylvanSap] Server stopped automatically (Disabled or Outside Hours).');
      }
    } catch (e) {
      debugPrint('[SylvanSap] Failed to evaluate server state on schedule tick: $e');
    }
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

        final rootDir = Directory(p.join(appDirectoryPath, 'SylvanSap'));
        final segments = request.url.pathSegments;

        if (request.url.path == 'api/veins' || request.url.path == '') {
          if (await rootDir.exists()) {
            final dirs = rootDir.listSync()
                .whereType<Directory>()
                .map((d) => p.basename(d.path))
                .where((name) => !name.startsWith('.'))
                .toList();
            return shelf.Response.ok(jsonEncode({'sylvan_veins': dirs}), headers: {'content-type': 'application/json'});
          }
          return shelf.Response.ok(jsonEncode({'sylvan_veins': []}), headers: {'content-type': 'application/json'});
        }

        final relPath = segments.join('/');
        final targetFile = File(p.join(rootDir.path, relPath));
        final targetDir = Directory(p.join(rootDir.path, relPath));

        if (await targetFile.exists()) {
          final bytes = await targetFile.readAsBytes();
          final ext = p.extension(targetFile.path).toLowerCase();
          String contentType = 'application/octet-stream';
          if (ext == '.html') contentType = 'text/html; charset=utf-8';
          if (ext == '.css') contentType = 'text/css; charset=utf-8';
          if (ext == '.js') contentType = 'application/javascript; charset=utf-8';
          if (ext == '.txt') contentType = 'text/plain; charset=utf-8';
          
          if (request.method == 'PUT' || request.method == 'POST') {
            final parentDir = targetFile.parent;
            final parentName = p.basename(parentDir.path).toLowerCase();
            if (parentName.contains('immutable') || parentName.contains('sap_root')) {
              return shelf.Response.forbidden(jsonEncode({'error': 'Folder is locked Tree Sap (Read-Only)'}), headers: {'content-type': 'application/json'});
            }
            final bodyBytes = await request.read().expand((c) => c).toList();
            await targetFile.writeAsBytes(bodyBytes);
            return shelf.Response.ok(jsonEncode({'status': 'File updated successfully'}), headers: {'content-type': 'application/json'});
          }

          return shelf.Response.ok(bytes, headers: {'content-type': contentType});
        } else if (await targetDir.exists()) {
          if (request.method == 'POST') {
            final dirName = p.basename(targetDir.path).toLowerCase();
            if (dirName.contains('immutable') || dirName.contains('sap_root')) {
              return shelf.Response.forbidden(jsonEncode({'error': 'Cannot add files to Tree Sap (Read-Only)'}), headers: {'content-type': 'application/json'});
            }
            final fileName = request.headers['x-file-name'] ?? 'uploaded_asset';
            final newFile = File(p.join(targetDir.path, fileName));
            final bodyBytes = await request.read().expand((c) => c).toList();
            await newFile.writeAsBytes(bodyBytes);
            return shelf.Response.ok(jsonEncode({'status': 'File uploaded to vein successfully'}), headers: {'content-type': 'application/json'});
          }

          final subEntities = targetDir.listSync().map((e) => p.basename(e.path)).toList();
          return shelf.Response.ok(jsonEncode({'directory': relPath, 'contents': subEntities}), headers: {'content-type': 'application/json'});
        }

        return shelf.Response.notFound(jsonEncode({'error': 'Sylvan resource vein not found'}), headers: {'content-type': 'application/json'});
      };

      _sylvanServer = await shelf_io.serve(
        handler,
        '0.0.0.0',
        _sylvanPort,
        securityContext: securityContext,
      );
      
      _isServerRunning = true;
      debugPrint('[SylvanSap] Headless background server started on port $_sylvanPort.');
    } catch (e) {
      _isServerRunning = false;
      debugPrint('[SylvanSap] Headless server start error: $e');
    }
  }
}

class _SylvanSapScreenState extends State<SylvanSapScreen> with AutomaticKeepAliveClientMixin {
  Directory? _sylvanRootDir;
  List<FileSystemEntity> _sapFiles = [];
  Directory? _selectedFolder;
  List<FileSystemEntity> _selectedFolderContents = [];
  bool _isLoadingFiles = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _initializeSylvanDirectory();
    if (!SylvanSapScreen._hasInitializedServer) {
      SylvanSapScreen._hasInitializedServer = true;
      _loadPersistedServerState();
    }
  }

  Future<void> _loadPersistedServerState() async {
    try {
      await SylvanSapScreen._loadJwtSecretHeadless();
      final store = StoreRef<String, dynamic>.main();
      final persistedState = await store.record(SylvanSapScreen._dbKeySylvanRunning).get(sembastDb) as bool? ?? false;
      if (persistedState) {
        await _toggleSylvanServer(true, silent: true);
      }
    } catch (e) {
      debugPrint('Failed to load persisted SylvanSap state: $e');
    }
  }

  Future<void> _persistServerState(bool running) async {
    try {
      final store = StoreRef<String, dynamic>.main();
      await store.record(SylvanSapScreen._dbKeySylvanRunning).put(sembastDb, running);
    } catch (e) {
      debugPrint('Failed to save SylvanSap state: $e');
    }
  }

  Future<void> _initializeSylvanDirectory() async {
    final dir = Directory(p.join(appDirectoryPath, 'SylvanSap'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
      final sapRoot = Directory(p.join(dir.path, 'ImmutableSap_Root'));
      await sapRoot.create();
      await File(p.join(sapRoot.path, 'sap_core_spec.txt')).writeAsString('SylvanSap Immutable Vein Storage Node.\nProtected tree sap layer.');

      final writableDir = Directory(p.join(dir.path, 'VascularWorkspace'));
      await writableDir.create();
      await File(p.join(writableDir.path, 'index.html')).writeAsString('<html><body style="background:#1c1a1a;color:#81c784;font-family:monospace;"><h1>SylvanSap Live Web Stream</h1><p>Vascular transport route active.</p></body></html>');
    }
    setState(() {
      _sylvanRootDir = dir;
    });
    await _scanSylvanFiles();
  }

  Future<void> _scanSylvanFiles() async {
    if (_sylvanRootDir == null) return;
    setState(() => _isLoadingFiles = true);

    final entities = _sylvanRootDir!.listSync(recursive: false);
    final files = <FileSystemEntity>[];
    for (var entity in entities) {
      final name = p.basename(entity.path);
      if (name.startsWith('.')) continue;
      files.add(entity);
    }

    setState(() {
      _sapFiles = files;
      _isLoadingFiles = false;
      if (_selectedFolder == null && files.whereType<Directory>().isNotEmpty) {
        _selectFolder(files.whereType<Directory>().first);
      }
    });
  }

  void _selectFolder(Directory dir) {
    final contents = dir.listSync(recursive: false).where((e) {
      final name = p.basename(e.path);
      return !name.startsWith('.');
    }).toList();
    
    setState(() {
      _selectedFolder = dir;
      _selectedFolderContents = contents;
    });
  }

  bool _isTreeSapFolder(Directory dir) {
    final name = p.basename(dir.path);
    return name.toLowerCase().contains('immutable') || name.toLowerCase().contains('sap_root');
  }

  Future<void> _toggleSylvanServer(bool enable, {bool silent = false}) async {
    if (enable) {
      try {
        await SylvanSapScreen._startServerHeadless();
        await _persistServerState(true);
        if (mounted) setState(() {});

        if (!silent && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('SylvanSap HTTPS server started on https://$deviceIpAddress:${SylvanSapScreen._sylvanPort}')),
          );
        }
      } catch (e) {
        await _persistServerState(false);
        if (mounted) setState(() {});
      }
    } else {
      await SylvanSapScreen._sylvanServer?.close(force: true);
      SylvanSapScreen._sylvanServer = null;
      SylvanSapScreen._isServerRunning = false;
      await _persistServerState(false);
      if (mounted) setState(() {});
      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('SylvanSap server stopped.')),
        );
      }
    }
  }

  void _showJwtInstructionsDialog() {
    final token = SylvanSapScreen.generateJwtToken();
    final tokenController = TextEditingController(text: token);
    final sampleCurl = 'curl -k -H "Authorization: Bearer $token" https://$deviceIpAddress:${SylvanSapScreen._sylvanPort}/api/veins';

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF262424),
          title: const Row(
            children: [
              Icon(Icons.eco, color: Colors.lightGreenAccent, size: 20),
              SizedBox(width: 8),
              Text('SylvanSap JWT & Network Mount Guide', style: TextStyle(color: Colors.white, fontSize: 16)),
            ],
          ),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Bearer Authentication Token:', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: tokenController,
                    readOnly: true,
                    maxLines: 3,
                    style: const TextStyle(color: Colors.lightGreenAccent, fontFamily: 'monospace', fontSize: 11),
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
                        await SylvanSapScreen.resetJwtSecret();
                        final newToken = SylvanSapScreen.generateJwtToken();
                        setDialogState(() {
                          tokenController.text = newToken;
                        });
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('JWT Secret rotated! Previous Sylvan tokens have been expired.')),
                        );
                      },
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('Reset / Expire Old JWT Key'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('Remote Access & On-Demand Request Example:', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: const Color(0xFF1C1A1A), borderRadius: BorderRadius.circular(6)),
                    child: SelectableText(sampleCurl, style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 11)),
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

  Future<void> _createNewVeinFolder() async {
    final controller = TextEditingController();
    bool isTreeSap = false;

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF262424),
          title: const Text('Create New Sylvan Vein Folder', style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(labelText: 'Vein Folder Name', labelStyle: TextStyle(color: Colors.grey)),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                title: const Text('Lock as Tree Sap (Read-Only)', style: TextStyle(color: Colors.white)),
                subtitle: const Text('Prevents remote modification/uploads', style: TextStyle(color: Colors.grey, fontSize: 11)),
                value: isTreeSap,
                onChanged: (val) => setDialogState(() => isTreeSap = val),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.lightGreenAccent, foregroundColor: Colors.black),
              onPressed: () async {
                if (controller.text.trim().isNotEmpty && _sylvanRootDir != null) {
                  final folderName = isTreeSap ? 'ImmutableSap_${controller.text.trim()}' : controller.text.trim();
                  final newDir = Directory(p.join(_sylvanRootDir!.path, folderName));
                  if (!await newDir.exists()) {
                    await newDir.create();
                    await _scanSylvanFiles();
                  }
                }
                Navigator.pop(context);
              },
              child: const Text('Create Vein'),
            ),
          ],
        ),
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
            width: 260,
            color: const Color(0xFF222020),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('SylvanSap Veins', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                      IconButton(
                        icon: const Icon(Icons.add_box, color: Colors.lightGreenAccent, size: 18),
                        onPressed: _createNewVeinFolder,
                        tooltip: 'New Vein Folder',
                      ),
                    ],
                  ),
                ),
                Container(
                  margin: const EdgeInsets.all(8),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: SylvanSapScreen._isServerRunning ? Colors.green.withOpacity(0.1) : Colors.black12,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: SylvanSapScreen._isServerRunning ? Colors.lightGreenAccent.withOpacity(0.3) : Colors.white12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(SylvanSapScreen._isServerRunning ? 'Server: Active' : 'Server: Stopped', style: TextStyle(color: SylvanSapScreen._isServerRunning ? Colors.lightGreenAccent : Colors.grey, fontSize: 11, fontWeight: FontWeight.bold)),
                          Switch(
                            value: SylvanSapScreen._isServerRunning,
                            onChanged: (val) => _toggleSylvanServer(val),
                            activeColor: Colors.lightGreenAccent,
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text('Port: ${SylvanSapScreen._sylvanPort} (HTTPS)', style: const TextStyle(color: Colors.white60, fontSize: 10)),
                      const SizedBox(height: 4),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.lightGreenAccent,
                            side: const BorderSide(color: Colors.lightGreenAccent, width: 0.5),
                            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: _showJwtInstructionsDialog,
                          icon: const Icon(Icons.eco, size: 12),
                          label: const Text('View JWT & Mount Guide', style: TextStyle(fontSize: 10)),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(color: Colors.white12),
                Expanded(
                  child: _isLoadingFiles
                      ? const Center(child: CircularProgressIndicator())
                      : _sapFiles.isEmpty
                          ? const Center(child: Text('No Sylvan veins found.', style: TextStyle(color: Colors.white38, fontSize: 11)))
                          : ListView.builder(
                              itemCount: _sapFiles.length,
                              itemBuilder: (context, index) {
                                final entity = _sapFiles[index];
                                final name = p.basename(entity.path);
                                final isDir = entity is Directory;
                                final isLockedSap = isDir && _isTreeSapFolder(entity);
                                final isSelected = _selectedFolder?.path == entity.path;

                                return ListTile(
                                  selected: isSelected,
                                  selectedTileColor: Colors.green.withOpacity(0.15),
                                  leading: Icon(
                                    isLockedSap ? Icons.lock : (isDir ? Icons.folder_open : Icons.insert_drive_file),
                                    color: isLockedSap ? Colors.amber : Colors.lightGreenAccent,
                                    size: 18,
                                  ),
                                  title: Text(name, style: const TextStyle(color: Colors.white, fontSize: 12)),
                                  subtitle: Text(isLockedSap ? 'Tree Sap (Read-Only)' : 'Vascular Vein', style: const TextStyle(color: Colors.grey, fontSize: 10)),
                                  onTap: () {
                                    if (isDir) _selectFolder(entity as Directory);
                                  },
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
              child: _selectedFolder == null
                  ? const Center(child: Text('Select a Sylvan vein folder from the sidebar.', style: TextStyle(color: Colors.grey)))
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Vein: ${p.basename(_selectedFolder!.path)}', style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                            Text('Remote Samba-Mount Endpoint: https://$deviceIpAddress:${SylvanSapScreen._sylvanPort}/${p.basename(_selectedFolder!.path)}', style: const TextStyle(color: Colors.lightGreenAccent, fontSize: 11)),
                          ],
                        ),
                        const SizedBox(height: 16),
                        const Text('Vein Directory Contents', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                        const SizedBox(height: 8),
                        Expanded(
                          child: _selectedFolderContents.isEmpty
                              ? const Center(child: Text('This vein folder is empty.', style: TextStyle(color: Colors.grey)))
                              : ListView.builder(
                                  itemCount: _selectedFolderContents.length,
                                  itemBuilder: (context, index) {
                                    final item = _selectedFolderContents[index];
                                    final itemName = p.basename(item.path);
                                    final isSubDir = item is Directory;
                                    return ListTile(
                                      leading: Icon(isSubDir ? Icons.folder : Icons.insert_drive_file, color: isSubDir ? Colors.amberAccent : Colors.lightGreenAccent, size: 16),
                                      title: Text(itemName, style: const TextStyle(color: Colors.white, fontSize: 12)),
                                      subtitle: Text(item.path, style: const TextStyle(color: Colors.grey, fontSize: 10)),
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}