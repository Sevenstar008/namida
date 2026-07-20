import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:basic_audio_handler/basic_audio_handler.dart';
import 'package:http_cache_stream/http_cache_stream.dart';
import 'package:just_audio/just_audio.dart';
import 'package:playlist_manager/module/playlist_id.dart';
import 'package:windows_taskbar/windows_taskbar.dart';

import 'package:namida/class/audio_cache_detail.dart';
import 'package:namida/class/custom_mpv_player.dart';
import 'package:namida/class/file_parts.dart';
import 'package:namida/class/func_execute_limiter.dart';
import 'package:namida/class/replay_gain_data.dart';
import 'package:namida/class/track.dart';
import 'package:namida/class/video.dart';
import 'package:namida/controller/audio_cache_controller.dart';
import 'package:namida/controller/connectivity.dart';
import 'package:namida/controller/current_color.dart';
import 'package:namida/controller/history_controller.dart';
import 'package:namida/controller/home_widget_controller.dart';
import 'package:namida/controller/indexer_controller.dart';
import 'package:namida/controller/logs_controller.dart';
import 'package:namida/controller/lyrics_controller.dart';
import 'package:namida/controller/miniplayer_controller.dart';
import 'package:namida/controller/navigator_controller.dart';
import 'package:namida/controller/platform/permission_manager/permission_manager.dart';
import 'package:namida/controller/platform/tray_manager/tray_manager.dart';
import 'package:namida/controller/player_controller.dart';
import 'package:namida/controller/playlist_controller.dart';
import 'package:namida/controller/queue_controller.dart';
import 'package:namida/controller/settings_controller.dart';
import 'package:namida/controller/smtc_controller.dart';
import 'package:namida/controller/thumbnail_manager.dart';
import 'package:namida/controller/tray_controller.dart';
import 'package:namida/controller/vibrator_controller.dart';
import 'package:namida/controller/video_controller.dart';
import 'package:namida/controller/wakelock_controller.dart';
import 'package:namida/controller/waveform_controller.dart';
import 'package:namida/core/constants.dart';
import 'package:namida/core/enums.dart';
import 'package:namida/core/extensions.dart';
import 'package:namida/core/namida_converter_ext.dart';
import 'package:namida/core/translations/language.dart';
import 'package:namida/core/utils.dart';
import 'package:namida/main.dart';
import 'package:namida/ui/dialogs/common_dialogs.dart';

class NamidaAudioVideoHandler<Q extends Playable> extends BasicAudioHandler<Q> {
  @override
  bool getLoudnessEnhancerEnabledTrackValue() => settings.player.replayGainType.value.isLoudnessEnhancerEnabled;
  @override
  bool getLoudnessEnhancerEnabledTrackValueR() => settings.player.replayGainType.valueR.isLoudnessEnhancerEnabled;

  QueueSourceBase<Enum> latestQueueSource = QueueSource.others(null);

  bool get _willPlayWhenReady => playWhenReady.value;

  RxBaseCore<Duration?> get currentItemDuration => _currentItemDuration;
  final _currentItemDuration = Rxn<Duration>();

  @override
  AudioLoadConfiguration? get defaultAndroidLoadConfig {
    return AudioLoadConfiguration(
      androidLoadControl: AndroidLoadControl(
        minBufferDuration: const Duration(seconds: 5),
        maxBufferDuration: const Duration(minutes: 3),
        bufferForPlaybackAfterRebufferDuration: const Duration(seconds: 5),
        prioritizeTimeOverSizeThresholds: true,
      ),
    );
  }

  NamidaAudioVideoHandler() {
    AudioCacheController.inst.updateAudioCacheMap();
    playWhenReady.addListener(() {
      final ye = playWhenReady.value;
      CurrentColor.inst.switchColorPalettes(playWhenReady: ye);
      WakelockController.inst.updatePlayPauseStatus(ye);
      _refreshPlatformStatusDependersIsPlaying(ye);
    });

    settings.player.repeatMode.addListener(resetGaplessPlaybackData);

    final smtc = SMTCController.instance;
    if (smtc != null) {
      void listener() {
        final positionMS = currentPositionMS.value;
        final durationMS = currentItemDuration.value?.inMilliseconds;
        smtc.updateTimeline(positionMS, durationMS);
      }

      currentPositionMS.addListener(listener);
      currentItemDuration.addListener(listener);
    }

    if (Platform.isWindows) {
      WindowsTaskbar.setProgressMode(TaskbarProgressMode.noProgress).ignoreError();
      const int staleProgressValue = -1;
      int latestProgress = staleProgressValue;
      void taskbarListener() {
        final durationMS = currentItemDuration.value?.inMilliseconds;
        if (durationMS != null && durationMS > 0) {
          final positionMS = currentPositionMS.value;
          final progress = (positionMS / durationMS * 100).floor().clampInt(0, 100);
          if (progress != latestProgress) {
            latestProgress = progress;
            WindowsTaskbar.setProgress(progress, 100).ignoreError();
          }
        } else {
          if (latestProgress != staleProgressValue) {
            latestProgress = staleProgressValue;
            WindowsTaskbar.setProgressMode(TaskbarProgressMode.noProgress).ignoreError();
          }
        }
      }

      currentPositionMS.addListener(taskbarListener);
      currentItemDuration.addListener(taskbarListener);
    }

    _refreshWindowsTaskbar(playWhenReady.value, null);
    _refreshTrayService(playWhenReady.value, null);
  }

  // final currentVideoThumbnail = Rxn<File>();
  final currentCachedVideo = Rxn<NamidaVideo>();
  final currentCachedAudio = Rxn<AudioCacheDetails>();

  final isFetchingInfo = false.obs;

  bool get isCurrentAudioFromCache => _isCurrentAudioFromCache;
  bool _isCurrentAudioFromCache = false;

  VideoSourceOptions? _latestVideoOptions;

  @override
  Future<Map<String, int>> prepareTotalListenTime() async {
    try {
      final file = await File(AppPaths.TOTAL_LISTEN_TIME).create();
      final map = await file.readAsJson();
      return (map as Map<String, dynamic>).cast();
    } catch (_) {
      return {};
    }
  }

