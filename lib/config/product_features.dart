/// Product-level UI feature gates. Services and screens stay in the tree;
/// toggles only hide user-facing entry points until features ship.
class ProductFeatures {
  ProductFeatures._();

  /// Human P2P device chat ([PeerChatScreen], peer tiles, peer message search).
  static const bool deviceChatUiEnabled = false;
}
