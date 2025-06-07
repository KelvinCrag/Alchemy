import 'dart:async';
import 'dart:math';

import 'package:alchemy/fonts/alchemy_icons.dart';
import 'package:flutter/material.dart';
import 'package:fluttericon/octicons_icons.dart';
import 'package:get_it/get_it.dart';
import 'package:alchemy/settings.dart';
import 'package:alchemy/ui/details_screens.dart';
import 'package:alchemy/ui/library_screen.dart';
import 'package:alchemy/ui/menu.dart';
import 'package:lottie/lottie.dart';
import 'package:figma_squircle/figma_squircle.dart';
import 'package:share_plus/share_plus.dart';

import '../api/deezer.dart';
import '../api/definitions.dart';
import '../api/download.dart';
import '../service/audio_service.dart';
import '../translations.i18n.dart';
import 'cached_image.dart';

class TrackTile extends StatefulWidget {
  final Track track;
  final VoidCallback? onTap;
  final VoidCallback? onHold;
  final Widget? trailing;
  final EdgeInsetsGeometry? padding;

  const TrackTile(this.track,
      {this.onTap, this.onHold, this.trailing, this.padding, super.key});

  @override
  _TrackTileState createState() => _TrackTileState();
}

enum PlayingState { NONE, PLAYING, PAUSED }

class _TrackTileState extends State<TrackTile> {
  StreamSubscription? _mediaItemSub;
  StreamSubscription? _stateSub;
  StreamSubscription? _downloadItemSub;
  bool _isOffline = false;
  PlayingState nowPlaying = PlayingState.NONE;
  bool nowDownloading = false;
  double downloadProgress = 0;

  @override
  void initState() {
    //Listen to media item changes, update text color if currently playing
    _mediaItemSub = GetIt.I<AudioPlayerHandler>().mediaItem.listen((item) {
      if (widget.track.id == item?.id) {
        if (mounted) {
          setState(() {
            nowPlaying =
                GetIt.I<AudioPlayerHandler>().playbackState.value.playing
                    ? PlayingState.PLAYING
                    : PlayingState.PAUSED;
            _stateSub =
                GetIt.I<AudioPlayerHandler>().playbackState.listen((state) {
              if (mounted) {
                setState(() {
                  nowPlaying = state.playing
                      ? PlayingState.PLAYING
                      : PlayingState.PAUSED;
                });
              }
            });
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _stateSub?.cancel();
            nowPlaying = PlayingState.NONE;
          });
        }
      }
    });
    //Check if offline
    downloadManager.checkOffline(track: widget.track).then((b) {
      if (mounted) {
        setState(() => _isOffline = b || (widget.track.offline ?? false));
      }
    });

    //Listen to download change to drop progress indicator
    _downloadItemSub = downloadManager.serviceEvents.stream.listen((e) async {
      List<Download> downloads = await downloadManager.getDownloads();

      if (e['action'] == 'onProgress' && mounted) {
        setState(() {
          for (Map su in e['data']) {
            downloads
                .firstWhere((d) => d.id == su['id'], orElse: () => Download())
                .updateFromJson(su);
          }
        });
      }

      for (int i = 0; i < downloads.length; i++) {
        if (downloads[i].trackId == widget.track.id) {
          if (downloads[i].state != DownloadState.DONE) {
            if (mounted) {
              setState(() {
                nowDownloading = true;
                downloadProgress = downloads[i].progress;
              });
            }
          } else {
            if (mounted) {
              setState(() {
                nowDownloading = false;
                _isOffline = true;
              });
            }
          }
        }
      }
    });

    super.initState();
  }

