#!/usr/bin/env bash
set -euo pipefail
python3 - "${BYETUNES_ROOT:-ByeTunes/MusicManager}" <<'PY'
from pathlib import Path
import sys
r=Path(sys.argv[1]);p=r/'SongMetadata.swift';s=p.read_text()
if 'static func fetchPublicWordLyrics' in s: sys.exit(0)
s=s.replace('    case amll\n','    case lyricsplus\n    case lrcred\n    case amll\n',1)
s=s.replace('[.amll, .lrclib]', '[.lyricsplus, .lrcred, .amll, .lrclib]',1)
s=s.replace('        case .amll:\n            return "AMLL"','        case .lyricsplus: return "LyricsPlus"\n        case .lrcred: return "lrc.red"\n        case .amll:\n            return "AMLL"',1)
s=s.replace('        switch service {\n','        switch service {\n        case .lyricsplus, .lrcred:\n            return await searchPublicLyrics(query: query, service: service)\n',1)
s=s.replace('        switch result.service {\n','''        switch result.service {
        case .lyricsplus:
            return await fetchPublicWordLyrics(title: result.title, artist: result.artist, durationMs: result.durationMs ?? 0)?.ttml
        case .lrcred:
            guard let address = result.ttmlURL else { return nil }
            return await fetchPublicTTML(address: address)
''',1)
needle='        let provider = UserDefaults.standard.string(forKey: "freeLyricsProvider") ?? "automatic"'
s=s.replace(needle,needle+'''
        if provider == "automatic" || provider == "lyricsplus" {
            if let rich = await fetchPublicWordLyrics(title: song.title, artist: song.artist, durationMs: song.durationMs) {
                return (rich.ttml, plainTextFromTTML(rich.ttml), "lyricsplus", rich.timing)
            }
            if provider == "lyricsplus" { return nil }
        }
        if provider == "lrcred" {
            let matches = await searchPublicLyrics(query: "\\(song.artist) \\(song.title)", service: .lrcred)
            let exact = matches.filter {
                lyricIdentity($0.title) == lyricIdentity(song.title) && lyricIdentity($0.artist) == lyricIdentity(song.artist) &&
                song.durationMs > 0 && abs(($0.durationMs ?? -10000) - song.durationMs) <= 2000
            }
            guard exact.count == 1, let address = exact[0].ttmlURL,
                  let rich = await fetchPublicTTML(address: address) else { return nil }
            return (rich, plainTextFromTTML(rich), "lrcred", "timed")
        }
''',1)
helper=r'''
    private static let publicLyricCache = NSCache<NSString, NSData>()

    private static func lyricIdentity(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func publicLyricData(_ url: URL) async -> Data? {
        guard url.scheme == "https" else { return nil }
        let key = url.absoluteString as NSString
        if let cached = publicLyricCache.object(forKey: key) { return cached as Data }
        do {
            let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 12))
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2 * 1024 * 1024 else {
                Logger.shared.log("[LyricsSearch] Public provider HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            publicLyricCache.totalCostLimit = 8 * 1024 * 1024
            publicLyricCache.setObject(data as NSData, forKey: key, cost: data.count)
            return data
        } catch {
            Logger.shared.log("[LyricsSearch] Public provider unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    static func searchPublicLyrics(query: String, service: LyricsSearchService) async -> [LyricsSearchResult] {
        var url = URLComponents(string: "https://lrc.red/api/v1")!
        url.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let address = url.url, let data = await publicLyricData(address),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["results"] as? [[String: Any]] else { return [] }
        return rows.prefix(50).compactMap { row in
            guard let title = row["track_name"] as? String, let artist = row["artist_name"] as? String,
                  let document = row["lyricsUrl"] as? String else { return nil }
            return LyricsSearchResult(id: "\(service.rawValue)-\(document)", service: service, title: title,
                artist: artist, album: row["album_name"] as? String,
                durationMs: (row["duration"] as? NSNumber).map { Int($0.doubleValue * 1000) },
                hasSyncedLyrics: true, plainLyrics: nil, syncedLyrics: nil, remoteID: nil, ttmlURL: document)
        }
    }

    static func fetchPublicTTML(address: String) async -> String? {
        guard let url = URL(string: address), let data = await publicLyricData(url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let normalized = normalizeCustomTTML(text)
        guard isValidCustomTTML(normalized), plainTextFromTTML(normalized) != nil else { return nil }
        return normalized
    }

    static func fetchPublicWordLyrics(title: String, artist: String, durationMs: Int) async -> (ttml: String, timing: String)? {
        var url = URLComponents(string: "https://lyricsplus.prjktla.my.id/v2/lyrics/get")!
        url.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "artist", value: artist)]
        if durationMs > 0 { url.queryItems?.append(URLQueryItem(name: "duration", value: String(Double(durationMs) / 1000))) }
        guard let address = url.url, let data = await publicLyricData(address) else { return nil }
        return parsePublicWordLyrics(data: data, title: title, artist: artist, durationMs: durationMs)
    }

    static func parsePublicWordLyrics(data: Data, title: String, artist: String, durationMs: Int) -> (ttml: String, timing: String)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let processing = json["processingTime"] as? [String: Any],
              let selected = processing["selectedSongMetadata"] as? [String: Any],
              let selectedTitle = selected["title"] as? String, let selectedArtist = selected["artist"] as? String,
              lyricIdentity(title) == lyricIdentity(selectedTitle), lyricIdentity(artist) == lyricIdentity(selectedArtist),
              durationMs > 0, let duration = selected["duration"] as? NSNumber,
              abs(duration.doubleValue * 1000 - Double(durationMs)) <= 2000,
              json["type"] as? String == "Word",
              let rows = json["lyrics"] as? [[String: Any]], !rows.isEmpty else {
            return nil
        }
        var paragraphs: [String] = []
        for row in rows {
            guard let start = row["time"] as? NSNumber, let length = row["duration"] as? NSNumber,
                  let words = row["syllabus"] as? [[String: Any]], !words.isEmpty,
                  start.doubleValue >= 0, length.doubleValue > 0 else { return nil }
            let end = start.doubleValue + length.doubleValue
            guard end <= Double(durationMs) + 2000 else { return nil }
            var spans: [String] = []
            for word in words {
                guard let begin = word["time"] as? NSNumber, let duration = word["duration"] as? NSNumber,
                      let text = word["text"] as? String, begin.doubleValue >= start.doubleValue,
                      duration.doubleValue > 0, begin.doubleValue + duration.doubleValue <= end + 1 else { return nil }
                spans.append("<span begin=\"\(formatTTMLTime(begin.doubleValue / 1000))\" end=\"\(formatTTMLTime((begin.doubleValue + duration.doubleValue) / 1000))\">\(escapeTTMLText(text))</span>")
            }
            paragraphs.append("<p begin=\"\(formatTTMLTime(start.doubleValue / 1000))\" end=\"\(formatTTMLTime(end / 1000))\">\(spans.joined())</p>")
        }
        let document = "<tt xmlns=\"http://www.w3.org/ns/ttml\"><body><div>\(paragraphs.joined())</div></body></tt>"
        guard isValidCustomTTML(document), plainTextFromTTML(document) != nil else { return nil }
        return (document, "word")
    }
'''
s=s.replace('    private static let amllIndexCache',helper+'\n    private static let amllIndexCache',1);p.write_text(s)
p=r/'LyricsSearchSheet.swift';s=p.read_text().replace('= .amll','= .lyricsplus',1).replace('if result.service == .amll {','if result.service == .amll || result.service == .lyricsplus || result.service == .lrcred {');p.write_text(s)
p=r/'ManualMetadataEditor.swift';s=p.read_text().replace('result.service == .amll ? payload : nil','[LyricsSearchService.amll, .lyricsplus, .lrcred].contains(result.service) ? payload : nil');p.write_text(s)
p=r/'SettingsView.swift';s=p.read_text().replace('Text("Automatic: AMLL, then LRCLIB")','Text("Automatic: LyricsPlus, AMLL, LRCLIB")').replace('Text("AMLL only").tag("amll")','Text("LyricsPlus word timing only").tag("lyricsplus")\n                                    Text("lrc.red only").tag("lrcred")\n                                    Text("AMLL only").tag("amll")');p.write_text(s)
print('Applied verified public word lyric providers')
PY
