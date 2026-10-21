// MacClean — 나만 쓰는 맥 클리너
// 화면은 SwiftUI, 청소는 앱 안에 들어 있는 macclean.py 가 담당해요.

import SwiftUI
import AppKit
import IOKit.ps
import ServiceManagement

// MARK: - 데이터

struct CleanItem: Codable, Identifiable {
    let id: Int
    let cat: String
    let label: String
    let note: String
    let level: String          // "safe" | "check"
    let size: Int64
    let paths: [String]
    var isSafe: Bool { level == "safe" }
}

struct ScanResult: Codable { let items: [CleanItem]; let trash: Int64? }
struct TrashResult: Codable { let moved: Int; let failed: [String] }
struct TrashInfo: Codable { let trash: Int64? }

struct AppEntry: Codable, Identifiable, Hashable {
    let name: String
    let path: String
    let bundle: String
    let size: Int64
    var id: String { path }
}

struct Leftover: Codable, Hashable { let path: String; let size: Int64 }

struct AppInfo: Codable {
    let path: String
    let bundle: String
    let size: Int64
    let leftovers: [Leftover]
    let kept: [String]
}

enum TrashSortKey: String, CaseIterable { case date, size, name }

/// 휴지통 '날짜로 선택': 이 기간보다 오래전에 삭제한 항목
enum TrashAge: String, CaseIterable, Identifiable {
    case day, week, month, month3, month6, year
    var id: String { rawValue }

    var label: String {
        switch self {
        case .day: return "하루"
        case .week: return "일주일"
        case .month: return "1개월"
        case .month3: return "3개월"
        case .month6: return "6개월"
        case .year: return "1년"
        }
    }

    var cutoff: Date {
        let cal = Calendar.current
        let now = Date()
        switch self {
        case .day: return cal.date(byAdding: .day, value: -1, to: now) ?? now
        case .week: return cal.date(byAdding: .day, value: -7, to: now) ?? now
        case .month: return cal.date(byAdding: .month, value: -1, to: now) ?? now
        case .month3: return cal.date(byAdding: .month, value: -3, to: now) ?? now
        case .month6: return cal.date(byAdding: .month, value: -6, to: now) ?? now
        case .year: return cal.date(byAdding: .year, value: -1, to: now) ?? now
        }
    }
}

struct PrivItem: Codable, Hashable {
    let key: String
    let label: String
    let count: Int?
    let size: Int64
    let available: Bool
}

struct PrivBrowser: Codable, Identifiable {
    let name: String
    let bundle: String
    let running: Bool
    let noAccess: Bool
    let items: [PrivItem]
    var id: String { name }
}

struct PrivRequest: Codable { let browser: String; let items: [String] }
struct PrivResult: Codable { let browser: String; let done: [String]; let errors: [String]; let skipped: String? }

struct TrashEntry: Identifiable, Hashable {
    let url: URL
    let name: String
    let added: Date?
    var size: Int64?
    let origin: String?
    var id: String { url.path }
}

// MARK: - 도우미

func fmt(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func tilde(_ p: String) -> String {
    let home = NSHomeDirectory()
    if p.hasPrefix(home) { return "~" + String(p.dropFirst(home.count)) }
    return p
}

func revealInFinder(_ paths: [String]) {
    let urls = paths.prefix(20)
        .filter { FileManager.default.fileExists(atPath: $0) }
        .map { URL(fileURLWithPath: $0) }
    if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
}

func relativeDate(_ d: Date?) -> String {
    guard let d else { return "알 수 없음" }
    let f = RelativeDateTimeFormatter()
    f.locale = Locale(identifier: "ko_KR")
    f.unitsStyle = .full
    return f.localizedString(for: d, relativeTo: Date())
}

func absoluteDate(_ d: Date?) -> String {
    guard let d else { return "" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "ko_KR")
    f.dateFormat = "yyyy.M.d (E) HH:mm"
    return f.string(from: d)
}

/// 실제 디스크 사용량 (폴더면 안쪽까지)
func diskSize(_ url: URL) -> Int64 {
    let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
    guard let v = try? url.resourceValues(forKeys: keys) else { return 0 }
    if v.isDirectory == true && v.isSymbolicLink != true {
        var total: Int64 = 0
        if let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                                   options: [], errorHandler: { _, _ in true }) {
            while let f = en.nextObject() as? URL {
                if let fv = try? f.resourceValues(forKeys: keys) {
                    total += Int64(fv.totalFileAllocatedSize ?? fv.fileAllocatedSize ?? 0)
                }
            }
        }
        return total
    }
    return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// MacClean이 휴지통에 넣은 항목의 원래 위치 기록 (엔진이 씀)
enum TrashLog {
    struct Entry: Codable { let trash: String; let orig: String; let time: Double }

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacClean/trash-log.json")
    }

    static func entries() -> [Entry] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: d)) ?? []
    }

    static func origins() -> [String: String] {
        var m: [String: String] = [:]
        for e in entries() { m[e.trash] = e.orig }
        return m
    }

    /// 지정한 항목과 이미 휴지통에 없는 항목을 기록에서 정리
    static func prune(removing paths: [String] = []) {
        let gone = Set(paths)
        let keep = entries().filter { !gone.contains($0.trash) && FileManager.default.fileExists(atPath: $0.trash) }
        if let d = try? JSONEncoder().encode(keep) { try? d.write(to: url, options: .atomic) }
    }
}

// MARK: - 엔진 (macclean.py 실행)

enum EngineError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        if case .failed(let s) = self { return s }
        return nil
    }
}

final class LineBuffer: @unchecked Sendable {
    let lock = NSLock()
    var pending = ""
    var other = ""
}

enum Engine {
    static var script: String { Bundle.main.path(forResource: "macclean", ofType: "py") ?? "" }

    static func run(_ args: [String], input: Data? = nil,
                    progress: ((Int, Int, String) -> Void)? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                p.arguments = [script] + args
                var env = ProcessInfo.processInfo.environment
                env["PYTHONIOENCODING"] = "utf-8"
                env["PYTHONDONTWRITEBYTECODE"] = "1"
                p.environment = env

                let out = Pipe(), err = Pipe(), inp = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = inp

                let buf = LineBuffer()
                err.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
                    buf.lock.lock()
                    buf.pending += s
                    var lines: [String] = []
                    while let r = buf.pending.range(of: "\n") {
                        lines.append(String(buf.pending[..<r.lowerBound]))
                        buf.pending.removeSubrange(..<r.upperBound)
                    }
                    buf.lock.unlock()
                    for line in lines {
                        let f = line.components(separatedBy: "\t")
                        if f.count == 4, f[0] == "PROGRESS", let i = Int(f[1]), let n = Int(f[2]) {
                            progress?(i, n, f[3])
                        } else {
                            buf.lock.lock(); buf.other += line + "\n"; buf.lock.unlock()
                        }
                    }
                }

                do { try p.run() } catch {
                    cont.resume(throwing: EngineError.failed("엔진을 실행하지 못했어요: \(error.localizedDescription)"))
                    return
                }
                if let input { inp.fileHandleForWriting.write(input) }
                try? inp.fileHandleForWriting.close()

                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                err.fileHandleForReading.readabilityHandler = nil

                if p.terminationStatus == 0 {
                    cont.resume(returning: data)
                } else {
                    buf.lock.lock()
                    let msg = (buf.other + buf.pending).trimmingCharacters(in: .whitespacesAndNewlines)
                    buf.lock.unlock()
                    cont.resume(throwing: EngineError.failed(msg.isEmpty ? "엔진 오류 (코드 \(p.terminationStatus))" : msg))
                }
            }
        }
    }

    static func call<T: Decodable>(_ type: T.Type, _ args: [String], input: Data? = nil,
                                   progress: ((Int, Int, String) -> Void)? = nil) async throws -> T {
        let data = try await run(args, input: input, progress: progress)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - 업데이트 (GitHub에서 소스를 받아 이 맥에서 빌드)

struct RemoteVersion: Codable { let version: String; let notes: String? }

enum UpdateState: Equatable {
    case idle, checking, upToDate, available, downloading, building, restarting
    case failed(String)
}

enum Updater {
    static let repo = "joukey123/macclean"
    static let branch = "main"

    /// GitHub API: 캐시가 거의 없어서 올리자마자 보임 (시간당 60회 제한이라 실패하면 raw 주소로)
    static var apiVersionURL: URL {
        URL(string: "https://api.github.com/repos/\(repo)/contents/version.json?ref=\(branch)")!
    }
    static var versionURL: URL {
        URL(string: "https://raw.githubusercontent.com/\(repo)/\(branch)/version.json?t=\(Int(Date().timeIntervalSince1970))")!
    }

    static func fetchRemoteVersion() async throws -> RemoteVersion {
        var api = URLRequest(url: apiVersionURL)
        api.setValue("application/vnd.github.raw", forHTTPHeaderField: "Accept")
        api.setValue("MacClean", forHTTPHeaderField: "User-Agent")
        let raw = URLRequest(url: versionURL)
        var lastError: Error = URLError(.badServerResponse)
        for var req in [api, raw] {
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 15
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                return try JSONDecoder().decode(RemoteVersion.self, from: data)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
    static var sourceZipURL: URL {
        URL(string: "https://codeload.github.com/\(repo)/zip/refs/heads/\(branch)")!
    }

    /// Release 파일: 받을 때마다 GitHub이 다운로드 횟수를 세줌
    static func releaseZipURL(_ version: String) -> URL {
        URL(string: "https://github.com/\(repo)/releases/download/v\(version)/MacClean.zip")!
    }

    /// Release 파일을 먼저 받고, 그 버전의 Release가 없으면 기존 방식(저장소 최신 코드)으로
    static func downloadSource(version: String?) async throws -> URL {
        var sources: [URL] = []
        if let v = version { sources.append(releaseZipURL(v)) }
        sources.append(sourceZipURL)
        var lastError: Error = URLError(.badServerResponse)
        for url in sources {
            do {
                let (tmp, resp) = try await URLSession.shared.download(from: url)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                return tmp
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Apple 명령어 도구(swiftc)가 설치돼 있는지
    static func hasCommandLineTools() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        let dir = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 && FileManager.default.fileExists(atPath: dir + "/usr/bin/swiftc")
    }

    static func shell(_ exe: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do { try p.run() } catch { cont.resume(throwing: error); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    cont.resume()
                } else {
                    let text = String(data: data, encoding: .utf8) ?? ""
                    let lines = text.split(separator: "\n").map(String.init)
                    // 컴파일 에러면 'error:' 줄을 먼저 보여줌 (원인이 잘려 보이지 않도록)
                    let errors = lines.filter { $0.contains("error:") }
                    let shown = errors.isEmpty ? Array(lines.suffix(6)) : Array(errors.prefix(4))
                    cont.resume(throwing: EngineError.failed("업데이트 중 문제가 생겼어요:\n" + shown.joined(separator: "\n")))
                }
            }
        }
    }

    /// 압축 푼 소스에서 build.sh가 있는 폴더 찾기
    static func findSourceDir(_ root: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent("build.sh").path) { return root }
        let subs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for s in subs where fm.fileExists(atPath: s.appendingPathComponent("build.sh").path) { return s }
        return nil
    }

    /// 앱이 종료되길 기다렸다가: 기존 앱 백업 → 새 앱으로 교체 → 실패하면 백업 복구 → 다시 실행
    static let installScript = """
    #!/bin/bash
    PID="$1"; NEW="$2"; DEST="$3"
    for i in $(seq 1 150); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
    BK="$HOME/Library/Application Support/MacClean/backup"
    mkdir -p "$BK"
    rm -rf "$BK/MacClean.app"
    [ -d "$DEST" ] && ditto "$DEST" "$BK/MacClean.app"
    rm -rf "$DEST"
    if ! ditto "$NEW" "$DEST"; then
      ditto "$BK/MacClean.app" "$DEST"
    fi
    xattr -cr "$DEST" 2>/dev/null
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1
    open "$DEST"
    """
}

// MARK: - 내 맥 (사양·메모리·저장공간)

struct HardwareInfo {
    var name: String?          // MacBook Pro
    var chip: String?          // Apple M3 Pro
    var memoryText: String?    // 18 GB
    var macOS = ""
    var cores = 0
    var perfCores: Int?
    var effCores: Int?
    var bootDate: Date?
    var cycles: Int?
    var condition: String?
    var maxCapacity: String?
}

struct MemInfo {
    var total: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var swapUsed: UInt64 = 0
    var pressure = 1            // 1 정상, 2 주의, 4 높음
    var used: UInt64 { app + wired + compressed }
}

struct DiskInfo {
    var total: Int64 = 0
    var free: Int64 = 0         // 시스템이 확보할 수 있는 공간 포함
    var purgeable: Int64 = 0
}

struct BatteryInfo {
    var percent: Int
    var charging: Bool
    var onAC: Bool
}

struct AppMem: Identifiable {
    let pid: pid_t
    let name: String
    let path: String
    let bytes: UInt64
    var id: pid_t { pid }
}

func fmtMem(_ b: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory)
}

enum SysProbe {
    static let host = mach_host_self()

    static func sysctlInt(_ name: String) -> Int? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : nil
    }

    static func memory() -> MemInfo {
        var m = MemInfo()
        m.total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if r == KERN_SUCCESS {
            let page = UInt64(getpagesize())
            let anonPages = UInt64(stats.internal_page_count)
            let purgeable = UInt64(stats.purgeable_count)
            // 활성 상태 보기(Activity Monitor)와 같은 계산
            m.app = (anonPages > purgeable ? anonPages - purgeable : 0) * page
            m.wired = UInt64(stats.wire_count) * page
            m.compressed = UInt64(stats.compressor_page_count) * page
            m.cached = (UInt64(stats.external_page_count) + purgeable) * page
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { m.swapUsed = swap.xsu_used }
        if let level = sysctlInt("kern.memorystatus_vm_pressure_level") { m.pressure = level }
        return m
    }

    static func cpuTicks() -> [UInt64]? {   // user, system, idle, nice
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        return [UInt64(t.0), UInt64(t.1), UInt64(t.2), UInt64(t.3)]
    }

    static func disk() -> DiskInfo {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return DiskInfo() }
        let total = Int64(v.volumeTotalCapacity ?? 0)
        let avail = Int64(v.volumeAvailableCapacity ?? 0)
        let important = v.volumeAvailableCapacityForImportantUsage ?? avail
        return DiskInfo(total: total, free: max(important, avail), purgeable: max(0, important - avail))
    }

    static func battery() -> BatteryInfo? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            guard (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maxCap = d[kIOPSMaxCapacityKey] as? Int ?? 100
            return BatteryInfo(percent: maxCap > 0 ? cur * 100 / maxCap : cur,
                               charging: d[kIOPSIsChargingKey] as? Bool ?? false,
                               onAC: (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue)
        }
        return nil
    }

    static func bootDate() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
    }

    /// 칩, 모델명, 배터리 수명 등 (system_profiler, 1~2초)
    static func hardware() -> HardwareInfo {
        var h = HardwareInfo()
        let v = ProcessInfo.processInfo.operatingSystemVersion
        h.macOS = "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
        h.cores = ProcessInfo.processInfo.processorCount
        h.perfCores = sysctlInt("hw.perflevel0.physicalcpu")
        h.effCores = sysctlInt("hw.perflevel1.physicalcpu")
        h.bootDate = bootDate()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPHardwareDataType", "SPPowerDataType", "-json"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return h }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return h }

        if let hw = (root["SPHardwareDataType"] as? [[String: Any]])?.first {
            h.name = hw["machine_name"] as? String
            h.chip = (hw["chip_type"] as? String) ?? (hw["cpu_type"] as? String)
            h.memoryText = hw["physical_memory"] as? String
        }
        for d in (root["SPPowerDataType"] as? [[String: Any]]) ?? [] {
            guard let health = d["sppower_battery_health_info"] as? [String: Any] else { continue }
            h.cycles = health["sppower_battery_cycle_count"] as? Int
            if let c = health["sppower_battery_health"] as? String {
                switch c.lowercased() {
                case "good", "normal": h.condition = "정상"
                case "fair": h.condition = "보통"
                default: h.condition = "점검 권장"
                }
            }
            h.maxCapacity = health["sppower_battery_health_maximum_capacity"] as? String
        }
        return h
    }

    /// 내 계정 프로세스들의 (실행 파일 경로, 메모리 KB)
    static func processRows() -> [(path: String, kb: UInt64)] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-x", "-o", "rss=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        var rows: [(path: String, kb: UInt64)] = []
        for line in text.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let kb = UInt64(parts[0]) else { continue }
            rows.append((path: parts[1].trimmingCharacters(in: .whitespaces), kb: kb))
        }
        return rows
    }
}