  Future<void> _updateTrackLastPosition(Track track, int lastPositionMS) async {
    int dur = track.durationMS;
    if (dur <= 0) dur = currentItemDuration.value?.inMilliseconds ?? 0;

    if (dur > 0) {
      // -- save a starting position in case the remaining was less than 30 seconds.
      final remaining = dur - lastPositionMS;
      lastPositionMS = remaining <= 30000 ? 0 : lastPositionMS;
    }

    await Indexer.inst.updateTrackStats(track, lastPositionInMs: lastPositionMS);
  }

  FutureOr<String?> _getItemAudioTrackId(Q item) async {
    return item.executeAsync(
      selectable: (finalItem) {
        final track = finalItem.track.toTrackExt();
        return track.statsRaw?.audioTrackId;
      },
    );
  }

  FutureOr<Duration?> _getItemInitialPosition(Q item, Duration? itemDuration) async {
    final minValueInSetMinutes = settings.player.minTrackDurationToRestoreLastPosInMinutes.value;

    if (minValueInSetMinutes >= 0) {
      final minValueInSetMS = minValueInSetMinutes * 60 * 1000;
      final seekValueInMS = settings.player.seekDurationInSeconds.value * 1000;

      final lastPosAndDurationMSFn = item.executeAsync(
        selectable: (finalItem) {
          final track = finalItem.track.toTrackExt();
          final duration = itemDuration?.inMilliseconds ?? track.durationMS;
          return (track.statsRaw?.lastPositionInMs, duration);
        },
      );

      final lastPosAndDurationMS = lastPosAndDurationMSFn is Future ? await lastPosAndDurationMSFn : lastPosAndDurationMSFn;
      if (lastPosAndDurationMS != null) {
        final lastPosMS = lastPosAndDurationMS.$1;
        final durationMS = lastPosAndDurationMS.$2;
        // -- only seek if not at the start of track.
        if (lastPosMS != null && durationMS != null && lastPosMS >= seekValueInMS) {
          if (durationMS >= minValueInSetMS) {
            return lastPosMS.milliseconds;
          }
        }
      }
    }
    return null;
  }

  // =================================================================================
  //

  //
  // =================================================================================
  // ================================ Player methods =================================
  // =================================================================================

  void refreshNotification([Q? item]) {
    Q? exectuteOn = item ?? currentItem.value;
    Duration? knownDur;
    if (item != null) {
      exectuteOn = item;
    } else {
      exectuteOn = currentItem.value;
      knownDur = currentItemDuration.value;
    }
    exectuteOn?.execute(
      selectable: (finalItem) {
        _notificationUpdateItemSelectable(
          item: finalItem,
          isItemFavourite: finalItem.track.isFavourite,
          itemIndex: currentIndex.value,
          duration: knownDur,
        );
      },
    );
  }

  void _notificationUpdateItemSelectable({
    required Selectable item,
    required bool isItemFavourite,
    required int itemIndex,
    required Duration? duration,
  }) async {
    final media = await item.toMediaItem(currentIndex.value, currentQueue.value.length, duration);
    mediaItem.add(media);
    playbackState.add(transformEvent(PlaybackEvent(currentIndex: currentIndex.value), isItemFavourite, itemIndex));

    _refreshPlatformStatusDependers(media, playWhenReady.value, isItemFavourite);
  }

  void _refreshPlatformStatusDependersIsPlaying(bool isPlaying) {
    SMTCController.instance?.onPlayPause(isPlaying);
    HomeWidgetController.instance?.updateIsPlaying(isPlaying);
    _refreshWindowsTaskbar(isPlaying, null);
    _refreshTrayService(isPlaying, null);
  }

  void _refreshPlatformStatusDependers(MediaItem media, bool isPlaying, bool isFavourite) {
    SMTCController.instance?.updateMetadata(media);
    HomeWidgetController.instance?.updateAll(
      media.displayTitle ?? media.title,
      media.displaySubtitle ?? media.artist ?? media.album,
      media.artUri,
      isPlaying,
      isFavourite,
    );
    _refreshWindowsTaskbar(isPlaying, isFavourite);
    _refreshTrayService(isPlaying, isFavourite);
  }

  void _refreshWindowsTaskbar(bool isPlaying, bool? isFavourite) async {
    if (Platform.isWindows) {
      final trayIcons = TrayIcons.windows;
      ThumbnailToolbarAssetIcon getIco(String path) => ThumbnailToolbarAssetIcon(path);

      isFavourite ??= currentItem.value?.execute(selectable: (finalItem) => finalItem.track.isFavourite);
      void onFavOrUnfavPress() {
        final current = currentItem.value;
        if (current != null) {
          onNotificationFavouriteButtonPressed(current);
        }
      }

      final repeat = settings.player.repeatMode.value;
      final repeatText = repeat.buildText();
      final repeatIco = trayIcons.forRepeatMode(repeat);

      void onRepeatPress() {
        final e = settings.player.repeatMode.value.nextElement(PlayerRepeatMode.values);
        settings.player.save(repeatMode: e);
        _refreshWindowsTaskbar(_willPlayWhenReady, null);
      }

      try {
        String? title = mediaItem.value?.displayTitle ?? mediaItem.value?.title;
        if (title == null || title.isEmpty) {
          title = 'Namida';
        } else {
          title = '$title • Namida';
        }
        await Future.wait([
          WindowsTaskbar.setWindowTitle(title).ignoreError(),
          if (currentItem.value != null) // idk it just breaks if set after disposing
            WindowsTaskbar.setThumbnailToolbar(
              [
                if (isFavourite == true)
                  ThumbnailToolbarButton(
                    getIco(trayIcons.favorited),
                    lang.removeFromFavourites,
                    onFavOrUnfavPress,
                  )
                else if (isFavourite == false)
                  ThumbnailToolbarButton(
                    getIco(trayIcons.favorite),
                    lang.addToFavourites,
                    onFavOrUnfavPress,
                  ),
                ThumbnailToolbarButton(
                  getIco(repeatIco),
                  repeatText,
                  onRepeatPress,
                ),
                ThumbnailToolbarButton(
                  getIco(trayIcons.previous),
                  lang.previous,
                  Player.inst.previous,
                ),
                isPlaying
                    ? ThumbnailToolbarButton(
                        getIco(trayIcons.pause),
                        lang.pause,
                        Player.inst.pause,
                      )
                    : ThumbnailToolbarButton(
                        getIco(trayIcons.play),
                        lang.play,
                        Player.inst.play,
                      ),
                ThumbnailToolbarButton(
                  getIco(trayIcons.next),
                  lang.next,
                  Player.inst.next,
                ),
                ThumbnailToolbarButton(
                  getIco(trayIcons.stop),
                  lang.stop,
                  () => Player.inst.pause().whenComplete(Player.inst.dispose),
                  mode: ThumbnailToolbarButtonMode.dismissionClick,
                ),
              ],
            ).ignoreError(),
        ]);
      } catch (_) {}
    }
  }

