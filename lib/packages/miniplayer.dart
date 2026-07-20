// ignore_for_file: use_build_context_synchronously

import 'dart:io';

import 'package:flutter/material.dart';

import 'package:animated_background/animated_background.dart';

import 'package:namida/class/route.dart';
import 'package:namida/class/track.dart';
import 'package:namida/class/video.dart';
import 'package:namida/controller/connectivity.dart';
import 'package:namida/controller/current_color.dart';
import 'package:namida/controller/lyrics_controller.dart';
import 'package:namida/controller/miniplayer_controller.dart';
import 'package:namida/controller/navigator_controller.dart';
import 'package:namida/controller/player_controller.dart';
import 'package:namida/controller/playlist_controller.dart';
import 'package:namida/controller/settings_controller.dart';
import 'package:namida/controller/video_controller.dart';
import 'package:namida/controller/waveform_controller.dart';
import 'package:namida/core/dimensions.dart';
import 'package:namida/core/enums.dart';
import 'package:namida/core/extensions.dart';
import 'package:namida/core/functions.dart';
import 'package:namida/core/icon_fonts/broken_icons.dart';
import 'package:namida/core/themes.dart';
import 'package:namida/core/translations/language.dart';
import 'package:namida/core/utils.dart';
import 'package:namida/packages/lyrics_lrc_parsed_view.dart';
import 'package:namida/packages/miniplayer_base.dart';
import 'package:namida/ui/dialogs/add_to_playlist_dialog.dart';
import 'package:namida/ui/dialogs/common_dialogs.dart';
import 'package:namida/ui/dialogs/edit_tags_dialog.dart';
import 'package:namida/ui/dialogs/track_info_dialog.dart';
import 'package:namida/ui/widgets/artwork.dart';
import 'package:namida/ui/widgets/custom_widgets.dart';
import 'package:namida/ui/widgets/library/track_tile.dart';

class MiniPlayerParent extends StatelessWidget {
  final AnimationController animation;
  const MiniPlayerParent({super.key, required this.animation});