// MARK: - 상태

@MainActor
final class Model: ObservableObject {
    @Published var pane: Pane = .scan

    init() {
        startMonitoring()
    }

    /// 메뉴 막대용: 창이 닫혀 있어도 3초마다 CPU·메모리·저장 공간 갱신
    private var monitoring = false
    func startMonitoring() {
        guard !monitoring else { return }
        monitoring = true
        // Model은 앱이 켜져 있는 동안 계속 살아 있으므로 그대로 잡아둬도 됨
        Task {
            while !Task.isCancelled {
                await self.refreshLive(includeApps: false)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        // 메뉴 막대에 상주하는 동안 30분마다 새 버전 확인
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
                await self.checkForUpdate(silent: true)
            }
        }
    }

    // 내 맥
    @Published var hw: HardwareInfo?
    @Published var mem = MemInfo()
    @Published var cpu: Double = 0
    @Published var disk = DiskInfo()
    @Published var battery: BatteryInfo?
    @Published var heavyApps: [AppMem] = []
    private var lastTicks: [UInt64]?

    func loadHardware() async {
        if hw != nil { return }
        hw = await Task.detached(priority: .utility) { SysProbe.hardware() }.value
    }

    func refreshLive(includeApps: Bool) async {
        mem = SysProbe.memory()
        disk = SysProbe.disk()
        battery = SysProbe.battery()
        if let t = SysProbe.cpuTicks() {
            if let prev = lastTicks, prev.count == t.count {
                let d = zip(t, prev).map { $0 &- $1 }
                let busy = Double(d[0] + d[1] + d[3])
                let all = busy + Double(d[2])
                if all > 0 { cpu = busy / all }
            }
            lastTicks = t
        }
        if includeApps { await refreshHeavyApps() }
    }

