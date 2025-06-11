import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:alchemy/utils/connectivity.dart';
import 'package:async/async.dart';
import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:alchemy/fonts/alchemy_icons.dart';
import 'package:alchemy/utils/navigator_keys.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:get_it/get_it.dart';
import 'package:just_audio/just_audio.dart';
import 'package:logging/logging.dart';
import 'package:marquee/marquee.dart';
import 'package:rxdart/rxdart.dart';
import 'package:share_plus/share_plus.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../api/cache.dart';
import '../api/deezer.dart';
import '../api/definitions.dart';
import '../api/download.dart';
import '../service/audio_service.dart';
import '../settings.dart';
import '../translations.i18n.dart';
import 'cached_image.dart';
import 'elements.dart';
import 'lyrics.dart';
import 'menu.dart';
import 'player_bar.dart';
import 'router.dart';
import 'settings_screen.dart';
import 'tiles.dart';

//So can be updated when going back from lyrics
late Function updateColor;
late Color scaffoldBackgroundColor;

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  _PlayerScreenState createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  AudioPlayerHandler audioHandler = GetIt.I<AudioPlayerHandler>();
  LinearGradient? _bgGradient;
  StreamSubscription? _mediaItemSub;
  ImageProvider? _blurImage;

  //Calculate background color
  Future _updateColor() async {
    if (audioHandler.mediaItem.value == null) return;

    if (!settings.colorGradientBackground && !settings.blurPlayerBackground) {
      return;
    }

    //BG Image
    if (settings.blurPlayerBackground) {
      setState(() {
        _blurImage = NetworkImage(
            audioHandler.mediaItem.value?.extras?['thumb'] ??
                audioHandler.mediaItem.value?.artUri);
      });
    }

    //Run in isolate
    ColorScheme palette = await ColorScheme.fromImageProvider(
        provider: CachedNetworkImageProvider(
            audioHandler.mediaItem.value?.extras?['thumb'] ??
                audioHandler.mediaItem.value?.artUri));

    //Update notification
    if (settings.blurPlayerBackground) {
      SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
          statusBarColor: palette.primary.withAlpha(65),
          systemNavigationBarColor: Color.alphaBlend(
              palette.primary.withAlpha(65), scaffoldBackgroundColor)));
    }

    //Color gradient
    if (!settings.blurPlayerBackground) {
      SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
        statusBarColor: palette.primary.withAlpha(180),
      ));
      setState(() => _bgGradient = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [palette.primary.withAlpha(180), scaffoldBackgroundColor],
          stops: const [0.0, 0.6]));
    }
  }

  @override
  void initState() {
    _updateColor;
    _mediaItemSub = audioHandler.mediaItem.listen((event) {
      _updateColor();
    });

    updateColor = _updateColor;
    super.initState();
  }

  @override
  void dispose() {
    _mediaItemSub?.cancel();
    //Fix bottom buttons
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
        systemNavigationBarColor: settings.themeData.bottomAppBarTheme.color,
        statusBarColor: Colors.transparent));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    //Avoid async gap
    scaffoldBackgroundColor = Theme.of(context).scaffoldBackgroundColor;

    return Scaffold(
      body: Container(
        padding: EdgeInsets.only(
            top: MediaQuery.of(context).padding.top,
            bottom: MediaQuery.of(context).padding.bottom),
        decoration: BoxDecoration(
            gradient: settings.blurPlayerBackground ? null : _bgGradient),
        child: Stack(
          children: [
            if (settings.blurPlayerBackground)
              ClipRect(
                child: Container(
                  decoration: BoxDecoration(
                      image: DecorationImage(
                          image: _blurImage ?? const NetworkImage(''),
                          fit: BoxFit.fill,
                          colorFilter: ColorFilter.mode(
                              Colors.black.withAlpha(65), BlendMode.dstATop))),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                    child: Container(color: Colors.transparent),
                  ),
                ),
              ),
            StreamBuilder(
              stream: StreamZip(
                  [audioHandler.playbackState, audioHandler.mediaItem]),
              builder: (BuildContext context, AsyncSnapshot snapshot) {
                //When disconnected
                if (audioHandler.mediaItem.value == null) {
                  //playerHelper.startService();
                  return const Center(
                    child: CircularProgressIndicator(),
                  );
                }

                return OrientationBuilder(
                  builder: (context, orientation) {
                    //Responsive
                    ScreenUtil.init(context, minTextAdapt: true);
                    //Landscape
                    if (orientation == Orientation.landscape) {
                      // ignore: prefer_const_constructors
                      return PlayerScreenHorizontal();
                    }
                    //Portrait
                    // ignore: prefer_const_constructors
                    return PlayerScreenVertical();
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

//Landscape
class PlayerScreenHorizontal extends StatefulWidget {
  const PlayerScreenHorizontal({super.key});

  @override
  _PlayerScreenHorizontalState createState() => _PlayerScreenHorizontalState();
}

class _PlayerScreenHorizontalState extends State<PlayerScreenHorizontal> {
  StreamSubscription? _mediaItemSub;
  AudioPlayerHandler audioPlayerHandler = GetIt.I<AudioPlayerHandler>();
  String? mediaItemId;

  @override
  void initState() {
    if (mounted) {
      setState(() {
        mediaItemId = audioPlayerHandler.mediaItem.value?.id;
      });
    }
    _mediaItemSub = audioPlayerHandler.mediaItem.listen((event) {
      if (mounted) {
        setState(() {
          mediaItemId = audioPlayerHandler.mediaItem.value?.id;
        });
      }
    });
    super.initState();
  }

  @override
  void dispose() {
    _mediaItemSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.max,
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 2),
          child: SizedBox(
            width: ScreenUtil().setWidth(160),
            child: Stack(
              children: <Widget>[
                BigAlbumArt(),
              ],
            ),
          ),
        ),
        //Right side
        SizedBox(
          width: ScreenUtil().setWidth(170),
          child: Column(
            mainAxisSize: MainAxisSize.max,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  SizedBox(
                      height: ScreenUtil().setSp(50),
                      child: GetIt.I<AudioPlayerHandler>()
                                  .mediaItem
                                  .value!
                                  .displayTitle!
                                  .length >=
                              52
                          ? Marquee(
                              text: GetIt.I<AudioPlayerHandler>()
                                  .mediaItem
                                  .value!
                                  .displayTitle!,
                              style: TextStyle(
                                  fontSize: ScreenUtil().setSp(30),
                                  fontWeight: FontWeight.bold),
                              blankSpace: 32.0,
                              startPadding: 10.0,
                              accelerationDuration: const Duration(seconds: 1),
                              pauseAfterRound: const Duration(seconds: 2),
                            )
                          : Text(
                              GetIt.I<AudioPlayerHandler>()
                                  .mediaItem
                                  .value!
                                  .displayTitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: ScreenUtil().setSp(30),
                                  fontWeight: FontWeight.bold),
                            )),
                  Container(
                    height: 4,
                  ),
                  Text(
                    GetIt.I<AudioPlayerHandler>()
                            .mediaItem
                            .value!
                            .displaySubtitle ??
                        '',
                    maxLines: 1,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.clip,
                    style: TextStyle(
                      fontSize: ScreenUtil().setSp(32),
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: const SeekBar(24.0),
              ),
              PlaybackControls(ScreenUtil().setSp(40)),
              Padding(
                  //padding: EdgeInsets.fromLTRB(4, 0, 4, 8),
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 2.0),
                    child: Row(
                      mainAxisSize: MainAxisSize.max,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: <Widget>[
                        LyricsIconButton(
                          12,
                          afterOnPressed: updateColor,
                          key: mediaItemId != null ? Key(mediaItemId!) : null,
                        ),
                        IconButton(
                          icon: Icon(
                            AlchemyIcons.download,
                            size: ScreenUtil().setWidth(12),
                            semanticLabel: 'Download'.i18n,
                          ),
                          onPressed: () async {
                            Track t = Track.fromMediaItem(
                                GetIt.I<AudioPlayerHandler>().mediaItem.value!);
                            if (await downloadManager.addOfflineTrack(t,
                                    private: false, isSingleton: true) !=
                                false) {
                              Fluttertoast.showToast(
                                  msg: 'Downloads added!'.i18n,
                                  gravity: ToastGravity.BOTTOM,
                                  toastLength: Toast.LENGTH_SHORT);
                            }
                          },
                        ),
                        const QualityInfoWidget(),
                        RepeatButton(ScreenUtil().setWidth(12)),
                        const PlayerMenuButton()
                      ],
                    ),
                  ))
            ],
          ),
        )
      ],
    );
  }
}

