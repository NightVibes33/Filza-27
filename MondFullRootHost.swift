import SwiftUI
import UIKit
import AVFoundation
import WebKit
import Combine

// Full embedded mond shell based on rooootdev/mond main at
// 4a37bfca5cb4abb2c99891972365d872d700525e.  Filza remains the UIApplication
// owner, so mond's @main entry point is adapted into this host while its current
// navigation hierarchy and settings behavior are preserved.

private let mondEmbeddedUpstreamCommit = "4a37bfca5cb4abb2c99891972365d872d700525e"
private let mondEmbeddedCanonicalGestaltPath = "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist"

private func mondRootIssueSandboxToken(path: String) -> String? {
    typealias IssueFunction = @convention(c) (
        UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32, Int32
    ) -> UnsafeMutablePointer<CChar>?
    guard let library = dlopen("/usr/lib/system/libsystem_sandbox.dylib", RTLD_NOW) else { return nil }
    defer { dlclose(library) }
    guard let symbol = dlsym(library, "sandbox_extension_issue_file") else { return nil }
    let issue = unsafeBitCast(symbol, to: IssueFunction.self)
    let pointer = path.withCString {
        issue("com.apple.app-sandbox.read-write", $0, 0, 0)
    }
    guard let pointer else { return nil }
    defer { free(pointer) }
    return String(cString: pointer)
}

private func mondRootConsumeSandboxToken(_ token: String) -> Int64? {
    typealias ConsumeFunction = @convention(c) (UnsafePointer<CChar>?) -> Int64
    guard !token.isEmpty,
          let library = dlopen("/usr/lib/system/libsystem_sandbox.dylib", RTLD_NOW) else { return nil }
    defer { dlclose(library) }
    guard let symbol = dlsym(library, "sandbox_extension_consume") else { return nil }
    let consume = unsafeBitCast(symbol, to: ConsumeFunction.self)
    return token.withCString { consume($0) }
}

private var mondRootKeepAlivePlayer: AVAudioPlayer?
private var mondRootKeepAliveTimer: Timer?

@MainActor
private func mondRootKeepAlive() {
    guard mondRootKeepAlivePlayer == nil else { return }
    try? AVAudioSession.sharedInstance().setCategory(.playback, options: .mixWithOthers)
    try? AVAudioSession.sharedInstance().setActive(true)

    let sampleRate = 8_000
    let samples = Int(Double(sampleRate) * 0.5)
    var wave = Data("RIFF".utf8)
    wave.append(withUnsafeBytes(of: UInt32(36 + samples * 2).littleEndian) { Data($0) })
    wave.append(Data("WAVEfmt ".utf8))
    wave.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
    wave.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
    wave.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
    wave.append(withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Data($0) })
    wave.append(withUnsafeBytes(of: UInt32(sampleRate * 2).littleEndian) { Data($0) })
    wave.append(withUnsafeBytes(of: UInt16(2).littleEndian) { Data($0) })
    wave.append(withUnsafeBytes(of: UInt16(16).littleEndian) { Data($0) })
    wave.append(Data("data".utf8))
    wave.append(withUnsafeBytes(of: UInt32(samples * 2).littleEndian) { Data($0) })
    wave.append(Data(count: samples * 2))

    mondRootKeepAlivePlayer = try? AVAudioPlayer(data: wave)
    mondRootKeepAlivePlayer?.volume = 0
    mondRootKeepAlivePlayer?.numberOfLoops = -1
    mondRootKeepAlivePlayer?.play()
    mondRootKeepAliveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
        mondRootKeepAlivePlayer?.play()
    }
    FilzaDiagnosticsAppend("mond", "Keep Alive started")
}

@MainActor
private func mondRootLetDie() {
    mondRootKeepAliveTimer?.invalidate()
    mondRootKeepAliveTimer = nil
    mondRootKeepAlivePlayer?.stop()
    mondRootKeepAlivePlayer = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    FilzaDiagnosticsAppend("mond", "Keep Alive stopped")
}

