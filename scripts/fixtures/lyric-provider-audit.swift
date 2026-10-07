let primaryDocument = #"<tt xmlns="http://www.w3.org/ns/ttml" xmlns:t="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata"><head><metadata><name>Credit name</name></metadata></head><body><div><t:p begin="1.000" end="3.000"><t:span begin="1.000" end="2.000"><![CDATA[Stay & ]]></t:span><t:span begin="2.000" end="3.000">sing</t:span><t:span ttm:role="x-translation"><t:span>Translated text</t:span></t:span><t:span ttm:role="x-roman">Romanized text</t:span></t:p><p begin="4.000" end="5.000">再见 🌙</p></div></body></tt>"#
precondition(SongMetadata.plainTextFromTTML(primaryDocument) == "Stay & sing\n再见 🌙")
precondition(SongMetadata.plainTextFromTTML("<tt><body><p>   </p></body></tt>") == nil)
precondition(SongMetadata.plainTextFromTTML("<tt><body><p>broken") == nil)
let nativePrimary = SongMetadata.nativeLibraryLyricsPayload(text: nil, timedTTML: primaryDocument, durationMs: 5000)
precondition(nativePrimary.text == "Stay & sing\n再见 🌙" && !nativePrimary.timed)
print("PASS: all-provider TTML extraction excludes credit/translation/romanization metadata, preserves CDATA/entities/Unicode and rejects empty/malformed XML")

precondition(SongMetadata.editorLyricsState(text: nil, timedTTML: primaryDocument).timing == "word")