//Portrait
class PlayerScreenVertical extends StatefulWidget {
  const PlayerScreenVertical({super.key});

  @override
  _PlayerScreenVerticalState createState() => _PlayerScreenVerticalState();
}

class _PlayerScreenVerticalState extends State<PlayerScreenVertical> {
  final GlobalKey iconButtonKey = GlobalKey();
  StreamSubscription? _mediaItemSub;
  AudioPlayerHandler audioPlayerHandler = GetIt.I<AudioPlayerHandler>();
  String? mediaItemId;

  @override
  void initState() {
    if (mounted) {
      setState(() {
        mediaItemId = audioPlayerHandler.mediaItem.value?.id;
      });
    }
    _mediaItemSub = audioPlayerHandler.mediaItem.listen((event) {
      if (mounted) {
        setState(() {
          mediaItemId = audioPlayerHandler.mediaItem.value?.id;
        });
      }
    });
    super.initState();
  }

  @override
  void dispose() {
    _mediaItemSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.max,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        Padding(
            padding: const EdgeInsets.fromLTRB(0, 4, 16, 0),
            child: PlayerScreenTopRow(
                textSize: ScreenUtil().setSp(14),
                iconSize: ScreenUtil().setSp(18),
                textWidth: ScreenUtil().setWidth(350),
                short: true)),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
          child: SizedBox(
            height: ScreenUtil()
                .setHeight(MediaQuery.of(context).size.height * 0.35),
            child: Stack(
              children: <Widget>[
                BigAlbumArt(),
              ],
            ),
          ),
        ),
        Container(height: 4.0),
        ActionControls(24.0),
        Container(
          padding: EdgeInsets.fromLTRB(18, 0, 18, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SeekBar(8.0),
              Container(
                height: 8.0,
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 4.0),
                child: SizedBox(
                    height: ScreenUtil().setSp(18),
                    child: (GetIt.I<AudioPlayerHandler>()
                                        .mediaItem
                                        .value
                                        ?.displayTitle ??
                                    '')
                                .length >=
                            42
                        ? Marquee(
                            text: GetIt.I<AudioPlayerHandler>()
                                    .mediaItem
                                    .value
                                    ?.displayTitle ??
                                '',
                            style: TextStyle(
                                fontSize: ScreenUtil().setSp(16),
                                fontWeight: FontWeight.bold),
                            blankSpace: 32.0,
                            startPadding: 0,
                            accelerationDuration: const Duration(seconds: 1),
                            pauseAfterRound: const Duration(seconds: 2),
                          )
                        : Text(
                            GetIt.I<AudioPlayerHandler>()
                                    .mediaItem
                                    .value
                                    ?.displayTitle ??
                                '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: ScreenUtil().setSp(16),
                                fontWeight: FontWeight.bold),
                          )),
              ),
              Container(
                height: 4,
              ),
              Text(
                GetIt.I<AudioPlayerHandler>()
                        .mediaItem
                        .value
                        ?.displaySubtitle ??
                    '',
                maxLines: 1,
                textAlign: TextAlign.center,
                overflow: TextOverflow.clip,
                style: TextStyle(
                  fontSize: ScreenUtil().setSp(12),
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
        PlaybackControls(ScreenUtil().setSp(25)),
        Padding(
          padding: const EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 8.0),
          child: Row(
            mainAxisSize: MainAxisSize.max,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              LyricsIconButton(
                ScreenUtil().setSp(25) * 0.6,
                afterOnPressed: updateColor,
                key: mediaItemId != null ? Key(mediaItemId!) : null,
              ),
              IconButton(
                key: iconButtonKey,
                icon: Icon(
                  //Icons.menu,
                  AlchemyIcons.queue,
                  semanticLabel: 'Queue'.i18n,
                ),
                iconSize: ScreenUtil().setSp(25) * 0.6,
                onPressed: () async {
                  //Fix bottom buttons (Not needed anymore?)
                  SystemChrome.setSystemUIOverlayStyle(
                      const SystemUiOverlayStyle(
                          statusBarColor: Colors.transparent));

                  // Calculate the center of the icon
                  final RenderBox buttonRenderBox =
                      iconButtonKey.currentContext!.findRenderObject()
                          as RenderBox;
                  final Offset buttonOffset = buttonRenderBox
                      .localToGlobal(buttonRenderBox.size.center(Offset.zero));
                  //Navigate
                  //await Navigator.of(context).push(MaterialPageRoute(builder: (context) => QueueScreen()));
                  await Navigator.of(context).push(CircularExpansionRoute(
                      widget: const QueueScreen(),
                      //centerAlignment: Alignment.topRight,
                      centerOffset: buttonOffset)); // Expand from icon
                  //Fix colors
                  updateColor();
                },
              ),
            ],
          ),
        )
      ],
    );
  }
}