    func refreshHeavyApps() async {
        let rows = await Task.detached(priority: .utility) { SysProbe.processRows() }.value
        let me = Bundle.main.bundleIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != me && $0.bundleIdentifier != "com.apple.finder"
        }
        // 앱 본체 + 도우미 프로세스(크롬 렌더러 등)를 앱 단위로 합산
        let prefixes: [(pid: pid_t, prefix: String)] = apps.compactMap { a in
            guard let u = a.bundleURL else { return nil }
            return (pid: a.processIdentifier, prefix: u.path + "/")
        }
        var totals: [pid_t: UInt64] = [:]
        for r in rows {
            if let hit = prefixes.first(where: { r.path.hasPrefix($0.prefix) }) {
                totals[hit.pid, default: 0] += r.kb * 1024
            }
        }
        let list: [AppMem] = apps.compactMap { a in
            guard let b = totals[a.processIdentifier], b > 0 else { return nil }
            return AppMem(pid: a.processIdentifier, name: a.localizedName ?? "앱", path: a.bundleURL?.path ?? "", bytes: b)
        }
        heavyApps = Array(list.sorted { $0.bytes > $1.bytes }.prefix(8))
    }

    func quitApp(_ app: AppMem) {
        NSRunningApplication(processIdentifier: app.pid)?.terminate()
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await refreshLive(includeApps: true)
        }
    }

    /// macOS의 purge: 파일 캐시를 비움 (관리자 암호 필요, 효과는 일시적)
    func purgeFileCache() async {
        let before = mem.cached
        var err: NSDictionary?
        _ = NSAppleScript(source: "do shell script \"/usr/sbin/purge\" with administrator privileges")?
            .executeAndReturnError(&err)
        if let err {
            if (err[NSAppleScript.errorNumber] as? Int) == -128 { return }   // 사용자가 취소
            error = "파일 캐시를 비우지 못했어요."
            return
        }
        try? await Task.sleep(nanoseconds: 800_000_000)
        await refreshLive(includeApps: false)
        let freed = before > mem.cached ? before - mem.cached : 0
        banner = "파일 캐시 \(fmtMem(freed))를 비웠어요. 맥이 필요할 때 다시 채워요."
    }

    // 업데이트
    @Published var currentVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
    @Published var latestVersion: String?
    @Published var latestNotes: String?
    @Published var updateState: UpdateState = .idle

    func checkForUpdate(silent: Bool = true) async {
        if [.downloading, .building, .restarting].contains(updateState) { return }
        let previous = updateState
        updateState = .checking
        do {
            let info = try await Updater.fetchRemoteVersion()
            latestVersion = info.version
            latestNotes = info.notes
            updateState = Updater.isNewer(info.version, than: currentVersion) ? .available : .upToDate
        } catch {
            if silent {
                // 자동 확인이 실패해도 이미 보이던 업데이트 버튼은 그대로 둠
                updateState = (previous == .available) ? .available : .idle
            } else {
                updateState = .failed("업데이트 정보를 가져오지 못했어요. 인터넷 연결을 확인해주세요.")
            }
        }
    }

    func performUpdate() async {
        guard Updater.hasCommandLineTools() else {
            updateState = .failed("Apple 명령어 도구가 필요해요. 설치 창에서 '설치'를 누르고, 끝나면 다시 시도해주세요.")
            try? await Updater.shell("/usr/bin/xcode-select", ["--install"])
            return
        }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("macclean-update-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)

            updateState = .downloading
            let tmp = try await Updater.downloadSource(version: latestVersion)
            let zip = work.appendingPathComponent("source.zip")
            try fm.moveItem(at: tmp, to: zip)
            let src = work.appendingPathComponent("source")
            try await Updater.shell("/usr/bin/ditto", ["-x", "-k", zip.path, src.path])
            guard let dir = Updater.findSourceDir(src) else {
                throw EngineError.failed("받은 파일에서 build.sh를 찾지 못했어요.")
            }

            updateState = .building
            let out = work.appendingPathComponent("out")
            try await Updater.shell("/bin/bash", [dir.appendingPathComponent("build.sh").path, "--build-only", out.path])
            let newApp = out.appendingPathComponent("MacClean.app")
            guard fm.fileExists(atPath: newApp.path) else { throw EngineError.failed("새 버전 빌드 결과를 찾지 못했어요.") }

            updateState = .restarting
            let script = work.appendingPathComponent("install.sh")
            try Updater.installScript.write(to: script, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), newApp.path, Bundle.main.bundlePath]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            try? await Task.sleep(nanoseconds: 500_000_000)
            NSApp.terminate(nil)
        } catch {
            updateState = .failed(error.localizedDescription)
        }
    }

    // 스마트 스캔
    @Published var items: [CleanItem] = []
    @Published var selected: Set<Int> = []
    @Published var scanning = false
    @Published var scanned = false
    @Published var progress: Double = 0
    @Published var step = ""
    @Published var days = 14

    // 공통
    @Published var working = false
    @Published var banner: String?
    @Published var error: String?

    // 앱 삭제
    @Published var apps: [AppEntry] = []
    @Published var loadingApps = false
    @Published var appInfo: AppInfo?
    @Published var loadingInfo = false

    // 휴지통
    @Published var trashItems: [TrashEntry] = []
    @Published var trashSelected: Set<String> = []
    @Published var trashSize: Int64?
    @Published var loadingTrash = false
    @Published var trashNoAccess = false
    @Published var trashSortKey: TrashSortKey = .date
    @Published var trashSortAsc = false

    // 개인정보
    @Published var privacy: [PrivBrowser] = []
    @Published var privSelected: Set<String> = []    // "Chrome|history"
    @Published var loadingPrivacy = false
    @Published var privLoaded = false

    var privCookiesSelected: Bool { privSelected.contains { $0.hasSuffix("|cookies") } }

    func loadPrivacy() async {
        loadingPrivacy = true
        do {
            privacy = try await Engine.call([PrivBrowser].self, ["--privacy-json"])
            let valid = Set(privacy.flatMap { b in b.items.filter(\.available).map { "\(b.name)|\($0.key)" } })
            privSelected = privSelected.intersection(valid)
            privLoaded = true
        } catch {
            self.error = error.localizedDescription
        }
        loadingPrivacy = false
    }

    func cleanPrivacy() async {
        var reqs: [PrivRequest] = []
        for b in privacy {
            let keys = b.items.map(\.key).filter { privSelected.contains("\(b.name)|\($0)") }
            if !keys.isEmpty { reqs.append(PrivRequest(browser: b.name, items: keys)) }
        }
        guard !reqs.isEmpty else { return }
        working = true
        defer { working = false }
        do {
            let res = try await Engine.call([PrivResult].self, ["--privacy-clean"], input: try JSONEncoder().encode(reqs))
            let done = res.reduce(0) { $0 + $1.done.count }
            var msg = done > 0 ? "\(done)개 항목을 지웠어요 ✨ 비밀번호와 북마크는 그대로예요." : "지운 항목이 없어요."
            let skipped = res.compactMap(\.skipped)
            if !skipped.isEmpty { msg += " " + skipped.joined(separator: " ") }
            if !res.flatMap(\.errors).isEmpty { msg += " 일부는 지우지 못했어요 (권한 문제일 수 있어요)." }
            banner = msg
            privSelected = []
        } catch {
            self.error = error.localizedDescription
        }
        await loadPrivacy()
    }

    var sortedTrash: [TrashEntry] {
        let key = trashSortKey
        func less(_ a: TrashEntry, _ b: TrashEntry) -> Bool {
            switch key {
            case .date: return (a.added ?? .distantPast) < (b.added ?? .distantPast)
            case .size: return (a.size ?? -1) < (b.size ?? -1)
            case .name: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
        let asc = trashSortAsc
        return trashItems.sorted { asc ? less($0, $1) : less($1, $0) }
    }

    /// 같은 열을 다시 누르면 방향 전환. 날짜·크기는 큰 것(최근)부터, 이름은 가나다순부터
    func setTrashSort(_ key: TrashSortKey) {
        if trashSortKey == key {
            trashSortAsc.toggle()
        } else {
            trashSortKey = key
            trashSortAsc = (key == .name)
        }
    }

    var categories: [String] {
        var seen: [String] = []
        for i in items where !seen.contains(i.cat) { seen.append(i.cat) }
        return seen
    }
    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var selectedSize: Int64 { items.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size } }
    /// 그 기간보다 오래전에 삭제한 항목 (삭제 날짜를 모르는 항목은 제외)
    func trashOlder(than age: TrashAge) -> [TrashEntry] {
        let cutoff = age.cutoff
        return trashItems.filter { e in
            guard let d = e.added else { return false }
            return d < cutoff
        }
    }

    func selectTrash(olderThan age: TrashAge) {
        trashSelected = Set(trashOlder(than: age).map(\.id))
    }

    var trashSelectedSize: Int64 {
        trashItems.filter { trashSelected.contains($0.id) }.reduce(0) { $0 + ($1.size ?? 0) }
    }

    // ── 스캔 ──
    func scan() async {
        scanning = true; scanned = false; banner = nil; error = nil
        items = []; selected = []; progress = 0; step = "준비"
        do {
            let r = try await Engine.call(ScanResult.self, ["--json", "--days", String(days)]) { [weak self] i, n, name in
                Task { @MainActor in
                    self?.progress = Double(i) / Double(max(n, 1))
                    self?.step = name
                }
            }
            progress = 1
            try? await Task.sleep(nanoseconds: 350_000_000)
            items = r.items
            selected = Set(r.items.filter(\.isSafe).map(\.id))   // 안전한 것만 미리 체크
            scanned = true
        } catch {
            self.error = error.localizedDescription
        }
        scanning = false
    }

    func cleanSelected() async {
        let chosen = items.filter { selected.contains($0.id) }
        guard !chosen.isEmpty else { return }
        working = true
        defer { working = false }
        do {
            let input = try JSONEncoder().encode(chosen.flatMap(\.paths))
            let r = try await Engine.call(TrashResult.self, ["--trash-paths"], input: input)
            let failed = Set(r.failed)
            let done = chosen.filter { item in item.paths.allSatisfy { p in !failed.contains(p) } }
            let doneIDs = Set(done.map(\.id))
            let doneSize: Int64 = done.reduce(0) { $0 + $1.size }
            items.removeAll { doneIDs.contains($0.id) }
            selected.subtract(doneIDs)
            var msg = "\(fmt(doneSize))를 휴지통으로 옮겼어요. 휴지통을 비우면 용량이 확보돼요."
            if !failed.isEmpty { msg += " \(failed.count)개는 권한 문제로 옮기지 못했어요." }
            banner = msg
            await loadTrash()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // ── 앱 삭제 ──
    func loadApps() async {
        loadingApps = true
        do {
            let me = Bundle.main.bundleIdentifier ?? ""
            apps = try await Engine.call([AppEntry].self, ["--apps-json"]).filter { $0.bundle != me }
        } catch {
            self.error = error.localizedDescription
        }
        loadingApps = false
    }

    func loadInfo(_ app: AppEntry) async {
        loadingInfo = true
        appInfo = nil
        let info = try? await Engine.call(AppInfo.self, ["--app-info", app.path])
        if info?.path == app.path { appInfo = info }
        loadingInfo = false
    }

    func uninstall(_ app: AppEntry) async -> Bool {
        guard let info = appInfo, info.path == app.path else { return false }
        working = true
        defer { working = false }
        do {
            let paths = [info.path] + info.leftovers.map(\.path)
            let r = try await Engine.call(TrashResult.self, ["--trash-paths"], input: try JSONEncoder().encode(paths))
            if r.failed.contains(info.path) {
                error = "\(app.name)을(를) 옮기지 못했어요. 앱이 실행 중이거나 관리자 권한이 필요할 수 있어요."
                return false
            }
            apps.removeAll { $0.path == app.path }
            appInfo = nil
            banner = "\(app.name)과(와) 남은 파일 \(r.moved - 1)개를 휴지통으로 옮겼어요."
            await loadTrash()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    // ── 휴지통 ──
    var trashURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash") }

    func loadTrash() async {
        loadingTrash = true
        let dir = trashURL
        let origins = TrashLog.origins()
        let listed: [TrashEntry]? = await Task.detached(priority: .userInitiated) { () -> [TrashEntry]? in
            let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .contentModificationDateKey]
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: keys, options: []) else { return nil }
            return urls
                .filter { $0.lastPathComponent != ".DS_Store" && $0.lastPathComponent != ".localized" }
                .map { u -> TrashEntry in
                    let v = try? u.resourceValues(forKeys: Set(keys))
                    return TrashEntry(url: u, name: u.lastPathComponent,
                                      added: v?.addedToDirectoryDate ?? v?.contentModificationDate,
                                      size: nil, origin: origins[u.path])
                }
                .sorted { ($0.added ?? .distantPast) > ($1.added ?? .distantPast) }
        }.value

        guard let listed else {
            // 전체 디스크 접근 권한이 없으면 목록을 못 읽음 → 크기만이라도 엔진으로
            trashNoAccess = true
            trashItems = []
            if let r = try? await Engine.call(TrashInfo.self, ["--trash-info"]) { trashSize = r.trash }
            loadingTrash = false
            return
        }
        trashNoAccess = false
        let old = Dictionary(uniqueKeysWithValues: trashItems.map { ($0.id, $0.size) })
        trashItems = listed.map { var e = $0; e.size = old[e.id] ?? nil; return e }
        trashSelected = trashSelected.intersection(Set(listed.map(\.id)))
        loadingTrash = false

        let sizes: [String: Int64] = await Task.detached(priority: .utility) { () -> [String: Int64] in
            var d: [String: Int64] = [:]
            for e in listed { d[e.id] = diskSize(e.url) }
            return d
        }.value
        trashItems = trashItems.map { var e = $0; e.size = sizes[e.id] ?? e.size; return e }
        trashSize = trashItems.reduce(0) { $0 + ($1.size ?? 0) }
        TrashLog.prune()
    }

    func deleteSelectedTrash() async {
        let targets = trashItems.filter { trashSelected.contains($0.id) }
        await deleteForever(targets)
    }

    func emptyTrash() async {
        if trashNoAccess {
            working = true
            _ = try? await Engine.run(["--empty-trash", "--yes"])
            working = false
            banner = "휴지통을 비웠어요 ✨"
            await loadTrash()
        } else {
            await deleteForever(trashItems)
        }
    }

    private func deleteForever(_ targets: [TrashEntry]) async {
        guard !targets.isEmpty else { return }
        working = true
        defer { working = false }
        let urls = targets.map(\.url)
        let failed: Int = await Task.detached(priority: .userInitiated) { () -> Int in
            var n = 0
            for u in urls {
                do { try FileManager.default.removeItem(at: u) } catch { n += 1 }
            }
            return n
        }.value
        TrashLog.prune(removing: targets.map(\.id))
        trashSelected.subtract(targets.map(\.id))
        let freed = targets.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        banner = "\(targets.count - failed)개를 완전히 삭제했어요 · \(fmt(freed)) 확보 ✨"
            + (failed > 0 ? " (\(failed)개는 삭제하지 못했어요)" : "")
        await loadTrash()
    }

    func restore(_ e: TrashEntry) async {
        guard let origin = e.origin else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: origin) {
            error = "원래 위치에 같은 이름이 이미 있어요: \(tilde(origin))"
            return
        }
        do {
            let dest = URL(fileURLWithPath: origin)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: e.url, to: dest)
            TrashLog.prune(removing: [e.id])
            banner = "\(e.name)을(를) 원래 위치로 되돌렸어요."
        } catch {
            self.error = "되돌리지 못했어요: \(error.localizedDescription)"
        }
        await loadTrash()
    }
}

// MARK: - 디자인 요소

enum Pane: Hashable, CaseIterable { case scan, system, privacy, apps, trash }

extension Pane {
    var gradient: [Color] {
        switch self {
        case .scan: return [Color(hex: 0x1E1B4B), Color(hex: 0x5B2A86), Color(hex: 0xA2346F)]
        case .system: return [Color(hex: 0x0C0A2A), Color(hex: 0x312E81), Color(hex: 0x0E7490)]
        case .privacy: return [Color(hex: 0x0B132B), Color(hex: 0x1C2E73), Color(hex: 0x2F5BD3)]
        case .apps: return [Color(hex: 0x082F49), Color(hex: 0x0E5E6F), Color(hex: 0x1C8C7A)]
        case .trash: return [Color(hex: 0x16181F), Color(hex: 0x2E3247), Color(hex: 0x4A4366)]
        }
    }
}

struct Backdrop: View {
    let colors: [Color]
    var body: some View {
        ZStack {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color.white.opacity(0.14), Color.clear],
                           center: UnitPoint(x: 0.78, y: 0.12), startRadius: 0, endRadius: 560)
            RadialGradient(colors: [Color.black.opacity(0.28), Color.clear],
                           center: UnitPoint(x: 0.05, y: 1.0), startRadius: 0, endRadius: 640)
        }
    }
}

struct CatStyle {
    let icon: String
    let colors: [Color]