  @override
  void dispose() {
    _mediaItemSub?.cancel();
    _downloadItemSub?.cancel();
    _stateSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      ListTile(
        contentPadding: widget.padding,
        //dense: true,
        title: Text(
          widget.track.title ?? '',
          maxLines: 1,
          overflow: TextOverflow.clip,
          style: TextStyle(
              fontWeight:
                  nowPlaying != PlayingState.NONE ? FontWeight.bold : null),
        ),
        subtitle: Text(
          widget.track.artistString ?? '',
          maxLines: 1,
        ),
        leading: Stack(
          children: [
            Container(
              clipBehavior: Clip.hardEdge,
              decoration: ShapeDecoration(
                shape: SmoothRectangleBorder(
                  borderRadius: SmoothBorderRadius(
                    cornerRadius: 10,
                    cornerSmoothing: 0.6,
                  ),
                ),
              ),
              child: CachedImage(
                url: widget.track.image?.thumb ?? '',
                width: 48,
              ),
            ),
            if (nowPlaying == PlayingState.PLAYING)
              Container(
                width: 48,
                height: 48,
                color: Colors.black.withAlpha(30),
                child: Center(
                    child: Lottie.asset('assets/animations/playing_wave.json',
                        repeat: true,
                        frameRate: FrameRate(60),
                        fit: BoxFit.cover,
                        width: 40,
                        height: 40)),
              ),
            if (nowPlaying == PlayingState.PAUSED)
              Container(
                width: 48,
                height: 48,
                color: Colors.black.withAlpha(30),
                child: Center(
                    child: Lottie.asset('assets/animations/pausing_wave.json',
                        repeat: false,
                        frameRate: FrameRate(60),
                        fit: BoxFit.cover,
                        width: 40,
                        height: 40)),
              ),
          ],
        ),
        onTap: widget.onTap,
        onLongPress: widget.onHold,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isOffline)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 2.0),
                child: Icon(
                  Octicons.primitive_dot,
                  color: Colors.green,
                  size: 12.0,
                ),
              ),
            if (widget.track.explicit ?? false)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 2.0),
                child: Text(
                  'E',
                  style: TextStyle(color: Colors.red),
                ),
              ),
            SizedBox(
              width: 42.0,
              child: Text(
                widget.track.durationString ?? '',
                textAlign: TextAlign.center,
              ),
            ),
            widget.trailing ?? const SizedBox(width: 0, height: 0)
          ],
        ),
      ),
      if (nowDownloading)
        LinearProgressIndicator(
          value: downloadProgress,
          color: Colors.green.shade400,
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          minHeight: 1,
        )
    ]);
  }
}

class NotificationTile extends StatelessWidget {
  final DeezerNotification notification;
  final VoidCallback? onTap;

  const NotificationTile(this.notification, {this.onTap, super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          onTap: onTap,
          leading: Container(
            clipBehavior: Clip.hardEdge,
            decoration: ShapeDecoration(
              shape: SmoothRectangleBorder(
                borderRadius: SmoothBorderRadius(
                  cornerRadius: 10,
                  cornerSmoothing: 0.6,
                ),
              ),
            ),
            child: CachedImage(
              url: notification.image?.thumb ?? '',
              width: 48,
            ),
          ),
          title: Text(
            notification.title ?? '',
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          subtitle: Text(
            notification.subtitle ?? '',
            maxLines: 1,
          ),
        ),
        Padding(
          padding: EdgeInsets.symmetric(vertical: 4.0, horizontal: 16.0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(notification.footer ?? ''),
              if (!(notification.read ?? true))
                Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: CircleAvatar(
                    radius: 4,
                    backgroundColor: Theme.of(context).primaryColor,
                  ),
                )
            ],
          ),
        ),
        Divider()
      ],
    );
  }
}

class SimpleTrackTile extends StatelessWidget {
  final Track track;
  final Playlist? playlist;

  const SimpleTrackTile(this.track, this.playlist, {super.key});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      minVerticalPadding: 0,
      visualDensity: VisualDensity.compact,
      leading: Container(
        clipBehavior: Clip.hardEdge,
        decoration: ShapeDecoration(
          shape: SmoothRectangleBorder(
            borderRadius: SmoothBorderRadius(
              cornerRadius: 10,
              cornerSmoothing: 0.6,
            ),
          ),
        ),
        child: CachedImage(
          url: track.image?.full ?? '',
        ),
      ),
      title: Text(track.title ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
      subtitle: Text(track.artistString ?? '',
          style: TextStyle(color: Settings.secondaryText, fontSize: 12)),
      trailing: PlayerMenuButton(track),
      onTap: () {
        GetIt.I<AudioPlayerHandler>().playFromTrackList(
          playlist?.tracks ?? [track],
          track.id ?? '',
          QueueSource(
              id: playlist?.id, text: 'Favorites'.i18n, source: 'playlist'),
        );
      },
      onLongPress: () {
        MenuSheet m = MenuSheet();
        m.defaultTrackMenu(track, context: context);
      },
    );
  }
}

