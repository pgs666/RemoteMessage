import 'package:flutter/material.dart';

import 'app_data.dart';

class ComposeDraft {
  final String phone;
  final String message;
  final int? simSlotIndex;

  const ComposeDraft({required this.phone, required this.message, this.simSlotIndex});
}

class ComposeMessagePage extends StatefulWidget {
  final bool isZh;
  final List<DeviceSimProfile> simProfiles;
  final int? selectedSimSlot;

  const ComposeMessagePage({
    super.key,
    required this.isZh,
    required this.simProfiles,
    required this.selectedSimSlot,
  });

  @override
  State<ComposeMessagePage> createState() => _ComposeMessagePageState();
}

class _ComposeMessagePageState extends State<ComposeMessagePage> {
  final _phoneCtrl = TextEditingController();
  final _messageCtrl = TextEditingController();
  final _previewScrollCtrl = ScrollController();
  int? _simSlot;

  bool get _showSimSelection => widget.simProfiles.length > 1;
  String tr(String zh, String en) => widget.isZh ? zh : en;

  @override
  void initState() {
    super.initState();
    _simSlot = widget.selectedSimSlot ?? (widget.simProfiles.isNotEmpty ? widget.simProfiles.first.slotIndex : null);
    _messageCtrl.addListener(_scrollPreviewToEnd);
  }

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _messageCtrl.removeListener(_scrollPreviewToEnd);
    _messageCtrl.dispose();
    _previewScrollCtrl.dispose();
    super.dispose();
  }

  void _scrollPreviewToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_previewScrollCtrl.hasClients) return;
      _previewScrollCtrl.animateTo(
        _previewScrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    });
  }

  String _displaySimLabel(int slotIndex) => tr('卡${slotIndex + 1}', 'SIM ${slotIndex + 1}');

  void _submit() {
    final phone = _phoneCtrl.text.trim();
    final message = _messageCtrl.text.trim();
    if (phone.isEmpty || message.isEmpty) {
      return;
    }
    Navigator.pop(
      context,
      ComposeDraft(phone: phone, message: message, simSlotIndex: _showSimSelection ? _simSlot : null),
    );
  }

  Widget _buildSimSelector() {
    final label = _simSlot == null ? tr('发卡', 'SIM') : _displaySimLabel(_simSlot!);
    return PopupMenuButton<int>(
      initialValue: _simSlot,
      onSelected: (value) => setState(() => _simSlot = value),
      tooltip: tr('选择发送卡', 'Choose SIM'),
      itemBuilder: (_) => widget.simProfiles
          .map(
            (sim) => PopupMenuItem<int>(
              value: sim.slotIndex,
              child: Text(_displaySimLabel(sim.slotIndex)),
            ),
          )
          .toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        margin: const EdgeInsets.only(right: 4),
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(width: 2),
            const Icon(Icons.arrow_drop_down, size: 16),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('新短信', 'New SMS'))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: TextField(
              controller: _phoneCtrl,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                labelText: tr('号码', 'Phone'),
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.person_outline),
              ),
            ),
          ),
          Expanded(
            child: Container(
              color: Theme.of(context).colorScheme.surfaceContainerLowest,
              child: ListView(
                controller: _previewScrollCtrl,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                children: [
                  if (_messageCtrl.text.trim().isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        tr('在下方输入短信内容，发送前可预览气泡样式。', 'Type your message below to preview the bubble before sending.'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    )
                  else
                    Align(
                      alignment: Alignment.centerRight,
                      child: Container(
                        constraints: const BoxConstraints(maxWidth: 420),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(_messageCtrl.text.trim()),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageCtrl,
                    minLines: 1,
                    maxLines: 4,
                    decoration: InputDecoration(
                      hintText: tr('输入消息...', 'Type a message...'),
                      border: const OutlineInputBorder(),
                      suffixIcon: _showSimSelection ? _buildSimSelector() : null,
                      suffixIconConstraints: const BoxConstraints(minWidth: 68, maxWidth: 124),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FloatingActionButton.small(
                  onPressed: _submit,
                  child: const Icon(Icons.send),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
