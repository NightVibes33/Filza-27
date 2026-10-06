#!/usr/bin/env bash
set -euo pipefail
ROOT="${BYETUNES_ROOT:-ByeTunes/MusicManager}"
python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1]); p=root/'SongMetadata.swift'; s=p.read_text()
if 'static func searchAMLLLyrics' in s:
    print('AMLL picker already applied');sys.exit(0)
s=s.replace('    case lrclib\n    case musixmatch', '    case amll\n    case lrclib\n    case musixmatch',1)
s=s.replace('static var allCases: [LyricsSearchService] { [.lrclib] }','static var allCases: [LyricsSearchService] { [.amll, .lrclib] }',1)
s=s.replace('        case .lrclib:\n            return "LRCLIB"','        case .amll:\n            return "AMLL"\n        case .lrclib:\n            return "LRCLIB"',1)
s=s.replace('    let remoteID: Int?\n}', '    let remoteID: Int?\n    var ttmlURL: String? = nil\n}',1)
s=s.replace('        switch service {\n        case .lrclib:', '        switch service {\n        case .amll:\n            return await searchAMLLLyrics(query: query)\n        case .lrclib:',1)
s=s.replace('        switch result.service {\n        case .lrclib:', '        switch result.service {\n        case .amll:\n            guard let address = result.ttmlURL else { return nil }\n            return await fetchAMLLDocument(address: address)\n        case .lrclib:',1)
# Global selection controls automatic enrichment without changing manual choices.
s=s.replace('''        if song.storeId > 0,
           let rich = await fetchAMLLTTML(appleMusicID: song.storeId) {''','''        let provider = UserDefaults.standard.string(forKey: "freeLyricsProvider") ?? "automatic"
        if provider != "lrclib", song.storeId > 0,
           let rich = await fetchAMLLTTML(appleMusicID: song.storeId) {''',1)
s=s.replace('''        if let existing = song.lyrics?.trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty,
           isSyncedLRC(existing),''','''        if provider != "lrclib" {
            let matches = await searchAMLLLyrics(query: "\(song.artist) \(song.title)")
            let normalizedTitle = song.title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            let normalizedArtist = song.artist.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            let exact = matches.filter {
                $0.title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current) == normalizedTitle &&
                $0.artist.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current) == normalizedArtist
            }
            if exact.count == 1, let address = exact[0].ttmlURL,
               let document = await fetchAMLLDocument(address: address) {
                Logger.shared.log("[ByeTunesRichLyrics] AMLL exact title/artist index match; confirm recording version in editor")
                return (document, plainTextFromTTML(document), "amll", "timed")
            }
        }
        if provider == "amll" {
            Logger.shared.log("[ByeTunesRichLyrics] AMLL-only: no unique lyric match; use AMLL search in the lyric editor. LRCLIB fallback disabled.")
            return nil
        }
        if provider == "automatic" {
            Logger.shared.log("[ByeTunesRichLyrics] AMLL unavailable or missing catalog ID; using embedded lyrics / LRCLIB fallback")
        }
        if let existing = song.lyrics?.trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty,
           isSyncedLRC(existing),''',1)
# HTTP misses must appear in diagnostics, too.
s=s.replace('''                  let raw = String(data: data, encoding: .utf8) else {
                return nil
            }''','''                  let raw = String(data: data, encoding: .utf8) else {
                Logger.shared.log("[ByeTunesRichLyrics] AMLL unavailable appleMusicId=\\(appleMusicID) status=\\((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }''',1)