class QualityInfoWidget extends StatefulWidget {
  const QualityInfoWidget({super.key});

  @override
  _QualityInfoWidgetState createState() => _QualityInfoWidgetState();
}

class _QualityInfoWidgetState extends State<QualityInfoWidget> {
  AudioPlayerHandler audioHandler = GetIt.I<AudioPlayerHandler>();
  String value = '';
  StreamSubscription? streamSubscription;

  //Load data from native
  void _load() async {
    if (audioHandler.mediaItem.value == null) return;
    Map? data = await DownloadManager.platform.invokeMethod(
        'getStreamInfo', {'id': audioHandler.mediaItem.value!.id});
    //N/A
    if (data == null) {
      if (mounted) setState(() => value = '');
      //If not shown, try again later
      if (audioHandler.mediaItem.value?.extras?['show'] == null) {
        Future.delayed(const Duration(milliseconds: 200), _load);
      }

      return;
    }
    //Update
    StreamQualityInfo info = StreamQualityInfo.fromJson(data);
    if (mounted) {
      setState(() {
        value =
            '${info.format} ${info.bitrate(audioHandler.mediaItem.value!.duration ?? const Duration(seconds: 0))}kbps';
      });
    }
  }

  @override
  void initState() {
    _load();
    streamSubscription ??= audioHandler.mediaItem.listen((event) async {
      _load();
    });
    super.initState();
  }

