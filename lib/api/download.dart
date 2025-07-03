import 'dart:async';
import 'dart:io';

//import 'package:disk_space_plus/disk_space_plus.dart';
import 'package:filesize/filesize.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../api/deezer.dart';
import '../api/definitions.dart';
import '../utils/navigator_keys.dart';
import '../settings.dart';
import '../translations.i18n.dart';
import '../utils/file_utils.dart';

DownloadManager downloadManager = DownloadManager();

class DownloadManager {
  //Platform channels
  static MethodChannel get platform =>
      MethodChannel('definitely.not.deezer/native');
  static EventChannel get eventChannel =>
      EventChannel('definitely.not.deezer/events');

  bool running = false;
  int queueSize = 0;

  StreamController serviceEvents = StreamController.broadcast();
  String? offlinePath;
  Database? db;

  //Start/Resume downloads
  Future start() async {
    //Returns whether service is bound or not, the delay is really shitty/hacky way, until i find a real solution
    await updateServiceSettings();
    await platform.invokeMethod('start');
  }

  //Stop/Pause downloads
  Future stop() async {
    await platform.invokeMethod('stop');
  }

  Future init() async {
    String dbPath = p.join((await getDatabasesPath()), 'offline2.db');
    //Open db
    db = await openDatabase(dbPath, version: 1,
        onCreate: (Database db, int version) async {
      Batch b = db.batch();
      //Create tables, if doesn't exit
      b.execute('''CREATE TABLE Tracks (
        id TEXT PRIMARY KEY, title TEXT, album TEXT, artists TEXT, duration INTEGER, image TEXT, trackNumber INTEGER, offline INTEGER, lyrics TEXT, favorite INTEGER, diskNumber INTEGER, explicit INTEGER, fallback INTEGER)''');
      b.execute('''CREATE TABLE Albums (
        id TEXT PRIMARY KEY, title TEXT, artists TEXT, tracks TEXT, image TEXT, fans INTEGER, offline INTEGER, library INTEGER, type INTEGER, releaseDate TEXT)''');
      b.execute('''CREATE TABLE Artists (
        id TEXT PRIMARY KEY, name TEXT, albums TEXT, topTracks TEXT, image TEXT, fans INTEGER, hasNextPage INTEGER, offline INTEGER, library INTEGER, radio INTEGER)''');
      b.execute('''CREATE TABLE Playlists (
        id TEXT PRIMARY KEY, title TEXT, tracks TEXT, image TEXT, duration INTEGER, userId TEXT, userName TEXT, fans INTEGER, library INTEGER, description TEXT)''');
      b.execute('''CREATE TABLE Shows (
        id TEXT PRIMARY KEY, name TEXT, authors TEXT, description TEXT, fans INTEGER, isExplicit INTEGER, isLibrary INTEGER, offline INTEGER, image TEXT)''');
      b.execute('''CREATE TABLE Episodes (
        id TEXT PRIMARY KEY, title TEXT, description TEXT, url TEXT, duration INTEGER, publishedDate TEXT, image TEXT, isExplicit INTEGER, offline INTEGER, showId TEXT)''');
      await b.commit();
    });

    //Create offline directory
    var directory = await getExternalStorageDirectory();
    if (directory != null) {
      offlinePath = p.join(directory.path, 'offline/');
      await Directory(offlinePath!).create(recursive: true);
    }

    //Update settings
    await updateServiceSettings();

    //Listen to state change event
    eventChannel.receiveBroadcastStream().listen((e) {
      final event = e as Map<dynamic, dynamic>;
      final String? eventType = event['eventType'] as String?;

      if (eventType == 'downloadState') {
        final data = event['data'] as Map<dynamic, dynamic>;
        running = data['running'] as bool;
        queueSize = data['queueSize'] as int;
        serviceEvents.add({
          'action': 'onStateChange',
          'running': running,
          'queueSize': queueSize
        });
      } else if (eventType == 'downloadProgress') {
        serviceEvents.add({'action': 'onProgress', 'data': event['data']});
      } else {
        //Forward other/unknown events
        serviceEvents.add(e);
      }
    });

    await platform.invokeMethod('loadDownloads');
  }

  void exportTracks() async {
    List<Track> allTracks = await allOfflineTracks();
    for (Track track in allTracks) {
      String path = p.join(offlinePath!, track.id);
      File trackFile = File(path);
      if (await trackFile.exists()) {
        String newPath = _generatePath(track.id!, false);
        await trackFile.copy(newPath);
      }
      Fluttertoast.showToast(
          msg: 'Eported ' + allTracks.length.toString() + ' tracks.');
    }
  }

  //Get all downloads from db
  Future<List<Download>> getDownloads() async {
    List raw = await platform.invokeMethod('getDownloads');
    return raw.map((d) => Download.fromJson(d)).toList();
  }