helper=r'''
    private static let amllIndexCache = NSCache<NSString, NSData>()

    private static func cachedAMLLIndex() async throws -> Data {
        let key: NSString = "raw-lyrics-index"
        if let cached = amllIndexCache.object(forKey: key) { return cached as Data }
        let url = URL(string: "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/main/metadata/raw-lyrics-index.jsonl")!
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 20))
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 16 * 1024 * 1024 else {
            throw NSError(domain: "AMLLIndex", code: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        amllIndexCache.setObject(data as NSData, forKey: key, cost: data.count)
        return data
    }

    // Search AMLL's own metadata, including songs without an Apple catalog ID.
    static func searchAMLLLyrics(query: String) async -> [LyricsSearchResult] {
        do {
            let data = try await cachedAMLLIndex()
            guard let index = String(data: data, encoding: .utf8) else { return [] }
            let terms = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard !terms.isEmpty else { return [] }
            var matches: [LyricsSearchResult] = []
            for line in index.split(separator: "\n") {
                guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let entries = row["metadata"] as? [[Any]],
                      let file = row["rawLyricFile"] as? String,
                      file.hasSuffix(".ttml"), !file.contains("/"), !file.contains("..") else { continue }
                var fields: [String: [String]] = [:]
                for entry in entries {
                    if entry.count == 2, let key = entry[0] as? String, let values = entry[1] as? [String] {
                        fields[key] = values
                    }
                }
                let title = fields["musicName"]?.first ?? "Unknown Title"
                let artist = fields["artists"]?.joined(separator: ", ") ?? "Unknown Artist"
                let album = fields["album"]?.first
                let searchable = ([title, artist, album ?? ""] + (fields["appleMusicId"] ?? []))
                    .joined(separator: " ").folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                guard terms.allSatisfy({ searchable.contains($0) }) else { continue }
                matches.append(LyricsSearchResult(id: "amll-\(file)", service: .amll, title: title,
                    artist: artist, album: album, durationMs: nil, hasSyncedLyrics: true,
                    plainLyrics: nil, syncedLyrics: nil, remoteID: nil,
                    ttmlURL: "https://raw.githubusercontent.com/amll-dev/amll-ttml-db/main/raw-lyrics/\(file)"))
                if matches.count == 50 { break }
            }
            Logger.shared.log("[LyricsSearch] AMLL index returned \(matches.count) results")
            return matches
        } catch {
            Logger.shared.log("[LyricsSearch] AMLL index request failed: \(error.localizedDescription)")
            return []
        }
    }

    static func fetchAMLLDocument(address: String) async -> String? {
        guard let url = URL(string: address), url.scheme == "https", url.host == "raw.githubusercontent.com",
              url.path.hasPrefix("/amll-dev/amll-ttml-db/") else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 15))
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2 * 1024 * 1024,
                  let text = String(data: data, encoding: .utf8) else { return nil }
            let normalized = normalizeCustomTTML(text)
            guard isValidCustomTTML(normalized), plainTextFromTTML(normalized) != nil else { return nil }
            return normalized
        } catch {
            Logger.shared.log("[LyricsSearch] AMLL document failed: \(error.localizedDescription)")
            return nil
        }
    }

    static func plainTextFromTTML(_ text: String) -> String? {
        let delegate = AMLLTextParser()
        let parser = XMLParser(data: Data(text.utf8))
        parser.delegate = delegate
        guard parser.parse(), !delegate.lines.isEmpty else { return nil }
        return delegate.lines.joined(separator: "\n")
    }

    private final class AMLLTextParser: NSObject, XMLParserDelegate {
        var lines: [String] = []
        private var line: String? = nil
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            if elementName == "p" { line = "" }
            if elementName == "br", line != nil { line? += "\n" }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { line? += string }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "p", let text = line {
                lines.append(text.trimmingCharacters(in: .whitespacesAndNewlines)); line = nil
            }
        }
    }
'''
anchor='    private static func searchLyricsFromLRCLIB(query: String)'
s=s.replace(anchor,helper+'\n'+anchor,1);p.write_text(s)
p=root/'LyricsSearchSheet.swift';s=p.read_text()
s=s.replace('    let songArtist: String\n','    let songArtist: String\n    var onSelection: ((LyricsSearchResult, String) -> Void)? = nil\n',1)
s=s.replace('    @State private var lyricsService: LyricsSearchService = .lrclib','    @State private var lyricsService: LyricsSearchService = .amll',1)
s=s.replace('Text("Try a different artist or title")','Text(lyricsService == .amll ? "Try fewer search terms, or select LRCLIB for line-timed lyrics." : "Try a different artist or title")',1)
s=s.replace('''        Task {
            let service = lyricsService
            let searchResults''','''        let service = lyricsService
        let query = searchQuery
        Task {
            let searchResults''',1)
