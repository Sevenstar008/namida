import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_volume_controller/flutter_volume_controller.dart' show FlutterVolumeController;
import 'package:native_device_orientation/native_device_orientation.dart';
import 'package:screen_brightness/screen_brightness.dart';

import 'package:namida/class/route.dart';
import 'package:namida/class/track.dart';
import 'package:namida/class/video.dart';
import 'package:namida/controller/connectivity.dart';
import 'package:namida/controller/current_color.dart';
import 'package:namida/controller/miniplayer_controller.dart';
import 'package:namida/controller/navigator_controller.dart';
import 'package:namida/controller/platform/namida_channel/namida_channel.dart';
import 'package:namida/controller/player_controller.dart';
import 'package:namida/controller/settings_controller.dart';
import 'package:namida/controller/video_controller.dart';
import 'package:namida/core/constants.dart';
import 'package:namida/core/dimensions.dart';
import 'package:namida/core/enums.dart';
import 'package:namida/core/extensions.dart';
import 'package:namida/core/icon_fonts/broken_icons.dart';
import 'package:namida/core/namida_converter_ext.dart';
import 'package:namida/core/translations/language.dart';
import 'package:namida/core/utils.dart';
import 'package:namida/packages/three_arched_circle.dart';
import 'package:namida/ui/dialogs/edit_tags_dialog.dart';
import 'package:namida/ui/widgets/artwork.dart';
import 'package:namida/ui/widgets/custom_widgets.dart';
import 'package:namida/ui/widgets/settings/extra_settings.dart';

class NamidaVideoControls extends StatefulWidget {
  final bool showControls;
  final double? disableControlsUnderPercentage;
  final VoidCallback? onMinimizeTap;
  final bool isFullScreen;
  final bool isLocal;
  final bool forceEnableSponsorBlock;

  const NamidaVideoControls({
    super.key,
    required this.showControls,
    this.disableControlsUnderPercentage,
    required this.onMinimizeTap,
    required this.isFullScreen,
    required this.isLocal,
    this.forceEnableSponsorBlock = true,
  });

  @override
  State<NamidaVideoControls> createState() => NamidaVideoControlsState();
}

class NamidaVideoControlsState extends State<NamidaVideoControls> with TickerProviderStateMixin {
  bool _isVisible = false;
  double _maxWidth = 0.0;
  double _maxHeight = 0.0;
  final hideDuration = const Duration(seconds: 3);
  final hoverHideDuration = const Duration(seconds: 1);
  final volumeHideDuration = const Duration(milliseconds: 500);
  final brightnessHideDuration = const Duration(milliseconds: 500);
  final transitionDuration = const Duration(milliseconds: 300);
  final doubleTapSeekReset = const Duration(milliseconds: 900);

  Timer? _hideTimer;
  void _resetTimer() {
    _hideTimer?.cancel();
    _hideTimer = null;
  }

  void _startTimer({Duration? duration}) {
    _resetTimer();
    if (_isVisible) {
      _hideTimer = Timer(duration ?? hideDuration, () {
        setControlsVisibily(false);
      });
    }
  }

  void setControlsVisibily(bool visible, {bool? maintainStatusBar}) {
    if (visible && NamidaChannel.inst.isInPip.value) return; // dont show if in pip
    if (visible == _isVisible) return;
    if (mounted) setState(() => _isVisible = visible);

    if (mounted && (maintainStatusBar ?? widget.isFullScreen)) {
      if (visible) {
        // -- show status bar
        NamidaNavigator.setSystemUIImmersiveMode(false, overlays: [SystemUiOverlay.top]);
      } else {
        // -- hide status bar
        NamidaNavigator.setSystemUIImmersiveMode(true);
      }
    }
  }

  Timer? _isEndCardsVisibleTimer;
  final _isEndCardsVisible = true.obs;

  void showControlsBriefly() {
    setControlsVisibily(true, maintainStatusBar: false);
    _startTimer();
  }

  Widget _getBuilder({
    required Widget child,
  }) {
    final shouldShow = _isVisible;
    return IgnorePointer(
      ignoring: !shouldShow,
      child: AnimatedOpacity(
        duration: transitionDuration,
        opacity: shouldShow ? 1.0 : 0.0,
        child: child,
      ),
    );
  }

  void _onTap() {
    _currentDeviceVolume.value = null; // hide volume slider
    _canShowBrightnessSlider.value = false; // hide brightness slider
    if (_shouldSeekOnTap) return;
    if (_isVisible) {
      setControlsVisibily(false);
    } else {
      if (widget.showControls) {
        setControlsVisibily(true);
      }
    }
    _startTimer();
  }

  void _onEdgeHoverEnter() {
    _currentDeviceVolume.value = null; // hide volume slider
    _canShowBrightnessSlider.value = false; // hide brightness slider

    if (widget.showControls) {
      setControlsVisibily(true);
    }

    _resetTimer();
  }

  void _onEdgeHoverExit() {
    _startTimer(duration: hoverHideDuration);
  }

  bool _shouldSeekOnTap = false;
  Timer? _doubleSeekTimer;
  void _startSeekTimer(bool forward) {
    _shouldSeekOnTap = true;
    _doubleSeekTimer?.cancel();
    _doubleSeekTimer = Timer(doubleTapSeekReset, () {
      _shouldSeekOnTap = false;
      _seekSecondsRx.value = 0;
    });
  }

  final _seekSecondsRx = 0.obs;

  /// This prevents mixing up forward seek seconds with backward ones.
  bool _lastSeekWasForward = true;

  void _onDoubleTap(Offset position) async {
    final totalWidth = _maxWidth;
    final halfScreen = totalWidth / 2;
    final middleAmmountToIgnore = totalWidth / 6;
    final pos = position.dx - halfScreen;
    if (pos.abs() > middleAmmountToIgnore) {
      if (pos.isNegative) {
        // -- Seeking Backwards
        animateSeekControllers(false);
        _startSeekTimer(false);
        Player.inst.seekSecondsBackward(
          onSecondsReady: (finalSeconds) {
            if (_shouldSeekOnTap && !_lastSeekWasForward) {
              // only increase if not at the start
              if (Player.inst.nowPlayingPosition.value > 0) {
                _seekSecondsRx.value += finalSeconds;
              }
            } else {
              _seekSecondsRx.value = finalSeconds;
            }
          },
        );
        _lastSeekWasForward = false;
      } else {
        // -- Seeking Forwards
        animateSeekControllers(true);
        _startSeekTimer(true);
        Player.inst.seekSecondsForward(
          onSecondsReady: (finalSeconds) {
            if (_shouldSeekOnTap && _lastSeekWasForward) {
              // only increase if not at the end
              if (Player.inst.nowPlayingPosition.value < (Player.inst.currentItemDuration.value?.inMilliseconds ?? 0)) {
                _seekSecondsRx.value += finalSeconds;
              }
            } else {
              _seekSecondsRx.value = finalSeconds;
            }
          },
        );
        _lastSeekWasForward = true;
      }
    }
  }

