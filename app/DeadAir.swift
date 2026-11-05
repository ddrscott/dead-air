// Dead Air: a menu bar player for the station. It runs `dead-air-wire | dead-air-write`
// for the words, voices them with Phonon through Ollama, and plays them with
// AVAudioPlayer, so pause, skip, the media keys, and Control Center all work.
import AppKit
import AVFoundation
import MediaPlayer
import SwiftUI

let orange = Color(red: 0xE8 / 255, green: 0x5D / 255, blue: 0)
let home = FileManager.default.homeDirectoryForCurrentUser.path
let cacheDir = URL(fileURLWithPath: home + "/.cache/dead-air")
let airedFile = cacheDir.appendingPathComponent("aired.txt")
let logFile = cacheDir.appendingPathComponent("app.log")
let searchPath = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

let voices = ["Easton", "Zoey", "Miles", "Harper", "Preston", "Juniper", "Spencer", "Imogen", "Trevor", "Maeve",
              "Old Mortlake", "Captain Silas Blackwater", "The Thing Under the Stairs", "Vyrmathrax the Ancient"]
let idents = [
    "It's {time}. You're listening to Dead Air.",
    "Dead Air. It's {time}, and the newsroom is still typing.",
    "This is Dead Air, coming to you from a laptop that should probably be closed. It's {time}.",
    "{time}. Still here? So are we. Dead Air.",
    "Dead Air. Every word you hear was written on this machine, by a machine. It's {time}.",
    "You're listening to Dead Air. If it goes quiet, check on us.",
]

func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    NSFont(name: "JetBrains Mono", size: size) != nil
        ? .custom("JetBrains Mono", size: size).weight(weight)
        : .system(size: size, weight: weight, design: .monospaced)
}

func log(_ s: String) {
    let line = "\(Date().formatted(date: .omitted, time: .standard)) app \(s)\n"
    try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    if let h = try? FileHandle(forWritingTo: logFile) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? Data(line.utf8).write(to: logFile)
    }
}

struct Segment: Identifiable, Decodable, Equatable {
    var id: String
    var text: String
    var headline: String
    var source: String
    var link: String
    var isIdent = false
    enum CodingKeys: String, CodingKey { case id, text, headline, source, link }
}

struct Voiced { let seg: Segment; let wav: URL }