class AlbumTile extends StatelessWidget {
  final Album album;
  final VoidCallback? onTap;
  final VoidCallback? onHold;
  final Widget? trailing;
  final EdgeInsetsGeometry? padding;

  const AlbumTile(this.album,
      {super.key, this.onTap, this.onHold, this.trailing, this.padding});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: padding,
      title: Text(
        album.title ?? '',
        maxLines: 1,
      ),
      subtitle: Text(
        album.artistString ?? '',
        maxLines: 1,
      ),
      leading: Container(
        clipBehavior: Clip.hardEdge,
        decoration: ShapeDecoration(
          shape: SmoothRectangleBorder(
            borderRadius: SmoothBorderRadius(
              cornerRadius: 10,
              cornerSmoothing: 0.6,
            ),
          ),
        ),
        child: CachedImage(
          url: album.image?.thumb ?? '',
          width: 48,
        ),
      ),
      onTap: onTap,
      onLongPress: onHold,
      trailing: trailing,
    );
  }
}

class ArtistTile extends StatelessWidget {
  final Artist artist;
  final VoidCallback? onTap;
  final VoidCallback? onHold;
  final double? size;

  const ArtistTile(this.artist,
      {super.key, this.onTap, this.onHold, this.size});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
        width: size ?? 140,
        child: InkWell(
          borderRadius: BorderRadius.circular(25),
          onTap: onTap,
          onLongPress: onHold,
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.all(4),
                child: Container(
                  clipBehavior: Clip.hardEdge,
                  decoration: ShapeDecoration(
                    shape: SmoothRectangleBorder(
                      borderRadius: SmoothBorderRadius(
                        cornerRadius: 25,
                        cornerSmoothing: 0.6,
                      ),
                    ),
                  ),
                  child: CachedImage(
                    url: artist.image?.thumb ?? '',
                    circular: true,
                    width: size,
                  ),
                ),
              ),
              Container(height: 2.0),
              SizedBox(
                child: Text(
                  artist.name ?? '',
                  maxLines: 1,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14.0),
                ),
              ),
            ],
          ),
        ));
  }
}

class PlaylistTile extends StatelessWidget {
  final Playlist playlist;
  final VoidCallback? onTap;
  final VoidCallback? onHold;
  final Widget? trailing;
  final EdgeInsetsGeometry? padding;

  const PlaylistTile(this.playlist,
      {super.key, this.onHold, this.onTap, this.trailing, this.padding});

  String get subtitle {
    if (playlist.user?.name == '' || playlist.user?.id == deezerAPI.userId) {
      if (playlist.trackCount == null) return '';
      return '${playlist.trackCount} ' + 'Tracks'.i18n;
    }
    return playlist.user?.name ?? '';
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: padding,
      title: Text(
        playlist.title ?? '',
        maxLines: 1,
      ),
      subtitle: Text(
        subtitle,
        maxLines: 1,
      ),
      leading: Container(
        clipBehavior: Clip.hardEdge,
        decoration: ShapeDecoration(
          shape: SmoothRectangleBorder(
            borderRadius: SmoothBorderRadius(
              cornerRadius: 10,
              cornerSmoothing: 0.6,
            ),
          ),
        ),
        child: CachedImage(
          url: playlist.image?.thumb ?? '',
          width: 48,
        ),
      ),
      onTap: onTap,
      onLongPress: onHold,
      trailing: trailing,
    );
  }
}

class ArtistHorizontalTile extends StatelessWidget {
  final Artist artist;
  final VoidCallback? onTap;
  final VoidCallback? onHold;
  final Widget? trailing;
  final EdgeInsetsGeometry? padding;

