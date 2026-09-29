# GassPlayer IPTV

> A native, modern iOS IPTV player built around **Xtream Codes and M3U/M3U8 playlists**, with EPG, catch-up, VOD and series playback, metadata enrichment, favourites, content management, downloads, parental controls, cloud synchronization, advanced playback controls, and an integrated VPN architecture.

[![iOS](https://img.shields.io/badge/iOS-17.0%2B-0A84FF?logo=apple&logoColor=white)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-5.10-F05138?logo=swift&logoColor=white)](#technology)
[![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-0A84FF?logo=swift&logoColor=white)](#technology)
[![Build](https://img.shields.io/github/actions/workflow/status/iamgasgass/GassPlayer-IPTV/build.yml?branch=main&label=build)](https://github.com/iamgasgass/GassPlayer-IPTV/actions)
[![License](https://img.shields.io/badge/License-MIT-lightgrey)](#license)

## Overview

**GassPlayer IPTV** is a native iOS media application designed to bring IPTV, VOD and series content together inside a single SwiftUI interface.

The application is built around a central source/catalog architecture rather than treating every playlist as an isolated player. Xtream Codes accounts and M3U/M3U8 playlists can be stored locally, verified, reordered, enabled or disabled, pinned, duplicated, exported and combined into merged playlists. Active catalog data is cached and refreshed independently from the presentation layer, allowing the interface to remain responsive while large provider catalogs are loaded.

The player is powered by **KSPlayer** and is designed for both live television and on-demand playback. It exposes advanced controls for quality, playback speed, buffering, seeking, FFmpeg decoding, audio and subtitles, video delay, aspect ratio, loop playback and other playback-engine options. The player also includes PiP, AirPlay integration, channel history, previous/next navigation, screen locking, gesture controls, external-player handoff and a sleep timer.

For live television, GassPlayer includes a full electronic programme guide with short and full EPG retrieval, timeline/grid presentation, channel grouping, favourites, current-program progress, programme details, reminders and catch-up playback when the provider exposes archive data.

For movies and series, the application can enrich provider metadata through **TMDB**, **OMDb** and **Trakt**, display posters, backdrops, genres, cast and ratings, keep watch progress, resume playback, download supported VOD/episode streams and expose alternate sources when the same content exists on another configured provider.

The application also includes a parental-lock system, local search history, global content search, persistent caches, optional iCloud key-value synchronization, JSON backup/import flows, a debug console, network diagnostics, theme and layout preferences, and a personal VPN management layer.

This is not a web wrapper. GassPlayer is a native SwiftUI application using Apple's networking, notification, media, Network Extension and system-integration APIs together with KSPlayer for playback.

## Highlights

- Native SwiftUI IPTV interface targeting iOS 17.0+.
- Xtream Codes authentication with account status, expiry and connection information.
- Live TV, VOD movies and TV series catalogues from Xtream providers.
- M3U/M3U8 playlist import and parsing with `EXTINF`, logos, groups, TVG identifiers and content-type detection.
- Multiple configurable media sources with active-source switching.
- Source pinning, enable/disable state, sorting, renaming, duplication, connection verification and deletion.
- JSON export/import for source configuration and preferences.
- Merged playlists combining multiple configured sources into one logical catalogue.
- Persistent local catalogue caching with scheduled refresh and source-aware cache isolation.
- Retry policy and defensive decoding for inconsistent Xtream provider payloads.
- Category-aware channel and VOD navigation.
- Grid and list presentation for live channels.
- Dedicated movie detail and series/episode detail screens.
- Continue Watching and recently watched history.
- Separate favourites for Live TV, movies and series.
- Global search across available catalogue content with persistent search history.
- Full EPG with short/full provider fallback, caching, timeline navigation and day switching.
- Catch-up/timeshift playback when provider archive data is available.
- Programme reminders through local notifications.
- EPG layout, density, channel-card and colour customization.
- TMDB metadata enrichment for movies and series.
- OMDb ratings including IMDb, Rotten Tomatoes and Metacritic when an API key is configured.
- Trakt ratings, device-flow account connection and scrobbling support.
- OpenSubtitles search integration.
- Advanced KSPlayer-based playback with quality and track selection.
- Picture-in-Picture support.
- AirPlay audio and video integration.
- External player handoff for supported installed players.
- Playback speed selection and skip/seek controls.
- Screen lock while watching.
- Sleep timer.
- Channel history and previous/next channel navigation.
- Advanced FFmpeg and buffering controls.
- Video/audio synchronization delay.
- Hardware and software decoding preferences.
- Accurate seek and configurable FFmpeg seek behaviour.
- Embedded subtitle selection and subtitle persistence options.
- 360°/panorama rendering controls.
- Adaptive bitrate / automatic quality switching.
- Loop playback and HTTP cache controls.
- VOD and series episode background downloads with Wi-Fi-only preference.
- Parental PIN protection with category/content locking.
- iCloud key-value synchronization for sources, favourites and watch progress.
- Local cache management and cache diagnostics.
- Debug console and exportable debug logs.
- Network/ATS diagnostics.
- Theme selection and compact/comfortable content density.
- Italian, English and Spanish language options exposed by the settings layer.
- Personal VPN configuration architecture with native IKEv2 and Packet Tunnel integration for WireGuard.
- Provider-derived VPN configuration discovery for compatible Xtream panels.
- GitHub Actions CI with duplicate-file verification, SwiftLint, unit tests and unsigned IPA/archive build support.
- XcodeGen-based project generation for reproducible local and CI builds.

## Interface

### Home

The Home screen acts as the central library dashboard instead of simply being a list of channels.

It exposes:

- Continue Watching.
- Favourite Live TV channels.
- Favourite VOD movies.
- Favourite series.
- Quick access to Live TV, VOD and series sections.
- Quick access to the TV Guide.
- Active source selection.
- Source management.
- Empty-library and source-ready states.
- Navigation to the configured content libraries.

The Home view is driven by persisted application state, so recently watched items and favourites remain available across launches.

### Live TV

Live television is available through category-aware channel browsing.

- Channel grid presentation.
- Optional list-style channel presentation.
- Category/group filtering.
- Channel numbering where available.
- Channel logos.
- Current-program information when EPG data is available.
- Favourite channels.
- Fast adjacent-channel navigation.
- Multi-source catalogue support.
- Unified browsing of merged playlists.
- Direct playback from channel tiles.
- EPG prefetching for visible channels.

### VOD

Movies are presented as first-class media items rather than raw stream URLs.

A movie detail page can combine:

- Provider title and stream information.
- Poster and backdrop imagery.
- Synopsis.
- Genres.
- Cast.
- Provider metadata.
- TMDB metadata.
- IMDb rating.
- Rotten Tomatoes score.
- Metacritic score.
- Trakt rating.
- Favourite state.
- Alternate source discovery.
- Playback.
- Download.
- Resume/watch-progress behaviour.

Metadata enrichment is optional and degrades gracefully when an external service or API key is unavailable.

### TV Series

Series support includes:

- Series catalogue browsing.
- Series detail pages.
- Season selection.
- Episode lists.
- Episode thumbnails when available.
- Resume episode handling.
- Automatic continuation to the next episode.
- Previous/next episode navigation.
- Recently watched tracking.
- Download of supported episodes.
- Alternate series sources.
- TMDB metadata enrichment.
- Trakt integration where configured.

## Browser and Source Capabilities

### Xtream Codes

GassPlayer implements the main Xtream catalogue flow using the provider's `player_api.php` API.

| Capability | Behaviour |
|---|---|
| Authentication | Validates username, password and server endpoint. |
| Account Information | Reads account status, expiry date, active connections and maximum connections. |
| Live Categories | Loads `get_live_categories`. |
| VOD Categories | Loads `get_vod_categories`. |
| Series Categories | Loads `get_series_categories`. |
| Live Streams | Loads `get_live_streams`. |
| VOD Streams | Loads `get_vod_streams`. |
| Series List | Loads `get_series`. |
| VOD Details | Loads `get_vod_info`. |
| Series Details | Loads `get_series_info`. |
| Stream URLs | Builds provider stream URLs from the configured credentials and stream identifier. |
| Flexible Decoding | Accepts common provider inconsistencies such as numbers returned as strings. |
| Catalog Recovery | Recovers categories missing from an incomplete global stream response. |
| Deduplication | Removes duplicated stream IDs while preserving stable ordering. |
| Account Verification | Allows a source to be checked without forcing playback authentication semantics. |

The catalog loader is optimized to avoid unnecessarily querying every category when the provider's global stream endpoint already contains the complete catalogue.

### M3U / M3U8

The M3U parser supports common IPTV metadata including:

- `#EXTINF`.
- Channel/movie/series title.
- `tvg-logo`.
- `group-title`.
- `tvg-id`.
- `tvg-type`.
- Stream URL.
- UTF-8 and ISO-8859-1 decoding fallback.
- Automatic content classification.

Content classification follows this order:

1. Explicit `tvg-type`.
2. Keywords in `group-title`.
3. `SxxExx` patterns in the title.
4. Live TV fallback.

This allows many heterogeneous IPTV playlists to be imported without requiring a separate proprietary playlist format.

### Additional Source Types

The source model exposes configuration types for:

- Xtream Codes.
- M3U / M3U8.
- Plex.
- Jellyfin.
- Emby.

The current codebase provides dedicated catalogue/API implementations for Xtream and M3U/M3U8. Plex, Jellyfin and Emby are represented in the source-management model and UI, but the repository does not currently contain dedicated API service layers equivalent to `XtreamAPIService` for those platforms. They should therefore be considered source-type foundations rather than fully implemented independent catalog backends.

## Source Management

GassPlayer treats media providers as persistent first-class objects.

| Capability | Behaviour |
|---|---|
| Add Source | Creates a new configured provider/playlist. |
| Edit Source | Changes name, endpoint, credentials and presentation metadata. |
| Rename | Changes the local display name without changing provider credentials. |
| Duplicate | Creates a copy of an existing source configuration. |
| Delete | Removes the source and its stored configuration. |
| Enable/Disable | Controls whether the source participates in the active catalogue. |
| Pin | Moves important sources to the top of the source list. |
| Sort | Supports manual and alternate sorting modes. |
| Verify | Tests source connectivity and records the verification result. |
| Verify All | Checks all applicable Xtream sources. |
| Active Source | Selects the provider used by the primary catalogue views. |
| Custom Icon | Assigns a local icon to a source. |
| Verification State | Stores last verification date, result and known Xtream channel count. |
| JSON Export | Exports source definitions for backup or transfer. |
| JSON Import | Imports compatible source backups while avoiding duplicate host/user combinations. |
| Merge | Combines multiple sources into a single logical playlist. |

> Source backup JSON can contain usernames, passwords and tokens. Treat exported files as sensitive configuration data and only share them through trusted channels.

## Merged Playlists

The content-management layer can create virtual playlists from multiple configured sources.

Merged playlists support:

- Multiple member sources.
- Custom playlist names.
- Rename.
- Delete.
- Manual reordering.
- Persistent storage.
- Unified catalogue presentation.

This makes it possible to expose several providers as one logical Live TV/VOD/series library without modifying the underlying source configurations.

## EPG — Electronic Programme Guide

GassPlayer includes a dedicated EPG subsystem for Xtream sources.

### EPG Retrieval

The EPG service supports:

- `get_short_epg`.
- Automatic fallback to `get_simple_data_table`.
- Short EPG caching.
- Full EPG caching.
- Per-channel invalidation.
- Global EPG cache clearing.
- Flexible timestamp decoding.
- Unix timestamps expressed in seconds or milliseconds.
- Multiple textual date formats.
- Base64 decoding when appropriate.
- Program normalization and deduplication.
- Provider payloads that return empty/scalar responses.

### EPG Interface

The EPG grid provides:

- Channel rows.
- Time-based horizontal timeline.
- Current-time indicator.
- Today / yesterday / tomorrow navigation.
- Channel-group filtering.
- Current-program indication.
- Program progress.
- Program details.
- Live playback.
- Catch-up playback when available.
- Program reminders.
- Favourite channels.
- Lazy loading of additional channel rows.
- Multiple density modes.
- Multiple channel-card styles.
- Dynamic or dark tile colour modes.
- Configurable guide presentation.

### Catch-Up / Timeshift

For providers exposing archive playback, GassPlayer constructs a provider timeshift URL from:

- Channel/stream ID.
- Program start time.
- Program duration.
- Xtream credentials.

A programme with archive availability can therefore be played from its historical position rather than only watched live.

### Programme Reminders

Users can schedule local notifications for upcoming programmes.

The reminder subsystem handles:

- Notification authorization.
- Reminder scheduling.
- Reminder cancellation.
- EPG programme association.

## Player

The playback layer is built around **KSPlayer** and is designed to expose both conventional player controls and advanced streaming-engine settings.

### Playback

The player supports:

- Live streams.
- Movies.
- Series episodes.
- Play/pause.
- Seek.
- Skip.
- Previous/next content.
- Playback speed.
- Quality selection.
- Audio track selection.
- Subtitle selection.
- Embedded subtitle handling.
- Video delay.
- Aspect-ratio selection.
- Loop playback.
- Adaptive quality.
- Channel history.
- Screen lock.
- Sleep timer.
- Retry/reload after playback errors.
- External-player handoff.

### Gestures and HUD

The player includes gesture-driven interaction for:

- Single tap control visibility.
- Double-tap actions.
- Volume/brightness interaction.
- Playback HUD feedback.
- Auto-hiding controls.
- Haptic feedback.
- Toast-style player messages.

### Picture in Picture

PiP support is integrated into the playback layer for compatible streams and devices, allowing playback to continue while navigating elsewhere in iOS.

### AirPlay

The player exposes:

- AirPlay audio.
- AirPlay video.
- Native iOS route selection.

### External Players

GassPlayer can detect and hand off playback to supported installed players, including schemes registered for applications such as:

- VLC.
- VLC X-Callback.
- Infuse.
- OutPlayer.

External playback depends on the corresponding application being installed and accepting the requested URL/scheme.

### Chromecast

The player UI exposes a Chromecast action point, but the repository explicitly treats Google Cast support as dependent on adding the Google Cast SDK. It is not equivalent to the native AirPlay integration.

## Advanced Playback Settings

GassPlayer exposes a large set of KSPlayer/FFmpeg controls for users who need to tune difficult streams.

### Buffering

- Minimum buffer duration.
- Maximum buffer duration.
- Configurable buffering behaviour.
- Explanatory UI for unstable connections.

### Decoding

- VideoToolbox hardware decoding.
- Asynchronous hardware decompression.
- Synchronous video decoding.
- Synchronous audio decoding.
- FFmpeg low-resolution decoding modes.
- Full resolution.
- Half resolution.
- Quarter resolution.
- Audio-only mode.
- Fast second-open mode.
- Automatic deinterlacing.

### Synchronization

- Video delay from negative to positive offsets.
- Audio/video synchronization reset.
- Visual explanation of delay direction.

### Seeking

- Accurate seek.
- FFmpeg seek-mode selection.
- Automatic resume after seeking.

### Subtitles

- Automatic embedded subtitle selection.
- Image subtitle preservation during seek.
- Text subtitles.
- Image subtitles such as PGS/DVB/DVD where supported by the playback stack.
- Closed captions where exposed by the stream.

### Panorama / 360°

The player exposes panorama rendering controls for equirectangular 360° material, including automatic rotation based on metadata where available.

### Network and FFmpeg

Advanced settings also expose:

- Adaptive bitrate / automatic quality switching.
- HTTP cache.
- FFmpeg filter chains.
- Advanced FFmpeg options.
- Playback state and retry controls.

These settings are intended for advanced users because incompatible combinations can prevent a stream from opening correctly. The player provides a retry path that reloads the stream with the current settings.

## Downloads

GassPlayer includes a background download subsystem for supported VOD and episode streams.

| Capability | Behaviour |
|---|---|
| Background Session | Uses `URLSessionConfiguration.background`. |
| Progress | Publishes per-download progress. |
| Persistent Preference | Remembers Wi-Fi-only mode. |
| Wi-Fi Only | Prevents new downloads from using cellular data when enabled. |
| File Storage | Stores completed downloads in the app's Documents directory. |
| Movie Downloads | Available from supported movie detail flows. |
| Episode Downloads | Available from supported series episode flows. |
| Shared Manager | Central `DownloadManager` keeps progress consistent across views. |

The current implementation uses a background `URLSession` rather than a WebKit download pipeline. The download destination currently uses an `.mp4` filename based on the generated download identifier, so it should be considered optimized for the VOD/episode streams targeted by the application rather than a generic arbitrary-file download manager.

## Metadata and Discovery

### TMDB

The TMDB service can enrich provider content with:

- Movie search.
- TV/series search.
- Details.
- Genres.
- Credits.
- Top cast.
- Backdrops and images.
- Logos.
- External IDs.
- Poster enrichment.

Queries are normalized and cached in memory to avoid repeated requests during a session.

### OMDb

OMDb can supplement metadata with ratings not always exposed by the primary metadata provider.

Supported rating sources include:

- IMDb.
- Rotten Tomatoes.
- Metacritic.

An OMDb API key is required and can be configured in the application settings.

### Trakt

Trakt integration provides:

- Device authorization flow.
- User connection/disconnection.
- Movie/series community ratings.
- IMDb-based rating lookup.
- Playback scrobbling start.
- Playback scrobbling stop.
- Watch-progress reporting.

Trakt requires a configured client ID/client secret for authenticated account functionality.

### OpenSubtitles

The repository contains an OpenSubtitles search service for discovering subtitle results for supported media.

Availability depends on the provider response and configured integration requirements.

## Search

Global search operates across the available catalogue and can surface:

- Live channels.
- Movies.
- Series.

The search UI includes content filtering and opens the corresponding playback/detail flow.

Search history is persisted locally with:

- Duplicate suppression.
- Most-recent-first ordering.
- Removal of individual searches.
- Clear-all support.
- A bounded history size.

## Favourites

Favourites are managed as first-class content data.

Separate Home sections are provided for:

- Favourite Live TV.
- Favourite movies.
- Favourite series.

The same favourite identity scheme is used across catalogue and detail views so that the favourite state remains synchronized when the same item is displayed in different parts of the application.

## Continue Watching

Recently watched content is stored locally and surfaced from Home.

The system can retain:

- Content identity.
- Title.
- Kind.
- Playback URL.
- Watch position.
- Last watched date.
- Episode information where applicable.

For series, the episode flow can use the stored progress to resume the appropriate episode and continue into the next episode when available.

## Parental Lock

The application includes a local parental-control subsystem.

Features include:

- PIN setup.
- PIN verification.
- Locking.
- Unlocking.
- Per-category/content locking.
- Persistent lock state.
- Hashed PIN storage rather than keeping the raw PIN as the primary stored value.

The parental-lock manager is covered by unit tests for PIN setup, disabling and category locking.

## Settings and Personalization

### Theme

The application includes a theme manager and settings for visual presentation.

### Content Density

Two primary content-density modes are exposed:

- Compact.
- Comfortable.

### Language

The settings layer exposes:

- Italiano.
- English.
- Español.
- System/default behaviour where applicable.

### Active Source

The active Xtream source can be selected from the settings and Home interfaces.

### Cache Management

Settings expose catalogue/cache maintenance operations including:

- Refresh catalogue.
- Clear catalogue cache.
- Inspect system cache count.
- Clear system cache.
- Clear EPG cache.

### Playback Defaults

Playback defaults can be restored from settings.

### Backup and Restore

Application preferences can be exported to JSON and imported later.

The preferences backup layer is designed to serialize application configuration while keeping source-management semantics separate from normal preference restoration.

## Cloud Sync

GassPlayer contains an iCloud key-value synchronization layer for selected application data.

Synchronizable data includes:

- Source configurations.
- Favourite identifiers.
- Watch progress.

The implementation uses `NSUbiquitousKeyValueStore`.

Cloud synchronization is intentionally lightweight and should not be confused with full database synchronization or cloud storage of downloaded media files.

## VPN

GassPlayer contains a personal/provider VPN architecture based on Apple's Network Extension APIs.

### Supported Configuration Types

The VPN model defines:

- IKEv2.
- WireGuard.
- OpenVPN.

### IKEv2

IKEv2 is handled through the native iOS VPN stack (`NEVPNProtocolIKEv2`) and therefore uses the operating system's VPN implementation.

### WireGuard

The `PacketTunnelProvider` contains WireGuard configuration construction and integrates the `WireGuardAdapter` API.

A WireGuard configuration can include:

- Client private key.
- Server public key.
- Pre-shared key.
- Endpoint.
- Client address.
- DNS servers.
- Allowed IP ranges.
- MTU.

Secrets used by the tunnel can be referenced through the Keychain helper rather than being passed around as plain UI state.

### OpenVPN

OpenVPN is represented in the configuration model and personal VPN manager, but the current `PacketTunnelProvider` does not implement an OpenVPN engine. It must therefore not be presented as a completed OpenVPN client.

### Provider VPN Discovery

The Xtream service contains provider-VPN configuration discovery logic that attempts common panel endpoint patterns. This is necessarily provider-dependent because Xtream Codes does not define one universal VPN configuration endpoint.

A provider using a different endpoint may require an additional integration in `XtreamAPIService.swift`.

### VPN Safety

The VPN subsystem must never be interpreted as a generic VPN service simply because a profile can be configured. A usable encrypted tunnel requires a valid protocol implementation, credentials/keys and a compatible provider configuration.

## Network and Reliability

GassPlayer is designed to tolerate the inconsistent payloads frequently encountered in IPTV provider APIs.

### Flexible Decoding

Xtream models can tolerate common type mismatches such as:

- Numeric values encoded as strings.
- Strings encoded as numbers.
- Boolean values represented by `0`/`1`.
- Empty values.
- Optional provider fields.

### Retry Policy

Network operations can use a shared retry policy with bounded attempts and backoff.

The retry policy is unit tested for:

- Immediate success.
- Recovery after transient failures.
- Failure after the maximum number of attempts.

### Cache

The cache service supports:

- Typed values.
- Expiration.
- Per-key invalidation.
- Prefix invalidation.
- Expired-entry cleanup.
- Cache counting.
- Global clearing.

Separate cache namespaces are used for different subsystems such as EPG and Xtream catalog data.

### Persistent Catalog

Large Xtream catalogues can be persisted locally so the application can restore useful data without waiting for every provider request after launch.

The catalog store supports:

- Categories.
- Live streams.
- VOD streams.
- Series.
- Series details.
- VOD details.
- Source-aware snapshots.
- Stable cache filenames.
- Cache invalidation.
- Snapshot restoration.

## Debugging and Diagnostics

The project includes dedicated diagnostic tooling.

### Debug Logger

The debug logger supports:

- Structured log entries.
- Clearing logs.
- Exporting logs as text.
- Asynchronous logging from networking/catalog operations.

### Debug Console

A dedicated Debug Console view exposes application diagnostic information without requiring Xcode for every investigation.

### ATS Diagnostics

`ATSDiagnosticView` is included to inspect transport-security related conditions relevant to IPTV endpoints.

This is particularly useful because IPTV providers frequently expose HTTP endpoints, redirects or non-standard TLS configurations.

## Architecture

The codebase is organized around models, services, persistent stores, SwiftUI views and a separate Network Extension target.

```text
GassPlayer-IPTV/
├── .github/
│   ├── ISSUE_TEMPLATE/
│   │   ├── bug_report.yml
│   │   └── feature_request.yml
│   └── workflows/
│       └── build.yml                    # CI: verify -> lint -> test -> build/IPA
├── .swiftlint.yml                       # SwiftLint configuration
├── CHANGELOG.md
├── CONTRIBUTING.md
├── LICENSE
├── Makefile                             # Local build/generation shortcuts
├── project.yml                          # XcodeGen project definition
├── GassPlayer/
│   ├── App/
│   │   └── GassPlayerApp.swift          # Application entry point
│   ├── Models/
│   │   ├── CatchupModels.swift
│   │   ├── ContentManagementModels.swift
│   │   ├── DebugLogEntry.swift
│   │   ├── EPGExternalSource.swift
│   │   ├── EPGProgram.swift
│   │   ├── M3UModels.swift
│   │   ├── MediaDetail.swift
│   │   ├── MediaSource.swift
│   │   ├── ParentalLock.swift
│   │   ├── PersonalVPNConfig.swift
│   │   ├── VPNConfig.swift
│   │   ├── XtreamModels.swift
│   │   ├── XtreamSeriesModels.swift
│   │   └── XtreamVODModels.swift
│   ├── PacketTunnel/
│   │   ├── PacketTunnelProvider.swift   # Network Extension tunnel provider
│   │   └── TunnelKeychainHelper.swift
│   ├── Resources/
│   │   ├── Assets.xcassets/
│   │   ├── Info.plist
│   │   ├── GassPlayer.entitlements
│   │   └── GassPlayer-CI.entitlements
│   └── Services/
│       ├── AggregatedSourceService.swift
│       ├── AppPreferencesBackupCodec.swift
│       ├── CacheService.swift
│       ├── CatalogSettings.swift
│       ├── CloudSyncService.swift
│       ├── ContentManagementService.swift
│       ├── DebugLogger.swift
│       ├── DownloadManager.swift
│       ├── EPGManager.swift
│       ├── EPGService.swift
│       ├── FlexibleDecoding.swift
│       ├── GlobalSearchService.swift
│       ├── KSPlaybackController.swift
│       ├── M3UPlaylistService.swift
│       ├── M3UPlaylistStore.swift
│       ├── NavigationOverlayState.swift
│       ├── NetworkMonitor.swift
│       ├── OMDbService.swift
│       ├── OpenSubtitlesService.swift
│       ├── ParentalLockManager.swift
│       ├── PersistentCatalogStore.swift
│       ├── PersonalVPNManager.swift
│       ├── RecentlyWatchedStore.swift
│       ├── ReminderService.swift
│       ├── RetryPolicy.swift
│       ├── SearchHistoryStore.swift
│       ├── SourceBackupCodec.swift
│       ├── SourceManager.swift
│       ├── SourceVerificationService.swift
│       ├── TMDBService.swift
│       ├── ThemeManager.swift
│       ├── TraktAccountManager.swift
│       ├── TraktService.swift
│       ├── XtreamAPIService.swift
│       └── XtreamCatalogStore.swift
├── GassPlayerTests/
│   ├── M3UPlaylistServiceTests.swift
│   ├── MediaSourceConfigTests.swift
│   ├── ParentalLockManagerTests.swift
│   ├── RetryPolicyTests.swift
│   ├── SearchHistoryStoreTests.swift
│   ├── SourceBackupCodecTests.swift
│   └── XtreamAPIServiceTests.swift
└── README.md
```

### State Model

GassPlayer does not place all application state inside individual views.

Dedicated managers/stores own specific domains:

| Component | Responsibility |
|---|---|
| `SourceManager` | Sources, active source, ordering, pinning, enable/disable and verification state. |
| `XtreamCatalogStore` | Xtream categories, streams, VOD and series catalogues plus persistence/cache. |
| `M3UPlaylistStore` | Parsed M3U playlist data and groups. |
| `ContentManagementService` | Favourites and merged playlists. |
| `RecentlyWatchedStore` | Recently watched and playback progress data. |
| `SearchHistoryStore` | Persistent search history. |
| `EPGManager` | External EPG sources and refresh scheduling. |
| `CacheService` | Shared expiring cache infrastructure. |
| `DownloadManager` | Background VOD/episode download lifecycle. |
| `ParentalLockManager` | PIN and content-lock state. |
| `CloudSyncService` | iCloud key-value synchronization. |
| `PersonalVPNManager` | VPN profile and connection lifecycle. |
| `KSPlaybackController` | Playback-engine state and stream controls. |
| `ThemeManager` | Appearance/theme preferences. |
| `DebugLogger` | Structured diagnostics. |

Views render these stores and issue actions back to the appropriate service instead of duplicating core application state.

## Technology

| Area | Technology |
|---|---|
| Language | Swift 5.10 |
| User Interface | SwiftUI |
| Target Platform | iOS 17.0+ |
| Device Families | iPhone and iPad targets |
| Playback Engine | KSPlayer |
| Media Foundation | AVFoundation / AVRoutePickerView / Picture in Picture APIs |
| Networking | URLSession / Foundation networking |
| IPTV API | Xtream Codes `player_api.php` |
| Playlist Format | M3U / M3U8 |
| EPG | Xtream short/full EPG endpoints |
| Metadata | TMDB, OMDb, Trakt |
| Subtitles | OpenSubtitles service layer |
| Persistence | UserDefaults, Application caches and Codable snapshots |
| Cloud | `NSUbiquitousKeyValueStore` |
| Notifications | UserNotifications |
| VPN | Network Extension / native IKEv2 / Packet Tunnel |
| WireGuard | WireGuardKit integration layer |
| CI | GitHub Actions |
| Project Generation | XcodeGen |
| Lint | SwiftLint |
| Testing | XCTest |

### External Packages

The XcodeGen project declares:

- **KSPlayer** from `https://github.com/kingslay/KSPlayer.git`
- **WireGuardKit** from `https://github.com/ridgelineinternational/wireguard-apple-xcframework.git`

The WireGuard dependency is a third-party XCFramework-oriented fork rather than the canonical WireGuard Apple repository. Because VPN cryptography is security-sensitive, deployments that depend on it should review and verify the exact dependency source and build before treating the VPN feature as production security infrastructure.

## Requirements

- macOS with Xcode installed.
- Xcode version capable of building the project with an iOS 17 SDK.
- iPhone or iPad running iOS 17.0 or later, or a compatible iOS Simulator.
- Homebrew for the recommended XcodeGen/SwiftLint setup.
- An Apple Developer Team for normal installation/signing on physical devices.
- Provider credentials or a compatible M3U/M3U8 playlist for IPTV playback.
- Optional API keys for TMDB/OMDb/Trakt metadata functionality.

## Build Locally

1. Clone the repository.

   ```bash
   git clone https://github.com/iamgasgass/GassPlayer-IPTV.git
   cd GassPlayer-IPTV
   ```

2. Install the project-generation and lint tools.

   ```bash
   brew install xcodegen swiftlint
   ```

3. Generate the Xcode project.

   ```bash
   xcodegen generate
   ```

4. Open the generated project.

   ```bash
   open GassPlayer.xcodeproj
   ```

   Or use the project shortcut:

   ```bash
   make open
   ```

5. Choose an iPhone/iPad simulator or physical device.

6. Configure signing in Xcode for a physical device.

7. Build with `Command-B`, run with `Command-R`, or test with `Command-U`.

### Command-Line Build

The Makefile provides:

```bash
make generate
make build
make archive
make ipa
make clean
make verify
```

`make verify` checks for duplicate Swift filenames under `GassPlayer/`, which helps prevent accidental source collisions after merging or extracting project archives.

## Tests

The project includes XCTest coverage for core non-UI components.

Current test areas include:

- M3U parsing.
- M3U multiple-channel parsing.
- Media source Codable round trips.
- Source backup encoding/decoding.
- Invalid source-backup handling.
- Retry policy.
- Search history ordering and persistence.
- Search history duplicate suppression.
- Search history size limit.
- Parental PIN setup and disabling.
- Parental category locking.
- Xtream stream URL construction.
- Xtream VOD URL construction.
- Xtream malformed-host handling.

Run the test suite from Xcode with `Command-U`, or from the command line after generating the project:

```bash
xcodebuild test \
  -project GassPlayer.xcodeproj \
  -scheme GassPlayer \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

The exact simulator name may need to be adjusted to the simulator installed on the development machine.

## GitHub Actions CI

The repository includes `.github/workflows/build.yml`.

The CI pipeline performs the following validation/build flow:

1. Checks the repository for duplicate Swift source filenames.
2. Installs/generates the Xcode project through XcodeGen.
3. Runs SwiftLint.
4. Runs the XCTest suite.
5. Builds the application without requiring signing secrets.
6. Produces an unsigned archive/IPA when the relevant build stage completes.
7. Uploads build/test artifacts where configured by the workflow.

For signed distribution, an Apple Developer signing configuration and the appropriate certificates/profiles must be supplied separately.

## Unsigned IPA

The repository's Makefile can create an unsigned IPA:

```bash
make ipa
```

The resulting package is produced from the archived `GassPlayer.app` and is not automatically a device-installable, App Store-signed application.

For installation on a physical iOS device, the application must be signed with an appropriate certificate and provisioning profile through the user's chosen installation workflow.

Unsigned builds are useful for:

- CI validation.
- Local inspection.
- Reproducible build artifacts.
- Subsequent signing through an external workflow.

## Configuration

### Xtream Source

A typical Xtream source requires:

- Display name.
- Server URL/host.
- Username.
- Password.

The application validates the host and builds the provider API endpoints automatically.

### M3U Source

An M3U/M3U8 source requires:

- Display name.
- Playlist URL.

The parser accepts common IPTV `EXTINF` metadata and classifies content into Live TV, VOD or series where enough information is available.

### Metadata APIs

Optional integrations can be configured through their respective settings:

- TMDB.
- OMDb.
- Trakt.

API credentials are external-service credentials and should be treated as sensitive.

## Manual Verification

Before submitting a change, verify the affected flows on at least one compatible simulator or physical device.

### Sources

- Add an Xtream source.
- Authenticate with valid credentials.
- Inspect account status and expiry information.
- Verify a source manually.
- Verify all applicable sources.
- Pin and unpin a source.
- Enable and disable a source.
- Rename and duplicate a source.
- Reorder sources.
- Export a source as JSON.
- Import a source backup.
- Create a merged playlist from at least two sources.
- Rename, reorder and delete a merged playlist.

### Live TV

- Load the Live TV catalogue.
- Switch categories/groups.
- Open a channel.
- Add and remove a favourite.
- Confirm channel numbering where available.
- Switch active sources.
- Confirm the catalogue survives a relaunch when persistent cache is populated.

### EPG

- Open the TV Guide.
- Switch between Yesterday, Today and Tomorrow.
- Change channel groups.
- Change EPG density.
- Change channel-card style.
- Change tile colour style.
- Open a programme detail.
- Play a live programme.
- Play a catch-up programme when archive data is available.
- Schedule and cancel a reminder.
- Refresh the guide.
- Clear the EPG cache.

### Movies and Series

- Open a VOD movie.
- Confirm provider metadata loads.
- Confirm TMDB enrichment when configured.
- Confirm OMDb ratings when an API key is present.
- Confirm Trakt ratings when configured.
- Open a series.
- Switch seasons.
- Open an episode.
- Resume a partially watched episode.
- Continue to the next episode.
- Check alternate source handling.
- Add/remove movies and series from favourites.

### Player

- Start a live stream.
- Start a VOD stream.
- Start a series episode.
- Play/pause.
- Seek and skip.
- Change playback speed.
- Change video quality.
- Change audio tracks.
- Change subtitles.
- Lock/unlock the player.
- Trigger the sleep timer.
- Test AirPlay audio.
- Test AirPlay video.
- Test Picture in Picture on a compatible device.
- Test external-player handoff where supported.
- Test retry after a playback failure.
- Change buffer settings.
- Test accurate seek.
- Test video delay.
- Test hardware/software decoding preferences.
- Test adaptive quality.
- Test loop playback.
- Test audio-only mode where supported by the stream.

### Downloads

- Start a supported movie download.
- Start a supported episode download.
- Confirm progress updates.
- Toggle Wi-Fi-only mode.
- Verify the preference persists after relaunch.
- Confirm completed files are stored locally.
- Verify multiple downloads use the shared manager correctly.

### Search and Library

- Search for a live channel.
- Search for a movie.
- Search for a series.
- Apply search filters.
- Repeat a previous search.
- Confirm duplicate searches are moved to the front instead of duplicated.
- Delete an individual search.
- Clear search history.
- Verify Continue Watching.
- Remove an item from Continue Watching.
- Add/remove favourites.

### Parental Lock

- Set a PIN.
- Lock content/category.
- Attempt to access locked content.
- Unlock with the correct PIN.
- Verify incorrect PIN behaviour.
- Disable the parental lock.
- Relaunch and confirm persisted state.

### Metadata and Integrations

- Configure TMDB and verify poster/detail enrichment.
- Configure OMDb and verify IMDb/Rotten Tomatoes/Metacritic data.
- Connect Trakt through device authorization.
- Verify Trakt ratings.
- Verify scrobbling where supported.
- Test OpenSubtitles search on supported media.

### Cloud and Backup

- Export application preferences.
- Import the exported JSON.
- Push source/favourite/watch-progress data to iCloud.
- Pull synchronized data on a second compatible installation.
- Confirm downloaded media is not treated as cloud-synchronized data.

### VPN

- Configure an IKEv2 profile.
- Confirm the native VPN lifecycle.
- Configure a valid WireGuard profile.
- Confirm required keys and endpoint are present.
- Start/stop the WireGuard tunnel.
- Verify invalid WireGuard configurations fail safely.
- Do not advertise OpenVPN as functional until an OpenVPN engine is actually integrated into the Packet Tunnel.

### UI and Device Layout

- Test portrait orientation.
- Test landscape orientation.
- Test an iPhone with Dynamic Island/notch.
- Test an iPad target.
- Test compact and comfortable layouts.
- Test light/dark/system appearance where applicable.
- Confirm sheets, player overlays and navigation remain usable after rotation.

## Project Principles

- **Native first:** Prefer SwiftUI and supported Apple frameworks over web-based UI wrappers.
- **Provider tolerance:** IPTV providers are inconsistent; parsing and networking code should remain defensive.
- **Stable state ownership:** Keep source, catalogue, playback, EPG and content-management state in their dedicated services/stores.
- **Graceful degradation:** Missing metadata APIs, incomplete EPG data or optional integrations should not break core playback.
- **Cache deliberately:** Cache expensive provider operations while preserving explicit refresh/invalidation paths.
- **Security honesty:** Do not describe a VPN protocol as encrypted unless a real audited protocol implementation is present.
- **Sensitive configuration:** Treat provider credentials, API keys, VPN keys and exported JSON backups as sensitive.
- **Modern-device awareness:** UI must remain correct on iPhone and iPad layouts, including landscape playback and system overlays.
- **Responsive playback:** Player actions, retries, quality changes and buffering settings should not unnecessarily block the main UI.
- **Test core logic:** Parsers, persistence codecs, retry logic, URL construction and security-sensitive state transitions should remain covered by unit tests.
- **Minimal duplication:** Avoid multiple competing implementations of the same model, decoder or manager.

## Known Limitations and Honest Scope

The following points are intentional and should be understood before deployment.

### Plex / Jellyfin / Emby

These source types are present in the source model and source-management UI, but there are no dedicated Plex, Jellyfin or Emby API/catalog services in the current repository comparable to the Xtream implementation.

They should therefore be treated as extensible source types rather than complete independent integrations.

### OpenVPN

`VPNProtocolType` includes OpenVPN and `PersonalVPNManager` can represent an OpenVPN profile, but the current `PacketTunnelProvider` only contains a WireGuard implementation path.

OpenVPN is not a complete encrypted implementation in the current codebase.

### Chromecast

A Chromecast action is represented in the player UI, but Google Cast SDK integration is not included in the current package dependencies. Native AirPlay support is the implemented Apple playback-routing integration.

### Provider VPN Discovery

Provider VPN configuration discovery uses common Xtream-style endpoint conventions. There is no universal Xtream VPN configuration standard, so providers using proprietary endpoints may require additional code.

### IPTV Content

GassPlayer does not provide television channels, movies, series, credentials or playlists. Users are responsible for the legality and authorization of the content sources they configure.

## Privacy and Credentials

GassPlayer handles several categories of potentially sensitive data:

- IPTV usernames.
- IPTV passwords.
- Provider endpoints.
- VPN keys and credentials.
- TMDB/OMDb/Trakt credentials.
- Source backup JSON files.
- Watch history and favourites.
- Downloaded media.

Exported JSON backups may contain credentials or tokens and should be handled accordingly.

The application does not imply that provider credentials or media rights are legitimate merely because a source can be configured.

## Contributing

Contributions are welcome, especially fixes that improve:

- IPTV provider compatibility.
- EPG robustness.
- Playback stability.
- UI responsiveness.
- Metadata matching.
- Source management.
- Test coverage.
- iOS compatibility.
- Accessibility.
- Network reliability.
- VPN integration safety.

1. Fork the repository and create a feature branch.

   ```bash
   git checkout -b feature/your-change
   ```

2. Keep the implementation focused and preserve the existing architecture.

3. Run the duplicate-file check.

   ```bash
   make verify
   ```

4. Run SwiftLint.

   ```bash
   swiftlint
   ```

5. Run the test suite.

   ```bash
   xcodebuild test \
     -project GassPlayer.xcodeproj \
     -scheme GassPlayer \
     -destination 'platform=iOS Simulator,name=iPhone 16'
   ```

6. Test the affected flows on a simulator or physical device.

7. Open a pull request describing:
   - What changed.
   - Why it changed.
   - Which providers/devices were tested.
   - Any known limitations.

### Coding Conventions

- `PascalCase` for types, structs and enums.
- `camelCase` for properties and methods.
- Prefer one primary public type per Swift file.
- Keep UI-facing state on `@MainActor` where appropriate.
- Use the existing `XtreamError` model for Xtream networking errors.
- Avoid duplicate generic decoding helpers.
- Keep networking/provider logic in services rather than views.
- Keep persistence logic in dedicated stores/codecs.
- Avoid introducing untested cryptographic or VPN protocol implementations.

## License

GassPlayer IPTV is released under the **MIT License**.

Copyright (c) 2026 iamgasgass.

See the full license text in [`LICENSE`](LICENSE).

## Disclaimer

GassPlayer IPTV is an independent, unofficial IPTV player project.

It is not affiliated with, endorsed by, sponsored by, or associated with:

- Apple Inc.
- KSPlayer maintainers.
- Xtream Codes or any IPTV provider.
- TMDB.
- OMDb.
- Trakt.
- OpenSubtitles.
- WireGuard.

All third-party names and services remain the property of their respective owners.

GassPlayer does not provide IPTV content, channel subscriptions, provider credentials or access rights. Users are responsible for ensuring that the sources and media they access comply with applicable laws, licenses and provider terms.

## Support

- Repository: [iamgasgass/GassPlayer-IPTV](https://github.com/iamgasgass/GassPlayer-IPTV)
- Issues: [GitHub Issues](https://github.com/iamgasgass/GassPlayer-IPTV/issues)
- Source management and feature requests: use the repository issue templates.
- Build/CI problems: include the Xcode version, iOS version, device/simulator model, build command and relevant logs.

---

Built for people who want a native, configurable IPTV experience on modern Apple devices, combining Live TV, VOD, series, EPG and advanced playback controls in one application.

- Built by [iamgasgass](https://github.com/iamgasgass)
