import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../widgets/skill_config_card.dart';

/// Full-page screen for configuring skills.
///
/// Receives the current set of enabled skills and returns the updated set
/// via [Navigator.pop].
class SkillSelectScreen extends StatefulWidget {
  final Set<String> enabledSkills;

  const SkillSelectScreen({super.key, required this.enabledSkills});

  @override
  State<SkillSelectScreen> createState() => _SkillSelectScreenState();
}

class _SkillSelectScreenState extends State<SkillSelectScreen> {
  late Set<String> _enabledSkills;

  @override
  void initState() {
    super.initState();
    _enabledSkills = Set<String>.from(widget.enabledSkills);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.addAgent_configureSkills),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _enabledSkills),
            child: Text(l10n.common_save),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SkillConfigCard(
          enabledSkills: _enabledSkills,
          onChanged: (skills) {
            setState(() {
              _enabledSkills = skills;
            });
          },
        ),
      ),
    );
  }
}
