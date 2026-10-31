import 'package:monastack/features/office/world/agent_speech_layer.dart';
import 'package:flutter/material.dart';
import 'package:monastack/shared/node_request.dart';

class AgentConfiguration extends StatefulWidget {
  const AgentConfiguration({super.key, required this.request});
  final NodeRequest request;
  @override
  State<AgentConfiguration> createState() => _AgentConfigurationState();
}

class _AgentConfigurationState extends State<AgentConfiguration> {
  Map<String, dynamic>? data;
  Map<String, dynamic> config = {};
  String selected = 'mona';
  int version = 0;
  bool busy = true;
  String? error;
  final name = TextEditingController();
  final prompt = TextEditingController();
  List audit = [];
  bool get manage => data?['can_manage'] == true;
  List get agents => data?['agents'] as List? ?? [];
  Map get catalog => data?['catalog'] as Map? ?? {};
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    name.dispose();
    prompt.dispose();
    super.dispose();
  }

  void select(String id) {
    final row = agents.firstWhere((a) => a['id'] == id);
    selected = id;
    version = row['version'] as int;
    config = Map<String, dynamic>.from(row['config'] as Map);
    config['activation_mode'] ??= 'voice';
    config['muted_idle_seconds'] ??= 5;
    config['tools'] = List<String>.from(config['tools'] as List? ?? []);
    config['actions'] = List<String>.from(config['actions'] as List? ?? []);
    name.text = config['display_name'] as String? ?? id;
    prompt.text = config['system_prompt'] as String? ?? '';
  }

  Future<void> load() async {
    try {
      final result = await widget.request(
        'GET',
        '/v1/agent-configuration',
      ) as Map<String, dynamic>;
      if (!mounted) return;
      data = result;
      if (manage) {
        audit = await widget.request(
          'GET',
          '/v1/agent-configuration/audit',
        ) as List;
      }
      if (!mounted) return;
      setState(() {
        select(selected);
        busy = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          busy = false;
          error = 'Could not load agent configuration.';
        });
      }
    }
  }

  Future<void> save() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      config['display_name'] = name.text.trim();
      config['system_prompt'] = prompt.text;
      await widget.request('PUT', '/v1/agent-configuration/$selected', {
        'version': version,
        'config': config,
      });
      await load();
    } catch (_) {
      if (mounted) {
        setState(() {
          busy = false;
          error = 'Save failed. Check permissions or reload if another administrator changed this agent.';
        });
      }
    }
  }

  List get filteredVoices {
    final presentation = switch (config['gender']) {
      'female' => 'feminine',
      'male' => 'masculine',
      'nonbinary' => 'neutral',
      _ => null,
    };
    return (catalog['voices'] as List? ?? [])
        .where((v) => presentation == null || v['presentation'] == presentation)
        .toList();
  }

  Widget dropdown(
    String label,
    String field,
    List<String> values, {
    void Function(String)? after,
  }) => DropdownButtonFormField<String>(
    key: ValueKey('$selected-$field-${config[field]}'),
    initialValue: values.contains(config[field])
        ? config[field] as String
        : null,
    decoration: InputDecoration(labelText: label),
    items: [
      for (final value in values)
        DropdownMenuItem(value: value, child: Text(value)),
    ],
    onChanged: !manage || busy
        ? null
        : (value) {
            if (value != null) {
              setState(() {
                config[field] = value;
                after?.call(value);
              });
            }
          },
  );
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Agent configuration'),
    content: SizedBox(
      width: 780,
      height: 580,
      child: data == null
          ? Center(
              child: busy
                  ? const CircularProgressIndicator()
                  : Text(error ?? 'Unavailable'),
            )
          : SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: selected,
                    decoration: const InputDecoration(labelText: 'Agent'),
                    items: [
                      for (final a in agents)
                        DropdownMenuItem(
                          value: a['id'] as String,
                          child: Text(a['config']['display_name'] as String),
                        ),
                    ],
                    onChanged: busy
                        ? null
                        : (value) {
                            if (value != null) setState(() => select(value));
                          },
                  ),
                  if (!manage)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        'Read-only. Agent administration permission is required to edit settings.',
                      ),
                    ),
                  TextField(
                    controller: name,
                    enabled: manage && !busy,
                    decoration: const InputDecoration(
                      labelText: 'Display name',
                    ),
                    maxLength: 60,
                  ),
                  const Text(
                    'Gender & voice',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 76,
                        height: 76,
                        child: AgentAvatarFace(
                          actor: selected,
                          gender: config['gender'] as String? ?? 'unspecified',
                          level: 0,
                          speaking: false,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SegmentedButton<String>(
                              segments: const [
                                ButtonSegment(
                                  value: 'female',
                                  label: Text('Female'),
                                  icon: Icon(Icons.face_3_outlined),
                                ),
                                ButtonSegment(
                                  value: 'male',
                                  label: Text('Male'),
                                  icon: Icon(Icons.face_6_outlined),
                                ),
                              ],
                              selected:
                                  {'female', 'male'}.contains(config['gender'])
                                  ? {config['gender'] as String}
                                  : {},
                              emptySelectionAllowed: !{
                                'female',
                                'male',
                              }.contains(config['gender']),
                              onSelectionChanged: !manage || busy
                                  ? null
                                  : (values) {
                                      if (values.isEmpty) return;
                                      setState(() {
                                        config['gender'] = values.single;
                                        if (!filteredVoices.any(
                                          (v) => v['id'] == config['voice'],
                                        )) {
                                          final recommended =
                                              values.single == 'male'
                                              ? 'cedar'
                                              : 'marin';
                                          config['voice'] =
                                              filteredVoices.any(
                                                (v) => v['id'] == recommended,
                                              )
                                              ? recommended
                                              : filteredVoices
                                                    .firstOrNull?['id'];
                                        }
                                      });
                                    },
                            ),
                            const SizedBox(height: 6),
                            Text(
                              {'female', 'male'}.contains(config['gender'])
                                  ? '${config['gender'] == 'female' ? 'Female avatar' : 'Male avatar'} · voice: ${config['voice']}'
                                  : 'Choose Female or Male to apply an avatar and matching voice.',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  dropdown('Voice', 'voice', [
                    for (final v in filteredVoices) v['id'] as String,
                  ]),
                  Text(
                    catalog['voice_filter_note'] as String? ?? '',
                    style: const TextStyle(fontSize: 11),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Agent enabled'),
                    value: config['enabled'] == true,
                    onChanged: manage && !busy
                        ? (v) => setState(() => config['enabled'] = v)
                        : null,
                  ),
                  if (manage) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'Voice activation',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    DropdownButtonFormField<String>(
                      key: ValueKey(
                        '$selected-activation-${config['activation_mode']}',
                      ),
                      initialValue: config['activation_mode'] as String,
                      decoration: const InputDecoration(
                        labelText: 'Start GPT-Live',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'voice',
                          child: Text('Wait for voice · mic on + speech'),
                        ),
                        DropdownMenuItem(
                          value: 'automatic',
                          child: Text('Automatic on room entry'),
                        ),
                      ],
                      onChanged: busy
                          ? null
                          : (v) {
                              if (v != null) {
                                setState(() => config['activation_mode'] = v);
                              }
                            },
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        config['activation_mode'] == 'automatic'
                            ? 'Starts a billed Live session when someone connects to the room, including with microphones off. After the timeout it waits for voice or a new arrival.'
                            : 'Keeps GPT-Live closed until an authorized unmuted microphone has speech.',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    for (final spec in [
                      ('idle_seconds', 'No speech timeout (seconds)', 5, 600),
                      (
                        'muted_idle_seconds',
                        'All microphones muted timeout (seconds)',
                        1,
                        600,
                      ),
                    ])
                      TextFormField(
                        key: ValueKey('$selected-${spec.$1}-$version'),
                        initialValue: '${config[spec.$1]}',
                        enabled: !busy,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: spec.$2,
                          helperText:
                              '${spec.$3}–${spec.$4}. The agent finishes its reply/work before closing. Global safety cap applies.',
                        ),
                        onChanged: (v) {
                          config[spec.$1] = int.tryParse(v) ?? 0;
                        },
                      ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: prompt,
                      enabled: !busy,
                      minLines: 5,
                      maxLines: 12,
                      maxLength: 8000,
                      decoration: const InputDecoration(
                        labelText: 'System prompt',
                        alignLabelWithHint: true,
                      ),
                    ),
                    dropdown('Conversation language', 'language', [
                      'auto',
                      'en',
                      'vi',
                    ]),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Greet when the conversation starts'),
                      value: config['greeting'] == true,
                      onChanged: busy
                          ? null
                          : (v) => setState(() => config['greeting'] = v),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Tools & allowed actions',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const Text(
                      'Mona administration actions also require the initiating user to have administration permission. Task creation always requires app approval.',
                      style: TextStyle(fontSize: 12),
                    ),
                    for (final tool in catalog['tools'] as List? ?? [])
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(tool as String),
                        value: (config['tools'] as List).contains(tool),
                        onChanged: busy
                            ? null
                            : (v) => setState(() {
                                final tools = config['tools'] as List;
                                if (v == true) {
                                  tools.add(tool);
                                } else {
                                  tools.remove(tool);
                                  (config['actions'] as List).removeWhere(
                                    (a) => (catalog['actions'] as List).any(
                                      (entry) =>
                                          entry['id'] == a &&
                                          entry['tool'] == tool,
                                    ),
                                  );
                                }
                              }),
                      ),
                    for (final action in catalog['actions'] as List? ?? [])
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(action['label'] as String),
                        subtitle: Text(
                          '${action['id']}${action['supported'] != true
                              ? ' · Adapter not installed'
                              : action['mona_only'] == true
                              ? ' · Mona + authorized administrator'
                              : ''}',
                        ),
                        value: (config['actions'] as List).contains(
                          action['id'],
                        ),
                        onChanged:
                            busy ||
                                action['supported'] != true ||
                                (action['mona_only'] == true &&
                                    selected != 'mona') ||
                                !(config['tools'] as List).contains(
                                  action['tool'],
                                )
                            ? null
                            : (v) => setState(() {
                                final actions = config['actions'] as List;
                                if (v == true) {
                                  actions.add(action['id']);
                                } else {
                                  actions.remove(action['id']);
                                }
                              }),
                      ),
                    const Divider(),
                    const Text(
                      'Session limits',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    for (final spec in [
                      (
                        'session_seconds',
                        'Session duration cap (seconds)',
                        30,
                        3600,
                      ),
                    ])
                      TextFormField(
                        key: ValueKey('$selected-${spec.$1}-$version'),
                        initialValue: '${config[spec.$1]}',
                        enabled: !busy,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: spec.$2,
                          helperText:
                              '${spec.$3}–${spec.$4}; the global server cap also applies',
                        ),
                        onChanged: (v) {
                          config[spec.$1] = int.tryParse(v) ?? 0;
                        },
                      ),
                    const SizedBox(height: 16),
                    const Text(
                      'Recent configuration changes',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    for (final entry
                        in audit.where((a) => a['agent'] == selected).take(10))
                      Text(
                        'v${entry['version']} · ${entry['actor']} · ${entry['source']}',
                      ),
                  ],
                  if (error != null)
                    Text(error!, style: const TextStyle(color: Colors.red)),
                ],
              ),
            ),
    ),
    actions: [
      TextButton(onPressed: busy ? null : load, child: const Text('Reload')),
      if (manage)
        TextButton(
          onPressed: busy
              ? null
              : () async {
                  setState(() {
                    busy = true;
                    error = null;
                  });
                  try {
                    await widget.request(
                      'POST',
                      '/v1/agent-configuration/$selected/reset',
                      {'version': version},
                    );
                    await load();
                  } catch (_) {
                    if (mounted) {
                      setState(() {
                        busy = false;
                        error =
                            'Could not restore defaults. Reload and try again.';
                      });
                    }
                  }
                },
          child: const Text('Restore defaults'),
        ),
      if (manage)
        FilledButton(
          onPressed: busy ? null : save,
          child: const Text('Save configuration'),
        ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  );
}