  const ArtistHorizontalTile(this.artist,
      {super.key, this.onHold, this.onTap, this.trailing, this.padding});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: ListTile(
        contentPadding: padding,
        title: Text(
          artist.name ?? '',
          maxLines: 1,
        ),
        leading: CachedImage(
          url: artist.image?.thumb ?? '',
          circular: true,
          width: 48,
        ),
        onTap: onTap,
        onLongPress: onHold,
        trailing: trailing,
      ),
    );
  }
}

class PlaylistCardTile extends StatelessWidget {
  final Playlist playlist;
  final VoidCallback? onTap;
  final VoidCallback? onHold;
  const PlaylistCardTile(this.playlist, {super.key, this.onTap, this.onHold});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
        width: 140,
        child: InkWell(
          borderRadius: BorderRadius.circular(25),
          onTap: onTap,
          onLongPress: onHold,
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.all(4),
                child: Container(
                  clipBehavior: Clip.hardEdge,
                  decoration: ShapeDecoration(
                    shape: SmoothRectangleBorder(
                      borderRadius: SmoothBorderRadius(
                        cornerRadius: 25,
                        cornerSmoothing: 0.6,
                      ),
                    ),
                  ),
                  child: CachedImage(
                    url: playlist.image?.thumb ?? '',
                    width: 130,
                    height: 130,
                    rounded: true,
                  ),
                ),
              ),
              Container(height: 2.0),
              SizedBox(
                child: Text(
                  playlist.title ?? '',
                  maxLines: 1,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14.0),
                ),
              ),
            ],
          ),
        ));
  }
}

class SmartTrackListTile extends StatelessWidget {
  final SmartTrackList smartTrackList;
  final VoidCallback? onTap;
  final VoidCallback? onHold;
  const SmartTrackListTile(this.smartTrackList,
      {super.key, this.onHold, this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
        width: 140,
        child: InkWell(
          borderRadius: BorderRadius.circular(25),
          onTap: onTap,
          onLongPress: onHold,
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.all(4),
                child: Container(
                    clipBehavior: Clip.hardEdge,
                    decoration: ShapeDecoration(
                      shape: SmoothRectangleBorder(
                        borderRadius: SmoothBorderRadius(
                          cornerRadius: 25,
                          cornerSmoothing: 0.6,
                        ),
                      ),
                    ),
                    child: Stack(
                      children: [
                        CachedImage(
                          url: smartTrackList.image?.full ?? '',
                          width: 130,
                          height: 130,
                          rounded: true,
                        ),
                        Align(
                          alignment: Alignment.topLeft,
                          child: Padding(
                            padding: EdgeInsets.only(left: 12, top: 8),
                            child: Text(
                              smartTrackList.title?.toUpperCase() ?? '',
                              maxLines: 1,
                              textAlign: TextAlign.center,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color:
                                      Theme.of(context).scaffoldBackgroundColor,
                                  fontSize: 18.0,
                                  fontWeight: FontWeight.bold),
                            ),
                          ),
                        )
                      ],
                    )),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Text(smartTrackList.subtitle ?? '',
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12.0,
                        color:
                            (Theme.of(context).brightness == Brightness.light)
                                ? Colors.grey[800]
                                : Colors.white70)),
              )
            ],
          ),
        ));
  }
}

class FlowTrackListTile extends StatelessWidget {
  final DeezerFlow deezerFlow;
  final VoidCallback? onTap;
  final VoidCallback? onHold;
  const FlowTrackListTile(this.deezerFlow,
      {super.key, this.onHold, this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
        width: 105,
        child: InkWell(
          borderRadius: BorderRadius.circular(15),
          onTap: onTap,
          onLongPress: onHold,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                height: 4,
              ),
              CachedImage(
                url: deezerFlow.image?.full ?? '',
                circular: true,
                width: 95,
              ),
              Container(
                height: 8,
              ),
              Text(
                deezerFlow.title ?? '',
                maxLines: 1,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14.0),
              ),
              Container(
                height: 4,
              ),
            ],
          ),
        ));
  }
}