  void _refreshTrayService(bool isPlaying, bool? isFavourite) async {
    final tc = TrayController.instance;
    if (tc != null) {
      final trayIcons = TrayIcons.instance;

      isFavourite ??= currentItem.value?.execute(selectable: (finalItem) => finalItem.track.isFavourite);

      String title = mediaItem.value?.displayTitle ?? mediaItem.value?.title ?? 'Chilling...';
      if (title.length > 48) {
        title = '${title.substring(0, 48)}...';
      }
      final menu = TrayMenu(
        items: [
          TrayMenuItem(
            key: TrayMenuKey.nowPlaying,
            icon: trayIcons?.icStatMusicnote,
            label: title,
            disabled: true,
          ),
          TrayMenuItem.separator(),
          TrayMenuItem(
            key: TrayMenuKey.previous,
            icon: trayIcons?.previous,
            label: lang.previous,
          ),
          TrayMenuItem(
            key: TrayMenuKey.playPause,
            label: isPlaying ? lang.pause : lang.play,
            icon: isPlaying ? trayIcons?.pause : trayIcons?.play,
          ),
          TrayMenuItem(
            key: TrayMenuKey.next,
            icon: trayIcons?.next,
            label: lang.next,
          ),
          TrayMenuItem.separator(),
          TrayMenuItem(
            key: TrayMenuKey.showWindow,
            icon: trayIcons?.showWindow,
            label: lang.open,
          ),
          TrayMenuItem.separator(),
          TrayMenuItem(
            key: TrayMenuKey.exit,
            icon: trayIcons?.stop,
            label: lang.exit,
          ),
        ],
      );
      tc.update(menu, title);
    }
  }

  // =================================================================================
  //

  //
  // ==============================================================================================
  // ==============================================================================================
  // ================================== QueueManager Overriden ====================================

  @override
  Object identifyBy(Q element) {
    return element.execute(
          selectable: (finalItem) => finalItem.track.path,
        ) ??
        '';
  }

  @override
  void onIndexChanged(int newIndex, Q newItem) {
    refreshNotification(newItem);
    settings.extra.save(lastPlayedIndex: newIndex);
    newItem.execute(
      selectable: (finalItem) {
        CurrentColor.inst.updatePlayerColorFromTrack(finalItem, newIndex);
      },
    );
  }

  @override
  Future<void> onQueueChanged() async {
    await super.onQueueChanged();
    if (currentQueue.value.isEmpty) {
      CurrentColor.inst.resetCurrentPlayingTrack();
      if (MiniPlayerController.inst.isInQueue) MiniPlayerController.inst.snapToMini();
      // await pause();
      await [
        onDispose(),
        QueueController.inst.emptyLatestQueue(),
      ].execute();
    } else {
      refreshNotification(currentItem.value);
      await QueueController.inst.updateLatestQueue(currentQueue.value, source: latestQueueSource);
    }
  }

  @override
  Future<void> onReorderItems(int currentIndex, Q itemDragged) async {
    super.onReorderItems(currentIndex, itemDragged);
    itemDragged.execute(
      selectable: (finalItem) => CurrentColor.inst.updatePlayerColorFromTrack(null, currentIndex, updateIndexOnly: true),
    );
  }

  @override
  FutureOr<void> beforeQueueAddOrInsert(Iterable<Q> items) async {
    if (settings.mixedQueue.value) return;
    if (currentQueue.value.isEmpty) return;

    final current = currentItem.value;
    final newItem = items.firstOrNull;

    final wasPlayWhenReady = playWhenReady.value;
    if (newItem is Selectable && current is! Selectable) {
      await clearQueue();
      await onDispose();
    }
    setPlayWhenReady(wasPlayWhenReady);
  }

  @override
  FutureOr<void> clearQueue() async {
    videoPlayerInfo.value = null;
    Lyrics.inst.resetLyrics();
    WaveformController.inst.resetWaveform();
    CurrentColor.inst.resetCurrentPlayingTrack();
    VideoController.inst.currentVideoConfig.resetAll();

    currentPositionMS.value = 0;
    _currentItemDuration.value = null;

    currentCachedVideo.value = null;
    currentCachedAudio.value = null;
    _isCurrentAudioFromCache = false;
    isFetchingInfo.value = false;
    await super.clearQueue();
  }

  @override
  Future<void>? beforeSkippingToItem() {
    NamidaNavigator.inst.popAllMenus();
    return super.beforeSkippingToItem(); // saving last position & waiting for reorder/removing.
  }

  @override
  Future<void> assignNewQueue<Id>({
    required int playAtIndex,
    required Iterable<Q> queue,
    bool shuffle = false,
    bool startPlaying = true,
    int? maximumItems,
    void Function()? onQueueEmpty,
    void Function()? onIndexAndQueueSame,
    void Function(List<Q> finalizedQueue)? onQueueDifferent,
    void Function(Q currentItem)? onAssigningCurrentItem,
    bool Function(Q? currentItem, Q itemToPlay)? canRestructureQueueOnly,
    void Function()? onRestructuringQueue,
    Id Function(Q currentItem)? duplicateRemover,
  }) async {
    await beforeQueueAddOrInsert(queue);
    setPlayWhenReady(startPlaying);
    await super.assignNewQueue(
      playAtIndex: playAtIndex,
      queue: queue,
      maximumItems: maximumItems,
      shuffle: shuffle,
      onIndexAndQueueSame: onIndexAndQueueSame,
      onQueueDifferent: onQueueDifferent,
      onQueueEmpty: onQueueEmpty,
      onAssigningCurrentItem: onAssigningCurrentItem,
      onRestructuringQueue: () {
        if (playWhenReady.value && !isPlaying.value) play();
        VibratorController.light();
      },
          canRestructureQueueOnly:
              canRestructureQueueOnly ??
              (currentItem, itemToPlay) {
                if (itemToPlay is Selectable && currentItem is Selectable) {
                  return itemToPlay.track.path == currentItem.track.path;
                }
                return false;
              },
      duplicateRemover: duplicateRemover,
    );
  }

