import Foundation
import AppKit
import Security

// MARK: - Models

enum FanMode: String, CaseIterable, Identifiable {
    case auto = "Auto"
    case fullBlast = "Full Blast"
    case custom = "Custom"

    nonisolated var id: String { rawValue }

    var description: String {
        switch self {
        case .auto: "System manages fan speed automatically"
        case .fullBlast: "Run selected fans at maximum reported speed"
        case .custom: "Set a custom target speed (can exceed max)"
        }
    }

    var icon: String {
        switch self {
        case .auto: "gearshape"
        case .fullBlast: "wind"
        case .custom: "slider.horizontal.3"
        }
    }
}

struct FanInfo: Identifiable {
    nonisolated let id: Int
    var currentRPM: Double = 0
    var minRPM: Double = 0
    var maxRPM: Double = 6500
}

// MARK: - Fan Manager

@Observable
class FanManager {
    var fans: [FanInfo] = []
    var selectedFans: Set<Int> = []
    var mode: FanMode = .auto
    var customRPM: Double = 3000
    var cpuTemperature: Double = 0
    var errorMessage: String?
    var debugLog: String?
    var isConnected = false

    private let smc = SMCKit()
    private var pollTask: Task<Void, Never>?
    private var authRef: AuthorizationRef?

    // Swift marks AuthorizationExecuteWithPrivileges unavailable, but the symbol
    // is still present in Security.framework. We resolve it via dlsym.
    private typealias AuthExecFn = @convention(c) (
        AuthorizationRef,
        UnsafePointer<CChar>,
        AuthorizationFlags,
        UnsafePointer<UnsafeMutablePointer<CChar>?>,
        UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
    ) -> OSStatus

    private static let authExecWithPrivilegesFn: AuthExecFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "AuthorizationExecuteWithPrivileges") else {
            return nil
        }
        return unsafeBitCast(sym, to: AuthExecFn.self)
    }()

    var sliderMin: Double {
        fans.map(\.minRPM).min() ?? 0
    }

    var sliderMax: Double {
        let reported = fans.map(\.maxRPM).max() ?? 6500
        return max(reported * 1.5, 10000)
    }

    init() {
        connect()
    }

    func connect() {
        do {
            try smc.open()
            isConnected = true
            errorMessage = nil
            loadFans()
            startPolling()
        } catch {
            isConnected = false
            errorMessage = error.localizedDescription
        }
    }

    private func loadFans() {
        guard let count = try? smc.getFanCount(), count > 0 else {
            fans = []
            selectedFans = []
            return
        }

        fans = (0..<count).map { i in
            FanInfo(
                id: i,
                currentRPM: (try? smc.getFanCurrentRPM(fan: i)) ?? 0,
                minRPM: (try? smc.getFanMinRPM(fan: i)) ?? 0,
                maxRPM: (try? smc.getFanMaxRPM(fan: i)) ?? 6500
            )
        }

        selectedFans = Set(fans.map(\.id))

        if let first = fans.first {
            customRPM = Double(Int((first.minRPM + first.maxRPM) / 2 / 100) * 100)
        }
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func refresh() {
        for i in fans.indices {
            if let rpm = try? smc.getFanCurrentRPM(fan: fans[i].id) {
                fans[i].currentRPM = rpm
            }
        }
        if let temp = try? smc.getCPUTemperature() {
            cpuTemperature = temp
        }
    }

    // MARK: - Mode Application

    func applyMode() {
        guard !selectedFans.isEmpty else {
            errorMessage = "Select at least one fan."
            return
        }

        let fanList = selectedFans.sorted().map(String.init).joined(separator: ",")
        let helperArgs: [String]
        switch mode {
        case .auto: helperArgs = ["auto", fanList]
        case .fullBlast: helperArgs = ["full", fanList]
        case .custom: helperArgs = ["custom", String(Int(customRPM)), fanList]
        }

        let result = executeElevated(args: helperArgs)
        debugLog = result.log
        if result.success {
            errorMessage = nil
        } else {
            errorMessage = result.error
        }
    }

    func resetToAuto() {
        mode = .auto
        selectedFans = Set(fans.map(\.id))
        _ = executeElevated(args: ["auto", selectedFans.sorted().map(String.init).joined(separator: ",")])
    }

    // MARK: - Elevated Execution (cached auth — one prompt per app launch)

    private func ensureAuth() -> (ok: Bool, error: String?) {
        if authRef != nil { return (true, nil) }

        var ref: AuthorizationRef?
        let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
        let status = AuthorizationCreate(nil, nil, flags, &ref)

        if status == errAuthorizationSuccess, let ref {
            authRef = ref
            return (true, nil)
        }
        if status == errAuthorizationCanceled {
            return (false, "Authorization cancelled.")
        }
        return (false, "Authorization failed (status \(status)).")
    }

    private func executeElevated(args: [String]) -> (success: Bool, error: String?, log: String) {
        let auth = ensureAuth()
        guard auth.ok, let ref = authRef else {
            return (false, auth.error ?? "Authorization unavailable.", "")
        }
        guard let execPath = Bundle.main.executablePath else {
            return (false, "Could not locate app executable.", "")
        }

        let fullArgs = ["--smc-helper"] + args

        // Build a null-terminated C string array.
        var cArgs: [UnsafeMutablePointer<CChar>?] = fullArgs.map { strdup($0) }
        cArgs.append(nil)
        defer { for p in cArgs { if let p { free(p) } } }

        guard let authExec = Self.authExecWithPrivilegesFn else {
            return (false, "AuthorizationExecuteWithPrivileges unavailable.", "")
        }

        var pipe: UnsafeMutablePointer<FILE>?
        let status: OSStatus = cArgs.withUnsafeMutableBufferPointer { buf in
            execPath.withCString { pathPtr in
                authExec(ref, pathPtr, [], buf.baseAddress!, &pipe)
            }
        }

        guard status == errAuthorizationSuccess else {
            if status == errAuthorizationCanceled {
                // User cancelled — drop cached auth so next attempt re-prompts.
                clearAuth()
                return (false, "Authorization cancelled.", "")
            }
            clearAuth()
            return (false, "AuthorizationExecuteWithPrivileges failed (\(status)).", "")
        }

        var output = Data()
        if let pipe {
            let fd = fileno(pipe)
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                output.append(buf, count: n)
            }
            fclose(pipe)
        }

        // Reap the helper process so it doesn't become a zombie.
        var childStatus: Int32 = 0
        _ = wait(&childStatus)

        let text = String(data: output, encoding: .utf8) ?? ""
        if text.contains("SMC Helper Error") {
            return (false, text.trimmingCharacters(in: .whitespacesAndNewlines), text)
        }
        return (true, nil, text)
    }

    private func clearAuth() {
        if let ref = authRef {
            AuthorizationFree(ref, [.destroyRights])
        }
        authRef = nil
    }

    deinit {
        pollTask?.cancel()
        smc.close()
        clearAuth()
    }
}