s=s.replace('searchLyrics(query: searchQuery, service: service)','searchLyrics(query: query, service: service)',1)
s=s.replace('''                if self.lyricsService == service {
                    self.results = searchResults
                }
                self.isLoading = false''','''                guard self.lyricsService == service, self.searchQuery == query else { return }
                self.results = searchResults
                self.isLoading = false''',1)
s=s.replace('''                    self.lyrics = fetchedLyrics
                    self.isPresented = false''','''                    if result.service == .amll {
                        self.lyrics = SongMetadata.plainTextFromTTML(fetchedLyrics) ?? ""
                    } else {
                        self.lyrics = fetchedLyrics
                    }
                    self.onSelection?(result, fetchedLyrics)
                    self.isPresented = false''',1);p.write_text(s)
p=root/'ManualMetadataEditor.swift';s=p.read_text()
s=s.replace('    @State private var lyrics: String = ""','''    @State private var lyrics: String = ""
    @State private var chosenTTML: String? = nil
    @State private var chosenLyricText: String? = nil
    @State private var chosenLyricSource: String? = nil''',1)
s=s.replace('songTitle: title, songArtist: artist)','''songTitle: title, songArtist: artist, onSelection: { result, payload in
                    chosenTTML = result.service == .amll ? payload : nil
                    chosenLyricText = lyrics
                    chosenLyricSource = result.service.rawValue
                })''',1)
s=s.replace('''        updatedSong.artworkData = artworkData''','''        if let chosenLyricText, chosenLyricText == lyrics {
            updatedSong.syncedLyricsTTML = chosenTTML
            updatedSong.syncedLyricsSource = chosenLyricSource
            updatedSong.syncedLyricsTiming = chosenTTML != nil ? "timed" : (SongMetadata.isSyncedLRC(lyrics) ? "line" : "plain")
        }
        updatedSong.artworkData = artworkData''',1)
s=s.replace('''        lyrics = song.lyrics ?? ""''','''        lyrics = song.lyrics ?? ""
        chosenTTML = nil
        chosenLyricText = nil
        chosenLyricSource = nil''',1);p.write_text(s)
p=root/'SettingsView.swift';s=p.read_text()
s=s.replace('private struct DownloaderSettingsScreen: View {','''private struct DownloaderSettingsScreen: View {
    @AppStorage("freeLyricsProvider") private var freeLyricsProvider = "automatic"''',1)
s=s.replace('''                                Text("AMLL → LRCLIB → plain lyrics")''','''                                Picker("Lyrics Provider", selection: $freeLyricsProvider) {
                                    Text("Automatic: AMLL, then LRCLIB").tag("automatic")
                                    Text("AMLL only").tag("amll")
                                    Text("LRCLIB only").tag("lrclib")
                                }
                                .pickerStyle(.menu)''',1)
s=s.replace('Text("Free synced lyric pipeline")','Text("Lyrics Provider")',1)
s=s.replace('Text("AMLL word-sync with LRCLIB fallback.")','Text("Fetch timed lyrics using your selected provider.")',1)
s=s.replace('Metadata sources, Apple Music synced lyrics, and LRCLIB fallback','Metadata sources and free AMLL / LRCLIB lyrics')
p.write_text(s)
print('Enabled manual AMLL index search, preserved selected TTML, and added global lyric provider preference')
PY