private let mondRootRespringDocument = """
<!DOCTYPE html><html><body>
<iframe id="frame" srcdoc="" sandbox="allow-forms allow-modals allow-orientation-lock allow-pointer-lock allow-popups allow-presentation allow-scripts"></iframe>
<script>
const frame=document.getElementById('frame');
const r=`<html><body><script>
const c=document.createElement('div');c.style.cssText='perspective:1px;perspective-origin:9999999% 9999999%;';document.body.appendChild(c);
for(let i=0;i<500;i++){const d=document.createElement('div');d.style.cssText='position:absolute;width:100vw;height:100vh;backdrop-filter:blur(100px);-webkit-backdrop-filter:blur(100px);transform:translate3d(100000px,100000px,'+i+'px) rotateY(90deg);';c.appendChild(d);}
setInterval(()=>{navigator.share({title:'R',text:'R'.repeat(100000)}).catch(()=>{});const x=new Uint8Array(1024*1024*10);crypto.getRandomValues(x);},0);
<\\/script></body></html>`;frame.srcdoc=r;
</script></body></html>
"""

private struct MondRootRespringView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { WKWebView() }
    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(mondRootRespringDocument, baseURL: nil)
    }
}

private struct MondEmbeddedLogView: View {
    @State private var log = ""
    private let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    Text(log.isEmpty ? "mond logs will appear here." : log)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(16)
                    Color.clear.frame(height: 1).id("mond-log-bottom")
                }
                .frame(minHeight: 205, maxHeight: max(205, geometry.size.height))
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .onAppear {
                    reload()
                    proxy.scrollTo("mond-log-bottom", anchor: .bottom)
                }
                .onReceive(timer) { _ in
                    let old = log
                    reload()
                    if old != log { proxy.scrollTo("mond-log-bottom", anchor: .bottom) }
                }
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = log
                    } label: {
                        Label("Copy Output", systemImage: "doc.on.doc")
                    }
                }
            }
        }
        .frame(height: 240)
    }

    private func reload() {
        let url = URL(fileURLWithPath: FilzaDiagnosticsDirectory(), isDirectory: true)
            .appendingPathComponent("Runtime.log")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let relevant = text.split(separator: "\n", omittingEmptySubsequences: true).filter { line in
            let value = line.lowercased()
            return value.contains("mond") || value.contains("gestalt") ||
                   value.contains("bad_query") || value.contains("(bq)") ||
                   value.contains("cmg") || value.contains("poster") ||
                   value.contains("housearrest") || value.contains("mcm")
        }
        log = relevant.suffix(180).joined(separator: "\n")
    }
}

private struct MondGestaltControllerDestination: UIViewControllerRepresentable {
    let path: String

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = MondGestaltHostFactory.makeViewController(path: path)
        controller.title = "MobileGestalt"
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

private struct MondPosterBoardDestination: View {
    var body: some View {
        // Filza already carries the complete current PosterBoard workspace and
        // its validated archive/write path.  Expose it at mond's PosterBoard
        // destination instead of duplicating a second write engine.
        WallpaperLabView()
    }
}

private struct MondCurrentSettingsView: View {
    let gestaltPath: String

    @Environment(\.dismiss) private var dismiss
    @AppStorage("method") private var method = "bad_query"
    @AppStorage("ka_on") private var keepAlive = true
    @AppStorage("token") private var token = ""

    @State private var exploitSucceeded = false
    @State private var accessStatus = ""
    @State private var runningExploit = false
    @State private var showConfirm = false
    @State private var showRespring = false

    private var gestaltDirectory: String {
        (gestaltPath as NSString).deletingLastPathComponent
    }

