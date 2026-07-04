//
//  Column.swift
//  ProcexpModel — W0 shared contracts
//
//  The user-selectable columns of the main process list, with pure
//  formatting and sort-key functions so any renderer stays consistent.
//

import Foundation

/// A sortable key derived from a column value. Comparable across a single column.
public enum SortKey: Comparable, Sendable {
    case number(Double)
    case text(String)
    case none

    public static func < (lhs: SortKey, rhs: SortKey) -> Bool {
        switch (lhs, rhs) {
        case let (.number(a), .number(b)): return a < b
        case let (.text(a), .text(b)):     return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        case (.none, _):                   return false
        case (_, .none):                   return true
        default:                           return false
        }
    }
}

public enum Column: String, CaseIterable, Sendable, Codable {
    case name, pid, ppid, cpu, cpuTime, privateBytes, workingSet, virtualSize,
         threads, handles, description, company, version, path, commandLine,
         user, session, startTime, priority, nice, ioRead, ioWrite,
         network, gpu, gpuMemory, integrity, signature, virusTotal, autostart

    public var title: String {
        switch self {
        case .name:         return "Process"
        case .pid:          return "PID"
        case .ppid:         return "Parent PID"
        case .cpu:          return "CPU"
        case .cpuTime:      return "CPU Time"
        case .privateBytes: return "Private Bytes"
        case .workingSet:   return "Working Set"
        case .virtualSize:  return "Virtual Size"
        case .threads:      return "Threads"
        case .handles:      return "Handles"
        case .description:  return "Description"
        case .company:      return "Company Name"
        case .version:      return "Version"
        case .path:         return "Path"
        case .commandLine:  return "Command Line"
        case .user:         return "User Name"
        case .session:      return "Session"
        case .startTime:    return "Start Time"
        case .priority:     return "Priority"
        case .nice:         return "Nice"
        case .ioRead:       return "I/O Read Bytes"
        case .ioWrite:      return "I/O Write Bytes"
        case .network:      return "Network"
        case .gpu:          return "GPU"
        case .gpuMemory:    return "GPU Memory"
        case .integrity:    return "Integrity"
        case .signature:    return "Verified Signer"
        case .virusTotal:   return "VirusTotal"
        case .autostart:    return "Autostart Location"
        }
    }

    public var defaultWidth: CGFloat {
        switch self {
        case .name:         return 260
        case .pid:          return 58
        case .ppid:         return 78
        case .cpu:          return 54
        case .cpuTime:      return 88
        case .privateBytes, .workingSet, .virtualSize: return 96
        case .threads:      return 62
        case .handles:      return 68
        case .description:  return 220
        case .company:      return 170
        case .version:      return 118
        case .path, .commandLine: return 420
        case .user:         return 130
        case .session:      return 76
        case .startTime:    return 142
        case .priority:     return 70
        case .nice:         return 48
        case .ioRead, .ioWrite: return 110
        case .network:      return 96
        case .gpu:          return 58
        case .gpuMemory:    return 96
        case .integrity:    return 92
        case .signature:    return 240
        case .virusTotal:   return 82
        case .autostart:    return 260
        }
    }

    public var isRightAligned: Bool {
        switch self {
        case .name, .description, .company, .version, .path, .commandLine,
             .user, .startTime, .signature, .autostart, .integrity:
            return false
        default:
            return true
        }
    }

    /// Columns backed by supportable macOS data sources in this app. Unsupported
    /// Windows-only/private-API columns stay decodable for old settings but are
    /// removed from menus, saved layouts, and active column sets.
    public var isSupportedOnMac: Bool {
        switch self {
        case .network, .gpu, .gpuMemory, .integrity:
            return false
        default:
            return true
        }
    }

    public static var supportedOnMac: [Column] {
        allCases.filter(\.isSupportedOnMac)
    }

    public static let pinnedOnMac: [Column] = [.name, .pid]

