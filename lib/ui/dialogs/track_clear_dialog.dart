// ignore_for_file: use_build_context_synchronously

import 'dart:io';

import 'package:flutter/material.dart';

import 'package:namida/class/track.dart';
import 'package:namida/controller/edit_delete_controller.dart';
import 'package:namida/controller/indexer_controller.dart';
import 'package:namida/controller/lyrics_search_utils/lrc_search_utils_selectable.dart';
import 'package:namida/controller/navigator_controller.dart';
import 'package:namida/controller/thumbnail_manager.dart';
import 'package:namida/core/constants.dart';
import 'package:namida/core/extensions.dart';
import 'package:namida/core/icon_fonts/broken_icons.dart';
import 'package:namida/core/translations/language.dart';
import 'package:namida/ui/widgets/custom_widgets.dart';

void showTrackClearDialog(List<Selectable> tracksPre, Color colorScheme) async {
  final tracksMap = <Track, bool>{};
  int videosTotalSize = 0;
  int audiosTotalSize = 0;
  int lyricsTotalSize = 0;
  int imagesTotalSize = 0;

  for (var item in tracksPre) {
    var tr = item.track;
    if (tracksMap[tr] == null) {
      tracksMap[tr] = true;

      final artworkFile = File(tr.pathToImage);
      if (await artworkFile.exists()) imagesTotalSize += await artworkFile.fileSize() ?? 0;

      final lrcUtils = LrcSearchUtilsSelectable(kDummyExtendedTrack, tr);
      final cachedLRCFile = lrcUtils.cachedLRCFile;
      final cachedTxtFile = lrcUtils.cachedTxtFile;
      if (await cachedLRCFile.exists()) lyricsTotalSize += await cachedLRCFile.fileSize() ?? 0;
      if (await cachedTxtFile.exists()) lyricsTotalSize += await cachedTxtFile.fileSize() ?? 0;
    }
  }

  final tracks = tracksMap.keys.toList();
  final isSingle = tracks.length == 1;

  NamidaNavigator.inst.navigateDialog(
    colorScheme: colorScheme,
    dialogBuilder: (theme) => CustomBlurryDialog(
      theme: theme,
      normalTitleStyle: true,
      icon: Broken.broom,
      title: isSingle ? lang.clearTrackItem : lang.clearTrackItemMultiple(number: tracks.length),
      child: Column(
        children: [
          if (videosTotalSize > 0)
            CustomListTile(
              passedColor: colorScheme,
              title: isSingle ? lang.videoCacheFile : lang.videoCacheFiles,
              subtitle: videosTotalSize.fileSizeFormatted,
              icon: Broken.video_square,
              onTap: () async {
                await EditDeleteController.inst.deleteCachedVideos(tracks);
                NamidaNavigator.inst.closeDialog();
              },
            ),
          if (audiosTotalSize > 0)
            CustomListTile(
              passedColor: colorScheme,
              title: lang.audioCache,
              subtitle: audiosTotalSize.fileSizeFormatted,
              icon: Broken.audio_square,
              onTap: () async {
                await EditDeleteController.inst.deleteCachedAudios(tracks);
                NamidaNavigator.inst.closeDialog();
              },
            ),
          if (lyricsTotalSize > 0)
            CustomListTile(
              passedColor: colorScheme,
              title: lang.lyrics,
              icon: Broken.document,
              onTap: () async {
                await EditDeleteController.inst.deleteLRCLyrics(tracks);
                await EditDeleteController.inst.deleteTXTLyrics(tracks);
                NamidaNavigator.inst.closeDialog();
              },
            ),
          if (imagesTotalSize > 0)
            CustomListTile(
              passedColor: colorScheme,
              title: isSingle ? lang.artwork : lang.artworks,
              icon: Broken.image,
              onTap: () async {
                await EditDeleteController.inst.deleteArtwork(tracks);
                NamidaNavigator.inst.closeDialog();
              },
            ),
        ],
      ),
    ),
  );
}
