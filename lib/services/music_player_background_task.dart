import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:finamp/models/finamp_models.dart';
import 'package:finamp/models/jellyfin_models.dart' as jellyfin_models;
import 'package:finamp/services/queue_service.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:logging/logging.dart';

import 'finamp_settings_helper.dart';

/// This provider handles the currently playing music so that multiple widgets
/// can control music.
class MusicPlayerBackgroundTask extends BaseAudioHandler {
  late final AudioPlayer _player;
  late final AudioPipeline _audioPipeline;
  late final List<AndroidAudioEffect> _androidAudioEffects;
  late final List<DarwinAudioEffect> _iosAudioEffects;
  late final AndroidLoudnessEnhancer? _loudnessEnhancerEffect;

  ConcatenatingAudioSource _queueAudioSource =
      ConcatenatingAudioSource(children: []);
  final _audioServiceBackgroundTaskLogger = Logger("MusicPlayerBackgroundTask");
  final _volumeNormalizationLogger = Logger("VolumeNormalization");

  /// Set when creating a new queue. Will be used to set the first index in a
  /// new queue.
  int? nextInitialIndex;

  Duration _sleepTimerDuration = Duration.zero;
  DateTime _sleepTimerStartTime = DateTime.now();

  /// Holds the current sleep timer, if any. This is a ValueNotifier so that
  /// widgets like SleepTimerButton can update when the sleep timer is/isn't
  /// null.
  final ValueNotifier<Timer?> _sleepTimer = ValueNotifier<Timer?>(null);

  Future<bool> Function()? _queueCallbackPreviousTrack;

  List<int>? get shuffleIndices => _player.shuffleIndices;

  ValueListenable<Timer?> get sleepTimer => _sleepTimer;

  double iosBaseVolumeGainFactor = 1.0;

  MusicPlayerBackgroundTask() {
    _audioServiceBackgroundTaskLogger.info("Starting audio service");

    if (Platform.isWindows || Platform.isLinux) {
      _audioServiceBackgroundTaskLogger
          .info("Initializing media-kit for Windows/Linux");
      JustAudioMediaKit.title = "Finamp";
      JustAudioMediaKit.prefetchPlaylist = true; // cache upcoming tracks
      JustAudioMediaKit.ensureInitialized(
        linux: true,
        windows: true,
        macOS: false,
        iOS: false,
        android: false,
      );
    }

    _androidAudioEffects = [];
    _iosAudioEffects = [];

    if (Platform.isAndroid) {
      _loudnessEnhancerEffect = AndroidLoudnessEnhancer();
      _androidAudioEffects.add(_loudnessEnhancerEffect!);
    } else {
      _loudnessEnhancerEffect = null;
    }

    _audioPipeline = AudioPipeline(
      androidAudioEffects: _androidAudioEffects,
      darwinAudioEffects: _iosAudioEffects,
    );

    _player = AudioPlayer(
      audioLoadConfiguration: AudioLoadConfiguration(
        androidLoadControl: AndroidLoadControl(
          minBufferDuration: FinampSettingsHelper.finampSettings.bufferDuration,
          maxBufferDuration: FinampSettingsHelper
                  .finampSettings.bufferDuration *
              1.5, // allows the player to fetch a bit more data in exchange for reduced request frequency
          prioritizeTimeOverSizeThresholds: true,
        ),
        darwinLoadControl: DarwinLoadControl(
          preferredForwardBufferDuration:
              FinampSettingsHelper.finampSettings.bufferDuration,
        ),
      ),
      audioPipeline: _audioPipeline,
    );

    _loudnessEnhancerEffect?.setEnabled(
        FinampSettingsHelper.finampSettings.volumeNormalizationActive);
    _loudnessEnhancerEffect?.setTargetGain(0.0 /
        10.0); //!!! always divide by 10, the just_audio implementation has a bug so it expects a value in Bel and not Decibel (remove once https://github.com/ryanheise/just_audio/pull/1092/commits/436b3274d0233818a061ecc1c0856a630329c4e6 is merged)
    // calculate base volume gain for iOS as a linear factor, because just_audio doesn't yet support AudioEffect on iOS
    iosBaseVolumeGainFactor = pow(
            10.0,
            FinampSettingsHelper.finampSettings.volumeNormalizationIOSBaseGain /
                20.0)
        as double; // https://sound.stackexchange.com/questions/38722/convert-db-value-to-linear-scale
    if (!Platform.isAndroid) {
      _volumeNormalizationLogger.info(
          "non-Android base volume gain factor: $iosBaseVolumeGainFactor");
    }

    // Propagate all events from the audio player to AudioService clients.
    _player.playbackEventStream.listen((event) async {
      playbackState.add(_transformEvent(event));
    });

    FinampSettingsHelper.finampSettingsListener.addListener(() {
      // update replay gain settings every time settings are changed
      iosBaseVolumeGainFactor = pow(
              10.0,
              FinampSettingsHelper
                      .finampSettings.volumeNormalizationIOSBaseGain /
                  20.0)
          as double; // https://sound.stackexchange.com/questions/38722/convert-db-value-to-linear-scale
      if (FinampSettingsHelper.finampSettings.volumeNormalizationActive) {
        _loudnessEnhancerEffect?.setEnabled(true);
        _applyVolumeNormalization(mediaItem.valueOrNull);
      } else {
        _loudnessEnhancerEffect?.setEnabled(false);
        _player.setVolume(1.0); // disable replay gain on iOS
        _volumeNormalizationLogger.info("Replay gain disabled");
      }
    });

    mediaItem.listen((currentTrack) {
      _applyVolumeNormalization(currentTrack);
    });

    // Special processing for state transitions.
    _player.processingStateStream.listen((event) async {
      if (event == ProcessingState.completed) {
        await handleEndOfQueue();
      }
    });

    // PlaybackEvent doesn't include shuffle/loops so we listen for changes here
    _player.shuffleModeEnabledStream.listen((_) {
      final event = _transformEvent(_player.playbackEvent);
      playbackState.add(event);
      _audioServiceBackgroundTaskLogger.info(
          "Shuffle mode changed to ${event.shuffleMode} (${_player.shuffleModeEnabled}).");
    });
    _player.loopModeStream.listen((_) {
      final event = _transformEvent(_player.playbackEvent);
      playbackState.add(event);
      _audioServiceBackgroundTaskLogger.info(
          "Loop mode changed to ${event.repeatMode} (${_player.loopMode}).");
    });
  }

