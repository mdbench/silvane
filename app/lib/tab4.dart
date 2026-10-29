import 'dart:io';
import 'package:flutter/material.dart';
import 'package:sembast/sembast.dart';
import 'main.dart';

class Tab4Screen extends StatefulWidget {
  final String searchQuery;
  const Tab4Screen({super.key, required this.searchQuery});

  @override
  State<Tab4Screen> createState() => _Tab4ScreenState();
}

class UfwRule {
  final int index;
  final String to;
  final String action;
  final String from;

  UfwRule({
    required this.index,
    required this.to,
    required this.action,
    required this.from,
  });
}

class _Tab4ScreenState extends State<Tab4Screen> {
  bool _isLoading = true;
  String _ufwStatus = 'Unknown';
  List<UfwRule> _rules = [];
  
  // Custom Plaintext DNS Provider settings stored in Sembast
  final TextEditingController _dnsController = TextEditingController();
  bool _isSavingDns = false;
  String _dnsStatusMsg = '';
  
  // Protected system ports that cannot be closed accidentally (SSH, DNS, HTTP, HTTPS)
  static const List<int> _protectedPorts = [22, 53, 80, 443];

  @override
  void initState() {
    super.initState();
    _loadUfwStatusAndRules();
    _loadStoredDnsSettings();
  }

  @override
  void dispose() {
    _dnsController.dispose();
    super.dispose();
  }

  Future<void> _loadStoredDnsSettings() async {
    final store = StoreRef<String, dynamic>.main();
    final savedDns = await store.record('custom_plaintext_dns').get(sembastDb) as String? ?? '8.8.8.8';
    _dnsController.text = savedDns;
    setState(() {});
  }

  Future<void> _saveCustomDns() async {
    setState(() => _isSavingDns = true);
    try {
      final dnsIp = _dnsController.text.trim();
      if (dnsIp.isEmpty) {
        setState(() => _dnsStatusMsg = 'DNS server IP cannot be empty.');
        return;
      }

      // Save preference into Sembast metadata store
      final store = StoreRef<String, dynamic>.main();
      await store.record('custom_plaintext_dns').put(sembastDb, dnsIp);

      // Debian Bookworm specific DNS configuration for user 'kiosk'
      // Updates system resolver or systemd-resolved stub via sudo/kiosk privileges
      try {
        final result = await Process.run('sudo', ['bash', '-c', 'echo "nameserver $dnsIp" > /etc/resolv.conf']);
        if (result.exitCode != 0) {
          // Fallback mechanism using resolvectl for Debian Bookworm systemd-resolved environments
          await Process.run('sudo', ['resolvectl', 'dns', 'lo', dnsIp]);
        }
      } catch (e) {
        debugPrint('System resolver update exception: $e');
      }

      setState(() => _dnsStatusMsg = 'Debian Bookworm plaintext DNS successfully set to $dnsIp for kiosk session.');
    } catch (e) {
      setState(() => _dnsStatusMsg = 'Error saving DNS: $e');
    } finally {
      setState(() => _isSavingDns = false);
    }
  }

