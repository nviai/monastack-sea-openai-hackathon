/// Readable English labels; authorization continues to use canonical role IDs.
String actorRoleLabel(Object? value) => (value as String? ?? '')
    .split(',')
    .map(
      (role) => switch (role.trim()) {
        'ceo' => 'CEO',
        'cto' => 'CTO',
        'org-admin' => 'Company Administrator',
        'dev' => 'Software Engineer',
        'qa' => 'QA Engineer',
        'pm' => 'Product Manager',
        'sales' => 'Sales',
        'cs' => 'Customer Support',
        'accountant' => 'Accountant',
        'agent' => 'AI Agent',
        'hr' => 'HR',
        'operations' => 'Operations',
        _ => role.trim(),
      },
    )
    .join(', ');

/// Agent specialty is presentation metadata, never an authorization role.
String agentTitle(Object? id) => switch (id) {
  'mona' => 'Office Assistant',
  'dev-agent' => 'Software Engineer',
  'qa-agent' => 'QA Engineer',
  'pm-agent' => 'Product Manager',
  'sales-agent' => 'Sales Specialist',
  'cskh-agent' => 'Customer Support',
  _ => 'AI Agent',
};

String agentDisplayName(Object? id, Object? name) =>
    '${name ?? id} · ${agentTitle(id)}';

String actorDisplayName(Map<String, dynamic> actor) => actor['kind'] == 'agent'
    ? agentDisplayName(actor['id'], actor['name'])
    : actor['name'] as String;

String agentDefaultName(Object? id) => switch (id) {
  'mona' => 'Mona',
  'dev-agent' => 'Atlas',
  'qa-agent' => 'Iris',
  'pm-agent' => 'Nova',
  'sales-agent' => 'Leo',
  'cskh-agent' => 'Luna',
  _ => id?.toString() ?? 'Agent',
};