@MainActor
final class Station: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = Station()
    @Published var now: Segment?
    @Published var playing = false
    @Published var status = "Press play."
    @Published var upNext: [Segment] = []      // written, waiting to be voiced or played
    @Published var recent: [Segment] = []
    @Published var elapsed: Double = 0
    @Published var duration: Double = 0

    @AppStorage("voice") var voice = "Easton"
    @AppStorage("identVoice") var identVoice = "The Thing Under the Stairs"
    @AppStorage("idents") var identsOn = true

    let ollama = URL(string: "http://localhost:11434/v1/audio/speech")!
    private var pending: [Segment] = []
    private var ready: [Voiced] = []
    private var player: AVAudioPlayer?
    private var procs: [Process] = []
    private var buffer = Data()
    private var started = false
    private var voicedNews = 0
    private var waiting = false
    private var tick: Timer?

    override init() {
        super.init()
        let cc = MPRemoteCommandCenter.shared()
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in self?.toggle(); return .success }
        cc.playCommand.addTarget { [weak self] _ in if self?.playing == false { self?.toggle() }; return .success }
        cc.pauseCommand.addTarget { [weak self] _ in if self?.playing == true { self?.toggle() }; return .success }
        cc.nextTrackCommand.addTarget { [weak self] _ in self?.skip(); return .success }
        cc.previousTrackCommand.isEnabled = false
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        tick = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player else { return }
                self.elapsed = p.currentTime
            }
        }
    }

    // deadair://play, pause, toggle, skip: for Shortcuts, Siri, and `open deadair://play`.
    func handle(_ url: URL) {
        guard let host = url.host else { return }
        let str = url.absoluteString
        switch host {
        case "play": if !playing { toggle() }
        case "pause": if playing { toggle() }
        case "toggle": toggle()
        case "skip", "next": skip()
        default: log("unknown URL \(str)")
        }
    }

    // MARK: transport

    func toggle() {
        if !started { start() }
        playing.toggle()
        if playing {
            if let p = player { p.play() } else { advance() }
        } else {
            player?.pause()
        }
        publishNowPlaying()
    }

    func skip() {
        player?.stop()
        player = nil
        if playing { advance() }
    }

    private func advance() {
        guard playing else { return }
        guard !ready.isEmpty else {
            player = nil; now = nil; waiting = true; elapsed = 0; duration = 0
            status = pending.isEmpty ? "The newsroom is typing…" : "Voicing…"
            publishNowPlaying()
            return
        }
        waiting = false
        let v = ready.removeFirst()
        do {
            let p = try AVAudioPlayer(contentsOf: v.wav)
            p.delegate = self
            p.play()
            player = p
            now = v.seg
            duration = p.duration
            elapsed = 0
            status = "On air"
            if !v.seg.isIdent {
                recent.insert(v.seg, at: 0)
                recent = Array(recent.prefix(15))
                markAired(v.seg.id)
            }
            refreshUpNext()
            publishNowPlaying()
        } catch {
            log("can't play \(v.wav.path): \(error)")
            advance()
        }
        try? FileManager.default.removeItem(at: v.wav)   // the player has it in memory
    }

    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully: Bool) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            if self.player === p { self.player = nil; self.advance() }
        }
    }

    // MARK: the newsroom (wire | write)

    func start() {
        started = true
        // WAVs voiced but never played by the last run.
        for f in (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)) ?? []
        where f.lastPathComponent.hasPrefix("seg-") && f.pathExtension == "wav" {
            try? FileManager.default.removeItem(at: f)
        }
        status = "Reading the wire…"
        let env = ["PATH": searchPath, "HOME": home]
        let wire = Process(), write = Process()
        wire.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        wire.arguments = ["dead-air-wire", "--follow", "5", "--seen", airedFile.path, "--no-remember"]
        write.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        write.arguments = ["dead-air-write"]
        wire.environment = env; write.environment = env
        let mid = Pipe(), out = Pipe()
        wire.standardOutput = mid; write.standardInput = mid; write.standardOutput = out
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logFile.path) { FileManager.default.createFile(atPath: logFile.path, contents: nil) }
        let errLog = try? FileHandle(forWritingTo: logFile)
        errLog?.seekToEndOfFile()
        wire.standardError = errLog; write.standardError = errLog
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            Task { @MainActor in self?.receive(data) }
        }
        do {
            try wire.run(); try write.run()
            procs = [wire, write]
        } catch {
            status = "Couldn't start dead-air-wire. Is it installed? (make install)"
            log("start failed: \(error)")
        }
        Task { await voiceLoop() }
    }

    func stop() {
        for p in procs where p.isRunning { p.terminate() }
        procs = []
    }

    private func receive(_ data: Data) {
        if data.isEmpty { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let seg = try? JSONDecoder().decode(Segment.self, from: line), !seg.text.isEmpty {
                pending.append(seg)
                refreshUpNext()
            }
        }
    }

    private func refreshUpNext() {
        upNext = ready.map(\.seg).filter { !$0.isIdent } + pending
    }

    private func markAired(_ id: String) {
        guard !id.isEmpty else { return }
        if let h = try? FileHandle(forWritingTo: airedFile) {
            h.seekToEndOfFile(); h.write(Data((id + "\n").utf8)); try? h.close()
        } else {
            try? Data((id + "\n").utf8).write(to: airedFile)
        }
    }

    // MARK: voicing with Phonon

    private func voiceLoop() async {
        while true {
            if ready.count < 2, !pending.isEmpty {
                let seg = pending.removeFirst()
                if identsOn && voicedNews % 4 == 0 {
                    await voice(identSegment(), as: identVoice)
                }
                await voice(seg, as: voice)
                voicedNews += 1
                refreshUpNext()
            } else {
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    private func identSegment() -> Segment {
        let d = Date(), cal = Calendar.current
        let h = cal.component(.hour, from: d) % 12 == 0 ? 12 : cal.component(.hour, from: d) % 12
        let m = cal.component(.minute, from: d)
        let t = m == 0 ? "\(h) o'clock" : String(format: "%d:%02d", h, m)
        let text = idents.randomElement()!.replacingOccurrences(of: "{time}", with: t)
        return Segment(id: "", text: text, headline: "Station ID", source: "Dead Air", link: "", isIdent: true)
    }

    private func voice(_ seg: Segment, as voiceName: String) async {
        var req = URLRequest(url: ollama, timeoutInterval: 180)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": "phonon:latest", "voice": voiceName, "input": seg.text, "response_format": "pcm"])
        do {
            let (pcm, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                status = "Phonon said \((resp as? HTTPURLResponse)?.statusCode ?? 0). Try: ollama pull phonon"
                return
            }
            let wav = cacheDir.appendingPathComponent("seg-\(UUID().uuidString).wav")
            try wavData(trimmed(pcm)).write(to: wav)
            ready.append(Voiced(seg: seg, wav: wav))
            if waiting { advance() }
        } catch {
            status = "Can't reach Ollama on localhost:11434. Is it running?"
            log("voice failed: \(error)")
            pending.insert(seg, at: 0)
            try? await Task.sleep(for: .seconds(5))
        }
    }

    // Phonon opens every clip with ~200 ms of silence; keep 20 ms of it.
    private func trimmed(_ pcm: Data) -> Data {
        let first: Int = pcm.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            return s.firstIndex { abs(Int32($0)) > 1000 } ?? 0
        }
        return pcm.subdata(in: max(0, first - 480) * 2 ..< pcm.count)
    }

    private func wavData(_ pcm: Data, rate: UInt32 = 24000) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + UInt32(pcm.count)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }

    // MARK: Control Center / media keys

    private func publishNowPlaying() {
        let c = MPNowPlayingInfoCenter.default()
        guard let seg = now else {
            c.nowPlayingInfo = [MPMediaItemPropertyTitle: status, MPMediaItemPropertyArtist: "Dead Air"]
            c.playbackState = playing ? .playing : .paused
            return
        }
        c.nowPlayingInfo = [
            MPMediaItemPropertyTitle: seg.headline,
            MPMediaItemPropertyArtist: seg.source,
            MPMediaItemPropertyAlbumTitle: "Dead Air",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player?.currentTime ?? 0,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
        ]
        c.playbackState = playing ? .playing : .paused
    }
}