  // ==============================================================================================
  //

  //
  // ==============================================================================================
  // ==============================================================================================
  // ================================== NamidaBasicAudioHandler Overriden ====================================

  @override
  InterruptionAction defaultOnInterruption(InterruptionType type) => settings.player.onInterrupted.value[type] ?? InterruptionAction.pause;

  @override
  FutureOr<int> itemToDurationInSeconds(Q item) async {
    return (await item.execute<Future<int?>>(
          selectable: (finalItem) async {
            final dur = finalItem.track.durationMS;
            if (dur > 0) {
              return dur ~/ 1000;
            } else {
              final ap = Player.createTempPlayer();
              try {
                final d = await ap.setSource(
                  ItemPrepareConfig(
                    await finalItem.toAudioSource(0, 1, null, cache: false),
                    index: 0,
                    initialPosition: null,
                    audioTrackId: null,
                    videoOptions: null,
                  ),
                );
                return d?.inSeconds ?? 0;
              } finally {
                ap.stop();
                ap.dispose();
              }
            }
          },
        )) ??
        0;
  }

  @override
  String? itemToTotalListenTimeKey(Q? item) {
    return item?.execute(
      selectable: (_) => LibraryCategory.localTracks,
    );
  }

  @override
  FutureOr<void> onItemMarkedListened(Q item, int listenedSeconds, double listenedPercentage) async {
    await item.execute(
      selectable: (finalItem) async {
        final newTrackWithDate = TrackWithDate(
          dateAdded: currentTimeMS,
          track: finalItem.track,
        );
        await HistoryController.inst.addTracksToHistory([newTrackWithDate]);
      },
    );
  }

  final _fnLimiter = FunctionExecuteLimiter(
    considerRapid: const Duration(milliseconds: 500),
    executeAfter: const Duration(milliseconds: 300),
    considerRapidAfterNExecutions: 3,
  );
  bool? _pausedTemporarily;

  Future<void> _freePlayerTemporarily() async {
    // -- can cause issues, disabled currently.
    // return super.freePlayer();
  }

  @override
  FutureOr<ItemPrepareConfig<Q, UriSource>?> prepareItem(Q item, int index) async {
    return await item.executeAsync(
      selectable: (finalItem) async {
        return _itemToPrepareConfigSelectable(item, finalItem, index, null);
      },
    );
  }

  @override
  Future<void> onItemPlay(Q item, int index, Function skipItem, ItemPreparedPlayerInfo<Q>? preparedItemInfo) {
    _currentItemDuration.value = null;
    if (!defaultGaplessEnabled) {
      // -- this was added to prevent multiple skips when spamming play/pause at the end of playback
      // -- but it's not needed for gapless, otherwise the state will stay stuck at this value
      currentState.value = null;
    }

    // -- should be done here so that if info fetching takes time, crossfade out still works.
    // -- otherwise the previous item would keep playing indefinetly.
    beginEarlyCrossFadeOutIfRequired();
    if (settings.enablePartyModeColorSwap.value) CurrentColor.inst.switchColorPalettes(item: item);
    return _fnLimiter.executeFuture(
      () async {
        return await item.execute(
          selectable: (finalItem) async {
            final twd = finalItem.trackWithDate;
            if (twd != null) {
              final qs = twd.queueSource;
              if (qs != null && qs.supportResuming) {
                QueueController.latestPlayedForSourceManager.update(qs, finalItem);
              }
            }

            await onItemPlaySelectable(item, finalItem, index, skipItem, preparedItemInfo: preparedItemInfo);
          },
        );
      },
      onRapidDetected: () {
        if (playWhenReady.value) {
          _pausedTemporarily = true;
          pause();
        }
      },
      onReExecute: () {
        if (_pausedTemporarily == true) {
          _pausedTemporarily = null;
          play();
        }
      },
    );
  }

  Timer? _playErrorSkipTimer;
  final playErrorRemainingSecondsToSkip = 0.obs;
  void cancelPlayErrorSkipTimer() {
    _playErrorSkipTimer?.cancel();
    _playErrorSkipTimer = null;
    playErrorRemainingSecondsToSkip.value = 0;
  }

  Future<ItemPrepareConfigSelectable<Q, UriSource>> _itemToPrepareConfigSelectable(
    Q pi,
    Selectable item,
    int index,
    Duration? duration, {
    CurrentVideoConfig? configToUpdate,
  }) async {
    final isVideo = item is Video;
    final tr = item.track;
    duration ??= Duration(milliseconds: tr.durationMS);
    configToUpdate ??= CurrentVideoConfig();
    final initialVideo = await VideoController.inst.updateCurrentVideo(tr, returnEarly: true, configToUpdate: configToUpdate);
    final videoOptions = !settings.enableVideoPlayback.value
        ? null
        : initialVideo == null
        ? isVideo
              ? VideoSourceOptions(
                  source: await item.toAudioSource(currentIndex.value, currentQueue.value.length, duration),
                  loop: false,
                  videoOnly: true,
                )
              : null
        : VideoSourceOptions(
            source: AudioVideoSource.file(initialVideo.path),
            loop: VideoController.inst.canLoopVideo(initialVideo, duration.inMilliseconds),
            videoOnly: isVideo,
          );
    return ItemPrepareConfigSelectable(
      await tr.toAudioSource(currentIndex.value, currentQueue.value.length, duration),
      itemExists: await tr.exists(),
      item: pi,
      videoOptions: videoOptions,
      index: index,
      initialPosition: await _getItemInitialPosition(pi, duration),
      audioTrackId: await _getItemAudioTrackId(pi),
      videoUpdateConfig: configToUpdate,
    );
  }

