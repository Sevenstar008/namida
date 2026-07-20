part of 'settings_controller.dart';

class _ExtraSettings with SettingsFileWriter {
  _ExtraSettings._internal();

  final selectedLibraryTab = LibraryTab.tracks.obs;
  final staticLibraryTab = LibraryTab.tracks.obs;
  final autoLibraryTab = true.obs;
  final preferredSearchType = RxnF<SearchType>(fallback: SearchType.auto);

  bool? tapToScroll;
  bool? enhancedDragToScroll;
  bool? smoothScrolling;
  bool? floatingArtworkEffect;
  bool? tiltingCardsEffect;
  bool? mediaWaveHaptic;
  bool? artistAlbumsExpanded;
  bool? artistSinglesExpanded;
  bool? ytStyleButtonSwitcher;

  int lastPlayedIndex = 0;

  int? audioConfigPageIndex;

  bool windowMaximized = false;
  Rect? windowBounds;

  void save({
    LibraryTab? selectedLibraryTab,
    LibraryTab? staticLibraryTab,
    bool? autoLibraryTab,
    SearchType? preferredSearchType,
    bool? tapToScroll,
    bool? enhancedDragToScroll,
    bool? smoothScrolling,
    bool? floatingArtworkEffect,
    bool? tiltingCardsEffect,
    bool? mediaWaveHaptic,
    bool? artistAlbumsExpanded,
    bool? artistSinglesExpanded,
    bool? ytStyleButtonSwitcher,
    int? lastPlayedIndex,
    int? audioConfigPageIndex,
    Rect? windowBounds,
    bool? windowMaximized,
  }) {
    if (selectedLibraryTab != null) this.selectedLibraryTab.value = selectedLibraryTab;
    if (staticLibraryTab != null) this.staticLibraryTab.value = staticLibraryTab;
    if (autoLibraryTab != null) this.autoLibraryTab.value = autoLibraryTab;
    if (preferredSearchType != null) this.preferredSearchType.value = preferredSearchType;
    if (tapToScroll != null) this.tapToScroll = tapToScroll;
    if (enhancedDragToScroll != null) this.enhancedDragToScroll = enhancedDragToScroll;
    if (smoothScrolling != null) this.smoothScrolling = smoothScrolling;
    if (floatingArtworkEffect != null) this.floatingArtworkEffect = floatingArtworkEffect;
    if (tiltingCardsEffect != null) this.tiltingCardsEffect = tiltingCardsEffect;
    if (mediaWaveHaptic != null) this.mediaWaveHaptic = mediaWaveHaptic;
    if (artistAlbumsExpanded != null) this.artistAlbumsExpanded = artistAlbumsExpanded;
    if (artistSinglesExpanded != null) this.artistSinglesExpanded = artistSinglesExpanded;
    if (ytStyleButtonSwitcher != null) this.ytStyleButtonSwitcher = ytStyleButtonSwitcher;
    if (lastPlayedIndex != null) this.lastPlayedIndex = lastPlayedIndex;
    if (audioConfigPageIndex != null) this.audioConfigPageIndex = audioConfigPageIndex;
    if (windowBounds != null) this.windowBounds = windowBounds;
    if (windowMaximized != null) this.windowMaximized = windowMaximized;
    _writeToStorage();
  }

  @override
  void applyKuruSettings() {
    selectedLibraryTab.value = LibraryTab.playlists;
    staticLibraryTab.value = LibraryTab.playlists;
  }

  Future<void> prepareSettingsFile() async {
    final json = await prepareSettingsFile_();
    if (json is! Map) return;

    try {
      final autoLibraryTabFinal = json['autoLibraryTab'] ?? autoLibraryTab.value;
      staticLibraryTab.value = LibraryTab.values.getEnum(json['staticLibraryTab']) ?? staticLibraryTab.value;
      selectedLibraryTab.value = autoLibraryTabFinal
          ? LibraryTab.values.getEnum(json['selectedLibraryTab']) ?? selectedLibraryTab.value
          : LibraryTab.values.getEnum(json['staticLibraryTab']) ?? staticLibraryTab.value;
      autoLibraryTab.value = autoLibraryTabFinal;
      preferredSearchType.value = SearchType.values.getEnum(json['preferredSearchType']) ?? preferredSearchType.value;

      tapToScroll = json['tapToScroll'] ?? tapToScroll;
      enhancedDragToScroll = json['enhancedDragToScroll'] ?? enhancedDragToScroll;
      smoothScrolling = json['smoothScrolling'] ?? smoothScrolling;
      floatingArtworkEffect = json['floatingArtworkEffect'] ?? floatingArtworkEffect;
      tiltingCardsEffect = json['tiltingCardsEffect'] ?? tiltingCardsEffect;
      mediaWaveHaptic = json['mediaWaveHaptic'] ?? mediaWaveHaptic;
      artistAlbumsExpanded = json['artistAlbumsExpanded'] ?? artistAlbumsExpanded;
      artistSinglesExpanded = json['artistSinglesExpanded'] ?? artistSinglesExpanded;
      ytStyleButtonSwitcher = json['ytStyleButtonSwitcher'] ?? ytStyleButtonSwitcher;
      lastPlayedIndex = json['lastPlayedIndex'] ?? lastPlayedIndex;
      audioConfigPageIndex = json['audioConfigPageIndex'] ?? audioConfigPageIndex;

      final windowBoundsJson = json['windowBounds'];
      if (windowBoundsJson is Map) {
        this.windowBounds = Rect.fromLTRB(
          windowBoundsJson['l'],
          windowBoundsJson['t'],
          windowBoundsJson['r'],
          windowBoundsJson['b'],
        );
      }
      windowMaximized = json['windowMaximized'] ?? windowMaximized;
    } catch (e, st) {
      printy(e, isError: true);
      logger.report(e, st);
    }
  }

  @override
  Object get jsonToWrite => <String, dynamic>{
    'selectedLibraryTab': selectedLibraryTab.value.name,
    'staticLibraryTab': staticLibraryTab.value.name,
    'autoLibraryTab': autoLibraryTab.value,
    'preferredSearchType': ?preferredSearchType.value?.name,
    if (tapToScroll != null) 'tapToScroll': tapToScroll,
    if (enhancedDragToScroll != null) 'enhancedDragToScroll': enhancedDragToScroll,
    if (smoothScrolling != null) 'smoothScrolling': smoothScrolling,
    if (floatingArtworkEffect != null) 'floatingArtworkEffect': floatingArtworkEffect,
    if (tiltingCardsEffect != null) 'tiltingCardsEffect': tiltingCardsEffect,
    if (mediaWaveHaptic != null) 'mediaWaveHaptic': mediaWaveHaptic,
    if (artistAlbumsExpanded != null) 'artistAlbumsExpanded': artistAlbumsExpanded,
    if (artistSinglesExpanded != null) 'artistSinglesExpanded': artistSinglesExpanded,
    if (ytStyleButtonSwitcher != null) 'ytStyleButtonSwitcher': ytStyleButtonSwitcher,
    'lastPlayedIndex': lastPlayedIndex,
    'audioConfigPageIndex': ?audioConfigPageIndex,
    if (windowBounds != null)
      'windowBounds': {
        'l': windowBounds!.left,
        't': windowBounds!.top,
        'r': windowBounds!.right,
        'b': windowBounds!.bottom,
      },
    'windowMaximized': windowMaximized,
  };

  Future<void> _writeToStorage() async => await writeToStorage();

  @override
  String get filePath => AppPaths.SETTINGS_EXTRA;
}