  @override
  void dispose() {
    streamSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (value != '') {
      return TextButton(
        child: Text(value),
        onPressed: () {
          Navigator.of(context).push(
              MaterialPageRoute(builder: (context) => const QualitySettings()));
        },
      );
    }
    return Container();
    /*return Center(
      child: Transform.scale(
        scale: 0.75, // Adjust the scale to 75% of the original size
        child: const CircularProgressIndicator(),
      ),
    );*/
  }
}

class LyricsIconButton extends StatefulWidget {
  final double width;
  final Function? afterOnPressed;

  const LyricsIconButton(
    this.width, {
    super.key,
    this.afterOnPressed,
  });

  @override
  _LyricsIconButtonState createState() => _LyricsIconButtonState();
}

class _LyricsIconButtonState extends State<LyricsIconButton> {
  Track track =
      Track.fromMediaItem(GetIt.I<AudioPlayerHandler>().mediaItem.value!);
  bool isEnabled = false;
  LyricsFull? trackLyrics;
  AudioPlayerHandler audioHandler = GetIt.I<AudioPlayerHandler>();

  void _loadLyrics() async {
    if (!isEnabled) {
      try {
        LyricsFull newLyrics = await deezerAPI.lyrics(track);
        if (mounted && newLyrics.id != null) {
          Logger.root.info(
              'LyricsIconButton: Found lyrics for ${track.id} : ${newLyrics.id}');
          if (mounted) {
            setState(() {
              isEnabled = true;
              trackLyrics = newLyrics;
              audioHandler.mediaItem.value?.extras
                  ?.addAll({'lyrics': jsonEncode(newLyrics.toJson())});
            });
          }
        }
      } catch (e) {
        //No lyrics available.
        Logger.root.info(
            'LyricsIconButton: An error occured while loading lyrics for ${track.id} : $e');
      }
    } else {
      try {
        if (mounted) {
          setState(() {
            trackLyrics = LyricsFull.fromJson(
                jsonDecode(audioHandler.mediaItem.value?.extras?['lyrics']));
          });
        }
      } catch (e) {
        //Lyrics bug
        Logger.root.info(
            'LyricsIconButton: An error occured while loading lyrics for ${track.id} : $e');
      }
    }
  }

  @override
  void initState() {
    super.initState();

    setState(() {
      isEnabled = track.lyrics?.syncedLyrics != null ||
          track.lyrics?.unsyncedLyrics != null;
    });

    _loadLyrics();
  }

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: isEnabled
          ? 1.0
          : 0.7, // Full opacity for enabled, reduced for disabled
      child: IconButton(
        icon: Icon(
          //Icons.lyrics,
          AlchemyIcons.microphone_show,
          size: ScreenUtil().setWidth(widget.width),
          semanticLabel: 'Lyrics'.i18n,
        ),
        onPressed: isEnabled
            ? () async {
                //Fix bottom buttons
                SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
                    statusBarColor: Colors.transparent));

                await Navigator.of(context).push(MaterialPageRoute(
                    builder: (context) => LyricsScreen(
                          track: track,
                          parentLyrics: trackLyrics,
                        )));

                if (widget.afterOnPressed != null) {
                  widget.afterOnPressed!();
                }
              }
            : null, // No action when disabled
      ),
    );
  }
}

