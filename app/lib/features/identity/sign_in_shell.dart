import 'package:flutter/material.dart';
import 'package:monastack/shared/brand/monastack_logo.dart';
import 'package:monastack/shared/workspace_theme.dart';

class SignInShell extends StatelessWidget {
  const SignInShell({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => SafeArea(
    child: LayoutBuilder(
      builder: (context, bounds) {
        final wide = bounds.maxWidth >= 900;
        final form = Container(
          width: 430,
          padding: EdgeInsets.all(wide ? 36 : 24),
          decoration: BoxDecoration(
            color: WorkspaceColors.paper,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: WorkspaceColors.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: MonastackLogo(size: 42),
              ),
              const SizedBox(height: 24),
              const Text(
                'WELCOME BACK',
                style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 2,
                  fontWeight: FontWeight.w700,
                  color: WorkspaceColors.muted,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Welcome to Monastack',
                style: TextStyle(
                  fontSize: 25,
                  height: 1.25,
                  fontWeight: FontWeight.w700,
                  color: WorkspaceColors.ink,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Sign in to your workspace and pick up where your team left off.',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.6,
                  color: WorkspaceColors.muted,
                ),
              ),
              const SizedBox(height: 26),
              child,
            ],
          ),
        );
        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1020),
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.all(40),
                            margin: const EdgeInsets.only(right: 24),
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [Color(0xff253d38), Color(0xff47665a)],
                              ),
                              borderRadius: BorderRadius.circular(28),
                            ),
                            child: const Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'MONASTACK / YOUR TEAM SPACE',
                                  style: TextStyle(
                                    fontSize: 10,
                                    letterSpacing: 2,
                                    color: Color(0xffd4e5ce),
                                  ),
                                ),
                                SizedBox(height: 54),
                                Icon(
                                  Icons.hub_outlined,
                                  size: 58,
                                  color: Color(0xffd4e5ce),
                                ),
                                SizedBox(height: 28),
                                Text(
                                  'One place.\nBetter together.',
                                  style: TextStyle(
                                    fontSize: 42,
                                    height: 1.15,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xfffcfbf7),
                                    letterSpacing: -1,
                                  ),
                                ),
                                SizedBox(height: 18),
                                Text(
                                  'Bring your people, projects and AI agents into one shared office.',
                                  style: TextStyle(
                                    fontSize: 15,
                                    height: 1.7,
                                    color: Color(0xffd4e5ce),
                                  ),
                                ),
                                SizedBox(height: 42),
                                _Feature(
                                  icon: Icons.meeting_room_outlined,
                                  text: 'A room for every conversation',
                                ),
                                SizedBox(height: 16),
                                _Feature(
                                  icon: Icons.view_kanban_outlined,
                                  text: 'Clear projects. Shared progress.',
                                ),
                                SizedBox(height: 16),
                                _Feature(
                                  icon: Icons.auto_awesome_outlined,
                                  text: 'AI teammates, ready to help',
                                ),
                              ],
                            ),
                          ),
                        ),
                        form,
                      ],
                    )
                  : form,
            ),
          ),
        );
      },
    ),
  );
}

class _Feature extends StatelessWidget {
  const _Feature({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 19, color: const Color(0xffd4e5ce)),
      const SizedBox(width: 12),
      Expanded(
        child: Text(
          text,
          style: const TextStyle(fontSize: 13, color: Color(0xffe4eddf)),
        ),
      ),
    ],
  );
}