class AlbumCard extends StatelessWidget {
  final Album album;
  final VoidCallback? onTap;
  final VoidCallback? onHold;

  const AlbumCard(this.album, {super.key, this.onTap, this.onHold});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
        width: 140,
        child: InkWell(
          borderRadius: BorderRadius.circular(25),
          onTap: onTap,
          onLongPress: onHold,
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.all(4),
                child: Container(
                  clipBehavior: Clip.hardEdge,
                  decoration: ShapeDecoration(
                    shape: SmoothRectangleBorder(
                      borderRadius: SmoothBorderRadius(
                        cornerRadius: 25,
                        cornerSmoothing: 0.6,
                      ),
                    ),
                  ),
                  child: CachedImage(
                    url: album.image?.thumb ?? '',
                    width: 130,
                    height: 130,
                    rounded: true,
                  ),
                ),
              ),
              Container(height: 2.0),
              SizedBox(
                child: Text(
                  album.title ?? '',
                  maxLines: 1,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14.0),
                ),
              ),
              Container(
                height: 2.0,
              ),
              SizedBox(
                child: Text(album.artistString ?? '',
                    maxLines: 1,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12.0,
                        color:
                            (Theme.of(context).brightness == Brightness.light)
                                ? Colors.grey[800]
                                : Colors.white70)),
              )
            ],
          ),
        ));
  }
}

class ChannelTile extends StatelessWidget {
  final DeezerChannel channel;
  final VoidCallback? onTap;
  const ChannelTile(this.channel, {super.key, this.onTap});

