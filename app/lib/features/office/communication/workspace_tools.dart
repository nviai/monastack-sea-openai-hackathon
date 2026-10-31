import 'package:flutter/material.dart';

typedef _Tool = ({String id, String label, IconData icon});

const _groups = <(String, List<_Tool>)>[
  (
    'Work',
    [
      (id: 'chat', label: 'Chat', icon: Icons.forum_outlined),
      (id: 'tasks', label: 'Open task board', icon: Icons.view_kanban_outlined),
      (id: 'agent-chat', label: 'Chat with agents', icon: Icons.chat_outlined),
      (id: 'agents', label: 'Agent proposals', icon: Icons.smart_toy_outlined),
      (
        id: 'room-admin',
        label: 'Room membership',
        icon: Icons.lock_person_outlined,
      ),
      (id: 'inference', label: 'Local text model', icon: Icons.memory_outlined),
    ],
  ),
  (
    'Knowledge',
    [
      (id: 'documents', label: 'Documents', icon: Icons.description_outlined),
      (id: 'meetings', label: 'Meetings', icon: Icons.event_outlined),
      (
        id: 'whiteboard',
        label: 'Whiteboard',
        icon: Icons.sticky_note_2_outlined,
      ),
    ],
  ),
  (
    'Customers',
    [
      (id: 'customers', label: 'Customers', icon: Icons.contacts_outlined),
      (id: 'sales', label: 'Sales pipeline', icon: Icons.trending_up),
      (
        id: 'contracts',
        label: 'Contract proposals',
        icon: Icons.handshake_outlined,
      ),
      (
        id: 'bookings',
        label: 'Customer bookings',
        icon: Icons.calendar_month_outlined,
      ),
      (id: 'support', label: 'Customer support', icon: Icons.support_agent),
    ],
  ),
  (
    'Finance',
    [
      (
        id: 'expenses',
        label: 'Expense approvals',
        icon: Icons.receipt_long_outlined,
      ),
      (
        id: 'journals',
        label: 'Journal entries',
        icon: Icons.menu_book_outlined,
      ),
      (
        id: 'payments',
        label: 'Payment authorizations',
        icon: Icons.verified_outlined,
      ),
    ],
  ),
  (
    'People & operations',
    [
      (id: 'leave', label: 'Leave requests', icon: Icons.beach_access_outlined),
      (id: 'incidents', label: 'Incidents', icon: Icons.report_outlined),
    ],
  ),
];

const _accountTools = <_Tool>[
  (
    id: 'account',
    label: 'Account & devices',
    icon: Icons.manage_accounts_outlined,
  ),
];
const _adminTools = <_Tool>[
  (id: 'people', label: 'People & invitations', icon: Icons.group_add_outlined),
  (id: 'company', label: 'Company & nodes', icon: Icons.apartment_outlined),
];

/// Grouped launcher for workspace views. Returns the chosen tool ID.
/// Every view authorizes its own requests against the node.
class WorkspaceTools extends StatelessWidget {
  const WorkspaceTools({
    super.key,
    this.account = false,
    this.admin = false,
    this.chatUnread = 0,
  });

  /// Signed in with an account (not a device token), and as an admin.
  final bool account;
  final bool admin;
  final int chatUnread;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Workspace tools'),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (group, tools) in [
              if (account)
                ('Account', [..._accountTools, if (admin) ..._adminTools]),
              ..._groups,
            ]) ...[
              Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 6),
                child: Text(
                  group.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 11,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w700,
                    color: Color(0xff71847a),
                  ),
                ),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final tool in tools)
                    SizedBox(
                      width: 176,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          alignment: Alignment.centerLeft,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 14,
                          ),
                        ),
                        onPressed: () => Navigator.pop(context, tool.id),
                        icon: Badge(
                          isLabelVisible: tool.id == 'chat' && chatUnread > 0,
                          label: Text('$chatUnread'),
                          child: Icon(tool.icon, size: 18),
                        ),
                        label: Text(
                          tool.label,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
    ],
  );
}
