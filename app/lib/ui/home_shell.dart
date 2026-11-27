import 'package:flutter/material.dart';

import '../app.dart';
import '../state/astra_controller.dart';
import 'chat_list_panel.dart';
import 'onboarding.dart';
import 'screens/chat_screen.dart';
import 'screens/favorites_screen.dart';
import 'screens/provider_edit_screen.dart';
import 'screens/settings_screen.dart';
import 'theme.dart';

enum _Section { chats, favorites, settings }

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  _Section _section = _Section.chats;
  bool _mobileShowChat = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      AstraScope.of(context).onAppResumed();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = AstraScope.of(context);
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final viewInsetsBottom = MediaQuery.viewInsetsOf(context).bottom;
    final inMobileChat = !wide &&
        _section == _Section.chats &&
        _mobileShowChat &&
        controller.currentConversation != null;
    final palette = AstraPalette.of(context);
    final error = controller.lastError;

    Widget content;
    if (wide) {
      content = Row(
        children: [
          _NavRail(
            section: _section,
            onSection: (section) => setState(() => _section = section),
            connected: controller.sync.connectedCount,
          ),
          VerticalDivider(width: 1, color: palette.border),
          if (_section == _Section.settings)
            const Expanded(child: SettingsScreen())
          else if (_section == _Section.favorites)
            Expanded(
              child: FavoritesScreen(
                onJumpToTurn: (conversationId, turnId) {
                  controller.selectConversation(
                    conversationId,
                    focusTurnId: turnId,
                  );
                  setState(() => _section = _Section.chats);
                },
              ),
            )
          else ...[
            SizedBox(
              width: 300,
              child: ChatListPanel(
                onOpenChat: (id) => controller.selectConversation(id),
                onAddProvider: _openProviderEditor,
              ),
            ),
            VerticalDivider(width: 1, color: palette.border),
            Expanded(child: _chatArea(controller, showBack: false)),
          ],
        ],
      );
    } else {
      content = Column(
        children: [
          Expanded(
            child: _section == _Section.settings
                ? const SettingsScreen()
                : _section == _Section.favorites
                    ? FavoritesScreen(
                        onJumpToTurn: (conversationId, turnId) {
                          controller.selectConversation(
                            conversationId,
                            focusTurnId: turnId,
                          );
                          setState(() {
                            _section = _Section.chats;
                            _mobileShowChat = true;
                          });
                        },
                      )
                    : _mobileShowChat && controller.currentConversation != null
                        ? _chatArea(controller, showBack: true)
                        : ChatListPanel(
                            showBrand: true,
                            onOpenChat: (id) {
                              controller.selectConversation(id);
                              setState(() => _mobileShowChat = true);
                            },
                            onAddProvider: _openProviderEditor,
                          ),
          ),
          if (!inMobileChat)
            NavigationBar(
              selectedIndex: switch (_section) {
                _Section.chats => 0,
                _Section.favorites => 1,
                _Section.settings => 2,
              },
              onDestinationSelected: (index) {
                setState(() {
                  _section = switch (index) {
                    0 => _Section.chats,
                    1 => _Section.favorites,
                    _ => _Section.settings,
                  };
                  if (_section != _Section.chats) _mobileShowChat = false;
                });
              },
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.chat_bubble_outline),
                  selectedIcon: Icon(Icons.chat_bubble),
                  label: '对话',
                ),
                NavigationDestination(
                  icon: Icon(Icons.bookmarks_outlined),
                  selectedIcon: Icon(Icons.bookmarks),
                  label: '收藏',
                ),
                NavigationDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings),
                  label: '设置',
                ),
              ],
            ),
        ],
      );
    }

    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        bottom: viewInsetsBottom <= 0,
        child: Column(
          children: [
            if (error != null)
              _ErrorStrip(
                message: error,
                onClose: controller.clearError,
              ),
            Expanded(child: content),
          ],
        ),
      ),
    );
  }

  Widget _chatArea(AstraController controller, {required bool showBack}) {
    final conversation = controller.currentConversation;
    if (conversation == null) {
      return NoConversationView(onAddProvider: _openProviderEditor);
    }
    return ChatScreen(
      key: ValueKey(conversation.id),
      showBack: showBack,
      onBack: () => setState(() => _mobileShowChat = false),
      onDeleted: () => setState(() => _mobileShowChat = false),
    );
  }

  void _openProviderEditor() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const ProviderEditScreen(),
      ),
    );
  }
}

class _NavRail extends StatelessWidget {
  const _NavRail({
    required this.section,
    required this.onSection,
    required this.connected,
  });

  final _Section section;
  final void Function(_Section) onSection;
  final int connected;

  @override
  Widget build(BuildContext context) {
    final palette = AstraPalette.of(context);
    return Container(
      width: 76,
      color: palette.surface,
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        children: [
          const BrandMark(compact: true),
          const SizedBox(height: 24),
          _RailButton(
            icon: Icons.chat_bubble_outline,
            selectedIcon: Icons.chat_bubble,
            tooltip: '对话',
            selected: section == _Section.chats,
            onTap: () => onSection(_Section.chats),
          ),
          const SizedBox(height: 8),
          _RailButton(
            icon: Icons.bookmarks_outlined,
            selectedIcon: Icons.bookmarks,
            tooltip: '收藏',
            selected: section == _Section.favorites,
            onTap: () => onSection(_Section.favorites),
          ),
          const SizedBox(height: 8),
          _RailButton(
            icon: Icons.settings_outlined,
            selectedIcon: Icons.settings,
            tooltip: '设置',
            selected: section == _Section.settings,
            onTap: () => onSection(_Section.settings),
          ),
          const Spacer(),
          if (connected > 0)
            Tooltip(
              message: '$connected 个同步连接',
              child: Icon(
                Icons.cloud_done_outlined,
                size: 18,
                color: palette.accent,
              ),
            ),
          const SizedBox(height: 8),
          Text(
            'LOCAL',
            style: TextStyle(
              color: palette.muted,
              fontSize: 9,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.icon,
    required this.selectedIcon,
    required this.tooltip,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = AstraPalette.of(context);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: selected ? palette.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(
              selected ? selectedIcon : icon,
              color: selected ? palette.accent : palette.muted,
              size: 21,
            ),
          ),
        ),
      ),
    );
  }
}

class _ErrorStrip extends StatelessWidget {
  const _ErrorStrip({required this.message, required this.onClose});

  final String message;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final palette = AstraPalette.of(context);
    return Container(
      width: double.infinity,
      color: palette.danger.withValues(alpha: 0.12),
      padding: const EdgeInsets.fromLTRB(18, 8, 8, 8),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 17, color: palette.danger),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: palette.danger, fontSize: 12.5),
            ),
          ),
          IconButton(
            onPressed: onClose,
            icon: Icon(Icons.close, size: 16, color: palette.danger),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}