class PlayerMenuButton extends StatelessWidget {
  const PlayerMenuButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(
        //Icons.more_vert,
        Icons.menu,
        size: ScreenUtil().setWidth(12),
        semanticLabel: 'Options'.i18n,
      ),
      onPressed: () {
        Track t =
            Track.fromMediaItem(GetIt.I<AudioPlayerHandler>().mediaItem.value!);
        MenuSheet m = MenuSheet(navigateCallback: () {
          Navigator.of(context).pop();
        });
        if (GetIt.I<AudioPlayerHandler>().mediaItem.value!.extras?['show'] ==
            null) {
          m.defaultTrackMenu(t,
              context: context,
              options: [m.sleepTimer(context), m.wakelock(context)]);
        } else {
          m.defaultShowEpisodeMenu(
              Show.fromJson(jsonDecode(GetIt.I<AudioPlayerHandler>()
                  .mediaItem
                  .value!
                  .extras?['show'])),
              ShowEpisode.fromMediaItem(
                  GetIt.I<AudioPlayerHandler>().mediaItem.value!),
              context: context,
              options: [m.sleepTimer(context), m.wakelock(context)]);
        }
      },
    );
  }
}

class RepeatButton extends StatefulWidget {
  final double iconSize;
  const RepeatButton(this.iconSize, {super.key});

  @override
  _RepeatButtonState createState() => _RepeatButtonState();
}

class _RepeatButtonState extends State<RepeatButton> {
  Icon get repeatIcon {
    switch (GetIt.I<AudioPlayerHandler>().getLoopMode()) {
      case LoopMode.off:
        return Icon(
          AlchemyIcons.repeat,
          size: widget.iconSize,
          semanticLabel: 'Repeat off'.i18n,
        );
      case LoopMode.all:
        return Icon(
          AlchemyIcons.repeat_active_small,
          size: widget.iconSize,
          semanticLabel: 'Repeat'.i18n,
        );
      case LoopMode.one:
        return Icon(
          AlchemyIcons.repeat_one,
          size: widget.iconSize,
          semanticLabel: 'Repeat one'.i18n,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: repeatIcon,
      onPressed: () async {
        await GetIt.I<AudioPlayerHandler>().changeRepeat();
        setState(() {});
      },
    );
  }
}

class ActionControls extends StatefulWidget {
  final double iconSize;
  final Track? track;
  const ActionControls(this.iconSize, {this.track, super.key});

  @override
  _ActionControls createState() => _ActionControls();
}

class _ActionControls extends State<ActionControls> {
  AudioPlayerHandler audioHandler = GetIt.I<AudioPlayerHandler>();
  late Track t;

  Icon get libraryIcon {
    if (audioHandler.mediaItem.value != null
        ? cache.checkTrackFavorite(t)
        : false) {
      return Icon(
        AlchemyIcons.heart_fill,
        size: widget.iconSize,
        semanticLabel: 'Unlove'.i18n,
      );
    }
    return Icon(
      AlchemyIcons.heart,
      size: widget.iconSize,
      semanticLabel: 'Love'.i18n,
    );
  }

  @override
  void initState() {
    if (mounted) {
      setState(() {
        t = widget.track ??
            (audioHandler.mediaItem.value != null
                ? Track.fromMediaItem(audioHandler.mediaItem.value!)
                : Track());
      });
    }
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    String? id = t.id;
    return Container(
      padding: EdgeInsets.only(top: 8),
      child: Row(
        mainAxisSize: MainAxisSize.max,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          IconButton(
              onPressed: () async {
                Share.share('https://deezer.com/track/$id');
              },
              icon: Icon(
                AlchemyIcons.share_android,
                size: widget.iconSize,
                semanticLabel: 'Share'.i18n,
              )),
          Container(
            margin: EdgeInsets.symmetric(horizontal: 24),
            padding: EdgeInsets.all(2),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                  color: Settings.secondaryText.withAlpha(230), width: 0.5),
            ),
            alignment: Alignment.center,
            child: IconButton(
              icon: Icon(
                AlchemyIcons.more_vert,
                size: widget.iconSize * 1.25,
                semanticLabel: 'Options'.i18n,
              ),
              onPressed: () {
                MenuSheet m = MenuSheet(navigateCallback: () {
                  Navigator.of(context).pop();
                });
                if (audioHandler.mediaItem.value?.extras?['show'] == null) {
                  m.defaultTrackMenu(t,
                      context: context,
                      options: [m.sleepTimer(context), m.wakelock(context)]);
                } else {
                  m.defaultShowEpisodeMenu(
                      Show.fromJson(jsonDecode(
                          audioHandler.mediaItem.value?.extras?['show'])),
                      ShowEpisode.fromMediaItem(audioHandler.mediaItem.value!),
                      context: context,
                      options: [m.sleepTimer(context), m.wakelock(context)]);
                }
              },
            ),
          ),
          IconButton(
            icon: libraryIcon,
            onPressed: () async {
              cache.libraryTracks ??= [];

              if (cache.checkTrackFavorite(t)) {
                //Remove from library
                setState(() => cache.libraryTracks?.remove(t.id));
                await deezerAPI.removeFavorite(t.id ?? '');
                await cache.save();
              } else {
                //Add
                setState(() => cache.libraryTracks?.add(t.id ?? ''));
                await deezerAPI.addFavoriteTrack(t.id ?? '');
                await cache.save();
              }
            },
          )
        ],
      ),
    );
  }
}