    static func of(_ cat: String) -> CatStyle {
        switch cat {
        case "AI 앱": return CatStyle(icon: "brain.head.profile", colors: [Color(hex: 0xC084FC), Color(hex: 0x7C3AED)])
        case "인터넷·브라우저 캐시": return CatStyle(icon: "globe", colors: [Color(hex: 0x93C5FD), Color(hex: 0x4F46E5)])
        case "중복 빌드 폴더": return CatStyle(icon: "square.stack.3d.up.fill", colors: [Color(hex: 0xFDBA74), Color(hex: 0xEA580C)])
        case "개발 찌꺼기": return CatStyle(icon: "hammer.fill", colors: [Color(hex: 0xFDE047), Color(hex: 0xCA8A04)])
        case "시스템 정크": return CatStyle(icon: "gearshape.2.fill", colors: [Color(hex: 0x7DD3FC), Color(hex: 0x2563EB)])
        case "다운로드": return CatStyle(icon: "arrow.down.circle.fill", colors: [Color(hex: 0x86EFAC), Color(hex: 0x16A34A)])
        case "삭제한 앱의 남은 파일": return CatStyle(icon: "puzzlepiece.extension.fill", colors: [Color(hex: 0xF9A8D4), Color(hex: 0xDB2777)])
        case "대용량·오래된 파일": return CatStyle(icon: "externaldrive.fill", colors: [Color(hex: 0xFCA5A5), Color(hex: 0xDC2626)])
        case "중복 파일": return CatStyle(icon: "doc.on.doc.fill", colors: [Color(hex: 0x67E8F9), Color(hex: 0x0891B2)])
        default: return CatStyle(icon: "folder.fill", colors: [Color(hex: 0xCBD5E1), Color(hex: 0x64748B)])
        }
    }
}

struct IconTile: View {
    let icon: String
    let colors: [Color]
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(Color.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .shadow(color: (colors.last ?? .black).opacity(0.45), radius: size * 0.18, y: size * 0.06)
    }
}

struct PillButton: ButtonStyle {
    var colors: [Color] = [Color(hex: 0xFF8CC6), Color(hex: 0x8E6BFF)]
    @Environment(\.isEnabled) var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
            .background(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.28), lineWidth: 1))
            .shadow(color: (colors.first ?? .clear).opacity(isEnabled ? 0.45 : 0), radius: 14, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.9 : 1) : 0.4)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct GhostButton: ButtonStyle {
    @Environment(\.isEnabled) var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.white.opacity(configuration.isPressed ? 0.2 : 0.11), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

struct RoundIconButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(hover ? 0.22 : 0.1), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
    }
}

enum CheckState { case off, on, mixed }

struct CheckCircle: View {
    let state: CheckState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(state == .off ? Color.clear : Color(hex: 0x8E6BFF))
                Circle().stroke(Color.white.opacity(state == .off ? 0.55 : 0.0), lineWidth: 1.5)
                if state == .on {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(Color.white)
                } else if state == .mixed {
                    Image(systemName: "minus").font(.system(size: 10, weight: .heavy)).foregroundStyle(Color.white)
                }
            }
            .frame(width: 22, height: 22)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

struct LevelBadge: View {
    let safe: Bool
    var body: some View {
        Text(safe ? "안전" : "확인 필요")
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(safe ? Color(hex: 0x6EE7B7) : Color(hex: 0xFCD34D))
            .background((safe ? Color(hex: 0x10B981) : Color(hex: 0xF59E0B)).opacity(0.18), in: Capsule())
    }
}

struct Card<Content: View>: View {
    var hover = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(hover ? 0.13 : 0.08)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.11), lineWidth: 1))
    }
}

// MARK: - 앱

/// 메뉴 막대에 떠 있는 동안은 창을 닫아도 앱을 끄지 않음 (상주 프로그램)
enum Residency {
    static var menuBarOn: Bool { UserDefaults.standard.object(forKey: "menuBarEnabled") as? Bool ?? true }

    /// 창이 열리면 Dock에 아이콘 표시
    static func showInDock() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

    /// 창을 닫으면 Dock 아이콘을 숨기고 메뉴 막대에만 남음
    static func hideFromDockIfResident() {
        guard menuBarOn else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 메뉴 막대 표시를 꺼둔 상태면 숨은 채로 남지 않도록 종료
        !Residency.menuBarOn
    }
}

@main
struct MacCleanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = Model()
    @AppStorage("menuBarEnabled") private var menuBarEnabled = true

    var body: some Scene {
        // 창은 하나만 (메뉴 막대에서 '열기'를 눌러도 새 창이 늘어나지 않게)
        Window("MacClean", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 960, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)

        // 오른쪽 위 메뉴 막대: CPU · 메모리 · 남은 저장 공간
        MenuBarExtra(isInserted: $menuBarEnabled) {
            MenuBarPanel()
                .environmentObject(model)
        } label: {
            MenuBarLabel()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct ContentView: View {
    @EnvironmentObject var m: Model

    var body: some View {
        ZStack {
            ForEach(Pane.allCases, id: \.self) { p in
                Backdrop(colors: p.gradient).opacity(m.pane == p ? 1 : 0)
            }
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.45), value: m.pane)

            HStack(spacing: 0) {
                Sidebar(pane: $m.pane)
                Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1).ignoresSafeArea()
                VStack(spacing: 0) {
                    BannerView()
                    Group {
                        switch m.pane {
                        case .scan: ScanView()
                        case .system: SystemView { m.pane = .scan }
                        case .privacy: PrivacyView()
                        case .apps: AppsView()
                        case .trash: TrashView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.top, 12)
            }
        }
        .foregroundStyle(Color.white)
        .preferredColorScheme(.dark)
        .onAppear { Residency.showInDock() }
        .onDisappear { Residency.hideFromDockIfResident() }
        .task {
            await m.refreshLive(includeApps: false)
            await m.checkForUpdate()
            await m.loadTrash()
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var m: Model
    @Binding var pane: Pane

    var trashSubtitle: String {
        if let s = m.trashSize { return s == 0 ? "비어 있음" : fmt(s) }
        return "삭제 날짜 · 완전 삭제"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                IconTile(icon: "sparkles", colors: [Color(hex: 0xFF8CC6), Color(hex: 0x8E6BFF)], size: 30)
                Text("MacClean").font(.system(size: 17, weight: .bold, design: .rounded))
            }
            .padding(.horizontal, 10)
            .padding(.top, 46)
            .padding(.bottom, 22)

            SidebarItem(title: "스마트 스캔",
                        subtitle: m.scanned ? "\(fmt(m.totalSize)) 정리 가능" : "맥 점검",
                        icon: "sparkles",
                        colors: [Color(hex: 0xF0ABFC), Color(hex: 0xA855F7)],
                        selected: pane == .scan) { pane = .scan }
            SidebarItem(title: "내 맥",
                        subtitle: m.mem.total > 0
                            ? "메모리 \(Int(Double(m.mem.used) / Double(m.mem.total) * 100))% · 남은 공간 \(fmt(m.disk.free))"
                            : "사양 · 메모리 · 저장 공간",
                        icon: "laptopcomputer",
                        colors: [Color(hex: 0x67E8F9), Color(hex: 0x6366F1)],
                        selected: pane == .system) { pane = .system }
            SidebarItem(title: "개인정보",
                        subtitle: m.privSelected.isEmpty ? "방문 기록 · 쿠키" : "\(m.privSelected.count)개 선택",
                        icon: "hand.raised.fill",
                        colors: [Color(hex: 0x93C5FD), Color(hex: 0x2563EB)],
                        selected: pane == .privacy) { pane = .privacy }
            SidebarItem(title: "앱 완전 삭제",
                        subtitle: m.apps.isEmpty ? "앱과 흔적까지" : "앱 \(m.apps.count)개",
                        icon: "xmark.app.fill",
                        colors: [Color(hex: 0x5EEAD4), Color(hex: 0x0D9488)],
                        selected: pane == .apps) { pane = .apps }
            SidebarItem(title: "휴지통",
                        subtitle: trashSubtitle,
                        icon: "trash.fill",
                        colors: [Color(hex: 0xC4B5FD), Color(hex: 0x6366F1)],
                        selected: pane == .trash) { pane = .trash }

            Spacer()

            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill").foregroundStyle(Color(hex: 0x6EE7B7))
                VStack(alignment: .leading, spacing: 1) {
                    Text("AI 대화 보호 중").font(.system(size: 11, weight: .semibold))
                    Text("이력·기억은 건드리지 않아요").font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.55))
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            UpdateFooter()
                .padding(.top, 4)
                .padding(.bottom, 14)
        }
        .padding(.horizontal, 12)
        .frame(width: 232)
        .background(Color.black.opacity(0.24).ignoresSafeArea())
    }
}

struct UpdateFooter: View {
    @EnvironmentObject var m: Model
    @State private var confirm = false

    var busyText: String? {
        switch m.updateState {
        case .downloading: return "새 버전 받는 중…"
        case .building: return "새 버전 만드는 중… (1~2분)"
        case .restarting: return "다시 시작하는 중…"
        default: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if m.updateState == .available {
                Button {
                    confirm = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("v\(m.latestVersion ?? "") 업데이트")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButton(colors: [Color(hex: 0x34D399), Color(hex: 0x059669)]))
            } else if let busy = busyText {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.system(size: 11, weight: .medium))
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(hex: 0x10B981).opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if case .failed(let msg) = m.updateState {
                VStack(alignment: .leading, spacing: 4) {
                    Text(msg).font(.system(size: 10)).foregroundStyle(Color(hex: 0xFCA5A5)).lineLimit(6).textSelection(.enabled)
                    Button("다시 확인") { Task { await m.checkForUpdate(silent: false) } }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                }
            }

            HStack(spacing: 6) {
                Text("v\(m.currentVersion)").font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.5))
                if m.updateState == .upToDate {
                    Text("최신 버전").font(.system(size: 10)).foregroundStyle(Color(hex: 0x6EE7B7).opacity(0.8))
                }
                Spacer()
                Button {
                    Task { await m.checkForUpdate(silent: false) }
                } label: {
                    if m.updateState == .checking {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.55))
                    }
                }
                .buttonStyle(.plain)
                .help("업데이트 확인")
                .disabled(busyText != nil)
            }
            .padding(.horizontal, 4)
        }
        .alert("v\(m.latestVersion ?? "")로 업데이트할까요?", isPresented: $confirm) {
            Button("업데이트") { Task { await m.performUpdate() } }
            Button("나중에", role: .cancel) {}
        } message: {
            Text((m.latestNotes.map { $0 + "\n\n" } ?? "") + "새 버전을 받아 이 맥에서 만든 뒤 자동으로 다시 시작해요. 1~2분 걸려요.")
        }
    }
}

