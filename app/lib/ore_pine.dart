import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:sembast/sembast.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'main.dart';
import 'db_service.dart';
import 'metal_mail.dart';

class OrePineScreen extends StatefulWidget {
  final String searchQuery;
  const OrePineScreen({super.key, required this.searchQuery});

  @override
  State<OrePineScreen> createState() => _OrePineScreenState();

  // --- Static Server State & Methods ---
  static HttpServer? _orePineServer;
  static bool _isServerRunning = false;
  
  static final int _serverPort = 41940;
  static const String _dbKeyRunning = 'ore_pine_server_running';
  static const String _dbKeyModels = 'ore_pine_ai_models';
  static const String _dbKeyCache = 'ore_pine_query_cache';
  static const String _dbKeyLimits = 'ore_pine_user_limits';

  // Session-based trustless fingerprint registry (cleared on server restart/reboot)
  static final Set<String> _activeSessionFingerprints = <String>{};

  static Future<void> startServerIfEnabled() async {
    try {
      final dir = Directory(p.join(appDirectoryPath, 'OrePineStore'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      final store = StoreRef<String, dynamic>.main();
      final persistedState = await store.record(_dbKeyRunning).get(sembastDb) as bool? ?? false;
      
      if (!persistedState) {
        if (_isServerRunning) {
          await _orePineServer?.close(force: true);
          _orePineServer = null;
          _isServerRunning = false;
          _activeSessionFingerprints.clear();
          debugPrint('[OrePine] Server stopped automatically (User disabled).');
        }
        return;
      }

      bool withinHours = true;
      try {
        final timeConfigStore = stringMapStoreFactory.store('system_time_config');
        final configMap = await timeConfigStore.record('config').get(sembastDb);
        if (configMap != null && configMap['schedules'] != null) {
          final schedules = Map<String, dynamic>.from(configMap['schedules'] as Map);
          final scheduleStr = schedules['OrePine']?.toString().trim() ?? '24/7 Active';
          
          final lower = scheduleStr.toLowerCase();
          if (lower.isNotEmpty && !lower.contains('24/7') && !lower.contains('active')) {
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
      } catch (_) {
        withinHours = true;
      }

      final shouldBeRunning = persistedState && withinHours;
      if (shouldBeRunning && !_isServerRunning) {
        await _startServerHeadless();
        debugPrint('[OrePine] Server started automatically.');
      } else if (!shouldBeRunning && _isServerRunning) {
        await _orePineServer?.close(force: true);
        _orePineServer = null;
        _isServerRunning = false;
        _activeSessionFingerprints.clear();
        debugPrint('[OrePine] Server stopped (Outside hours).');
      }
    } catch (e) {
      debugPrint('[OrePine] Evaluation error: $e');
    }
  }

  static double _calculateSentenceSimilarity(String a, String b) {
    final wordsA = a.toLowerCase().replaceAll(RegExp(r'[^\w\s]'), '').split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final wordsB = b.toLowerCase().replaceAll(RegExp(r'[^\w\s]'), '').split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (wordsA.isEmpty || wordsB.isEmpty) return 0.0;

    final setA = wordsA.toSet();
    final setB = wordsB.toSet();
    final intersection = setA.intersection(setB).length;
    final union = setA.union(setB).length;
    return intersection / union;
  }

  static Future<String?> _findCachedResponse(String query) async {
    try {
      final isSingleSentence = !query.contains(RegExp(r'[.!?](\s+|$)'));
      if (!isSingleSentence) return null;

      final cacheStore = stringMapStoreFactory.store(_dbKeyCache);
      final records = await cacheStore.find(sembastDb);
      
      for (var record in records) {
        final cachedQuery = record.value['query']?.toString() ?? '';
        final response = record.value['response']?.toString() ?? '';
        
        final similarity = _calculateSentenceSimilarity(query, cachedQuery);
        if (similarity >= 0.90) {
          return response;
        }
      }
    } catch (e) {
      debugPrint('[OrePine] Cache lookup error: $e');
    }
    return null;
  }

  static Future<void> _cacheQueryResponse(String query, String response) async {
    try {
      final cacheStore = stringMapStoreFactory.store(_dbKeyCache);
      await cacheStore.add(sembastDb, {
        'query': query,
        'response': response,
        'timestamp': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      debugPrint('[OrePine] Cache write error: $e');
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
        final path = request.url.path;

        // Serve static asset fingerprint2.min.js
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

        if (path == '' || path == 'index.html') {
          final htmlContent = '''
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>OrePine AI Gateway</title>
    <style>
        :root {
            --bg-dark: #121010;
            --panel-bg: #1c1a1a;
            --border-color: #332f2f;
            --accent-cyan: #00ffff;
            --accent-green: #aaffaa;
            --text-main: #eceff1;
            --text-muted: #888;
        }
        body { background: var(--bg-dark); color: var(--text-main); font-family: monospace; margin: 0; display: flex; height: 100vh; overflow: hidden; }
        .login-container { max-width: 400px; margin: 100px auto; background: var(--panel-bg); padding: 24px; border-radius: 8px; border: 1px solid var(--border-color); width: 100%; box-sizing: border-box; }
        input, select, textarea, button { width: 100%; padding: 10px; margin: 8px 0; background: #121010; color: white; border: 1px solid #444; border-radius: 4px; box-sizing: border-box; font-family: monospace; }
        button { background: var(--accent-cyan); color: black; font-weight: bold; cursor: pointer; border: none; }
        button:hover { opacity: 0.9; }
        .hidden { display: none !important; }

        .app-layout { display: flex; width: 100vw; height: 100vh; }
        .sidebar { width: 280px; background: var(--panel-bg); border-right: 1px solid var(--border-color); display: flex; flex-direction: column; padding: 16px; box-sizing: border-box; }
        .sidebar h2 { font-size: 16px; margin-top: 0; color: var(--accent-cyan); display: flex; align-items: center; justify-content: space-between; }
        .btn-new { background: var(--accent-cyan); color: #000; border: none; padding: 10px; font-weight: bold; border-radius: 6px; cursor: pointer; width: 100%; margin-bottom: 12px; }
        .thread-list { flex: 1; overflow-y: auto; margin-bottom: 12px; }
        .thread-item { padding: 10px; border-radius: 6px; cursor: pointer; margin-bottom: 6px; background: #222020; border: 1px solid transparent; font-size: 13px; display: flex; justify-content: space-between; align-items: center; }
        .thread-item span { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; flex: 1; }
        .thread-item:hover { background: #2c2929; }
        .thread-item.active { border-color: var(--accent-cyan); background: #262424; }
        .edit-btn { background: none; border: none; color: var(--text-muted); cursor: pointer; font-size: 12px; }
        .edit-btn:hover { color: #fff; }
        
        .io-buttons { display: flex; gap: 6px; }
        .btn-io { flex: 1; background: #2a2727; color: var(--text-main); border: 1px solid var(--border-color); padding: 8px; font-size: 11px; border-radius: 4px; cursor: pointer; }
        .btn-io:hover { background: #333; }

        .chat-main { flex: 1; display: flex; flex-direction: column; background: var(--bg-dark); }
        .chat-header { padding: 16px; background: var(--panel-bg); border-bottom: 1px solid var(--border-color); display: flex; align-items: center; justify-content: space-between; }
        
        #chatbox { flex: 1; overflow-y: auto; padding: 20px; display: flex; flex-direction: column; gap: 12px; }
        .msg { max-width: 75%; padding: 12px 16px; border-radius: 8px; line-height: 1.4; font-size: 13px; word-break: break-word; }
        .msg.user { align-self: flex-end; background: #243b24; color: var(--accent-green); border: 1px solid #2f4f2f; }
        .msg.ai { align-self: flex-start; background: #1a2f2f; color: var(--accent-cyan); border: 1px solid #1f3f3f; }
        .msg-sender { font-weight: bold; margin-bottom: 4px; font-size: 11px; opacity: 0.7; }

        .chat-input-area { padding: 16px; background: var(--panel-bg); border-top: 1px solid var(--border-color); display: flex; gap: 10px; }
        .btn-send { background: var(--accent-cyan); color: #000; border: none; padding: 0 20px; font-weight: bold; border-radius: 6px; cursor: pointer; width: auto; }
        .limit-badge { font-size: 11px; color: #ffaa66; background: #332211; padding: 4px 8px; border-radius: 4px; }
        
        .stats-panel { padding: 10px; background: #181616; border-top: 1px solid var(--border-color); font-size: 11px; color: var(--text-muted); }
    </style>
    <!-- Load fingerprint2.min.js only when loading the page / authenticating -->
    <script src="/fingerprint2.min.js"></script>
</head>
<body>
    <div id="login-form" class="login-container">
        <h2>OrePine Gateway Login</h2>
        <input type="text" id="username" placeholder="ACL Username" />
        <input type="password" id="password" placeholder="Password" />
        <input type="text" id="totp" placeholder="TOTP 2FA Code (if enabled)" />
        <button onclick="login()">Authenticate</button>
        <p id="error-msg" style="color: #ff5252; font-size: 12px;"></p>
    </div>

    <div id="app-view" class="app-layout hidden">
        <div class="sidebar">
            <h2>OrePine AI <span>🌲</span></h2>
            <button class="btn-new" onclick="createNewThread()">+ New Thread</button>
            <div class="thread-list" id="threadList"></div>
            <div class="io-buttons">
                <button class="btn-io" onclick="exportThreads()">Export JSON</button>
                <button class="btn-io" onclick="document.getElementById('importFile').click()">Import JSON</button>
                <input type="file" id="importFile" style="display:none" onchange="importThreads(event)" accept=".json">
            </div>
            <div style="margin-top: 10px;">
                <button class="btn-io" style="background: #a93226; color: white;" onclick="logout()">Logout</button>
            </div>
        </div>

        <div class="chat-main">
            <div class="chat-header">
                <span id="currentThreadTitle" style="font-weight: bold;">Select or start a chat</span>
                <div style="display: flex; gap: 15px; align-items: center;">
                    <div class="limit-badge" id="usageLimitBadge">Token Cap: 0 / 10,000</div>
                    <div>
                        <label style="font-size: 12px; color: var(--text-muted); margin-right: 6px;">Model:</label>
                        <select id="modelSelect" onchange="updateModelStats()"></select>
                    </div>
                </div>
            </div>
            <div id="chatbox">
                <div style="text-align: center; color: var(--text-muted); margin-top: auto; margin-bottom: auto;">
                    Select a thread from the sidebar or click "+ New Thread" to begin.
                </div>
            </div>
            <div class="stats-panel" id="modelStatsPanel">
                Selected Model Rate Limit Stats: Select a model to inspect.
            </div>
            <div class="chat-input-area">
                <input type="text" id="queryInput" placeholder="Ask policy, documentation, or query AI..." onkeydown="if(event.key==='Enter') sendQuery()">
                <button class="btn-send" onclick="sendQuery()">Send</button>
            </div>
        </div>
    </div>

    <script>
        let db;
        let activeThreadId = null;
        let currentUser = localStorage.getItem('ore_pine_user');
        let currentFingerprint = localStorage.getItem('ore_pine_fp');
        let userTokensUsed = 0;
        let tokenLimit = 10000;
        let availableModels = [];

        if (currentUser && currentFingerprint) showApp();

        async function generateFingerprint() {
            return new Promise((resolve) => {
                if (typeof Fingerprint2 === 'undefined') {
                    resolve('fallback_fp_' + Math.random());
                    return;
                }
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
            
            const fp = await generateFingerprint();

            const res = await fetch('/api/auth/login', {
                method: 'POST',
                headers: {'content-type': 'application/json', 'x-trustless-fp': fp},
                body: JSON.stringify({username: u, password: p, totp: t, fingerprint: fp})
            });
            const data = await res.json();
            if (res.ok) {
                localStorage.setItem('ore_pine_user', data.username);
                localStorage.setItem('ore_pine_fp', fp);
                currentUser = data.username;
                currentFingerprint = fp;
                showApp();
            } else {
                document.getElementById('error-msg').innerText = data.error || 'Login failed';
            }
        }

        function showApp() {
            document.getElementById('login-form').classList.add('hidden');
            document.getElementById('app-view').classList.remove('hidden');
            initIndexedDB();
            loadModels();
            loadUserUsage();
        }

        function logout() {
            localStorage.removeItem('ore_pine_user');
            localStorage.removeItem('ore_pine_fp');
            location.reload();
        }

        function initIndexedDB() {
            const request = indexedDB.open("OrePineClientDB_" + currentUser, 3);
            request.onupgradeneeded = event => {
                db = event.target.result;
                if (!db.objectStoreNames.contains("threads")) {
                    db.createObjectStore("threads", { keyPath: "id" });
                }
                if (!db.objectStoreNames.contains("messages")) {
                    const msgStore = db.createObjectStore("messages", { keyPath: "id", autoIncrement: true });
                    msgStore.createIndex("threadId", "threadId", { unique: false });
                }
            };
            request.onsuccess = event => {
                db = event.target.result;
                loadThreads();
            };
        }

        async function loadModels() {
            try {
                const res = await fetch('/api/models', {
                    headers: { 'x-trustless-fp': currentFingerprint }
                });
                const data = await res.json();
                availableModels = data.models || [];
                const select = document.getElementById('modelSelect');
                select.innerHTML = '';
                if (availableModels.length === 0) {
                    let opt = document.createElement('option');
                    opt.textContent = 'No models available';
                    select.appendChild(opt);
                    return;
                }
                availableModels.forEach(m => {
                    let opt = document.createElement('option');
                    opt.value = m.name;
                    opt.textContent = m.name;
                    select.appendChild(opt);
                });
                updateModelStats();
            } catch(e) { console.error('Failed loading models', e); }
        }

        function updateModelStats() {
            const selectedName = document.getElementById('modelSelect').value;
            const model = availableModels.find(m => m.name === selectedName);
            const panel = document.getElementById('modelStatsPanel');
            if (model) {
                panel.innerHTML = `Model: <b>\${model.name}</b> | Trustless FP Verified: <b>Active</b> | Rate Limit Cap: <b>\${model.perModelCap || 5000} Tokens</b>`;
            } else {
                panel.innerHTML = `No model selected or available.`;
            }
        }

        async function loadUserUsage() {
            try {
                const res = await fetch('/api/usage?user=' + currentUser, {
                    headers: { 'x-trustless-fp': currentFingerprint }
                });
                const data = await res.json();
                userTokensUsed = data.tokens || 0;
                if (data.overallCap) tokenLimit = data.overallCap;
                document.getElementById('usageLimitBadge').textContent = `Token Cap: \${userTokensUsed} / \${tokenLimit}`;
            } catch(e) {}
        }

        function createNewThread() {
            if(!db) return;
            const id = 'thread_' + Date.now();
            const title = 'New Conversation';
            
            const tx = db.transaction(["threads"], "readwrite");
            tx.objectStore("threads").add({ id, title, createdAt: new Date() });
            tx.oncomplete = () => {
                loadThreads(id);
            };
        }

        function loadThreads(selectId = null) {
            if(!db) return;
            const tx = db.transaction(["threads"], "readonly");
            const store = tx.objectStore("threads");
            const req = store.getAll();
            req.onsuccess = () => {
                const list = req.result;
                const container = document.getElementById('threadList');
                container.innerHTML = '';
                
                if (list.length === 0) {
                    createNewThread();
                    return;
                }

                list.sort((a,b) => new Date(b.createdAt) - new Date(a.createdAt));
                list.forEach((t, index) => {
                    if (!activeThreadId && index === 0) activeThreadId = t.id;
                    if (selectId && t.id === selectId) activeThreadId = t.id;

                    const div = document.createElement('div');
                    div.className = 'thread-item ' + (t.id === activeThreadId ? 'active' : '');
                    
                    const span = document.createElement('span');
                    span.textContent = t.title;
                    span.onclick = () => switchThread(t.id, t.title);
                    
                    const btn = document.createElement('button');
                    btn.className = 'edit-btn';
                    btn.textContent = '✏️';
                    btn.onclick = (e) => {
                        e.stopPropagation();
                        renameThread(t.id, t.title);
                    };

                    div.appendChild(span);
                    div.appendChild(btn);
                    container.appendChild(div);
                });

                if (activeThreadId) {
                    const activeObj = list.find(x => x.id === activeThreadId);
                    if(activeObj) document.getElementById('currentThreadTitle').textContent = activeObj.title;
                    loadMessages(activeThreadId);
                }
            };
        }

        function renameThread(id, currentTitle) {
            const newTitle = prompt("Enter new thread title:", currentTitle);
            if (!newTitle || !newTitle.trim()) return;
            const tx = db.transaction(["threads"], "readwrite");
            const store = tx.objectStore("threads");
            store.get(id).onsuccess = (e) => {
                const t = e.target.result;
                if(t) {
                    t.title = newTitle.trim();
                    store.put(t);
                    loadThreads(id);
                }
            };
        }

        function switchThread(id, title) {
            activeThreadId = id;
            document.getElementById('currentThreadTitle').textContent = title;
            document.querySelectorAll('.thread-item').forEach(el => el.classList.remove('active'));
            event.currentTarget.classList.add('active');
            loadMessages(id);
        }

        function loadMessages(threadId) {
            const box = document.getElementById('chatbox');
            box.innerHTML = '';
            const tx = db.transaction(["messages"], "readonly");
            const index = tx.objectStore("messages").index("threadId");
            const req = index.getAll(threadId);
            req.onsuccess = () => {
                req.result.forEach(m => {
                    appendMessageUI(m.sender, m.text, m.className);
                });
            };
        }

        function appendMessageUI(sender, text, className) {
            const box = document.getElementById('chatbox');
            const div = document.createElement('div');
            div.className = 'msg ' + className;
            div.innerHTML = `<div class="msg-sender">\${sender}</div><div>\${text}</div>`;
            box.appendChild(div);
            box.scrollTop = box.scrollHeight;
        }

        async function sendQuery() {
            if(!activeThreadId) return;
            const input = document.getElementById('queryInput');
            const query = input.value.trim();
            const model = document.getElementById('modelSelect').value;
            if(!query || !model || model.includes('No models')) return;

            if (userTokensUsed + query.length > tokenLimit) {
                alert('Token cap reached! You have been rate limited.');
                return;
            }

            appendMessageUI('User', query, 'user');
            saveMessageToDB(activeThreadId, 'User', query, 'user', true);
            input.value = '';

            try {
                const res = await fetch('/api/query?user=' + currentUser, {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json',
                        'x-trustless-fp': currentFingerprint
                    },
                    body: JSON.stringify({ query, model })
                });
                
                if (res.status === 401) {
                    alert('Trustless fingerprint session expired or invalid. Please log in again.');
                    logout();
                    return;
                }

                const data = await res.json();
                appendMessageUI('AI (' + (data.source || 'model') + ')', data.response, 'ai');
                saveMessageToDB(activeThreadId, 'AI', data.response, 'ai', false);

                userTokensUsed += (query.length + data.response.length);
                document.getElementById('usageLimitBadge').textContent = `Token Cap: \${userTokensUsed} / \${tokenLimit}`;

                await fetch('/api/track-usage?user=' + currentUser, {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json',
                        'x-trustless-fp': currentFingerprint
                    },
                    body: JSON.stringify({ tokens: query.length + data.response.length, model: model })
                });
            } catch(e) {
                appendMessageUI('System', 'Error communicating with OrePine gateway.', 'ai');
            }
        }

        function saveMessageToDB(threadId, sender, text, className, isFirstQuery) {
            if(!db) return;
            const tx = db.transaction(["messages", "threads"], "readwrite");
            tx.objectStore("messages").add({ threadId, sender, text, className, timestamp: new Date() });

            if (isFirstQuery) {
                const threadStore = tx.objectStore("threads");
                threadStore.get(threadId).onsuccess = (e) => {
                    const t = e.target.result;
                    if (t && t.title === 'New Conversation') {
                        t.title = text.length > 25 ? text.substring(0, 25) + '...' : text;
                        threadStore.put(t);
                        loadThreads(threadId);
                    }
                };
            }
        }

        async function exportThreads() {
            if(!db) return;
            const tx = db.transaction(["threads", "messages"], "readonly");
            const threads = await new Promise(resolve => tx.objectStore("threads").getAll().onsuccess = e => resolve(e.target.result));
            const messages = await new Promise(resolve => tx.objectStore("messages").getAll().onsuccess = e => resolve(e.target.result));

            const exportData = { threads, messages };
            const blob = new Blob([JSON.stringify(exportData, null, 2)], {type: 'application/json'});
            const url = URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url;
            a.download = 'ore_pine_chat_backup_' + currentUser + '.json';
            a.click();
        }

        async function importThreads(event) {
            const file = event.target.files[0];
            if(!file) return;
            const reader = new FileReader();
            reader.onload = async function(e) {
                try {
                    const data = JSON.parse(e.target.result);
                    const tx = db.transaction(["threads", "messages"], "readwrite");
                    if (data.threads) {
                        data.threads.forEach(t => tx.objectStore("threads").put(t));
                    }
                    if (data.messages) {
                        data.messages.forEach(m => tx.objectStore("messages").put(m));
                    }
                    tx.oncomplete = () => {
                        alert('Threads successfully imported!');
                        loadThreads();
                    };
                } catch(err) {
                    alert('Invalid backup JSON file.');
                }
            };
            reader.readAsText(file);
        }
    </script>
</body>
</html>
''';
          return shelf.Response.ok(htmlContent, headers: {'content-type': 'text/html; charset=utf-8'});
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

        // Authentication endpoint
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
              if (user.totpSecret.isEmpty || !MetalMailScreen.verifyTotpCode(user.totpSecret, totpCode)) {
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

        if (path == 'api/models') {
          final store = stringMapStoreFactory.store(OrePineScreen._dbKeyModels);
          final models = await store.find(sembastDb);
          final modelList = models.map((m) => m.value).toList();
          return shelf.Response.ok(jsonEncode({'models': modelList}), headers: {'content-type': 'application/json'});
        }

        final userQueryParam = request.url.queryParameters['user'] ?? 'guest';

        if (path == 'api/usage') {
          final limitStore = stringMapStoreFactory.store(OrePineScreen._dbKeyLimits);
          final userMap = await limitStore.record(userQueryParam).get(sembastDb) as Map<String, dynamic>? ?? {'tokens': 0, 'overallCap': 10000};
          return shelf.Response.ok(jsonEncode(userMap), headers: {'content-type': 'application/json'});
        }

        if (request.method == 'POST' && path == 'api/track-usage') {
          try {
            final bodyStr = await request.readAsString();
            final body = jsonDecode(bodyStr) as Map<String, dynamic>;
            final tokens = body['tokens'] as int? ?? 0;
            final modelName = body['model'] as String? ?? 'default';
            
            final limitStore = stringMapStoreFactory.store(OrePineScreen._dbKeyLimits);
            final userMap = Map<String, dynamic>.from(await limitStore.record(userQueryParam).get(sembastDb) as Map? ?? {'tokens': 0, 'overallCap': 10000});
            
            final currentUsage = (userMap['tokens'] as num?)?.toInt() ?? 0;
            userMap['tokens'] = currentUsage + tokens;

            final modelCaps = Map<String, dynamic>.from(userMap['modelCaps'] as Map? ?? {});
            final modelUsage = (modelCaps[modelName] as num?)?.toInt() ?? 0;
            modelCaps[modelName] = modelUsage + tokens;
            userMap['modelCaps'] = modelCaps;
            
            await limitStore.record(userQueryParam).put(sembastDb, userMap);

            return shelf.Response.ok(jsonEncode({'success': true}));
          } catch (_) {
            return shelf.Response.internalServerError(body: 'Tracking error');
          }
        }

        if (request.method == 'POST' && path == 'api/query') {
          try {
            final bodyStr = await request.readAsString();
            final body = jsonDecode(bodyStr) as Map<String, dynamic>;
            final query = body['query']?.toString() ?? '';
            final model = body['model']?.toString() ?? 'Default';

            final cached = await _findCachedResponse(query);
            if (cached != null) {
              return shelf.Response.ok(jsonEncode({'response': cached, 'source': 'sembast_cache'}), headers: {'content-type': 'application/json'});
            }

            String responseText = "AI Response generated via model [$model] for: \"$query\".";
            await _cacheQueryResponse(query, responseText);
            return shelf.Response.ok(jsonEncode({'response': responseText, 'source': 'upstream'}), headers: {'content-type': 'application/json'});
          } catch (e) {
            return shelf.Response.internalServerError(body: jsonEncode({'error': e.toString()}));
          }
        }

        return shelf.Response.notFound('Endpoint not found');
      };

      _orePineServer = await shelf_io.serve(handler, '0.0.0.0', _serverPort, securityContext: securityContext);
      _isServerRunning = true;
      debugPrint('[OrePine] Server running on port $_serverPort.');
    } catch (e) {
      _isServerRunning = false;
      debugPrint('[OrePine] Start error: $e');
    }
  }
}

class _OrePineScreenState extends State<OrePineScreen> {
  bool _isRunning = false;
  List<Map<String, dynamic>> _models = [];
  List<UserAccount> _users = [];
  Map<String, Map<String, dynamic>> _userLimitsData = {};
  
  final TextEditingController _modelNameController = TextEditingController();
  final TextEditingController _tokenController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadState();
  }

  Future<void> _loadState() async {
    final store = StoreRef<String, dynamic>.main();
    final running = await store.record(OrePineScreen._dbKeyRunning).get(sembastDb) as bool? ?? false;
    
    final modelStore = stringMapStoreFactory.store(OrePineScreen._dbKeyModels);
    final savedModels = await modelStore.find(sembastDb);

    final users = await DbService().getAllUsers();
    
    final limitStore = stringMapStoreFactory.store(OrePineScreen._dbKeyLimits);
    final limitRecords = await limitStore.find(sembastDb);
    Map<String, Map<String, dynamic>> limitsMap = {};
    for (var rec in limitRecords) {
      limitsMap[rec.key] = Map<String, dynamic>.from(rec.value as Map? ?? {});
    }

    if (mounted) {
      setState(() {
        _isRunning = running;
        _models = savedModels.map((m) => Map<String, dynamic>.from(m.value)).toList();
        _users = users;
        _userLimitsData = limitsMap;
      });
    }
  }

  Future<void> _toggleServer(bool val) async {
    if (val) {
      await OrePineScreen._startServerHeadless();
    } else {
      await OrePineScreen._orePineServer?.close(force: true);
      OrePineScreen._orePineServer = null;
      OrePineScreen._isServerRunning = false;
      OrePineScreen._activeSessionFingerprints.clear();
    }
    final store = StoreRef<String, dynamic>.main();
    await store.record(OrePineScreen._dbKeyRunning).put(sembastDb, val);
    setState(() => _isRunning = val);
  }

  Future<void> _addModel() async {
    final name = _modelNameController.text.trim();
    final token = _tokenController.text.trim();
    if (name.isEmpty) return;

    final modelStore = stringMapStoreFactory.store(OrePineScreen._dbKeyModels);
    await modelStore.add(sembastDb, {'name': name, 'token': token});
    _modelNameController.clear();
    _tokenController.clear();
    await _loadState();
  }

  void _openUserCapDialog(UserAccount user) {
    final limitStore = stringMapStoreFactory.store(OrePineScreen._dbKeyLimits);
    final currentData = _userLimitsData[user.username] ?? {'tokens': 0, 'overallCap': 10000, 'modelCaps': {}};
    
    final overallCapController = TextEditingController(text: '${currentData['overallCap'] ?? 10000}');
    final Map<String, TextEditingController> modelControllers = {};

    final modelCaps = Map<String, dynamic>.from(currentData['modelCaps'] as Map? ?? {});
    for (var m in _models) {
      final name = m['name'] ?? '';
      modelControllers[name] = TextEditingController(text: '${modelCaps[name] ?? 5000}');
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF262424),
        title: Text('Adjust Limits: ${user.username}', style: const TextStyle(color: Colors.white)),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Overall Token Cap:', style: TextStyle(color: Colors.white70, fontSize: 12)),
                TextField(
                  controller: overallCapController,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(filled: true, fillColor: Color(0xFF1c1a1a)),
                ),
                const SizedBox(height: 16),
                const Text('Per-Model Token Caps:', style: TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold, fontSize: 12)),
                const SizedBox(height: 8),
                ..._models.map((m) {
                  final name = m['name'] ?? '';
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name, style: const TextStyle(color: Colors.white, fontSize: 11)),
                        TextField(
                          controller: modelControllers[name],
                          keyboardType: TextInputType.number,
                          style: const TextStyle(color: Colors.white),
                          decoration: const InputDecoration(filled: true, fillColor: Color(0xFF1c1a1a), isDense: true),
                        ),
                      ],
                    ),
                  );
                }),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.cyanAccent, foregroundColor: Colors.black),
            onPressed: () async {
              final newOverall = int.tryParse(overallCapController.text.trim()) ?? 10000;
              final newModelCaps = <String, int>{};
              modelControllers.forEach((k, v) {
                newModelCaps[k] = int.tryParse(v.text.trim()) ?? 5000;
              });

              currentData['overallCap'] = newOverall;
              currentData['modelCaps'] = newModelCaps;

              await limitStore.record(user.username).put(sembastDb, currentData);
              Navigator.pop(context);
              await _loadState();
            },
            child: const Text('Save Caps'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1C1A1A),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('OrePine AI Gateway & MCP Server', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                Row(
                  children: [
                    Text(_isRunning ? 'Status: Running' : 'Status: Stopped', style: TextStyle(color: _isRunning ? Colors.cyanAccent : Colors.grey)),
                    const SizedBox(width: 8),
                    Switch(value: _isRunning, onChanged: _toggleServer, activeColor: Colors.cyanAccent),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('HTTPS Endpoint: https://$deviceIpAddress:${OrePineScreen._serverPort}', style: const TextStyle(color: Colors.cyanAccent, fontSize: 13)),
            const Divider(color: Colors.white12, height: 24),
            const Text('Manage AI Models & Auth Tokens', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _modelNameController,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(labelText: 'Model Name', labelStyle: TextStyle(color: Colors.grey), filled: true, fillColor: Color(0xFF262424)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _tokenController,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(labelText: 'Auth Token / API Key', labelStyle: TextStyle(color: Colors.grey), filled: true, fillColor: Color(0xFF262424)),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.cyanAccent, foregroundColor: Colors.black),
                  onPressed: _addModel,
                  child: const Text('Add Model'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text('Configured Models & User Token Caps / Rate Limits:', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                children: [
                  ..._models.map((m) => ListTile(
                    leading: const Icon(Icons.psychology, color: Colors.cyanAccent),
                    title: Text(m['name'] ?? '', style: const TextStyle(color: Colors.white)),
                    subtitle: Text('Token: ${m['token']}', style: const TextStyle(color: Colors.grey, fontSize: 11)),
                  )),
                  const Divider(color: Colors.white24, height: 24),
                  const Text('User Token Caps & Usage List (Click user to adjust caps):', style: TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 8),
                  ..._users.map((u) {
                    final data = _userLimitsData[u.username] ?? {};
                    final usage = (data['tokens'] as num?)?.toInt() ?? 0;
                    final cap = (data['overallCap'] as num?)?.toInt() ?? 10000;
                    return InkWell(
                      onTap: () => _openUserCapDialog(u),
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(color: const Color(0xFF262424), borderRadius: BorderRadius.circular(6)),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('User: ${u.username} (${u.role}) ✏️', style: const TextStyle(color: Colors.white, fontSize: 12)),
                            Text('Tokens Used: $usage / $cap Cap', style: TextStyle(color: usage > (cap * 0.9) ? Colors.redAccent : Colors.greenAccent, fontSize: 12)),
                          ],
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}