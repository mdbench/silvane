import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:process_run/shell.dart';
import 'package:sembast/sembast.dart';
import 'main.dart';

const List<String> skippedFolders = [
  'ForestFinderSpool',
  'MetalMail',
  'OrePineStore',
  'SilverGit',
  'SylvanSap',
];

class Tab2Screen extends StatefulWidget {
  final String searchQuery;
  const Tab2Screen({super.key, required this.searchQuery});

  @override
  State<Tab2Screen> createState() => _Tab2ScreenState();
}

class _Tab2ScreenState extends State<Tab2Screen> with AutomaticKeepAliveClientMixin {
  Directory? _currentDirectory;
  Directory? _selectedFolderForTree;
  List<FileSystemEntity> _currentFolderContents = [];
  List<FileNode> _selectedTreeNodes = [];
  final settingsStore = StoreRef<String, dynamic>.main();

  @override
  bool get wantKeepAlive => true; // Preserves Tab2 state across tab switches

  @override
  void initState() {
    super.initState();
    _currentDirectory = Directory(appDirectoryPath);
    _loadCurrentDirectoryContents();
  }

  @override
  void didUpdateWidget(covariant Tab2Screen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.searchQuery != widget.searchQuery) {
      _loadCurrentDirectoryContents();
    }
  }

  Future<void> _loadCurrentDirectoryContents() async {
    final dir = _currentDirectory ?? Directory(appDirectoryPath);
    if (!await dir.exists()) return;

    final query = widget.searchQuery.trim().toLowerCase();
    List<FileSystemEntity> contents = [];

    await for (final entity in dir.list(recursive: false, followLinks: false)) {
      final name = p.basename(entity.path);
      
      if (name == 'silvane_meta.db' || name.startsWith('.') || skippedFolders.contains(name)) continue;

      if (query.isEmpty || name.toLowerCase().contains(query) || entity.path.toLowerCase().contains(query)) {
        contents.add(entity);
      }
    }

    contents.sort((a, b) {
      if (a is Directory && b is File) return -1;
      if (a is File && b is Directory) return 1;
      return p.basename(a.path).compareTo(p.basename(b.path));
    });

    if (mounted) {
      setState(() {
        _currentFolderContents = contents;
      });
    }

    if (_selectedFolderForTree != null && await _selectedFolderForTree!.exists()) {
      await _loadTreeForFolder(_selectedFolderForTree!);
    }
  }

  Future<void> _loadTreeForFolder(Directory folder) async {
    List<FileNode> nodes = [];
    final query = widget.searchQuery.trim().toLowerCase();

    await for (final entity in folder.list(recursive: true, followLinks: false)) {
      final relativePath = p.relative(entity.path, from: folder.path);
      
      // FIX: Check if any segment in the path (e.g., .git, .silvane_venv) starts with a dot
      final segments = p.split(relativePath);
      if (segments.any((seg) => seg.startsWith('.') || skippedFolders.contains(seg))) continue;

      final name = p.basename(entity.path);

      if (query.isEmpty || name.toLowerCase().contains(query) || relativePath.toLowerCase().contains(query)) {
        final relPath = p.relative(entity.path, from: appDirectoryPath);
        final savedStatus = await settingsStore.record(relPath).get(sembastDb) as bool? ?? false;
        final encryptedStatus = await settingsStore.record('${relPath}_encrypted').get(sembastDb) as bool? ?? false;
        
        nodes.add(FileNode(
          entity: entity,
          relativePath: relativePath,
          isProtected: savedStatus,
          isEncrypted: encryptedStatus,
        ));
      }
    }

    nodes.sort((a, b) => a.relativePath.compareTo(b.relativePath));
    if (mounted) {
      setState(() {
        _selectedFolderForTree = folder;
        _selectedTreeNodes = nodes;
      });
    }
  }

  void _navigateInto(Directory dir) {
    setState(() {
      _currentDirectory = dir;
      if (!p.equals(dir.path, appDirectoryPath)) {
        _loadTreeForFolder(dir);
      } else {
        _selectedFolderForTree = null;
        _selectedTreeNodes.clear();
      }
    });
    _loadCurrentDirectoryContents();
  }

  void _navigateUp() {
    if (_currentDirectory == null || p.equals(_currentDirectory!.path, appDirectoryPath)) return;
    final parentDir = _currentDirectory!.parent;
    _navigateInto(parentDir);
  }

  Future<void> _toggleProtectionEntity(FileSystemEntity entity) async {
    final relPath = p.relative(entity.path, from: appDirectoryPath);
    final currentStatus = await settingsStore.record(relPath).get(sembastDb) as bool? ?? false;
    final nextStatus = !currentStatus;
    await settingsStore.record(relPath).put(sembastDb, nextStatus);
    
    await _loadCurrentDirectoryContents();
    if (_selectedFolderForTree != null) {
      await _loadTreeForFolder(_selectedFolderForTree!);
    }
  }

  Future<void> _promptAndToggleEncryption(FileSystemEntity entity) async {
    final relPath = p.relative(entity.path, from: appDirectoryPath);
    final encKey = '${relPath}_encrypted';
    final passKey = '${relPath}_enc_password';
    
    final currentStatus = await settingsStore.record(encKey).get(sembastDb) as bool? ?? false;

    if (currentStatus) {
      await settingsStore.record(encKey).put(sembastDb, false);
      await settingsStore.record(passKey).delete(sembastDb);
      await _loadCurrentDirectoryContents();
      if (_selectedFolderForTree != null) await _loadTreeForFolder(_selectedFolderForTree!);
      return;
    }

    bool passwordProtected = false;
    final passwordController = TextEditingController();

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1C1A1A),
          title: const Text('Cydog Encrypted Access Setup', style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Configure access security for: ${p.basename(entity.path)}', style: const TextStyle(color: Colors.grey, fontSize: 13)),
              const SizedBox(height: 16),
              SwitchListTile(
                title: const Text('Password Encrypted', style: TextStyle(color: Colors.white)),
                subtitle: Text(passwordProtected ? 'Requires user password prompt on load' : 'Auto-decrypted seamlessly', style: const TextStyle(color: Colors.grey, fontSize: 11)),
                value: passwordProtected,
                onChanged: (val) => setDialogState(() => passwordProtected = val),
              ),
              if (passwordProtected) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Decryption Password',
                    labelStyle: TextStyle(color: Colors.grey),
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.cyan),
              onPressed: () async {
                await settingsStore.record(encKey).put(sembastDb, true);
                if (passwordProtected && passwordController.text.isNotEmpty) {
                  await settingsStore.record(passKey).put(sembastDb, passwordController.text.trim());
                } else {
                  await settingsStore.record(passKey).put(sembastDb, '');
                }
                Navigator.pop(context);
              },
              child: const Text('Enable Encryption', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );

    await _loadCurrentDirectoryContents();
    if (_selectedFolderForTree != null) {
      await _loadTreeForFolder(_selectedFolderForTree!);
    }
  }

  Future<void> _deleteRepositoryFolder(Directory repoDir) async {
    final parentPath = repoDir.parent.path;
    if (!p.equals(parentPath, appDirectoryPath)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Safety Error: Subfolders cannot be deleted as repositories. Only top-level repo folders can be removed.')),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1C1A1A),
        title: Text('Delete Repository: ${p.basename(repoDir.path)}?', style: const TextStyle(color: Colors.white)),
        content: const Text(
          'This will delete the main repository folder and its contents. Core system files and metadata remain untouched.',
          style: TextStyle(color: Colors.grey),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete Repository', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await repoDir.delete(recursive: true);
        if (mounted) {
          setState(() {
            if (_selectedFolderForTree != null && (p.isWithin(_selectedFolderForTree!.path, repoDir.path) || _selectedFolderForTree?.path == repoDir.path)) {
              _selectedFolderForTree = null;
              _selectedTreeNodes.clear();
            }
            if (_currentDirectory != null && (p.isWithin(repoDir.path, _currentDirectory!.path) || p.equals(_currentDirectory!.path, repoDir.path))) {
              _currentDirectory = Directory(appDirectoryPath);
              _selectedFolderForTree = null;
              _selectedTreeNodes.clear();
            }
          });
        }
        await _loadCurrentDirectoryContents();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Repository folder deleted successfully.')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to delete repository: $e')),
          );
        }
      }
    }
  }

  void _showGitLogsDialog(Directory repoDir) {
    showDialog(
      context: context,
      builder: (context) => GitLogsDialog(repositoryDirectory: repoDir),
    );
  }

  void _showCloneDialog() {
    showDialog(
      context: context,
      builder: (context) => GitCloneDialog(onCloneComplete: () {
        _loadCurrentDirectoryContents();
      }),
    );
  }

  Color _getCapabilityColor(FileSystemEntity entity, bool isProtected, bool isEncrypted) {
    if (isEncrypted) return Colors.cyanAccent;
    if (isProtected) return Colors.amber;
    if (entity is Directory) return Colors.lightBlueAccent;
    final ext = p.extension(entity.path).toLowerCase();
    if (['.sh', '.py', '.js', '.dart', '.go', '.rs'].contains(ext)) return Colors.greenAccent;
    if (['.json', '.yaml', '.yml', '.env', '.config', '.pem'].contains(ext)) return Colors.orangeAccent;
    if (['.md', '.txt'].contains(ext)) return Colors.grey;
    return Colors.white70;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Required by AutomaticKeepAliveClientMixin
    final currentPathDisplay = _currentDirectory != null
        ? p.relative(_currentDirectory!.path, from: appDirectoryPath)
        : '.';
    
    final bool isAtRootRepoLevel = _currentDirectory != null && p.equals(_currentDirectory!.path, appDirectoryPath);
    Directory? activeRepoDir;
    if (!isAtRootRepoLevel && _currentDirectory != null) {
      List<String> parts = p.split(p.relative(_currentDirectory!.path, from: appDirectoryPath));
      if (parts.isNotEmpty) {
        activeRepoDir = Directory(p.join(appDirectoryPath, parts.first));
      }
    }

    return Container(
      color: const Color(0xFF1C1A1A),
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  if (_currentDirectory != null && !p.equals(_currentDirectory!.path, appDirectoryPath))
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: _navigateUp,
                      tooltip: 'Parent Directory',
                    ),
                  Text(
                    'Workspace Manager: /$currentPathDisplay',
                    style: const TextStyle(color: Color(0xFFECEFF1), fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              Row(
                children: [
                  if (activeRepoDir != null) ...[
                    MetallicShimmerButton(
                      onPressed: () => _showGitLogsDialog(activeRepoDir!),
                      label: 'View Git Logs',
                    ),
                    const SizedBox(width: 8),
                  ],
                  MetallicShimmerButton(
                    onPressed: _showCloneDialog,
                    label: '+ Clone Repository',
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            flex: 6,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF262424),
                      borderRadius: BorderRadius.circular(6.0),
                      border: Border.all(color: Colors.grey.withOpacity(0.2)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.all(12.0),
                          child: Text('Directories & Files', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white70)),
                        ),
                        const Divider(height: 1, color: Colors.grey),
                        Expanded(
                          child: _currentFolderContents.isEmpty
                              ? const Center(child: Text('Empty folder', style: TextStyle(color: Colors.grey)))
                              : ListView.builder(
                                  itemCount: _currentFolderContents.length,
                                  itemBuilder: (context, index) {
                                    final entity = _currentFolderContents[index];
                                    final isDir = entity is Directory;
                                    final name = p.basename(entity.path);
                                    final relPath = p.relative(entity.path, from: appDirectoryPath);
                                    
                                    return FutureBuilder<List<Object?>>(
                                      future: Future.wait([
                                        settingsStore.record(relPath).get(sembastDb),
                                        settingsStore.record('${relPath}_encrypted').get(sembastDb),
                                      ]),
                                      builder: (context, snapshot) {
                                        final isProtected = snapshot.data?[0] as bool? ?? false;
                                        final isEncrypted = snapshot.data?[1] as bool? ?? false;

                                        return ListTile(
                                          leading: Icon(
                                            isDir ? Icons.folder : Icons.insert_drive_file,
                                            size: 28,
                                            color: isEncrypted ? Colors.cyanAccent : (isProtected ? Colors.amber : (isDir ? Colors.amber : Colors.blueGrey[200])),
                                          ),
                                          title: Text(
                                            name,
                                            style: TextStyle(
                                              color: isEncrypted ? Colors.cyanAccent : (isProtected ? Colors.amber : Colors.white),
                                              fontWeight: FontWeight.w500,
                                              fontSize: 14,
                                              decoration: isProtected ? TextDecoration.lineThrough : null,
                                            ),
                                          ),
                                          subtitle: Text(
                                            isEncrypted ? 'Encrypted Secure Access' : (isDir ? 'Directory' : 'File'),
                                            style: const TextStyle(color: Colors.grey, fontSize: 11),
                                          ),
                                          trailing: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              IconButton(
                                                icon: Icon(
                                                  isProtected ? Icons.lock : Icons.lock_open,
                                                  size: 16,
                                                  color: isProtected ? Colors.amber : Colors.grey,
                                                ),
                                                onPressed: () => _toggleProtectionEntity(entity),
                                                tooltip: 'Toggle Protection',
                                              ),
                                              IconButton(
                                                icon: Icon(
                                                  isEncrypted ? Icons.vpn_key : Icons.vpn_key_off,
                                                  size: 16,
                                                  color: isEncrypted ? Colors.cyanAccent : Colors.grey,
                                                ),
                                                onPressed: () => _promptAndToggleEncryption(entity),
                                                tooltip: 'Toggle Encrypted Access',
                                              ),
                                              if (isAtRootRepoLevel && isDir) ...[
                                                IconButton(
                                                  icon: const Icon(Icons.history, color: Colors.greenAccent, size: 18),
                                                  onPressed: () => _showGitLogsDialog(entity as Directory),
                                                  tooltip: 'View Git Logs',
                                                ),
                                                IconButton(
                                                  icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                                                  onPressed: () => _deleteRepositoryFolder(entity),
                                                  tooltip: 'Delete Main Repository Folder',
                                                ),
                                              ],
                                            ],
                                          ),
                                          onTap: () {
                                            if (isDir) {
                                              _navigateInto(entity as Directory);
                                            }
                                          },
                                        );
                                      },
                                    );
                                  },
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 7,
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF262424),
                      borderRadius: BorderRadius.circular(6.0),
                      border: Border.all(color: Colors.grey.withOpacity(0.2)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(12.0),
                          child: Text(
                            _selectedFolderForTree == null
                                ? 'Select a folder to view recursive tree'
                                : 'Folder Tree: ${p.basename(_selectedFolderForTree!.path)}',
                            style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white70),
                          ),
                        ),
                        const Divider(height: 1, color: Colors.grey),
                        Expanded(
                          child: _selectedFolderForTree == null
                              ? const Center(
                                  child: Text(
                                    'Click a folder on the left to inspect its complete recursive file tree.',
                                    style: TextStyle(color: Colors.grey),
                                    textAlign: TextAlign.center,
                                  ),
                                )
                              : _selectedTreeNodes.isEmpty
                                  ? const Center(child: Text('No contents in folder match query.', style: TextStyle(color: Colors.grey)))
                                  : ListView.builder(
                                      itemCount: _selectedTreeNodes.length,
                                      itemBuilder: (context, index) {
                                        final node = _selectedTreeNodes[index];
                                        final depth = p.split(node.relativePath).length - 1;
                                        final isDir = node.entity is Directory;

                                        return Padding(
                                          padding: EdgeInsets.only(left: depth * 16.0),
                                          child: ListTile(
                                            dense: true,
                                            leading: Icon(
                                              isDir ? Icons.folder : Icons.insert_drive_file,
                                              size: 24,
                                              color: node.isEncrypted ? Colors.cyanAccent : (node.isProtected ? Colors.amber : (isDir ? Colors.amberAccent : Colors.white70)),
                                            ),
                                            title: Text(
                                              p.basename(node.entity.path),
                                              style: TextStyle(
                                                color: node.isEncrypted ? Colors.cyanAccent : (node.isProtected ? Colors.amber : Colors.white),
                                                decoration: node.isProtected ? TextDecoration.lineThrough : null,
                                              ),
                                            ),
                                            trailing: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                IconButton(
                                                  icon: Icon(
                                                    node.isProtected ? Icons.lock : Icons.lock_open,
                                                    size: 16,
                                                    color: node.isProtected ? Colors.amber : Colors.grey,
                                                  ),
                                                  onPressed: () async {
                                                    await _toggleProtectionEntity(node.entity);
                                                  },
                                                  tooltip: 'Toggle Protection',
                                                ),
                                                IconButton(
                                                  icon: Icon(
                                                    node.isEncrypted ? Icons.vpn_key : Icons.vpn_key_off,
                                                    size: 16,
                                                    color: node.isEncrypted ? Colors.cyanAccent : Colors.grey,
                                                  ),
                                                  onPressed: () async {
                                                    await _promptAndToggleEncryption(node.entity);
                                                  },
                                                  tooltip: 'Toggle Encrypted Access',
                                                ),
                                              ],
                                            ),
                                          ),
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
          ),
          const SizedBox(height: 12),
          Expanded(
            flex: 4,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12.0),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(6.0),
                border: Border.all(color: Colors.grey.withOpacity(0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'silvane@os-terminal:\$ ls -la (Read-Only Telemetry View)',
                        style: TextStyle(color: Colors.greenAccent, fontFamily: 'monospace', fontSize: 12),
                      ),
                      Text(
                        'Path: /$currentPathDisplay',
                        style: const TextStyle(color: Colors.grey, fontSize: 11, fontFamily: 'monospace'),
                      ),
                    ],
                  ),
                  const Divider(color: Colors.white24),
                  Expanded(
                    child: ListView.builder(
                      itemCount: _currentFolderContents.length,
                      itemBuilder: (context, index) {
                        final entity = _currentFolderContents[index];
                        final name = p.basename(entity.path);
                        final isDir = entity is Directory;
                        final color = _getCapabilityColor(entity, false, false);

                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2.0),
                          child: Text(
                            isDir 
                                ? 'drwxr-xr-x  1 silvane silvane  ' + (entity.path.hashCode.abs() % 4096).toString() + '  ' + name + '/' 
                                : '-rw-r--r--  1 silvane silvane  ' + entity.statSync().size.toString() + '  ' + name,
                            style: TextStyle(
                              color: color,
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                          ),
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

class FileNode {
  final FileSystemEntity entity;
  final String relativePath;
  final bool isProtected;
  final bool isEncrypted;

  FileNode({
    required this.entity,
    required this.relativePath,
    required this.isProtected,
    required this.isEncrypted,
  });
}

class GitLogsDialog extends StatefulWidget {
  final Directory repositoryDirectory;
  const GitLogsDialog({super.key, required this.repositoryDirectory});

  @override
  State<GitLogsDialog> createState() => _GitLogsDialogState();
}

class _GitLogsDialogState extends State<GitLogsDialog> {
  bool _isLoading = true;
  String _gitLogOutput = '';
  String _branchInfo = '';

  @override
  void initState() {
    super.initState();
    _fetchGitMetadata();
  }

  Future<void> _fetchGitMetadata() async {
    try {
      final shell = Shell(workingDirectory: widget.repositoryDirectory.path);
      
      final branchResult = await shell.run('git branch --show-current');
      final branch = branchResult.outText.trim();

      final logResult = await shell.run('git log -n 30 --oneline --decorate');
      final logs = logResult.outText.trim();

      if (mounted) {
        setState(() {
          _branchInfo = branch.isNotEmpty ? branch : 'HEAD (Detached/Unknown)';
          _gitLogOutput = logs.isNotEmpty ? logs : 'No commit history found.';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _gitLogOutput = 'Error parsing git repository info: $e';
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final repoName = p.basename(widget.repositoryDirectory.path);
    return AlertDialog(
      backgroundColor: const Color(0xFF1C1A1A),
      title: Text('Git Telemetry & Logs: $repoName', style: const TextStyle(color: Colors.white, fontSize: 16)),
      content: SizedBox(
        width: 600,
        height: 400,
        child: _isLoading
            ? const Center(child: CircularProgressIndicator(color: Colors.amber))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Active Branch: $_branchInfo', style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  const Text('Commit History (`git log`):', style: TextStyle(color: Colors.grey, fontSize: 12)),
                  const SizedBox(height: 6),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: SingleChildScrollView(
                        child: Text(
                          _gitLogOutput,
                          style: const TextStyle(color: Colors.white70, fontFamily: 'monospace', fontSize: 12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close', style: TextStyle(color: Colors.grey)),
        ),
      ],
    );
  }
}

class GitCloneDialog extends StatefulWidget {
  final VoidCallback onCloneComplete;
  const GitCloneDialog({super.key, required this.onCloneComplete});

  @override
  State<GitCloneDialog> createState() => _GitCloneDialogState();
}

class _GitCloneDialogState extends State<GitCloneDialog> {
  final _formKey = GlobalKey<FormState>();
  String _provider = 'GitHub';
  final _urlController = TextEditingController();
  final _nameController = TextEditingController();
  final _tokenController = TextEditingController();
  bool _isPrivate = false;
  bool _isMirror = false;
  bool _isCloning = false;
  String _statusMsg = '';

  Future<void> _executeGitClone() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isCloning = true;
      _statusMsg = 'Executing remote shell thread process...';
    });

    try {
      String targetUrl = _urlController.text.trim();
      if (_isPrivate && _tokenController.text.isNotEmpty) {
        final uri = Uri.parse(targetUrl);
        targetUrl = uri.replace(userInfo: 'token:${_tokenController.text.trim()}').toString();
      }

      final destinationPath = p.join(appDirectoryPath, _nameController.text.trim());
      final shell = Shell();
      
      final List<String> arguments = ['clone'];
      if (_isMirror) {
        arguments.add('--mirror');
      }
      arguments.addAll([targetUrl, destinationPath]);

      await shell.run('git ${arguments.join(' ')}');

      if (mounted) {
        setState(() => _statusMsg = 'Repository configured successfully.');
      }
      widget.onCloneComplete();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _statusMsg = 'Process Exception Error: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _isCloning = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1C1A1A),
      title: const Text('Provision Target Repository Engine', style: TextStyle(color: Colors.white)),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                value: _provider,
                dropdownColor: const Color(0xFF262424),
                style: const TextStyle(color: Colors.white),
                items: ['GitHub', 'GitLab', 'Gitea'].map((String val) {
                  return DropdownMenuItem<String>(value: val, child: Text(val));
                }).toList(),
                onChanged: (val) => setState(() => _provider = val!),
                decoration: const InputDecoration(labelText: 'Git Infrastructure Instance', labelStyle: TextStyle(color: Colors.grey)),
              ),
              TextFormField(
                controller: _urlController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(labelText: 'Repository Target URL Path', labelStyle: TextStyle(color: Colors.grey)),
                validator: (v) => v!.isEmpty ? 'Field required' : null,
              ),
              TextFormField(
                controller: _nameController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(labelText: 'Local Direct Workplace Folder Alias', labelStyle: TextStyle(color: Colors.grey)),
                validator: (v) => v!.isEmpty ? 'Field required' : null,
              ),
              CheckboxListTile(
                title: const Text('Private Instance Target Path', style: TextStyle(color: Colors.white)),
                value: _isPrivate,
                onChanged: (v) => setState(() {
                  _isPrivate = v!;
                  if (_isPrivate) _isMirror = false;
                }),
              ),
              if (_isPrivate)
                TextFormField(
                  controller: _tokenController,
                  obscureText: true,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(labelText: 'Personal Access Token Credentials', labelStyle: TextStyle(color: Colors.grey)),
                ),
              if (!_isPrivate)
                CheckboxListTile(
                  title: const Text('Mirror Repository Engine (`--mirror`)', style: TextStyle(color: Colors.white)),
                  value: _isMirror,
                  onChanged: (v) => setState(() => _isMirror = v!),
                ),
              const SizedBox(height: 12),
              Text(_statusMsg, style: const TextStyle(color: Colors.amber, fontSize: 12)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isCloning ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
        ),
        if (!_isCloning)
          MetallicShimmerButton(
            onPressed: _executeGitClone,
            label: 'Clone Engine boot',
          ),
      ],
    );
  }
}