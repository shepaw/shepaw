import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../models/model_routing_config.dart';
import '../widgets/model_routing_config_card.dart';

/// Full-page screen for configuring multi-modal model routing.
///
/// Receives the current routing map and returns the updated
/// [ModelRoutingConfig] (routes + custom modalities) via [Navigator.pop].
class ModelRoutingConfigScreen extends StatefulWidget {
  final Map<ModalityType, ModelRouteConfig> routes;
  final List<CustomModality> customModalities;

  const ModelRoutingConfigScreen({
    super.key,
    required this.routes,
    this.customModalities = const [],
  });

  @override
  State<ModelRoutingConfigScreen> createState() =>
      _ModelRoutingConfigScreenState();
}

class _ModelRoutingConfigScreenState extends State<ModelRoutingConfigScreen> {
  late Map<ModalityType, ModelRouteConfig> _routes;
  late List<CustomModality> _customModalities;

  @override
  void initState() {
    super.initState();
    _routes = Map<ModalityType, ModelRouteConfig>.from(widget.routes);
    _customModalities = List<CustomModality>.from(widget.customModalities);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.addAgent_configureModelRouting),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, {
              'routes': _routes,
              'customModalities': _customModalities,
            }),
            child: Text(l10n.common_save),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: ModelRoutingConfigCard(
          routes: _routes,
          customModalities: _customModalities,
          onChanged: (routes, customModalities) {
            setState(() {
              _routes = routes;
              _customModalities = customModalities;
            });
          },
        ),
      ),
    );
  }
}