    /// Formats the display string for this column for a given process.
    public func string(for p: ProcessRecord) -> String {
        switch self {
        case .name:         return p.name
        case .pid:          return String(p.id.pid)
        case .ppid:         return p.parent.map { String($0.pid) } ?? ""
        case .cpu:          return p.hasTaskInfo ? (p.cpuPercent < 0.01 ? "" : String(format: "%.2f", p.cpuPercent)) : ""
        case .cpuTime:      return p.hasTaskInfo ? ByteFormat.duration(nanos: p.cpuTime) : ""
        case .privateBytes: return p.hasTaskInfo ? ByteFormat.bytes(p.physFootprint ?? p.residentSize) : ""
        case .workingSet:   return p.hasTaskInfo ? ByteFormat.bytes(p.residentSize) : ""
        case .virtualSize:  return p.hasTaskInfo ? ByteFormat.bytes(p.virtualSize) : ""
        case .threads:      return p.hasTaskInfo ? String(p.threadCount) : ""
        case .handles:      return p.fileDescriptorCount.map(String.init) ?? ""
        case .description:  return p.displayDescription ?? ""
        case .company:      return p.companyName ?? ""
        case .version:      return p.version ?? ""
        case .path:         return p.executablePath ?? ""
        case .commandLine:  return p.commandLine ?? ""
        case .user:         return p.userName ?? String(p.uid)
        case .session:      return p.sessionTTY ?? ""
        case .startTime:    return ByteFormat.dateTime(p.startTimeDate)
        case .priority:     return p.hasTaskInfo ? String(p.priority) : ""
        case .nice:         return String(p.nice)
        case .ioRead:       return p.diskBytesRead.map(ByteFormat.bytes) ?? ""
        case .ioWrite:      return p.diskBytesWritten.map(ByteFormat.bytes) ?? ""
        case .network:      return p.networkBytesPerSec.map { ByteFormat.bytes($0) + "/s" } ?? ""
        case .gpu:          return p.gpuPercent.map { String(format: "%.1f", $0) } ?? ""
        case .gpuMemory:    return ""
        case .integrity:    return p.flags.contains(.sandboxed) ? "Sandboxed" : (p.flags.contains(.platformBinary) ? "Platform" : "")
        case .signature:    return p.signing?.signerDescription ?? ""
        case .virusTotal:
            guard let vt = p.signing?.virusTotal else { return "" }
            return "\(vt.positives)/\(vt.total)"
        case .autostart:    return p.autostartLocation ?? ""
        }
    }

    /// A comparable sort key for this column.
    public func sortValue(for p: ProcessRecord) -> SortKey {
        switch self {
        case .name:         return .text(p.name)
        case .pid:          return .number(Double(p.id.pid))
        case .ppid:         return .number(Double(p.parent?.pid ?? -1))
        case .cpu:          return p.hasTaskInfo ? .number(p.cpuPercent) : .none
        case .cpuTime:      return p.hasTaskInfo ? .number(Double(p.cpuTime)) : .none
        case .privateBytes: return p.hasTaskInfo ? .number(Double(p.physFootprint ?? p.residentSize)) : .none
        case .workingSet:   return p.hasTaskInfo ? .number(Double(p.residentSize)) : .none
        case .virtualSize:  return p.hasTaskInfo ? .number(Double(p.virtualSize)) : .none
        case .threads:      return p.hasTaskInfo ? .number(Double(p.threadCount)) : .none
        case .handles:      return .number(Double(p.fileDescriptorCount ?? 0))
        case .description:  return .text(p.displayDescription ?? "")
        case .company:      return .text(p.companyName ?? "")
        case .version:      return .text(p.version ?? "")
        case .path:         return .text(p.executablePath ?? "")
        case .commandLine:  return .text(p.commandLine ?? "")
        case .user:         return .text(p.userName ?? String(p.uid))
        case .session:      return .text(p.sessionTTY ?? "")
        case .startTime:    return .number(p.startTimeDate.timeIntervalSince1970)
        case .priority:     return p.hasTaskInfo ? .number(Double(p.priority)) : .none
        case .nice:         return .number(Double(p.nice))
        case .ioRead:       return .number(Double(p.diskBytesRead ?? 0))
        case .ioWrite:      return .number(Double(p.diskBytesWritten ?? 0))
        case .network:      return .number(Double(p.networkBytesPerSec ?? 0))
        case .gpu:          return .number(p.gpuPercent ?? 0)
        case .gpuMemory:    return .none
        case .integrity:    return .text(string(for: p))
        case .signature:    return .text(p.signing?.signerDescription ?? "")
        case .virusTotal:   return .number(Double(p.signing?.virusTotal?.positives ?? -1))
        case .autostart:    return .text(p.autostartLocation ?? "")
        }
    }

    /// A sensible default column layout matching Process Explorer's defaults.
    public static let defaultColumns: [Column] = [
        .name, .pid, .cpu, .privateBytes, .workingSet, .description, .company, .signature
    ]
}

private extension ProcessRecord {
    var hasTaskInfo: Bool { !flags.contains(.limitedTaskInfo) }
}

/// Pure formatting helpers used by column rendering (no locale surprises for tests).
public enum ByteFormat {
    public static func bytes(_ value: UInt64) -> String {
        if value == 0 { return "" }
        let units = ["B", "K", "M", "G", "T", "P"]
        var v = Double(value)
        var i = 0
        while v >= 1024 && i < units.count - 1 {
            v /= 1024
            i += 1
        }
        if i == 0 { return "\(value) B" }
        return String(format: "%.1f %@", v, units[i])
    }

    public static func duration(nanos: UInt64) -> String {
        let totalSeconds = Double(nanos) / 1_000_000_000
        let h = Int(totalSeconds) / 3600
        let m = (Int(totalSeconds) % 3600) / 60
        let s = Int(totalSeconds) % 60
        let cs = Int((totalSeconds - Double(Int(totalSeconds))) * 100)
        return String(format: "%d:%02d:%02d.%02d", h, m, s, cs)
    }

    public static func dateTime(_ date: Date) -> String {
        if date == .distantPast { return "" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }
}