struct SidebarItem: View {
    let title: String
    let subtitle: String
    let icon: String
    let colors: [Color]
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                IconTile(icon: icon, colors: colors, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.6)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.16 : (hover ? 0.07 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

struct BannerView: View {
    @EnvironmentObject var m: Model

    var body: some View {
        if let e = m.error {
            bar(text: e, icon: "exclamationmark.triangle.fill", color: Color(hex: 0xF87171)) { m.error = nil }
        } else if let b = m.banner {
            bar(text: b, icon: "checkmark.circle.fill", color: Color(hex: 0x34D399)) { m.banner = nil }
        }
    }

    func bar(text: String, icon: String, color: Color, close: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.system(size: 13)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.white.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(color.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(color.opacity(0.35), lineWidth: 1))
        .padding(.horizontal, 28)
        .padding(.bottom, 6)
    }
}

// MARK: - 스마트 스캔

struct ScanView: View {
    @EnvironmentObject var m: Model
    @State private var focus: String?
    @State private var confirm = false

    var body: some View {
        Group {
            if m.scanned && !m.items.isEmpty && !m.scanning {
                results
            } else {
                hero
            }
        }
        .alert("선택한 \(m.selected.count)개 항목을 휴지통으로 옮길까요?", isPresented: $confirm) {
            Button("휴지통으로 이동", role: .destructive) { Task { await m.cleanSelected() } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("총 \(fmt(m.selectedSize)) · 휴지통에서 언제든 되돌릴 수 있어요.")
        }
    }

    // 스캔 전 / 스캔 중 / 정리할 게 없을 때
    var hero: some View {
        VStack(spacing: 28) {
            Spacer()
            VStack(spacing: 10) {
                Text(m.scanning ? "살펴보는 중…" : (m.scanned ? "아주 깔끔해요!" : "맥을 깨끗하게"))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                Text(m.scanning ? m.step
                     : (m.scanned ? "지금은 정리할 항목이 없어요."
                        : "브라우저·앱 캐시 · 중복 빌드 · 개발 찌꺼기 · 남은 앱 파일 · 중복 파일까지 한 번에 찾아요."))
                    .font(.system(size: 14))
                    .foregroundStyle(Color.white.opacity(0.7))
            }
            ScanOrb(scanning: m.scanning, progress: m.progress, done: m.scanned) {
                Task { await m.scan() }
            }
            if !m.scanning {
                HStack(spacing: 10) {
                    Text("오래된 기준").font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.65))
                    Picker("", selection: $m.days) {
                        Text("7일").tag(7)
                        Text("14일").tag(14)
                        Text("30일").tag(30)
                        Text("60일").tag(60)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 230)
                }
            }
            Spacer()
            Text("스캔만으로는 아무것도 지우지 않아요")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.45))
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity)
    }

    var results: some View {
        VStack(spacing: 0) {
            if let cat = focus {
                CategoryDetail(cat: cat) { withAnimation(.easeInOut(duration: 0.2)) { focus = nil } }
            } else {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("스캔 완료").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.white.opacity(0.65))
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(fmt(m.totalSize)).font(.system(size: 42, weight: .bold, design: .rounded)).monospacedDigit()
                            Text("정리 가능").font(.system(size: 17, weight: .medium)).foregroundStyle(Color.white.opacity(0.75))
                        }
                    }
                    Spacer()
                    Button {
                        focus = nil
                        Task { await m.scan() }
                    } label: {
                        Label("다시 스캔", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(GhostButton())
                }
                .padding(.horizontal, 28)
                .padding(.top, 18)
                .padding(.bottom, 18)

                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 215), spacing: 14)], spacing: 14) {
                        ForEach(m.categories, id: \.self) { cat in
                            CategoryCard(cat: cat) { withAnimation(.easeInOut(duration: 0.2)) { focus = cat } }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 20)
                }
            }
            actionBar
        }
    }

    var actionBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("선택 \(m.selected.count)개 · \(fmt(m.selectedSize))").font(.system(size: 14, weight: .semibold)).monospacedDigit()
                Text("안전한 항목은 미리 선택돼 있어요").font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.55))
            }
            Spacer()
            Button("안전한 것만") { m.selected = Set(m.items.filter(\.isSafe).map(\.id)) }
                .buttonStyle(GhostButton())
            Button("모두 해제") { m.selected = [] }
                .buttonStyle(GhostButton())
            Button {
                confirm = true
            } label: {
                Label("정리하기", systemImage: "sparkles")
            }
            .buttonStyle(PillButton())
            .disabled(m.selected.isEmpty || m.working)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .background(Color.black.opacity(0.2))
    }
}

struct ScanOrb: View {
    let scanning: Bool
    let progress: Double
    let done: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color(hex: 0xFF8CC6).opacity(scanning ? 0.5 : 0.35), Color.clear],
                                     center: .center, startRadius: 40, endRadius: 170))
                .frame(width: 320, height: 320)
                .animation(.easeInOut(duration: 0.6), value: scanning)

            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 8)
                .frame(width: 214, height: 214)

            if scanning {
                Circle()
                    .trim(from: 0, to: max(0.03, progress))
                    .stroke(AngularGradient(colors: [Color(hex: 0xFFB3DA), Color(hex: 0x9D7BFF), Color(hex: 0xFFB3DA)],
                                            center: .center),
                            style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 214, height: 214)
                    .animation(.easeInOut(duration: 0.4), value: progress)
            }

            Button(action: action) {
                ZStack {
                    Circle().fill(LinearGradient(colors: [Color(hex: 0xFF8CC6), Color(hex: 0x8E6BFF)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                    Circle().fill(LinearGradient(colors: [Color.white.opacity(0.35), Color.clear],
                                                 startPoint: .top, endPoint: .center))
                        .padding(4)
                    Circle().stroke(Color.white.opacity(0.4), lineWidth: 1.5)
                    VStack(spacing: 4) {
                        if scanning {
                            Text(verbatim: "\(Int(progress * 100))%")
                                .font(.system(size: 36, weight: .bold, design: .rounded))
                                .monospacedDigit()
                        } else {
                            Image(systemName: done ? "arrow.clockwise" : "sparkles")
                                .font(.system(size: 34, weight: .semibold))
                            Text(done ? "다시 스캔" : "스캔")
                                .font(.system(size: 19, weight: .bold, design: .rounded))
                        }
                    }
                    .foregroundStyle(Color.white)
                }
                .frame(width: 176, height: 176)
                .shadow(color: Color(hex: 0xFF6FB5).opacity(hover ? 0.75 : 0.45), radius: hover ? 34 : 22)
                .scaleEffect(hover && !scanning ? 1.04 : 1)
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: hover)
            }
            .buttonStyle(.plain)
            .disabled(scanning)
            .onHover { hover = $0 }
        }
    }
}

struct CategoryCard: View {
    @EnvironmentObject var m: Model
    let cat: String
    let open: () -> Void
    @State private var hover = false

    var rows: [CleanItem] { m.items.filter { $0.cat == cat } }
    var selCount: Int { rows.filter { m.selected.contains($0.id) }.count }

    var body: some View {
        let st = CatStyle.of(cat)
        let rows = self.rows
        let size: Int64 = rows.reduce(0) { $0 + $1.size }
        let state: CheckState = selCount == 0 ? .off : (selCount == rows.count ? .on : .mixed)

        Card(hover: hover) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    IconTile(icon: st.icon, colors: st.colors, size: 46)
                    Spacer()
                    CheckCircle(state: state) {
                        let ids = Set(rows.map(\.id))
                        if state == .on { m.selected.subtract(ids) } else { m.selected.formUnion(ids) }
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(cat).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.white.opacity(0.85)).lineLimit(1)
                    Text(fmt(size)).font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("\(rows.count)개 항목 · \(selCount)개 선택").font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.55))
                }
                HStack(spacing: 4) {
                    Text("자세히 보기").font(.system(size: 11, weight: .semibold))
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(Color.white.opacity(hover ? 0.95 : 0.55))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture(perform: open)
        .onHover { hover = $0 }
        .scaleEffect(hover ? 1.015 : 1)
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

struct CategoryDetail: View {
    @EnvironmentObject var m: Model
    let cat: String
    let back: () -> Void

    var body: some View {
        let st = CatStyle.of(cat)
        let rows = m.items.filter { $0.cat == cat }
        let total: Int64 = rows.reduce(0) { $0 + $1.size }

        VStack(spacing: 0) {
            HStack(spacing: 14) {
                RoundIconButton(icon: "chevron.left", help: "뒤로", action: back)
                IconTile(icon: st.icon, colors: st.colors, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(cat).font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("\(rows.count)개 항목 · \(fmt(total))").font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.6))
                }
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, 16)
            .padding(.bottom, 16)

            if rows.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 44)).foregroundStyle(Color(hex: 0x6EE7B7))
                    Text("이 카테고리는 모두 정리했어요").foregroundStyle(Color.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(rows) { ItemRow(item: $0) }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 18)
                }
            }
        }
    }
}

struct ItemRow: View {
    @EnvironmentObject var m: Model
    let item: CleanItem
    @State private var hover = false

    var isOn: Bool { m.selected.contains(item.id) }

    func toggle() {
        if isOn { m.selected.remove(item.id) } else { m.selected.insert(item.id) }
    }

    var pathSummary: String {
        guard let first = item.paths.first else { return "" }
        let extra = item.paths.count - 1
        return tilde(first) + (extra > 0 ? "  외 \(extra)개" : "")
    }

    var body: some View {
        HStack(spacing: 12) {
            CheckCircle(state: isOn ? .on : .off, action: toggle)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(item.label).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    LevelBadge(safe: item.isSafe)
                }
                if !item.note.isEmpty {
                    Text(item.note).font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.62)).lineLimit(2)
                }
                Text(pathSummary).font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.4))
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(fmt(item.size)).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
            RoundIconButton(icon: "magnifyingglass", help: "Finder에서 보기") { revealInFinder(item.paths) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(hover ? 0.12 : 0.07)))
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { hover = $0 }
    }
}

// MARK: - 내 맥

struct RingGauge: View {
    let value: Double
    let colors: [Color]
    let label: String
    let sub: String

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.1), lineWidth: 11)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(value, 0.001), 1)))
                .stroke(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                        style: StrokeStyle(lineWidth: 11, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: value)
            VStack(spacing: 0) {
                Text(label).font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                Text(sub).font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.55))
            }
        }
        .frame(width: 108, height: 108)
    }
}

struct StatLine: View {
    let title: String
    let value: String
    var accent: Color? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.6))
            Spacer(minLength: 6)
            Text(value).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(accent ?? Color.white)
        }
    }
}

struct MemoryPart: Identifiable {
    let name: String
    let bytes: UInt64
    let color: Color
    var id: String { name }
}

struct StackBar: View {
    let parts: [MemoryPart]
    let total: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { g in
                HStack(spacing: 0) {
                    ForEach(parts) { p in
                        Rectangle()
                            .fill(p.color)
                            .frame(width: g.size.width * CGFloat(Double(p.bytes) / Double(max(total, 1))))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 10)
            .background(Color.white.opacity(0.08))
            .clipShape(Capsule())
            .animation(.easeInOut(duration: 0.6), value: parts.map(\.bytes))

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 6) {
                ForEach(parts) { p in
                    HStack(spacing: 6) {
                        Circle().fill(p.color).frame(width: 8, height: 8)
                        Text(p.name).font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.65))
                        Spacer(minLength: 4)
                        Text(fmtMem(p.bytes)).font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                    }
                }
            }
        }
    }
}

struct SystemView: View {
    @EnvironmentObject var m: Model
    let goScan: () -> Void
    @State private var confirmPurge = false
    @AppStorage("menuBarEnabled") private var menuBarEnabled = true