  Future<void> onItemPlaySelectable(
    Q pi,
    Selectable item,
    int index,
    Function skipItem, {
    required ItemPreparedPlayerInfo<Q>? preparedItemInfo,
  }) async {
    final tr = item.track;
    videoPlayerInfo.value = null;
    Lyrics.inst.resetLyrics();
    WaveformController.inst.resetWaveform();
    VideoController.inst.currentVideoConfig.resetAll();

    if (tr.isPhysical) {
      WaveformController.inst.generateWaveform(
        path: tr.path,
        duration: Duration(milliseconds: tr.durationMS),
        stillPlaying: (path) {
          final current = currentItem.value;
          return current is Selectable && path == current.track.path;
        },
      );
    }
    Lyrics.inst.updateLyrics(tr).ignoreError();

    Duration? duration = tr.durationMS.milliseconds;
    bool checkInterrupted() {
      if (item != currentItem.value) {
        return true;
      } else {
        if (duration != null) _currentItemDuration.value = duration;
        return false;
      }
    }

    if (tr.path.startsWith('/namida_dummy/')) return;
    if (checkInterrupted()) return; // -- refresh duration

    // -- generating artwork in case it wasnt, to be displayed in notification
    File(tr.pathToImage).exists().then((exists) {
      // -- we check if it exists to avoid refreshing notification redundently.
      // -- otherwise `getArtwork` already handles duplications.
      if (!exists) {
        Indexer.inst.getArtwork(imagePath: tr.pathToImage, track: tr, compressed: false, checkFileFirst: false).then((value) => refreshNotification());
      }
    });

    // -- hmm marking local tracks as yt-watched..?
    // final trackYoutubeId = tr.youtubeID;
    // if (trackYoutubeId.isNotEmpty) {
    //   YoutubeInfoController.history.markVideoWatched(videoId: trackYoutubeId, streamResult: null, errorOnMissingParam: false);
    // }

    ItemPrepareConfig<Q, UriSource>? preparedConfig = preparedItemInfo?.config;

    if (preparedConfig is ItemPrepareConfigSelectable<Q, UriSource>) {
      VideoController.inst.currentVideoConfig.updateFrom(preparedConfig.videoUpdateConfig);
    }
    Future<Duration?> setPls() async {
      bool itemReallyExists = preparedConfig?.itemExists == true ? true : tr.existsSync();
      if (!itemReallyExists) throw PathNotFoundException(tr.path, const OSError(), 'Track file not found or couldn\'t be accessed.');

      if (preparedConfig == null || preparedConfig!.item != item) {
        // -- creating new config
        preparedConfig = await _itemToPrepareConfigSelectable(pi, item, index, duration, configToUpdate: VideoController.inst.currentVideoConfig);
      } else {
        // -- using already prepared config
      }
      final config = preparedConfig!;
      final dur = await setSource(
        config.source,
        index: index,
        item: config.item,
        videoOptions: config.videoOptions,
        initialPosition: config.initialPosition,
        audioTrackId: config.audioTrackId,
        initialPositionFallback: (duration) => _getItemInitialPosition(pi, duration),
        isVideoFile: true,
      );

      if (dur != null) Indexer.inst.updateTrackDuration(tr, dur);

      refreshNotification(currentItem.value);
      return dur;
    }

    try {
      duration = await setPls();
    } catch (e, st) {
      if (checkInterrupted()) return;
      final reallyError = !(duration != null && currentPositionMS.value > 0);
      if (reallyError) {
        printy(e, isError: true);
        // -- playing music from root folders still require `all_file_access`
        // -- this is a fix for not playing some external files reported by some users.
        final hadPermissionBefore = await PermissionManager.platform.hasManageExternalStoragePermission();
        if (checkInterrupted()) return;
        if (hadPermissionBefore) {
          onPauseRaw();
          cancelPlayErrorSkipTimer();
          playErrorRemainingSecondsToSkip.value = 7;

          _playErrorSkipTimer = Timer.periodic(
            const Duration(seconds: 1),
            (timer) {
              playErrorRemainingSecondsToSkip.value--;
              if (playErrorRemainingSecondsToSkip.value <= 0) {
                NamidaNavigator.inst.closeDialog();
                if (currentQueue.value.length > 1) skipItem();
                timer.cancel();
              }
            },
          );
          NamidaDialogs.inst.showTrackDialog(
            tr,
            errorPlayingTrack: e,
            source: QueueSource.playerQueue,
          );
          logger.error('Error playing file', e: e, st: st);
          return;
        } else {
          final hasPermission = await requestManageStoragePermission();
          if (!hasPermission) return;
          if (checkInterrupted()) return;
          try {
            duration = await setPls();
          } catch (_) {}
        }
      }
    }

    if (checkInterrupted()) return;

    final replayGainType = settings.player.replayGainType.value;
    if (replayGainType.isAnyEnabled) {
      final gainData = item.track.toTrackExt().gainData;
      if (replayGainType.isLoudnessEnhancerEnabled) {
        final gainToUse = gainData?.gainToUse;
        if (gainToUse != null) await loudnessEnhancerExtended?.setTargetGainTrack(gainToUse);
      } else if (replayGainType.isVolumeEnabled) {
        final vol = gainData?.calculateGainAsVolume();
        replayGainLinearVolumeMultiplierRx.value = vol ?? ReplayGainData.kDefaultFallbackVolume; // save in memory only
      }
    }

    if (preparedConfig?.videoOptions == null) VideoController.inst.updateCurrentVideo(tr, returnEarly: false);

    // -- to fix a bug where [headset buttons/android next gesture] sometimes don't get detected.
    if (playWhenReady.value) onPlayRaw(attemptFixVolume: false);

    startCounterToAListen(pi);
  }

  @override
  FutureOr<void> ensureReplayGainVolumeUpdated(Playable? item) {
    final replayGainType = settings.player.replayGainType.value;
    if (replayGainType.isAnyEnabled) {
      return item?.execute<FutureOr<void>>(
        selectable: (finalItem) {
          final gainData = finalItem.track.toTrackExt().gainData;
          if (replayGainType.isLoudnessEnhancerEnabled) {
            final gainToUse = gainData?.gainToUse;
            if (gainToUse != null) return loudnessEnhancerExtended?.setTargetGainTrack(gainToUse);
          } else if (replayGainType.isVolumeEnabled) {
            final vol = gainData?.calculateGainAsVolume();
            replayGainLinearVolumeMultiplierRx.value = vol ?? ReplayGainData.kDefaultFallbackVolume; // save in memory only
          }
          return null;
        },
      );
    }
  }

  @override
  FutureOr<PlayerConfig?> getPlayerConfigForItem(Playable? item, AVPlayer player) {
    final isPerTrackAudioConfigOverriden = settings.player.isPerTrackAudioConfigOverriden.value;
    if (isPerTrackAudioConfigOverriden) return null;

    final key = item?.key;
    if (key == null) return null;

    return Player.audioConfigs.get(key);
  }

