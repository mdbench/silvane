import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:sembast/sembast.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart' as shelf_router;
import 'package:crypto/crypto.dart';
import 'package:printing/printing.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf/pdf.dart';
import 'main.dart';

class ForestFinderScreen extends StatefulWidget {
  final String searchQuery;
  const ForestFinderScreen({super.key, required this.searchQuery});

  @override
  State<ForestFinderScreen> createState() => _ForestFinderScreenState();

  // --- Static Server State & Methods (accessible globally) ---
  static HttpServer? _forestServer;
  static bool _isServerRunning = false;
  static bool _hasInitializedServer = false;
  
  static String _adminPassword = 'ForestAdminPassword2026!';
  static final int _forestPort = 41920;
  static const String _dbKeyForestRunning = 'forest_finder_server_running';
  static const String _dbKeyAdminPass = 'forest_finder_admin_password';

  /// Public static method to start the ForestFinder server with all pages in the background on app boot.
  static Future<void> startServerIfEnabled() async {
    try {
      // 1. Ensure the base directory exists inline
      final dir = Directory(p.join(appDirectoryPath, 'ForestFinderSpool'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      final store = StoreRef<String, dynamic>.main();
      
      // 2. Check if persistently enabled by user
      final persistedState = await store.record(_dbKeyForestRunning).get(sembastDb) as bool? ?? false;
      if (!persistedState) return;
      
      // 3. Check Hours of Operation configuration from the Sembast 'system_time_config' store
      bool withinHours = true;
      try {
        final timeConfigStore = stringMapStoreFactory.store('system_time_config');
        final configMap = await timeConfigStore.record('config').get(sembastDb);
        if (configMap != null && configMap['schedules'] != null) {
          final schedules = Map<String, dynamic>.from(configMap['schedules'] as Map);
          final scheduleStr = schedules['ForestFinder'] ?? '24/7 Active';
          
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
        await _startServerHeadless();
        debugPrint('[ForestFinder] Server started automatically (Enabled & Within Hours).');
      } else if (!shouldBeRunning && _isServerRunning) {
        await _forestServer?.close(force: true);
        _forestServer = null;
        _isServerRunning = false;
        debugPrint('[ForestFinder] Server stopped automatically (Disabled or Outside Hours).');
      }
    } catch (e) {
      debugPrint('[ForestFinder] Failed to evaluate server state on schedule tick: $e');
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

      final store = StoreRef<String, dynamic>.main();
      final savedPass = await store.record(_dbKeyAdminPass).get(sembastDb) as String?;
      if (savedPass != null && savedPass.isNotEmpty) {
        _adminPassword = savedPass;
      }

      final router = shelf_router.Router();

      router.get('/', (shelf.Request request) {
        final htmlContent = '''
          <!DOCTYPE html>
          <html>
          <head>
            <meta charset="UTF-8">
            <title>ForestFinder - Gateway Hub</title>
            <style>
              body { font-family: sans-serif; background: #1c1a1a; color: #ECEFF1; padding: 40px; display: flex; justify-content: center; }
              .card { background: #222020; padding: 30px; border-radius: 12px; box-shadow: 0 4px 15px rgba(0,0,0,0.4); max-width: 450px; width: 100%; border: 1px solid rgba(255,255,255,0.08); text-align: center; }
              h2 { color: #81c784; margin-top: 0; }
              a { display: block; margin: 15px 0; padding: 12px; background: #2a2828; color: #81c784; text-decoration: none; border-radius: 6px; font-weight: bold; border: 1px solid #444; }
              a:hover { background: #333; }
            </style>
          </head>
          <body>
            <div class="card">
              <h2>ForestFinder Hub</h2>
              <p style="color: #90a4ae; font-size: 13px;">Secure Document Transmission & Printing Gateways</p>
              <a href="/submit">Document Submission Portal</a>
              <a href="/monitor">Printer Queue Monitor</a>
              <a href="/admin">Secure Admin Dashboard</a>
            </div>
          </body>
          </html>
        ''';
        return shelf.Response.ok(htmlContent, headers: {'content-type': 'text/html; charset=utf-8'});
      });

      router.get('/submit', (shelf.Request request) {
        final htmlContent = '''
          <!DOCTYPE html>
          <html>
          <head>
            <meta charset="UTF-8">
            <title>ForestFinder - Virtual Drop & Print</title>
            <style>
              body { font-family: sans-serif; background: #1c1a1a; color: #ECEFF1; padding: 40px; display: flex; justify-content: center; }
              .card { background: #222020; padding: 30px; border-radius: 12px; box-shadow: 0 4px 15px rgba(0,0,0,0.4); max-width: 450px; width: 100%; border: 1px solid rgba(255,255,255,0.08); }
              h2 { color: #81c784; margin-top: 0; text-align: center; }
              label { display: block; margin-top: 15px; font-weight: 600; font-size: 14px; color: #b0bec5; }
              input, select, textarea { width: 100%; padding: 10px; margin-top: 5px; border-radius: 6px; border: 1px solid #444; background: #1c1a1a; color: #fff; box-sizing: border-box; font-size: 14px; }
              textarea { resize: vertical; height: 80px; }
              button { width: 100%; padding: 12px; margin-top: 25px; background: #81c784; color: #1c1a1a; border: none; border-radius: 6px; font-weight: bold; font-size: 16px; cursor: pointer; }
              button:hover { background: #66bb6a; }
              .nav-back { display: block; text-align: center; margin-top: 15px; color: #90a4ae; text-decoration: none; font-size: 12px; }
            </style>
          </head>
          <body>
            <div class="card">
              <h2>ForestFinder Submit</h2>
              <p style="text-align: center; color: #90a4ae; font-size: 13px;">Background Submission Portal</p>
              <form action="/submit" method="POST" enctype="multipart/form-data">
                <label>Sender Name:</label>
                <input type="text" name="senderName" required placeholder="e.g., Jane Doe" />
                <label>Recipient / Department:</label>
                <input type="text" name="recipient" placeholder="e.g., Engineering Team" />
                <label>Cover Sheet Notes:</label>
                <textarea name="notes" placeholder="Enter message or memo details..."></textarea>
                <label>Target Printer:</label>
                <select name="printerName" required>
                  <option value="" disabled selected>No printers available</option>
                </select>
                <label style="margin-top: 15px;">Document (PDF):</label>
                <input type="file" name="document" accept=".pdf" required />
                <button type="submit">Transmit & Print</button>
              </form>
              <a href="/" class="nav-back">Back to Hub</a>
            </div>
          </body>
          </html>
        ''';
        return shelf.Response.ok(htmlContent, headers: {'content-type': 'text/html; charset=utf-8'});
      });

      router.post('/submit', (shelf.Request request) async {
        return shelf.Response.ok('<!DOCTYPE html><html><head><meta charset="UTF-8"></head><body style="background:#1c1a1a;color:#81c784;font-family:sans-serif;text-align:center;padding:50px;"><h2>Success! Document spooled and queued securely.</h2><br><a href="/submit" style="color:#fff;">Submit Another</a> | <a href="/monitor" style="color:#fff;">View Queue Monitor</a></body></html>', headers: {'content-type': 'text/html; charset=utf-8'});
      });

      router.get('/monitor', (shelf.Request request) {
        final htmlContent = '''
          <!DOCTYPE html>
          <html>
          <head>
            <meta charset="UTF-8">
            <title>ForestFinder - Public Queue Monitor</title>
            <style>
              body { font-family: sans-serif; background: #1c1a1a; color: #ECEFF1; padding: 40px; }
              .card { background: #222020; padding: 30px; border-radius: 12px; box-shadow: 0 4px 15px rgba(0,0,0,0.4); max-width: 700px; margin: auto; border: 1px solid rgba(255,255,255,0.08); }
              h2 { color: #81c784; text-align: center; }
              table { width: 100%; border-collapse: collapse; margin-top: 15px; }
              th, td { padding: 12px 15px; text-align: left; border-bottom: 1px solid #333; font-size: 13px; color: #fff; }
              th { background: #2a2828; color: #b0bec5; }
              .nav-back { display: block; text-align: center; margin-top: 20px; color: #90a4ae; text-decoration: none; font-size: 12px; }
            </style>
          </head>
          <body>
            <div class="card">
              <h2>ForestFinder Printer Queue Monitor</h2>
              <p style="text-align: center; color: #90a4ae; font-size: 13px;">Active queue status per printer</p>
              <table>
                <tr><th>Job ID</th><th>Target Printer</th><th>Queued Time</th><th>Status</th></tr>
                <tr><td colspan="4" style="text-align:center; color:#888;">No jobs currently in print queue.</td></tr>
              </table>
              <a href="/" class="nav-back">Back to Hub</a>
            </div>
          </body>
          </html>
        ''';
        return shelf.Response.ok(htmlContent, headers: {'content-type': 'text/html; charset=utf-8'});
      });

      router.get('/admin', (shelf.Request request) async {
        final dashboardHtml = '''
          <h2>ForestFinder Secure Admin Audit Dashboard</h2>
          <p>Confidential document transmission monitoring, spooled PDF inspection, and job management.</p>
          
          <div style="margin-bottom: 40px;">
            <h3>Active Print Queue (Offline Spool)</h3>
            <table>
              <tr><th>Job ID</th><th>Sender & IP</th><th>Target Printer</th><th>Spooled Time</th><th>Actions</th></tr>
              <tr><td colspan="5" style="text-align:center; color:#888;">No jobs currently in queue.</td></tr>
            </table>
          </div>

          <div>
            <h3>Print History & Audit Log (Anti-Leak Tracing)</h3>
            <table>
              <tr><th>Job ID</th><th>Sender Name</th><th>Client IP Address</th><th>Printer</th><th>Timestamp</th><th>Status</th></tr>
              <tr><td colspan="6" style="text-align:center; color:#888;">No print history logged yet.</td></tr>
            </table>
          </div>

          <br>
          <a href="/" style="color: #81c784; text-decoration: none; font-size: 13px;">Back to Hub</a>
        ''';
        final wrapped = _wrapEncryptedPageForClient(dashboardHtml, _adminPassword);
        return shelf.Response.ok(wrapped, headers: {'content-type': 'text/html; charset=utf-8'});
      });

      _forestServer = await shelf_io.serve(
        router.call,
        '0.0.0.0',
        _forestPort,
        securityContext: securityContext,
      );

      _isServerRunning = true;
      debugPrint('[ForestFinder] Headless background server started on port $_forestPort with all routes.');
    } catch (e) {
      _isServerRunning = false;
      debugPrint('[ForestFinder] Headless server start error: $e');
    }
  }

  static String _wrapEncryptedPageForClient(String htmlContent, String password) {
    final passwordHash = sha256.convert(utf8.encode(password)).toString();

    return '''
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Cydog Secure Encrypted Admin Portal</title>
    <style>
        body, html { margin: 0; padding: 0; width: 100%; height: 100%; background: #1c1a1a; color: #eceff1; font-family: sans-serif; }
        .box { background: #262424; padding: 30px; border-radius: 8px; border: 1px solid rgba(255,255,255,0.1); width: 420px; text-align: center; margin: 100px auto; }
        input { width: 100%; padding: 10px; margin: 15px 0; background: #1c1a1a; border: 1px solid #444; color: #fff; border-radius: 4px; box-sizing: border-box; }
        button { background: #81c784; color: #1c1a1a; border: none; padding: 10px 20px; border-radius: 4px; cursor: pointer; font-weight: bold; width: 100%; }
        button:hover { background: #66bb6a; }
        #portal-container { display: none; padding: 30px; }
        .error { color: #ff5252; font-size: 12px; margin-top: 10px; }
        table { width: 100%; border-collapse: collapse; margin-top: 15px; background: #222020; border-radius: 6px; overflow: hidden; }
        th, td { padding: 12px 15px; text-align: left; border-bottom: 1px solid #333; font-size: 13px; color: #fff; }
        th { background: #2a2828; color: #b0bec5; }
        h2, h3 { color: #81c784; }
        .btn-cancel { background: #e53935; color: white; padding: 6px 12px; border-radius: 4px; text-decoration: none; font-size: 12px; border: none; cursor: pointer; }
        .btn-view { background: #00acc1; color: white; padding: 6px 12px; border-radius: 4px; text-decoration: none; font-size: 12px; margin-right: 6px; display: inline-block; }
    </style>
</head>
<body>
    <div class="box" id="prompt-box">
        <h3>Cydog Protected Admin Portal</h3>
        <p style="font-size: 12px; color: #aaa;" id="prompt-text">Enter admin decryption password to unlock portal...</p>
        <div id="password-group">
            <input type="password" id="pass-input" placeholder="Admin Password">
            <button onclick="submitPassword()">Unlock Admin Portal</button>
            <div id="error-msg" class="error"></div>
        </div>
    </div>
    <div id="portal-container"></div>

    <script>
        const expectedHash = "$passwordHash";
        const encodedContent = "${base64Encode(utf8.encode(htmlContent))}";

        async function sha256(message) {
            const msgBuffer = new TextEncoder().encode(message);
            const hashBuffer = await crypto.subtle.digest('SHA-256', msgBuffer);
            const hashArray = Array.from(new Uint8Array(hashBuffer));
            return hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
        }

        async function submitPassword() {
            const pass = document.getElementById('pass-input').value;
            const inputHash = await sha256(pass);
            const errorEl = document.getElementById('error-msg');

            if (inputHash === expectedHash) {
                document.getElementById('prompt-box').style.display = 'none';
                const container = document.getElementById('portal-container');
                container.style.display = 'block';
                container.innerHTML = atob(encodedContent);
            } else {
                errorEl.innerText = 'Decryption failed. Incorrect admin password.';
            }
        }
    </script>
</body>
</html>
''';
  }
}

class _ForestFinderScreenState extends State<ForestFinderScreen> with AutomaticKeepAliveClientMixin {
  List<Printer> _printers = [];
  Printer? _selectedPrinter;
  final List<String> _activityLogs = [];
  Directory? _spoolDir;
  List<Map<String, dynamic>> _printQueue = [];
  List<Map<String, dynamic>> _printHistory = [];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _initializeSpoolDirectory();
    _loadPrinters();
    _loadPersistedAdminPassword();
    if (!ForestFinderScreen._hasInitializedServer) {
      ForestFinderScreen._hasInitializedServer = true;
      _loadPersistedServerState();
    }
  }

  Future<void> _loadPersistedAdminPassword() async {
    try {
      final store = StoreRef<String, dynamic>.main();
      final savedPass = await store.record(ForestFinderScreen._dbKeyAdminPass).get(sembastDb) as String?;
      if (savedPass != null && savedPass.isNotEmpty) {
        setState(() {
          ForestFinderScreen._adminPassword = savedPass;
        });
      }
    } catch (e) {
      debugPrint('Failed to load admin password: $e');
    }
  }

  Future<void> _saveAdminPassword(String newPass) async {
    try {
      final store = StoreRef<String, dynamic>.main();
      await store.record(ForestFinderScreen._dbKeyAdminPass).put(sembastDb, newPass);
      
      final wasRunning = ForestFinderScreen._isServerRunning;
      if (wasRunning) {
        _log('Admin password changed. Taking down server for restart...');
        await _toggleForestServer(false, silent: true);
      }

      setState(() {
        ForestFinderScreen._adminPassword = newPass;
      });

      if (wasRunning) {
        _log('Restarting server with updated Cydog admin credentials...');
        await _toggleForestServer(true, silent: true);
      }

      _log('Admin password updated successfully. Server is back online.');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Admin password updated! Server was restarted and is now back online.')),
        );
      }
    } catch (e) {
      debugPrint('Failed to save admin password: $e');
    }
  }