    var uptime: String {
        guard let boot = m.hw?.bootDate else { return "" }
        let f = DateComponentsFormatter()
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "ko_KR")
        f.calendar = cal
        f.allowedUnits = [.day, .hour, .minute]
        f.unitsStyle = .full
        f.maximumUnitCount = 2
        return f.string(from: boot, to: Date()) ?? ""
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                // 같은 줄의 두 카드는 높이를 똑같이 (더 큰 쪽에 맞춤)
                HStack(alignment: .top, spacing: 14) {
                    storageCard
                    memoryCard
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 14) {
                    cpuCard
                    if m.battery != nil {
                        batteryCard
                    } else {
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                appsCard
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .task { await m.loadHardware() }
        .task {
            var n = 0
            while !Task.isCancelled {
                await m.refreshLive(includeApps: n % 3 == 0)
                n += 1
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .alert("파일 캐시를 비울까요?", isPresented: $confirmPurge) {
            Button("비우기") { Task { await m.purgeFileCache() } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("관리자 암호를 물어봐요.\n맥은 남는 메모리를 파일 캐시로 써서 앱을 빨리 열어요. 비우면 메모리 숫자가 잠깐 줄지만 금방 다시 채워지고, 직후엔 앱이 조금 느리게 열릴 수 있어요.")
        }
    }

    var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSImage(named: NSImage.computerName) ?? NSImage())
                .resizable()
                .frame(width: 64, height: 64)
                .shadow(color: Color.black.opacity(0.3), radius: 10, y: 5)
            VStack(alignment: .leading, spacing: 4) {
                Text(m.hw?.name ?? "내 Mac").font(.system(size: 30, weight: .bold, design: .rounded))
                Text([m.hw?.chip, m.hw?.memoryText.map { "메모리 \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.8))
                Text([m.hw?.macOS ?? "", uptime.isEmpty ? "" : "켜진 지 \(uptime)"].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Toggle("메뉴 막대에 표시", isOn: $menuBarEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 12, weight: .medium))
                Text("오른쪽 위에 CPU·메모리·저장 공간")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
        }
    }

    func title(_ t: String, _ icon: String, _ colors: [Color]) -> some View {
        HStack(spacing: 8) {
            IconTile(icon: icon, colors: colors, size: 26)
            Text(t).font(.system(size: 14, weight: .semibold))
        }
    }

    func percent(_ part: Double, _ whole: Double) -> Int {
        whole > 0 ? Int((part / whole * 100).rounded()) : 0
    }

    var storageCard: some View {
        let used = max(0, m.disk.total - m.disk.free)
        let frac = m.disk.total > 0 ? Double(used) / Double(m.disk.total) : 0
        return Card {
            VStack(alignment: .leading, spacing: 14) {
                title("저장 공간", "internaldrive.fill", [Color(hex: 0x7DD3FC), Color(hex: 0x2563EB)])
                HStack(spacing: 18) {
                    RingGauge(value: frac,
                              colors: frac > 0.9 ? [Color(hex: 0xFCA5A5), Color(hex: 0xDC2626)] : [Color(hex: 0x7DD3FC), Color(hex: 0x6366F1)],
                              label: "\(percent(Double(used), Double(m.disk.total)))%", sub: "사용 중")
                    VStack(alignment: .leading, spacing: 7) {
                        StatLine(title: "전체", value: fmt(m.disk.total))
                        StatLine(title: "사용", value: fmt(used))
                        StatLine(title: "남은 공간", value: fmt(m.disk.free), accent: Color(hex: 0x6EE7B7))
                        if m.disk.purgeable > 0 {
                            StatLine(title: "macOS가 확보 가능", value: fmt(m.disk.purgeable))
                        }
                    }
                }
                Spacer(minLength: 0)   // 버튼은 카드 아래쪽에
                Button(action: goScan) {
                    Label("스마트 스캔으로 공간 확보", systemImage: "sparkles")
                }
                .buttonStyle(GhostButton())
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    var pressureBadge: some View {
        let (text, color): (String, Color) = {
            switch m.mem.pressure {
            case 4: return ("메모리 부족", Color(hex: 0xF87171))
            case 2: return ("조금 빠듯해요", Color(hex: 0xFCD34D))
            default: return ("여유 있어요", Color(hex: 0x6EE7B7))
            }
        }()
        return Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
    }

    var memoryCard: some View {
        let frac = m.mem.total > 0 ? Double(m.mem.used) / Double(m.mem.total) : 0
        return Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    title("메모리 (램)", "memorychip.fill", [Color(hex: 0xF0ABFC), Color(hex: 0xA855F7)])
                    Spacer()
                    pressureBadge
                }
                HStack(spacing: 18) {
                    RingGauge(value: frac, colors: [Color(hex: 0xF0ABFC), Color(hex: 0x8B5CF6)],
                              label: "\(percent(Double(m.mem.used), Double(m.mem.total)))%", sub: "사용 중")
                    VStack(alignment: .leading, spacing: 7) {
                        StatLine(title: "전체", value: fmtMem(m.mem.total))
                        StatLine(title: "사용", value: fmtMem(m.mem.used))
                        StatLine(title: "스왑 (디스크 사용)", value: fmtMem(m.mem.swapUsed),
                                 accent: m.mem.swapUsed > 2 << 30 ? Color(hex: 0xFCD34D) : nil)
                    }
                }
                StackBar(parts: [
                    MemoryPart(name: "앱 메모리", bytes: m.mem.app, color: Color(hex: 0xC084FC)),
                    MemoryPart(name: "고정 메모리", bytes: m.mem.wired, color: Color(hex: 0xF472B6)),
                    MemoryPart(name: "압축됨", bytes: m.mem.compressed, color: Color(hex: 0xFBBF24)),
                    MemoryPart(name: "캐시된 파일", bytes: m.mem.cached, color: Color(hex: 0x94A3B8)),
                ], total: m.mem.total)
                Text("캐시된 파일은 다른 앱이 필요하면 바로 비워져요. 상태가 '여유 있어요'면 정리할 필요 없어요.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    var cpuCard: some View {
        let coresText: String = {
            guard let hw = m.hw else { return "" }
            if let p = hw.perfCores, let e = hw.effCores { return "\(hw.cores)코어 (성능 \(p) · 효율 \(e))" }
            return "\(hw.cores)코어"
        }()
        return Card {
            VStack(alignment: .leading, spacing: 14) {
                title("프로세서 (CPU)", "cpu.fill", [Color(hex: 0x86EFAC), Color(hex: 0x059669)])
                HStack(spacing: 18) {
                    RingGauge(value: m.cpu, colors: [Color(hex: 0x86EFAC), Color(hex: 0x14B8A6)],
                              label: "\(Int((m.cpu * 100).rounded()))%", sub: "사용 중")
                    VStack(alignment: .leading, spacing: 7) {
                        StatLine(title: "칩", value: m.hw?.chip ?? "—")
                        StatLine(title: "코어", value: coresText.isEmpty ? "—" : coresText)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    var batteryCard: some View {
        let b = m.battery ?? BatteryInfo(percent: 0, charging: false, onAC: false)
        let state = b.charging ? "충전 중" : (b.onAC ? "전원 연결됨" : "배터리 사용 중")
        return Card {
            VStack(alignment: .leading, spacing: 14) {
                title("배터리", b.charging ? "battery.100.bolt" : "battery.75", [Color(hex: 0xFDE047), Color(hex: 0xF59E0B)])
                HStack(spacing: 18) {
                    RingGauge(value: Double(b.percent) / 100,
                              colors: b.percent <= 20 ? [Color(hex: 0xFCA5A5), Color(hex: 0xDC2626)] : [Color(hex: 0xFDE047), Color(hex: 0x84CC16)],
                              label: "\(b.percent)%", sub: state)
                    VStack(alignment: .leading, spacing: 7) {
                        StatLine(title: "배터리 상태", value: m.hw?.condition ?? "—",
                                 accent: m.hw?.condition == "점검 권장" ? Color(hex: 0xFCD34D) : nil)
                        StatLine(title: "최대 용량", value: m.hw?.maxCapacity ?? "—")
                        StatLine(title: "충전 횟수", value: m.hw?.cycles.map { "\($0)회" } ?? "—")
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    var appsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    title("메모리를 많이 쓰는 앱", "square.stack.3d.down.right.fill", [Color(hex: 0xFDA4AF), Color(hex: 0xE11D48)])
                    Spacer()
                    Button {
                        confirmPurge = true
                    } label: {
                        Label("파일 캐시 비우기", systemImage: "wind")
                    }
                    .buttonStyle(GhostButton())
                    .disabled(m.working)
                }
                Text("안 쓰는 앱을 종료하는 게 램을 확보하는 가장 확실한 방법이에요. 종료하기 전에 저장할 내용이 있는지 확인해주세요.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                if m.heavyApps.isEmpty {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("앱 메모리 확인 중…").font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.6))
                    }
                    .padding(.vertical, 8)
                } else {
                    VStack(spacing: 6) {
                        ForEach(m.heavyApps) { app in
                            HeavyAppRow(app: app, total: m.mem.total)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct HeavyAppRow: View {
    @EnvironmentObject var m: Model
    let app: AppMem
    let total: UInt64
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                GeometryReader { g in
                    Capsule()
                        .fill(LinearGradient(colors: [Color(hex: 0xFDA4AF), Color(hex: 0xE11D48)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, g.size.width * CGFloat(Double(app.bytes) / Double(max(total, 1)))))
                }
                .frame(height: 4)
            }
            Text(fmtMem(app.bytes))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 80, alignment: .trailing)
            Button("종료") { m.quitApp(app) }
                .buttonStyle(GhostButton())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(hover ? 0.1 : 0.05)))
        .onHover { hover = $0 }
    }
}

// MARK: - 메뉴 막대

enum LoginItem {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// 메뉴 막대용 짧은 용량 표기: 561GB, 48.2GB, 1.2TB (Finder와 같은 1000 단위)
func compactBytes(_ b: Int64) -> String {
    let gb = Double(b) / 1_000_000_000
    if gb >= 999.5 { return String(format: "%.1fTB", gb / 1000) }
    if gb >= 99.95 { return String(format: "%.0fGB", gb) }
    if gb >= 0.995 { return String(format: "%.1fGB", gb) }
    return String(format: "%.0fMB", Double(b) / 1_000_000)
}

struct MenuBarMetric: Identifiable {
    let icon: String
    let value: String
    let colors: [Color]
    var id: String { icon }
}

struct MenuBarLabel: View {
    @EnvironmentObject var m: Model
    @Environment(\.colorScheme) private var scheme
    @AppStorage("mbShowCPU") private var showCPU = true
    @AppStorage("mbShowRAM") private var showRAM = true
    @AppStorage("mbShowDisk") private var showDisk = true

    // 패널과 같은 아이콘·색
    var metrics: [MenuBarMetric] {
        var list: [MenuBarMetric] = []
        if showCPU {
            list.append(MenuBarMetric(icon: "cpu.fill", value: "\(Int((m.cpu * 100).rounded()))%",
                                      colors: [Color(hex: 0x86EFAC), Color(hex: 0x14B8A6)]))
        }
        if showRAM, m.mem.total > 0 {
            list.append(MenuBarMetric(icon: "memorychip.fill",
                                      value: "\(Int(Double(m.mem.used) / Double(m.mem.total) * 100))%",
                                      colors: [Color(hex: 0xF0ABFC), Color(hex: 0xA855F7)]))
        }
        if showDisk, m.disk.total > 0 {
            let full = Double(m.disk.total - m.disk.free) / Double(m.disk.total) > 0.9
            list.append(MenuBarMetric(icon: "internaldrive.fill", value: compactBytes(m.disk.free),
                                      colors: full ? [Color(hex: 0xFCA5A5), Color(hex: 0xDC2626)]
                                                   : [Color(hex: 0x7DD3FC), Color(hex: 0x6366F1)]))
        }
        return list
    }

    /// 메뉴 막대는 글자 사이의 아이콘을 지워버려서, 컬러 아이콘+숫자를 한 장의 그림으로 만들어 표시.
    /// 글자색은 메뉴 막대가 어두우면 흰색, 밝으면 검은색.
    func rendered(_ items: [MenuBarMetric], dark: Bool) -> NSImage? {
        let content = HStack(spacing: 10) {
            ForEach(items) { it in
                HStack(spacing: 4) {
                    Image(systemName: it.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LinearGradient(colors: it.colors, startPoint: .top, endPoint: .bottom))
                    Text(it.value)
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(dark ? Color.white : Color.black.opacity(0.85))
                }
            }
        }
        .padding(.horizontal, 1)
        .frame(height: 18)

        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let img = renderer.nsImage else { return nil }
        img.isTemplate = false   // 색을 그대로 유지
        return img
    }

    var body: some View {
        let items = metrics
        if items.isEmpty {
            Image(systemName: "sparkles")
        } else if let img = rendered(items, dark: scheme == .dark) {
            Image(nsImage: img)
        } else {
            Text(items.map(\.value).joined(separator: "  "))
        }
    }
}

struct MeterRow: View {
    let icon: String
    let title: String
    let detail: String
    let value: Double
    let colors: [Color]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(colors.last ?? Color.white)
                    .frame(width: 16)
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(detail).font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.8))
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule()
                        .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, g.size.width * CGFloat(min(max(value, 0), 1))))
                }
            }
            .frame(height: 6)
            .animation(.easeInOut(duration: 0.5), value: value)
        }
    }
}

struct MenuBarPanel: View {
    @EnvironmentObject var m: Model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("menuBarEnabled") private var menuBarEnabled = true
    @AppStorage("mbShowCPU") private var showCPU = true
    @AppStorage("mbShowRAM") private var showRAM = true
    @AppStorage("mbShowDisk") private var showDisk = true
    @State private var showSettings = false
    @State private var loginOn = LoginItem.isOn
    @State private var loginNeedsApproval = LoginItem.needsApproval

    var loginBinding: Binding<Bool> {
        Binding(
            get: { loginOn },
            set: { on in
                do { try LoginItem.set(on) } catch {
                    m.error = "로그인 시 자동 실행을 바꾸지 못했어요: \(error.localizedDescription)"
                }
                loginOn = LoginItem.isOn
                loginNeedsApproval = LoginItem.needsApproval
            }
        )
    }

    func show(_ pane: Pane) {
        m.pane = pane
        Residency.showInDock()
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    var pressure: (String, Color) {
        switch m.mem.pressure {
        case 4: return ("메모리 부족", Color(hex: 0xF87171))
        case 2: return ("조금 빠듯해요", Color(hex: 0xFCD34D))
        default: return ("여유 있어요", Color(hex: 0x6EE7B7))
        }
    }

    var body: some View {
        let memFrac = m.mem.total > 0 ? Double(m.mem.used) / Double(m.mem.total) : 0
        let diskUsed = max(0, m.disk.total - m.disk.free)
        let diskFrac = m.disk.total > 0 ? Double(diskUsed) / Double(m.disk.total) : 0

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                IconTile(icon: "sparkles", colors: [Color(hex: 0xFF8CC6), Color(hex: 0x8E6BFF)], size: 26)
                Text("MacClean").font(.system(size: 15, weight: .bold, design: .rounded))
                Spacer()
                Text(pressure.0)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(pressure.1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(pressure.1.opacity(0.18), in: Capsule())
            }

            MeterRow(icon: "cpu.fill", title: "CPU",
                     detail: "\(Int((m.cpu * 100).rounded()))%",
                     value: m.cpu, colors: [Color(hex: 0x86EFAC), Color(hex: 0x14B8A6)])
            MeterRow(icon: "memorychip.fill", title: "메모리",
                     detail: "\(fmtMem(m.mem.used)) / \(fmtMem(m.mem.total))",
                     value: memFrac, colors: [Color(hex: 0xF0ABFC), Color(hex: 0x8B5CF6)])
            MeterRow(icon: "internaldrive.fill", title: "저장 공간",
                     detail: "\(fmt(m.disk.free)) 남음",
                     value: diskFrac,
                     colors: diskFrac > 0.9 ? [Color(hex: 0xFCA5A5), Color(hex: 0xDC2626)] : [Color(hex: 0x7DD3FC), Color(hex: 0x6366F1)])
            if let b = m.battery {
                MeterRow(icon: b.charging ? "battery.100.bolt" : "battery.75", title: "배터리",
                         detail: "\(b.percent)%" + (b.charging ? " · 충전 중" : ""),
                         value: Double(b.percent) / 100,
                         colors: b.percent <= 20 ? [Color(hex: 0xFCA5A5), Color(hex: 0xDC2626)] : [Color(hex: 0xFDE047), Color(hex: 0x84CC16)])
            }

            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)

            HStack(spacing: 8) {
                Button { show(.scan) } label: {
                    Label("스마트 스캔", systemImage: "sparkles").frame(maxWidth: .infinity)
                }
                .buttonStyle(PillButton())
                Button { show(.system) } label: {
                    Label("자세히", systemImage: "laptopcomputer")
                }
                .buttonStyle(GhostButton())
            }

            DisclosureGroup(isExpanded: $showSettings) {
                VStack(alignment: .leading, spacing: 7) {
                    Toggle("메뉴 막대에 CPU 표시", isOn: $showCPU)
                    Toggle("메뉴 막대에 메모리 표시", isOn: $showRAM)
                    Toggle("메뉴 막대에 남은 저장 공간 표시", isOn: $showDisk)
                    Toggle("로그인할 때 자동 실행", isOn: loginBinding)
                    if loginNeedsApproval {
                        Text("시스템 설정 → 일반 → 로그인 항목에서 MacClean을 허용해주세요.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color(hex: 0xFCD34D))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .padding(.top, 6)
            } label: {
                Text("설정").font(.system(size: 12, weight: .semibold))
            }

            HStack {
                Button("메뉴 막대에서 숨기기") {
                    // 창이 닫혀 있으면 앱이 안 보이게 되므로 창을 열어둠
                    show(.system)
                    menuBarEnabled = false
                }
                Spacer()
                Button("MacClean 종료") { NSApp.terminate(nil) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(Color.white.opacity(0.55))
        }
        .padding(16)
        .frame(width: 310)
        .background(LinearGradient(colors: Pane.system.gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
        .foregroundStyle(Color.white)
        .preferredColorScheme(.dark)
        .onAppear {
            loginOn = LoginItem.isOn
            loginNeedsApproval = LoginItem.needsApproval
        }
    }
}

// MARK: - 개인정보

struct PrivacyView: View {
    @EnvironmentObject var m: Model
    @State private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("개인정보").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.white.opacity(0.65))
                    Text("브라우저 흔적 지우기").font(.system(size: 32, weight: .bold, design: .rounded))
                    Label("비밀번호와 북마크는 절대 건드리지 않아요", systemImage: "key.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: 0x6EE7B7))
                }
                Spacer()
                RoundIconButton(icon: "arrow.clockwise", help: "새로고침") { Task { await m.loadPrivacy() } }
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 16)

            if m.loadingPrivacy && !m.privLoaded {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("브라우저 살펴보는 중…").font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if m.privacy.isEmpty {
                VStack(spacing: 14) {
                    IconTile(icon: "hand.raised.fill", colors: [Color(hex: 0x93C5FD), Color(hex: 0x2563EB)], size: 72)
                    Text("지울 브라우저 기록이 없어요").font(.system(size: 22, weight: .bold, design: .rounded))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(m.privacy) { BrowserCard(b: $0) }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 18)
                }
                bottomBar
            }
        }
        .task { await m.loadPrivacy() }
        .alert("선택한 \(m.privSelected.count)개 항목을 지울까요?", isPresented: $confirm) {
            Button("지우기", role: .destructive) { Task { await m.cleanPrivacy() } }
            Button("취소", role: .cancel) {}
        } message: {
            Text(m.privCookiesSelected
                 ? "쿠키를 지우면 해당 브라우저의 모든 사이트에서 로그아웃돼요.\n지운 기록은 되돌릴 수 없어요. 비밀번호와 북마크는 그대로예요."
                 : "지운 기록은 되돌릴 수 없어요. 비밀번호와 북마크는 그대로예요.")
        }
    }

    var bottomBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("선택 \(m.privSelected.count)개").font(.system(size: 14, weight: .semibold))
                Text(m.privCookiesSelected ? "⚠️ 쿠키가 선택돼 있어요 · 로그아웃돼요" : "실행 중인 브라우저는 종료 후 정리돼요")
                    .font(.system(size: 11))
                    .foregroundStyle(m.privCookiesSelected ? Color(hex: 0xFCD34D) : Color.white.opacity(0.55))
            }
            Spacer()
            Button("모두 해제") { m.privSelected = [] }
                .buttonStyle(GhostButton())
                .disabled(m.privSelected.isEmpty)
            Button {
                confirm = true
            } label: {
                Label("선택 항목 지우기", systemImage: "hand.raised.fill")
            }
            .buttonStyle(PillButton(colors: [Color(hex: 0x60A5FA), Color(hex: 0x4F46E5)]))
            .disabled(m.privSelected.isEmpty || m.working)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .background(Color.black.opacity(0.2))
    }
}

struct BrowserCard: View {
    @EnvironmentObject var m: Model
    let b: PrivBrowser
    @State private var tick = 0

    var isRunning: Bool {
        _ = tick
        return !NSRunningApplication.runningApplications(withBundleIdentifier: b.bundle).isEmpty
    }

    var appIcon: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b.bundle) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    func quit() {
        NSRunningApplication.runningApplications(withBundleIdentifier: b.bundle).forEach { $0.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            tick += 1
            Task { await m.loadPrivacy() }
        }
    }

    var body: some View {
        let running = isRunning
        let availableCount = b.items.filter(\.available).count

        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    if let icon = appIcon {
                        Image(nsImage: icon).resizable().frame(width: 40, height: 40)
                    } else {
                        IconTile(icon: "globe", colors: [Color(hex: 0x93C5FD), Color(hex: 0x4F46E5)], size: 40)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(b.name).font(.system(size: 17, weight: .bold, design: .rounded))
                        Text(b.noAccess ? "권한이 필요해요" : "지울 수 있는 기록 \(availableCount)종")
                            .font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.55))
                    }
                    Spacer()
                    if running {
                        Text("실행 중")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(hex: 0xFCD34D))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color(hex: 0xF59E0B).opacity(0.18), in: Capsule())
                        Button("종료하기") { quit() }.buttonStyle(GhostButton())
                    }
                }

                if b.noAccess {
                    HStack(spacing: 10) {
                        Text("Safari 기록을 보려면 전체 디스크 접근 권한이 필요해요.")
                            .font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.7))
                        Spacer()
                        Button("설정 열기") {
                            if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                NSWorkspace.shared.open(u)
                            }
                        }
                        .buttonStyle(GhostButton())
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(b.items, id: \.key) { it in
                            PrivItemTile(browser: b.name, item: it, disabled: running || !it.available)
                        }
                    }
                    if running {
                        Text("실행 중에는 지울 수 없어요. 종료하면 체크할 수 있어요.")
                            .font(.system(size: 11)).foregroundStyle(Color(hex: 0xFCD34D).opacity(0.85))
                    }
                }
            }
            .padding(16)
        }
    }
}