  /// this could be useful for updating queue state from this player class, but isn't used right now due to limitations with just_audio
  void setQueueCallbacks({
    required Future<bool> Function() previousTrackCallback,
  }) {
    _queueCallbackPreviousTrack = previousTrackCallback;
  }

  Future<void> initializeAudioSource(ConcatenatingAudioSource source,
      {required bool preload}) async {
    _queueAudioSource = source;

    try {
      await _player.setAudioSource(
        _queueAudioSource,
        preload: preload,
        initialIndex: nextInitialIndex,
      );
    } on PlayerException catch (e) {
      _audioServiceBackgroundTaskLogger
          .severe("Player error code ${e.code}: ${e.message}");
    } on PlayerInterruptedException catch (e) {
      _audioServiceBackgroundTaskLogger
          .warning("Player interrupted: ${e.message}");
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe("Player error ${e.toString()}");
    }
  }

  /// Fully dispose the player instance.  Should only be called during app shutdown.
  Future<void> dispose() => _player.dispose();

  @override
  Future<void> play() {
    return _player.play();
  }

  @override
  Future<void> setSpeed(final double speed) async {
    return _player.setSpeed(speed);
  }

  @override
  Future<void> pause() => _player.pause();

  Future<void> togglePlayback() {
    if (_player.playing) {
      return pause();
    } else {
      return play();
    }
  }

