import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app.dart';
import '../theme.dart';
import '../widgets/common.dart';

class SyncSection extends StatefulWidget {
  const SyncSection({super.key});

  @override
  State<SyncSection> createState() => _SyncSectionState();
}

class _SyncSectionState extends State<SyncSection> {
  final _code = TextEditingController();
  Timer? _ticker;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = AstraScope.of(context);
    final sync = controller.sync;
    final palette = AstraPalette.of(context);
    final peers = sync.peers;
    final connected = sync.connectedPeerIds;
    final expires = sync.pairingExpiresAt;
    final remaining = expires == null
        ? 0
        : expires.difference(DateTime.now()).inSeconds;

    return AstraSurface(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle(
            title: '同步',
            subtitle: '局域网内凭配对码同步聊天、图片与模型配置；API Key 永不同步',
          ),
          const SizedBox(height: 6),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('本机作为同步主机'),
            subtitle: Text(
              sync.hosting
                  ? '已监听局域网，Android 仅在前台时保持'
                  : '开启后可让其他 Astra 客户端输入配对码接入',
              style: TextStyle(color: palette.muted, fontSize: 12),
            ),
            value: sync.hosting,
            onChanged: _working ? null : (value) => _toggleHosting(value),
          ),
          if (sync.hosting) ...[
            Row(
              children: [
                FilledButton.icon(
                  onPressed: _working ? null : _generateCode,
                  icon: const Icon(Icons.qr_code_2, size: 17),
                  label: const Text('生成配对码'),
                ),
                const SizedBox(width: 10),
                if (sync.pairingCode != null)
                  Text(
                    remaining > 0 ? '$remaining 秒后失效' : '已过期',
                    style: TextStyle(color: palette.muted, fontSize: 12),
                  ),
              ],
            ),
            if (sync.pairingCode != null) ...[
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                decoration: BoxDecoration(
                  color: palette.accentSoft,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: palette.accent.withOpacity(0.3),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: SelectableText(
                        _formatCode(sync.pairingCode!),
                        style: TextStyle(
                          fontSize: 21,
                          letterSpacing: 1.8,
                          fontWeight: FontWeight.w700,
                          color: palette.accent,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '复制配对码',
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: sync.pairingCode!),
                        );
                        if (context.mounted) {
                          showAppSnack(context, '配对码已复制');
                        }
                      },
                      icon: Icon(Icons.copy_rounded, color: palette.accent),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 18),
            Text(
              '加入其他设备',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: palette.ink,
              ),
            ),
            const SizedBox(height: 7),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _code,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      hintText: '输入对方显示的 12 位配对码',
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.tonal(
                  onPressed: _working ? null : _join,
                  child: const Text('加入'),
                ),
              ],
            ),
          ] else ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _code,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      hintText: '输入对方显示的 12 位配对码',
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.tonal(
                  onPressed: _working ? null : _join,
                  child: const Text('加入'),
                ),
              ],
            ),
          ],
          if (_working) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(minHeight: 2),
          ],
          const SizedBox(height: 18),
          Row(
            children: [
              Text(
                '已配对设备 (${peers.length})',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: palette.ink,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _working
                    ? null
                    : () async {
                        setState(() => _working = true);
                        try {
                          await controller.syncNow();
                        } finally {
                          if (mounted) setState(() => _working = false);
                        }
                      },
                icon: const Icon(Icons.sync, size: 16),
                label: const Text('立即同步'),
              ),
            ],
          ),
          if (peers.isEmpty)
            Text(
              '还没有配对设备。让对方生成配对码，或本机生成后让对方输入。',
              style: TextStyle(color: palette.muted, fontSize: 12.5),
            )
          else
            ...peers.map((peer) {
              final online = connected.contains(peer.deviceId);
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  peer.isHost ? Icons.computer : Icons.smartphone,
                  color: palette.muted,
                ),
                title: Text(peer.name),
                subtitle: Text(
                  '${peer.platform} · ${online ? '在线' : '离线'} · '
                  '${peer.isHost ? '本机为主机' : '本机为加入方'}',
                  style: TextStyle(color: palette.muted, fontSize: 12),
                ),
                trailing: PopupMenuButton<String>(
                  onSelected: (value) async {
                    if (value == 'unpair') {
                      await controller.unpair(peer.deviceId);
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'unpair', child: Text('解除配对')),
                  ],
                ),
              );
            }),
          if (peers.isNotEmpty) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _working
                    ? null
                    : () async {
                        setState(() => _working = true);
                        try {
                          await controller.reconnectPeers();
                        } catch (error) {
                          if (context.mounted) showAppSnack(context, '$error');
                        } finally {
                          if (mounted) setState(() => _working = false);
                        }
                      },
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('重新连接已有设备'),
              ),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            '同步只在同一局域网内进行，配对数据使用设备间加密。'
            '手机作为主机时需要保持 Astra 在前台。',
            style: TextStyle(color: palette.muted, fontSize: 11.5, height: 1.5),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleHosting(bool value) async {
    final controller = AstraScope.of(context);
    setState(() => _working = true);
    try {
      if (value) {
        await controller.startHosting();
      } else {
        await controller.stopHosting();
      }
    } catch (error) {
      if (mounted) showAppSnack(context, '$error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _generateCode() async {
    final controller = AstraScope.of(context);
    setState(() => _working = true);
    try {
      await controller.createPairingCode();
    } catch (error) {
      if (mounted) showAppSnack(context, '$error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _join() async {
    final controller = AstraScope.of(context);
    setState(() => _working = true);
    try {
      await controller.joinWithCode(_code.text);
      _code.clear();
      if (mounted) showAppSnack(context, '配对成功，正在同步');
    } catch (error) {
      if (mounted) showAppSnack(context, '$error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }
}

String _formatCode(String code) {
  final buffer = StringBuffer();
  for (var i = 0; i < code.length; i++) {
    if (i > 0 && i % 4 == 0) buffer.write(' ');
    buffer.write(code[i]);
  }
  return buffer.toString();
}
