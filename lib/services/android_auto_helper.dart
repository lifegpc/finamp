import 'package:audio_service/audio_service.dart';
import 'package:collection/collection.dart';
import 'package:get_it/get_it.dart';

import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/models/finamp_models.dart';
import 'downloads_helper.dart';
import 'finamp_user_helper.dart';
import 'jellyfin_api_helper.dart';
import 'finamp_settings_helper.dart';
import 'queue_service.dart';

class AndroidAutoHelper {
  final _finampUserHelper = GetIt.instance<FinampUserHelper>();
  final _jellyfinApiHelper = GetIt.instance<JellyfinApiHelper>();
  final _downloadsHelper = GetIt.instance<DownloadsHelper>();

  Future<BaseItemDto?> getItemFromId(String itemId) async {
    if (itemId == '-1') return null;
    return _downloadsHelper.getDownloadedParent(itemId)?.item ?? await _jellyfinApiHelper.getItemById(itemId);
  }

  Future<List<BaseItemDto>> getBaseItems(String type, String categoryId, String? itemId) async {
    final tabContentType = TabContentType.values.firstWhere((e) => e.name == type);

    // limit amount so it doesn't crash on large libraries
    // TODO: somehow load more after the limit
    //       a problem with this is: how? i don't *think* there is a callback for scrolling. maybe there could be a button to load more?
    const limit = 100;

    // if we are in offline mode, only get downloaded parents for categories
    if (FinampSettingsHelper.finampSettings.isOffline) {
      List<BaseItemDto> baseItems = [];

      // root category, get all matching parents
      if (categoryId == '-1') {
        for (final downloadedParent in _downloadsHelper.downloadedParents) {
          if (baseItems.length >= limit) break;
          if (downloadedParent.item.type == tabContentType.itemType()) {
            baseItems.add(downloadedParent.item);
          }
        }
      } else {
        // specific category, get all items in category
        var downloadedParent = _downloadsHelper.getDownloadedParent(categoryId);
        if (downloadedParent != null) {
          baseItems.addAll([for (final child in downloadedParent.downloadedChildren.values.whereIndexed((i, e) => i < limit)) child]);
        }
      }
      return baseItems;
    }
    // fetch the online version if we aren't in offline mode

    final sortBy = tabContentType == TabContentType.artists ? "ProductionYear,PremiereDate" : "SortName";

    // select the item type that each category holds
    final includeItemTypes = categoryId != '-1' // if categoryId is -1, we are browsing a root library. e.g. browsing the list of all albums or artists
        ? (tabContentType == TabContentType.albums ? TabContentType.songs.itemType() // get an album's songs
        : tabContentType == TabContentType.artists ? TabContentType.albums.itemType() // get an artist's albums
        : tabContentType == TabContentType.playlists ? TabContentType.songs.itemType() // get a playlist's songs
        : tabContentType == TabContentType.genres ? TabContentType.albums.itemType() // get a genre's albums
        : throw FormatException("Unsupported TabContentType `$tabContentType`"))
        : tabContentType.itemType(); // get the root library

    // if category id is defined, use that to get items.
    // otherwise, use the current view as fallback to ensure we get the correct items.
    final parentItem = categoryId != '-1'
        ? BaseItemDto(id: categoryId, type: tabContentType.itemType())
        : _finampUserHelper.currentUser?.currentView;

    final items = await _jellyfinApiHelper.getItems(parentItem: parentItem, sortBy: sortBy, includeItemTypes: includeItemTypes, isGenres: tabContentType == TabContentType.genres, limit: limit);
    return items != null ? [for (final item in items) item] : [];
  }

  Future<List<MediaItem>> getMediaItems(String type, String categoryId, String? itemId) async {
    return [ for (final item in await getBaseItems(type, categoryId, itemId)) await _convertToMediaItem(item, categoryId) ];
  }

  Future<void> playFromMediaId(String type, String categoryId, String? itemId) async {
    final tabContentType = TabContentType.values.firstWhere((e) => e.name == type);

    // shouldn't happen, but just in case
    if (!_isPlayable(tabContentType)) return;

    // get all songs in current category
    final parentItem = await getItemFromId(categoryId);
    final categoryBaseItems = await getBaseItems(type, categoryId, itemId);

    // queue service should be initialized by time we get here
    final queueService = GetIt.instance<QueueService>();
    await queueService.startPlayback(items: categoryBaseItems, source: QueueItemSource(
      type: tabContentType == TabContentType.playlists
          ? QueueItemSourceType.playlist
          : QueueItemSourceType.album,
      name: QueueItemSourceName(
          type: QueueItemSourceNameType.preTranslated,
          pretranslatedName: parentItem?.name),
      id: parentItem?.id ?? categoryId,
      item: parentItem,
    ));
  }

  // albums, playlists, and songs should play when clicked
  // genres and artists have subcategories, so they should be browsable but not playable
  bool _isPlayable(TabContentType tabContentType) {
    return tabContentType == TabContentType.albums || tabContentType == TabContentType.playlists || tabContentType == TabContentType.songs;
  }

  Future<MediaItem> _convertToMediaItem(BaseItemDto item, String categoryId) async {
    final tabContentType = TabContentType.fromItemType(item.type!);
    var newId = '${tabContentType.name}|';
    // if item is a parent type (category), set newId to 'type|categoryId'. otherwise, if it's a specific item (song), set it to 'type|categoryId|itemId'
    if (item.isFolder ?? tabContentType != TabContentType.songs && categoryId == '-1') {
      newId += item.id;
    } else {
      newId += '$categoryId|${item.id}';
    }

    return MediaItem(
      id: newId,
      playable: _isPlayable(tabContentType), // this dictates whether clicking on an item will try to play it or browse it
      album: item.album,
      artist: item.artists?.join(", ") ?? item.albumArtist,
      // TODO: may need to download image locally to display it - https://developer.android.com/training/cars/media#display-artwork
      //       specifically android automotive systems seem to not display artwork
      //       and offline mode doesn't display artwork either
      //       both of these probably need a custom ContentProvider
      artUri: _downloadsHelper.getDownloadedImage(item)?.file.uri ??
          _jellyfinApiHelper.getImageUrl(item: item), // ?.replace(scheme: "content"),
      title: item.name ?? "unknown",
      // Jellyfin returns microseconds * 10 for some reason
      duration: Duration(
        microseconds:
        (item.runTimeTicks == null ? 0 : item.runTimeTicks! ~/ 10),
      ),
    );
  }
}