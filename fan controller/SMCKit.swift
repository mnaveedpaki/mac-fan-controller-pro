import Foundation
import IOKit

// MARK: - Errors

enum SMCError: Error, LocalizedError {
    case driverNotFound
    case failedToOpen(kern_return_t)
    case readError(kern_return_t)
    case writeError(kern_return_t)
    case notOpen

    nonisolated var errorDescription: String? {
        switch self {
        case .driverNotFound:
            "SMC driver not found on this Mac"
        case .failedToOpen(let code):
            "Failed to open SMC connection (error \(code))"
        case .readError(let code):
            "SMC read error (\(code))"
        case .writeError(let code):
            "SMC write error (\(code)). Administrator privileges required."
        case .notOpen:
            "SMC connection not open"
        }
    }
}

// MARK: - SMC Constants

private let KERNEL_INDEX_SMC: UInt32 = 2
private let SMC_CMD_READ_BYTES: UInt8 = 5
private let SMC_CMD_WRITE_BYTES: UInt8 = 6
private let SMC_CMD_READ_KEYINFO: UInt8 = 9

// MARK: - SMC Data Structures

typealias SMCBytes_t = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct SMCKeyData_vers_t {
    var major: CUnsignedChar = 0
    var minor: CUnsignedChar = 0
    var build: CUnsignedChar = 0
    var reserved: CUnsignedChar = 0
    var release: CUnsignedShort = 0
}

private struct SMCKeyData_pLimitData_t {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyData_keyInfo_t {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    // Swift embeds structs using `size` (9 bytes) not `stride` (12 bytes),
    // but the kernel expects C layout where sizeof includes trailing padding.
    // These 3 bytes align with C's sizeof(SMCKeyData_keyInfo_t) = 12.
    private var _padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
}

private struct SMCKeyData_t {
    var key: UInt32 = 0
    var vers = SMCKeyData_vers_t()
    var pLimitData = SMCKeyData_pLimitData_t()
    var keyInfo = SMCKeyData_keyInfo_t()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes_t = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )
}

struct SMCVal_t {
    var key: String = ""
    var dataSize: UInt32 = 0
    var dataType: String = ""
    var bytes: SMCBytes_t = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )
}

// MARK: - FourCharCode Helpers

private func fourCharCode(_ str: String) -> UInt32 {
    var result: UInt32 = 0
    for byte in str.utf8.prefix(4) {
        result = (result << 8) | UInt32(byte)
    }
    return result
}

private func fourCharString(_ code: UInt32) -> String {
    var s = ""
    s.append(Character(UnicodeScalar((code >> 24) & 0xFF)!))
    s.append(Character(UnicodeScalar((code >> 16) & 0xFF)!))
    s.append(Character(UnicodeScalar((code >> 8) & 0xFF)!))
    s.append(Character(UnicodeScalar(code & 0xFF)!))
    return s
}

// MARK: - SMC Client

class SMCKit {
    private var connection: io_connect_t = 0
    private(set) var isOpen = false

