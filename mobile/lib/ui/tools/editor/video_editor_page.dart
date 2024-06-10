import 'dart:io';
import "dart:math";

import 'package:flutter/material.dart';
import "package:logging/logging.dart";
import 'package:path/path.dart' as path;
import "package:pedantic/pedantic.dart";
import "package:photo_manager/photo_manager.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/db/files_db.dart";
import "package:photos/ente_theme_data.dart";
import "package:photos/events/local_photos_updated_event.dart";
import "package:photos/generated/l10n.dart";
import "package:photos/models/file/file.dart";
import "package:photos/services/sync_service.dart";
import "package:photos/ui/tools/editor/export_video_service.dart";
import 'package:photos/ui/tools/editor/video_crop_page.dart';
import "package:photos/ui/tools/editor/video_editor/video_editor_bottom_action.dart";
import "package:photos/ui/tools/editor/video_editor/video_editor_main_actions.dart";
import "package:photos/ui/tools/editor/video_editor/video_editor_navigation_options.dart";
import "package:photos/ui/tools/editor/video_editor/video_editor_player_control.dart";
import "package:photos/ui/tools/editor/video_rotate_page.dart";
import "package:photos/ui/tools/editor/video_trim_page.dart";
import "package:photos/ui/viewer/file/detail_page.dart";
import "package:photos/utils/dialog_util.dart";
import "package:photos/utils/navigation_util.dart";
import "package:photos/utils/toast_util.dart";
import "package:video_editor/video_editor.dart";

class VideoEditorPage extends StatefulWidget {
  const VideoEditorPage({
    super.key,
    required this.file,
    required this.ioFile,
    required this.detailPageConfig,
  });

  final EnteFile file;
  final File ioFile;
  final DetailPageConfiguration detailPageConfig;

  @override
  State<VideoEditorPage> createState() => _VideoEditorPageState();
}

class _VideoEditorPageState extends State<VideoEditorPage> {
  final _exportingProgress = ValueNotifier<double>(0.0);
  final _isExporting = ValueNotifier<bool>(false);
  final _logger = Logger("VideoEditor");

  VideoEditorController? _controller;

  @override
  void initState() {
    super.initState();

    Future.microtask(() {
      _controller = VideoEditorController.file(
        widget.ioFile,
        minDuration: const Duration(seconds: 1),
        cropStyle: CropGridStyle(
          selectedBoundariesColor:
              const ColorScheme.dark().videoPlayerPrimaryColor,
        ),
        trimStyle: TrimSliderStyle(
          onTrimmedColor: const ColorScheme.dark().videoPlayerPrimaryColor,
          onTrimmingColor: const ColorScheme.dark().videoPlayerPrimaryColor,
          background: Theme.of(context).brightness == Brightness.light
              ? const Color(0xFFF5F5F5)
              : const Color(0xFF252525),
          positionLineColor: Theme.of(context).brightness == Brightness.light
              ? const Color(0xFF424242)
              : const Color(0xFFFFFFFF),
          lineColor: (Theme.of(context).brightness == Brightness.light
                  ? const Color(0xFF424242)
                  : const Color(0xFFFFFFFF))
              .withOpacity(0.6),
        ),
      );

      _controller!.initialize().then((_) => setState(() {})).catchError(
        (error) {
          // handle minumum duration bigger than video duration error
          Navigator.pop(context);
        },
        test: (e) => e is VideoMinDurationError,
      );
    });
  }

