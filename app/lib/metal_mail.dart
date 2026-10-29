import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:sembast/sembast.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:crypto/crypto.dart';
import 'db_service.dart';
import 'main.dart';

class MetalMailScreen extends StatefulWidget {
  final String searchQuery;
  const MetalMailScreen({super.key, required this.searchQuery});

  @override
  State<MetalMailScreen> createState() => _MetalMailScreenState();

  // --- Static Server State & Methods ---
  static HttpServer? _mailServer;
  static bool _isServerRunning = false;
  static bool _hasInitializedServer = false;
  
  static final int _mailPort = 41930;
  static const String _dbKeyMailRunning = 'metal_mail_server_running';

  // Session-based trustless fingerprint registry (cleared on server restart/reboot)
  static final Set<String> _activeSessionFingerprints = <String>{};

  static bool verifyTotpCode(String secret, String code) {
    if (code.length != 6) return false;
    try {
      final epochSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final timeStep = epochSeconds ~/ 30;
      
      for (int i = -1; i <= 1; i++) {
        final computed = _computeTotp(secret, timeStep + i);
        if (computed == code) return true;
      }
    } catch (e) {
      debugPrint('[MetalMail] TOTP verification error: $e');
    }
    return false;
  }

  static String _computeTotp(String base32Secret, int timeStep) {
    try {
      final key = _base32Decode(base32Secret);
      final data = Uint8List(8);
      var val = timeStep;
      for (int i = 7; i >= 0; i--) {
        data[i] = val & 0xff;
        val >>= 8;
      }
      final hmac = Hmac(sha1, key);
      final digest = hmac.convert(data);
      final offset = digest.bytes[digest.bytes.length - 1] & 0x0f;
      final binary = ((digest.bytes[offset] & 0x7f) << 24) |
          ((digest.bytes[offset + 1] & 0xff) << 16) |
          ((digest.bytes[offset + 2] & 0xff) << 8) |
          (digest.bytes[offset + 3] & 0xff);
      final otp = binary % 1000000;
      return otp.toString().padLeft(6, '0');
    } catch (_) {
      return '';
    }
  }