struct PrivItemTile: View {
    @EnvironmentObject var m: Model
    let browser: String
    let item: PrivItem
    let disabled: Bool
    @State private var hover = false

    var key: String { "\(browser)|\(item.key)" }
    var isOn: Bool { m.privSelected.contains(key) && !disabled }
    var isCookies: Bool { item.key == "cookies" }

    var icon: String {
        switch item.key {
        case "history": return "clock.arrow.circlepath"
        case "downloads": return "arrow.down.circle"
        case "autofill": return "character.cursor.ibeam"
        default: return "person.crop.circle.badge.xmark"
        }
    }

    var detail: String {
        if !item.available { return "없음" }
        if let c = item.count { return "\(c.formatted())개" }
        return item.size > 0 ? fmt(item.size) : "있음"
    }

    func toggle() {
        guard !disabled else { return }
        if m.privSelected.contains(key) { m.privSelected.remove(key) } else { m.privSelected.insert(key) }
    }

    var body: some View {
        HStack(spacing: 10) {
            CheckCircle(state: isOn ? .on : .off, action: toggle)
                .disabled(disabled)
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.75))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.label).font(.system(size: 13, weight: .semibold))
                Text(isCookies ? "모든 사이트에서 로그아웃돼요" : detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(isCookies ? Color(hex: 0xFCD34D).opacity(0.9) : Color.white.opacity(0.55))
            }
            Spacer(minLength: 4)
            if isCookies {
                Text(detail).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(Color.white.opacity(0.6))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(isOn ? 0.17 : (hover && !disabled ? 0.1 : 0.05))))
        .opacity(disabled ? 0.45 : 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { hover = $0 }
    }
}

// MARK: - 앱 완전 삭제

struct AppsView: View {
    @EnvironmentObject var m: Model
    @State private var query = ""
    @State private var current: AppEntry?
    @State private var confirm = false
    @State private var tick = 0