  @override
  void dispose() async {
    _exportingProgress.dispose();
    _isExporting.dispose();
    _controller?.dispose().ignore();
    ExportService.dispose().ignore();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(
          elevation: 0,
          toolbarHeight: 0,
        ),
        body: _controller != null && _controller!.initialized
            ? SafeArea(
                child: Stack(
                  children: [
                    Column(
                      children: [
                        Expanded(
                          child: Column(
                            children: [
                              Expanded(
                                child: Hero(
                                  tag: "video-editor-preview",
                                  child: CropGridViewer.preview(
                                    controller: _controller!,
                                  ),
                                ),
                              ),
                              VideoEditorPlayerControl(
                                controller: _controller!,
                              ),
                              VideoEditorMainActions(
                                children: [
                                  VideoEditorBottomAction(
                                    label: "Trim",
                                    svgPath:
                                        "assets/video-editor/video-editor-trim-action.svg",
                                    onPressed: () => Navigator.push(
                                      context,
                                      MaterialPageRoute<void>(
                                        builder: (context) => VideoTrimPage(
                                          controller: _controller!,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 40),
                                  VideoEditorBottomAction(
                                    label: "Crop",
                                    svgPath:
                                        "assets/video-editor/video-editor-crop-action.svg",
                                    onPressed: () => Navigator.push(
                                      context,
                                      MaterialPageRoute<void>(
                                        builder: (context) => VideoCropPage(
                                          controller: _controller!,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 40),
                                  VideoEditorBottomAction(
                                    label: "Rotate",
                                    svgPath:
                                        "assets/video-editor/video-editor-rotate-action.svg",
                                    onPressed: () => Navigator.push(
                                      context,
                                      MaterialPageRoute<void>(
                                        builder: (context) => VideoRotatePage(
                                          controller: _controller!,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 40),
                              VideoEditorNavigationOptions(
                                secondaryText: "Save copy",
                                onSecondaryPressed: () {
                                  exportVideo();
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              )
            : const Center(child: CircularProgressIndicator()),
      ),
    );
  }

  void exportVideo() async {
    _exportingProgress.value = 0;
    _isExporting.value = true;
    final dialog = createProgressDialog(context, S.of(context).savingEdits);
    await dialog.show();

    final config = VideoFFmpegVideoEditorConfig(
      _controller!,
      format: VideoExportFormat.mp4,
      // commandBuilder: (config, videoPath, outputPath) {
      //   final List<String> filters = config.getExportFilters();
      //   filters.add('hflip'); // add horizontal flip

      //   return '-i $videoPath ${config.filtersCmd(filters)} -preset ultrafast $outputPath';
      // },
    );

    try {
      await ExportService.runFFmpegCommand(
        await config.getExecuteConfig(),
        onProgress: (stats) {
          _exportingProgress.value =
              config.getFFmpegProgress(stats.getTime().toInt());
        },
        onError: (e, s) => _logger.severe("Error exporting video", e, s),
        onCompleted: (result) async {
          _isExporting.value = false;
          if (!mounted) return;

          final fileName = path.basenameWithoutExtension(widget.file.title!) +
              "_edited_" +
              DateTime.now().microsecondsSinceEpoch.toString() +
              ".mp4";
          //Disabling notifications for assets changing to insert the file into
          //files db before triggering a sync.
          await PhotoManager.stopChangeNotify();

          try {
            final AssetEntity? newAsset =
                await (PhotoManager.editor.saveVideo(result, title: fileName));
            result.deleteSync();
            (await newAsset?.file)
                ?.setLastModifiedSync(widget.ioFile.lastModifiedSync());
            final newFile = await EnteFile.fromAsset(
              widget.file.deviceFolder ?? '',
              newAsset!,
            );

            newFile.generatedID =
                await FilesDB.instance.insertAndGetId(widget.file);
            Bus.instance
                .fire(LocalPhotosUpdatedEvent([newFile], source: "editSave"));
            unawaited(SyncService.instance.sync());
            showShortToast(context, S.of(context).editsSaved);
            _logger.info("Original file " + widget.file.toString());
            _logger.info("Saved edits to file " + newFile.toString());
            final existingFiles = widget.detailPageConfig.files;
            final files = (await widget.detailPageConfig.asyncLoader!(
              existingFiles[existingFiles.length - 1].creationTime!,
              existingFiles[0].creationTime!,
            ))
                .files;
            // the index could be -1 if the files fetched doesn't contain the newly
            // edited files
            int selectionIndex = files
                .indexWhere((file) => file.generatedID == newFile.generatedID);
            if (selectionIndex == -1) {
              files.add(newFile);
              selectionIndex = files.length - 1;
            }
            await dialog.hide();

            replacePage(
              context,
              DetailPage(
                widget.detailPageConfig.copyWith(
                  files: files,
                  selectedIndex: min(selectionIndex, files.length - 1),
                ),
              ),
            );
          } catch (_) {
            await dialog.hide();
          }
        },
      );
    } catch (_) {
      await dialog.hide();
    }
  }
}