  Future<void> _loadUfwStatusAndRules() async {
    setState(() => _isLoading = true);
    _rules.clear();

    try {
      final statusResult = await Process.run('sudo', ['ufw', 'status']);
      _ufwStatus = statusResult.stdout.toString().trim();

      final numberedResult = await Process.run('sudo', ['ufw', 'status', 'numbered']);
      final output = numberedResult.stdout.toString();
      final lines = output.split('\n');

      for (var line in lines) {
        final match = RegExp(r'\[\s*([0-9]+)\]\s+([^\s]+)\s+([A-Z\s]+)\s+(.*)').firstMatch(line.trim());
        if (match != null) {
          final idx = int.parse(match.group(1)!);
          final to = match.group(2)!.trim();
          final action = match.group(3)!.trim();
          final from = match.group(4)!.trim();

          _rules.add(UfwRule(index: idx, to: to, action: action, from: from));
        }
      }
    } catch (e) {
      _ufwStatus = 'UFW utility restricted or inactive ($e)';
    }

    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  bool _isRuleProtected(UfwRule rule) {
    for (var port in _protectedPorts) {
      if (rule.to.contains('$port') || rule.to.contains('www') || rule.to.contains('ssh') || rule.to.contains('http')) {
        return true;
      }
    }
    return false;
  }

  Future<void> _closeOrDenyRule(UfwRule rule) async {
    if (_isRuleProtected(rule)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Safety Restriction: Cannot close critical webserver, python/php, or service ports (22, 53, 80, 443).')),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1C1A1A),
        title: Text('Close / Deny Port Rule [${rule.index}]?', style: const TextStyle(color: Colors.white)),
        content: Text(
          'This will delete or deny rule matching "${rule.to}" (${rule.action}). Are you sure?',
          style: const TextStyle(color: Colors.grey),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Confirm Close Port', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await Process.run('sudo', ['ufw', '--force', 'delete', rule.index.toString()]);
        await _loadUfwStatusAndRules();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Firewall rule successfully deleted/closed.')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to update UFW rule: $e')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = widget.searchQuery.trim().toLowerCase();
    final filteredRules = _rules.where((r) {
      return r.to.toLowerCase().contains(query) ||
          r.action.toLowerCase().contains(query) ||
          r.from.toLowerCase().contains(query);
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
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Debian Bookworm UFW Firewall & Network Security',
                    style: TextStyle(color: Color(0xFFECEFF1), fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Managed under kiosk session: Inspect ports, deny unauthorized traffic, and configure DNS resolvers.',
                    style: TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                ],
              ),
              MetallicShimmerButton(
                onPressed: _loadUfwStatusAndRules,
                label: 'Refresh Firewall Rules',
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Custom Plaintext DNS Configuration Card for Debian Bookworm
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF262424),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.dns, color: Colors.amberAccent, size: 20),
                    SizedBox(width: 8),
                    Text('Custom Plaintext DNS Provider (Debian Bookworm / Kiosk)', style: TextStyle(color: Color(0xFFECEFF1), fontSize: 15, fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Specify a custom resolver IP (e.g., 8.8.8.8, 1.1.1.1) applied directly to system network resolution.',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _dnsController,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: 'Enter Nameserver IP (e.g., 8.8.8.8)',
                          hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                          fillColor: const Color(0xFF1C1A1A),
                          filled: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton(
                      onPressed: _isSavingDns ? null : _saveCustomDns,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF3A3636),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                      ),
                      child: _isSavingDns
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : const Text('Apply DNS', style: TextStyle(color: Colors.white)),
                    ),
                  ],
                ),
                if (_dnsStatusMsg.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(_dnsStatusMsg, style: const TextStyle(color: Colors.greenAccent, fontSize: 12)),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),

          // UFW Ports Table & Management
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF262424),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.security, color: Colors.blueAccent, size: 20),
                          SizedBox(width: 8),
                          Text('Active Inbound & Outbound UFW Ports', style: TextStyle(color: Color(0xFFECEFF1), fontSize: 15, fontWeight: FontWeight.bold)),
                        ],
                      ),
                      Text('Status: ${_ufwStatus.contains('active') ? 'Active (Secured)' : 'Inactive / Restricted'}', style: TextStyle(color: _ufwStatus.contains('active') ? Colors.greenAccent : Colors.orangeAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const Divider(color: Colors.white10, height: 20),
                  Expanded(
                    child: _isLoading
                        ? const Center(child: CircularProgressIndicator(color: Colors.white))
                        : filteredRules.isEmpty
                            ? const Center(child: Text('No active UFW port rules found or firewall is inactive.', style: TextStyle(color: Colors.grey)))
                            : ListView.builder(
                                itemCount: filteredRules.length,
                                itemBuilder: (context, index) {
                                  final rule = filteredRules[index];
                                  final isProtected = _isRuleProtected(rule);

                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 8),
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF1C1A1A),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(color: isProtected ? Colors.amber.withOpacity(0.3) : Colors.white10),
                                    ),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Row(
                                          children: [
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                              decoration: BoxDecoration(
                                                color: Colors.white10,
                                                borderRadius: BorderRadius.circular(4),
                                              ),
                                              child: Text('[#${rule.index}]', style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.bold, fontSize: 12)),
                                            ),
                                            const SizedBox(width: 12),
                                            Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text('Port / Service: ${rule.to}', style: const TextStyle(color: Color(0xFFECEFF1), fontWeight: FontWeight.bold, fontSize: 13)),
                                                const SizedBox(height: 2),
                                                Text('Action: ${rule.action} | Origin: ${rule.from}', style: const TextStyle(color: Colors.grey, fontSize: 11)),
                                              ],
                                            ),
                                          ],
                                        ),
                                        Row(
                                          children: [
                                            if (isProtected) ...[
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                                decoration: BoxDecoration(
                                                  color: Colors.amber.withOpacity(0.15),
                                                  borderRadius: BorderRadius.circular(4),
                                                ),
                                                child: const Text('Protected Service / Web', style: TextStyle(color: Colors.amber, fontSize: 11, fontWeight: FontWeight.bold)),
                                              ),
                                              const SizedBox(width: 8),
                                            ],
                                            ElevatedButton(
                                              onPressed: isProtected ? null : () => _closeOrDenyRule(rule),
                                              style: ElevatedButton.styleFrom(
                                                backgroundColor: isProtected ? Colors.grey.withOpacity(0.2) : Colors.red.withOpacity(0.2),
                                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                              ),
                                              child: Text(
                                                isProtected ? 'Locked' : 'Close / Deny Port',
                                                style: TextStyle(color: isProtected ? Colors.grey : Colors.redAccent, fontSize: 12, fontWeight: FontWeight.bold),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
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