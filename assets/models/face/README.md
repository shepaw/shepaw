# Face recognition models (on-device, TFLite)

This directory holds the trained TFLite models used by
`TfliteFaceEmbeddingEngine` (`lib/services/vision/tflite_face_embedding_engine.dart`).
They are **not** checked into git — run `tool/fetch_face_models.sh` to download them
(requires network; sha256-verified).

Expected files:

| file | purpose | input / output |
|---|---|---|
| `ultraface.tflite` | face detection (UltraFace, Linzaer variant) | `[1,240,320,3]` float32 [0,1] → scores `[1,N,2]`, boxes `[1,N,4]` |
| `mobilefacenet.tflite` | face embedding (MobileFaceNet, 112×112) | `[1,112,112,3]` float32 [-1,1] → `[1,192]` |

## Behaviour without models

If these files are absent, `TfliteFaceEmbeddingEngine.isAvailable` returns `false` and
`FaceEmbeddingEngineRegistry.resolve()` falls back to the **Debug engine**
(`debug_face_embedding_engine.dart`, deterministic pseudo-embeddings, clearly not
biometric). The whole pipeline (enroll / recognize / profile) still works end-to-end
for development and tests.