  void animateSeekControllers(bool isForward) async {
    if (isForward) {
      // -- first container
      _animateAfterDelayMS(controller: seekAnimationForward1, delay: 0, target: 1.0);
      _animateAfterDelayMS(controller: seekAnimationForward1, delay: 500, target: 0.0);

      // -- second container
      _animateAfterDelayMS(controller: seekAnimationForward2, delay: 200, target: 1.0);
      _animateAfterDelayMS(controller: seekAnimationForward2, delay: 600, target: 0.0);
    } else {
      // -- first container
      _animateAfterDelayMS(controller: seekAnimationBackward1, delay: 0, target: 1.0);
      _animateAfterDelayMS(controller: seekAnimationBackward1, delay: 500, target: 0.0);

      // -- second container
      _animateAfterDelayMS(controller: seekAnimationBackward2, delay: 200, target: 1.0);
      _animateAfterDelayMS(controller: seekAnimationBackward2, delay: 600, target: 0.0);
    }
  }

  Future<void> _animateAfterDelayMS({
    required AnimationController controller,
    required int delay,
    required double target,
  }) async {
    await Future.delayed(Duration(milliseconds: delay));
    await controller.animateTo(target);
  }

  /// disables controls entirely when specified. for example when minplayer is minimized & controls should't be there.
  void _disableControlsListener() {
    if (!mounted) return;
    final value = MiniPlayerController.inst.animation.value;
    final hideUnder = widget.disableControlsUnderPercentage!;
    final shouldHide = value < hideUnder;
    if (shouldHide != _isLocked) {
      setState(() => _isLocked = shouldHide);
    }
  }

  @override
  void initState() {
    super.initState();
    const dur = Duration(milliseconds: 200);
    const dur2 = Duration(milliseconds: 200);
    seekAnimationForward1 = AnimationController(
      vsync: this,
      duration: dur,
      lowerBound: 0.0,
      upperBound: 1.0,
    );
    seekAnimationForward2 = AnimationController(
      vsync: this,
      duration: dur2,
      lowerBound: 0.0,
      upperBound: 1.0,
    );
    seekAnimationBackward1 = AnimationController(
      vsync: this,
      duration: dur,
      lowerBound: 0.0,
      upperBound: 1.0,
    );
    seekAnimationBackward2 = AnimationController(
      vsync: this,
      duration: dur2,
      lowerBound: 0.0,
      upperBound: 1.0,
    );

    if (widget.isFullScreen) {
      Player.inst.onVolumeChangeAddListener(
        _volumeListenerKey,
        (mv) async {
          if (_canShowControls) {
            _currentDeviceVolume.value = mv;
            if (!_isPointerDown) _startVolumeSwipeTimer(); // only start timer if not handled by pointer down/up
          }
        },
      );
    }

    if (widget.disableControlsUnderPercentage != null) {
      _disableControlsListener();
      MiniPlayerController.inst.animation.addListener(_disableControlsListener);
    }

    if (widget.isFullScreen && NamidaFeaturesVisibility.changeApplicationBrightness) {
      ScreenBrightness.instance.system.then((value) => _currentBrigthnessDim.value = 1.0 + value);
      _systemBrightnessStreamSub = ScreenBrightness.instance.onSystemScreenBrightnessChanged.listen(
        (event) {
          if (event > 0) {
            _currentBrigthnessDim.value = 1.0 + event;
            _setScreenBrightness(event);
          }
        },
      );
    }
    if (widget.isFullScreen && _deviceOrientationCommunicatorStreamSub == null) _setupDeviceOrientationListener();
  }

  void _setScreenBrightness(double value) async {
    value = value.clampDouble(0.01, 1.0); // -- below 0.01 treats it as 0 and disables it making it jump to system brightness
    try {
      await ScreenBrightness.instance.setApplicationScreenBrightness(value);
    } catch (_) {}
  }

  StreamSubscription<double>? _systemBrightnessStreamSub;

  final _volumeListenerKey = 'video_widget';

  @override
  void dispose() {
    seekAnimationForward1.dispose();
    seekAnimationForward2.dispose();
    seekAnimationBackward1.dispose();
    seekAnimationBackward2.dispose();
    _currentDeviceVolume.close();
    _canShowBrightnessSlider.close();
    _seekSecondsRx.close();
    _isEndCardsVisible.close();
    Player.inst.onVolumeChangeRemoveListener(_volumeListenerKey);
    MiniPlayerController.inst.animation.removeListener(_disableControlsListener);
    _systemBrightnessStreamSub?.cancel();
    if (widget.isFullScreen && NamidaFeaturesVisibility.changeApplicationBrightness) {
      ScreenBrightness.instance.resetApplicationScreenBrightness();
    }
    _deviceOrientationCommunicatorStreamSub?.cancel();
    super.dispose();
  }

  late AnimationController seekAnimationForward1;
  late AnimationController seekAnimationForward2;
  late AnimationController seekAnimationBackward1;
  late AnimationController seekAnimationBackward2;