  //Insert track and metadata to DB
  Future _addTrackToDB(Batch batch, Track track, bool overwriteTrack) async {
    //Fetch lyrics
    try {
      if (settings.downloadLyrics) {
        LyricsFull lyrics = await deezerAPI.lyrics(track);
        if (lyrics.errorMessage == null) {
          track.lyrics = lyrics;
        } else {
          Logger.root.info(
              'Failed to load lyrics for track ${track.id} : ${lyrics.errorMessage}');
        }
      }
    } catch (e) {
      Logger.root.info(
          'An error occured while fetching lyrics for track ${track.id} : $e');
    }

    batch.insert('Tracks', track.toSQL(off: true),
        conflictAlgorithm: overwriteTrack
            ? ConflictAlgorithm.replace
            : ConflictAlgorithm.ignore);
    batch.insert(
        'Albums', track.album?.toSQL(off: false) as Map<String, dynamic>,
        conflictAlgorithm: ConflictAlgorithm.ignore);
    //Artists
    if (track.artists != null) {
      for (Artist a in track.artists!) {
        batch.insert('Artists', a.toSQL(off: false),
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    }
    return batch;
  }

  //Insert track and metadata to DB
  Future _addShowEpisodeToDB(
      Batch batch, ShowEpisode episode, bool overwriteShow,
      {Show? show}) async {
    batch.insert('Episodes', episode.toSQL(off: true),
        conflictAlgorithm: overwriteShow
            ? ConflictAlgorithm.replace
            : ConflictAlgorithm.ignore);
    Show s =
        show ?? await deezerAPI.show(episode.show?.id ?? '', page: 0, nb: 0);
    s.episodes?.add(episode);
    batch.insert('Shows', s.toSQL(off: true),
        conflictAlgorithm: overwriteShow
            ? ConflictAlgorithm.replace
            : ConflictAlgorithm.ignore);
    return batch;
  }

  //Quality selector for custom quality
  Future qualitySelect() async {
    AudioQuality? quality;
    await showModalBottomSheet(
        context: mainNavigatorKey.currentContext!,
        builder: (context) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 12, 0, 2),
                child: Text(
                  'Quality'.i18n,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 20.0),
                ),
              ),
              ListTile(
                title: const Text('MP3 128kbps'),
                onTap: () {
                  quality = AudioQuality.MP3_128;
                  mainNavigatorKey.currentState?.pop();
                },
              ),
              ListTile(
                title: const Text('MP3 320kbps'),
                onTap: () {
                  quality = AudioQuality.MP3_320;
                  mainNavigatorKey.currentState?.pop();
                },
              ),
              ListTile(
                title: const Text('FLAC'),
                onTap: () {
                  quality = AudioQuality.FLAC;
                  mainNavigatorKey.currentState?.pop();
                },
              )
            ],
          );
        });
    return quality;
  }

  Future<bool> openStoragePermissionSettingsDialog() async {
    Completer<bool> completer = Completer<bool>();

    await showDialog(
      context: mainNavigatorKey.currentContext!,
      builder: (context) {
        return AlertDialog(
          title: Text('Storage Permission Required'.i18n),
          content: Text(
              'Storage permission is required to download content.\nPlease open system settings and grant storage permission to ReFreezer.'
                  .i18n),
          actions: <Widget>[
            TextButton(
              child: Text('Cancel'.i18n),
              onPressed: () {
                Navigator.of(context).pop();
                completer.complete(false);
              },
            ),
            TextButton(
              child: Text('Open system settings'.i18n),
              onPressed: () {
                Navigator.of(context).pop();
                completer.complete(true);
              },
            ),
          ],
        );
      },
    );

    return completer.future;
  }

  Future<bool> openSAFPermissionDialog() async {
    Completer<bool> completer = Completer<bool>();

    await showDialog(
      context: mainNavigatorKey.currentContext!,
      builder: (context) {
        return AlertDialog(
          title: Text('External Storage Access Required'.i18n),
          content: Text(
              'To download files to the external storage, please grant access to the SD card or USB root directory in the following screen.'
                  .i18n),
          actions: <Widget>[
            TextButton(
              child: Text('Cancel'.i18n),
              onPressed: () {
                Navigator.of(context).pop();
                completer.complete(false);
              },
            ),
            TextButton(
              child: Text('Continue'.i18n),
              onPressed: () {
                Navigator.of(context).pop();
                completer.complete(true);
              },
            ),
          ],
        );
      },
    );

    return completer.future;
  }

  Future<bool> addOfflineTrack(Track track,
      {private = true, isSingleton = false}) async {
    //Permission
    if (!private && !(await checkPermission())) return false;

    //Ask for quality
    AudioQuality? quality;
    if (!private && settings.downloadQuality == AudioQuality.ASK) {
      quality = await qualitySelect();
      if (quality == null) return false;
    }

    //Fetch track if missing meta
    if (track.artists == null || track.artists!.isEmpty) {
      track = await deezerAPI.track(track.id!);
    }

    //Get path
    String path = _generatePath(track.id!, private, isSingleton: isSingleton);
    if (!(await File(path).exists())) {
      await platform.invokeMethod('addDownloads', [
        await Download.jsonFromTrack(track, path,
            private: private, quality: quality)
      ]);

      await start();

      // Wait for the download to complete
      bool downloadSuccess = await _waitForDownloadCompletion(track.id!);
      if (!downloadSuccess) {
        return false; // Exit if the download failed
      }
    }

    //Add to DB
    if (private) {
      Batch b = db!.batch();
      b = await _addTrackToDB(b, track, true);
      await b.commit();

      //Cache art
      DefaultCacheManager().getSingleFile(track.image?.thumb ?? '');
      DefaultCacheManager().getSingleFile(track.image?.full ?? '');
    }

    return true;
  }

  // Helper function to wait for download completion
  Future<bool> _waitForDownloadCompletion(String trackId) async {
    // Listen to the service events to check the download state
    Completer<bool> completer = Completer<bool>();
    late StreamSubscription subscription;

    subscription = serviceEvents.stream.listen((event) {
      if (event['action'] == 'onProgress') {
        for (var download in event['data']) {
          if (download['trackId'] == trackId &&
              download['state'] == DownloadState.DONE.index) {
            completer.complete(true);
            subscription.cancel();
          } else if (download['trackId'] == trackId &&
              download['state'] == DownloadState.ERROR.index) {
            completer.complete(false);
            subscription.cancel();
          }
        }
      }
    });

    return completer.future;
  }

  Future<bool> addOfflineEpisode(ShowEpisode episode,
      {private = true, isSingleton = false, Show? show}) async {
    //Permission
    if (!private && !(await checkPermission())) return false;

    //Get path
    String path = _generatePath(episode.id!, private, isSingleton: isSingleton);
    if (!(await File(path).exists())) {
      await platform.invokeMethod('addDownloads',
          [await Download.jsonFromEpisode(episode, path, private: private)]);

      await start();

      // Wait for the download to complete
      bool downloadSuccess = await _waitForDownloadCompletion(episode.id!);
      if (!downloadSuccess) {
        return false; // Exit if the download failed
      }
    }

    //Add to DB
    if (private) {
      Batch b = db!.batch();
      b = await _addShowEpisodeToDB(b, episode, true, show: show);
      await b.commit();

      //Cache art
      DefaultCacheManager().getSingleFile(episode.episodeCover?.thumb ?? '');
      DefaultCacheManager().getSingleFile(episode.episodeCover?.full ?? '');
    }

    return true;
  }

  Future addOfflineAlbum(Album album, {private = true}) async {
    //Permission
    if (!private && !(await checkPermission())) return;

    //Ask for quality
    AudioQuality? quality;
    if (!private && settings.downloadQuality == AudioQuality.ASK) {
      quality = await qualitySelect();
      if (quality == null) return false;
    }

    //Get from API if no tracks
    if (album.tracks == null || album.tracks!.isEmpty) {
      album = await deezerAPI.album(album.id ?? '');
    }

    //Add to DB
    if (private) {
      //Cache art
      DefaultCacheManager().getSingleFile(album.image?.thumb ?? '');
      DefaultCacheManager().getSingleFile(album.image?.full ?? '');

      Batch b = db!.batch();
      b.insert('Albums', album.toSQL(off: true),
          conflictAlgorithm: ConflictAlgorithm.replace);
      for (Track t in album.tracks ?? []) {
        b = await _addTrackToDB(b, t, true);
      }
      await b.commit();
    }

    //Generate downloads
    List<Map> out = [];
    for (Track t in (album.tracks ?? [])) {
      String tPath = _generatePath(t.id!, private);
      if (!(await File(tPath).exists())) {
        out.add(await Download.jsonFromTrack(t, tPath,
            private: private, quality: quality));
      }
    }
    await platform.invokeMethod('addDownloads', out);
    await start();

    List<Future> futures = [];
    List<Track> downloadedTracks = [];

    for (Track t in (album.tracks ?? [])) {
      futures.add(_waitForDownloadCompletion(t.id!).then((bool success) async {
        if (private) {
          Batch b = db!.batch();
          b = await _addTrackToDB(b, t, true);
          await b.commit();

          //Cache art
          DefaultCacheManager().getSingleFile(t.image?.thumb ?? '');
          DefaultCacheManager().getSingleFile(t.image?.full ?? '');

          downloadedTracks.add(t);
        }
      }));
    }

    //Update DB
    Future.wait(futures).whenComplete(() async {
      if (private) {
        album.tracks = downloadedTracks;
        Batch b = db!.batch();
        b.insert('Albums', album.toSQL(off: true),
            conflictAlgorithm: ConflictAlgorithm.replace);
        for (Track t in album.tracks ?? []) {
          b = await _addTrackToDB(b, t, true);
        }
        await b.commit();
      }
    });
  }

  Future addOfflinePlaylist(Playlist playlist,
      {private = true, AudioQuality? quality}) async {
    //Permission
    if (!private && !(await checkPermission())) return;

    //Ask for quality
    if (!private &&
        settings.downloadQuality == AudioQuality.ASK &&
        quality == null) {
      quality = await qualitySelect();
      if (quality == null) return false;
    }

    //Get tracks if missing
    if ((playlist.tracks == null) ||
        (playlist.tracks?.length ?? 0) < (playlist.trackCount ?? 0)) {
      playlist = await deezerAPI.fullPlaylist(playlist.id ?? '');
    }

    //Add to db
    if (private) {
      Batch b = db!.batch();
      b.insert('Playlists', playlist.toSQL(),
          conflictAlgorithm: ConflictAlgorithm.replace);
      await b.commit();
    }

    //Generate downloads
    List<Map> out = [];
    for (int i = 0; i < (playlist.tracks?.length ?? 0); i++) {
      Track t = playlist.tracks![i];
      String tPath = _generatePath(
        t.id!,
        private,
        playlistName: playlist.title,
        playlistTrackNumber: i,
      );
      if (!(await File(tPath).exists())) {
        out.add(await Download.jsonFromTrack(t, tPath,
            private: private, quality: quality));
      }
    }
    await platform.invokeMethod('addDownloads', out);
    await start();

    List<Future> futures = [];
    List<Track> downloadedTracks = [];

    for (Track t in (playlist.tracks ?? [])) {
      futures.add(_waitForDownloadCompletion(t.id!).then((bool success) async {
        if (private) {
          Batch b = db!.batch();
          b = await _addTrackToDB(b, t, true);
          await b.commit();

          //Cache art
          DefaultCacheManager().getSingleFile(t.image?.thumb ?? '');
          DefaultCacheManager().getSingleFile(t.image?.full ?? '');

          downloadedTracks.add(t);
        }
      }));
    }

    //Update DB
    Future.wait(futures).whenComplete(() async {
      if (private) {
        playlist.tracks = downloadedTracks;
        Batch b = db!.batch();
        b.insert('Playlists', playlist.toSQL(),
            conflictAlgorithm: ConflictAlgorithm.replace);
        await b.commit();
      }
    });
  }

  Future updateOfflinePlaylist(Playlist playlist) async {
    if (playlist.isIn(await getOfflinePlaylists())) {
      Playlist? fullPlaylist = await deezerAPI.fullPlaylist(playlist.id ?? '');

      //If playlist didn't change
      if (fullPlaylist == (await getOfflinePlaylist(playlist.id ?? ''))) return;

      if (!(await checkPermission())) return;

      List<Track> toDowload = [];

      //Add to DB
      Batch b = db!.batch();
      b.update('Playlists', fullPlaylist.toSQL(),
          where: 'id == ?',
          whereArgs: [fullPlaylist.id],
          conflictAlgorithm: ConflictAlgorithm.replace);
      for (Track t in (fullPlaylist.tracks ?? [])) {
        if ((await getOfflineTrack(t.id!)) == null) {
          toDowload.add(t);
        }
        b = await _addTrackToDB(b, t, true);
        //Cache art
        DefaultCacheManager().getSingleFile(t.image?.thumb ?? '');
        DefaultCacheManager().getSingleFile(t.image?.full ?? '');
      }
      await b.commit();

      //Generate downloads
      List<Map> out = [];
      for (int i = 0; i < toDowload.length; i++) {
        Track t = toDowload[i];
        String tPath = _generatePath(
          t.id!,
          true,
          playlistName: playlist.title,
          playlistTrackNumber: i,
        );
        if (!(await File(tPath).exists())) {
          out.add(await Download.jsonFromTrack(
            t,
            tPath,
            private: true,
          ));
        }
      }
      await platform.invokeMethod('addDownloads', out);
      await start();
    }
  }

  //Get track and meta from offline DB
  Future<Track?> getOfflineTrack(String id,
      {Album? album, List<Artist>? artists}) async {
    List tracks = await db!.query('Tracks', where: 'id == ?', whereArgs: [id]);
    if (tracks.isEmpty) return null;
    Track track = Track.fromSQL(tracks[0]);

    //Get album
    if (album == null) {
      List rawAlbums = await db!
          .query('Albums', where: 'id == ?', whereArgs: [track.album?.id]);
      if (rawAlbums.isNotEmpty) track.album = Album.fromSQL(rawAlbums[0]);
    } else {
      track.album = album;
    }

    //Get artists
    if (artists == null) {
      List<Artist> newArtists = [];
      for (Artist artist in (track.artists ?? [])) {
        List rawArtist = await db!
            .query('Artists', where: 'id == ?', whereArgs: [artist.id]);
        if (rawArtist.isNotEmpty) newArtists.add(Artist.fromSQL(rawArtist[0]));
      }
      if (newArtists.isNotEmpty) track.artists = newArtists;
    } else {
      track.artists = artists;
    }
    return track;
  }

  //Get offline library tracks
  Future<List<Track>> getOfflineTracks() async {
    List rawTracks = await db!.query('Tracks',
        where: 'library == 1 AND offline == 1', columns: ['id']);
    List<Track> out = [];
    //Load track meta individually
    for (Map rawTrack in rawTracks) {
      var offlineTrack = await getOfflineTrack(rawTrack['id']);
      if (offlineTrack != null) out.add(offlineTrack);
    }
    return out;
  }

  //Get all offline available tracks
  Future<List<Track>> allOfflineTracks() async {
    List rawTracks =
        await db!.query('Tracks', where: 'offline == 1', columns: ['id']);
    List<Track> out = [];
    //Load track meta individually
    for (Map rawTrack in rawTracks) {
      var offlineTrack = await getOfflineTrack(rawTrack['id']);
      if (offlineTrack != null) out.add(offlineTrack);
    }
    return out;
  }

  //Get all offline albums
  Future<List<Album>> getOfflineAlbums() async {
    List rawAlbums =
        await db!.query('Albums', where: 'offline == 1', columns: ['id']);
    List<Album> out = [];
    //Load each album
    for (Map rawAlbum in rawAlbums) {
      var offlineAlbum = await getOfflineAlbum(rawAlbum['id']);
      if (offlineAlbum != null) out.add(offlineAlbum);
    }
    return out;
  }

  //Get offline album with meta
  Future<Album?> getOfflineAlbum(String id) async {
    List rawAlbums =
        await db!.query('Albums', where: 'id == ?', whereArgs: [id]);
    if (rawAlbums.isEmpty) return null;
    Album album = Album.fromSQL(rawAlbums[0]);

    List<Track> tracks = [];
    //Load tracks

    if (album.tracks?.isEmpty ?? true) {
      album.tracks = (await db!
              .query('Tracks', where: 'album == ?', whereArgs: [album.id]))
          .map((dynamic t) => Track.fromJson(t))
          .toList();
    } else {
      for (int i = 0; i < (album.tracks?.length ?? 0); i++) {
        var offlineTrack = await getOfflineTrack(album.tracks![i].id!);
        if (offlineTrack != null) tracks.add(offlineTrack);
      }
    }

    album.tracks = tracks;
    //Load artists
    List<Artist> artists = [];
    for (int i = 0; i < (album.artists?.length ?? 0); i++) {
      artists.add((await getOfflineArtist(album.artists![i].id ?? '')) ??
          album.artists![i]);
    }
    album.artists = artists;

    return album;
  }

  Future<Show?> getOfflineShow(String id) async {
    List rawShows = await db!.query('Shows', where: 'id == ?', whereArgs: [id]);
    if (rawShows.isEmpty) return null;
    Show show = Show.fromSQL(rawShows[0]);

    List<ShowEpisode> episodes = [];
    List rawEps =
        await db!.query('Episodes', where: 'showId == ?', whereArgs: [id]);

    //Load each episode
    for (Map rawEp in rawEps) {
      var offlineEp = ShowEpisode.fromSQL(rawEp);
      if (offlineEp.id != null) episodes.add(offlineEp);
    }

    show.episodes = episodes;
    return show;
  }

  //Get all offline shows
  Future<List<Show>> getOfflineShows() async {
    List rawShows = await db!.query('Shows', where: 'offline == 1');
    List<Show> out = [];
    //Load each show
    for (Map rawShow in rawShows) {
      var offlineShow = Show.fromSQL(rawShow);
      if (offlineShow.id != null) out.add(offlineShow);
    }
    return out;
  }

  //Get offline album with meta
  Future<List<ShowEpisode>> getOfflineEpisodes(String showId) async {
    List rawEps =
        await db!.query('Episodes', where: 'showId == ?', whereArgs: [showId]);
    List<ShowEpisode> out = [];
    //Load each show
    for (Map rawEp in rawEps) {
      var offlineEp = ShowEpisode.fromSQL(rawEp);
      if (offlineEp.id != null) out.add(offlineEp);
    }
    return out;
  }

  Future<ShowEpisode?> getOfflineEpisode(String episodeId) async {
    List rawEp =
        await db!.query('Episodes', where: 'id == ?', whereArgs: [episodeId]);

    if (rawEp.isEmpty) return null;
    ShowEpisode ep = ShowEpisode.fromSQL(rawEp[0]);

    return ep;
  }

  Future<List<ShowEpisode>> getAllOfflineEpisodes() async {
    List rawEps = await db!.query('Episodes');
    List<ShowEpisode> out = [];
    //Load each show
    for (Map rawEp in rawEps) {
      var offlineEp = ShowEpisode.fromSQL(rawEp);
      if (offlineEp.id != null) out.add(offlineEp);
    }
    return out;
  }

  //Get offline artist METADATA, not tracks
  Future<Artist?> getOfflineArtist(String id) async {
    List rawArtists =
        await db!.query('Artists', where: 'id == ?', whereArgs: [id]);
    if (rawArtists.isEmpty) return null;
    Artist a = Artist.fromSQL(rawArtists[0]);
    List rawTracks =
        await db!.rawQuery('SELECT * FROM Tracks WHERE artists LIKE "%$id%"');
    a.topTracks =
        rawTracks.map<Track>((dynamic t) => Track.fromSQL(t)).toList();

    List<Album> rawAlbums =
        (await db!.rawQuery('SELECT * FROM Albums WHERE artists LIKE "%$id%"'))
            .map<Album>((dynamic a) => Album.fromSQL(a))
            .toList();
    List<Album> albums = [];
    for (Album al in rawAlbums) {
      List rawAlbum =
          await db!.query('Albums', where: 'id == ?', whereArgs: [al.id]);
      if (rawAlbums.isNotEmpty) {
        Album album = Album.fromSQL(rawAlbum[0]);

        List<Track> tracks = [];
        //Load tracks
        for (int i = 0; i < (album.tracks?.length ?? 0); i++) {
          var offlineTrack = await getOfflineTrack(album.tracks![i].id!);
          if (offlineTrack != null) tracks.add(offlineTrack);
        }
        album.tracks = tracks;
        album.artists = [a];

        albums.add(album);
      }
    }

    a.albums = albums.where((Album a) => a.id != null).toList();

    List<Playlist> rawPlaylists = [];
    for (Track t in a.topTracks) {
      for (dynamic p in (await db!
          .rawQuery('SELECT * FROM Playlists WHERE tracks LIKE "%${t.id}%"'))) {
        Playlist pl = Playlist.fromSQL(p);
        if (!pl.isIn(rawPlaylists)) {
          rawPlaylists.add(await getOfflinePlaylist(pl.id ?? '') ?? Playlist());
        }
      }
    }
    a.playlists = rawPlaylists.where((Playlist p) => p.id != null).toList();

    return a;
  }

  //Get all offline playlists
  Future<List<Playlist>> getOfflinePlaylists() async {
    List rawPlaylists = await db!.query('Playlists',
        columns: ['id'],
        where: 'id != ?',
        whereArgs: [deezerAPI.favoritesPlaylistId ?? '']);
    List<Playlist> out = [];
    for (Map rawPlaylist in rawPlaylists) {
      var offlinePlayList = await getOfflinePlaylist(rawPlaylist['id']);
      if (offlinePlayList != null) out.add(offlinePlayList);
    }
    return out;
  }

  //Get offline playlist
  Future<Playlist?> getOfflinePlaylist(String id) async {
    List rawPlaylists =
        await db!.query('Playlists', where: 'id == ?', whereArgs: [id]);
    if (rawPlaylists.isEmpty) return null;

    Playlist playlist = Playlist.fromSQL(rawPlaylists[0]);
    //Load tracks
    List<Track> tracks = [];
    if (playlist.tracks != null) {
      for (Track t in playlist.tracks!) {
        var offlineTrack = await getOfflineTrack(t.id!);
        if (offlineTrack != null) tracks.add(offlineTrack);
      }
    }
    playlist.tracks = tracks;
    return playlist;
  }

  Future removeOfflineTracks(List<Track> tracks) async {
    for (Track t in tracks) {
      //Check if library
      List rawTrack = await db!.query('Tracks',
          where: 'id == ?', whereArgs: [t.id], columns: ['favorite']);
      if (rawTrack.isNotEmpty) {
        //Count occurrences in playlists and albums
        List albums = await db!
            .rawQuery('SELECT (id) FROM Albums WHERE tracks LIKE "%${t.id}%"');
        List playlists = await db!.rawQuery(
            'SELECT (id) FROM Playlists WHERE tracks LIKE "%${t.id}%"');
        if (albums.length + playlists.length == 0 &&
            rawTrack[0]['favorite'] == 0) {
          //Safe to remove
          await db!.delete('Tracks', where: 'id == ?', whereArgs: [t.id]);
        } else {
          await db!.update('Tracks', {'offline': 0},
              where: 'id == ?', whereArgs: [t.id]);
        }
      }

      //Remove file
      try {
        if (await File(p.join(offlinePath!, t.id)).exists()) {
          File(p.join(offlinePath!, t.id)).delete();
        }
      } catch (e) {
        Logger.root.severe('Error deleting offline track: ${t.id}', e);
      }
    }
  }

  Future removeOfflineAlbum(String id) async {
    //Get album
    List rawAlbums =
        await db!.query('Albums', where: 'id == ?', whereArgs: [id]);
    if (rawAlbums.isEmpty) return;
    Album album = Album.fromSQL(rawAlbums[0]);
    //Remove album
    await db!.delete('Albums', where: 'id == ?', whereArgs: [id]);
    //Remove tracks
    await removeOfflineTracks(album.tracks!);
  }

  Future removeOfflinePlaylist(String id) async {
    //Fetch playlist
    List rawPlaylists =
        await db!.query('Playlists', where: 'id == ?', whereArgs: [id]);
    if (rawPlaylists.isEmpty) return;
    Playlist playlist = Playlist.fromSQL(rawPlaylists[0]);
    //Remove playlist
    await db!.delete('Playlists', where: 'id == ?', whereArgs: [id]);
    await removeOfflineTracks(playlist.tracks!);
  }

  //Check if album, track or playlist is offline
  Future<bool> checkOffline(
      {Album? album, Track? track, Playlist? playlist}) async {
    if (track != null) {
      //Track
      List res = await db!.query('Tracks',
          where: 'id == ? AND offline == 1', whereArgs: [track.id]);
      if (res.isEmpty) return false;
      return true;
    } else if (album != null) {
      //Album
      List res = await db!.query('Albums',
          where: 'id == ? AND offline == 1', whereArgs: [album.id]);
      if (res.isEmpty) return false;
      return true;
    } else if (playlist != null) {
      //Playlist
      List res = await db!
          .query('Playlists', where: 'id == ?', whereArgs: [playlist.id]);
      if (res.isEmpty) return false;
      return true;
    }
    return false;
  }

  //Offline search
  Future<InstantSearchResults> search(String query) async {
    InstantSearchResults results = InstantSearchResults(
        tracks: [],
        albums: [],
        artists: [],
        playlists: [],
        shows: [],
        episodes: []);

    //Artists
    List artistData =
        await db!.rawQuery('SELECT * FROM Artists WHERE name like "%$query%"');
    for (Map rawArtist in artistData) {
      var offlineArtist = await getOfflineArtist(rawArtist['id']);
      if (offlineArtist != null) results.artists!.add(offlineArtist);
    }

    //Tracks
    List tracksData = await db!.rawQuery(
        'SELECT * FROM Tracks WHERE offline == 1 AND title like "%$query%"');
    for (Map trackData in tracksData) {
      var offlineTrack = await getOfflineTrack(trackData['id']);
      if (offlineTrack != null) results.tracks!.add(offlineTrack);
    }

    //Tracks from artists
    for (Artist artist in (results.artists ?? [])) {
      List tracksData = await db!.rawQuery(
          'SELECT * FROM Tracks WHERE offline == 1 AND artists like "%${artist.id}%"');
      for (Map trackData in tracksData) {
        var offlineTrack = await getOfflineTrack(trackData['id']);
        if (offlineTrack != null) results.tracks!.add(offlineTrack);
      }
    }

    //Albums
    List albumsData = await db!.rawQuery(
        'SELECT (id) FROM Albums WHERE offline == 1 AND title like "%$query%"');
    for (Map rawAlbum in albumsData) {
      var offlineAlbum = await getOfflineAlbum(rawAlbum['id']);
      if (offlineAlbum != null) results.albums!.add(offlineAlbum);
    }

    //Albums from artists
    for (Artist artist in (results.artists ?? [])) {
      List albumsData = await db!.rawQuery(
          'SELECT (id) FROM Albums WHERE offline == 1 AND artists like "%${artist.id}%"');
      for (Map rawAlbum in albumsData) {
        var offlineAlbum = await getOfflineAlbum(rawAlbum['id']);
        if (offlineAlbum != null) results.albums!.add(offlineAlbum);
      }
    }

    //Playlists
    List playlists = await db!
        .rawQuery('SELECT * FROM Playlists WHERE title like "%$query%"');
    for (Map playlist in playlists) {
      var offlinePlaylist = await getOfflinePlaylist(playlist['id']);
      if (offlinePlaylist != null) results.playlists!.add(offlinePlaylist);
    }

    List showData =
        await db!.rawQuery('SELECT * FROM Shows WHERE name like "%$query%"');
    for (Map show in showData) {
      var offlineShow = await getOfflineShow(show['id']);
      if (offlineShow != null) results.shows?.add(offlineShow);
    }

    for (Show s in (results.shows ?? [])) {
      List showEpisodeData = await db!
          .rawQuery('SELECT * FROM Episodes WHERE showId like "${s.id}"');
      for (Map episode in showEpisodeData) {
        var offlineEpisode = await getOfflineEpisode(episode['id']);
        if (offlineEpisode != null) results.episodes?.add(offlineEpisode);
      }
    }

    List episodeData = await db!
        .rawQuery('SELECT * FROM Episodes WHERE title like "%$query%"');
    for (Map episode in episodeData) {
      var offlineEpisode = await getOfflineEpisode(episode['id']);
      if (offlineEpisode != null) results.episodes?.add(offlineEpisode);
    }

    return results;
  }

  //Sanitize filename
  String sanitize(String input) {
    RegExp sanitize = RegExp(r'[\/\\\?\%\*\:\|\"\<\>]');
    return input.replaceAll(sanitize, '');
  }

  //Generate track download path
  String _generatePath(String id, bool private,
      {String? playlistName,
      int? playlistTrackNumber,
      int? diskNumber,
      bool isSingleton = false}) {
    String path;
    if (private) {
      path = p.join(offlinePath!, id);
    } else {
      //Download path
      path = settings.downloadPath ?? '';

      if ((settings.playlistFolder) && playlistName != null) {
        path = p.join(path, sanitize(playlistName));
      }

      if (settings.artistFolder) path = p.join(path, '%albumArtist%');

      //Album folder / with disk number
      if (settings.albumFolder) {
        if (settings.albumDiscFolder) {
          path = p.join(
              path, '%album%' + ' - Disk ' + (diskNumber ?? 1).toString());
        } else {
          path = p.join(path, '%album%');
        }
      }
      //Final path
      path = p.join(path,
          isSingleton ? settings.singletonFilename : settings.downloadFilename);
      //Playlist track number variable (not accessible in service)
      if (playlistTrackNumber != null) {
        path = path.replaceAll(
            '%playlistTrackNumber%', playlistTrackNumber.toString());
        path = path.replaceAll('%0playlistTrackNumber%',
            playlistTrackNumber.toString().padLeft(2, '0'));
      } else {
        path = path.replaceAll('%playlistTrackNumber%', '');
        path = path.replaceAll('%0playlistTrackNumber%', '');
      }
    }
    return path;
  }

  //Get stats for library screen
  Future<List<String>> getStats() async {
    //Get offline counts
    int? trackCount = Sqflite.firstIntValue(
        (await db!.rawQuery('SELECT COUNT(*) FROM Tracks WHERE offline == 1')));
    int? albumCount = Sqflite.firstIntValue(
        (await db!.rawQuery('SELECT COUNT(*) FROM Albums WHERE offline == 1')));
    int? playlistCount = Sqflite.firstIntValue(
        (await db!.rawQuery('SELECT COUNT(*) FROM Playlists')));
    //Free space
    //double diskSpace = await DiskSpacePlus.getFreeDiskSpace ?? 0;
    double diskSpace = 0;
    //Used space
    List<FileSystemEntity> offlineStat =
        await Directory(offlinePath!).list().toList();
    int offlineSize = 0;
    for (var fs in offlineStat) {
      offlineSize += (await fs.stat()).size;
    }
    //Return in list
    return ([
      trackCount.toString(),
      albumCount.toString(),
      playlistCount.toString(),
      filesize(offlineSize),
      filesize((diskSpace * 1000000).floor())
    ]);
  }

  //Send settings to download service
  Future updateServiceSettings() async {
    await platform.invokeMethod(
        'updateSettings', settings.getServiceSettings());
  }

  //Check storage permission
  Future<bool> checkPermission() async {
    //if (await FileUtils.checkManageStoragePermission(
    //    openStoragePermissionSettingsDialog)) {
    if (await FileUtils.checkExternalStoragePermissions(
      openStoragePermissionSettingsDialog,
    )) {
      return true;
    } else {
      Fluttertoast.showToast(
          msg: 'Storage permission denied!'.i18n,
          toastLength: Toast.LENGTH_SHORT,
          gravity: ToastGravity.BOTTOM);
      return false;
    }
  }

  //Remove download from queue/finished
  Future removeDownload(int id) async {
    await platform.invokeMethod('removeDownload', {'id': id});
  }

  //Restart failed downloads
  Future retryDownloads() async {
    //Permission
    if (!(await checkPermission())) return;
    await platform.invokeMethod('retryDownloads');
  }

  //Delete downloads by state
  Future removeDownloads(DownloadState state) async {
    await platform.invokeMethod(
        'removeDownloads', {'state': DownloadState.values.indexOf(state)});
  }
}