  @override
  Future<void> stop() async {
    try {
      _audioServiceBackgroundTaskLogger.info("Stopping audio service");

      final queueService = GetIt.instance<QueueService>();
      await queueService.stopPlayback();
      // await _player.seek(_player.duration);

      // await handleEndOfQueue();

      _sleepTimerDuration = Duration.zero;

      _sleepTimer.value?.cancel();
      _sleepTimer.value = null;

      await super.stop();
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  Future<void> stopPlayback() async {
    try {
      await _player.stop();
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  Future<void> handleEndOfQueue() async {
    try {
      _audioServiceBackgroundTaskLogger.info("Queue completed.");
      // A full stop will trigger a re-shuffle with an unshuffled first
      // item, so only pause.
      await pause();
      // Skipping to zero with empty queue re-triggers queue complete event
      if (_player.effectiveIndices?.isNotEmpty ?? false) {
        await skipToIndex(0);
      }
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  int getPlayPositionInSeconds() {
    return _player.position.inSeconds;
  }

  @override
  Future<void> skipToPrevious({
    bool forceSkip = false,
  }) async {
    bool doSkip = true;

    try {
      if (_queueCallbackPreviousTrack != null) {
        doSkip = await _queueCallbackPreviousTrack!();
      } else {
        doSkip = _player.position.inSeconds < 5;
      }

      // This can only be true if on first track while loop mode is off
      if (!_player.hasPrevious) {
        await _player.seek(Duration.zero);
      } else {
        if (doSkip || forceSkip) {
          if (_player.loopMode == LoopMode.one) {
            // if the user manually skips to the previous track, they probably want to actually skip to the previous track
            await skipByOffset(
                -1); //!!! don't use _player.previousIndex here, because that adjusts based on loop mode
          } else {
            await _player.seekToPrevious();
          }
        } else {
          await _player.seek(Duration.zero);
        }
      }
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  @override
  Future<void> skipToNext() async {
    try {
      if (_player.loopMode == LoopMode.one || !_player.hasNext) {
        // if the user manually skips to the next track, they probably want to actually skip to the next track
        await skipByOffset(
            1); //!!! don't use _player.nextIndex here, because that adjusts based on loop mode
      } else {
        await _player.seekToNext();
      }
      _audioServiceBackgroundTaskLogger
          .finer("_player.nextIndex: ${_player.nextIndex}");
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  Future<void> skipByOffset(int offset) async {
    _audioServiceBackgroundTaskLogger.fine("skipping by offset: $offset");

    try {
      int queueIndex = _player.shuffleModeEnabled
          ? _queueAudioSource.shuffleIndices
                  .indexOf((_player.currentIndex ?? 0)) +
              offset
          : (_player.currentIndex ?? 0) + offset;
      if (queueIndex >= (_player.effectiveIndices?.length ?? 1)) {
        if (_player.loopMode == LoopMode.off) {
          //!!! seek to end of track to for the player to handle the end of queue
          // this is hacky, but seems to be the only way to get the proper events that the playback history service needs
          //TODO Finamp should probably use its own event system that is able to convey the necessary information
          return await _player.seek(_player.duration);
        }
        queueIndex %= (_player.effectiveIndices?.length ?? 1);
      }
      if (queueIndex < 0) {
        if (_player.loopMode == LoopMode.off) {
          queueIndex = 0;
        } else {
          queueIndex %= (_player.effectiveIndices?.length ?? 1);
        }
      }
      await _player.seek(Duration.zero,
          index: _player.shuffleModeEnabled
              ? _queueAudioSource.shuffleIndices[queueIndex]
              : queueIndex);
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  Future<void> skipToIndex(int index) async {
    _audioServiceBackgroundTaskLogger.fine("skipping to index: $index");

    try {
      await _player.seek(Duration.zero,
          index: _player.shuffleModeEnabled
              ? _queueAudioSource.shuffleIndices[index]
              : index);
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  @override
  Future<void> seek(Duration position) async {
    try {
      await _player.seek(position);
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  Future<void> shuffle() async {
    try {
      await _player.shuffle();
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    try {
      switch (shuffleMode) {
        case AudioServiceShuffleMode.all:
          await _player.setShuffleModeEnabled(true);
          break;
        case AudioServiceShuffleMode.none:
          await _player.setShuffleModeEnabled(false);
          break;
        default:
          return Future.error(
              "Unsupported AudioServiceRepeatMode! Received ${shuffleMode.toString()}, requires all or none.");
      }
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    try {
      switch (repeatMode) {
        case AudioServiceRepeatMode.all:
          await _player.setLoopMode(LoopMode.all);
          break;
        case AudioServiceRepeatMode.none:
          await _player.setLoopMode(LoopMode.off);
          break;
        case AudioServiceRepeatMode.one:
          await _player.setLoopMode(LoopMode.one);
          break;
        default:
          return Future.error(
              "Unsupported AudioServiceRepeatMode! Received ${repeatMode.toString()}, requires all, none, or one.");
      }
    } catch (e) {
      _audioServiceBackgroundTaskLogger.severe(e);
      return Future.error(e);
    }
  }

  void setNextInitialIndex(int index) {
    nextInitialIndex = index;
  }

  void _applyVolumeNormalization(MediaItem? currentTrack) {
    if (FinampSettingsHelper.finampSettings.volumeNormalizationActive &&
        currentTrack != null) {
      final baseItem = jellyfin_models.BaseItemDto.fromJson(
          currentTrack.extras?["itemJson"]);

      double? effectiveGainChange =
          getEffectiveGainChange(currentTrack, baseItem);

      _volumeNormalizationLogger.info(
          "normalization gain for '${baseItem.name}': $effectiveGainChange (track gain change: ${baseItem.normalizationGain})");
      if (effectiveGainChange != null) {
        _volumeNormalizationLogger.info("Gain change: $effectiveGainChange");
        if (Platform.isAndroid) {
          _loudnessEnhancerEffect?.setTargetGain(effectiveGainChange /
              10.0); //!!! always divide by 10, the just_audio implementation has a bug so it expects a value in Bel and not Decibel (remove once https://github.com/ryanheise/just_audio/pull/1092/commits/436b3274d0233818a061ecc1c0856a630329c4e6 is merged)
        } else {
          final newVolume = iosBaseVolumeGainFactor *
              pow(
                  10.0,
                  effectiveGainChange /
                      20.0); // https://sound.stackexchange.com/questions/38722/convert-db-value-to-linear-scale
          final newVolumeClamped = newVolume.clamp(0.0, 1.0);
          _volumeNormalizationLogger
              .finer("new volume: $newVolume ($newVolumeClamped clipped)");
          _player.setVolume(newVolumeClamped);
        }
      } else {
        // reset gain offset
        _loudnessEnhancerEffect?.setTargetGain(0 /
            10.0); //!!! always divide by 10, the just_audio implementation has a bug so it expects a value in Bel and not Decibel (remove once https://github.com/ryanheise/just_audio/pull/1092/commits/436b3274d0233818a061ecc1c0856ua630329c4e6 is merged)
        _player.setVolume(
            iosBaseVolumeGainFactor); //!!! it's important that the base gain is used instead of 1.0, so that any tracks without normalization gain information don't fall back to full volume, but to the base volume for iOS
      }
    }
  }

  /// Sets the sleep timer with the given [duration].
  Timer setSleepTimer(Duration duration) {
    _sleepTimerDuration = duration;
    _sleepTimerStartTime = DateTime.now();

    _sleepTimer.value = Timer(duration, () async {
      _sleepTimer.value = null;
      return await pause();
    });
    return _sleepTimer.value!;
  }

  /// Cancels the sleep timer and clears it.
  void clearSleepTimer() {
    _sleepTimerDuration = Duration.zero;

    _sleepTimer.value?.cancel();
    _sleepTimer.value = null;
  }

  Duration get sleepTimerRemaining {
    if (_sleepTimer.value == null) {
      return Duration.zero;
    } else {
      return _sleepTimerStartTime
          .add(_sleepTimerDuration)
          .difference(DateTime.now());
    }
  }

  /// Transform a just_audio event into an audio_service state.
  ///
  /// This method is used from the constructor. Every event received from the
  /// just_audio player will be transformed into an audio_service state so that
  /// it can be broadcast to audio_service clients.
  PlaybackState _transformEvent(PlaybackEvent event) {
    return PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (_player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 3],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_player.processingState]!,
      playing: _player.playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: _player.shuffleModeEnabled &&
              (shuffleIndices?.isNotEmpty ?? false) &&
              event.currentIndex != null
          ? shuffleIndices!.indexOf(event.currentIndex!)
          : event.currentIndex,
      shuffleMode: _player.shuffleModeEnabled
          ? AudioServiceShuffleMode.all
          : AudioServiceShuffleMode.none,
      repeatMode: _audioServiceRepeatMode(_player.loopMode),
    );
  }

  List<IndexedAudioSource>? get effectiveSequence =>
      _player.sequenceState?.effectiveSequence;
  double get volume => _player.volume;
  bool get paused => !_player.playing;
  Duration get playbackPosition => _player.position;
}

double? getEffectiveGainChange(
    MediaItem currentTrack, jellyfin_models.BaseItemDto? item) {
  final baseItem = item ??
      jellyfin_models.BaseItemDto.fromJson(currentTrack.extras?["itemJson"]);
  double? effectiveGainChange;
  switch (FinampSettingsHelper.finampSettings.volumeNormalizationMode) {
    case VolumeNormalizationMode.hybrid:
      // case VolumeNormalizationMode.albumBased: // we use the context normalization gain for album-based because we don't have the album item here
      // use context normalization gain if available, otherwise use track normalization gain
      effectiveGainChange = currentTrack.extras?["contextNormalizationGain"] ??
          baseItem.normalizationGain;
      break;
    case VolumeNormalizationMode.trackBased:
      // only ever use track normalization gain
      effectiveGainChange = baseItem.normalizationGain;
      break;
    case VolumeNormalizationMode.albumOnly:
      // only ever use context normalization gain, don't normalize tracks out of special contexts
      effectiveGainChange = currentTrack.extras?["contextNormalizationGain"];
      break;
  }
  return effectiveGainChange;
}

AudioServiceRepeatMode _audioServiceRepeatMode(LoopMode loopMode) {
  switch (loopMode) {
    case LoopMode.off:
      return AudioServiceRepeatMode.none;
    case LoopMode.one:
      return AudioServiceRepeatMode.one;
    case LoopMode.all:
      return AudioServiceRepeatMode.all;
  }
}
