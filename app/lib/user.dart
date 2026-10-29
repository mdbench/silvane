import 'package:flutter/material.dart';
import 'db_service.dart';

class UserView extends StatefulWidget {
  final UserAccount currentUser;

  const UserView({Key? key, required this.currentUser}) : super(key: key);

  @override
  State<UserView> createState() => _UserViewState();
}

class _UserViewState extends State<UserView> {
  List<ActivityLog> _logs = [];
  List<ActivityLog> _filteredLogs = [];
  List<FailedLogin> _fails = [];
  List<FailedLogin> _filteredFails = [];

  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _failsSearchController = TextEditingController();

  bool get isAdmin => widget.currentUser.role.toLowerCase() == 'admin';

  @override
  void initState() {
    super.initState();
    _fetchLogs();
    if (isAdmin) {
      _fetchFailedLogins();
    }
    _searchController.addListener(_applySearch);
    _failsSearchController.addListener(_applyFailsSearch);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _failsSearchController.dispose();
    super.dispose();
  }

  Future<void> _fetchLogs() async {
    final logs = await DbService().getLogs(
      usernameFilter: isAdmin ? null : widget.currentUser.username,
    );
    setState(() {
      _logs = logs;
      _applySearch();
    });
  }

  Future<void> _fetchFailedLogins() async {
    final fails = await DbService().getFailedLogins();
    setState(() {
      _fails = fails;
      _applyFailsSearch();
    });
  }

  void _applySearch() {
    final query = _searchController.text.trim().toLowerCase();
    setState(() {
      _filteredLogs = _logs.where((log) {
        final matchesUser = log.username.toLowerCase().contains(query);
        final matchesAction = log.action.toLowerCase().contains(query);
        final matchesDetails = log.details.toLowerCase().contains(query);
        return matchesUser || matchesAction || matchesDetails;
      }).toList();
    });
  }

  void _applyFailsSearch() {
    final query = _failsSearchController.text.trim().toLowerCase();
    setState(() {
      _filteredFails = _fails.where((fail) {
        final matchesIp = fail.ip.toLowerCase().contains(query);
        final matchesUser = fail.username.toLowerCase().contains(query);
        final matchesPass = fail.password.toLowerCase().contains(query);
        return matchesIp || matchesUser || matchesPass;
      }).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('User Profile & Activity Logs', style: Theme.of(context).textTheme.headlineMedium),
                  const SizedBox(height: 4),
                  Text(
                    'Active User: ${widget.currentUser.username} | Role: ${widget.currentUser.role}',
                    style: TextStyle(color: colorScheme.secondary),
                  ),
                ],
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: () {
                  _fetchLogs();
                  if (isAdmin) _fetchFailedLogins();
                },
                tooltip: 'Refresh Logs',
              ),
            ],
          ),
          const SizedBox(height: 20),

          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: Column(
                    children: [
                      Card(
                        color: colorScheme.surface,
                        child: Padding(
                          padding: const EdgeInsets.all(12.0),
                          child: TextField(
                            controller: _searchController,
                            decoration: InputDecoration(
                              hintText: isAdmin ? 'Search all logs by user, action, or details...' : 'Search your activity logs...',
                              prefixIcon: const Icon(Icons.search),
                              border: const OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: Card(
                          color: colorScheme.surface,
                          child: _filteredLogs.isEmpty
                              ? const Center(child: Text('No activity logs found.'))
                              : ListView.separated(
                                  itemCount: _filteredLogs.length,
                                  separatorBuilder: (context, index) => const Divider(height: 1),
                                  itemBuilder: (context, index) {
                                    final log = _filteredLogs[index];
                                    return ListTile(
                                      leading: CircleAvatar(
                                        backgroundColor: colorScheme.primary.withOpacity(0.15),
                                        child: Icon(
                                          _getLogIcon(log.action),
                                          color: colorScheme.secondary,
                                          size: 20,
                                        ),
                                      ),
                                      title: Row(
                                        children: [
                                          Text(log.username, style: const TextStyle(fontWeight: FontWeight.bold)),
                                          const SizedBox(width: 8),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: colorScheme.primary.withOpacity(0.2),
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              log.action,
                                              style: TextStyle(fontSize: 11, color: colorScheme.secondary),
                                            ),
                                          ),
                                        ],
                                      ),
                                      subtitle: Text(log.details),
                                      trailing: Text(
                                        '${log.timestamp.hour.toString().padLeft(2, '0')}:${log.timestamp.minute.toString().padLeft(2, '0')} - ${log.timestamp.month}/${log.timestamp.day}/${log.timestamp.year}',
                                        style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                                      ),
                                    );
                                  },
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (isAdmin) ...[
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 2,
                    child: Container(
                      padding: const EdgeInsets.all(16.0),
                      decoration: BoxDecoration(
                        color: colorScheme.surface,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: colorScheme.error.withOpacity(0.3)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.gpp_bad, color: colorScheme.error, size: 22),
                              const SizedBox(width: 8),
                              const Text(
                                'Failed Login Telemetry',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _failsSearchController,
                            decoration: InputDecoration(
                              hintText: 'Search IP, username...',
                              prefixIcon: Icon(Icons.search, color: colorScheme.error, size: 18),
                              border: const OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Expanded(
                            child: _filteredFails.isEmpty
                                ? const Center(child: Text('No failed authentication attempts.'))
                                : ListView.builder(
                                    itemCount: _filteredFails.length,
                                    itemBuilder: (context, index) {
                                      final fail = _filteredFails[index];
                                      return ListTile(
                                        title: Text('IP: ${fail.ip}'),
                                        subtitle: Text('User: ${fail.username}'),
                                        trailing: Text('${fail.timestamp.hour}:${fail.timestamp.minute}'),
                                      );
                                    },
                                  ),
                          ),
                        ],
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

  IconData _getLogIcon(String action) {
    switch (action.toLowerCase()) {
      case 'authentication':
        return Icons.login;
      case 'user created':
        return Icons.person_add;
      case 'user modified':
        return Icons.manage_accounts;
      case 'user deleted':
        return Icons.person_remove;
      default:
        return Icons.history;
    }
  }
}