    var filtered: [AppEntry] {
        query.isEmpty ? m.apps : m.apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Color.white.opacity(0.55))
                        TextField("앱 검색", text: $query).textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    RoundIconButton(icon: "arrow.clockwise", help: "새로고침") { Task { await m.loadApps() } }
                }
                .padding(14)

                if m.loadingApps && m.apps.isEmpty {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("앱 목록 불러오는 중…").font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(filtered) { app in
                                AppRow(app: app, selected: current == app) { current = app }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 10)
                    }
                }
            }
            .frame(width: 290)
            .background(Color.black.opacity(0.14))

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { if m.apps.isEmpty { await m.loadApps() } }
        .task(id: current) {
            if let app = current { await m.loadInfo(app) }
        }
    }

    func isRunning(_ app: AppEntry) -> Bool {
        _ = tick
        guard !app.bundle.isEmpty else { return false }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundle).isEmpty
    }

    func quit(_ app: AppEntry) {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.bundle).forEach { $0.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { tick += 1 }
    }

    @ViewBuilder
    var detail: some View {
        if let app = current {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                            .resizable()
                            .frame(width: 104, height: 104)
                            .shadow(color: Color.black.opacity(0.35), radius: 16, y: 8)
                        Text(app.name).font(.system(size: 26, weight: .bold, design: .rounded))
                        Text(app.bundle).font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.5)).textSelection(.enabled)
                    }
                    .padding(.top, 26)

                    if isRunning(app) {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(hex: 0xFCD34D))
                            Text("앱이 실행 중이에요. 먼저 종료해야 깨끗하게 지워져요.").font(.system(size: 12))
                            Spacer()
                            Button("앱 종료") { quit(app) }.buttonStyle(GhostButton())
                        }
                        .padding(12)
                        .background(Color(hex: 0xF59E0B).opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    if m.loadingInfo {
                        ProgressView().controlSize(.small).padding(30)
                    } else if let info = m.appInfo, info.path == app.path {
                        let total: Int64 = info.size + info.leftovers.reduce(0) { $0 + $1.size }

                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("함께 지울 항목").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.white.opacity(0.6))
                                fileRow(info.path, info.size, icon: "app.fill")
                                ForEach(info.leftovers, id: \.path) { fileRow($0.path, $0.size, icon: "doc.fill") }
                                if info.leftovers.isEmpty {
                                    Text("남은 파일이 없어요.").font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.5))
                                }
                                Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
                                HStack {
                                    Text("합계").font(.system(size: 13, weight: .semibold))
                                    Spacer()
                                    Text(fmt(total)).font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit()
                                }
                            }
                            .padding(16)
                        }

                        if !info.kept.isEmpty {
                            Card {
                                VStack(alignment: .leading, spacing: 6) {
                                    Label("남겨두는 항목 · 대화 이력·기억·설정", systemImage: "lock.shield.fill")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color(hex: 0x6EE7B7))
                                    ForEach(info.kept, id: \.self) {
                                        Text(tilde($0)).font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.6))
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                    Text("다시 설치하면 그대로 이어서 쓸 수 있어요.")
                                        .font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.45))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                            }
                        }

                        Button {
                            confirm = true
                        } label: {
                            Label("\(fmt(total)) 완전 삭제", systemImage: "trash.fill")
                        }
                        .buttonStyle(PillButton(colors: [Color(hex: 0xFB7185), Color(hex: 0xE11D48)]))
                        .disabled(m.working)
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }
            .alert("\(app.name)을(를) 삭제할까요?", isPresented: $confirm) {
                Button("휴지통으로 이동", role: .destructive) {
                    Task { if await m.uninstall(app) { current = nil } }
                }
                Button("취소", role: .cancel) {}
            } message: {
                Text("앱과 남은 파일이 휴지통으로 이동해요.")
            }
        } else {
            VStack(spacing: 14) {
                IconTile(icon: "xmark.app.fill", colors: [Color(hex: 0x5EEAD4), Color(hex: 0x0D9488)], size: 72)
                Text("앱 완전 삭제").font(.system(size: 26, weight: .bold, design: .rounded))
                Text("왼쪽에서 앱을 고르면 앱이 남긴 파일까지 한 번에 찾아요.")
                    .font(.system(size: 13)).foregroundStyle(Color.white.opacity(0.65))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    func fileRow(_ path: String, _ size: Int64, icon: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.5)).frame(width: 16)
            Text(tilde(path)).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(fmt(size)).font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.8))
            RoundIconButton(icon: "magnifyingglass", help: "Finder에서 보기") { revealInFinder([path]) }
        }
    }
}

struct AppRow: View {
    let app: AppEntry
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                    .resizable().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(fmt(app.size)).font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.55))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.17 : (hover ? 0.07 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - 휴지통

struct TrashView: View {
    @EnvironmentObject var m: Model
    @State private var confirmDelete = false
    @State private var confirmEmpty = false

    var allState: CheckState {
        if m.trashSelected.isEmpty { return .off }
        return m.trashSelected.count == m.trashItems.count ? .on : .mixed
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if m.trashNoAccess {
                noAccess
            } else if m.loadingTrash && m.trashItems.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if m.trashItems.isEmpty {
                VStack(spacing: 14) {
                    IconTile(icon: "trash", colors: [Color(hex: 0xC4B5FD), Color(hex: 0x6366F1)], size: 72)
                    Text("휴지통이 비어 있어요").font(.system(size: 22, weight: .bold, design: .rounded))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                columns
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(m.sortedTrash) { TrashRow(entry: $0) }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 16)
                }
                bottomBar
            }
        }
        .task { await m.loadTrash() }
        .alert("선택한 \(m.trashSelected.count)개를 완전히 삭제할까요?", isPresented: $confirmDelete) {
            Button("완전 삭제", role: .destructive) { Task { await m.deleteSelectedTrash() } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("\(fmt(m.trashSelectedSize))가 영구적으로 삭제돼요. 되돌릴 수 없어요.")
        }
        .alert("휴지통을 모두 비울까요?", isPresented: $confirmEmpty) {
            Button("모두 비우기", role: .destructive) { Task { await m.emptyTrash() } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("휴지통의 모든 항목이 영구적으로 삭제돼요. 되돌릴 수 없어요.")
        }
    }

    var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("휴지통").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.white.opacity(0.65))
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(m.trashSize.map(fmt) ?? "—").font(.system(size: 42, weight: .bold, design: .rounded)).monospacedDigit()
                    if !m.trashItems.isEmpty {
                        Text("\(m.trashItems.count)개 항목").font(.system(size: 17, weight: .medium)).foregroundStyle(Color.white.opacity(0.75))
                    }
                }
            }
            Spacer()
            RoundIconButton(icon: "arrow.clockwise", help: "새로고침") { Task { await m.loadTrash() } }
            if !m.trashItems.isEmpty { sortMenu }
            Button {
                NSWorkspace.shared.open(m.trashURL)
            } label: {
                Label("Finder에서 열기", systemImage: "folder")
            }
            .buttonStyle(GhostButton())
            Button {
                confirmEmpty = true
            } label: {
                Label("모두 비우기", systemImage: "trash.slash")
            }
            .buttonStyle(GhostButton())
            .disabled((m.trashSize ?? 0) == 0 || m.working)
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .padding(.bottom, 16)
    }

    var columns: some View {
        HStack(spacing: 12) {
            CheckCircle(state: allState) {
                if allState == .on { m.trashSelected = [] } else { m.trashSelected = Set(m.trashItems.map(\.id)) }
            }
            // 아이콘 칸(30) 만큼 띄워서 이름 글자와 줄 맞춤
            Spacer().frame(width: 30, height: 1)
            sortButton("이름", .name).frame(maxWidth: .infinity, alignment: .leading)
            sortButton("삭제한 날짜", .date).frame(width: 170, alignment: .leading)
            sortButton("크기", .size).frame(width: 76, alignment: .trailing)
            Spacer().frame(width: 64, height: 1)
        }
        .font(.system(size: 11, weight: .semibold))
        .frame(height: 24)
        .padding(.horizontal, 40)
        .padding(.bottom, 4)
    }

    func sortButton(_ title: String, _ key: TrashSortKey) -> some View {
        let active = m.trashSortKey == key
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) { m.setTrashSort(key) }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if active {
                    Image(systemName: m.trashSortAsc ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .heavy))
                }
            }
            .foregroundStyle(Color.white.opacity(active ? 0.95 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("눌러서 정렬 · 한 번 더 누르면 순서 반대로")
    }

    var sortMenu: some View {
        Menu {
            Button("최근 삭제한 순") { m.trashSortKey = .date; m.trashSortAsc = false }
            Button("오래전 삭제한 순") { m.trashSortKey = .date; m.trashSortAsc = true }
            Divider()
            Button("큰 파일 순") { m.trashSortKey = .size; m.trashSortAsc = false }
            Button("작은 파일 순") { m.trashSortKey = .size; m.trashSortAsc = true }
            Divider()
            Button("이름 가나다순") { m.trashSortKey = .name; m.trashSortAsc = true }
            Button("이름 역순") { m.trashSortKey = .name; m.trashSortAsc = false }
        } label: {
            Label(sortLabel, systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.11), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
    }

    /// 삭제한 지 오래된 항목을 한 번에 선택
    var dateSelectMenu: some View {
        Menu {
            Section("이 기간보다 오래전에 삭제한 항목") {
                ForEach(TrashAge.allCases) { age in
                    let found = m.trashOlder(than: age)
                    let size = found.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
                    Button("\(age.label) 넘게 지난 항목 · \(found.count)개 (\(fmt(size)))") {
                        withAnimation(.easeInOut(duration: 0.15)) { m.selectTrash(olderThan: age) }
                    }
                    .disabled(found.isEmpty)
                }
            }
        } label: {
            Label("날짜로 선택", systemImage: "calendar")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.11), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
        .help("하루·일주일·1개월·3개월·6개월·1년보다 오래전에 삭제한 항목 선택")
    }

    var sortLabel: String {
        switch (m.trashSortKey, m.trashSortAsc) {
        case (.date, false): return "최근 삭제한 순"
        case (.date, true): return "오래전 삭제한 순"
        case (.size, false): return "큰 파일 순"
        case (.size, true): return "작은 파일 순"
        case (.name, true): return "이름 가나다순"
        case (.name, false): return "이름 역순"
        }
    }

    var bottomBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("선택 \(m.trashSelected.count)개 · \(fmt(m.trashSelectedSize))").font(.system(size: 14, weight: .semibold)).monospacedDigit()
                Text("완전 삭제하면 되돌릴 수 없어요").font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.55))
            }
            Spacer()
            dateSelectMenu
            Button("선택 해제") { m.trashSelected = [] }
                .buttonStyle(GhostButton())
                .disabled(m.trashSelected.isEmpty)
            Button {
                confirmDelete = true
            } label: {
                Label("선택 항목 완전 삭제", systemImage: "xmark.bin.fill")
            }
            .buttonStyle(PillButton(colors: [Color(hex: 0xFB7185), Color(hex: 0xE11D48)]))
            .disabled(m.trashSelected.isEmpty || m.working)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .background(Color.black.opacity(0.2))
    }

    var noAccess: some View {
        VStack(spacing: 16) {
            IconTile(icon: "lock.fill", colors: [Color(hex: 0xC4B5FD), Color(hex: 0x6366F1)], size: 64)
            Text("휴지통 목록을 보려면 권한이 필요해요").font(.system(size: 20, weight: .bold, design: .rounded))
            Text("시스템 설정 → 개인정보 보호 및 보안 → 전체 디스크 접근 권한에서\nMacClean을 켠 다음, 앱을 다시 실행해주세요.")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.white.opacity(0.7))
            Button {
                if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(u)
                }
            } label: {
                Label("설정 열기", systemImage: "gearshape")
            }
            .buttonStyle(PillButton(colors: [Color(hex: 0xA78BFA), Color(hex: 0x6366F1)]))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TrashRow: View {
    @EnvironmentObject var m: Model
    let entry: TrashEntry
    @State private var hover = false

    var isOn: Bool { m.trashSelected.contains(entry.id) }

    func toggle() {
        if isOn { m.trashSelected.remove(entry.id) } else { m.trashSelected.insert(entry.id) }
    }

    var body: some View {
        HStack(spacing: 12) {
            CheckCircle(state: isOn ? .on : .off, action: toggle)
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.url.path))
                .resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(entry.origin.map { "원래 위치: " + tilde($0) } ?? "Finder 등에서 삭제")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(relativeDate(entry.added)).font(.system(size: 12, weight: .medium))
                Text(absoluteDate(entry.added)).font(.system(size: 10)).foregroundStyle(Color.white.opacity(0.5))
            }
            .frame(width: 170, alignment: .leading)
            Group {
                if let s = entry.size {
                    Text(fmt(s))
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .frame(width: 76, alignment: .trailing)
            HStack(spacing: 6) {
                if entry.origin != nil {
                    RoundIconButton(icon: "arrow.uturn.backward", help: "원래 위치로 되돌리기") {
                        Task { await m.restore(entry) }
                    }
                }
                RoundIconButton(icon: "magnifyingglass", help: "Finder에서 보기") { revealInFinder([entry.url.path]) }
            }
            .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(isOn ? 0.15 : (hover ? 0.11 : 0.06))))
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { hover = $0 }
    }
}