    private var tokenValid: Bool {
        !token.isEmpty && (mondRootConsumeSandboxToken(token) ?? -1) >= 0
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        if let url = URL(string: "https://github.com/rooootdev/mond") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "moon.stars.fill")
                                .font(.title2)
                                .frame(width: 45, height: 45)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading) {
                                Text("mond").font(.headline)
                                Text(String(mondEmbeddedUpstreamCommit.prefix(7)))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .fontWeight(.semibold)
                                .foregroundStyle(.tertiary)
                                .imageScale(.small)
                        }
                    }
                    .foregroundStyle(.primary)
                }

                Section {
                    Picker("Method", selection: $method) {
                        Text("bad_query").tag("bad_query")
                        Text("cmg").tag("cmg")
                    }
                    .pickerStyle(.segmented)

                    Button(runningExploit ? "Running…" : "Run Exploit") {
                        runExploit()
                    }
                    .disabled(runningExploit)
                } header: {
                    Label("Exploit", systemImage: "wrench.and.screwdriver")
                } footer: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(method == "cmg"
                             ? "**CMG:** Supports iOS 27.0 b1 - b4. PosterBoard wont work with this method. Only use this when bad_query isnt working for you."
                             : "**bad_query:** Supports iOS 27.0 b1 - b4. By [forcequit](https://github.com/forcequitOS).")
                        if !accessStatus.isEmpty { Text(accessStatus) }
                    }
                }

                Section {
                    HStack {
                        TextField("Sandbox Extension Token.", text: $token)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            UIPasteboard.general.string = token
                        } label: {
                            Image(systemName: "document.on.document")
                        }
                        .disabled(token.isEmpty)
                    }
                    .contextMenu {
                        Text("Class: \(token.split(separator: ";").first { $0.contains("com.apple") }.map(String.init) ?? "N/A")")
                        Text("Path: \(token.split(separator: ";").last.map(String.init) ?? "N/A")")
                        Button {
                            UIPasteboard.general.string = token
                        } label: {
                            Label("Copy token", systemImage: "doc.on.doc")
                        }
                    }

                    Button("Generate Token") { generateToken() }
                        .disabled(!exploitSucceeded)
                } header: {
                    Label("Token", systemImage: "key")
                } footer: {
                    if !token.isEmpty && token != "Failed to get token." {
                        Text(tokenValid ? "Your sandbox token is valid." : "Your sandbox token is invalid.")
                    }
                    if !exploitSucceeded {
                        Text("Disabled because exploit access has not been verified. Run Exploit first.")
                    }
                }

                Section {
                    Toggle("Keep Alive", isOn: $keepAlive)
                        .onChange(of: keepAlive) { enabled in
                            if enabled { mondRootKeepAlive() } else { mondRootLetDie() }
                        }
                } header: {
                    Label("Settings", systemImage: "gear")
                }

                Section {
                    Button("Respring") { showConfirm = true }
                } header: {
                    Label("Tools", systemImage: "wrench.and.screwdriver")
                } footer: {
                    Text("Respring method by [neon](https://github.com/neonmodder123), swift implementation by [skadz](https://github.com/skadz108).")
                }

                Section {
                    Link("roooot — Main developer", destination: URL(string: "https://github.com/rooootdev")!)
                    Link("forcequit — The bad_query exploit", destination: URL(string: "https://github.com/forcequitOS")!)
                    Link("johnny — MCM bug-class work", destination: URL(string: "https://github.com/0xjohnnydev")!)
                    Link("jailbreak.party — PartyUI / GestaltView", destination: URL(string: "https://github.com/jailbreakdotparty")!)
                } header: {
                    Label("Credits", systemImage: "person.3.fill")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                method = FilzaGestaltPreferredMethod()
                exploitSucceeded = FileManager.default.isReadableFile(atPath: gestaltPath)
                if keepAlive { mondRootKeepAlive() }
            }
            .onChange(of: method) { newMethod in
                FilzaGestaltSetPreferredMethod(newMethod)
                exploitSucceeded = false
                accessStatus = "Method changed to \(newMethod). Tap Run Exploit to refresh access."
            }
            .alert("Are you sure?", isPresented: $showConfirm) {
                Button("Cancel", role: .cancel) {}
                Button("Confirm") {
                    FilzaDiagnosticsAppend("mond", "Respring confirmed")
                    showRespring = true
                }
            } message: {
                Text("Confirm that you want to respring.")
            }
            .overlay {
                if showRespring {
                    MondRootRespringView()
                        .brightness(-1.0)
                        .ignoresSafeArea()
                }
            }
        }
    }

    private func runExploit() {
        FilzaGestaltSetPreferredMethod(method)
        runningExploit = true
        accessStatus = "Running \(method)…"
        FilzaDiagnosticsAppend("mond", "Run Exploit selected method=\(method)")
        DispatchQueue.global(qos: .userInitiated).async {
            var detail: NSString?
            let path = FilzaGestaltRefreshAccess(&detail)
            DispatchQueue.main.async {
                runningExploit = false
                let detailText = detail.map(String.init)
                exploitSucceeded = path?.isEmpty == false
                if let path, !path.isEmpty {
                    accessStatus = detailText ?? "Access active: \(path)"
                    FilzaDiagnosticsAppend("mond", "exploit access active path=\(path)")
                } else {
                    accessStatus = detailText ?? "Access failed"
                    FilzaDiagnosticsAppend("mond", "exploit access failed: \(accessStatus)")
                }
            }
        }
    }

    private func generateToken() {
        guard let generated = mondRootIssueSandboxToken(path: gestaltDirectory) else {
            token = "Failed to get token."
            FilzaDiagnosticsAppend("mond", "Generate Token failed")
            return
        }
        token = generated
        FilzaDiagnosticsAppend("mond", "Generate Token completed")
    }
}