  static Uint8List _base32Decode(String base32) {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    var cleanInput = base32.toUpperCase().replaceAll(RegExp(r'[^A-Z2-7]'), '');
    var bits = 0;
    var value = 0;
    var output = <int>[];
    for (var i = 0; i < cleanInput.length; i++) {
      var idx = alphabet.indexOf(cleanInput[i]);
      if (idx < 0) continue;
      value = (value << 5) | idx;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        output.add((value >> bits) & 0xff);
      }
    }
    return Uint8List.fromList(output);
  }

  static Future<void> startServerIfEnabled() async {
    try {
      final dir = Directory(p.join(appDirectoryPath, 'MetalMail'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      final store = StoreRef<String, dynamic>.main();
      final persistedState = await store.record(_dbKeyMailRunning).get(sembastDb) as bool? ?? false;
      if (!persistedState) return;
      
      bool withinHours = true;
      try {
        final timeConfigStore = stringMapStoreFactory.store('system_time_config');
        final configMap = await timeConfigStore.record('config').get(sembastDb);
        if (configMap != null && configMap['schedules'] != null) {
          final schedules = Map<String, dynamic>.from(configMap['schedules'] as Map);
          final scheduleStr = schedules['MetalMail'] ?? '24/7 Active';
          
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

      final shouldBeRunning = persistedState && withinHours;

      if (shouldBeRunning && !_isServerRunning) {
        await _startServerHeadless();
        debugPrint('[MetalMail] Server started automatically (Enabled & Within Hours).');
      } else if (!shouldBeRunning && _isServerRunning) {
        await _mailServer?.close(force: true);
        _mailServer = null;
        _isServerRunning = false;
        _activeSessionFingerprints.clear();
        debugPrint('[MetalMail] Server stopped automatically (Disabled or Outside Hours).');
      }
    } catch (e) {
      debugPrint('[MetalMail] Failed to evaluate server state on schedule tick: $e');
    }
  }

  static Future<Directory> _getMetalMailDirHeadless() async {
    final dir = Directory(p.join(appDirectoryPath, 'MetalMail'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static String _deriveCanonicalThreadId(String sender, List<String> recipients, String subject) {
    final allParties = <String>{sender, ...recipients}.toList()..sort();
    final cleanSubject = subject.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_');
    return 'thread_${allParties.join("_")}_$cleanSubject';
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
        final path = request.url.path;

        // Serve static asset fingerprint2.min.js securely upon request
        if (path == 'fingerprint2.min.js') {
          try {
            final jsBytes = await rootBundle.load('assets/fingerprint2.min.js');
            return shelf.Response.ok(
              jsBytes.buffer.asUint8List(),
              headers: {'content-type': 'application/javascript; charset=utf-8'},
            );
          } catch (_) {
            return shelf.Response.notFound('Fingerprint script not found');
          }
        }

        if (path == '' || path == 'webmail' || path == 'index.html') {
          return shelf.Response.ok(_getWebmailHtmlTemplate(), headers: {'content-type': 'text/html; charset=utf-8'});
        }

        // --- Trustless Fingerprint Verification Middleware ---
        if (path.startsWith('api/')) {
          if (path != 'api/auth/login') {
            final clientFp = request.headers['x-trustless-fp'];
            if (clientFp == null || !_activeSessionFingerprints.contains(clientFp)) {
              return shelf.Response(
                401,
                body: jsonEncode({'error': 'Unauthorized: Invalid or missing session browser fingerprint.'}),
                headers: {'content-type': 'application/json'},
              );
            }
          }
        }

        if (path == 'api/auth/login' && request.method == 'POST') {
          try {
            final bodyStr = await request.readAsString();
            final data = jsonDecode(bodyStr) as Map<String, dynamic>;
            final username = data['username'] as String? ?? '';
            final password = data['password'] as String? ?? '';
            final totpCode = data['totp'] as String? ?? '';
            final fingerprint = data['fingerprint'] as String? ?? request.headers['x-trustless-fp'] ?? '';

            final user = await DbService().authenticate(username, password);
            if (user == null) {
              return shelf.Response.forbidden(jsonEncode({'error': 'Invalid username or password'}));
            }

            if (user.isTotpEnabled) {
              if (user.totpSecret.isEmpty || !verifyTotpCode(user.totpSecret, totpCode)) {
                return shelf.Response.forbidden(jsonEncode({'error': 'Invalid TOTP 2FA code'}));
              }
            }

            if (fingerprint.isNotEmpty) {
              _activeSessionFingerprints.add(fingerprint);
            }

            return shelf.Response.ok(jsonEncode({'status': 'success', 'username': user.username}), headers: {'content-type': 'application/json'});
          } catch (e) {
            return shelf.Response.internalServerError(body: jsonEncode({'error': 'Login error: $e'}));
          }
        }

        if (path == 'api/users') {
          final users = await DbService().getAllUsers();
          final userNames = users.map((u) => u.username).toList();
          return shelf.Response.ok(jsonEncode({'users': userNames}), headers: {'content-type': 'application/json'});
        }

        final username = request.url.queryParameters['user'] ?? request.headers['x-metal-user'] ?? 'admin';
        final rootDir = await _getMetalMailDirHeadless();
        
        final threadsDir = Directory(p.join(rootDir.path, 'threads'));
        if (!await threadsDir.exists()) await threadsDir.create(recursive: true);

        final usersIndexDir = Directory(p.join(rootDir.path, 'users_index'));
        if (!await usersIndexDir.exists()) await usersIndexDir.create(recursive: true);

        Future<Map<String, dynamic>> loadUserIndex(String uname) async {
          final indexFile = File(p.join(usersIndexDir.path, '$uname.json'));
          if (await indexFile.exists()) {
            try {
              return jsonDecode(await indexFile.readAsString()) as Map<String, dynamic>;
            } catch (_) {}
          }
          return {'inbox': <String>[], 'sent': <String>[]};
        }

        Future<void> saveUserIndex(String uname, Map<String, dynamic> indexData) async {
          final indexFile = File(p.join(usersIndexDir.path, '$uname.json'));
          await indexFile.writeAsString(jsonEncode(indexData));
        }

        if (path == 'api/mail' && request.method == 'GET') {
          final folder = request.url.queryParameters['folder'] == 'sent' ? 'sent' : 'inbox';
          final indexData = await loadUserIndex(username);
          final threadIds = List<String>.from(indexData[folder] ?? []);

          final mailList = <Map<String, dynamic>>[];
          for (var tid in threadIds) {
            final tFile = File(p.join(threadsDir.path, '$tid.metal'));
            if (await tFile.exists()) {
              try {
                mailList.add(jsonDecode(await tFile.readAsString()) as Map<String, dynamic>);
              } catch (_) {}
            }
          }

          mailList.sort((a, b) => (b['timestamp'] ?? '').compareTo(a['timestamp'] ?? ''));

          return shelf.Response.ok(
            jsonEncode({'user': username, 'folder': folder, 'count': mailList.length, 'mail': mailList}),
            headers: {'content-type': 'application/json'},
          );
        }

        if (path == 'api/mail/delete' && request.method == 'POST') {
          try {
            final bodyStr = await request.readAsString();
            final payloadData = jsonDecode(bodyStr) as Map<String, dynamic>;
            final threadId = payloadData['thread_id'] as String?;
            if (threadId == null) {
              return shelf.Response.badRequest(body: jsonEncode({'error': 'thread_id required'}));
            }

            final tFile = File(p.join(threadsDir.path, '$threadId.metal'));
            if (await tFile.exists()) await tFile.delete();

            await for (var entity in usersIndexDir.list()) {
              if (entity is File && entity.path.endsWith('.json')) {
                try {
                  final uname = p.basenameWithoutExtension(entity.path);
                  final idx = await loadUserIndex(uname);
                  bool changed = false;
                  if ((idx['inbox'] as List).contains(threadId)) {
                    (idx['inbox'] as List).remove(threadId);
                    changed = true;
                  }
                  if ((idx['sent'] as List).contains(threadId)) {
                    (idx['sent'] as List).remove(threadId);
                    changed = true;
                  }
                  if (changed) await saveUserIndex(uname, idx);
                } catch (_) {}
              }
            }

            return shelf.Response.ok(jsonEncode({'status': 'deleted'}), headers: {'content-type': 'application/json'});
          } catch (e) {
            return shelf.Response.internalServerError(body: jsonEncode({'error': 'Failed to delete: $e'}));
          }
        }

        if (request.method == 'POST' && path == 'api/mail/send') {
          try {
            final bodyStr = await request.readAsString();
            final payloadData = jsonDecode(bodyStr) as Map<String, dynamic>;
            final rawRecipients = payloadData['recipients'] ?? [payloadData['recipient']];
            final subject = payloadData['subject'] as String? ?? 'No Subject';
            final body = payloadData['body'] as String? ?? '';
            final attachmentName = payloadData['attachment_name'] as String?;
            final attachmentData = payloadData['attachment_data'] as String?;
            final threadIdInput = payloadData['thread_id'] as String?;

            if (rawRecipients == null || (rawRecipients is List && rawRecipients.isEmpty)) {
              return shelf.Response.badRequest(body: jsonEncode({'error': 'Recipients required'}));
            }

            final recipientList = rawRecipients is List 
                ? rawRecipients.map((e) => e.toString()).toList() 
                : [rawRecipients.toString()];
            
            final threadId = threadIdInput ?? _deriveCanonicalThreadId(username, recipientList, subject);
            final timestamp = DateTime.now().toIso8601String();

            final threadFile = File(p.join(threadsDir.path, '$threadId.metal'));
            Map<String, dynamic>? threadPacket;
            if (await threadFile.exists()) {
              try {
                threadPacket = jsonDecode(await threadFile.readAsString()) as Map<String, dynamic>;
              } catch (_) {}
            }

            if (threadPacket != null) {
              final responses = (threadPacket['responses'] as List<dynamic>? ?? []).map((e) => Map<String, dynamic>.from(e)).toList();
              responses.add({
                'author': username,
                'timestamp': timestamp,
                'content': body,
              });
              threadPacket['responses'] = responses;
              threadPacket['timestamp'] = timestamp;
            } else {
              threadPacket = {
                'thread_id': threadId,
                'sender': username,
                'recipient': recipientList.join(', '),
                'subject': subject,
                'timestamp': timestamp,
                'attachment_name': attachmentName,
                'attachment_data': attachmentData,
                'responses': [
                  {
                    'author': username,
                    'timestamp': timestamp,
                    'content': body,
                  }
                ]
              };
            }

            await threadFile.writeAsString(jsonEncode(threadPacket));

            final participants = <String>{username, ...recipientList};
            if (threadPacket['sender'] != null) participants.add(threadPacket['sender']);
            if (threadPacket['recipient'] != null) {
              threadPacket['recipient'].toString().split(',').forEach((r) => participants.add(r.trim()));
            }
            if (threadPacket['responses'] != null) {
              for (var r in threadPacket['responses']) {
                if (r['author'] != null) participants.add(r['author']);
              }
            }

            for (var participant in participants) {
              final idx = await loadUserIndex(participant);
              final inboxList = List<String>.from(idx['inbox'] ?? []);
              if (!inboxList.contains(threadId)) {
                inboxList.insert(0, threadId);
                idx['inbox'] = inboxList;
              }

              if (threadPacket['sender'] == participant) {
                final sentList = List<String>.from(idx['sent'] ?? []);
                if (!sentList.contains(threadId)) {
                  sentList.insert(0, threadId);
                  idx['sent'] = sentList;
                }
              }

              await saveUserIndex(participant, idx);
            }

            return shelf.Response.ok(jsonEncode({'status': 'Mail sent successfully', 'thread_id': threadId}), headers: {'content-type': 'application/json'});
          } catch (e) {
            return shelf.Response.internalServerError(body: jsonEncode({'error': 'Failed to send mail: $e'}));
          }
        }

        return shelf.Response.notFound(jsonEncode({'error': 'MetalMail endpoint not found'}), headers: {'content-type': 'application/json'});
      };

      _mailServer = await shelf_io.serve(
        handler,
        '0.0.0.0',
        _mailPort,
        securityContext: securityContext,
      );
      
      _isServerRunning = true;
      debugPrint('[MetalMail] Headless background server started on port $_mailPort.');
    } catch (e) {
      _isServerRunning = false;
      debugPrint('[MetalMail] Headless server start error: $e');
    }
  }

  static String _getWebmailHtmlTemplate() {
    return r'''
<!DOCTYPE html>
<html>
<head>
    <title>MetalMail Outlook Web Access</title>
    <style>
        body { background: #1c1a1a; color: #eceff1; font-family: monospace; margin: 0; padding: 0; height: 100vh; display: flex; flex-direction: column; }
        .login-container { max-width: 400px; margin: 100px auto; background: #222020; padding: 24px; border-radius: 8px; border: 1px solid #3a3636; }
        input, select, textarea, button { width: 100%; padding: 10px; margin: 8px 0; background: #1c1a1a; color: white; border: 1px solid #444; border-radius: 4px; box-sizing: border-box; font-family: monospace; }
        button { background: #2196f3; border: none; font-weight: bold; cursor: pointer; }
        button:hover { background: #1976d2; }
        .hidden { display: none !important; }
        
        #app-view { display: flex; flex: 1; height: 100vh; overflow: hidden; }
        .sidebar { width: 220px; background: #222020; border-right: 1px solid #333; display: flex; flex-direction: column; }
        .sidebar-item { padding: 12px 16px; cursor: pointer; color: #bbb; border-left: 3px solid transparent; }
        .sidebar-item:hover, .sidebar-item.active { background: #2a2828; color: #fff; border-left-color: #2196f3; }
        
        .main-pane { flex: 1; display: flex; flex-direction: column; background: #1c1a1a; }
        .top-bar { height: 50px; background: #262424; border-bottom: 1px solid #333; display: flex; align-items: center; justify-content: space-between; padding: 0 16px; }
        .search-bar { width: 300px; padding: 6px 12px; background: #1c1a1a; border: 1px solid #444; color: white; border-radius: 4px; }
        
        .content-split { display: flex; flex: 1; overflow: hidden; }
        .email-list { width: 320px; border-right: 1px solid #333; overflow-y: auto; background: #201e1e; }
        .email-item { padding: 12px; border-bottom: 1px solid #2a2828; cursor: pointer; }
        .email-item:hover { background: #282626; }
        .email-item.selected { background: #1976d233; border-left: 3px solid #2196f3; }
        
        .email-reader { flex: 1; padding: 20px; overflow-y: auto; background: #1c1a1a; }
        .empty-state { text-align: center; color: #777; margin-top: 100px; }
        .compose-modal { position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0,0,0,0.7); display: flex; align-items: center; justify-content: center; }
        .compose-box { width: 500px; background: #222020; padding: 20px; border-radius: 8px; border: 1px solid #444; }
    </style>
</head>
<body>
    <div id="login-form" class="login-container">
        <h2>MetalMail Webmail Login</h2>
        <input type="text" id="username" placeholder="ACL Username" />
        <input type="password" id="password" placeholder="Password" />
        <input type="text" id="totp" placeholder="TOTP 2FA Code (if enabled)" />
        <button onclick="login()">Login</button>
        <p id="error-msg" style="color: #ff5252;"></p>
    </div>

    <div id="app-view" class="hidden">
        <div class="sidebar">
            <div style="padding: 16px; font-weight: bold; color: #2196f3; border-bottom: 1px solid #333;">MetalMail</div>
            <div class="sidebar-item" onclick="openCompose()" style="background: #1976d2; color: white; text-align: center; margin: 12px; border-radius: 4px;">New Message</div>
            <div class="sidebar-item active" onclick="switchFolder('inbox', this)">Inbox</div>
            <div class="sidebar-item" onclick="switchFolder('sent', this)">Sent Items</div>
        </div>
        <div class="main-pane">
            <div class="top-bar">
                <input type="text" id="search-input" class="search-bar" placeholder="Search mail..." oninput="filterMail()" />
                <div style="display: flex; align-items: center; gap: 12px;">
                    <span id="user-display" style="color: #2196f3; font-weight: bold;"></span>
                    <button onclick="logout()" style="width: auto; padding: 6px 12px; background: #d32f2f;">Logout</button>
                </div>
            </div>
            <div class="content-split">
                <div class="email-list" id="email-list-container">
                    <div class="empty-state">No messages</div>
                </div>
                <div class="email-reader" id="email-reader-container">
                    <div class="empty-state">Select an email to read</div>
                </div>
            </div>
        </div>
    </div>

    <!-- Compose Modal -->
    <div id="compose-modal" class="compose-modal hidden">
        <div class="compose-box">
            <h3>New Message</h3>
            <label>Recipients (Hold Ctrl/Cmd for multi-select):</label>
            <select id="recipient-select" multiple style="height: 100px;"></select>
            <label>Subject:</label>
            <input type="text" id="compose-subject" placeholder="Subject" />
            <label>Message:</label>
            <textarea id="compose-body" rows="4" placeholder="Write message..."></textarea>
            <label>Attachment:</label>
            <input type="file" id="compose-file" />
            <button onclick="sendMail()">Send</button>
            <button onclick="closeCompose()" style="background: #555;">Cancel</button>
        </div>
    </div>

    <script>
        let currentUser = localStorage.getItem('metal_user');
        let currentFingerprint = localStorage.getItem('metal_fp');
        let currentFolder = 'inbox';
        let allMailData = [];
        let selectedThreadId = null;
        let allAclUsers = [];

        if (currentUser && currentFingerprint) {
            loadFingerprintScript().then(() => showApp());
        }

        function loadFingerprintScript() {
            return new Promise((resolve, reject) => {
                if (typeof Fingerprint2 !== 'undefined') {
                    resolve();
                    return;
                }
                const script = document.createElement('script');
                script.src = '/fingerprint2.min.js';
                script.onload = () => resolve();
                script.onerror = () => reject(new Error('Failed to load fingerprint script'));
                document.head.appendChild(script);
            });
        }

        async function generateFingerprint() {
            await loadFingerprintScript();
            return new Promise((resolve) => {
                new Fingerprint2().get(function(result, components) {
                    document.cookie = `ta=\${result}; Max-Age=3600; Path=/; SameSite=Strict; Secure`;
                    resolve(result);
                });
            });
        }

        async function login() {
            const u = document.getElementById('username').value;
            const p = document.getElementById('password').value;
            const t = document.getElementById('totp').value;
            
            try {
                const fp = await generateFingerprint();

                const res = await fetch('/api/auth/login', {
                    method: 'POST',
                    headers: {'content-type': 'application/json', 'x-trustless-fp': fp},
                    body: JSON.stringify({username: u, password: p, totp: t, fingerprint: fp})
                });
                const data = await res.json();
                if (res.ok) {
                    localStorage.setItem('metal_user', data.username);
                    localStorage.setItem('metal_fp', fp);
                    currentUser = data.username;
                    currentFingerprint = fp;
                    showApp();
                } else {
                    document.getElementById('error-msg').innerText = data.error || 'Login failed';
                }
            } catch (err) {
                document.getElementById('error-msg').innerText = 'Authentication initialization error';
            }
        }

        function showApp() {
            document.getElementById('login-form').classList.add('hidden');
            document.getElementById('app-view').classList.remove('hidden');
            document.getElementById('user-display').innerText = currentUser;
            loadMail();
            loadAclUsers();
        }

        async function loadAclUsers() {
            const res = await fetch('/api/users', {
                headers: { 'x-trustless-fp': currentFingerprint }
            });
            const data = await res.json();
            if (data.users) {
                allAclUsers = data.users;
            }
            const select = document.getElementById('recipient-select');
            select.innerHTML = '';
            allAclUsers.forEach(u => {
                if (u !== currentUser) {
                    select.innerHTML += '<option value="' + u + '">' + u + '</option>';
                }
            });
        }

        async function switchFolder(folder, element) {
            currentFolder = folder;
            document.querySelectorAll('.sidebar-item').forEach(el => el.classList.remove('active'));
            element.classList.add('active');
            loadMail();
        }

        async function loadMail() {
            const res = await fetch('/api/mail?user=' + currentUser + '&folder=' + currentFolder, {
                headers: { 'x-trustless-fp': currentFingerprint }
            });
            if (res.status === 401) {
                alert('Trustless fingerprint session expired or invalid. Please log in again.');
                logout();
                return;
            }
            const data = await res.json();
            allMailData = data.mail || [];
            renderMailList(allMailData);
            if (selectedThreadId) {
                const updatedThread = allMailData.find(m => m.thread_id === selectedThreadId);
                if (updatedThread) {
                    selectThread(selectedThreadId);
                } else {
                    selectedThreadId = null;
                    document.getElementById('email-reader-container').innerHTML = '<div class="empty-state">Select an email to read</div>';
                }
            }
        }

        function filterMail() {
            const query = document.getElementById('search-input').value.toLowerCase();
            const filtered = allMailData.filter(m => 
                (m.subject && m.subject.toLowerCase().includes(query)) ||
                (m.sender && m.sender.toLowerCase().includes(query)) ||
                (m.responses && m.responses.some(r => r.content.toLowerCase().includes(query)))
            );
            renderMailList(filtered);
        }

        function renderMailList(list) {
            const container = document.getElementById('email-list-container');
            container.innerHTML = '';
            
            if (list.length === 0) {
                container.innerHTML = '<div class="empty-state">No messages in ' + currentFolder + '</div>';
                document.getElementById('email-reader-container').innerHTML = '<div class="empty-state">Select an email to read</div>';
                return;
            }

            list.forEach(m => {
                const isSelected = selectedThreadId === m.thread_id ? 'selected' : '';
                const hasAttachment = m.attachment_name ? ' 📎' : '';
                container.innerHTML += '<div class="email-item ' + isSelected + '" onclick="selectThread(\'' + m.thread_id + '\')"><b>' + (m.subject || 'No Subject') + hasAttachment + '</b><br><small style="color: #aaa;">From: ' + m.sender + '</small></div>';
            });
        }

        function selectThread(threadId) {
            selectedThreadId = threadId;
            const thread = allMailData.find(m => m.thread_id === threadId);
            if (!thread) return;

            renderMailList(allMailData);

            const reader = document.getElementById('email-reader-container');
            let responsesHtml = '';
            if (thread.responses) {
                const sortedResponses = [...thread.responses].reverse();
                sortedResponses.forEach(r => {
                    responsesHtml += '<div style="background: #262424; padding: 12px; margin: 10px 0; border-radius: 6px; border: 1px solid #333;"><b>' + r.author + '</b> <span style="float: right; color: #777; font-size: 11px;">' + new Date(r.timestamp).toLocaleString() + '</span><br><br><div>' + r.content + '</div></div>';
                });
            }

            let attachmentHtml = '';
            if (thread.attachment_name && thread.attachment_data) {
                attachmentHtml = '<div style="margin-top: 16px; padding: 12px; background: #222020; border: 1px solid #444; border-radius: 4px; display: flex; align-items: center; justify-content: space-between;"><span><b>Attachment:</b> ' + thread.attachment_name + '</span><button onclick="downloadAttachment(\'' + thread.attachment_data + '\', \'' + thread.attachment_name + '\')" style="width: auto; padding: 6px 14px; background: #2196f3; margin: 0;">Download File</button></div>';
            }

            let replyBoxHtml = `
                <div style="margin-top: 20px; padding: 16px; background: #222020; border-radius: 6px; border: 1px solid #444;">
                    <div style="display: flex; gap: 8px; margin-bottom: 10px;">
                        <button onclick="triggerReply('reply')" style="width: auto; padding: 6px 14px; background: #333; margin: 0;">Reply</button>
                        <button onclick="triggerReply('replyAll')" style="width: auto; padding: 6px 14px; background: #333; margin: 0;">Reply All</button>
                    </div>
                    <div id="reply-form" class="hidden">
                        <label style="font-size: 12px; color: #aaa;">Recipients (Multi-Select):</label>
                        <select id="reply-recipient-select" multiple style="height: 80px; margin-bottom: 8px;"></select>
                        <textarea id="reply-body" rows="3" placeholder="Type your reply..."></textarea>
                        <button onclick="sendReply()" style="width: auto; padding: 6px 14px; background: #2196f3; margin-top: 6px;">Send Reply</button>
                    </div>
                </div>
            `;

            let deleteBtnHtml = `<button onclick="deleteThread('${thread.thread_id}')" style="width: auto; padding: 6px 14px; background: #d32f2f; float: right; margin-top: 0;">Delete Thread</button>`;

            reader.innerHTML = deleteBtnHtml + '<h2>' + thread.subject + '</h2><p style="color: #888; font-size: 12px;">Thread: ' + thread.thread_id + ' | Sender: ' + thread.sender + '</p><hr style="border-color: #333; margin: 16px 0;">' + responsesHtml + attachmentHtml + replyBoxHtml;
        }

        let currentReplyMode = 'reply';
        function triggerReply(mode) {
            currentReplyMode = mode;
            const thread = allMailData.find(m => m.thread_id === selectedThreadId);
            if (!thread) return;

            const selectEl = document.getElementById('reply-recipient-select');
            selectEl.innerHTML = '';
            
            let defaultSelected = new Set();
            if (mode === 'reply') {
                defaultSelected.add(thread.sender === currentUser ? (thread.recipient ? thread.recipient.split(',')[0].trim() : '') : thread.sender);
            } else {
                if (thread.sender) defaultSelected.add(thread.sender);
                if (thread.recipient) {
                    thread.recipient.split(',').forEach(r => defaultSelected.add(r.trim()));
                }
                if (thread.responses) {
                    thread.responses.forEach(r => defaultSelected.add(r.author));
                }
                defaultSelected.delete(currentUser);
            }

            allAclUsers.forEach(u => {
                if (u !== currentUser) {
                    const isSel = defaultSelected.has(u);
                    selectEl.innerHTML += '<option value="' + u + '" ' + (isSel ? 'selected' : '') + '>' + u + '</option>';
                }
            });

            document.getElementById('reply-form').classList.remove('hidden');
        }

        async function sendReply() {
            const thread = allMailData.find(m => m.thread_id === selectedThreadId);
            if (!thread) return;

            const selectEl = document.getElementById('reply-recipient-select');
            const recipients = Array.from(selectEl.selectedOptions).map(opt => opt.value);
            const body = document.getElementById('reply-body').value;

            if (recipients.length === 0 || !body.trim()) {
                alert('Please select at least one recipient and enter a message.');
                return;
            }

            const res = await fetch('/api/mail/send?user=' + currentUser, {
                method: 'POST',
                headers: {
                    'content-type': 'application/json',
                    'x-trustless-fp': currentFingerprint
                },
                body: JSON.stringify({
                    recipients: recipients,
                    subject: thread.subject,
                    body: body,
                    thread_id: thread.thread_id
                })
            });

            if (res.status === 401) {
                alert('Session expired. Please log in again.');
                logout();
                return;
            }

            if (res.ok) {
                loadMail();
            } else {
                alert('Failed to send reply');
            }
        }

        async function deleteThread(threadId) {
            if (!confirm('Are you sure you want to delete this thread?')) return;
            const res = await fetch('/api/mail/delete?user=' + currentUser, {
                method: 'POST',
                headers: {
                    'content-type': 'application/json',
                    'x-trustless-fp': currentFingerprint
                },
                body: JSON.stringify({ thread_id: threadId })
            });

            if (res.status === 401) {
                alert('Session expired. Please log in again.');
                logout();
                return;
            }

            if (res.ok) {
                selectedThreadId = null;
                loadMail();
            } else {
                alert('Failed to delete thread');
            }
        }

        function downloadAttachment(base64Data, filename) {
            const arr = base64Data.split(',');
            const mime = arr[0].match(/:(.*?);/)[1];
            const bstr = atob(arr[1]);
            let n = bstr.length;
            const u8arr = new Uint8Array(n);
            while (n--) {
                u8arr[n] = bstr.charCodeAt(n);
            }
            const blob = new Blob([u8arr], {type: mime});
            const url = URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url;
            a.download = filename;
            document.body.appendChild(a);
            a.click();
            document.body.removeChild(a);
            URL.revokeObjectURL(url);
        }

        function openCompose() { document.getElementById('compose-modal').classList.remove('hidden'); }
        function closeCompose() { document.getElementById('compose-modal').classList.add('hidden'); }

        async function sendMail() {
            const selectEl = document.getElementById('recipient-select');
            const recipients = Array.from(selectEl.selectedOptions).map(opt => opt.value);
            const subject = document.getElementById('compose-subject').value;
            const body = document.getElementById('compose-body').value;
            const fileInput = document.getElementById('compose-file');

            if (recipients.length === 0) {
                alert('Please select at least one recipient.');
                return;
            }

            let attachmentName = null;
            let attachmentData = null;

            if (fileInput.files.length > 0) {
                const file = fileInput.files[0];
                attachmentName = file.name;
                attachmentData = await toBase64(file);
            }

            const res = await fetch('/api/mail/send?user=' + currentUser, {
                method: 'POST',
                headers: {
                    'content-type': 'application/json',
                    'x-trustless-fp': currentFingerprint
                },
                body: JSON.stringify({recipients, subject, body, attachment_name: attachmentName, attachment_data: attachmentData})
            });

            if (res.status === 401) {
                alert('Session expired. Please log in again.');
                logout();
                return;
            }

            if (res.ok) {
                closeCompose();
                loadMail();
            } else {
                alert('Failed to send mail');
            }
        }

        const toBase64 = file => new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.readAsDataURL(file);
            reader.onload = () => resolve(reader.result);
            reader.onerror = error => reject(error);
        });

        function logout() {
            localStorage.clear();
            location.reload();
        }
    </script>
</body>
</html>
    ''';
  }
}

class _MetalMailScreenState extends State<MetalMailScreen> with AutomaticKeepAliveClientMixin {
  Directory? _mailRootDir;
  String _activeFolder = 'inbox';
  List<Map<String, dynamic>> _loadedThreads = [];
  Map<String, dynamic>? _selectedThread;
  
  List<String> _allAclUsernames = [];
  String? _auditedUser;
  Map<String, dynamic>? _auditData;

  bool _isLoading = false;
  final ScrollController _scrollController = ScrollController();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _initializeMetalMailDirectory();
    if (!MetalMailScreen._hasInitializedServer) {
      MetalMailScreen._hasInitializedServer = true;
      _loadPersistedServerState();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadPersistedServerState() async {
    try {
      final store = StoreRef<String, dynamic>.main();
      final persistedState = await store.record(MetalMailScreen._dbKeyMailRunning).get(sembastDb) as bool? ?? false;
      if (persistedState) {
        await _toggleMailServer(true, silent: true);
      }
    } catch (e) {
      debugPrint('Failed to load persisted MetalMail state: $e');
    }
  }

  Future<void> _persistServerState(bool running) async {
    try {
      final store = StoreRef<String, dynamic>.main();
      await store.record(MetalMailScreen._dbKeyMailRunning).put(sembastDb, running);
    } catch (e) {
      debugPrint('Failed to save MetalMail state: $e');
    }
  }

  Future<void> _initializeMetalMailDirectory() async {
    final dir = Directory(p.join(appDirectoryPath, 'MetalMail'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    setState(() {
      _mailRootDir = dir;
    });
    await _loadUsersList();
    await _loadUserMailbox('admin');
  }

  Future<void> _loadUsersList() async {
    final users = await DbService().getAllUsers();
    setState(() {
      _allAclUsernames = users.map((u) => u.username).toList();
    });
  }

  Future<void> _loadUserMailbox(String username) async {
    if (_mailRootDir == null) return;
    setState(() {
      _isLoading = true;
      _selectedThread = null;
    });

    final threadsDir = Directory(p.join(_mailRootDir!.path, 'threads'));
    final indexFile = File(p.join(_mailRootDir!.path, 'users_index', '$username.json'));

    List<String> threadIds = [];
    if (await indexFile.exists()) {
      try {
        final idxData = jsonDecode(await indexFile.readAsString()) as Map<String, dynamic>;
        threadIds = List<String>.from(idxData[_activeFolder] ?? []);
      } catch (_) {}
    }

    final threads = <Map<String, dynamic>>[];
    for (var tid in threadIds) {
      final tFile = File(p.join(threadsDir.path, '$tid.metal'));
      if (await tFile.exists()) {
        try {
          threads.add(jsonDecode(await tFile.readAsString()) as Map<String, dynamic>);
        } catch (_) {}
      }
    }

    threads.sort((a, b) => (b['timestamp'] ?? '').compareTo(a['timestamp'] ?? ''));

    setState(() {
      _loadedThreads = threads;
      _isLoading = false;
      if (threads.isNotEmpty) {
        _selectedThread = threads.first;
      }
    });
  }

  Future<void> _computeAuditForUser(String username) async {
    if (_mailRootDir == null) return;
    final threadsDir = Directory(p.join(_mailRootDir!.path, 'threads'));
    final indexFile = File(p.join(_mailRootDir!.path, 'users_index', '$username.json'));

    List<String> inboxIds = [];
    List<String> sentIds = [];
    if (await indexFile.exists()) {
      try {
        final idxData = jsonDecode(await indexFile.readAsString()) as Map<String, dynamic>;
        inboxIds = List<String>.from(idxData['inbox'] ?? []);
        sentIds = List<String>.from(idxData['sent'] ?? []);
      } catch (_) {}
    }

    int sentCount = sentIds.length;
    int receivedCount = inboxIds.length - sentCount;
    if (receivedCount < 0) receivedCount = 0;

    int todaySent = 0;
    int weekSent = 0;
    int monthSent = 0;
    int halfYearSent = 0;

    final now = DateTime.now();
    final fileTypes = <String, int>{};
    final recipientCounts = <String, int>{};

    for (var tid in sentIds) {
      final tFile = File(p.join(threadsDir.path, '$tid.metal'));
      if (await tFile.exists()) {
        try {
          final tData = jsonDecode(await tFile.readAsString()) as Map<String, dynamic>;
          final tStamp = DateTime.tryParse(tData['timestamp'] ?? '') ?? now;
          final diff = now.difference(tStamp).inDays;

          if (diff <= 1) todaySent++;
          if (diff <= 7) weekSent++;
          if (diff <= 30) monthSent++;
          if (diff <= 180) halfYearSent++;

          final attName = tData['attachment_name'] as String?;
          if (attName != null && attName.contains('.')) {
            final ext = attName.split('.').last.toLowerCase();
            fileTypes[ext] = (fileTypes[ext] ?? 0) + 1;
          }

          final recs = tData['recipient']?.toString() ?? '';
          for (var r in recs.split(',')) {
            final trimmed = r.trim();
            if (trimmed.isNotEmpty) {
              recipientCounts[trimmed] = (recipientCounts[trimmed] ?? 0) + 1;
            }
          }
        } catch (_) {}
      }
    }

    setState(() {
      _auditedUser = username;
      _auditData = {
        'sentCount': sentCount,
        'receivedCount': receivedCount,
        'todaySent': todaySent,
        'weekSent': weekSent,
        'monthSent': monthSent,
        'halfYearSent': halfYearSent,
        'fileTypes': fileTypes,
        'recipients': recipientCounts,
      };
    });
  }

  Future<void> _toggleMailServer(bool enable, {bool silent = false}) async {
    await _persistServerState(enable);
    if (enable) {
      try {
        await MetalMailScreen._startServerHeadless();
        if (mounted) setState(() {});

        if (!silent && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('MetalMail HTTPS webmail server started on https://$deviceIpAddress:${MetalMailScreen._mailPort}')),
          );
        }
      } catch (e) {
        await _persistServerState(false);
        if (mounted) setState(() {});
      }
    } else {
      await MetalMailScreen._mailServer?.close(force: true);
      MetalMailScreen._mailServer = null;
      MetalMailScreen._isServerRunning = false;
      MetalMailScreen._activeSessionFingerprints.clear();
      if (mounted) setState(() {});
    }
  }

  Future<void> _showComposeDialog() async {
    final allUsers = await DbService().getAllUsers();
    final selectedRecipients = <String>{};
    final subjectController = TextEditingController();
    final bodyController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF262424),
          title: const Text('Compose New Message (Multi-Recipient)', style: TextStyle(color: Colors.white, fontSize: 14)),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Recipients (ACL List):', style: TextStyle(color: Colors.white70, fontSize: 12)),
                const SizedBox(height: 6),
                Container(
                  height: 120,
                  decoration: BoxDecoration(border: Border.all(color: Colors.white24), borderRadius: BorderRadius.circular(4)),
                  child: ListView.builder(
                    itemCount: allUsers.length,
                    itemBuilder: (context, index) {
                      final u = allUsers[index];
                      final isSelected = selectedRecipients.contains(u.username);
                      return CheckboxListTile(
                        title: Text(u.username, style: const TextStyle(color: Colors.white, fontSize: 12)),
                        value: isSelected,
                        activeColor: Colors.blueAccent,
                        dense: true,
                        onChanged: (val) {
                          setDialogState(() {
                            if (val == true) {
                              selectedRecipients.add(u.username);
                            } else {
                              selectedRecipients.remove(u.username);
                            }
                          });
                        },
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: subjectController,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(labelText: 'Subject', labelStyle: TextStyle(color: Colors.grey)),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: bodyController,
                  style: const TextStyle(color: Colors.white),
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: 'Message Body', labelStyle: TextStyle(color: Colors.grey)),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent, foregroundColor: Colors.white),
              onPressed: () async {
                final subject = subjectController.text.trim();
                final body = bodyController.text.trim();
                if (selectedRecipients.isNotEmpty && subject.isNotEmpty && body.isNotEmpty && _mailRootDir != null) {
                  const sender = 'admin';
                  final threadId = MetalMailScreen._deriveCanonicalThreadId(sender, selectedRecipients.toList(), subject);
                  final timestamp = DateTime.now().toIso8601String();

                  final threadsDir = Directory(p.join(_mailRootDir!.path, 'threads'));
                  if (!await threadsDir.exists()) await threadsDir.create(recursive: true);

                  final threadFile = File(p.join(threadsDir.path, '$threadId.metal'));
                  final packet = {
                    'thread_id': threadId,
                    'sender': sender,
                    'recipient': selectedRecipients.join(', '),
                    'subject': subject,
                    'timestamp': timestamp,
                    'attachment_name': null,
                    'attachment_data': null,
                    'responses': [
                      {
                        'author': sender,
                        'timestamp': timestamp,
                        'content': body,
                      }
                    ]
                  };
                  await threadFile.writeAsString(jsonEncode(packet));

                  final involvedUsers = {sender, ...selectedRecipients};
                  for (var user in involvedUsers) {
                    final indexFile = File(p.join(_mailRootDir!.path, 'users_index', '$user.json'));
                    Map<String, dynamic> idx = {'inbox': <String>[], 'sent': <String>[]};
                    if (await indexFile.exists()) {
                      try {
                        idx = jsonDecode(await indexFile.readAsString()) as Map<String, dynamic>;
                      } catch (_) {}
                    }
                    final inbox = List<String>.from(idx['inbox'] ?? []);
                    if (!inbox.contains(threadId)) inbox.insert(0, threadId);
                    idx['inbox'] = inbox;

                    if (user == sender) {
                      final sent = List<String>.from(idx['sent'] ?? []);
                      if (!sent.contains(threadId)) sent.insert(0, threadId);
                      idx['sent'] = sent;
                    }

                    await indexFile.parent.create(recursive: true);
                    await indexFile.writeAsString(jsonEncode(idx));
                  }

                  await _loadUserMailbox('admin');
                }
                Navigator.pop(context);
              },
              child: const Text('Send'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteThread(String threadId) async {
    if (_mailRootDir == null) return;
    final tFile = File(p.join(_mailRootDir!.path, 'threads', '$threadId.metal'));
    if (tFile.existsSync()) tFile.deleteSync();

    final usersIndexDir = Directory(p.join(_mailRootDir!.path, 'users_index'));
    if (usersIndexDir.existsSync()) {
      await for (var entity in usersIndexDir.list()) {
        if (entity is File && entity.path.endsWith('.json')) {
          try {
            final idx = jsonDecode(entity.readAsStringSync()) as Map<String, dynamic>;
            bool changed = false;
            if ((idx['inbox'] as List).contains(threadId)) {
              (idx['inbox'] as List).remove(threadId);
              changed = true;
            }
            if ((idx['sent'] as List).contains(threadId)) {
              (idx['sent'] as List).remove(threadId);
              changed = true;
            }
            if (changed) entity.writeAsStringSync(jsonEncode(idx));
          } catch (_) {}
        }
      }
    }
    await _loadUserMailbox('admin');
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final webmailUrl = 'https://$deviceIpAddress:${MetalMailScreen._mailPort}/webmail';

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
                      const Text('MetalMail Admin', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                      IconButton(
                        icon: const Icon(Icons.create, color: Colors.blueAccent, size: 18),
                        onPressed: _showComposeDialog,
                        tooltip: 'New Message',
                      ),
                    ],
                  ),
                ),
                Container(
                  margin: const EdgeInsets.all(8),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: MetalMailScreen._isServerRunning ? Colors.blue.withOpacity(0.1) : Colors.black12,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: MetalMailScreen._isServerRunning ? Colors.blueAccent.withOpacity(0.3) : Colors.white12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(MetalMailScreen._isServerRunning ? 'Server: Active' : 'Server: Stopped', style: TextStyle(color: MetalMailScreen._isServerRunning ? Colors.blueAccent : Colors.grey, fontSize: 11, fontWeight: FontWeight.bold)),
                          Switch(
                            value: MetalMailScreen._isServerRunning,
                            onChanged: (val) => _toggleMailServer(val),
                            activeColor: Colors.blueAccent,
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text('Port: ${MetalMailScreen._mailPort} (HTTPS)', style: const TextStyle(color: Colors.white60, fontSize: 10)),
                    ],
                  ),
                ),
                const Divider(color: Colors.white12),
                ListTile(
                  selected: _activeFolder == 'inbox',
                  selectedTileColor: Colors.blue.withOpacity(0.15),
                  leading: const Icon(Icons.inbox, color: Colors.blueAccent, size: 16),
                  title: const Text('Admin Inbox', style: TextStyle(color: Colors.white, fontSize: 12)),
                  onTap: () {
                    setState(() => _activeFolder = 'inbox');
                    _loadUserMailbox('admin');
                  },
                ),
                ListTile(
                  selected: _activeFolder == 'sent',
                  selectedTileColor: Colors.blue.withOpacity(0.15),
                  leading: const Icon(Icons.send, color: Colors.cyanAccent, size: 16),
                  title: const Text('Admin Sent Items', style: TextStyle(color: Colors.white, fontSize: 12)),
                  onTap: () {
                    setState(() => _activeFolder = 'sent');
                    _loadUserMailbox('admin');
                  },
                ),
                const Divider(color: Colors.white12),
                Expanded(
                  child: _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : _loadedThreads.isEmpty
                          ? const Center(child: Text('No messages in folder.', style: TextStyle(color: Colors.white38, fontSize: 11)))
                          : ListView.builder(
                              controller: _scrollController,
                              itemCount: _loadedThreads.length,
                              itemBuilder: (context, index) {
                                final thread = _loadedThreads[index];
                                final isSelected = _selectedThread?['thread_id'] == thread['thread_id'];
                                final subject = thread['subject'] ?? 'No Subject';
                                final sender = thread['sender'] ?? 'unknown';
                                final hasAttachment = thread['attachment_name'] != null;

                                return ListTile(
                                  selected: isSelected,
                                  selectedTileColor: Colors.blue.withOpacity(0.2),
                                  title: Row(
                                    children: [
                                      Expanded(child: Text(subject, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis)),
                                      if (hasAttachment) const Icon(Icons.attach_file, size: 14, color: Colors.grey),
                                    ],
                                  ),
                                  subtitle: Text('From: $sender', style: const TextStyle(color: Colors.grey, fontSize: 10)),
                                  onTap: () => setState(() => _selectedThread = thread),
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
                      const Text('MetalMail Webportal & Inspect', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                      Row(
                        children: [
                          const Text('Webmail URL: ', style: TextStyle(color: Colors.grey, fontSize: 11)),
                          SelectableText(webmailUrl, style: const TextStyle(color: Colors.blueAccent, fontSize: 11, fontFamily: 'monospace')),
                        ],
                      ),
                    ],
                  ),
                  const Divider(color: Colors.white12, height: 24),
                  Expanded(
                    child: _selectedThread == null
                        ? const Center(child: Text('No messages found or none selected.', style: TextStyle(color: Colors.grey)))
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(_selectedThread!['subject'] ?? '', style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                                        const SizedBox(height: 4),
                                        Text('Thread ID: ${_selectedThread!['thread_id']} \vert{} Sender:${_selectedThread!['sender']}', style: const TextStyle(color: Colors.grey, fontSize: 11)),
                                      ],
                                    ),
                                  ),
                                  ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade700, foregroundColor: Colors.white),
                                    icon: const Icon(Icons.delete, size: 16),
                                    label: const Text('Delete Thread'),
                                    onPressed: () async {
                                      final threadId = _selectedThread!['thread_id'];
                                      await _deleteThread(threadId);
                                    },
                                  ),
                                ],
                              ),
                              if (_selectedThread!['attachment_name'] != null) ...[
                                const SizedBox(height: 8),
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(color: const Color(0xFF262424), borderRadius: BorderRadius.circular(6), border: Border.all(color: Colors.white12)),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.attachment, size: 14, color: Colors.blueAccent),
                                      const SizedBox(width: 6),
                                      Text(_selectedThread!['attachment_name'], style: const TextStyle(color: Colors.blueAccent, fontSize: 12)),
                                    ],
                                  ),
                                ),
                              ],
                              const Divider(color: Colors.white12, height: 20),
                              Expanded(
                                child: ListView.builder(
                                  itemCount: (_selectedThread!['responses'] as List).length,
                                  itemBuilder: (context, index) {
                                    final responses = (_selectedThread!['responses'] as List).reversed.toList();
                                    final response = responses[index];
                                    final author = response['author'];
                                    final timestamp = response['timestamp'];
                                    final content = response['content'];

                                    return Container(
                                      margin: const EdgeInsets.symmetric(vertical: 6),
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF262424),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(color: Colors.white12),
                                      ),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                            children: [
                                              Text(author, style: const TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold, fontSize: 12)),
                                              Text(timestamp, style: const TextStyle(color: Colors.grey, fontSize: 10)),
                                            ],
                                          ),
                                          const SizedBox(height: 8),
                                          Text(content, style: const TextStyle(color: Colors.white70, fontSize: 13)),
                                        ],
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
            ),
          ),
          const VerticalDivider(width: 1, color: Colors.white12),

          Container(
            width: 300,
            color: const Color(0xFF222020),
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('User Audit Dashboard', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                const SizedBox(height: 8),
                const Text('Select user to inspect metrics:', style: TextStyle(color: Colors.grey, fontSize: 11)),
                const SizedBox(height: 8),
                SizedBox(
                  height: 120,
                  child: ListView.builder(
                    itemCount: _allAclUsernames.length,
                    itemBuilder: (context, index) {
                      final uname = _allAclUsernames[index];
                      final isAudited = _auditedUser == uname;
                      return ListTile(
                        selected: isAudited,
                        selectedTileColor: Colors.blue.withOpacity(0.2),
                        dense: true,
                        title: Text(uname, style: const TextStyle(color: Colors.white, fontSize: 12)),
                        onTap: () => _computeAuditForUser(uname),
                      );
                    },
                  ),
                ),
                const Divider(color: Colors.white12),
                Expanded(
                  child: _auditedUser == null
                      ? const Center(child: Text('No user selected for audit.', style: TextStyle(color: Colors.white38, fontSize: 11)))
                      : ListView(
                          children: [
                            Text('Audit: $_auditedUser', style: const TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold, fontSize: 13)),
                            const SizedBox(height: 12),
                            const Text('Sent vs Received Volume', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Expanded(
                                  child: Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(color: const Color(0xFF1c1a1a), borderRadius: BorderRadius.circular(4)),
                                    child: Column(
                                      children: [
                                        const Text('Sent', style: TextStyle(color: Colors.grey, fontSize: 10)),
                                        const SizedBox(height: 4),
                                        Text('${_auditData!['sentCount']}', style: const TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold, fontSize: 14)),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(color: const Color(0xFF1c1a1a), borderRadius: BorderRadius.circular(4)),
                                    child: Column(
                                      children: [
                                        const Text('Received', style: TextStyle(color: Colors.grey, fontSize: 10)),
                                        const SizedBox(height: 4),
                                        Text('${_auditData!['receivedCount']}', style: const TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold, fontSize: 14)),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            const Text('Timeframe Breakdown (Sent)', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
                            const SizedBox(height: 6),
                            Text('• Today: ${_auditData!['todaySent']}', style: const TextStyle(color: Colors.white70, fontSize: 11)),
                            Text('• Last 7 Days: ${_auditData!['weekSent']}', style: const TextStyle(color: Colors.white70, fontSize: 11)),
                            Text('• Last 30 Days: ${_auditData!['monthSent']}', style: const TextStyle(color: Colors.white70, fontSize: 11)),
                            Text('• Last 6 Months: ${_auditData!['halfYearSent']}', style: const TextStyle(color: Colors.white70, fontSize: 11)),
                            const SizedBox(height: 16),
                            const Text('File Attachments Sent', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
                            const SizedBox(height: 6),
                            ...((_auditData!['fileTypes'] as Map<String, int>).entries.isEmpty
                                ? [const Text('None', style: TextStyle(color: Colors.grey, fontSize: 11))]
                                : (_auditData!['fileTypes'] as Map<String, int>).entries.map((e) => Text('• .${e.key}:${e.value}', style: const TextStyle(color: Colors.white70, fontSize: 11)))),
                            const SizedBox(height: 16),
                            const Text('Top Recipients Contacted', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
                            const SizedBox(height: 6),
                            ...((_auditData!['recipients'] as Map<String, int>).entries.isEmpty
                                ? [const Text('None', style: TextStyle(color: Colors.grey, fontSize: 11))]
                                : (_auditData!['recipients'] as Map<String, int>).entries.map((e) => Text('• ${e.key}:${e.value} times', style: const TextStyle(color: Colors.white70, fontSize: 11)))),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}