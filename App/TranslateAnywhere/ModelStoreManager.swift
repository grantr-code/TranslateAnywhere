/*
 * ModelStoreManager.swift
 * Runtime local-model catalog, installation, and download management.
 *
 * Models are stored outside the app bundle under:
 *   ~/Library/Application Support/TranslateAnywhere/models/<model-id>/
 */

import Foundation
import CryptoKit
import os.log

struct LocalModelStatus: Sendable {
    let state: ModelInstallState
    let progress: Double
    let lastError: String?
}

private struct ModelManifest: Codable {
    let schemaVersion: Int
    let models: [ModelManifestEntry]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case models
    }
}

private struct ModelManifestEntry: Codable {
    let id: String
    let family: String
    let version: String?
    let files: [ModelManifestFile]
}

private struct ModelManifestFile: Codable {
    let path: String
    let url: String?
    let sha256: String?
    let sizeBytes: UInt64?

    enum CodingKeys: String, CodingKey {
        case path
        case url
        case sha256
        case sizeBytes = "size_bytes"
    }
}

actor ModelStoreManager {

    static let shared = ModelStoreManager()

    private let logger = Logger(subsystem: "com.translateanywhere.app", category: "ModelStore")
    private let fm = FileManager.default

    private var states: [LocalModelID: ModelInstallState] = [:]
    private var progress: [LocalModelID: Double] = [:]
    private var lastErrors: [LocalModelID: String] = [:]
    private var installTasks: [LocalModelID: Task<Void, Never>] = [:]

    private var cachedManifest: ModelManifest?
    private var attemptedRemoteManifest = false

    private let appSupportURL: URL
    private let modelsRootURL: URL
    private let downloadsRootURL: URL

    private init() {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(AppConstants.appName, isDirectory: true)
        self.appSupportURL = base
        self.modelsRootURL = base.appendingPathComponent("models", isDirectory: true)
        self.downloadsRootURL = base.appendingPathComponent("downloads", isDirectory: true)

        do {
            try fm.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
            try fm.createDirectory(at: modelsRootURL, withIntermediateDirectories: true)
            try fm.createDirectory(at: downloadsRootURL, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create model storage directories: \(error.localizedDescription)")
        }

        for id in LocalModelID.allCases {
            states[id] = .notInstalled
            progress[id] = 0
        }

        Task {
            await refreshInstalledStates()
        }
    }

    // MARK: - Public API

    func refreshInstalledStates() {
        for id in LocalModelID.allCases {
            let current = states[id] ?? .notInstalled
            if current == .downloading {
                continue
            }

            let installed = isModelInstalledOnDisk(id)
            states[id] = installed ? .installed : .notInstalled
            if installed {
                progress[id] = 1.0
                lastErrors[id] = nil
            } else {
                progress[id] = 0
            }
            postInstallStateChanged(id)
        }
    }

    func hasAnyInstalledModels() -> Bool {
        LocalModelID.allCases.contains(where: { isModelInstalledOnDisk($0) })
    }

    func isInstalled(_ modelId: LocalModelID) -> Bool {
        isModelInstalledOnDisk(modelId)
    }

    func installedModelDirectory(for modelId: LocalModelID) -> String? {
        guard isModelInstalledOnDisk(modelId) else {
            return nil
        }
        return modelDirectory(for: modelId).path
    }

    func status(for modelId: LocalModelID) -> LocalModelStatus {
        LocalModelStatus(
            state: states[modelId] ?? .notInstalled,
            progress: progress[modelId] ?? 0,
            lastError: lastErrors[modelId]
        )
    }

    func allStatuses() -> [LocalModelID: LocalModelStatus] {
        var result: [LocalModelID: LocalModelStatus] = [:]
        for id in LocalModelID.allCases {
            result[id] = status(for: id)
        }
        return result
    }

    func installModel(_ modelId: LocalModelID) {
        if installTasks[modelId] != nil {
            return
        }

        let task = Task {
            await performInstall(modelId)
        }
        installTasks[modelId] = task
    }

    func installAllModels() {
        for id in LocalModelID.allCases {
            if !isModelInstalledOnDisk(id) {
                installModel(id)
            }
        }
    }

    @discardableResult
    func installModelAndWait(_ modelId: LocalModelID) async -> Bool {
        installModel(modelId)
        if let task = installTasks[modelId] {
            await task.value
        }
        return isModelInstalledOnDisk(modelId)
    }

    // MARK: - Install Logic

    private func performInstall(_ modelId: LocalModelID) async {
        states[modelId] = .downloading
        progress[modelId] = 0
        lastErrors[modelId] = nil
        postInstallStateChanged(modelId)
        postDownloadProgressChanged(modelId)

        let tempInstallURL = downloadsRootURL
            .appendingPathComponent("\(modelId.rawValue)-\(UUID().uuidString)", isDirectory: true)

        do {
            let entry = try await manifestEntry(for: modelId)
            try fm.createDirectory(at: tempInstallURL, withIntermediateDirectories: true)

            var totalBytes: UInt64 = 0
            for file in entry.files {
                totalBytes += file.sizeBytes ?? 0
            }
            var completedBytes: UInt64 = 0
            var completedFiles: UInt64 = 0

            for file in entry.files {
                let fileURL = try resolveFileURL(for: modelId, file: file)
                let (tmpDownloadURL, _) = try await URLSession.shared.download(from: fileURL)

                let destination = tempInstallURL.appendingPathComponent(file.path)
                let destinationDir = destination.deletingLastPathComponent()
                try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)

                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.moveItem(at: tmpDownloadURL, to: destination)

                if let expected = file.sha256, !expected.isEmpty {
                    let actual = try Self.sha256Hex(for: destination)
                    guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                        throw NSError(
                            domain: "ModelStore",
                            code: 1001,
                            userInfo: [NSLocalizedDescriptionKey: "Checksum mismatch for \(file.path)"]
                        )
                    }
                }

                if let declared = file.sizeBytes {
                    completedBytes += declared
                } else {
                    completedBytes += try Self.fileSize(of: destination)
                }
                completedFiles += 1

                if totalBytes > 0 {
                    progress[modelId] = min(0.99, Double(completedBytes) / Double(totalBytes))
                } else {
                    progress[modelId] = min(0.99, Double(completedFiles) / Double(max(entry.files.count, 1)))
                }
                postDownloadProgressChanged(modelId)
            }

            let finalURL = modelDirectory(for: modelId)
            if fm.fileExists(atPath: finalURL.path) {
                try fm.removeItem(at: finalURL)
            }
            try fm.moveItem(at: tempInstallURL, to: finalURL)

            states[modelId] = .installed
            progress[modelId] = 1.0
            lastErrors[modelId] = nil
            postInstallStateChanged(modelId)
            postDownloadProgressChanged(modelId)
            logger.info("Installed model \(modelId.rawValue, privacy: .public)")

        } catch {
            logger.error("Install failed for \(modelId.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            states[modelId] = .failed
            progress[modelId] = 0
            lastErrors[modelId] = error.localizedDescription
            postInstallStateChanged(modelId)
            postDownloadProgressChanged(modelId)

            if fm.fileExists(atPath: tempInstallURL.path) {
                try? fm.removeItem(at: tempInstallURL)
            }
        }

        installTasks[modelId] = nil
    }

    // MARK: - Manifest

    private func manifestEntry(for modelId: LocalModelID) async throws -> ModelManifestEntry {
        let manifest = try await loadManifest()
        guard let entry = manifest.models.first(where: { $0.id == modelId.rawValue }) else {
            throw NSError(
                domain: "ModelStore",
                code: 1002,
                userInfo: [NSLocalizedDescriptionKey: "Manifest entry missing for \(modelId.rawValue)"]
            )
        }
        return entry
    }

    private func loadManifest() async throws -> ModelManifest {
        if let cachedManifest {
            return cachedManifest
        }

        if !attemptedRemoteManifest {
            attemptedRemoteManifest = true
            if let remoteURL = URL(string: AppConstants.modelsManifestURL) {
                do {
                    let (data, response) = try await URLSession.shared.data(from: remoteURL)
                    guard let http = response as? HTTPURLResponse,
                          (200...299).contains(http.statusCode) else {
                        throw NSError(domain: "ModelStore", code: 1003,
                                      userInfo: [NSLocalizedDescriptionKey: "Remote manifest HTTP failure"])
                    }

                    let decoded = try JSONDecoder().decode(ModelManifest.self, from: data)
                    cachedManifest = decoded
                    logger.info("Loaded remote model manifest")
                    return decoded
                } catch {
                    logger.error("Remote manifest load failed: \(error.localizedDescription)")
                }
            }
        }

        let fallback = fallbackManifest()
        cachedManifest = fallback
        logger.info("Using fallback model manifest")
        return fallback
    }

    private func fallbackManifest() -> ModelManifest {
        func file(_ path: String) -> ModelManifestFile {
            ModelManifestFile(path: path, url: nil, sha256: nil, sizeBytes: nil)
        }

        let opusFiles = [
            file("model_profile.json"),
            file("opus-mt-en-ru/config.json"),
            file("opus-mt-en-ru/model.bin"),
            file("opus-mt-en-ru/shared_vocabulary.json"),
            file("opus-mt-en-ru/source.spm"),
            file("opus-mt-en-ru/target.spm"),
            file("opus-mt-ru-en/config.json"),
            file("opus-mt-ru-en/model.bin"),
            file("opus-mt-ru-en/shared_vocabulary.json"),
            file("opus-mt-ru-en/source.spm"),
            file("opus-mt-ru-en/target.spm"),
        ]

        let opusBigFiles = [
            file("model_profile.json"),
            file("opus-mt-en-zle/config.json"),
            file("opus-mt-en-zle/model.bin"),
            file("opus-mt-en-zle/shared_vocabulary.json"),
            file("opus-mt-en-zle/source.spm"),
            file("opus-mt-en-zle/target.spm"),
            file("opus-mt-zle-en/config.json"),
            file("opus-mt-zle-en/model.bin"),
            file("opus-mt-zle-en/shared_vocabulary.json"),
            file("opus-mt-zle-en/source.spm"),
            file("opus-mt-zle-en/target.spm"),
        ]

        let nllbFiles = [
            file("model_profile.json"),
            file("config.json"),
            file("generation_config.json"),
            file("model.bin"),
            file("shared_vocabulary.json"),
            file("sentencepiece.bpe.model"),
        ]

        return ModelManifest(schemaVersion: 1, models: [
            ModelManifestEntry(id: LocalModelID.opusBase.rawValue,
                               family: LocalModelFamily.opus.rawValue,
                               version: "1",
                               files: opusFiles),
            ModelManifestEntry(id: LocalModelID.opusBig.rawValue,
                               family: LocalModelFamily.opus.rawValue,
                               version: "1",
                               files: opusBigFiles),
            ModelManifestEntry(id: LocalModelID.nllb13b.rawValue,
                               family: LocalModelFamily.nllb.rawValue,
                               version: "1",
                               files: nllbFiles),
            ModelManifestEntry(id: LocalModelID.nllb33b.rawValue,
                               family: LocalModelFamily.nllb.rawValue,
                               version: "1",
                               files: nllbFiles),
        ])
    }

    // MARK: - Filesystem

    private func modelDirectory(for modelId: LocalModelID) -> URL {
        modelsRootURL.appendingPathComponent(modelId.rawValue, isDirectory: true)
    }

    private func isModelInstalledOnDisk(_ modelId: LocalModelID) -> Bool {
        let dir = modelDirectory(for: modelId)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }

        switch modelId.family {
        case .opus:
            let hasBasePair = fm.fileExists(atPath: dir.appendingPathComponent("opus-mt-en-ru/model.bin").path)
                && fm.fileExists(atPath: dir.appendingPathComponent("opus-mt-ru-en/model.bin").path)
            let hasBigPair = fm.fileExists(atPath: dir.appendingPathComponent("opus-mt-en-zle/model.bin").path)
                && fm.fileExists(atPath: dir.appendingPathComponent("opus-mt-zle-en/model.bin").path)
            return hasBasePair || hasBigPair
        case .nllb:
            return fm.fileExists(atPath: dir.appendingPathComponent("model.bin").path)
                && fm.fileExists(atPath: dir.appendingPathComponent("sentencepiece.bpe.model").path)
        }
    }

    private func resolveFileURL(for modelId: LocalModelID, file: ModelManifestFile) throws -> URL {
        if let explicit = file.url, let url = URL(string: explicit) {
            return url
        }

        guard let base = URL(string: "https://huggingface.co/grantr-code/translateanywhere-models/resolve/main") else {
            throw NSError(domain: "ModelStore", code: 1004,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid fallback model base URL"])
        }

        // Keep each model under its own directory in the artifact repo.
        return base
            .appendingPathComponent(modelId.rawValue)
            .appendingPathComponent(file.path)
    }

    private static func fileSize(of fileURL: URL) throws -> UInt64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let size = attrs[.size] as? NSNumber else {
            return 0
        }
        return size.uint64Value
    }

    private static func sha256Hex(for fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty {
                break
            }
            hasher.update(data: chunk)
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Notifications

    private func postInstallStateChanged(_ modelId: LocalModelID) {
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .modelInstallStateChanged,
                object: nil,
                userInfo: ["modelId": modelId.rawValue]
            )
        }
    }

    private func postDownloadProgressChanged(_ modelId: LocalModelID) {
        let value = progress[modelId] ?? 0
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .modelDownloadProgressChanged,
                object: nil,
                userInfo: [
                    "modelId": modelId.rawValue,
                    "progress": value,
                ]
            )
        }
    }
}
