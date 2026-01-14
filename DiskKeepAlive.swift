import SwiftUI
import AppKit
import IOKit.pwr_mgt
import ServiceManagement

// MARK: - App Info
struct AppInfo {
    static let version = "1.2.0"
    static let repoURL = "https://github.com/meichengg/disk-keep-alive"
    static let changelogURL = "https://raw.githubusercontent.com/meichengg/disk-keep-alive/master/CHANGELOG.md"
}

// MARK: - Volume Model
struct Volume: Identifiable, Equatable {
    let id: String
    let name: String
    let path: String
    let isExternal: Bool
    let totalSize: Int64
    let freeSize: Int64
    let icon: NSImage?
    
    var formattedSize: String {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        return "\(fmt.string(fromByteCount: freeSize)) free of \(fmt.string(fromByteCount: totalSize))"
    }
    
    static func == (lhs: Volume, rhs: Volume) -> Bool {
        lhs.id == rhs.id && lhs.path == rhs.path
    }
}

// MARK: - Log Entry
struct LogEntry: Identifiable {
    let id = UUID()
    let time: Date
    let message: String
    
    var timeString: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return fmt.string(from: time)
    }
}

// MARK: - Settings Manager
class SettingsManager {
    static let shared = SettingsManager()
    private let defaults = UserDefaults.standard
    
    private let kSavedVolumes = "savedVolumeIDs"
    private let kInterval = "pingInterval"
    private let kLaunchAtLogin = "launchAtLogin"
    
    var savedVolumeIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: kSavedVolumes) ?? []) }
        set { defaults.set(Array(newValue), forKey: kSavedVolumes) }
    }
    
    var interval: Double {
        get { 
            let val = defaults.double(forKey: kInterval)
            return val > 0 ? val : 30
        }
        set { defaults.set(newValue, forKey: kInterval) }
    }
    
    var launchAtLogin: Bool {
        get { defaults.bool(forKey: kLaunchAtLogin) }
        set { defaults.set(newValue, forKey: kLaunchAtLogin) }
    }
}

// MARK: - Volume Manager
class VolumeManager: ObservableObject {
    static let shared = VolumeManager()
    
    @Published var volumes: [Volume] = []
    @Published var activeVolumes: Set<String> = []
    @Published var failedVolumes: Set<String> = []
    @Published var interval: Double = SettingsManager.shared.interval {
        didSet { 
            if interval != oldValue { 
                restartAllTimers()
                SettingsManager.shared.interval = interval
            }
        }
    }
    @Published var logs: [LogEntry] = []
    
    private var timers: [String: Timer] = [:]
    private var powerAssertions: [String: IOPMAssertionID] = [:]
    private var observers: [NSObjectProtocol] = []
    private var pendingVolumeIDs: Set<String> = []
    
    init() {
        setupObservers()
        refresh()
        restoreFromSettings()
    }
    
    private func restoreFromSettings() {
        let savedIDs = SettingsManager.shared.savedVolumeIDs
        guard !savedIDs.isEmpty else { return }
        
        pendingVolumeIDs = savedIDs
        log("🔄 Restoring \(savedIDs.count) saved volume(s)...")
        
        // Start any already mounted volumes immediately
        startPendingVolumes()
        
        if !pendingVolumeIDs.isEmpty {
            log("⏳ Waiting for: \(pendingVolumeIDs.joined(separator: ", "))")
        }
    }
    
    private func startPendingVolumes() {
        for vol in volumes {
            if pendingVolumeIDs.contains(vol.id) && !activeVolumes.contains(vol.path) {
                start(vol)
                pendingVolumeIDs.remove(vol.id)
                log("✅ Restored: \(vol.name)")
            }
        }
        
        if pendingVolumeIDs.isEmpty && !activeVolumes.isEmpty {
            log("✅ All saved volumes restored")
        }
    }
    
    func saveCurrentState() {
        let activeIDs = Set(volumes.filter { activeVolumes.contains($0.path) }.map { $0.id })
        SettingsManager.shared.savedVolumeIDs = activeIDs
    }
    