  @override
  void onNotificationFavouriteButtonPressed(Q item) {
    item.execute(
      selectable: (finalItem) {
        final newStat = PlaylistController.inst.favouriteButtonOnPressed(finalItem.track, refreshNotification: false);
        _notificationUpdateItemSelectable(
          item: finalItem,
          itemIndex: currentIndex.value,
          isItemFavourite: newStat,
          duration: currentItemDuration.value,
        );
      },
    );
  }

  @override
  void onRepeatModeChange(PlayerRepeatMode repeatMode) {
    settings.player.save(repeatMode: repeatMode);
  }

  @override
  void onTotalListenTimeIncrease(Map<String, int> totalTimeInSeconds, String key) {
    final newSeconds = totalTimeInSeconds[key] ?? 0;

    // saves the file each 20 seconds.
    if (newSeconds % 20 == 0) {
      File(AppPaths.TOTAL_LISTEN_TIME).writeAsJson(totalTimeInSeconds);
    }
  }

  @override
  void onItemLastPositionReport(Q? currentItem, int currentPositionMs) async {
    await currentItem?.execute(
      selectable: (finalItem) => _updateTrackLastPosition(finalItem.track, currentPositionMs),
    );
  }

  @override
  void onPlaybackEventStream(PlaybackEvent event) {
    final item = currentItem.value;
    item?.execute(
      selectable: (finalItem) async {
        final isFav = finalItem.track.isFavourite;
        playbackState.add(transformEvent(event, isFav, currentIndex.value));
      },
    );
  }

  @override
  Future<void> onPlaybackCompleted() {
    VideoController.inst.videoControlsKey.currentState?.showControlsBriefly();
    VideoController.inst.videoControlsKeyFullScreen.currentState?.showControlsBriefly();
    return super.onPlaybackCompleted();
  }

  @override
  Future<void> setSkipSilenceEnabled(bool enabled) async {
    if (getDefaultPlayerConfig(currentItem.value).skipSilence) await super.setSkipSilenceEnabled(enabled);
  }

  @override
  PlayerConfig getDefaultPlayerConfig(Q? item) => PlayerConfig(
    skipSilence: settings.player.skipSilenceEnabled.value,
    loudnessEnhancerEnabled: settings.equalizer.loudnessEnhancerEnabled.value,
    loudnessEnhancer: settings.equalizer.loudnessEnhancer.value,
    equalizerEnabled: settings.equalizer.equalizerEnabled.value,
    equalizer: settings.equalizer.equalizer.value,
    preset: settings.equalizer.preset.value,
    speed: settings.player.speed.value,
    volume: settings.player.volume.value,
    pitch: settings.player.pitch.value,
  );

  PlayerConfig getDefaultPlayerConfigR(Q? item) => PlayerConfig(
    skipSilence: settings.player.skipSilenceEnabled.valueR,
    loudnessEnhancerEnabled: settings.equalizer.loudnessEnhancerEnabled.valueR,
    loudnessEnhancer: settings.equalizer.loudnessEnhancer.valueR,
    equalizerEnabled: settings.equalizer.equalizerEnabled.valueR,
    equalizer: settings.equalizer.equalizer.valueR,
    preset: settings.equalizer.preset.valueR,
    speed: settings.player.speed.valueR,
    volume: settings.player.volume.valueR,
    pitch: settings.player.pitch.valueR,
  );

  @override
  double get replayGainLinearVolumeMultiplierValue => replayGainLinearVolumeMultiplierRx.value;

  final replayGainLinearVolumeMultiplierRx = 1.0.obs;

  @override
  bool get enableCrossFade => settings.player.enableCrossFade.value;

  @override
  bool get defaultGaplessEnabled => settings.player.enableGaplessPlayback.value;

  @override
  int get defaultCrossFadeMilliseconds => settings.player.crossFadeDurationMS.value;

  @override
  int get defaultCrossFadeTriggerStartOffsetSeconds => settings.player.crossFadeAutoTriggerSeconds.value;

  @override
  bool get displayFavouriteButtonInNotification => settings.displayFavouriteButtonInNotification.value;

  @override
  bool get displayStopButtonInNotification => settings.displayStopButtonInNotification.value;

  @override
  bool get defaultShouldStartPlayingOnNextPrev => settings.player.playOnNextPrev.value;

  @override
  bool get enableVolumeFadeOnPlayPause => settings.player.enableVolumeFadeOnPlayPause.value;

  @override
  bool get playerInfiniyQueueOnNextPrevious => settings.player.infiniyQueueOnNextPrevious.value;

  @override
  int get playerPauseFadeDurInMilli => settings.player.pauseFadeDurInMilli.value;

  @override
  int get playerPlayFadeDurInMilli => settings.player.playFadeDurInMilli.value;

  @override
  bool get playerPauseOnVolume0 => settings.player.pauseOnVolume0.value;

  @override
  PlayerRepeatMode get playerRepeatMode => settings.player.repeatMode.value;

  @override
  bool get jumpToFirstItemAfterFinishingQueue => settings.player.jumpToFirstTrackAfterFinishingQueue.value;

  @override
  int get listenCounterMarkPlayedPercentage => settings.isTrackPlayedPercentageCount.value;

  @override
  int get listenCounterMarkPlayedSeconds => settings.isTrackPlayedSecondsCount.value;

  @override
  int get maximumSleepTimerMins => kMaximumSleepTimerMins;

  @override
  int get maximumSleepTimerItems => kMaximumSleepTimerTracks;

  @override
  InterruptionAction get onBecomingNoisyEventStream => InterruptionAction.pause;

  @override
  Duration get defaultInterruptionResumeThreshold => Duration(minutes: settings.player.interruptionResumeThresholdMin.value);

  @override
  Duration get defaultVolume0ResumeThreshold => Duration(minutes: settings.player.volume0ResumeThresholdMin.value);

  @override
  Duration get defaultConnectWiredResumeThresholdMin => Duration(minutes: settings.player.connectWiredResumeThresholdMin.value);

  @override
  Duration get defaultConnectWirelessResumeThresholdMin => Duration(minutes: settings.player.connectWirelessResumeThresholdMin.value);

  bool get previousButtonReplays => settings.previousButtonReplays.value;

  // ------------------------------------------------------------

  Future<void> togglePlayPause() {
    if (playWhenReady.value) {
      return pause();
    } else {
      return play();
    }
  }

  @override
  Future<void> seek(Duration position) async {
    Future<void> plsSeek() => super.seek(position);

    await plsSeek();
  }

