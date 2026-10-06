#!/usr/bin/env bash
set -euo pipefail
python3 - "${BYETUNES_ROOT:-ByeTunes/MusicManager}" <<'PY'
from pathlib import Path
import sys
r=Path(sys.argv[1]);p=r/'SongMetadata.swift';s=p.read_text()
if '// Provider audit: primary lyrics only' in s:sys.exit(0)
a=s.index('    private final class AMLLTextParser:');b=s.index('\n    }',a)+len('\n    }')
parser=r'''    // Provider audit: primary lyrics only; credit metadata never enters paragraph text.
    private final class AMLLTextParser: NSObject, XMLParserDelegate {
        var lines: [String] = []
        private var line: String? = nil
        private var ignoredDepth = 0
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributes: [String: String] = [:]) {
            let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
            if ignoredDepth > 0 { ignoredDepth += 1; return }
            let role = attributes["ttm:role"] ?? attributes["role"] ?? ""
            if ["x-translation", "x-roman", "x-romanization", "translation", "romanization"].contains(role) {
                ignoredDepth = 1; return
            }
            if name == "p" { line = "" }
            if name == "br", line != nil { line? += "\n" }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if ignoredDepth == 0 { line? += string }
        }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if ignoredDepth == 0, let text = String(data: CDATABlock, encoding: .utf8) { line? += text }
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if ignoredDepth > 0 { ignoredDepth -= 1; return }
            let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
            if name == "p", let text = line {
                lines.append(text.trimmingCharacters(in: .whitespacesAndNewlines)); line = nil
            }
        }
    }'''
s=s[:a]+parser+s[b:]
s=s.replace(r'#"<span\b', r'#"<(?:[\w.-]+:)?span\b', 1)
s=s.replace('guard parser.parse(), !delegate.lines.isEmpty else { return nil }','guard parser.parse(), delegate.lines.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }',1)
s=s.replace('return (rich.ttml, song.lyrics, "amll", rich.timing)','return (rich.ttml, plainTextFromTTML(rich.ttml), "amll", editorLyricsState(text: nil, timedTTML: rich.ttml).timing)',1)
s=s.replace('return (rich, plainTextFromTTML(rich), "lrcred", "timed")','return (rich, plainTextFromTTML(rich), "lrcred", editorLyricsState(text: nil, timedTTML: rich).timing)',1)
s=s.replace('return (document, plainTextFromTTML(document), "amll", "timed")','return (document, plainTextFromTTML(document), "amll", editorLyricsState(text: nil, timedTTML: document).timing)',1)
# Preserve punctuation and Unicode correctly in LRCLIB's query parameters.
a=s.index('    static func fetchLyricsFromLRCLIB(');b=s.index('\n    }',a)+len('\n    }')
old=s[a:b]
start=old.index('        let titleEnc');end=old.index('\n        do {',start)
url=r'''        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "duration", value: String(Double(durationMs) / 1000))
        ]
        if !album.isEmpty && album != "Unknown Album" {
            components.queryItems?.append(URLQueryItem(name: "album_name", value: album))
        }
        guard let url = components.url else { return nil }
'''
old=old[:start]+url+old[end:]
old=old.replace('let (data, _) = try await URLSession.shared.data(from: url)','let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 12))\n            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }')
s=s[:a]+old+s[b:]
a=s.index('        if provider == "lrcred" {');b=s.index('\n        if provider != "lrclib", song.storeId',a)
block=r'''        var automaticLineCandidate: (ttml: String?, text: String?, source: String, timing: String)? = nil
        if provider == "lrcred" || provider == "automatic" {
            let matches = await searchPublicLyrics(query: "\(song.artist) \(song.title)", service: .lrcred)
            let exact = matches.filter {
                lyricIdentity($0.title) == lyricIdentity(song.title) && lyricIdentity($0.artist) == lyricIdentity(song.artist) &&
                song.durationMs > 0 && abs(($0.durationMs ?? -10000) - song.durationMs) <= 2000
            }
            if exact.count == 1, let address = exact[0].ttmlURL, let rich = await fetchPublicTTML(address: address) {
                let state = editorLyricsState(text: nil, timedTTML: rich)
                let candidate: (ttml: String?, text: String?, source: String, timing: String) = (rich, state.text, "lrcred", state.timing)
                if provider == "lrcred" || state.timing == "word" { return candidate }
                automaticLineCandidate = candidate
            } else if provider == "lrcred" { return nil }
        }
'''
s=s[:a]+block+s[b:]
marker='        if let existing = song.lyrics?.trimmingCharacters(in: .whitespacesAndNewlines),'
a=s.index('    static func resolveFreeSyncedLyrics(');b=s.index('    private static func fetchAMLLTTML(',a)
segment=s[a:b];assert marker in segment
segment=segment.replace(marker,'        if let automaticLineCandidate { return automaticLineCandidate }\n'+marker,1);s=s[:a]+segment+s[b:]
p.write_text(s)
p=r/'SettingsView.swift';s=p.read_text().replace('Automatic: LyricsPlus, AMLL, LRCLIB','Automatic: LyricsPlus, lrc.red, AMLL, LRCLIB').replace('Fetch timed lyrics using your selected provider.','Retain timed lyrics in Filza; Apple Music displays plain lyrics.');p.write_text(s)
p=r/'LyricsSearchSheet.swift';s=p.read_text()
s=s.replace('    @State private var lyricsService:', '    @State private var searchRequestID = UUID()\n    @State private var lyricsService:',1)
s=s.replace('        let service = lyricsService\n        let query = searchQuery','        let requestID = UUID()\n        searchRequestID = requestID\n        let service = lyricsService\n        let query = searchQuery',1)
s=s.replace('guard self.lyricsService == service, self.searchQuery == query else { return }','guard self.searchRequestID == requestID else { return }\n                self.isLoading = false\n                guard self.lyricsService == service, self.searchQuery == query else { return }',1)
s=s.replace('                self.isResolvingLyrics = false\n                if let fetchedLyrics','                self.isResolvingLyrics = false\n                guard self.isPresented else { return }\n                if let fetchedLyrics',1);p.write_text(s)
print('Audited primary TTML text extraction, actual timing classification, LRCLIB queries and stale search state')
PY
