import 'package:flutter/material.dart';

/// 表单页底部固定操作栏，与 agent 编辑/创建页风格一致。
class FormBottomBar extends StatelessWidget {
  final Widget child;

  const FormBottomBar({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(
          top: BorderSide(color: colorScheme.outlineVariant),
        ),
      ),
      child: child,
    );
  }
}

/// 全宽主操作按钮（保存/创建/确认）。
class FormPrimaryButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final IconData icon;
  final String label;
  final bool isLoading;

  const FormPrimaryButton({
    super.key,
    required this.onPressed,
    required this.icon,
    required this.label,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: isLoading ? null : onPressed,
        icon: isLoading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Icon(icon),
        label: Text(label),
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 16),
        ),
      ),
    );
  }
}

/// 取消 + 保存双按钮布局。
class FormCancelSaveBar extends StatelessWidget {
  final VoidCallback? onCancel;
  final VoidCallback? onSave;
  final String cancelLabel;
  final String saveLabel;
  final bool isSaving;

  const FormCancelSaveBar({
    super.key,
    required this.onCancel,
    required this.onSave,
    required this.cancelLabel,
    required this.saveLabel,
    this.isSaving = false,
  });

  @override
  Widget build(BuildContext context) {
    return FormBottomBar(
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: isSaving ? null : onCancel,
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: Text(cancelLabel),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: ElevatedButton.icon(
              onPressed: isSaving ? null : onSave,
              icon: isSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.save),
              label: Text(saveLabel),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