  @override
  Future<void> skipToPrevious({bool isManualSkip = true}) async {
    if (previousButtonReplays) {
      final int secondsToReplay;
      if (settings.player.isSeekDurationPercentage.value) {
        final sFromP = (currentItemDuration.value?.inSeconds ?? 0) * (settings.player.seekDurationInPercentage.value / 100);
        secondsToReplay = sFromP.toInt();
      } else {
        secondsToReplay = settings.player.seekDurationInSeconds.value;
      }

      if (secondsToReplay > 0 && currentPositionMS.value > secondsToReplay * 1000) {
        await seek(Duration.zero);
        return;
      }
    }

    await super.skipToPrevious();
  }

  @override
  Future<void> onDispose() async {
    mediaItem.add(null);
    await [
      super.onDispose(),
      if (Platform.isAndroid) AudioService.forceStop(),
    ].execute();
    SMTCController.instance?.onStop();
    _refreshWindowsTaskbar(false, null);
    _refreshTrayService(false, null);
  }

  Timer? _headsetButtonClickTimer;
  int _headsetClicksCount = 0;

  Timer _createHeadsetClicksTimer(void Function() callback) {
    return Timer(Duration(milliseconds: 250), () {
      callback();

      // -- reset timer
      _headsetButtonClickTimer?.cancel();
      _headsetButtonClickTimer = null;
      _headsetClicksCount = 0;
    });
  }

  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    if (button == MediaButton.next) {
      skipToNext();
      return;
    } else if (button == MediaButton.previous) {
      skipToPrevious();
      return;
    }

    _headsetClicksCount++;

    _headsetButtonClickTimer?.cancel();

    if (_headsetClicksCount == 1) {
      _headsetButtonClickTimer = _createHeadsetClicksTimer(_willPlayWhenReady ? pause : play);
    } else if (_headsetClicksCount == 2) {
      _headsetButtonClickTimer = _createHeadsetClicksTimer(skipToNext);
    } else if (_headsetClicksCount == 3) {
      _headsetButtonClickTimer = _createHeadsetClicksTimer(skipToPrevious);
    }
  }

  @override
  Future<void> fastForward() async => await onFastForward();

  @override
  Future<void> rewind() async => await onRewind();

  Future<Duration?> setSource(
    UriSource source, {
    required Q? item,
    required int index,
    Duration? initialPosition,
    String? audioTrackId,
    FutureOr<Duration?> Function(Duration duration)? initialPositionFallback,
    VideoSourceOptions? videoOptions,
    bool isVideoFile = false,
    String? cachedAudioPath,
    bool keepOldVideoSource = false,
  }) async {
    if (isVideoFile && videoOptions != null) {
      _setLastAccessedForSourceIfFileTry(videoOptions.source);
    }
    if (cachedAudioPath != null) {
      File(cachedAudioPath).setLastAccessedTry(DateTime.now());
    }
    if (!keepOldVideoSource) _latestVideoOptions = videoOptions;
    final duration = await setAudioSource(
      ItemPrepareConfig<Q, UriSource>(
        source,
        item: item,
        index: index,
        initialPosition: initialPosition,
        audioTrackId: audioTrackId,
        videoOptions: videoOptions,
        keepOldVideoSource: keepOldVideoSource,
      ),
    );
    if (initialPosition == null && initialPositionFallback != null && duration != null) {
      final p = await initialPositionFallback(duration);
      if (p != null && p > Duration.zero && p != initialPosition) seek(p);
    }
    return duration;
  }

  @override
  Future<MediaItem> itemToMediaItem(Q item) {
    return item.execute(
      selectable: (finalItem) {
        int durMS = finalItem.track.durationMS;
        return finalItem.toMediaItem(currentIndex.value, currentQueue.value.length, durMS > 0 ? durMS.milliseconds : currentItemDuration.value);
      },
    )!;
  }

  @override
  String itemToMediaItemId(Q item) {
    return item.execute(
      selectable: (finalItem) => finalItem.toMediaItemId(),
    )!;
  }

  // ------- video -------

  Future<void> setVideoSource({required AudioVideoSource source, bool loopingAnimation = false, bool isFile = false, bool videoOnly = false}) async {
    if (isFile) _setLastAccessedForSourceIfFileTry(source);
    final videoOptions = VideoSourceOptions(
      source: source,
      loop: loopingAnimation,
      videoOnly: videoOnly,
    );
    _latestVideoOptions = videoOptions;
    await super.setVideo(videoOptions);
  }

  Future<void> _setLastAccessedForSourceIfFileTry(AudioVideoSource source) async {
    if (source is UriSource && source.uri.isScheme('file')) {
      try {
        final file = File.fromUri(source.uri);
        await file.setLastAccessed(DateTime.now());
      } catch (_) {}
    }
  }

  @override
  MediaControlsProvider get mediaControls => _mediaControls;
  static final _mediaControls = Platform.isAndroid && NamidaFeaturesAvailablity.android13and_plus.resolve()
      ? MediaControlsProvider.android13plus() // can crash on android below 13
      : MediaControlsProvider.main();

  // -- builders

  static AVPlayer createPlayer({
    bool disableVideo = false,
    required AudioPlayer Function() exoplayerCreator,
    required AudioPlayer Function() exoplayerSWCreator,
  }) {
    var pl = settings.player.internalPlayer.value;
    if (pl == InternalPlayerType.auto) {
      pl = InternalPlayerType.platformDefault;
    }
    return switch (pl) {
      InternalPlayerType.auto => CustomMPVPlayer(disableVideo: disableVideo), // shouldn't happen
      InternalPlayerType.exoplayer => CustomAudioPlayer(exoplayerCreator()),
      InternalPlayerType.exoplayer_sw => CustomAudioPlayer(exoplayerSWCreator()),
      InternalPlayerType.mpv => CustomMPVPlayer(disableVideo: disableVideo),
    };
  }

  @override
  AVPlayer createPlayerInstance() {
    return createPlayer(
      exoplayerCreator: () => _createAndroidPlayer(preferSWDecoders: false),
      exoplayerSWCreator: () => _createAndroidPlayer(preferSWDecoders: true),
    );
  }

  AudioPlayer _createAndroidPlayer({required bool preferSWDecoders}) {
    return AudioPlayer(
      androidApplyAudioAttributes: false,
      handleInterruptions: false,
      handleAudioSessionActivation: true,
      audioLoadConfiguration: defaultAndroidLoadConfig,
      audioPipeline: AudioPipeline(
        androidAudioEffects: [
          ?equalizerExtended?.equalizer,
          ?loudnessEnhancerExtended?.loudnessEnhancer,
        ],
      ),
      preferSWDecoders: preferSWDecoders,
    );
  }
}