// MARK: - SMC Helper Mode

enum SMCHelper {
    static func run() {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--smc-helper"),
              idx + 1 < args.count else { return }

        let command = args[idx + 1]
        let smc = SMCKit()

        let logPath = "/tmp/fan-controller.log"
        let logHandle = fopen(logPath, "a")
        func log(_ msg: String) {
            print(msg)
            fflush(stdout)
            if let h = logHandle {
                fputs(msg + "\n", h)
                fflush(h)
            }
        }
        defer { if let h = logHandle { fclose(h) } }

        log("=== Helper start (uid=\(getuid()), euid=\(geteuid())) cmd=\(command) args=\(args.dropFirst().joined(separator: " ")) ===")

        do {
            try smc.open()
            defer { smc.close() }

            let count = try smc.getFanCount()
            log("SMC opened, fan count: \(count)")

            // Parse fan indices from the last argument if it looks like "0,1".
            // For auto/full: args are [cmd, fanList]. For custom: [cmd, rpm, fanList].
            let fanIndices: [Int] = {
                let allFans = Array(0..<count)
                let tail = args.last ?? ""
                let parsed = tail.split(separator: ",").compactMap { Int($0) }
                let valid = parsed.filter { $0 >= 0 && $0 < count }
                return valid.isEmpty ? allFans : valid
            }()
            log("Applying to fans: \(fanIndices)")

            switch command {
            case "auto":
                for i in fanIndices {
                    try smc.setFanForced(i, forced: false)
                    _ = try? smc.writeKey("F\(i)Md", bytes: byteValue(0))
                    log("Fan \(i): auto restored")
                }

            case "full":
                for i in fanIndices {
                    let maxRPM = try smc.getFanMaxRPM(fan: i)
                    try smc.setFanForced(i, forced: true)
                    _ = try? smc.writeKey("F\(i)Md", bytes: byteValue(1))
                    try smc.setFanTargetRPM(fan: i, rpm: maxRPM)
                    log("Fan \(i): full blast, target=\(maxRPM)")
                }

            case "custom":
                guard idx + 2 < args.count, let rpm = Double(args[idx + 2]) else {
                    log("ERROR: missing rpm argument")
                    return
                }
                for i in fanIndices {
                    try smc.setFanForced(i, forced: true)
                    _ = try? smc.writeKey("F\(i)Md", bytes: byteValue(1))
                    try smc.setFanTargetRPM(fan: i, rpm: rpm)
                    log("Fan \(i): custom target=\(rpm)")
                }

            default:
                log("ERROR: unknown command \(command)")
            }

            log("=== Helper done OK ===")
        } catch {
            log("SMC Helper Error: \(error.localizedDescription)")
        }
    }

    private static func byteValue(_ v: UInt8) -> SMCBytes_t {
        (v, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }
}
