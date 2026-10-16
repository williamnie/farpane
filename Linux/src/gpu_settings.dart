import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/platform_model.dart';

class FarPaneGpuSettings extends StatefulWidget {
  const FarPaneGpuSettings({super.key});

  @override
  State<FarPaneGpuSettings> createState() => _FarPaneGpuSettingsState();
}

class _FarPaneGpuSettingsState extends State<FarPaneGpuSettings> {
  Timer? _timer;
  bool _available = false;
  bool _enabled = false;
  bool _busy = false;
  bool _reading = false;
  String _backend = 'idle';
  String _reason = '';

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    final available = await bind.mainGetOption(key: 'linux-gpu-capability');
    if (!mounted || available != 'Y') return;
    setState(() => _available = true);
    await _refresh();
    if (mounted) {
      _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
    }
  }

  Future<void> _refresh() async {
    if (_reading) return;
    _reading = true;
    try {
      final enabled = await bind.mainGetOption(key: 'linux-gpu-media');
      final text = await bind.mainGetOption(key: 'linux-gpu-status');
      final status = jsonDecode(text) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _enabled = enabled == 'Y';
        _backend = status['backend'] as String? ?? 'unavailable';
        _reason = status['reason'] as String? ?? '';
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _backend = 'unavailable';
          _reason = error.toString();
        });
      }
    } finally {
      _reading = false;
    }
  }

  Future<void> _change(String key, String value) async {
    setState(() => _busy = true);
    try {
      await bind.mainSetOption(key: key, value: value);
      await _refresh();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_available) return const SizedBox.shrink();
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    String t(String chinese, String english) => zh ? chinese : english;
    final status = {
      'disabled': t('已关闭，使用原有媒体路径', 'Disabled; using the original media path'),
      'idle': t('等待兼容的 H.264 连接', 'Waiting for a compatible H.264 connection'),
      'gpu': t('GPU 媒体路径正在运行', 'GPU media path is active'),
      'cpu': t('已回退到原有媒体路径', 'Using the original media path'),
      'unavailable': t('FarPane 后台进程尚未就绪', 'FarPane background process is not ready'),
    }[_backend] ?? _backend;
    return Card(
      margin: const EdgeInsets.fromLTRB(15, 10, 15, 10),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t('Linux GPU 媒体（实验性）', 'Linux GPU media (experimental)'),
              style: const TextStyle(fontSize: 20)),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(t('使用 GPU 捕获与编码', 'Use GPU capture and encoding')),
            subtitle: Text(t('默认关闭。当前支持 linux-host 的单屏、SDR、无旋转 H.264 连接；不满足条件时自动回退。',
                'Off by default. Supports the qualified linux-host display with SDR, no rotation and H.264; other configurations fall back automatically.')),
            value: _enabled,
            onChanged: _busy ? null : (value) => _change('linux-gpu-media', value ? 'Y' : ''),
          ),
          Text(status),
          if (_reason.isNotEmpty && _reason != 'FarPane background process is not ready') Padding(
            padding: const EdgeInsets.only(top: 6), child: SelectableText(_reason)),
          TextButton(
            onPressed: !_enabled || _busy ? null : () => _change('linux-gpu-retry',
                DateTime.now().microsecondsSinceEpoch.toString()),
            child: Text(t('重新检测 GPU', 'Retry GPU detection')),
          ),
          Text(t('切换会重建当前 FarPane 视频流。关闭后即可回到原有媒体路径。',
              'Changing this setting rebuilds the current FarPane video stream. Turn it off to restore the original media path.')),
        ]),
      ),
    );
  }
}