// ----------------------- Extensions --------------------------
extension TrackToAudioSourceMediaItem on Selectable {
  FutureOr<UriSource> toAudioSource(int currentIndex, int queueLength, Duration? duration, {bool cache = true}) {
    if (track.isNetwork) {
      return _buildTrackNetworkAudioSource(tr: this.track);
    }
    return AudioVideoSource.file(
      track.path,
      // tag: toMediaItem(currentIndex, queueLength, duration),
    );
  }

  String toMediaItemId() => track.path;

  Future<MediaItem> toMediaItem(int currentIndex, int queueLength, Duration? duration) async {
    final tr = track.toTrackExt();
    final artist = tr.originalArtist == '' ? UnknownTags.ARTIST : tr.originalArtist;
    final imagePath = tr.pathToImage;
    String? imagePathToUse = await File(imagePath).exists() ? imagePath : null;
    imagePathToUse ??= Indexer.inst.getFallbackFolderArtworkPath(folder: tr.folder);
    return MediaItem(
      id: this.toMediaItemId(),
      title: tr.title,
      displayTitle: tr.title,
      displaySubtitle: tr.hasUnknownAlbum ? artist : "$artist - ${tr.originalAlbum}",
      displayDescription: "${currentIndex + 1}/$queueLength",
      artist: artist,
      album: tr.hasUnknownAlbum ? '' : tr.originalAlbum,
      genre: tr.originalGenre,
      duration: duration ?? Duration(milliseconds: tr.durationMS),
      artUri: _fileToContentUri(imagePathToUse ?? AppPaths.NAMIDA_LOGO_LAYER),
    );
  }
}

Uri _fileToContentUri(String filePath) {
  if (Platform.isAndroid) {
    try {
      return Uri(
        scheme: 'content',
        host: 'com.msob7y.namida',
        queryParameters: {'path': filePath},
      );
    } catch (_) {
      // -- error in content uri means nothing more than android auto/etc not showing artworks
    }
  }
  return Uri.file(filePath);
}

extension PlayableExecuter on Playable {
  T? execute<T>({
    required T Function(Selectable finalItem) selectable,
  }) {
    final item = this;
    if (item is Selectable) {
      return selectable(item);
    }
    return null;
  }

  FutureOr<T?> executeAsync<T>({
    required FutureOr<T?> Function(Selectable finalItem) selectable,
  }) {
    final item = this;
    if (item is Selectable) {
      return selectable(item);
    }
    return null;
  }
}

UriSource _buildCacheableAVSource(
  Uri uriDDL, {
  required int? size,
  Map<String, String>? headers,
  required File cacheFile,
  required void Function(File cachedFile) onFirstCacheDone,
  required void Function(File cachedFile) onFetched,
}) {
  final cacheConfig = HttpCacheManager.instance.createStreamConfig();
  if (size != null && size > 0) {
    // -- usually required for yt new urls that enforces chunk streaming
    cacheConfig.requestHeaders['Range'] = 'bytes=0-${size - 1}';
  }
  cacheConfig.onCacheDone = onFirstCacheDone;
  final cacheStream = HttpCacheManager.instance.createStream(
    uriDDL,
    file: cacheFile,
    config: cacheConfig,
  );
  cacheStream.download().then(onFetched).ignoreError();
  final cacheUrl = cacheStream.cacheUrl;
  void disposeStream() => cacheStream.dispose(force: true);
  return AudioVideoSource.uri(
    cacheUrl,
    headers: headers,
    onDispose: disposeStream,
  );
}

Future<UriSource> _buildTrackNetworkAudioSource({required Track tr}) async {
  final uri = Uri.parse(tr.path);
  final res = MediaUrlParseResult.parseFromUri(uri);
  final id = res.id;
  if (id == null || id.isEmpty) return AudioVideoSource.file('');

  final cleanPath = id.startsWith('/') ? id.substring(1) : res.id;
  final cacheFile = FileParts.join(AppDirs.APP_CACHE, res.type.name, res.username, cleanPath);

  bool stillPlaying(String path) {
    final current = Player.inst.currentItem.value;
    return current is Selectable && path == current.track.path;
  }

  void onFetched(File cachedFile) async {
    if (stillPlaying(tr.path)) {
      await WaveformController.inst.generateWaveform(
        path: cachedFile.path,
        duration: Duration(milliseconds: tr.durationMS),
        stillPlaying: (_) => stillPlaying(tr.path),
      );
    }
  }

  if (await cacheFile.exists()) {
    if (await cacheFile.fileSize() == tr.size) {
      onFetched(cacheFile);
      return AudioVideoSource.file(cacheFile.path);
    } else {
      await cacheFile.tryDeleting();
    }
  }

  final uriDDLInfo = await MusicWebServer.baseUrlToActualUrl(
    tr.path,
    uri: uri,
    onFetchedIfLocal: onFetched,
  );

  if (uriDDLInfo == null) return AudioVideoSource.file('');

  if (!uriDDLInfo.allowStreamCaching) {
    return AudioVideoSource.uri(uriDDLInfo.uri, headers: uriDDLInfo.headers);
  }

  return _buildCacheableAVSource(
    uriDDLInfo.uri,
    size: null,
    headers: uriDDLInfo.headers,
    cacheFile: cacheFile,
    onFirstCacheDone: (cachedFile) {},
    onFetched: onFetched,
  );
}

class ItemPrepareConfigSelectable<Q, S extends UriSource> extends ItemPrepareConfig<Q, S> {
  final CurrentVideoConfig videoUpdateConfig;
  const ItemPrepareConfigSelectable(
    super.source, {
    required super.index,
    required super.initialPosition,
    required super.videoOptions,
    required super.audioTrackId,
    required this.videoUpdateConfig,
    super.item,
    super.itemExists,
    super.keepOldVideoSource = false,
  });
}

class _NoPreparedConfigException implements Exception {
  final String msg;
  const _NoPreparedConfigException(this.msg);

  @override
  String toString() => msg;
}
