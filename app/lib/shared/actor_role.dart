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
