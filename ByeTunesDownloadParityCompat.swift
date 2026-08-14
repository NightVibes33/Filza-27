import Foundation

@MainActor
enum ByeTunesLegacyYouTubeAlbumCache {
    private static var tracksByAlbumID: [String: [DownloadTrack]] = [:]

    static func replace(with tracks: [DownloadTrack]) {
        var next: [String: [DownloadTrack]] = [:]
        for track in tracks {
            next[albumID(for: track), default: []].append(track)
        }
        tracksByAlbumID = next
    }

    static func clear() {
        tracksByAlbumID.removeAll()
    }

    static func tracks(for albumID: String) -> [DownloadTrack] {
        tracksByAlbumID[albumID] ?? []
    }

    static func albumID(for track: DownloadTrack) -> String {
        let normalizedArtist = DownloadSupport.normalizedSearchValue(track.artistLine)
        let normalizedAlbum = DownloadSupport.normalizedSearchValue(track.albumName)
        return "youtube-album-\(normalizedArtist)-\(normalizedAlbum)"
    }
}

enum ByeTunesLegacyYouTubeAudioResolver {
    private static let invidiousInstances = [
        "https://invidious.darkness.services",
        "https://invidious.fdn.fr",
        "https://inv.nadeko.net",
        "https://invidious.jing.rocks",
        "https://invidious.nerdvpn.de",
        "https://invidious.private.coffee",
        "https://inv.tux.pizza"
    ]

    private static let pipedInstances = [
        "https://api.piped.projectsegfau.com",
        "https://pipedapi.adminforge.de",
        "https://api.piped.privacydev.net"
    ]

    static func resolve(videoID: String) async -> URL? {
        for instance in invidiousInstances.shuffled() {
            guard let url = URL(string: "\(instance)/api/v1/videos/\(videoID)"),
                  let json = await fetchDictionary(url),
                  let adaptiveFormats = json["adaptiveFormats"] as? [[String: Any]] else { continue }

            let audioFormats = adaptiveFormats.filter {
                ($0["type"] as? String ?? "").hasPrefix("audio/")
            }
            let sortedAudio = audioFormats.sorted {
                integer($0["bitrate"]) > integer($1["bitrate"])
            }
            if let bestAudio = sortedAudio.first,
               let rawURL = bestAudio["url"] as? String,
               let resolved = URL(string: rawURL) {
                Logger.shared.log("[YouTubeProvider] Resolved audio through Invidious fallback")
                return resolved
            }
        }

        for instance in pipedInstances.shuffled() {
            guard let url = URL(string: "\(instance)/streams/\(videoID)"),
                  let json = await fetchDictionary(url),
                  let audioStreams = json["audioStreams"] as? [[String: Any]] else { continue }

            let sortedAudio = audioStreams.sorted {
                integer($0["bitrate"]) > integer($1["bitrate"])
            }
            if let bestAudio = sortedAudio.first,
               let rawURL = bestAudio["url"] as? String,
               let resolved = URL(string: rawURL) {
                Logger.shared.log("[YouTubeProvider] Resolved audio through Piped fallback")
                return resolved
            }
        }

        Logger.shared.log("[YouTubeProvider] No public audio stream fallback resolved for \(videoID)")
        return nil
    }

    private static func fetchDictionary(_ url: URL) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any] else { return nil }
            return dictionary
        } catch {
            return nil
        }
    }

    private static func integer(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String, let parsed = Int(value) { return parsed }
        return 0
    }
}

extension MetadataProvider {
    static func resolveYouTubeAudioStreamURLCompat(videoID: String) async -> URL? {
        await ByeTunesLegacyYouTubeAudioResolver.resolve(videoID: videoID)
    }
}

@MainActor
extension DownloadViewModel {
    func searchYouTubeLegacyCompat(query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            ByeTunesLegacyYouTubeAlbumCache.clear()
            artistResults = []
            songResults = []
            albumResults = []
            playlistResults = []
            canLoadMoreSongs = false
            canLoadMoreAlbums = false
            canLoadMorePlaylists = false
            errorText = nil
            return
        }