class Download {
  int? id;
  String? path;
  bool? private;
  String? trackId;
  String? streamTrackId;
  String? trackToken;
  String? md5origin;
  String? mediaVersion;
  String? title;
  String? image;
  int? quality;
  bool? isEpisode;
  String? url;
  //Dynamic
  DownloadState? state;
  int? received;
  int? filesize;

  Download({
    this.id,
    this.path,
    this.private,
    this.trackId,
    this.streamTrackId,
    this.trackToken,
    this.md5origin,
    this.mediaVersion,
    this.title,
    this.image,
    this.state,
    this.received,
    this.filesize,
    this.quality,
    this.isEpisode,
    this.url,
  });

  //Get progress between 0 - 1
  double get progress {
    return ((received?.toDouble() ?? 0.0) / (filesize?.toDouble() ?? 1.0))
        .toDouble();
  }

  factory Download.fromJson(Map<dynamic, dynamic> data) {
    return Download(
      path: data['path'],
      image: data['image'],
      private: data['private'],
      trackId: data['trackId'],
      id: data['id'],
      state: DownloadState.values[data['state']],
      title: data['title'],
      quality: data['quality'],
      isEpisode: data['isEpisode'] == 1,
    );
  }

  //Change values from "update json"
  void updateFromJson(Map<dynamic, dynamic> data) {
    quality = data['quality'];
    received = data['received'] ?? 0;
    state = DownloadState.values[data['state']];
    //Prevent null division later
    filesize = ((data['filesize'] ?? 0) <= 0) ? 1 : (data['filesize'] ?? 1);
  }