class PlaybackControls extends StatefulWidget {
  final double iconSize;
  const PlaybackControls(this.iconSize, {super.key});

  @override
  _PlaybackControlsState createState() => _PlaybackControlsState();
}

class _PlaybackControlsState extends State<PlaybackControls> {
  AudioPlayerHandler audioHandler = GetIt.I<AudioPlayerHandler>();

  @override
  Widget build(BuildContext context) {
    final queueState = audioHandler.queueState;
    bool shuffleModeEnabled =
        queueState.shuffleMode == AudioServiceShuffleMode.all;
    return Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            mainAxisSize: MainAxisSize.max,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              RepeatButton(widget.iconSize * 0.6),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.max,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  /*IconButton(
              icon: Icon(
                AlchemyIcons.angry_face,
                size: widget.iconSize * 0.44,
                semanticLabel: 'Dislike'.i18n,
              ),
              onPressed: () async {
                await deezerAPI.dislikeTrack(audioHandler.mediaItem.value!.id);
                if (audioHandler.queueState.hasNext) {
                  audioHandler.skipToNext();
                }
              }),*/
                  Padding(
                    padding: EdgeInsets.only(right: 12),
                    child: PrevNextButton(widget.iconSize * 0.8, prev: true),
                  ),
                  PlayPauseButton(widget.iconSize),
                  Padding(
                    padding: EdgeInsets.only(left: 12),
                    child: PrevNextButton(widget.iconSize * 0.8),
                  )
                ],
              ),
              IconButton(
                icon: Icon(
                  //cons.shuffle,
                  shuffleModeEnabled
                      ? AlchemyIcons.shuffle_active_small
                      : AlchemyIcons.shuffle,
                  semanticLabel: 'Shuffle'.i18n,
                  color: Colors.white,
                  size: widget.iconSize * 0.6,
                ),
                onPressed: () async {
                  await audioHandler.toggleShuffle();
                  setState(() {
                    shuffleModeEnabled = true;
                  });
                },
              )
            ]));
  }
}

class BigAlbumArt extends StatefulWidget {
  const BigAlbumArt({super.key});

  @override
  _BigAlbumArtState createState() => _BigAlbumArtState();
}

class _BigAlbumArtState extends State<BigAlbumArt> with WidgetsBindingObserver {
  final AudioPlayerHandler audioHandler = GetIt.I<AudioPlayerHandler>();
  List<ZoomableImage> _imageList = [];
  late PageController _pageController;
  StreamSubscription? _currentItemAndQueueSub;
  bool _isVisible = false;
  bool _changeTrackOnPageChange = true;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(
      initialPage: audioHandler.currentIndex,
    );

    _imageList = _getImageList(audioHandler.queue.value);

    _currentItemAndQueueSub =
        Rx.combineLatest2<MediaItem?, List<MediaItem>, void>(
      audioHandler.mediaItem,
      audioHandler.queue,
      (mediaItem, queue) {
        if (queue.isNotEmpty) {
          _handleMediaItemChange(mediaItem);
          if (_didQueueChange(queue)) {
            setState(() {
              _imageList = _getImageList(queue);
            });
          }
        }
      },
    ).listen((_) {});