    private func setupObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] n in
            if let url = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                self?.log("📀 Mounted: \(url.lastPathComponent)")
            }
            self?.refresh()
            // Check if this is a pending volume we're waiting for
            self?.startPendingVolumes()
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] n in
            if let url = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                self?.log("⏏️ Unmounted: \(url.lastPathComponent)")
                self?.stop(path: url.path)
            }
            self?.refresh()
        })
    }
    
    func log(_ msg: String) {
        DispatchQueue.main.async {
            self.logs.append(LogEntry(time: Date(), message: msg))
            if self.logs.count > 100 { self.logs.removeFirst() }
            print("[\(LogEntry(time: Date(), message: "").timeString)] \(msg)")
        }
    }
    
    func refresh() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
                                       .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                       .volumeIsLocalKey, .volumeUUIDStringKey, .effectiveIconKey]
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else { return }
        
        let newVolumes = urls.compactMap { url -> Volume? in
            guard let rv = try? url.resourceValues(forKeys: Set(keys)),
                  url.path != "/", !url.path.hasPrefix("/System") else { return nil }
            let isExt = (rv.volumeIsRemovable ?? false) || (rv.volumeIsEjectable ?? false) || !(rv.volumeIsLocal ?? true)
            return Volume(
                id: rv.volumeUUIDString ?? url.path,
                name: rv.volumeName ?? url.lastPathComponent,
                path: url.path,
                isExternal: isExt,
                totalSize: Int64(rv.volumeTotalCapacity ?? 0),
                freeSize: Int64(rv.volumeAvailableCapacity ?? 0),
                icon: rv.effectiveIcon as? NSImage
            )
        }
        
        // Only update if volume list changed (not just size)
        let newPaths = Set(newVolumes.map { $0.path })
        let oldPaths = Set(volumes.map { $0.path })
        if newPaths != oldPaths {
            volumes = newVolumes
        }
    }
    
    func toggle(_ vol: Volume) {
        activeVolumes.contains(vol.path) ? stop(path: vol.path) : start(vol)
    }
    
    func start(_ vol: Volume) {
        stop(path: vol.path)
        activeVolumes.insert(vol.path)
        failedVolumes.remove(vol.path)
        createAssertion(vol)
        startTimer(vol)
        log("▶️ Started: \(vol.name) (interval: \(Int(interval))s)")
        saveCurrentState()
    }
    
    func stop(path: String) {
        let name = volumes.first { $0.path == path }?.name ?? path
        if timers[path] != nil {
            timers[path]?.invalidate()
            timers.removeValue(forKey: path)
            log("⏹️ Stopped: \(name)")
        }
        if let id = powerAssertions[path] {
            IOPMAssertionRelease(id)
            powerAssertions.removeValue(forKey: path)
        }
        activeVolumes.remove(path)
        failedVolumes.remove(path)
        saveCurrentState()
    }
    
    func startAll() { volumes.forEach { start($0) } }
    func stopAll() { Array(activeVolumes).forEach { stop(path: $0) } }
    
    func eject(_ vol: Volume) {
        // Remove from active immediately to update UI
        activeVolumes.remove(vol.path)
        failedVolumes.remove(vol.path)
        stop(path: vol.path)
        log("⏏️ Ejecting: \(vol.name)...")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            Thread.sleep(forTimeInterval: 0.3)
            
            let url = URL(fileURLWithPath: vol.path)
            var success = false
            var lastError: Error?
            
            for attempt in 1...3 {
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                    success = true
                    break
                } catch {
                    lastError = error
                    if attempt < 3 { Thread.sleep(forTimeInterval: 0.5) }
                }
            }
            
            DispatchQueue.main.async {
                if success {
                    self?.log("✅ Ejected: \(vol.name)")
                } else {
                    self?.log("❌ Eject failed: \(vol.name) - \(lastError?.localizedDescription ?? "Unknown")")
                }
            }
        }
    }
    
    private func restartAllTimers() {
        for path in Array(activeVolumes) {
            if let vol = volumes.first(where: { $0.path == path }) {
                timers[path]?.invalidate()
                startTimer(vol)
                log("🔄 Interval changed to \(Int(interval))s for: \(vol.name)")
            }
        }
    }
    
    private func createAssertion(_ vol: Volume) {
        var id: IOPMAssertionID = 0
        if IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Keep \(vol.name) awake" as CFString, &id) == kIOReturnSuccess {
            powerAssertions[vol.path] = id
        }
    }
    
    private func startTimer(_ vol: Volume) {
        let path = vol.path
        let name = vol.name
        ping(path, name)
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.ping(path, name)
        }
        timers[path] = t
        RunLoop.main.add(t, forMode: .common)
    }
    
    func ping(_ path: String, _ name: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var success = false
            
            // Method 1: Large random write + sync + read back
            let probeFile = "\(path)/.dka_\(ProcessInfo.processInfo.processIdentifier)"
            let fd = open(probeFile, O_RDWR | O_CREAT | O_TRUNC, 0o644)
            if fd >= 0 {
                // Write larger block (64KB) to bypass any caching
                var randomData = [UInt8](repeating: 0, count: 65536)
                arc4random_buf(&randomData, 65536)
                _ = write(fd, &randomData, 65536)
                
                // Force flush to physical disk
                _ = fcntl(fd, F_FULLFSYNC)
                
                // Seek to random position and read back
                lseek(fd, 0, SEEK_SET)
                var readBack = [UInt8](repeating: 0, count: 65536)
                _ = read(fd, &readBack, 65536)
                
                close(fd)
                unlink(probeFile)
                success = true
            }
            
            // Method 2: Read multiple random files across disk
            if success {
                self?.readMultipleRandomFiles(path, count: 5)
            }
            
            // Method 3: Stat the volume root (triggers metadata read)
            var statBuf = stat()
            _ = stat(path, &statBuf)
            
            DispatchQueue.main.async {
                if success {
                    self?.failedVolumes.remove(path)
                    self?.log("💓 Ping: \(name)")
                } else {
                    self?.failedVolumes.insert(path)
                    self?.log("❌ Ping failed: \(name)")
                }
            }
        }
    }
    
    private func readMultipleRandomFiles(_ path: String, count: Int) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: path) else { return }
        
        var files: [String] = []
        var scanned = 0
        while let file = enumerator.nextObject() as? String, scanned < 200 {
            let fullPath = "\(path)/\(file)"
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue {
                let attrs = try? fm.attributesOfItem(atPath: fullPath)
                let size = attrs?[.size] as? Int64 ?? 0
                if size > 4096 && size < 50_000_000 {
                    files.append(fullPath)
                }
            }
            scanned += 1
        }
        
        // Read from multiple random files
        for _ in 0..<min(count, files.count) {
            guard let randomFile = files.randomElement() else { continue }
            let fd = open(randomFile, O_RDONLY)
            if fd >= 0 {
                let fileSize = lseek(fd, 0, SEEK_END)
                if fileSize > 4096 {
                    // Read from multiple random positions
                    for _ in 0..<3 {
                        let randomPos = off_t(arc4random_uniform(UInt32(min(fileSize - 4096, Int64(Int32.max)))))
                        lseek(fd, randomPos, SEEK_SET)
                        var buffer = [UInt8](repeating: 0, count: 8192)
                        _ = read(fd, &buffer, 8192)
                    }
                }
                close(fd)
            }
        }
    }
}