  Widget _getSeekAnimatedContainer({
    required AnimationController controller,
    required bool isForward,
    required bool isSecondary,
  }) {
    final seekContainerSize = _maxWidth;
    final offsetPercentage = isSecondary ? 0.7 : 0.55;
    final finalOffset = -(seekContainerSize * offsetPercentage);
    return Positioned(
      right: isForward ? finalOffset : null,
      left: isForward ? null : finalOffset,
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: controller,
          child: SizedBox(
            width: seekContainerSize,
            height: seekContainerSize,
          ),
          builder: (context, child) {
            return DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white.withOpacityExt((controller.value / 3).clampDouble(0, 1)),
                shape: BoxShape.circle,
              ),
              child: child!,
            );
          },
        ),
      ),
    );
  }

  Widget getSeekTextWidget({
    required AnimationController controller,
    required bool isForward,
  }) {
    final textTheme = context.textTheme;
    final seekContainerSize = _maxWidth;
    final finalOffset = seekContainerSize * 0.05;
    const forwardIcons = <int, IconData>{
      5: Broken.forward_5_seconds,
      10: Broken.forward_10_seconds,
      15: Broken.forward_15_seconds,
    };
    const backwardIcons = <int, IconData>{
      5: Broken.backward_5_seconds,
      10: Broken.backward_10_seconds,
      15: Broken.backward_15_seconds,
    };
    const color = Color.fromRGBO(222, 222, 222, 0.8);
    const strokeWidth = 1.8;
    const strokeColor = Color.fromRGBO(20, 20, 20, 0.5);
    const shadowBR = 5.0;
    const outlineShadow = <Shadow>[
      // bottomLeft
      Shadow(offset: Offset(-strokeWidth, -strokeWidth), color: strokeColor, blurRadius: shadowBR),
      // bottomRight
      Shadow(offset: Offset(strokeWidth, -strokeWidth), color: strokeColor, blurRadius: shadowBR),
      // topRight
      Shadow(offset: Offset(strokeWidth, strokeWidth), color: strokeColor, blurRadius: shadowBR),
      // topLeft
      Shadow(offset: Offset(-strokeWidth, strokeWidth), color: strokeColor, blurRadius: shadowBR),
    ];
    return Positioned(
      right: isForward ? finalOffset : null,
      left: isForward ? null : finalOffset,
      child: FadeIgnoreTransition(
        completelyKillWhenPossible: true,
        opacity: controller,
        child: ObxO(
          rx: _seekSecondsRx,
          builder: (context, ss) => Column(
            children: [
              Icon(
                isForward ? forwardIcons[ss] ?? Broken.forward : backwardIcons[ss] ?? Broken.backward,
                color: color,
                shadows: outlineShadow,
              ),
              const SizedBox(height: 8.0),
              Text(
                '$ss ${lang.seconds}',
                style: textTheme.displayMedium?.copyWith(
                  color: color,
                  shadows: outlineShadow,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _getQualityChip({
    required String title,
    String? subtitle,
    String? thirdLine,
    IconData? icon,
    required void Function(bool isSelected) onPlay,
    required bool selected,
    required bool isCached,
    Widget? trailing,
    bool popOnTap = true,
  }) {
    final textTheme = context.textTheme;
    return NamidaInkWell(
      onTap: () {
        _startTimer();
        if (popOnTap) NamidaNavigator.inst.popMenu();
        onPlay(selected);
      },
      decoration: const BoxDecoration(),
      borderRadius: 6.0,
      bgColor: selected ? CurrentColor.inst.miniplayerColor.withAlpha(100) : null,
      margin: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 2.0),
      padding: const EdgeInsets.all(6.0),
      child: Row(
        children: [
          Icon(icon ?? (isCached ? Broken.tick_circle : Broken.story), size: 20.0),
          const SizedBox(width: 4.0),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    title,
                    style: textTheme.displayMedium?.copyWith(fontSize: 13.0),
                  ),
                  if (subtitle != null && subtitle != '')
                    Text(
                      subtitle,
                      style: textTheme.displaySmall?.copyWith(fontSize: 12.0),
                    ),
                ],
              ),
              if (thirdLine != null && thirdLine != '')
                Text(
                  thirdLine,
                  style: textTheme.displaySmall?.copyWith(fontSize: 12.0),
                ),
            ],
          ),
          ?trailing,
        ],
      ),
    );
  }

  double _volumeThreshold = 0.0;
  final _volumeMinDistance = 10.0;
  final _currentDeviceVolume = Rxn<double>();

  Timer? _volumeSwipeTimer;
  void _startVolumeSwipeTimer() {
    _volumeSwipeTimer?.cancel();
    _volumeSwipeTimer = Timer(volumeHideDuration, () {
      _currentDeviceVolume.value = null;
    });
  }

  double _brightnessDimThreshold = 0.0;
  final _brightnessMinDistance = 2.0;
  final _canShowBrightnessSlider = false.obs;
  Timer? _brightnessDimTimer;
  void _startBrightnessDimTimer() {
    _brightnessDimTimer?.cancel();
    _brightnessDimTimer = Timer(brightnessHideDuration, () {
      _canShowBrightnessSlider.value = false;
    });
  }

  bool _canSlideVolume(BuildContext context, double globalHeight) {
    final minimumVerticalDistanceToIgnoreSwipes = _maxHeight * 0.1;

    final isSafeFromDown = globalHeight > minimumVerticalDistanceToIgnoreSwipes;
    final isSafeFromUp = globalHeight < _maxHeight - minimumVerticalDistanceToIgnoreSwipes;
    return isSafeFromDown && isSafeFromUp;
  }

  /// used to disable slider if user swiped too close to the edge.
  bool _disableSliders = false;

  /// used to hide slider if wasnt handled by pointer down/up.
  bool _isPointerDown = false;

  bool _isDraggingSeekBar = false;

  Rx<double> get _currentBrigthnessDim => VideoController.inst.currentBrigthnessDim;

  final _maxBrightnessValue = NamidaFeaturesVisibility.changeApplicationBrightness ? 2.0 : 1.0;

  Widget _getVerticalSliderWidget(String key, double? perc, IconData icon, ui.FlutterView view, {double max = 1.0}) {
    final textTheme = context.textTheme;
    final totalHeight = view.physicalSize.shortestSide / view.devicePixelRatio * 0.75;
    return CustomAnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: perc == null || _isDraggingSeekBar
          ? SizedBox(key: Key('$key.hidden'))
          : Material(
              key: Key('$key.visible'),
              type: MaterialType.transparency,
              child: Container(
                width: 42.0,
                decoration: BoxDecoration(
                  color: context.theme.cardColor.withOpacityExt(0.5),
                  borderRadius: BorderRadius.circular(12.0.multipliedRadius),
                ),
                child: Column(
                  children: [
                    const SizedBox(height: 12.0),
                    Stack(
                      alignment: Alignment.bottomCenter,
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacityExt(0.2),
                            borderRadius: BorderRadius.circular(8.0.multipliedRadius),
                          ),
                          width: 4.0,
                          height: totalHeight * 0.4,
                        ),
                        Container(
                          decoration: BoxDecoration(
                            color: CurrentColor.inst.miniplayerColor,
                            borderRadius: BorderRadius.circular(8.0.multipliedRadius),
                          ),
                          width: 4.0,
                          height: totalHeight * 0.4 * (perc / max),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12.0),
                    Text(
                      "${(perc * 100).round()}%",
                      style: textTheme.displaySmall,
                    ),
                    const SizedBox(height: 6.0),
                    Icon(icon, size: 20.0),
                    const SizedBox(height: 12.0),
                  ],
                ),
              ),
            ),
    );
  }

  final borr = BorderRadius.circular(10.0.multipliedRadius);
  final borr8 = BorderRadius.circular(8.0.multipliedRadius);

  bool _pointerDownedOnRight = true;

  bool _doubleTapFirstPress = false;
  Timer? _doubleTapTimer;
  void _onFinishingDoubleTapTimer() {
    _doubleTapFirstPress = false;
    _doubleTapTimer?.cancel();
    _doubleTapTimer = null;
  }

  bool get _canShowControls => !_isLocked && !NamidaChannel.inst.isInPip.value;

  EdgeInsets _deviceInsets = EdgeInsets.zero;

  final _videoConstraintsKey = GlobalKey();

  StreamSubscription<NativeDeviceOrientation>? _deviceOrientationCommunicatorStreamSub;
  void _setupDeviceOrientationListener() {
    if (Platform.isAndroid || Platform.isIOS) {
      _deviceOrientationCommunicatorStreamSub?.cancel();
      final stream = NativeDeviceOrientationCommunicator().onOrientationChanged();
      _deviceOrientationCommunicatorStreamSub = stream.listen(
        (event) {
          if (mounted) {
            setState(() => _deviceInsets = EdgeInsets.zero);
          }
        },
      );
    }
  }

  bool _didDeviceInsetsChange(EdgeInsets newDeviceInsets) {
    return newDeviceInsets.left > _deviceInsets.left ||
        newDeviceInsets.right > _deviceInsets.right ||
        newDeviceInsets.top > _deviceInsets.top ||
        newDeviceInsets.bottom > _deviceInsets.bottom;
  }

  void toggleGlowBehindVideo() {
    final newValueEnabled = !settings.enableGlowBehindVideo.value;
    settings.save(enableGlowBehindVideo: newValueEnabled);
    if (newValueEnabled) {
      snackyy(title: lang.warning, message: lang.performanceNote, icon: Broken.danger);
    }
  }

  void _onPointerUpCancel() {
    _isPointerDown = false;
    _disableSliders = false;
    _startVolumeSwipeTimer();
    _startBrightnessDimTimer();
    _isEndCardsVisibleTimer?.cancel();
    _isEndCardsVisible.value = true;
  }

  bool _isLocked = false;
  void _toggleLocked() {
    setState(() {
      _isLocked = !_isLocked;
    });
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = context.textTheme;
    final newDeviceInsets = MediaQuery.viewPaddingOf(context);
    if (_deviceInsets == EdgeInsets.zero || _didDeviceInsetsChange(newDeviceInsets)) {
      if (newDeviceInsets != EdgeInsets.zero) _deviceInsets = newDeviceInsets;
    }

    final isFullScreen = widget.isFullScreen;

    final maxWidth = _maxWidth = isFullScreen ? context.width : context.width.withMaximum(Dimensions.inst.miniplayerMaxWidth);
    final maxHeight = _maxHeight = context.height;

    final inLandscape = NamidaNavigator.inst.isInLanscape;

    final videoBoxMaxConstraints = inLandscape
        ? BoxConstraints(
            maxHeight: maxHeight,
            maxWidth: maxHeight * 16 / 9,
          )
        : BoxConstraints(
            maxHeight: maxWidth * 9 / 16,
            maxWidth: maxWidth,
          );

    final finalVideoWidget = ObxO(
      rx: Player.inst.videoPlayerInfo,
      builder: (context, info) {
        if (info != null && info.isInitialized) {
          return NamidaAspectRatio(
            aspectRatio: info.aspectRatio,
            child: ObxO(
              rx: VideoController.inst.videoZoomAdditionalScale,
              builder: (context, pinchInZoom) => AnimatedScale(
                duration: const Duration(milliseconds: 200),
                scale: 1.0 + pinchInZoom * 0.02,
                child: Texture(textureId: info.textureId),
              ),
            ),
          );
        }
        if (widget.isLocal && !isFullScreen) {
          return Container(
            key: const Key('dummy_container'),
            color: Colors.transparent,
          );
        }
        // -- fallback images
        return LayoutWidthProvider(
          builder: (context, providerMaxWidth) {
            // -- in landscape, the size is calculated based on height, to fit in correctly.
            final fallbackWidth = (inLandscape ? maxHeight * 16 / 9 : maxWidth).withMaximum(providerMaxWidth);
            final fallbackHeight = double.infinity;
            return ObxO(
              rx: Player.inst.currentItem,
              builder: (context, item) {
                final track = item is Selectable ? item.track : null;
                return ArtworkWidget(
                  key: ValueKey(track?.path),
                  track: track,
                  path: track?.pathToImage,
                  thumbnailSize: fallbackWidth,
                  width: fallbackWidth,
                  borderRadius: 0,
                  blur: 0,
                  disableBlurBgSizeShrink: true,
                  compressed: false,
                  fit: BoxFit.contain, // never change this my friend
                );
              },
            );
          },
        );
      },
    );

    final horizontalControlsPadding = isFullScreen
        ? inLandscape
              ? EdgeInsets.only(left: 12.0 + _deviceInsets.left, right: 12.0 + _deviceInsets.right) // lanscape videos
              : EdgeInsets.only(left: 12.0 + _deviceInsets.left, right: 12.0 + _deviceInsets.right) // vertical videos
        : const EdgeInsets.symmetric(horizontal: 2.0);

    final safeAreaPadding = isFullScreen
        ? inLandscape
              ? EdgeInsets.only(left: _deviceInsets.left, right: _deviceInsets.right)
              : EdgeInsets
                    .zero // bcz we hide status bar and nav bar
        : EdgeInsets.zero;

    final bottomPadding = isFullScreen
        ? inLandscape
              ? 12.0 +
                    _deviceInsets
                        .bottom // lanscape videos
              : 12.0 +
                    0.35 *
                        _deviceInsets
                            .bottom // vertical videos
        : 2.0;
    final topPadding = isFullScreen
        ? inLandscape
              ? 12.0 +
                    _deviceInsets
                        .top // lanscape videos
              : 12.0 +
                    _deviceInsets
                        .top // vertical videos
        : 2.0;
    final itemsColor = Colors.white.withAlpha(200);
    final shouldShowSliders = _canShowControls && isFullScreen;
    final shouldShowSeekBar = isFullScreen;
    final view = View.of(context);

    final mainButtonSize = 40.0.withMaximum(maxWidth * 0.1);
    final mainButtonPadding = EdgeInsets.all(14.0.withMaximum(maxWidth * 0.035));

    final mainBufferIconSize = mainButtonSize * 1.3; // 40 => 52

    final secondaryButtonSize = 30.0.withMaximum(maxWidth * 0.06);
    final secondaryButtonPadding = EdgeInsets.all(10.0.withMaximum(maxWidth * 0.025));

    final lockIconWidget = isFullScreen
        ? NamidaBgBlurClipped(
            blur: 3.0,
            decoration: BoxDecoration(
              color: Colors.black.withOpacityExt(0.2),
              borderRadius: borr8,
            ),
            child: Padding(
              padding: const EdgeInsets.all(6.0),
              child: NamidaIconButton(
                verticalPadding: 2.0,
                horizontalPadding: 8.0,
                padding: EdgeInsets.zero,
                icon: _isLocked ? Broken.lock_slash : Broken.lock_1,
                iconSize: _isLocked ? 22.0 : 18.0,
                iconColor: itemsColor,
                onPressed: _toggleLocked,
              ),
            ),
          )
        : null;

    final skipSponsorButton = const SizedBox();

    late final queueOrderChip = Obx(
      (context) {
        final queueL = Player.inst.currentQueue.valueR.length;
        if (queueL <= 1) return const SizedBox();
        return NamidaBgBlurClipped(
          blur: 3.0,
          decoration: BoxDecoration(
            color: Colors.black.withOpacityExt(0.2),
            borderRadius: borr8,
          ),
          child: Padding(
            padding: const EdgeInsets.all(6.0),
            child: Obx(
              (context) => Text(
                "${Player.inst.currentIndex.valueR + 1}/$queueL",
                style: textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w600, color: itemsColor),
              ),
            ),
          ),
        );
      },
    );

    final currentSegmentsChip = const SizedBox();

    Widget videoControlsWidget = _ListenerEnabled(
      enabled: !_isLocked,
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        _pointerDownedOnRight = event.position.dx > maxWidth / 2;
        _isPointerDown = true;
        if (_shouldSeekOnTap) {
          _onDoubleTap(event.position);
          _startTimer();
        }
        _disableSliders = !_canSlideVolume(context, event.position.dy);
        _isEndCardsVisibleTimer = Timer(Duration(milliseconds: 200), () {
          _isEndCardsVisible.value = false;
        });
      },
      onPointerUp: (_) {
        _onPointerUpCancel();
      },
      onPointerCancel: (_) {
        _onPointerUpCancel();
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: _isLocked ? null : (_) {},
        onHorizontalDragUpdate: _isLocked ? null : (_) {},
        onHorizontalDragEnd: _isLocked ? null : (_) {},
        onHorizontalDragCancel: _isLocked ? null : () {},
        onVerticalDragUpdate: !shouldShowSliders
            ? null
            : (event) async {
                if (_disableSliders) return;
                if (_isDraggingSeekBar) return;
                final d = event.delta.dy;
                if (_pointerDownedOnRight) {
                  // -- volume
                  _volumeThreshold += d;
                  if (_volumeThreshold >= _volumeMinDistance) {
                    _volumeThreshold = 0.0;
                    await FlutterVolumeController.lowerVolume(null);
                  } else if (_volumeThreshold <= -_volumeMinDistance) {
                    _volumeThreshold = 0.0;
                    await FlutterVolumeController.raiseVolume(null);
                  }
                } else {
                  _brightnessDimThreshold += d;
                  if (_brightnessDimThreshold >= _brightnessMinDistance) {
                    _brightnessDimThreshold = 0.0;
                    _canShowBrightnessSlider.value = true;
                    _currentBrigthnessDim.value = (_currentBrigthnessDim.value - 0.01).withMinimum(0.1);
                  } else if (_brightnessDimThreshold <= -_brightnessMinDistance) {
                    _brightnessDimThreshold = 0.0;
                    _canShowBrightnessSlider.value = true;
                    _currentBrigthnessDim.value = (_currentBrigthnessDim.value + 0.01).withMaximum(_maxBrightnessValue);
                  }
                  if (NamidaFeaturesVisibility.changeApplicationBrightness) {
                    if (_currentBrigthnessDim.value > 1.0) {
                      // -- settings to 0 just disables it, thats why only `> 1.0`
                      _setScreenBrightness(_currentBrigthnessDim.value - 1.0);
                    }
                  }
                }
              },
        onTapUp: _canShowControls
            ? (event) {
                if (_isDraggingSeekBar) return;

                if (_doubleTapFirstPress && _doubleTapTimer?.isActive == true) {
                  // -- pressed again within 200ms.
                  _onDoubleTap(event.localPosition);
                  setControlsVisibily(false);
                  _doubleTapTimer?.cancel();
                  _doubleTapTimer = Timer(const Duration(milliseconds: 200), () {
                    _doubleTapFirstPress = false;
                    _onFinishingDoubleTapTimer();
                  });
                } else {
                  _onTap();
                  _doubleTapFirstPress = true;
                  _doubleTapTimer?.cancel();
                  _doubleTapTimer = Timer(const Duration(milliseconds: 200), () {
                    _doubleTapFirstPress = false;
                  });
                }
              }
            : _isLocked
            ? (_) {
                _onTap();
              }
            : null,
        onTapCancel: () {
          _onFinishingDoubleTapTimer();
        },
        child: Stack(
          fit: StackFit.passthrough,
          alignment: Alignment.center,
          children: [
            Align(
              alignment: Alignment.center,
              child: Padding(
                padding: safeAreaPadding,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    ObxO(
                      key: _videoConstraintsKey,
                      rx: settings.enableGlowBehindVideo,
                      builder: (context, enableGlowBehindVideo) => ObxO(
                        rx: NamidaChannel.inst.isInPip,
                        builder: (context, inPip) => _DropShadowWrapper(
                          enabled: isFullScreen && !inPip && enableGlowBehindVideo,
                          child: finalVideoWidget,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // ---- Brightness Mask -----
            Positioned.fill(
              child: ObxO(
                rx: _currentBrigthnessDim,
                builder: (context, brightness) => brightness < 1.0
                    ? IgnorePointer(
                        child: ColoredBox(
                          color: Colors.black.withOpacityExt(1 - brightness),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ),

            // -- local video seek handled by the system seek bar below

            if (_isLocked && lockIconWidget != null)
              Align(
                alignment: .topLeft,
                child: Padding(
                  padding: horizontalControlsPadding + EdgeInsets.only(top: topPadding) + const EdgeInsets.all(8.0),
                  child: _getBuilder(
                    child: lockIconWidget,
                  ),
                ),
              ),

            if (widget.showControls)
              IgnorePointer(
                ignoring: !_canShowControls,
                child: Opacity(
                  opacity: _canShowControls ? 1.0 : 0,
                  child: Stack(
                    fit: StackFit.passthrough,
                    alignment: Alignment.center,
                    children: [
                      if (NamidaFeaturesVisibility.showVideoControlsOnHover)
                        Center(
                          child: LayoutWidthHeightProvider(
                            builder: (context, maxWidth, maxHeight) {
                              // final leftPortion = maxWidth * 0.1;
                              // final rightPortion = maxWidth * 0.9;
                              final topPortion = maxHeight * 0.1;
                              final bottomPortion = maxHeight * 0.8;

                              final allowBottom = isFullScreen;

                              return MouseRegion(
                                opaque: false,
                                onHover: (event) {
                                  // final dx = event.position.dx;
                                  final dy = event.position.dy;
                                  final allowVertical = (dy < topPortion || (allowBottom && dy > bottomPortion));
                                  const allowHorizontal = false;
                                  // final allowHorizontal = (dx < leftPortion || dx > rightPortion);
                                  if (allowVertical || allowHorizontal) {
                                    if (_isVisible == false) {
                                      _onEdgeHoverEnter();
                                    }
                                  } else {
                                    if (_isVisible == true && _hideTimer == null) {
                                      _onEdgeHoverExit();
                                    }
                                  }
                                },
                              );
                            },
                          ),
                        ),

                      // ---- Mask -----
                      Positioned.fill(
                        child: IgnorePointer(
                          child: _getBuilder(
                            child: Container(
                              color: Colors.black.withOpacityExt(0.25),
                            ),
                          ),
                        ),
                      ),

                      Positioned.fill(
                        child: LongPressDetector(
                          onLongPress: null,
                          initializer: (instance) {
                            instance.onLongPressStart = _isLocked ? null : (_) => Player.inst.startSpeedUp();
                            instance.onLongPressEnd = (_) => Player.inst.endSpeedUp();
                            instance.onLongPressCancel = () => Player.inst.endSpeedUp();
                          },
                        ),
                      ),

                      // ---- Top Row ----
                      Padding(
                        padding: horizontalControlsPadding + EdgeInsets.only(top: topPadding),
                        child: TapDetector(
                          onTap: () {},
                          child: Align(
                            alignment: Alignment.topCenter,
                            child: _getBuilder(
                              child: Row(
                                children: [
                                  if (isFullScreen || widget.onMinimizeTap != null)
                                    NamidaIconButton(
                                      horizontalPadding: 12.0,
                                      verticalPadding: 6.0,
                                      onPressed: isFullScreen ? NamidaNavigator.inst.exitFullScreen : widget.onMinimizeTap,
                                      icon: Broken.arrow_down_2,
                                      iconColor: itemsColor,
                                      iconSize: 20.0,
                                    ),
                                  const SizedBox(width: 8.0),
                                  Expanded(
                                    child: isFullScreen
                                        ? Material(
                                            type: MaterialType.transparency,
                                            child: _VideoTitleSubtitleWidget(
                                              isLocal: widget.isLocal,
                                            ),
                                          )
                                        : const SizedBox(),
                                  ),
                                  const SizedBox(width: 4.0),

                                  // ==== Reset Brightness ====
                                  ObxO(
                                    rx: _currentBrigthnessDim,
                                    builder: (context, brigthnessDim) => CustomAnimatedSwitcher(
                                      duration: const Duration(milliseconds: 200),
                                      child: brigthnessDim < 1.0
                                          ? NamidaIconButton(
                                              key: const Key('brightnesseto_ok'),
                                              tooltip: () => lang.resetBrightness,
                                              icon: Broken.sun_1,
                                              iconColor: itemsColor.withOpacityExt(0.8),
                                              verticalPadding: 4.0,
                                              horizontalPadding: 8.0,
                                              iconSize: 18.0,
                                              onPressed: () => _currentBrigthnessDim.value = 1.0,
                                            )
                                          : const SizedBox(
                                              key: Key('brightnesseto_no'),
                                            ),
                                    ),
                                  ),
                                  const SizedBox(width: 4.0),

                                  // ===== Speed Chip =====
                                  NamidaPopupWrapper(
                                    onPop: _startTimer,
                                    onTap: () {
                                      _resetTimer();
                                      setControlsVisibily(true);
                                    },
                                    children: () => [
                                      ...settings.player.speeds.map(
                                        (speed) => ObxO(
                                          rx: Player.inst.currentSpeed,
                                          builder: (context, selectedSpeed) {
                                            final isSelected = selectedSpeed == speed;
                                            return NamidaInkWell(
                                              onTap: () {
                                                _startTimer();
                                                final isSelected = Player.inst.currentSpeed.value == speed;
                                                if (!isSelected) {
                                                  Player.inst.setSpeed(speed);
                                                  settings.player.save(speed: speed);
                                                  NamidaNavigator.inst.popMenu();
                                                }
                                              },
                                              decoration: const BoxDecoration(),
                                              borderRadius: 6.0,
                                              bgColor: isSelected ? CurrentColor.inst.miniplayerColor.withAlpha(100) : null,
                                              margin: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 2.0),
                                              padding: const EdgeInsets.all(6.0),
                                              child: Row(
                                                children: [
                                                  const Icon(Broken.play_cricle, size: 20.0),
                                                  const SizedBox(width: 12.0),
                                                  Text(
                                                    "${speed}x",
                                                    style: textTheme.displayMedium?.copyWith(fontSize: 13.0),
                                                  ),
                                                ],
                                              ),
                                            );
                                          },
                                        ),
                                      ),
                                      NamidaInkWell(
                                        onTap: () {
                                          _startTimer();
                                          NamidaNavigator.inst.popMenu();
                                          NamidaNavigator.inst.navigateDialog(dialog: const _SpeedsEditorDialog());
                                        },
                                        decoration: const BoxDecoration(),
                                        borderRadius: 6.0,
                                        bgColor: null,
                                        margin: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 2.0),
                                        padding: const EdgeInsets.all(6.0),
                                        child: Row(
                                          children: [
                                            const Icon(Broken.add_circle, size: 20.0),
                                            const SizedBox(width: 12.0),
                                            Text(
                                              lang.add,
                                              style: textTheme.displayMedium?.copyWith(fontSize: 13.0),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                    child: Padding(
                                      padding: const EdgeInsets.all(4.0),
                                      child: NamidaBgBlurClipped(
                                        blur: 3.0,
                                        decoration: BoxDecoration(
                                          color: Colors.black.withOpacityExt(0.2),
                                          borderRadius: BorderRadius.circular(6.0.multipliedRadius),
                                        ),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
                                          child: Obx(
                                            (context) {
                                              final speed = Player.inst.currentSpeed.valueR;
                                              return Row(
                                                children: [
                                                  Icon(
                                                    Broken.play_cricle,
                                                    size: 16.0,
                                                    color: itemsColor,
                                                  ),
                                                  const SizedBox(width: 4.0).animateEntrance(showWhen: speed != 1.0, allCurves: Curves.easeInOutQuart),
                                                  Text(
                                                    "${speed}x",
                                                    style: textTheme.displaySmall?.copyWith(
                                                      color: itemsColor,
                                                      fontSize: 12.0,
                                                    ),
                                                  ).animateEntrance(showWhen: speed != 1.0, allCurves: Curves.easeInOutQuart),
                                                ],
                                              );
                                            },
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  // ===== Quality Chip (local) =====
                                  NamidaPopupWrapper(
                                    openOnTap: true,
                                    onPop: _startTimer,
                                    onTap: () {
                                      _resetTimer();
                                      setControlsVisibily(true);
                                    },
                                    childrenDefault: () => [
                                      Obx(
                                        (context) => _getQualityChip(
                                          title: lang.audioOnly,
                                          onPlay: (isSelected) {
                                            Player.inst.setAudioOnlyPlayback(true);
                                            VideoController.inst.currentVideo.value = null;
                                            settings.save(enableVideoPlayback: false);
                                          },
                                          selected: widget.isLocal ? VideoController.inst.currentVideo.valueR == null : false,
                                          isCached: false,
                                          icon: Broken.musicnote,
                                        ),
                                      ),
                                    ],
                                    child: Padding(
                                      padding: const EdgeInsets.all(4.0),
                                      child: NamidaBgBlurClipped(
                                        blur: 3.0,
                                        decoration: BoxDecoration(
                                          color: Colors.black.withOpacityExt(0.2),
                                          borderRadius: BorderRadius.circular(6.0.multipliedRadius),
                                        ),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
                                          child: Obx(
                                            (context) {
                                              final isAudio = widget.isLocal ? VideoController.inst.currentVideo.valueR == null : false;
                                              final icon = isAudio ? Broken.musicnote : Broken.setting;
                                              final video = widget.isLocal ? VideoController.inst.currentVideo.valueR : null;
                                              final qt = video == null ? null : '${video.resolution}p${video.framerateText()}';
                                              return Row(
                                                children: [
                                                  if (qt != null) ...[
                                                    Text(
                                                      qt,
                                                      style: textTheme.displaySmall?.copyWith(color: itemsColor),
                                                    ),
                                                    const SizedBox(width: 4.0),
                                                  ],
                                                  Icon(
                                                    icon,
                                                    color: itemsColor,
                                                    size: 16.0,
                                                  ),
                                                ],
                                              );
                                            },
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),

                                  if (isFullScreen)
                                    NamidaPopupWrapper(
                                      openOnTap: true,
                                      onPop: _startTimer,
                                      onTap: () {
                                        _resetTimer();
                                        setControlsVisibily(true);
                                      },
                                      childrenDefault: () => [
                                        NamidaPopupItem(
                                          icon: Broken.sun_1,
                                          secondaryIcon: Broken.drop,
                                          title: lang.enableGlowEffect,
                                          onTap: toggleGlowBehindVideo,
                                          trailing: ObxO(
                                            rx: settings.enableGlowBehindVideo,
                                            builder: (context, active) => CustomSwitch(
                                              active: active,
                                              width: 37.0,
                                              height: 20.0,
                                            ),
                                          ),
                                        ),
                                      ],
                                      child: Padding(
                                        padding: const EdgeInsets.all(4.0),
                                        child: NamidaBgBlurClipped(
                                          blur: 3.0,
                                          decoration: BoxDecoration(
                                            color: Colors.black.withOpacityExt(0.2),
                                            borderRadius: BorderRadius.circular(6.0.multipliedRadius),
                                          ),
                                          child: NamidaTooltip(
                                            message: () => lang.configure,
                                            child: Padding(
                                              padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 6.0),
                                              child: Icon(
                                                Broken.setting_4,
                                                size: 16.0,
                                                color: itemsColor,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                 ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      // ---- Bottom Row ----
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          skipSponsorButton,
                          Padding(
                            padding: horizontalControlsPadding + EdgeInsets.only(bottom: bottomPadding),
                            child: TapDetector(
                              onTap: () {},
                              child: _getBuilder(
                                child: Padding(
                                  padding: const EdgeInsets.all(4.0),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (shouldShowSeekBar)
                                        const SizedBox(
                                          width: double.infinity,
                                          height: 4.0,
                                        ),
                                      Row(
                                        children: [
                                          NamidaBgBlurClipped(
                                            blur: 3.0,
                                            decoration: BoxDecoration(
                                              color: Colors.black.withOpacityExt(0.2),
                                              borderRadius: borr8,
                                            ),
                                            child: Padding(
                                              padding: const EdgeInsets.all(6.0),
                                              child: TapDetector(
                                                behavior: HitTestBehavior.translucent,
                                                onTap: () {
                                                  settings.player.save(displayRemainingDurInsteadOfTotal: !settings.player.displayRemainingDurInsteadOfTotal.value);
                                                },
                                                child: Row(
                                                  mainAxisSize: MainAxisSize.min,
                                                  children: [
                                                    Obx(
                                                      (context) => Text(
                                                        "${Player.inst.nowPlayingPositionR.milliSecondsLabel}/",
                                                        style: textTheme.displayMedium?.copyWith(
                                                          fontSize: 13.5,
                                                          color: itemsColor,
                                                        ),
                                                      ),
                                                    ),
                                                    Obx(
                                                      (context) {
                                                        int totalDurMs = Player.inst.getCurrentVideoDurationR.inMilliseconds;
                                                        String prefix = '';
                                                        if (settings.player.displayRemainingDurInsteadOfTotal.valueR) {
                                                          totalDurMs = totalDurMs - Player.inst.nowPlayingPositionR;
                                                          prefix = '-';
                                                        }

                                                        return Text(
                                                          "$prefix${totalDurMs.milliSecondsLabel}",
                                                          style: textTheme.displayMedium?.copyWith(
                                                            fontSize: 13.5,
                                                            color: itemsColor,
                                                          ),
                                                        );
                                                      },
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 4.0),
                                          if (isFullScreen) ...[
                                            // -- queue order
                                            queueOrderChip,
                                            const SizedBox(width: 4.0),
                                          ],
                                          Expanded(
                                            child: Align(
                                              alignment: Alignment.centerLeft,
                                              child: currentSegmentsChip,
                                            ),
                                          ),
                                          if (lockIconWidget != null) ...[
                                            const SizedBox(width: 4.0),
                                            lockIconWidget,
                                          ],
                                          const SizedBox(width: 4.0),
                                          NamidaBgBlurClipped(
                                            blur: 3.0,
                                            decoration: BoxDecoration(
                                              color: Colors.black.withOpacityExt(0.2),
                                              borderRadius: borr8,
                                            ),
                                            child: Padding(
                                              padding: const EdgeInsets.all(6.0),
                                              child: Row(
                                                children: [
                                                  const SizedBox(width: 2.0),
                                                  if (NamidaFeaturesVisibility.showRotateScreenInFullScreen && isFullScreen) ...[
                                                    // -- rotate screen button
                                                    NamidaIconButton(
                                                      verticalPadding: 2.0,
                                                      horizontalPadding: 4.0,
                                                      padding: EdgeInsets.zero,
                                                      iconSize: 20.0,
                                                      icon: Broken.rotate_left_1,
                                                      iconColor: itemsColor,
                                                      onPressed: () {
                                                        _startTimer();
                                                        NamidaNavigator.inst.setDeviceOrientations(!NamidaNavigator.inst.isInLanscape);
                                                      },
                                                    ),
                                                    const SizedBox(width: 10.0),
                                                  ],

                                                   RepeatModeIconButton(
                                                    compact: true,
                                                    color: itemsColor,
                                                    onPressed: () {
                                                      _startTimer();
                                                    },
                                                  ),
                                                  if (isFullScreen) const SizedBox(width: 10.0) else const SizedBox(width: 8.0),
                                                  SoundControlButton(
                                                    compact: true,
                                                    color: itemsColor,
                                                    onPressed: () {
                                                      _startTimer();
                                                    },
                                                  ),
                                                  if (isFullScreen) const SizedBox(width: 10.0) else const SizedBox(width: 8.0),
                                                   NamidaIconButton(
                                                     verticalPadding: 2.0,
                                                     horizontalPadding: 4.0,
                                                     padding: EdgeInsets.zero,
                                                     iconSize: 20.0,
                                                     icon: Broken.maximize_2,
                                                    iconColor: itemsColor,
                                                    onPressed: () {
                                                      _startTimer();
                                                      VideoController.inst.toggleFullScreenVideoView(isLocal: widget.isLocal);
                                                    },
                                                  ),
                                                  const SizedBox(width: 2.0),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      if (shouldShowSeekBar && !inLandscape) const SizedBox(height: 24.0),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),

                      // ---- Middle Actions ----
                      Padding(
                        padding: safeAreaPadding,
                        child: _getBuilder(
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              const SizedBox(),
                              ObxO(
                                rx: Player.inst.currentIndex,
                                builder: (context, currentIndex) {
                                  final shouldShowPrev = currentIndex != 0;
                                  return Opacity(
                                    opacity: shouldShowPrev ? 1.0 : 0.5,
                                    child: NamidaBgBlurClipped(
                                      blur: 2,
                                      shape: BoxShape.circle,
                                      child: ColoredBox(
                                        color: Colors.black.withOpacityExt(0.2),
                                        child: NamidaIconButton(
                                          icon: null,
                                          padding: secondaryButtonPadding,
                                          onPressed: () {
                                            Player.inst.previous();
                                            _startTimer();
                                          },
                                          child: Icon(
                                            Broken.previous,
                                            size: secondaryButtonSize,
                                            color: itemsColor,
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                              NamidaBgBlurClipped(
                                blur: 2.5,
                                shape: BoxShape.circle,
                                child: ColoredBox(
                                  color: Colors.black.withOpacityExt(0.3),
                                  child: NamidaIconButton(
                                    icon: null,
                                    padding: mainButtonPadding,
                                    onPressed: () {
                                      Player.inst.togglePlayPause();
                                      _startTimer();
                                    },
                                    child: ObxO(
                                      rx: Player.inst.playWhenReady,
                                      builder: (context, playWhenReady) => CustomAnimatedSwitcher(
                                        duration: const Duration(milliseconds: 200),
                                        child: playWhenReady
                                            ? Icon(
                                                Broken.pause,
                                                size: mainButtonSize,
                                                color: itemsColor,
                                                key: const Key('paused'),
                                              )
                                            : Icon(
                                                Broken.play,
                                                size: mainButtonSize,
                                                color: itemsColor,
                                                key: const Key('playing'),
                                              ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              ObxO(
                                rx: Player.inst.currentIndex,
                                builder: (context, currentIndex) {
                                  return ObxO(
                                    rx: Player.inst.currentQueue,
                                    builder: (context, ytqueue) {
                                      final shouldShowNext = currentIndex != ytqueue.length - 1;
                                      return Opacity(
                                        opacity: shouldShowNext ? 1.0 : 0.5,
                                        child: NamidaBgBlurClipped(
                                          blur: 2,
                                          shape: BoxShape.circle,
                                          child: ColoredBox(
                                            color: Colors.black.withOpacityExt(0.2),
                                            child: NamidaIconButton(
                                              icon: null,
                                              padding: secondaryButtonPadding,
                                              onPressed: () {
                                                Player.inst.next();
                                                _startTimer();
                                              },
                                              child: Icon(
                                                Broken.next,
                                                size: secondaryButtonSize,
                                                color: itemsColor,
                                              ),
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  );
                                },
                              ),
                              const SizedBox(),
                            ],
                          ),
                        ),
                      ),
                      IgnorePointer(
                        child: Padding(
                          padding: safeAreaPadding,
                          child: Obx(
                            (context) => Player.inst.shouldShowLoadingIndicatorR
                                ? ThreeArchedCircle(
                                    color: itemsColor,
                                    size: mainBufferIconSize,
                                  )
                                : const SizedBox(),
                          ),
                        ),
                      ),

                      // ===== Seek Animators ====
                      Positioned.fill(
                        child: Padding(
                          padding: safeAreaPadding,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              // -- left --
                              _getSeekAnimatedContainer(
                                controller: seekAnimationBackward1,
                                isForward: false,
                                isSecondary: false,
                              ),
                              _getSeekAnimatedContainer(
                                controller: seekAnimationBackward2,
                                isForward: false,
                                isSecondary: true,
                              ),

                              // -- right --
                              _getSeekAnimatedContainer(
                                controller: seekAnimationForward1,
                                isForward: true,
                                isSecondary: false,
                              ),
                              _getSeekAnimatedContainer(
                                controller: seekAnimationForward2,
                                isForward: true,
                                isSecondary: true,
                              ),

                              // ===========
                              getSeekTextWidget(
                                controller: seekAnimationBackward2,
                                isForward: false,
                              ),
                              getSeekTextWidget(
                                controller: seekAnimationForward2,
                                isForward: true,
                              ),
                            ],
                          ),
                        ),
                      ),

                      // ========= Sliders ==========
                      if (shouldShowSliders) ...[
                        Positioned.fill(
                          child: Padding(
                            padding: safeAreaPadding,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                // ======= Brightness Slider ========
                                Positioned(
                                  right: maxWidth * 0.1,
                                  child: Obx(
                                    (context) {
                                      final bri = _canShowBrightnessSlider.valueR ? _currentBrigthnessDim.valueR : null;
                                      return _getVerticalSliderWidget(
                                        'brightness',
                                        bri,
                                        max: _maxBrightnessValue,
                                        Broken.sun_1,
                                        view,
                                      );
                                    },
                                  ),
                                ),
                                // ======= Volume Slider ========
                                Positioned(
                                  left: maxWidth * 0.1,
                                  child: ObxO(
                                    rx: _currentDeviceVolume,
                                    builder: (context, vol) => _getVerticalSliderWidget(
                                      'volume',
                                      vol,
                                      Broken.volume_high,
                                      view,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],

                      Positioned(
                        top: 0,
                        child: ObxO(
                          rx: Player.inst.isSpeedModifierActive,
                          builder: (context, modifierActive) => CustomAnimatedSwitcher(
                            duration: const Duration(milliseconds: 100),
                            child: modifierActive == true
                                ? Padding(
                                    key: const Key('longpress_active'),
                                    padding: EdgeInsets.only(top: 24.0 + topPadding),
                                    child: NamidaBgBlurClipped(
                                      blur: 2.5,
                                      child: NamidaInkWell(
                                        borderRadius: 8.0,
                                        bgColor: Colors.black.withOpacityExt(0.3),
                                        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Broken.forward,
                                              size: 20.0,
                                              color: itemsColor,
                                            ),
                                            const SizedBox(width: 6.0),
                                            Text(
                                              "${lang.speed} ${settings.player.longPressSpeed.value}x",
                                              style: context.textTheme.displayMedium?.copyWith(
                                                color: itemsColor,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  )
                                : const SizedBox(
                                    key: Key('longpress_inactive'),
                                  ),
                          ),
                        ),
                      ),

                    ],
                  ),
                ),
              )
            else if (widget.forceEnableSponsorBlock)
              skipSponsorButton,
          ],
        ),
      ),
    );

    return videoControlsWidget;
  }
}

class _ListenerEnabled extends StatelessWidget {
  final bool enabled;
  final PointerDownEventListener? onPointerDown;
  final PointerUpEventListener? onPointerUp;
  final PointerCancelEventListener? onPointerCancel;
  final HitTestBehavior behavior;
  final Widget child;

  const _ListenerEnabled({
    required this.enabled,
    this.onPointerDown,
    this.onPointerUp,
    this.onPointerCancel,
    this.behavior = HitTestBehavior.deferToChild,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return Listener(
      onPointerDown: onPointerDown,
      onPointerUp: onPointerUp,
      onPointerCancel: onPointerCancel,
      behavior: behavior,
      child: child,
    );
  }
}

class _SpeedsEditorDialog extends StatefulWidget {
  const _SpeedsEditorDialog();

  @override
  State<_SpeedsEditorDialog> createState() => __SpeedsEditorDialogState();
}

class __SpeedsEditorDialogState extends State<_SpeedsEditorDialog> {
  final speedsController = TextEditingController();
  final formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    speedsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: formKey,
      child: CustomBlurryDialog(
        title: lang.configure,
        actions: [
          NamidaTextButton(
            onTap: NamidaNavigator.inst.closeDialog,
            text: lang.done,
          ),
          NamidaButton(
            text: lang.add,
            onTap: () {
              formKey.currentState?.validate();
            },
          ),
        ],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              children: settings.player.speeds
                  .map(
                    (e) => IgnorePointer(
                      ignoring: e == 1.0,
                      child: Opacity(
                        opacity: e == 1.0 ? 0.5 : 1.0,
                        child: Container(
                          margin: const EdgeInsets.all(4.0),
                          padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 10.0),
                          decoration: BoxDecoration(
                            color: context.theme.cardTheme.color,
                            borderRadius: BorderRadius.circular(16.0.multipliedRadius),
                          ),
                          child: InkWell(
                            onTap: () {
                              if (e == 1.0) {
                                snackyy(message: lang.error); // we already ignore tap but uh
                                return;
                              }
                              if (settings.player.speeds.length <= 4) return showMinimumItemsSnack(4);

                              settings.player.speeds
                                ..remove(e)
                                ..sort();
                              settings.player.save(speeds: settings.player.speeds);
                              setState(() {});
                            },
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(e.toString()),
                                const SizedBox(width: 6.0),
                                const Icon(
                                  Broken.close_circle,
                                  size: 18.0,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  )
                  .toFixedList(),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 14.0),
              child: CustomTagTextField(
                controller: speedsController,
                hintText: lang.value,
                labelText: lang.speed,
                isNumeric: true,
                validator: (value) {
                  value ??= '';
                  if (value.isEmpty) return lang.emptyValue;
                  final sp = double.parse(speedsController.text);
                  if (settings.player.speeds.contains(sp)) return lang.error;
                  settings.player.speeds
                    ..add(sp)
                    ..sort();
                  settings.player.save(speeds: settings.player.speeds);
                  speedsController.clear();
                  setState(() {});
                  return null;
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VideoTitleSubtitleWidget extends StatelessWidget {
  final bool isLocal;

  const _VideoTitleSubtitleWidget({
    required this.isLocal,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = context.textTheme;
    return PlayableTitleSubtitleWidget(
      isYTID: !isLocal,
      builder: (title, subtitle) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null && title.isNotEmpty)
            Text(
              title,
              style: textTheme.displayLarge?.copyWith(color: const Color.fromRGBO(255, 255, 255, 0.85)),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          if (subtitle != null && subtitle.isNotEmpty)
            Text(
              subtitle,
              style: textTheme.displaySmall?.copyWith(color: const Color.fromRGBO(255, 255, 255, 0.7)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }
}

class _DropShadowWrapper extends StatelessWidget {
  final bool enabled;
  final Widget child;

  const _DropShadowWrapper({
    required this.enabled,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        CustomAnimatedSwitcher(
          duration: Duration(milliseconds: 800),
          reverseDuration: Duration(milliseconds: 500),
          child: enabled
              ? DropShadow(
                  blurRadius: 40,
                  offset: const Offset(0, 0.0),
                  bgSizePercentage: 1.1,
                  sizePercentage: 1.0,
                  child: child,
                )
              : const SizedBox(
                  key: ValueKey('video_bg_blur_disabled'),
                ),
        ),
        child,
      ],
    );
  }
}

extension _ListExt<E> on List<E> {
  E? reduceOrNull(E Function(E value, E element) combine) {
    if (isEmpty) return null;
    E value = this.first;
    for (final current in this) {
      value = combine(value, current);
    }
    return value;
  }
}