    WidgetsBinding.instance.addObserver(this);
  }

  List<ZoomableImage> _getImageList(List<MediaItem> queue) {
    return queue
        .map((item) => ZoomableImage(url: item.artUri?.toString() ?? ''))
        .toList();
  }

  bool _didQueueChange(List<MediaItem> newQueue) {
    if (newQueue.length != _imageList.length) {
      // Length changed = new queue
      return true;
    }
    for (int i = 0; i < newQueue.length; i++) {
      if (newQueue[i].artUri?.toString() != _imageList[i].url) {
        // An item changed on this position = new queue
        return true;
      }
    }
    // No changes = same queue
    return false;
  }

  void _handleMediaItemChange(MediaItem? item) async {
    final targetItemId = item?.id ?? '';
    final targetPage =
        audioHandler.queue.value.indexWhere((item) => item.id == targetItemId);
    if (targetPage == -1) return;

    // No need to animating to the same page
    if (_pageController.page?.round() == targetPage) return;

    if (_isVisible) {
      // Widget is visible, animate to the target page
      _changeTrackOnPageChange = false;
      await _pageController
          .animateToPage(
        targetPage,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      )
          .then((_) {
        _changeTrackOnPageChange = true;
      });
    } else {
      // Widget is not visible, jump to the target page without animation
      _changeTrackOnPageChange = false;
      _pageController.jumpToPage(targetPage);
      _changeTrackOnPageChange = true;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _currentItemAndQueueSub?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    setState(() {
      _isVisible = state == AppLifecycleState.resumed;
    });
  }

  @override
  Widget build(BuildContext context) {
    return VisibilityDetector(
      key: const Key('big_album_art'),
      onVisibilityChanged: (VisibilityInfo info) {
        if (mounted) {
          setState(() {
            _isVisible = info.visibleFraction > 0.0;
          });
        }
      },
      child: GestureDetector(
        onVerticalDragUpdate: (DragUpdateDetails details) {
          if (details.delta.dy > 16) {
            Navigator.of(context).pop();
          }
        },
        child: PageView(
          controller: _pageController,
          onPageChanged: (int index) {
            if (_changeTrackOnPageChange) {
              // Only trigger if the page change is caused by user swiping
              audioHandler.skipToQueueItem(index);
            }
          },
          children: _imageList,
        ),
      ),
    );
  }
}

//Top row containing QueueSource, queue...
class PlayerScreenTopRow extends StatelessWidget {
  final double? textSize;
  final double? iconSize;
  final double? textWidth;
  final bool? short;
  final GlobalKey iconButtonKey = GlobalKey();
  PlayerScreenTopRow(
      {super.key, this.textSize, this.iconSize, this.textWidth, this.short});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.max,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        IconButton(
          icon: const Icon(
            Icons.keyboard_arrow_down_sharp,
          ),
          iconSize: iconSize ?? ScreenUtil().setSp(52),
          splashRadius: iconSize ?? ScreenUtil().setWidth(52),
          onPressed: () async {
            // Navigate back
            Navigator.pop(context);
          },
        ),
        Expanded(
          child: SizedBox(
            width: textWidth ?? ScreenUtil().setWidth(800),
            child: Text(
              (short ?? false)
                  ? (GetIt.I<AudioPlayerHandler>().queueSource?.text ?? '')
                  : 'Playing from:'.i18n +
                      ' ' +
                      (GetIt.I<AudioPlayerHandler>().queueSource?.text ?? ''),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.left,
              style: TextStyle(fontSize: textSize ?? ScreenUtil().setSp(16)),
            ),
          ),
        ),
      ],
    );
  }
}

class SeekBar extends StatefulWidget {
  final double relativeTextSize;
  const SeekBar(this.relativeTextSize, {super.key});

  @override
  _SeekBarState createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  AudioPlayerHandler audioHandler = GetIt.I<AudioPlayerHandler>();
  bool _seeking = false;
  double _pos = 0;

  double get position {
    if (_seeking) return _pos;
    double p =
        audioHandler.playbackState.value.position.inMilliseconds.toDouble();
    if (p > duration) return duration;
    return p;
  }

  //Duration to mm:ss
  String _timeString(double pos) {
    Duration d = Duration(milliseconds: pos.toInt());
    return "${d.inMinutes}:${d.inSeconds.remainder(60).toString().padLeft(2, '0')}";
  }

  double get duration {
    if (audioHandler.mediaItem.value == null) return 1.0;
    return audioHandler.mediaItem.value?.duration?.inMilliseconds.toDouble() ??
        0;
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: Stream.periodic(const Duration(milliseconds: 250)),
      builder: (BuildContext context, AsyncSnapshot snapshot) {
        return Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.symmetric(
                      vertical: 4.0, horizontal: 4.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      Text(
                        _timeString(position),
                        style: TextStyle(
                            fontSize:
                                ScreenUtil().setSp(widget.relativeTextSize)),
                      ),
                      Text(
                        _timeString(duration),
                        style: TextStyle(
                            fontSize:
                                ScreenUtil().setSp(widget.relativeTextSize)),
                      )
                    ],
                  ),
                ),
                SizedBox(
                  height: 32.0,
                  child: Slider(
                    focusNode: FocusNode(
                        canRequestFocus: false,
                        skipTraversal:
                            true), // Don't focus on Slider - it doesn't work (and not needed)
                    value: position,
                    max: duration,
                    onChangeStart: (double d) {
                      setState(() {
                        _seeking = true;
                        _pos = d;
                      });
                    },
                    onChanged: (double d) {
                      setState(() {
                        _pos = d;
                      });
                    },
                    onChangeEnd: (double d) async {
                      await audioHandler
                          .seek(Duration(milliseconds: d.round()));
                      setState(() {
                        _pos = d;
                        _seeking = false;
                      });
                    },
                  ),
                )
              ],
            ));
      },
    );
  }
}