// MARK: - Views
struct ContentView: View {
    @ObservedObject var vm = VolumeManager.shared
    @State private var showLogs = false
    @State private var copyToast = false
    @State private var sliderValue: Double = SettingsManager.shared.interval
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "externaldrive.badge.checkmark").foregroundColor(.accentColor)
                Text("Disk Keep Alive").font(.headline)
                Spacer()
                Button(action: { showLogs.toggle() }) {
                    Image(systemName: "list.bullet.rectangle").foregroundColor(showLogs ? .accentColor : .secondary)
                }.buttonStyle(.borderless).help("Toggle logs")
                Button(action: { vm.refresh() }) { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
            }.padding()
            
            Divider()
            
            if showLogs { logView } else { volumeList }
            
            Divider()
            controlsView
        }
        .overlay(alignment: .bottom) {
            if copyToast {
                Text("✓ Copied!")
                    .font(.caption.bold())
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.accentColor))
                    .padding(.bottom, 100)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
    
    func showCopyToast() {
        withAnimation { copyToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            withAnimation { copyToast = false }
        }
    }
    
    var volumeList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(vm.volumes) { vol in
                    VolumeRow(
                        vol: vol,
                        active: vm.activeVolumes.contains(vol.path),
                        failed: vm.failedVolumes.contains(vol.path),
                        onToggle: { vm.toggle(vol) },
                        onEject: { vm.eject(vol) }
                    )
                }
            }.padding()
        }
    }
    
    var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(vm.logs.map { "[\($0.timeString)] \($0.message)" }.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
                    .id("logText")
            }
            .defaultScrollAnchor(.bottom)
            .background(Color.black.opacity(0.03))
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 8) {
                    Button(action: {
                        let all = vm.logs.map { "[\($0.timeString)] \($0.message)" }.joined(separator: "\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(all, forType: .string)
                        showCopyToast()
                    }) {
                        Image(systemName: "doc.on.doc").font(.body).foregroundColor(.secondary)
                    }.buttonStyle(.borderless).help("Copy all logs")
                    
                    Button(action: { proxy.scrollTo("logText", anchor: .bottom) }) {
                        Image(systemName: "arrow.down.circle.fill").font(.title3).foregroundColor(.accentColor)
                    }.buttonStyle(.borderless).help("Scroll to bottom")
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
                .padding(.trailing, 20)
                .padding(.bottom, 8)
            }
        }
    }
    
    var controlsView: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Interval:").foregroundColor(.secondary)
                Slider(value: $sliderValue, in: 5...120, step: 5) { editing in
                    if !editing {
                        vm.interval = sliderValue
                    }
                }.frame(width: 150)
                Text("\(Int(sliderValue))s").monospacedDigit().frame(width: 35)
            }
            HStack(spacing: 12) {
                Button(action: { vm.startAll() }) { Label("Start All", systemImage: "play.fill") }.buttonStyle(.borderedProminent)
                Button(action: { vm.stopAll() }) { Label("Stop All", systemImage: "stop.fill") }.buttonStyle(.bordered)
            }
        }.padding()
    }
}