  Future<void> _loadPersistedServerState() async {
    try {
      final store = StoreRef<String, dynamic>.main();
      final persistedState = await store.record(ForestFinderScreen._dbKeyForestRunning).get(sembastDb) as bool? ?? false;
      if (persistedState && !ForestFinderScreen._isServerRunning) {
        await _toggleForestServer(true, silent: true);
      } else {
        if (mounted) setState(() {});
      }
    } catch (e) {
      debugPrint('Failed to load persisted ForestFinder state: $e');
    }
  }

  Future<void> _persistServerState(bool running) async {
    try {
      final store = StoreRef<String, dynamic>.main();
      await store.record(ForestFinderScreen._dbKeyForestRunning).put(sembastDb, running);
    } catch (e) {
      debugPrint('Failed to save ForestFinder state: $e');
    }
  }

  Future<SecurityContext> _getSecureContext() async {
    final certBytes = await rootBundle.load('assets/cert.pem');
    final keyBytes = await rootBundle.load('assets/key.pem');

    final context = SecurityContext(withTrustedRoots: false);
    context.useCertificateChainBytes(certBytes.buffer.asUint8List());
    context.usePrivateKeyBytes(keyBytes.buffer.asUint8List());
    return context;
  }

  Future<void> _initializeSpoolDirectory() async {
    final dir = Directory(p.join(appDirectoryPath, 'ForestFinderSpool'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    setState(() {
      _spoolDir = dir;
    });
    await _loadSpoolLogs();
  }

  Future<void> _loadSpoolLogs() async {
    if (_spoolDir == null) return;
    try {
      final queueFile = File(p.join(_spoolDir!.path, 'queue.json'));
      if (await queueFile.exists()) {
        final content = await queueFile.readAsString();
        final List list = jsonDecode(content);
        _printQueue = list.cast<Map<String, dynamic>>();
      }

      final historyFile = File(p.join(_spoolDir!.path, 'history.json'));
      if (await historyFile.exists()) {
        final content = await historyFile.readAsString();
        final List list = jsonDecode(content);
        _printHistory = list.cast<Map<String, dynamic>>();
      }
      setState(() {});
    } catch (e) {
      debugPrint('Error loading spool logs: $e');
    }
  }

  Future<void> _saveSpoolLogs() async {
    if (_spoolDir == null) return;
    try {
      final queueFile = File(p.join(_spoolDir!.path, 'queue.json'));
      await queueFile.writeAsString(jsonEncode(_printQueue));

      final historyFile = File(p.join(_spoolDir!.path, 'history.json'));
      await historyFile.writeAsString(jsonEncode(_printHistory));
    } catch (e) {
      debugPrint('Error saving spool logs: $e');
    }
  }

  Future<void> _loadPrinters() async {
    try {
      final allPrinters = await Printing.listPrinters();
      final networkPrinters = allPrinters.where((p) {
        final nameLower = p.name.toLowerCase();
        final urlLower = (p.url ?? '').toLowerCase();
        
        if (nameLower.contains('file') || nameLower.contains('pdf') || nameLower.contains('virtual')) {
          return false;
        }
        if (urlLower.contains('file://') || urlLower.isEmpty) {
          return urlLower.startsWith('ipp://') || urlLower.startsWith('socket://') || urlLower.startsWith('lpd://');
        }
        return true;
      }).toList();

      setState(() {
        _printers = networkPrinters;
        if (_selectedPrinter == null && networkPrinters.isNotEmpty) {
          _selectedPrinter = networkPrinters.first;
        }
      });
      _log('Filtered down to ${_printers.length} true network/hardware printers.');
    } catch (e) {
      _log('Error listing printers: $e');
    }
  }

  Future<void> addRemoteNetworkPrinter({
    required String printerName,
    required String printerIp,
  }) async {
    try {
      final sanitizedName = printerName.replaceAll(RegExp(r'\s+'), '_');
      final uri = 'ipp://$printerIp/ipp/print';

      _log('Linking remote printer $sanitizedName at $uri...');

      final result = await Process.run(
        'lpadmin',
        ['-p', sanitizedName, '-E', '-v', uri, '-m', 'everywhere'],
      );

      if (result.exitCode == 0) {
        _log('Successfully linked remote printer: $sanitizedName');
        await _loadPrinters();
      } else {
        _log('Failed to link printer: ${result.stderr.toString().trim()}');
      }
    } catch (e) {
      _log('Error executing lpadmin process: $e');
    }
  }

  void _showAddRemotePrinterDialog() {
    final nameController = TextEditingController();
    final ipController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF262424),
        title: const Text('Add Remote Network Printer', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(labelText: 'Printer Identifier', labelStyle: TextStyle(color: Colors.grey)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ipController,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(labelText: 'Printer IP Address (e.g., 192.168.1.50)', labelStyle: TextStyle(color: Colors.grey)),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.lightGreenAccent, foregroundColor: Colors.black),
            onPressed: () {
              Navigator.pop(context);
              addRemoteNetworkPrinter(printerName: nameController.text.trim(), printerIp: ipController.text.trim());
            },
            child: const Text('Link Printer'),
          ),
        ],
      ),
    );
  }

  void _showSetAdminPasswordDialog() {
    final passController = TextEditingController(text: ForestFinderScreen._adminPassword);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF262424),
        title: const Text('Set Admin Portal Password', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Enter the password required to unlock the Cydog-encrypted admin audit portal. Updating this will restart the server.', style: TextStyle(color: Colors.grey, fontSize: 12)),
            const SizedBox(height: 12),
            TextField(
              controller: passController,
              obscureText: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(labelText: 'Admin Password', labelStyle: TextStyle(color: Colors.grey)),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.lightGreenAccent, foregroundColor: Colors.black),
            onPressed: () {
              Navigator.pop(context);
              _saveAdminPassword(passController.text.trim());
            },
            child: const Text('Save & Restart'),
          ),
        ],
      ),
    );
  }

  void _log(String message) {
    if (mounted) {
      setState(() {
        _activityLogs.insert(0, '[${DateTime.now().toLocal().toString().split('.').first}] $message');
        if (_activityLogs.length > 100) _activityLogs.removeLast();
      });
    }
  }

  Future<void> _cancelJob(String jobId) async {
    setState(() {
      _printQueue.removeWhere((j) => j['jobId'] == jobId);
    });
    await _saveSpoolLogs();
    _log('Job $jobId cancelled by administrator.');
  }

  Future<Uint8List?> _getJobPdfBytes(String jobId) async {
    try {
      final file = File(p.join(_spoolDir!.path, 'job_$jobId.pdf'));
      if (await file.exists()) {
        return await file.readAsBytes();
      }
    } catch (e) {
      debugPrint('Error reading job pdf: $e');
    }
    return null;
  }

  Future<void> _toggleForestServer(bool enable, {bool silent = false}) async {
    if (enable) {
      try {
        final securityContext = await _getSecureContext();
        debugPrint('[ForestFinder] SSL Context loaded successfully.');

        final router = shelf_router.Router();

        router.get('/', (shelf.Request request) {
          final htmlContent = '''
            <!DOCTYPE html>
            <html>
            <head>
              <meta charset="UTF-8">
              <title>ForestFinder - Gateway Hub</title>
              <style>
                body { font-family: sans-serif; background: #1c1a1a; color: #ECEFF1; padding: 40px; display: flex; justify-content: center; }
                .card { background: #222020; padding: 30px; border-radius: 12px; box-shadow: 0 4px 15px rgba(0,0,0,0.4); max-width: 450px; width: 100%; border: 1px solid rgba(255,255,255,0.08); text-align: center; }
                h2 { color: #81c784; margin-top: 0; }
                a { display: block; margin: 15px 0; padding: 12px; background: #2a2828; color: #81c784; text-decoration: none; border-radius: 6px; font-weight: bold; border: 1px solid #444; }
                a:hover { background: #333; }
              </style>
            </head>
            <body>
              <div class="card">
                <h2>ForestFinder Hub</h2>
                <p style="color: #90a4ae; font-size: 13px;">Secure Document Transmission & Printing Gateways</p>
                <a href="/submit">Document Submission Portal</a>
                <a href="/monitor">Printer Queue Monitor</a>
                <a href="/admin">Secure Admin Dashboard</a>
              </div>
            </body>
            </html>
          ''';
          return shelf.Response.ok(htmlContent, headers: {'content-type': 'text/html; charset=utf-8'});
        });

        router.get('/submit', (shelf.Request request) {
          final printerOptions = _printers.isEmpty
              ? '<option value="" disabled selected>No printers available</option>'
              : _printers.map((p) => '<option value="${p.name}">${p.name} (${p.location ?? "Network"})</option>').join();

          final htmlContent = '''
            <!DOCTYPE html>
            <html>
            <head>
              <meta charset="UTF-8">
              <title>ForestFinder - Virtual Drop & Print</title>
              <style>
                body { font-family: sans-serif; background: #1c1a1a; color: #ECEFF1; padding: 40px; display: flex; justify-content: center; }
                .card { background: #222020; padding: 30px; border-radius: 12px; box-shadow: 0 4px 15px rgba(0,0,0,0.4); max-width: 450px; width: 100%; border: 1px solid rgba(255,255,255,0.08); }
                h2 { color: #81c784; margin-top: 0; text-align: center; }
                label { display: block; margin-top: 15px; font-weight: 600; font-size: 14px; color: #b0bec5; }
                input, select, textarea { width: 100%; padding: 10px; margin-top: 5px; border-radius: 6px; border: 1px solid #444; background: #1c1a1a; color: #fff; box-sizing: border-box; font-size: 14px; }
                textarea { resize: vertical; height: 80px; }
                button { width: 100%; padding: 12px; margin-top: 25px; background: #81c784; color: #1c1a1a; border: none; border-radius: 6px; font-weight: bold; font-size: 16px; cursor: pointer; }
                button:hover { background: #66bb6a; }
                .nav-back { display: block; text-align: center; margin-top: 15px; color: #90a4ae; text-decoration: none; font-size: 12px; }
              </style>
            </head>
            <body>
              <div class="card">
                <h2>ForestFinder Submit</h2>
                <p style="text-align: center; color: #90a4ae; font-size: 13px;">Secure Document & Fax Drop Portal</p>
                <form action="/submit" method="POST" enctype="multipart/form-data">
                  <label>Sender Name:</label>
                  <input type="text" name="senderName" required placeholder="e.g., Jane Doe" />

                  <label>Recipient / Department:</label>
                  <input type="text" name="recipient" placeholder="e.g., Engineering Team" />

                  <label>Cover Sheet Notes:</label>
                  <textarea name="notes" placeholder="Enter message or memo details..."></textarea>

                  <label>Target Printer:</label>
                  <select name="printerName" required>$printerOptions</select>
                  
                  <label style="margin-top: 15px;">Document (PDF):</label>
                  <input type="file" name="document" accept=".pdf" required />
                  
                  <button type="submit">Transmit & Print</button>
                </form>
                <a href="/" class="nav-back">Back to Hub</a>
              </div>
            </body>
            </html>
          ''';
          return shelf.Response.ok(htmlContent, headers: {'content-type': 'text/html; charset=utf-8'});
        });

        router.post('/submit', (shelf.Request request) async {
          try {
            final clientIp = request.context['shelf.io.connection_info'] as HttpConnectionInfo?;
            final ipAddress = clientIp?.remoteAddress.address ?? 'Unknown IP';

            _log('Incoming print job transmission from IP: $ipAddress');
            return shelf.Response.ok('<!DOCTYPE html><html><head><meta charset="UTF-8"></head><body style="background:#1c1a1a;color:#81c784;font-family:sans-serif;text-align:center;padding:50px;"><h2>Success! Document spooled and queued securely.</h2><br><a href="/submit" style="color:#fff;">Submit Another</a> | <a href="/monitor" style="color:#fff;">View Queue Monitor</a></body></html>', headers: {'content-type': 'text/html; charset=utf-8'});
          } catch (e) {
            _log('Print processing error: $e');
            return shelf.Response.internalServerError(body: 'Failed to process print job.');
          }
        });

        router.get('/monitor', (shelf.Request request) {
          final queueRows = _printQueue.isEmpty
              ? '<tr><td colspan="4" style="text-align:center; color:#888;">No jobs currently in print queue.</td></tr>'
              : _printQueue.map((j) => '<tr><td>${j['jobId']}</td><td>${j['printer']}</td><td>${j['timestamp']}</td><td style="color:#81c784;">Queued</td></tr>').join();

          final htmlContent = '''
            <!DOCTYPE html>
            <html>
            <head>
              <meta charset="UTF-8">
              <title>ForestFinder - Public Queue Monitor</title>
              <style>
                body { font-family: sans-serif; background: #1c1a1a; color: #ECEFF1; padding: 40px; }
                .card { background: #222020; padding: 30px; border-radius: 12px; box-shadow: 0 4px 15px rgba(0,0,0,0.4); max-width: 700px; margin: auto; border: 1px solid rgba(255,255,255,0.08); }
                h2 { color: #81c784; text-align: center; }
                table { width: 100%; border-collapse: collapse; margin-top: 15px; }
                th, td { padding: 12px 15px; text-align: left; border-bottom: 1px solid #333; font-size: 13px; color: #fff; }
                th { background: #2a2828; color: #b0bec5; }
                .nav-back { display: block; text-align: center; margin-top: 20px; color: #90a4ae; text-decoration: none; font-size: 12px; }
              </style>
            </head>
            <body>
              <div class="card">
                <h2>ForestFinder Printer Queue Monitor</h2>
                <p style="text-align: center; color: #90a4ae; font-size: 13px;">Active queue status per printer</p>
                <table>
                  <tr><th>Job ID</th><th>Target Printer</th><th>Queued Time</th><th>Status</th></tr>
                  $queueRows
                </table>
                <a href="/" class="nav-back">Back to Hub</a>
              </div>
            </body>
            </html>
          ''';
          return shelf.Response.ok(htmlContent, headers: {'content-type': 'text/html; charset=utf-8'});
        });

        router.get('/admin', (shelf.Request request) async {
          final queueRows = _printQueue.isEmpty
              ? '<tr><td colspan="5" style="text-align:center; color:#888;">No jobs currently in queue.</td></tr>'
              : _printQueue.map((j) => '''
                  <tr>
                    <td>${j['jobId']}</td>
                    <td><b>${j['senderName']}</b> (${j['ipAddress']})</td>
                    <td>${j['printer']}</td>
                    <td>${j['timestamp']}</td>
                    <td>
                      <a href="/job/${j['jobId']}" class="btn-view" target="_blank">View File</a>
                      <button onclick="cancelJob('${j['jobId']}')" class="btn-cancel">Cancel</button>
                    </td>
                  </tr>
                ''').join();

          final historyRows = _printHistory.isEmpty
              ? '<tr><td colspan="6" style="text-align:center; color:#888;">No print history logged yet.</td></tr>'
              : _printHistory.map((j) => '<tr><td>${j['jobId']}</td><td><b>${j['senderName']}</b></td><td>${j['ipAddress']}</td><td>${j['printer']}</td><td>${j['timestamp']}</td><td style="color:#81c784;">${j['status']}</td></tr>').join();

          final dashboardHtml = '''
            <h2>ForestFinder Secure Admin Audit Dashboard</h2>
            <p>Confidential document transmission monitoring, spooled PDF inspection, and job management.</p>
            
            <div style="margin-bottom: 40px;">
              <h3>Active Print Queue (Offline Spool)</h3>
              <table>
                <tr><th>Job ID</th><th>Sender & IP</th><th>Target Printer</th><th>Spooled Time</th><th>Actions</th></tr>
                $queueRows
              </table>
            </div>

            <div>
              <h3>Print History & Audit Log (Anti-Leak Tracing)</h3>
              <table>
                <tr><th>Job ID</th><th>Sender Name</th><th>Client IP Address</th><th>Printer</th><th>Timestamp</th><th>Status</th></tr>
                $historyRows
              </table>
            </div>

            <br>
            <a href="/" style="color: #81c784; text-decoration: none; font-size: 13px;">Back to Hub</a>

            <script>
              async function cancelJob(jobId) {
                if (confirm('Are you sure you want to cancel job ' + jobId + '?')) {
                  const res = await fetch('/cancel/' + jobId, { method: 'POST' });
                  if (res.ok) {
                    location.reload();
                  } else {
                    alert('Failed to cancel job.');
                  }
                }
              }
            </script>
          ''';

          final wrapped = ForestFinderScreen._wrapEncryptedPageForClient(dashboardHtml, ForestFinderScreen._adminPassword);
          return shelf.Response.ok(wrapped, headers: {'content-type': 'text/html; charset=utf-8'});
        });

        router.get('/job/<jobId>', (shelf.Request request, String jobId) async {
          final pdfBytes = await _getJobPdfBytes(jobId);
          if (pdfBytes == null) {
            return shelf.Response.notFound('Job PDF not found.');
          }
          return shelf.Response.ok(pdfBytes, headers: {'content-type': 'application/pdf'});
        });

        router.post('/cancel/<jobId>', (shelf.Request request, String jobId) async {
          await _cancelJob(jobId);
          return shelf.Response.ok(jsonEncode({'success': true}), headers: {'content-type': 'application/json'});
        });

        ForestFinderScreen._forestServer = await shelf_io.serve(
          router.call,
          '0.0.0.0',
          ForestFinderScreen._forestPort,
          securityContext: securityContext,
        );

        ForestFinderScreen._isServerRunning = true;
        await _persistServerState(true);
        if (mounted) setState(() {});

        if (!silent && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('ForestFinder HTTPS server started on https://$deviceIpAddress:${ForestFinderScreen._forestPort}')),
          );
        }
      } catch (e) {
        ForestFinderScreen._isServerRunning = false;
        await _persistServerState(false);
        if (mounted) setState(() {});
      }
    } else {
      await ForestFinderScreen._forestServer?.close(force: true);
      ForestFinderScreen._forestServer = null;
      ForestFinderScreen._isServerRunning = false;
      await _persistServerState(false);
      if (mounted) setState(() {});
    }
  }

  void _showJobDetailsDialog(Map<String, dynamic> job) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF262424),
        title: Text('Job Details: ${job['jobId']}', style: const TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Sender: ${job['senderName']}', style: const TextStyle(color: Colors.white70)),
            Text('IP Address: ${job['ipAddress']}', style: const TextStyle(color: Colors.white70)),
            Text('Printer: ${job['printer']}', style: const TextStyle(color: Colors.white70)),
            Text('Timestamp: ${job['timestamp']}', style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.cyan, foregroundColor: Colors.black),
                onPressed: () async {
                  final bytes = await _getJobPdfBytes(job['jobId']);
                  if (bytes != null) {
                    await Printing.layoutPdf(onLayout: (format) => bytes);
                  }
                },
                icon: const Icon(Icons.print, size: 16),
                label: const Text('View / Print Exact File'),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close', style: TextStyle(color: Colors.white))),
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
                      const Text('ForestFinder Print Node', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                      IconButton(
                        icon: const Icon(Icons.add_link, color: Colors.lightGreenAccent, size: 18),
                        onPressed: _showAddRemotePrinterDialog,
                        tooltip: 'Link Remote Printer',
                      ),
                    ],
                  ),
                ),
                Container(
                  margin: const EdgeInsets.all(8),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: ForestFinderScreen._isServerRunning ? Colors.green.withOpacity(0.1) : Colors.black12,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: ForestFinderScreen._isServerRunning ? Colors.lightGreenAccent.withOpacity(0.3) : Colors.white12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(ForestFinderScreen._isServerRunning ? 'Server: Active' : 'Server: Stopped', style: TextStyle(color: ForestFinderScreen._isServerRunning ? Colors.lightGreenAccent : Colors.grey, fontSize: 11, fontWeight: FontWeight.bold)),
                          Switch(
                            value: ForestFinderScreen._isServerRunning,
                            onChanged: (val) async {
                              await _toggleForestServer(val);
                            },
                            activeColor: Colors.lightGreenAccent,
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text('Port: ${ForestFinderScreen._forestPort} (HTTPS)', style: const TextStyle(color: Colors.white60, fontSize: 10)),
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
                          onPressed: _showSetAdminPasswordDialog,
                          icon: const Icon(Icons.lock, size: 12),
                          label: const Text('Set Admin Password', style: TextStyle(fontSize: 10)),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(color: Colors.white12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Network Printers', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, fontSize: 12)),
                      IconButton(
                        icon: const Icon(Icons.refresh, color: Colors.white54, size: 14),
                        onPressed: _loadPrinters,
                        tooltip: 'Refresh Printers',
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _printers.isEmpty
                      ? const Center(child: Text('No network printers found.\nClick "+" to link remote IP.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white38, fontSize: 11)))
                      : ListView.builder(
                          itemCount: _printers.length,
                          itemBuilder: (context, index) {
                            final printer = _printers[index];
                            final isSelected = _selectedPrinter?.name == printer.name;
                            return ListTile(
                              selected: isSelected,
                              selectedTileColor: Colors.green.withOpacity(0.15),
                              leading: const Icon(Icons.print, color: Colors.lightGreenAccent, size: 18),
                              title: Text(printer.name, style: const TextStyle(color: Colors.white, fontSize: 12)),
                              subtitle: Text(printer.url ?? printer.location ?? 'Network Printer', style: const TextStyle(color: Colors.grey, fontSize: 10)),
                              onTap: () {
                                setState(() {
                                  _selectedPrinter = printer;
                                });
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('ForestFinder Gateway Portal', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                      Row(
                        children: [
                          Text('Hub: https://$deviceIpAddress:${ForestFinderScreen._forestPort}/', style: const TextStyle(color: Colors.lightGreenAccent, fontSize: 11)),
                          const SizedBox(width: 12),
                          Text('Submit: https://$deviceIpAddress:${ForestFinderScreen._forestPort}/submit', style: const TextStyle(color: Colors.lightGreenAccent, fontSize: 11)),
                          const SizedBox(width: 12),
                          Text('Monitor: https://$deviceIpAddress:${ForestFinderScreen._forestPort}/monitor', style: const TextStyle(color: Colors.lightGreenAccent, fontSize: 11)),
                          const SizedBox(width: 12),
                          Text('Admin: https://$deviceIpAddress:${ForestFinderScreen._forestPort}/admin', style: const TextStyle(color: Colors.cyanAccent, fontSize: 11)),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text('Active Print Queue (Offline Spool & Management)', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 200,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black26,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: _printQueue.isEmpty
                          ? const Center(child: Text('No active jobs in queue.', style: TextStyle(color: Colors.grey, fontSize: 11)))
                          : ListView.builder(
                              itemCount: _printQueue.length,
                              itemBuilder: (context, index) {
                                final job = _printQueue[index];
                                return ListTile(
                                  dense: true,
                                  title: Text('Job #${job['jobId']} — ${job['senderName']} (${job['ipAddress']})', style: const TextStyle(color: Colors.white, fontSize: 12)),
                                  subtitle: Text('Printer: ${job['printer']} | Spooled: ${job['timestamp']}', style: const TextStyle(color: Colors.grey, fontSize: 10)),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      ElevatedButton(
                                        style: ElevatedButton.styleFrom(backgroundColor: Colors.cyan, foregroundColor: Colors.black, visualDensity: VisualDensity.compact),
                                        onPressed: () => _showJobDetailsDialog(job),
                                        child: const Text('View File', style: TextStyle(fontSize: 10)),
                                      ),
                                      const SizedBox(width: 6),
                                      ElevatedButton(
                                        style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white, visualDensity: VisualDensity.compact),
                                        onPressed: () => _cancelJob(job['jobId']),
                                        child: const Text('Cancel', style: TextStyle(fontSize: 10)),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('Print & Server Activity Logs', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                  const SizedBox(height: 8),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black26,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: _activityLogs.isEmpty
                          ? const Center(child: Text('No print activity logged yet.', style: TextStyle(color: Colors.grey, fontSize: 11)))
                          : ListView.builder(
                              itemCount: _activityLogs.length,
                              itemBuilder: (context, index) {
                                return Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 2),
                                  child: Text(
                                    _activityLogs[index],
                                    style: const TextStyle(color: Colors.lightGreenAccent, fontFamily: 'monospace', fontSize: 11),
                                  ),
                                );
                              },
                            ),
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