class QueueScreen extends StatefulWidget {
  const QueueScreen({super.key});

  @override
  _QueueScreenState createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> with WidgetsBindingObserver {
  AudioPlayerHandler audioHandler = GetIt.I<AudioPlayerHandler>();
  StreamSubscription? _queueStateSub;
  ScrollController? _scrollController;

  @override
  void initState() {
    _scrollController = ScrollController();
    super.initState();
    final currentIndex = audioHandler.queueState.queueIndex ?? 0;
    if (currentIndex > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollController?.animateTo(
          currentIndex * 62.0, // Estimated TrackTile height
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      });
    }
  }

  @override
  void dispose() {
    _queueStateSub?.cancel();
    _scrollController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final queueState = audioHandler.queueState;
    final shuffleModeEnabled =
        queueState.shuffleMode == AudioServiceShuffleMode.all;

    return Scaffold(
      appBar: FreezerAppBar(
        'Queue'.i18n,
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 4, 0, 0),
            child: IconButton(
              icon: Icon(
                //cons.shuffle,
                AlchemyIcons.plus,
                semanticLabel: 'Create playlist'.i18n,
              ),
              onPressed: () async {
                if (!(await isConnected())) {
                  Fluttertoast.showToast(
                      msg: 'Cannot create playlists in offline mode'.i18n,
                      gravity: ToastGravity.BOTTOM);
                  return;
                }
                MenuSheet m = MenuSheet();
                if (mounted) {
                  await m.createPlaylist(context);
                }
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 4, 0, 0),
            child: IconButton(
              icon: Icon(
                //cons.shuffle,
                shuffleModeEnabled
                    ? AlchemyIcons.shuffle_active_small
                    : AlchemyIcons.shuffle,
                semanticLabel: 'Shuffle'.i18n,
              ),
              onPressed: () async {
                await audioHandler.toggleShuffle();
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 4, 16, 0),
            child: IconButton(
              icon: Icon(
                AlchemyIcons.trash,
                semanticLabel: 'Clear all'.i18n,
              ),
              onPressed: () {
                audioHandler.clearQueue();
                mainNavigatorKey.currentState!
                    .popUntil((route) => route.isFirst);
              },
            ),
          )
        ],
      ),
      body: shuffleModeEnabled // No manual re-ordring in shuffle mode
          ? ListView(
              controller: _scrollController,
              children: List.generate(
                  queueState.queue.length,
                  (int index) => TrackTile(
                        Track.fromMediaItem(queueState.queue[index]),
                        onTap: () async {
                          await audioHandler.skipToQueueItem(index);
                          if (context.mounted) Navigator.of(context).pop();
                        },
                        key: Key(queueState.queue[index].id + index.toString()),
                        trailing: IconButton(
                          icon: Icon(
                            Icons.close,
                            semanticLabel: 'Close'.i18n,
                          ),
                          onPressed: () async {
                            await audioHandler
                                .removeQueueItem(queueState.queue[index]);
                            if (mounted) {
                              setState(() {
                                queueState.queue;
                              });
                            }
                          },
                        ),
                      )),
            )
          : ReorderableListView(
              scrollController: _scrollController,
              onReorder: (int oldIndex, int newIndex) {
                if (oldIndex == newIndex) return;
                setState(() {
                  if (newIndex > oldIndex) newIndex -= 1;
                });
                audioHandler.moveQueueItem(oldIndex, newIndex);
              },
              children: List.generate(
                  queueState.queue.length,
                  (int index) => TrackTile(
                        Track.fromMediaItem(queueState.queue[index]),
                        onTap: () async {
                          await audioHandler.skipToQueueItem(index);
                        },
                        key: Key(queueState.queue[index].id + index.toString()),
                        trailing: IconButton(
                          icon: Icon(
                            Icons.close,
                            semanticLabel: 'Close'.i18n,
                          ),
                          onPressed: () async {
                            await audioHandler
                                .removeQueueItem(queueState.queue[index]);
                            if (mounted) {
                              setState(() {
                                queueState.queue;
                              });
                            }
                          },
                        ),
                      ))),
    );
  }
}