struct VolumeRow: View {
    let vol: Volume
    let active: Bool
    let failed: Bool
    let onToggle: () -> Void
    let onEject: () -> Void
    
    var statusColor: Color {
        if !active { return .clear }
        return failed ? .orange : .green
    }
    
    var usedPercent: Double {
        guard vol.totalSize > 0 else { return 0 }
        return Double(vol.totalSize - vol.freeSize) / Double(vol.totalSize)
    }
    
    var barColor: LinearGradient {
        let used = usedPercent
        let usedColor: Color = used > 0.9 ? .red : (used > 0.75 ? .orange : .blue)
        return LinearGradient(
            stops: [
                .init(color: usedColor, location: 0),
                .init(color: usedColor, location: used),
                .init(color: Color.secondary.opacity(0.3), location: used),
                .init(color: Color.secondary.opacity(0.3), location: 1)
            ],
            startPoint: .leading, endPoint: .trailing
        )
    }
    
    var body: some View {
        HStack(spacing: 12) {
            if let icon = vol.icon {
                Image(nsImage: icon).resizable().frame(width: 32, height: 32)
            } else {
                Image(systemName: "externaldrive.fill").font(.title).foregroundColor(.orange).frame(width: 32, height: 32)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(vol.name).fontWeight(.medium)
                RoundedRectangle(cornerRadius: 3).fill(barColor).frame(height: 6)
                Text(vol.formattedSize).font(.caption2).foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button(action: onEject) {
                Image(systemName: "eject.fill").foregroundColor(.secondary)
            }.buttonStyle(.borderless).help("Eject \(vol.name)")
            
            if active {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                    .help(failed ? "Ping failed - read-only volume?" : "Active")
            }
            Toggle("", isOn: Binding(get: { active }, set: { _ in onToggle() })).toggleStyle(.switch).labelsHidden()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.08)))
    }
}


// MARK: - Update Checker
class UpdateChecker {
    static let shared = UpdateChecker()
    private var timer: Timer?
    