private struct MondCurrentRootView: View {
    let gestaltPath: String

    @AppStorage("method") private var method = "bad_query"
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    MondEmbeddedLogView()
                        .listRowInsets(EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18))
                } header: {
                    Label("Logs", systemImage: "apple.terminal")
                }

                Section {
                    NavigationLink {
                        MondGestaltControllerDestination(path: gestaltPath)
                            .ignoresSafeArea(edges: .bottom)
                    } label: {
                        Text("MobileGestalt")
                    }

                    NavigationLink {
                        MondPosterBoardDestination()
                    } label: {
                        Text("PosterBoard")
                    }
                    .disabled(method == "cmg")

                    NavigationLink {
                        Text("HouseArrest is still in development and is not enabled in the current upstream build.")
                            .padding()
                            .navigationTitle("HouseArrest")
                    } label: {
                        Text("HouseArrest")
                    }
                    .disabled(true)
                } header: {
                    Label("Tweaks", systemImage: "paintbrush")
                } footer: {
                    if method == "cmg" {
                        Text("Only MobileGestalt is available when method is set to cmg.\nHouseArrest is still in development and may not work as expected.")
                    } else {
                        Text("HouseArrest is still in development and may not work as expected.")
                    }
                }
            }
            .navigationTitle("mond")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                MondCurrentSettingsView(gestaltPath: gestaltPath)
            }
            .onAppear {
                method = FilzaGestaltPreferredMethod()
                FilzaDiagnosticsAppend("mond",
                    "full upstream root appeared commit=\(mondEmbeddedUpstreamCommit)")
            }
        }
    }
}

@objc(MondFullHostFactory)
public final class MondFullHostFactory: NSObject {
    @objc(makeViewControllerWithPath:)
    public static func makeViewController(path: String) -> UIViewController {
        let effectivePath = path.isEmpty ? mondEmbeddedCanonicalGestaltPath : path
        FilzaDiagnosticsAppend("mond",
            "constructing full current mond root commit=\(mondEmbeddedUpstreamCommit)")
        let controller = UIHostingController(rootView: MondCurrentRootView(gestaltPath: effectivePath))
        controller.title = "mond"
        controller.view.backgroundColor = .systemGroupedBackground
        return controller
    }
}