    func open() throws {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC")
        )
        guard service != 0 else { throw SMCError.driverNotFound }
        defer { IOObjectRelease(service) }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == kIOReturnSuccess else {
            throw SMCError.failedToOpen(result)
        }
        isOpen = true
    }

    func close() {
        if isOpen {
            IOServiceClose(connection)
            connection = 0
            isOpen = false
        }
    }

    deinit { close() }

    // MARK: - Low-Level

    private func callSMC(_ input: inout SMCKeyData_t) throws -> SMCKeyData_t {
        guard isOpen else { throw SMCError.notOpen }

        var output = SMCKeyData_t()
        var outputSize = MemoryLayout<SMCKeyData_t>.stride

        let result = IOConnectCallStructMethod(
            connection,
            KERNEL_INDEX_SMC,
            &input, MemoryLayout<SMCKeyData_t>.stride,
            &output, &outputSize
        )

        guard result == kIOReturnSuccess else {
            throw input.data8 == SMC_CMD_WRITE_BYTES
                ? SMCError.writeError(result)
                : SMCError.readError(result)
        }
        return output
    }

    private func getKeyInfo(_ key: UInt32) throws -> SMCKeyData_keyInfo_t {
        var input = SMCKeyData_t()
        input.key = key
        input.data8 = SMC_CMD_READ_KEYINFO
        return try callSMC(&input).keyInfo
    }

    func readKey(_ key: String) throws -> SMCVal_t {
        let code = fourCharCode(key)
        let info = try getKeyInfo(code)

        var input = SMCKeyData_t()
        input.key = code
        input.keyInfo = info
        input.data8 = SMC_CMD_READ_BYTES

        let output = try callSMC(&input)
        return SMCVal_t(
            key: key,
            dataSize: info.dataSize,
            dataType: fourCharString(info.dataType),
            bytes: output.bytes
        )
    }

    func writeKey(_ key: String, bytes: SMCBytes_t) throws {
        let code = fourCharCode(key)
        let info = try getKeyInfo(code)

        var input = SMCKeyData_t()
        input.key = code
        input.keyInfo = info
        input.data8 = SMC_CMD_WRITE_BYTES
        input.bytes = bytes

        _ = try callSMC(&input)
    }

    // MARK: - Fan Operations

    func getFanCount() throws -> Int {
        Int(try readKey("FNum").bytes.0)
    }

    func getFanCurrentRPM(fan: Int) throws -> Double {
        decodeRPM(try readKey(String(format: "F%dAc", fan)))
    }

    func getFanMinRPM(fan: Int) throws -> Double {
        decodeRPM(try readKey(String(format: "F%dMn", fan)))
    }

    func getFanMaxRPM(fan: Int) throws -> Double {
        decodeRPM(try readKey(String(format: "F%dMx", fan)))
    }

    func getFanTargetRPM(fan: Int) throws -> Double {
        decodeRPM(try readKey(String(format: "F%dTg", fan)))
    }

    func setFanTargetRPM(fan: Int, rpm: Double) throws {
        let key = String(format: "F%dTg", fan)
        let existing = try readKey(key)
        try writeKey(key, bytes: encodeRPM(rpm, dataType: existing.dataType))
    }

    func setFanForced(_ fan: Int, forced: Bool) throws {
        let val = try readKey("FS! ")
        var bits = UInt16(val.bytes.0) << 8 | UInt16(val.bytes.1)

        if forced {
            bits |= UInt16(1 << fan)
        } else {
            bits &= ~UInt16(1 << fan)
        }

        var bytes = emptyBytes()
        bytes.0 = UInt8((bits >> 8) & 0xFF)
        bytes.1 = UInt8(bits & 0xFF)
        try writeKey("FS! ", bytes: bytes)
    }

    // MARK: - Temperature

    func getCPUTemperature() throws -> Double {
        let val = try readKey("TC0P")
        return decodeSP78(val.bytes)
    }

    // MARK: - Data Encoding (type-aware)

    private func decodeRPM(_ val: SMCVal_t) -> Double {
        switch val.dataType {
        case "flt ":
            return Double(decodeFloat32(val.bytes))
        case "fpe2":
            return decodeFPE2(val.bytes)
        default:
            return decodeFPE2(val.bytes)
        }
    }

    private func encodeRPM(_ value: Double, dataType: String) -> SMCBytes_t {
        switch dataType {
        case "flt ":
            return encodeFloat32(value)
        case "fpe2":
            return encodeFPE2(value)
        default:
            return encodeFPE2(value)
        }
    }

    // Float32 (flt ) - used on T2 Macs, native (little-endian) byte order
    private func decodeFloat32(_ bytes: SMCBytes_t) -> Float32 {
        let bits = UInt32(bytes.0)
            | UInt32(bytes.1) << 8
            | UInt32(bytes.2) << 16
            | UInt32(bytes.3) << 24
        return Float32(bitPattern: bits)
    }

    private func encodeFloat32(_ value: Double) -> SMCBytes_t {
        let bits = Float32(value).bitPattern
        var bytes = emptyBytes()
        bytes.0 = UInt8(bits & 0xFF)
        bytes.1 = UInt8((bits >> 8) & 0xFF)
        bytes.2 = UInt8((bits >> 16) & 0xFF)
        bytes.3 = UInt8((bits >> 24) & 0xFF)
        return bytes
    }

    // FPE2 (unsigned 14.2 fixed-point) - used on older Intel Macs, big-endian
    private func decodeFPE2(_ bytes: SMCBytes_t) -> Double {
        Double(UInt16(bytes.0) << 8 | UInt16(bytes.1)) / 4.0
    }

    private func encodeFPE2(_ value: Double) -> SMCBytes_t {
        let raw = UInt16(max(0, value) * 4.0)
        var bytes = emptyBytes()
        bytes.0 = UInt8((raw >> 8) & 0xFF)
        bytes.1 = UInt8(raw & 0xFF)
        return bytes
    }

    // SP78 (signed 8.8 fixed-point) - temperature, big-endian
    private func decodeSP78(_ bytes: SMCBytes_t) -> Double {
        Double(Int16(bitPattern: UInt16(bytes.0) << 8 | UInt16(bytes.1))) / 256.0
    }

    private func emptyBytes() -> SMCBytes_t {
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }
}