  Color _textColor() {
    if (channel.backgroundImage == null) {
      double luminance = channel.backgroundColor!.computeLuminance();
      return (luminance > 0.5) ? Colors.black : Colors.white;
    } else {
      // Deezer website seems to always use white for title over logo image
      return Colors.white;
    }
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(25),
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.all(4.0),
        child: Container(
          width: 180,
          height: 80,
          clipBehavior: Clip.hardEdge,
          decoration: ShapeDecoration(
            shape: SmoothRectangleBorder(
              borderRadius: SmoothBorderRadius(
                cornerRadius: 25,
                cornerSmoothing: 0.6,
              ),
            ),
            color: channel.backgroundColor,
          ),
          child: Stack(
            children: [
              Align(
                alignment: Alignment.bottomRight,
                child: Transform.translate(
                  offset: Offset(15, 15),
                  child: Transform.rotate(
                    angle: pi / 10,
                    child: CachedImage(
                      url: channel.backgroundImage
                              ?.customUrl('80', '80', quality: '100') ??
                          '',
                      width: 80,
                      height: 80,
                      rounded: true,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.all(12.0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    channel.title ?? '',
                    maxLines: 1,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 18.0,
                        fontWeight: FontWeight.bold,
                        color: _textColor()),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ShowCard extends StatelessWidget {
  final Show show;
  final VoidCallback? onTap;
  final VoidCallback? onHold;

  const ShowCard(this.show, {super.key, this.onTap, this.onHold});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
        width: 140,
        child: InkWell(
          borderRadius: BorderRadius.circular(25),
          onTap: onTap,
          onLongPress: onHold,
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.all(4),
                child: Container(
                  clipBehavior: Clip.hardEdge,
                  decoration: ShapeDecoration(
                    shape: SmoothRectangleBorder(
                      borderRadius: SmoothBorderRadius(
                        cornerRadius: 25,
                        cornerSmoothing: 0.6,
                      ),
                    ),
                  ),
                  child: CachedImage(
                    url: show.image?.thumb ?? '',
                    width: 130,
                    height: 130,
                    rounded: true,
                  ),
                ),
              ),
              Container(height: 2.0),
              SizedBox(
                child: Text(
                  show.name ?? '',
                  maxLines: 1,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14.0),
                ),
              ),
            ],
          ),
        ));
  }
}

class ShowTile extends StatelessWidget {
  final Show show;
  final VoidCallback? onTap;
  final VoidCallback? onHold;
  final EdgeInsetsGeometry? padding;
  final Widget? trailing;

  const ShowTile(this.show,
      {super.key, this.onTap, this.onHold, this.padding, this.trailing});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: padding,
      title: Text(
        show.name ?? '',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        show.description ?? '',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: onTap,
      onLongPress: onHold,
      leading: Container(
        clipBehavior: Clip.hardEdge,
        decoration: ShapeDecoration(
          shape: SmoothRectangleBorder(
            borderRadius: SmoothBorderRadius(
              cornerRadius: 10,
              cornerSmoothing: 0.6,
            ),
          ),
        ),
        child: CachedImage(
          url: show.image?.thumb ?? '',
          width: 48,
        ),
      ),
      trailing: trailing,
    );
  }
}

class ShowEpisodeTile extends StatefulWidget {
  final ShowEpisode episode;
  final VoidCallback? onTap;
  final VoidCallback? onHold;
  final Widget? trailing;
  final Show? show;
  final EdgeInsetsGeometry? padding;

  const ShowEpisodeTile(this.episode,
      {super.key,
      this.onTap,
      this.onHold,
      this.trailing,
      this.show,
      this.padding});

  @override
  _ShowEpisodeTileState createState() => _ShowEpisodeTileState();
}

class _ShowEpisodeTileState extends State<ShowEpisodeTile> {
  StreamSubscription? _mediaItemSub;
  StreamSubscription? _stateSub;
  StreamSubscription? _downloadItemSub;
  bool _isOffline = false;
  PlayingState nowPlaying = PlayingState.NONE;
  bool nowDownloading = false;
  double downloadProgress = 0;

  @override
  void initState() {
    //Listen to media item changes, update text color if currently playing
    _mediaItemSub = GetIt.I<AudioPlayerHandler>().mediaItem.listen((item) {
      if (widget.episode.id == item?.id) {
        if (mounted) {
          setState(() {
            nowPlaying =
                GetIt.I<AudioPlayerHandler>().playbackState.value.playing
                    ? PlayingState.PLAYING
                    : PlayingState.PAUSED;
            _stateSub =
                GetIt.I<AudioPlayerHandler>().playbackState.listen((state) {
              if (mounted) {
                setState(() {
                  nowPlaying = state.playing
                      ? PlayingState.PLAYING
                      : PlayingState.PAUSED;
                });
              }
            });
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _stateSub?.cancel();
            nowPlaying = PlayingState.NONE;
          });
        }
      }
    });
    /*//Check if offline
    downloadManager.checkOffline(track: widget.episode).then((b) {
      if (mounted) {
        setState(() => _isOffline = b || (widget.track.offline ?? false));
      }
    });
*/
    //Listen to download change to drop progress indicator
    _downloadItemSub = downloadManager.serviceEvents.stream.listen((e) async {
      List<Download> downloads = await downloadManager.getDownloads();

      if (e['action'] == 'onProgress' && mounted) {
        setState(() {
          for (Map su in e['data']) {
            downloads
                .firstWhere((d) => d.id == su['id'], orElse: () => Download())
                .updateFromJson(su);
          }
        });
      }

      for (int i = 0; i < downloads.length; i++) {
        if (downloads[i].trackId == widget.episode.id) {
          if (downloads[i].state != DownloadState.DONE) {
            if (mounted) {
              setState(() {
                nowDownloading = true;
                downloadProgress = downloads[i].progress;
              });
            }
          } else {
            if (mounted) {
              setState(() {
                nowDownloading = false;
                _isOffline = true;
              });
            }
          }
        }
      }
    });

    super.initState();

    _checkOffline();
  }

  void _checkOffline() async {
    if (widget.episode.isIn(await downloadManager.getAllOfflineEpisodes()) &&
        mounted) {
      setState(() {
        _isOffline = true;
      });
    }
  }

  @override
  void dispose() {
    _mediaItemSub?.cancel();
    _downloadItemSub?.cancel();
    _stateSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        InkWell(
          onLongPress: widget.onHold,
          onTap: widget.onTap,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                contentPadding: widget.padding,
                dense: true,
                title: Text(
                  widget.episode.title ?? '',
                  maxLines: 2,
                  overflow: TextOverflow.clip,
                  style: TextStyle(
                      fontWeight: nowPlaying != PlayingState.NONE
                          ? FontWeight.bold
                          : null),
                ),
                leading: Stack(
                  children: [
                    CachedImage(
                      url: widget.episode.episodeCover?.full ?? '',
                      width: 48,
                      rounded: true,
                    ),
                    if (nowPlaying == PlayingState.PLAYING)
                      Container(
                        width: 48,
                        height: 48,
                        color: Colors.black.withAlpha(30),
                        child: Center(
                            child: Lottie.asset(
                                'assets/animations/playing_wave.json',
                                repeat: true,
                                frameRate: FrameRate(60),
                                fit: BoxFit.cover,
                                width: 40,
                                height: 40)),
                      ),
                    if (nowPlaying == PlayingState.PAUSED)
                      Container(
                        width: 48,
                        height: 48,
                        color: Colors.black.withAlpha(30),
                        child: Center(
                            child: Lottie.asset(
                                'assets/animations/pausing_wave.json',
                                repeat: false,
                                frameRate: FrameRate(60),
                                fit: BoxFit.cover,
                                width: 40,
                                height: 40)),
                      ),
                  ],
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_isOffline)
                      IconButton(
                          onPressed: () {},
                          icon: Icon(AlchemyIcons.download_fill)),
                    if (!_isOffline)
                      IconButton(
                          onPressed: () {
                            downloadManager.addOfflineEpisode(widget.episode);
                          },
                          icon: Icon(AlchemyIcons.download)),
                    if (widget.episode.isExplicit ?? false)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 2.0),
                        child: Icon(AlchemyIcons.explicit),
                      ),
                    widget.trailing ??
                        IconButton(
                            onPressed: () => showModalBottomSheet(
                                  backgroundColor: Colors.transparent,
                                  useRootNavigator: true,
                                  isScrollControlled: true,
                                  context: context,
                                  builder: (BuildContext context) {
                                    return DraggableScrollableSheet(
                                      initialChildSize: 0.3,
                                      minChildSize: 0.3,
                                      maxChildSize: 0.9,
                                      expand: false,
                                      builder: (context,
                                          ScrollController scrollController) {
                                        return Container(
                                          padding: EdgeInsets.symmetric(
                                              vertical: 12.0),
                                          clipBehavior: Clip.hardEdge,
                                          decoration: BoxDecoration(
                                            color: Theme.of(context)
                                                .scaffoldBackgroundColor,
                                            border: Border.all(
                                                color: Colors.transparent),
                                            borderRadius: BorderRadius.only(
                                              topLeft: Radius.circular(18),
                                              topRight: Radius.circular(18),
                                            ),
                                          ),
                                          // Use ListView instead of SingleChildScrollView for scrollable content
                                          child: ListView(
                                            controller:
                                                scrollController, // Important: Connect ScrollController
                                            children: [
                                              ListTile(
                                                leading: Container(
                                                  clipBehavior: Clip.hardEdge,
                                                  decoration: ShapeDecoration(
                                                    shape:
                                                        SmoothRectangleBorder(
                                                      borderRadius:
                                                          SmoothBorderRadius(
                                                        cornerRadius: 10,
                                                        cornerSmoothing: 0.6,
                                                      ),
                                                    ),
                                                  ),
                                                  child: CachedImage(
                                                    url: widget
                                                            .episode
                                                            .episodeCover
                                                            ?.full ??
                                                        '',
                                                  ),
                                                ),
                                                title: Text(
                                                    widget.episode.title ?? ''),
                                                subtitle: Text(widget.episode
                                                        .durationString +
                                                    ' | ' +
                                                    (widget.episode
                                                            .publishedDate ??
                                                        '')),
                                              ),
                                              Padding(
                                                padding: EdgeInsets.all(16.0),
                                                child: Text(widget
                                                        .episode.description ??
                                                    ''),
                                              ),
                                              ListTile(
                                                title: Text('Share'.i18n),
                                                leading:
                                                    const Icon(Icons.share),
                                                onTap: () async {
                                                  Share.share(
                                                      'https://deezer.com/episode/${widget.episode.id}');
                                                },
                                              ),
                                            ],
                                          ),
                                        );
                                      },
                                    );
                                  },
                                ),
                            icon: Icon(AlchemyIcons.more_vert)),
                  ],
                ),
              ),
              if (widget.episode.description != null)
                Padding(
                  padding: widget.padding ??
                      EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                  child: Text(
                    widget.episode.description ?? '',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.justify,
                    style: TextStyle(
                        color: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.color
                            ?.withAlpha(230)),
                  ),
                ),
              Padding(
                padding:
                    widget.padding ?? const EdgeInsets.fromLTRB(16, 4, 0, 0),
                child: Row(
                  mainAxisSize: MainAxisSize.max,
                  children: [
                    Text(
                      '${widget.episode.publishedDate} ● ${widget.episode.durationString}',
                      textAlign: TextAlign.left,
                      style: TextStyle(
                          fontSize: 12.0,
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.color
                              ?.withAlpha(150)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const Divider(),
      ],
    );
  }
}

class LargePlaylistTile extends StatelessWidget {
  final Playlist playlist;
  final VoidCallback? onTap;

  const LargePlaylistTile(this.playlist, {this.onTap, super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
        padding: EdgeInsets.symmetric(
            horizontal: MediaQuery.of(context).size.width * 0.02),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(30),
              onTap: onTap ??
                  () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (context) => PlaylistDetails(playlist))),
              onLongPress: () {
                MenuSheet m = MenuSheet();
                m.defaultPlaylistMenu(playlist, context: context);
              },
              child: Container(
                clipBehavior: Clip.hardEdge,
                decoration: ShapeDecoration(
                  shape: SmoothRectangleBorder(
                    borderRadius: SmoothBorderRadius(
                      cornerRadius: 30,
                      cornerSmoothing: 0.8,
                    ),
                  ),
                ),
                child: CachedImage(
                  url: playlist.image?.fullUrl ?? '',
                  height: 160,
                  width: 160,
                ),
              ),
            ),
            SizedBox(
              width: 160,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 2.0, vertical: 6.0),
                child: Text(playlist.title ?? '',
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
              ),
            ),
          ],
        ));
  }
}