// MARK: UI

struct Header: View {
    let title: String
    var body: some View {
        HStack(spacing: 0) {
            Text("// ").foregroundStyle(orange)
            Text(title).foregroundStyle(.secondary)
        }
        .font(mono(10, .semibold))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PlayerView: View {
    @ObservedObject var s: Station

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Header(title: "DEAD_AIR")
                if s.playing && s.now != nil {
                    Text("● ON AIR").font(mono(10, .bold)).foregroundStyle(orange)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if s.playing { Text("$").font(mono(12, .bold)).foregroundStyle(orange) }
                    Text(s.now?.source ?? s.status).font(mono(11)).foregroundStyle(.secondary)
                }
                Text(s.now?.headline ?? "Tech news, written and read on this Mac.")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let text = s.now?.text {
                    ScrollView {
                        Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 90)
                }
            }

            ProgressView(value: s.duration > 0 ? min(s.elapsed / s.duration, 1) : 0)
                .progressViewStyle(.linear).tint(orange)

            HStack(spacing: 14) {
                Button(action: s.toggle) {
                    Image(systemName: s.playing ? "pause.fill" : "play.fill").frame(width: 28, height: 22)
                }
                .keyboardShortcut(.space, modifiers: [])
                Button(action: s.skip) { Image(systemName: "forward.fill").frame(width: 28, height: 22) }
                    .disabled(!s.playing)
                Spacer()
                if let link = s.now?.link, let url = URL(string: link), !link.isEmpty {
                    Button("Open story ↗") { NSWorkspace.shared.open(url) }.font(mono(11))
                }
            }
            .buttonStyle(.bordered)

            Divider()
            Header(title: "UP_NEXT (\(s.upNext.count))")
            if s.upNext.isEmpty {
                Text("Nothing written yet.").font(mono(11)).foregroundStyle(.tertiary)
            }
            ForEach(s.upNext.prefix(4)) { seg in row(seg) }

            if !s.recent.isEmpty {
                Header(title: "RECENT")
                ForEach(s.recent.dropFirst().prefix(5)) { seg in row(seg) }
            }

            Divider()
            HStack {
                Picker("Voice", selection: $s.voice) { ForEach(voices, id: \.self) { Text($0) } }
                    .labelsHidden().frame(width: 150)
                Toggle("IDs", isOn: $s.identsOn).toggleStyle(.checkbox).font(mono(11))
                Spacer()
                Button("Quit") { s.stop(); NSApp.terminate(nil) }.font(mono(11))
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    func row(_ seg: Segment) -> some View {
        Button {
            if let url = URL(string: seg.link), !seg.link.isEmpty { NSWorkspace.shared.open(url) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(seg.source.prefix(3)).uppercased()).font(mono(9, .bold)).foregroundStyle(.secondary)
                    .frame(width: 26, alignment: .leading)
                Text(seg.headline).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(seg.headline)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { urls.forEach(Station.shared.handle) }
    }
}

@main
struct DeadAirApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var station = Station.shared

    var body: some Scene {
        MenuBarExtra {
            PlayerView(s: station)
        } label: {
            Image(systemName: station.playing ? "dot.radiowaves.left.and.right" : "radio")
        }
        .menuBarExtraStyle(.window)
    }
}
