# Lyric provider audit — 2026-10-06

Target: Filza-27's four exposed lyric providers. Tests use public endpoints without Apple user tokens, subscriptions, browser cookies or authentication bypasses.

| Provider | Live evidence | Timing capability | Native imported Apple Music highlighting |
| --- | --- | --- | --- |
| LyricsPlus | Current search/get return Cloudflare 403 (error 1010); earlier saved Sleep Well response has 184 timed syllables | Word when available; app deliberately rejects responses without verified recording identity/duration | Unverified; fetching Apple-sourced timing does not register a native lyric asset |
| lrc.red | Current workspace requests return Cloudflare 403; user device logs confirm successful fetches, earlier cached service search fixture available | Word or line, depending on document; user Animal I Have Become document is Line | Raw TTML in lyrics database text visibly concatenated lines/credits; native text fallback implemented |
| AMLL | Index HTTP 200, 3317 entries; first indexed raw document HTTP 200, 17 paragraphs, 164 timed spans; no Sleep Well index entry | Community word/line TTML; incomplete coverage | Unverified |
| LRCLIB | Search HTTP 200, 20 results for d4vd Sleep Well, multiple different recording durations | Synced LRC has line timestamps; cannot supply real word timings | Native text fallback, not word highlighting |

## Fixes in this audit

- TTML extraction reads primary paragraph text, includes CDATA and prefixed elements, excludes credit metadata, translations and romanization, rejects malformed/empty documents.
- Actual word/line timing replaces generic timed labels.
- Automatic lookup considers lrc.red word timings and retains its line result while checking AMLL.
- LRCLIB query parameters use URLComponents and bounded request duration; unknown album placeholder is omitted.
- Manual stale searches cannot strand the loading indicator; cancelled lyric sheets cannot apply late results.
- Shared regression fixture covers Unicode, entities, credits, translated spans, CDATA, XML validity and readable native output.

## Verification limits

Current Cloudflare denials prevent fresh end-to-end verification of LyricsPlus/lrc.red from this workspace. Earlier fixtures are parser evidence, not current service availability. Provider coverage varies by song/version. The build runner can verify Swift code and packaging, but native Apple Music rendering still requires a device. No tested subscription-free registration path for imported word-timed native lyric assets has been established. Do not describe this as fully working native synced lyrics.