        let candidates = await MetadataProvider.searchYouTubeForMetadata(query: trimmed, limit: 25)
        let tracks = candidates.map { candidate -> DownloadTrack in
            let parsed = MetadataProvider.normalizeYouTubeTitle(candidate.title, channel: candidate.channelTitle)
            return DownloadTrack(
                id: "youtube-\(candidate.videoID)",
                name: parsed.title,
                artistLine: parsed.artist,
                albumName: parsed.album,
                artworkURL: candidate.thumbnailURL,
                isExplicit: false,
                sourceURL: "https://music.youtube.com/watch?v=\(candidate.videoID)",
                sourceContext: .song,
                provider: .youtube,
                artistIdentifier: candidate.channelTitle,
                albumIdentifier: nil,
                previewURL: nil
            )
        }

        ByeTunesLegacyYouTubeAlbumCache.replace(with: tracks)
        artistResults = []
        songResults = tracks
        albumResults = Self.legacyYouTubeAlbums(from: tracks)
        playlistResults = []

        // The pre-v2.4 load-more branch re-ran the identical first-page query
        // without an offset/token. Keep the visible result contract but do not
        // advertise a non-functional pagination path.
        canLoadMoreSongs = false
        canLoadMoreAlbums = false
        canLoadMorePlaylists = false
        errorText = tracks.isEmpty ? "No YouTube results found." : nil
    }

    func searchAllLegacySourcesCompat(query: String) async {
        await search(query: query, provider: .appleMusic)
        let appleArtists = artistResults
        let appleSongs = songResults
        let appleAlbums = albumResults
        let applePlaylists = playlistResults
        let appleError = errorText

        await search(query: query, provider: .tidal)
        let tidalArtists = artistResults
        let tidalSongs = songResults
        let tidalAlbums = albumResults
        let tidalPlaylists = playlistResults
        let tidalError = errorText

        await searchYouTubeLegacyCompat(query: query)
        let youtubeArtists = artistResults
        let youtubeSongs = songResults
        let youtubeAlbums = albumResults
        let youtubePlaylists = playlistResults
        let youtubeError = errorText

        await search(query: query, provider: .metadata)
        let metadataArtists = artistResults
        let metadataSongs = songResults
        let metadataAlbums = albumResults
        let metadataPlaylists = playlistResults
        let metadataError = errorText

        // Pre-v2.4 All Sources result order was Apple -> Tidal -> YouTube ->
        // iTunes/Deezer metadata.
        artistResults = Self.mergeLegacyUnique([appleArtists, tidalArtists, youtubeArtists, metadataArtists])
        songResults = Self.mergeLegacyUnique([appleSongs, tidalSongs, youtubeSongs, metadataSongs])
        albumResults = Self.mergeLegacyUnique([appleAlbums, tidalAlbums, youtubeAlbums, metadataAlbums])
        playlistResults = Self.mergeLegacyUnique([applePlaylists, tidalPlaylists, youtubePlaylists, metadataPlaylists])

        canLoadMoreSongs = false
        canLoadMoreAlbums = false
        canLoadMorePlaylists = false
        if artistResults.isEmpty && songResults.isEmpty && albumResults.isEmpty && playlistResults.isEmpty {
            errorText = [appleError, tidalError, youtubeError, metadataError]
                .compactMap { $0 }
                .first ?? "No results found across available sources."
        } else {
            errorText = nil
        }
    }

    private static func legacyYouTubeAlbums(from tracks: [DownloadTrack]) -> [DownloadAlbum] {
        var seen = Set<String>()
        var albums: [DownloadAlbum] = []
        for track in tracks {
            let id = ByeTunesLegacyYouTubeAlbumCache.albumID(for: track)
            guard seen.insert(id).inserted else { continue }
            albums.append(
                DownloadAlbum(
                    id: id,
                    name: track.albumName,
                    artistLine: track.artistLine,
                    artworkURL: track.artworkURL,
                    sourceURL: track.sourceURL,
                    provider: .youtube,
                    artistIdentifier: track.artistIdentifier,
                    albumIdentifier: nil
                )
            )
        }
        return albums
    }

    private static func mergeLegacyUnique<T: Identifiable>(_ groups: [[T]]) -> [T] where T.ID: Hashable {
        var seen = Set<T.ID>()
        var merged: [T] = []
        for group in groups {
            for item in group where seen.insert(item.id).inserted {
                merged.append(item)
            }
        }
        return merged
    }
}