class LargeAlbumTile extends StatelessWidget {
  final Album album;

  const LargeAlbumTile(this.album, {super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
        padding: EdgeInsets.symmetric(
            horizontal: MediaQuery.of(context).size.width * 0.02),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(30),
              onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (context) => AlbumDetails(album))),
              onLongPress: () {
                MenuSheet m = MenuSheet();
                m.defaultAlbumMenu(album, context: context);
              },
              child: Container(
                clipBehavior: Clip.hardEdge,
                decoration: ShapeDecoration(
                  shape: SmoothRectangleBorder(
                    borderRadius: SmoothBorderRadius(
                      cornerRadius: 30,
                      cornerSmoothing: 0.8,
                    ),
                  ),
                ),
                child: CachedImage(
                  url: album.image?.fullUrl ?? '',
                  height: 160,
                  width: 160,
                ),
              ),
            ),
            SizedBox(
                width: 160,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 2.0, vertical: 6.0),
                  child: Text(album.title ?? '',
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                )),
            SizedBox(
                width: 160,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4.0),
                  child: Text('By '.i18n + (album.artistString ?? ''),
                      maxLines: 1,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Settings.secondaryText, fontSize: 8)),
                )),
            if (album.releaseDate != null)
              SizedBox(
                  width: 160,
                  child: Padding(
                    padding:
                        EdgeInsets.symmetric(horizontal: 4.0, vertical: 2.0),
                    child: Text('Out on '.i18n + (album.releaseDate ?? ''),
                        maxLines: 1,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: Settings.secondaryText, fontSize: 8)),
                  )),
          ],
        ));
  }
}
