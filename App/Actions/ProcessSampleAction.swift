//
//  ProcessSampleAction.swift
//  Process sampling / dump-equivalent action.
//

import AppKit
import Foundation
import ProcexpModel
import UniformTypeIdentifiers

private struct ProcessSampleOutcome: Sendable {
    var title: String
    var message: String
}

extension AppModel {
    private static let sampleDurationSeconds = 10
    private static let sampleExecutablePath = "/usr/bin/sample"

    func sampleSelectedProcess() {
        guard let pid = selection else { return }
        sampleProcess(pid)
    }

    func sampleProcess(_ pid: ProcessID) {
        guard let record = snapshot.info(pid) else {
            processActionAlert = ProcessActionAlert(
                title: "Process Not Found",
                message: "The selected process is no longer present in the current snapshot."
            )
            return
        }

        let panel = NSSavePanel()
        panel.title = "Sample Process"
        panel.prompt = "Sample"
        panel.message = "Choose where to save a \(Self.sampleDurationSeconds)-second sample of \(record.name) (PID \(record.id.pid)). Sampling protected processes may require elevated privileges."
        panel.nameFieldStringValue = Self.defaultSampleFileName(for: record)
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        let processName = record.name
        let pidValue = record.id.pid
        Task {
            let outcome = await Self.runSampleCommand(
                pid: pidValue,
                processName: processName,
                destinationURL: destinationURL,
                durationSeconds: Self.sampleDurationSeconds
            )
            processActionAlert = ProcessActionAlert(title: outcome.title, message: outcome.message)
        }
    }

    private static func defaultSampleFileName(for record: ProcessRecord) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:").union(.newlines)
        let cleaned = record.name
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "process" : cleaned
        return "\(base)-\(record.id.pid).sample.txt"
    }

    nonisolated private static func runSampleCommand(pid: pid_t,
                                                     processName: String,
                                                     destinationURL: URL,
                                                     durationSeconds: Int) async -> ProcessSampleOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = runSampleCommandSynchronously(
                    pid: pid,
                    processName: processName,
                    destinationURL: destinationURL,
                    durationSeconds: durationSeconds
                )
                continuation.resume(returning: outcome)
            }
        }
    }

    nonisolated private static func runSampleCommandSynchronously(pid: pid_t,
                                                                  processName: String,
                                                                  destinationURL: URL,
                                                                  durationSeconds: Int) -> ProcessSampleOutcome {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: sampleExecutablePath)
        task.arguments = [String(pid), String(durationSeconds), "-file", destinationURL.path]

        let outputPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = outputPipe

        do {
            try task.run()
        } catch {
            return ProcessSampleOutcome(
                title: "Sample Could Not Start",
                message: "Could not run \(sampleExecutablePath) for \(processName) (PID \(pid)).\n\n\(describeSampleError(error))"
            )
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let destinationPath = destinationURL.path
        if task.terminationStatus == 0, FileManager.default.fileExists(atPath: destinationPath) {
            return ProcessSampleOutcome(
                title: "Sample Complete",
                message: "Saved a \(durationSeconds)-second sample of \(processName) (PID \(pid)) to:\n\n\(destinationPath)"
            )
        }

        let baseMessage: String
        if isPermissionFailure(output: output) {
            baseMessage = "macOS denied sampling \(processName) (PID \(pid)). Try running Process Explorer with appropriate permissions, sampling a process owned by your user, or adding a privileged-helper capture path. System Integrity Protection may still prevent sampling protected processes."
        } else if !FileManager.default.fileExists(atPath: destinationPath), task.terminationStatus == 0 {
            baseMessage = "sample reported success, but no output file was written at:\n\n\(destinationPath)"
        } else {
            baseMessage = "sample failed for \(processName) (PID \(pid)) with exit status \(task.terminationStatus). The process may have exited, or macOS may not allow this process to be sampled."
        }

        return ProcessSampleOutcome(
            title: "Sample Failed",
            message: appendSampleOutput(to: baseMessage, output: output)
        )
    }

    nonisolated private static func isPermissionFailure(output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("operation not permitted")
            || lower.contains("permission denied")
            || lower.contains("not permitted")
            || lower.contains("not authorized")
            || lower.contains("failed to get task")
    }

    nonisolated private static func appendSampleOutput(to message: String, output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return message }
        let limited = String(trimmed.prefix(4000))
        let suffix = trimmed.count > limited.count ? "\n..." : ""
        return "\(message)\n\nsample output:\n\(limited)\(suffix)"
    }

    nonisolated private static func describeSampleError(_ error: Error) -> String {
        let text = error.localizedDescription
        return text.isEmpty ? String(describing: error) : text
    }
}