  //Track to download JSON for service
  static Future<Map> jsonFromTrack(Track t, String path,
      {private = true, AudioQuality? quality}) async {
    //Get download info
    if (t.playbackDetails?.isEmpty ?? true) {
      t = await deezerAPI.track(t.id ?? '');
    }

    // Select playbackDetails for audio stream
    List<dynamic>? playbackDetails =
        t.playbackDetailsFallback?.isNotEmpty == true
            ? t.playbackDetailsFallback
            : t.playbackDetails;

    return {
      'private': private,
      'trackId': t.id,
      'streamTrackId': t.fallback?.id ?? t.id,
      'md5origin': playbackDetails?[0],
      'mediaVersion': playbackDetails?[1],
      'trackToken': playbackDetails?[2],
      'quality': private
          ? settings.getQualityInt(settings.offlineQuality)
          : settings.getQualityInt((quality ?? settings.downloadQuality)),
      'title': t.title,
      'path': path,
      'image': t.image?.thumb,
      'isEpisode': false,
    };
  }

  static Future<Map> jsonFromEpisode(ShowEpisode e, String path,
      {private = true}) async {
    return {
      'private': private,
      'trackId': e.id,
      'url': e.url,
      'title': e.title,
      'path': path,
      'image': e.episodeCover?.thumb,
      'quality': 1,
      'isEpisode': true,
    };
  }
}

//Has to be same order as in java
enum DownloadState { NONE, DOWNLOADING, POST, DONE, DEEZER_ERROR, ERROR }