    func startPeriodicCheck() {
        // Check immediately on startup
        checkForUpdate()
        
        // Then check every 6 hours
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            self?.checkForUpdate()
        }
    }
    
    func checkForUpdate() {
        guard let url = URL(string: AppInfo.changelogURL) else { return }
        
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        
        URLSession.shared.dataTask(with: request) { data, _, error in
            guard let data = data, error == nil,
                  let content = String(data: data, encoding: .utf8) else { return }
            
            // Parse latest version from changelog
            let lines = content.components(separatedBy: "\n")
            for line in lines {
                if line.hasPrefix("## ") {
                    let versionLine = line.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
                    if let match = versionLine.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) {
                        let latestVersion = String(versionLine[match])
                        if latestVersion != AppInfo.version && self.isNewer(latestVersion, than: AppInfo.version) {
                            DispatchQueue.main.async {
                                VolumeManager.shared.log("🆕 Update available: v\(latestVersion)")
                                self.showUpdateNotification(latestVersion)
                            }
                        }
                        break
                    }
                }
            }
        }.resume()
    }
    
    private func isNewer(_ new: String, than current: String) -> Bool {
        let newParts = new.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }
        
        for i in 0..<max(newParts.count, currentParts.count) {
            let n = i < newParts.count ? newParts[i] : 0
            let c = i < currentParts.count ? currentParts[i] : 0
            if n > c { return true }
            if n < c { return false }
        }
        return false
    }
    
    private func showUpdateNotification(_ version: String) {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "Disk Keep Alive v\(version) is available. You are currently using v\(AppInfo.version)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "\(AppInfo.repoURL)/releases/latest") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

// MARK: - About Window
class AboutWindowController {
    static let shared = AboutWindowController()
    private var window: NSWindow?
    
    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 350),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        w.title = "About Disk Keep Alive"
        w.contentView = NSHostingView(rootView: AboutView())
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct AboutView: View {
    @State private var changelog: String = "Loading..."
    @State private var latestVersion: String = ""
    @State private var isLoading = true
    
    var body: some View {
        VStack(spacing: 16) {
            // App icon and name
            Image(systemName: "externaldrive.fill.badge.checkmark")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)
            
            Text("Disk Keep Alive")
                .font(.title.bold())
            
            Text("Version \(AppInfo.version)")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            if !latestVersion.isEmpty && latestVersion != AppInfo.version {
                Text("New version available: \(latestVersion)")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            
            Divider()
            
            // Changelog
            VStack(alignment: .leading, spacing: 8) {
                Text("Latest Release Notes")
                    .font(.headline)
                
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    ScrollView {
                        Text(changelog)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 120)
                    .background(Color.black.opacity(0.03))
                    .cornerRadius(8)
                }
            }
            
            Divider()
            
            HStack(spacing: 16) {
                Button("GitHub") {
                    if let url = URL(string: AppInfo.repoURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                
                Button("Check for Updates") {
                    fetchChangelog()
                }
            }
        }
        .padding(24)
        .frame(width: 400)
        .onAppear { fetchChangelog() }
    }
    
    func fetchChangelog() {
        isLoading = true
        guard let url = URL(string: AppInfo.changelogURL) else { return }
        
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                isLoading = false
                
                guard let data = data, error == nil,
                      let content = String(data: data, encoding: .utf8) else {
                    changelog = "Failed to fetch changelog"
                    return
                }
                
                // Parse latest version from changelog
                let lines = content.components(separatedBy: "\n")
                for line in lines {
                    if line.hasPrefix("## ") || line.hasPrefix("# ") {
                        let versionLine = line.replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
                        if let match = versionLine.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) {
                            latestVersion = String(versionLine[match])
                            break
                        }
                    }
                }
                
                changelog = content
            }
        }.resume()
    }
}

// MARK: - App Delegate (Menu Bar Only)
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var statusItem: NSStatusItem!
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        
        createWindow()
        createMenuBar()
        VolumeManager.shared.log("🚀 App started")
        
        // Start periodic update check
        UpdateChecker.shared.startPeriodicCheck()
    }
    
    func createWindow() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        w.title = "Disk Keep Alive"
        w.contentView = NSHostingView(rootView: ContentView())
        w.center()
        w.setFrameAutosaveName("Main")
        w.isReleasedWhenClosed = false
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func createMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: nil)
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Window", action: #selector(showWindow), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Start All", action: #selector(startAll), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Stop All", action: #selector(stopAll), keyEquivalent: ""))
        menu.addItem(.separator())
        
        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.state = SettingsManager.shared.launchAtLogin ? .on : .off
        menu.addItem(launchItem)
        
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "About", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: ""))
        statusItem.menu = menu
        
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            let active = !VolumeManager.shared.activeVolumes.isEmpty
            self?.statusItem.button?.image = NSImage(systemSymbolName: active ? "externaldrive.fill.badge.checkmark" : "externaldrive.fill", accessibilityDescription: nil)
        }
    }
    
    @objc func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let newState = !SettingsManager.shared.launchAtLogin
        SettingsManager.shared.launchAtLogin = newState
        sender.state = newState ? .on : .off
        
        if #available(macOS 13.0, *) {
            do {
                if newState {
                    try SMAppService.mainApp.register()
                    VolumeManager.shared.log("✅ Enabled Launch at Login")
                } else {
                    try SMAppService.mainApp.unregister()
                    VolumeManager.shared.log("✅ Disabled Launch at Login")
                }
            } catch {
                VolumeManager.shared.log("❌ Launch at Login failed: \(error.localizedDescription)")
            }
        } else {
            VolumeManager.shared.log("⚠️ Launch at Login requires macOS 13+")
        }
    }
    
    @objc func showAbout() {
        AboutWindowController.shared.show()
    }
    
    @objc func showWindow() {
        if window == nil {
            createWindow()
        } else {
            window?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc func startAll() {
        VolumeManager.shared.startAll()
    }
    
    @objc func stopAll() {
        VolumeManager.shared.stopAll()
    }
    
    @objc func quitApp() {
        VolumeManager.shared.stopAll()
        VolumeManager.shared.log("👋 App quitting")
        NSApp.terminate(nil)
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

// MARK: - Main
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Cmd+Q hides window instead of quit
NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
    if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "q" {
        if let window = NSApp.keyWindow {
            window.orderOut(nil)
        }
        return nil
    }
    return event
}

app.run()
