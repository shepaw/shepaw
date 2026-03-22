import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'logger_service.dart';

/// 播放状态
class AudioPlaybackState {
  final String? messageId;
  final bool isPlaying;
  final Duration position;
  final Duration duration;

  const AudioPlaybackState({
    this.messageId,
    this.isPlaying = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
  });
}

/// 音频播放服务 - 单例模式
class AudioPlaybackService {
  static final AudioPlaybackService _instance = AudioPlaybackService._internal();
  factory AudioPlaybackService() => _instance;
  AudioPlaybackService._internal();

  final AudioPlayer _player = AudioPlayer();
  final _stateController = StreamController<AudioPlaybackState>.broadcast();
  Stream<AudioPlaybackState> get stateStream => _stateController.stream;

  String? _currentMessageId;
  AudioPlaybackState _state = const AudioPlaybackState();
  AudioPlaybackState get currentState => _state;

  bool _initialized = false;

  void _ensureInitialized() {
    if (_initialized) return;
    _initialized = true;

    _player.onPositionChanged.listen((position) {
      _state = AudioPlaybackState(
        messageId: _currentMessageId,
        isPlaying: true,
        position: position,
        duration: _state.duration,
      );
      _stateController.add(_state);
    });

    _player.onDurationChanged.listen((duration) {
      _state = AudioPlaybackState(
        messageId: _currentMessageId,
        isPlaying: _state.isPlaying,
        position: _state.position,
        duration: duration,
      );
      _stateController.add(_state);
    });

    _player.onPlayerComplete.listen((_) {
      _state = AudioPlaybackState(
        messageId: _currentMessageId,
        isPlaying: false,
        position: Duration.zero,
        duration: _state.duration,
      );
      _stateController.add(_state);
      _currentMessageId = null;
    });
  }

  /// 播放/暂停切换
  Future<void> playOrToggle(String messageId, String filePath) async {
    _ensureInitialized();

    try {
      if (_currentMessageId == messageId) {
        // 同一条消息：暂停/恢复
        if (_state.isPlaying) {
          await _player.pause();
          _state = AudioPlaybackState(
            messageId: messageId,
            isPlaying: false,
            position: _state.position,
            duration: _state.duration,
          );
          _stateController.add(_state);
        } else {
          await _player.resume();
          _state = AudioPlaybackState(
            messageId: messageId,
            isPlaying: true,
            position: _state.position,
            duration: _state.duration,
          );
          _stateController.add(_state);
        }
      } else {
        // 不同消息：停止当前，播放新的
        await _player.stop();
        _currentMessageId = messageId;

        _state = AudioPlaybackState(
          messageId: messageId,
          isPlaying: true,
          position: Duration.zero,
          duration: Duration.zero,
        );
        _stateController.add(_state);

        await _player.play(DeviceFileSource(filePath));
      }
    } catch (e) {
      LoggerService().error('Audio playback error', tag: 'AudioPlayback', error: e);
      _state = const AudioPlaybackState();
      _stateController.add(_state);
      _currentMessageId = null;
    }
  }

  /// 停止播放
  Future<void> stop() async {
    await _player.stop();
    _currentMessageId = null;
    _state = const AudioPlaybackState();
    _stateController.add(_state);
  }

  void dispose() {
    _player.dispose();
    _stateController.close();
  }
}