  @override
  Widget build(BuildContext context) {
    return Obx(
      (context) => Theme(
        data: AppThemes.inst.getAppTheme(CurrentColor.inst.miniplayerColor, !context.isDarkMode),
        child: Stack(
          children: [
            // -- MiniPlayer Wallpaper
            Positioned.fill(
              child: RepaintBoundary(
                child: FadeIgnoreTransition(
                  completelyKillWhenPossible: true,
                  opacity: NamidaMiniPlayerBase.clampedAnimationCP,
                  child: const Wallpaper(
                    gradient: false,
                    particleOpacity: 0.3,
                  ),
                ),
              ),
            ),

            // -- MiniPlayers
            RepaintBoundary(
              child: ObxO(
                rx: Player.inst.currentItem,
                builder: (context, currentItem) => currentItem is Selectable
                    ? const NamidaMiniPlayerTrack(key: Key('local_miniplayer'))
                    : const SizedBox(key: Key('empty_miniplayer')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class NamidaMiniPlayerTrack extends StatelessWidget {
  const NamidaMiniPlayerTrack({super.key});

  static void openMenu(TrackWithDate? trackWithDate, Track track) => NamidaDialogs.inst.showTrackDialog(
        track,
        source: QueueSource.playerQueue,
        heroTag: TrackTile.obtainHeroTag(trackWithDate, track, -1, true),
      );
  static void openInfoMenu(TrackWithDate? trackWithDate, Track track) => showTrackInfoDialog(
        track,
        true,
        heroTag: TrackTile.obtainHeroTag(trackWithDate, track, -1, true),
      );

  static MiniplayerInfoData<Track, SortType> textBuilder(Playable playable) {
    String firstLine = '';
    String secondLine = '';

    final track = (playable as Selectable).track;
    final trExt = track.toTrackExt();
    final title = trExt.title;
    final artist = trExt.originalArtist;
    if (settings.displayArtistBeforeTitle.value) {
      firstLine = artist.overflow;
      secondLine = title.overflow;
    } else {
      firstLine = title.overflow;
      secondLine = artist.overflow;
    }

    if (firstLine == '') {
      firstLine = secondLine;
      secondLine = '';
    }
    return MiniplayerInfoData(
      firstLine: firstLine,
      secondLine: secondLine,
      favouritePlaylist: PlaylistController.inst.favouritesPlaylist,
      itemToLike: track,
      onLikeTap: (isLiked) async => PlaylistController.inst.favouriteButtonOnPressed(track),
      onShowAddToPlaylistDialog: () => showAddToPlaylistDialog([track]),
      onMenuOpen: (_) => openMenu(playable.trackWithDate, track),
      onTextLongTap: () => openInfoMenu(playable.trackWithDate, track),
      likedIcon: Broken.heart_filled,
      normalIcon: Broken.heart,
    );
  }

  NamidaMiniPlayerBase getMiniPlayerBase(BuildContext context) {
    final theme = context.theme;
    final textTheme = theme.textTheme;
    return NamidaMiniPlayerBase<Track, SortType>(
      queueItemExtent: Dimensions.inst.trackTileItemExtent,
      trackTileConfigs: const TrackTilePropertiesConfigs(
        displayRightDragHandler: true,
        draggableThumbnail: true,
        horizontalGestures: false,
        queueSource: QueueSource.playerQueue,
      ),
      itemBuilder: (context, i, currentIndex, queue, properties, _) {
        final track = queue[i] as Selectable;
        final key = Key("${i}_${track.track.path}");
        return (
          TrackTile(
            properties: properties!,
            key: key,
            index: i,
            trackOrTwd: track,
            tracks: queue,
            cardColorOpacity: 0.5,
            fadeOpacity: i < currentIndex ? 0.3 : 0.0,
            onPlaying: () {
              // -- to improve performance, skipping process of checking new queues, etc..
              if (i == currentIndex) {
                Player.inst.togglePlayPause();
              } else {
                Player.inst.skipToQueueItem(i);
              }
            },
          ),
          key,
        );
      },
      getDurationMS: (currentItem) => (currentItem as Selectable).track.durationMS,
      itemsKeyword: (number, item) => number.displayTrackKeyword,
      onAddItemsTap: (currentItem) => TracksAddOnTap().onAddTracksTap(context),
      topText: (currentItem) => (currentItem as Selectable).track.originalAlbum,
      onTopTextTap: (currentItem) => NamidaOnTaps.inst.onAlbumTap((currentItem as Selectable).track.albumsIdentifiersModified.firstOrNull),
      onMenuOpen: (currentItem, _) => openMenu((currentItem as Selectable).trackWithDate, currentItem.track),
      focusedMenuOptions: (currentItem) => FocusedMenuOptions(
        onSearch: (item) {
          final tr = (item as Selectable).track;
          showSetYTLinkCommentDialog(tr, CurrentColor.inst.miniplayerColor, autoOpenSearch: true);
        },
        onPressed: (currentItem) => VideoController.inst.toggleVideoPlayback(),
        videoIconBuilder: (currentItem, size, color) => Obx(
          (context) => Icon(
            settings.enableVideoPlayback.valueR ? Broken.video : Broken.headphone,
            size: size,
            color: color,
          ),
        ),
        builder: (currentItem, fontSizeMultiplier, sizeMultiplier) {
          final onSecondary = theme.colorScheme.onSecondaryContainer;
          return Obx((context) {
            if (!settings.enableVideoPlayback.valueR) {
              final trExt = (currentItem as Selectable).track.toTrackExt();
              var text = " • ${trExt.audioInfoFormattedCompact}";
              final bits = trExt.bits;
              final isLossless = trExt.isLossless;

              final bitsTextParts = [
                if (bits >= 24) 'Hi-Res',
                if (isLossless == true) 'Lossless',
              ];
              final bitsText = bitsTextParts.join(' ');

              return Text.rich(
                TextSpan(
                  text: lang.audio,
                  style: textTheme.labelLarge?.copyWith(fontSize: fontSizeMultiplier(15.0), color: theme.colorScheme.onSecondaryContainer),
                  children: [
                    if (settings.displayAudioInfoMiniplayer.valueR)
                      TextSpan(
                        text: text,
                        style: TextStyle(color: theme.colorScheme.primary, fontSize: fontSizeMultiplier(11.0)),
                        children: bits > 0
                            ? [
                                const WidgetSpan(
                                  child: SizedBox(width: 4.0),
                                ),
                                WidgetSpan(
                                  child: NamidaPopupWrapper(
                                    contentDecoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(12.0.multipliedRadius),
                                      border: Border.all(
                                        color: CurrentColor.inst.miniplayerColor,
                                      ),
                                      gradient: LinearGradient(
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                        colors: [
                                          Color.alphaBlend(theme.scaffoldBackgroundColor.withOpacityExt(0.8), CurrentColor.inst.miniplayerColor).withOpacityExt(1.0),
                                          Color.alphaBlend(theme.scaffoldBackgroundColor.withOpacityExt(0.5), CurrentColor.inst.miniplayerColor).withOpacityExt(1.0),
                                        ],
                                      ),
                                    ),
                                    children: () => [
                                      Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 12.0),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          crossAxisAlignment: CrossAxisAlignment.center,
                                          children: [
                                            Icon(
                                              Broken.wind_2,
                                              size: 32.0,
                                            ),
                                            const SizedBox(height: 12.0),
                                            if (bitsText.isNotEmpty) ...[
                                              Text(
                                                bitsText,
                                                style: textTheme.displayLarge,
                                              ),
                                              const SizedBox(height: 6.0),
                                            ],
                                            Text(
                                              trExt.audioInfoFormattedAlt,
                                              style: textTheme.displayMedium,
                                            ),
                                            const SizedBox(height: 4.0),
                                          ],
                                        ),
                                      ),
                                    ],
                                    child: NamidaInkWell(
                                      borderRadius: 4.0,
                                      bgColor: theme.cardColor.withAlpha(60),
                                      padding: const EdgeInsetsGeometry.symmetric(horizontal: 4.0, vertical: 1.0),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Broken.wind_2,
                                            size: 12.0,
                                          ),
                                          const SizedBox(width: 2.0),
                                          Text(
                                            [
                                              '$bits-bit',
                                              ...bitsTextParts,
                                            ].join(' '),
                                            style: TextStyle(
                                              color: theme.colorScheme.primary,
                                              fontSize: fontSizeMultiplier(11.0),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ]
                            : null,
                      ),
                  ],
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              );
            }
            final currentVideo = VideoController.inst.currentVideo.valueR;
            final downloadedBytes = VideoController.inst.currentVideoConfig.currentDownloadedBytes.valueR;
            final videoTotalSize = currentVideo?.sizeInBytes ?? 0;
            final videoQuality = currentVideo?.resolution ?? 0;
            final videoFramerate = currentVideo?.framerateText(30);
            late final markText = VideoController.inst.currentVideoConfig.isNoVideosAvailable.valueR
                ? 'x'
                : (currentItem as Selectable).track is Video
                ? '✓'
                : '?';
            final fallbackQualityLabel = currentVideo?.nameInCache?.splitLast('_');
            final qualityText = videoQuality == 0 ? fallbackQualityLabel ?? markText : '${videoQuality}p';
            final framerateText = videoFramerate ?? '';

            final videoBlockedBy = VideoController.inst.currentVideoConfig.videoBlockedByType.valueR;
            final videoBlockedByIcon = switch (videoBlockedBy) {
              VideoFetchBlockedBy.cachePriority => Broken.cpu,
              VideoFetchBlockedBy.noNetwork => Broken.global_refresh,
              VideoFetchBlockedBy.dataSaver => Broken.blur,
              VideoFetchBlockedBy.playbackSource => Broken.scroll,
              null => null,
            };

            return Text.rich(
              TextSpan(
                text: lang.video,
                style: textTheme.labelLarge?.copyWith(fontSize: fontSizeMultiplier(15.0), color: theme.colorScheme.onSecondaryContainer),
                children: [
                  if (videoBlockedByIcon != null) ...[
                    TextSpan(
                      text: " • ",
                      style: TextStyle(color: onSecondary, fontSize: fontSizeMultiplier(15.0)),
                    ),
                    WidgetSpan(
                      child: Icon(
                        videoBlockedByIcon,
                        size: sizeMultiplier(14.0),
                        color: onSecondary,
                      ),
                    ),
                  ] else
                    TextSpan(
                      text: " • $qualityText$framerateText",
                      style: TextStyle(
                        color: theme.colorScheme.primary,
                        fontSize: fontSizeMultiplier(13.0),
                      ),
                    ),
                  // --
                  if (videoTotalSize > 0) ...[
                    TextSpan(
                      text: " • ",
                      style: TextStyle(color: theme.colorScheme.primary, fontSize: fontSizeMultiplier(14.0)),
                    ),
                    TextSpan(
                      text: downloadedBytes == null ? videoTotalSize.fileSizeFormatted : "${downloadedBytes.fileSizeFormatted}/${videoTotalSize.fileSizeFormatted}",
                      style: TextStyle(color: onSecondary, fontSize: fontSizeMultiplier(10.0)),
                    ),
                  ],
                ],
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            );
          });
        },
        currentId: (item) => (item as Selectable).track.youtubeID,
        loadQualities: null,
        localVideos: VideoController.inst.currentVideoConfig.currentPossibleLocalVideos,
        streams: null,
        onLocalVideoTap: (item, video) async {
          VideoController.inst.ensureVideoPlaybackActive();
          VideoController.inst.playVideoCurrent(video: video, track: (item as Selectable).track);
        },
        onStreamVideoTap: null,
      ),
      imageBuilder: (item, brMultiplier) => _TrackImage(
        track: (item as Selectable).track,
        brMultiplier: brMultiplier,
      ),
      currentImageBuilder: (item, brMultiplier, maxHeight, maxWidth) => _AnimatingTrackImage(
        track: (item as Selectable).track,
        brMultiplier: brMultiplier,
        maxHeight: maxHeight,
        maxWidth: maxWidth,
      ),
      textBuilder: textBuilder,
      canShowBuffering: (currentItem) => (currentItem as Selectable).track.isNetwork,
    );
  }

  @override
  Widget build(BuildContext context) {
    return getMiniPlayerBase(context);
  }
}

final _lrcAdditionalScale = 0.0.obs;

class _AnimatingTrackImage extends StatelessWidget {
  final Track track;
  final double Function(double borderRadius) brMultiplier;
  final double? maxHeight;
  final double? maxWidth;

  const _AnimatingTrackImage({
    required this.track,
    required this.brMultiplier,
    required this.maxHeight,
    required this.maxWidth,
  });

  @override
  Widget build(BuildContext context) {
    return _AnimatingThumnailWidget(
      brMultiplier: brMultiplier,
      isLocal: true,
      maxHeight: maxHeight,
      maxWidth: maxWidth,
      fallback: _TrackImage(
        track: track,
        brMultiplier: brMultiplier,
      ),
    );
  }
}

class _AnimatingThumnailWidget extends StatelessWidget {
  final double Function(double borderRadius) brMultiplier;
  final bool isLocal;
  final Widget fallback;
  final double? maxHeight;
  final double? maxWidth;

  const _AnimatingThumnailWidget({
    required this.brMultiplier,
    required this.isLocal,
    required this.fallback,
    required this.maxHeight,
    required this.maxWidth,
  });

  @override
  Widget build(BuildContext context) {
    return ObxO(
      rx: settings.animatingThumbnailInversed,
      builder: (context, isInversed) => ObxO(
        rx: settings.animatingThumbnailScaleMultiplier,
        builder: (context, userScaleMultiplier) => ObxO(
          rx: Player.inst.videoPlayerInfo,
          builder: (context, videoInfo) {
            final videoOrImage = Stack(
              alignment: Alignment.center,
              children: [
                videoInfo != null && videoInfo.isInitialized
                    ? AnimatedBuilder(
                        animation: NamidaMiniPlayerBase.clampedAnimationBCP,
                        child: DoubleTapDetector(
                          onDoubleTap: () => VideoController.inst.toggleFullScreenVideoView(isLocal: isLocal),
                          child: NamidaAspectRatio(
                            aspectRatio: videoInfo.aspectRatio,
                            child: Texture(textureId: videoInfo.textureId),
                          ),
                        ),
                        builder: (context, child) => BorderRadiusClip(
                          borderRadius: BorderRadius.circular(6.0.multipliedRadius + (brMultiplier(8.0.multipliedRadius) * NamidaMiniPlayerBase.clampedAnimationBCP.value)),
                          child: child!,
                        ),
                      )
                    : fallback,
              ],
            );

            return ObxO(
              rx: settings.enableLyrics,
              builder: (context, shoulShowLyricsView) {
                final animatedScaleChild = CustomAnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: shoulShowLyricsView
                      ? LyricsLRCParsedView(
                          key: Lyrics.inst.lrcViewKey,
                          videoOrImage: videoOrImage,
                          maxWidth: maxWidth,
                          maxHeight: maxHeight, // limit height for when sizes are internally mutated
                        )
                      : KeyedSubtree(
                          key: const ValueKey('no_lyrics'),
                          child: videoOrImage,
                        ),
                );
                return ObxO(
                  rx: VideoController.inst.videoZoomAdditionalScale,
                  builder: (context, videoZoomAdditionalScale) {
                    final additionalScaleVideo = 0.02 * videoZoomAdditionalScale;
                    return ObxO(
                      rx: _lrcAdditionalScale,
                      builder: (context, lrcAdditionalScale) {
                        final additionalScaleLRC = 0.02 * lrcAdditionalScale;
                        return ObxO(
                          rx: Player.inst.nowPlayingPosition,
                          builder: (context, nowPlayingPosition) {
                            final animatingScale = MiniPlayerController.inst.animation.value == 0
                                ? WaveformController.inst.getCurrentAnimatingScaleMinimized(nowPlayingPosition)
                                : shoulShowLyricsView
                                ? WaveformController.inst.getCurrentAnimatingScaleLyrics(nowPlayingPosition)
                                : WaveformController.inst.getCurrentAnimatingScale(nowPlayingPosition);
                            final finalScale = additionalScaleLRC + additionalScaleVideo + animatingScale;
                            return AnimatedScale(
                              duration: const Duration(milliseconds: 100),
                              scale: (isInversed ? 1.22 - finalScale : 1.13 + finalScale) * userScaleMultiplier,
                              child: animatedScaleChild,
                            );
                          },
                        );
                      },
                    );
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _TrackImage extends StatelessWidget {
  final Track track;
  final double Function(double borderRadius) brMultiplier;

  const _TrackImage({
    required this.track,
    required this.brMultiplier,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutWidthProvider(
      builder: (context, maxWidth) => ArtworkWidget(
        key: Key(track.pathToImage),
        track: track,
        path: track.pathToImage,
        thumbnailSize: maxWidth,
        compressed: MiniPlayerController.inst.shouldCompressArtwork,
        borderRadius: 6.0 + brMultiplier(8.0.multipliedRadius) * (maxWidth * 0.004),
        fadeMilliSeconds: 0,
        forceSquared: settings.forceSquaredTrackThumbnail.value,
        boxShadow: const [
          BoxShadow(
            color: Color.fromARGB(40, 12, 12, 12),
            blurRadius: 18.0,
            offset: Offset(0.0, 6.0),
          ),
        ],
        iconSize: maxWidth * 0.5,
        blur: 32.0 * MiniPlayerController.inst.animation.value,
        disableBlurBgSizeShrink: true,
        allowFloating: true,
      ),
    );
  }
}

class Wallpaper extends StatefulWidget {
  const Wallpaper({
    super.key,
    this.child,
    this.particleOpacity = .1,
    this.gradient = true,
  });

  final Widget? child;
  final double particleOpacity;
  final bool gradient;

  @override
  State<Wallpaper> createState() => _WallpaperState();
}

class _WallpaperState extends State<Wallpaper> with SingleTickerProviderStateMixin {
  @override
  Widget build(BuildContext context) {
    final theme = context.theme;
    return Material(
      color: theme.scaffoldBackgroundColor,
      child: Stack(
        children: [
          if (widget.gradient)
            Container(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0.95, -0.95),
                  radius: 1.0,
                  colors: [
                    theme.colorScheme.onSecondary.withOpacityExt(.3),
                    theme.colorScheme.onSecondary.withOpacityExt(.2),
                  ],
                ),
              ),
            ),
          if (settings.enableMiniplayerParticles.value)
            ObxO(
              rx: Player.inst.isPlaying,
              builder: (context, playing) => AnimatedOpacity(
                duration: const Duration(seconds: 1),
                opacity: playing ? 1 : 0,
                child: ObxO(
                  rx: Player.inst.nowPlayingPosition,
                  builder: (context, nowPlayingPosition) {
                    final scale = WaveformController.inst.getCurrentAnimatingScale(nowPlayingPosition);
                    final bpm = (2000 * scale).withMinimum(0);
                    return AnimatedScale(
                      duration: const Duration(milliseconds: 300),
                      scale: 1.0 + scale * 1.5,
                      child: AnimatedBackground(
                        vsync: this,
                        behaviour: RandomParticleBehaviour(
                          options: ParticleOptions(
                            baseColor: theme.colorScheme.secondary,
                            spawnMaxRadius: 4,
                            spawnMinRadius: 2,
                            spawnMaxSpeed: 60 + bpm * 2,
                            spawnMinSpeed: bpm,
                            maxOpacity: widget.particleOpacity,
                            minOpacity: 0,
                            particleCount: 50,
                          ),
                        ),
                        child: const SizedBox(),
                      ),
                    );
                  },
                ),
              ),
            ),
          if (widget.child != null) widget.child!,
        ],
      ),
    );
  }
}
