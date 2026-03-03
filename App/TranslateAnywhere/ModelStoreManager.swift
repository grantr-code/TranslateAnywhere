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
import Security

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

private enum ModelStoreError: LocalizedError {
    case tokenMissing
    case invalidManifestURL
    case invalidModelBaseURL
    case manifestHttpError(status: Int)
    case manifestDecodeFailed
    case manifestValidationFailed(reason: String)
    case manifestEntryMissing(modelId: String)
    case downloadHttpError(status: Int, path: String)
    case invalidHttpResponse(path: String)
    case requiredFileMissing(path: String)
    case requiredFileSizeMissing(path: String)
    case requiredFileChecksumMissing(path: String)
    case fileSizeMismatch(path: String, expected: UInt64, actual: UInt64)
    case checksumMismatch(path: String)
    case keychainError(message: String)

    var errorDescription: String? {
        switch self {
        case .tokenMissing:
            return "Hugging Face token required. Configure it from Models > Configure Hugging Face Token…"
        case .invalidManifestURL:
            return "Invalid remote manifest URL."
        case .invalidModelBaseURL:
            return "Invalid model artifact base URL."
        case .manifestHttpError(let status):
            if status == 401 || status == 403 {
                return "Hugging Face authentication failed (HTTP \(status)). Check your token permissions."
            }
            return "Manifest download failed (HTTP \(status))."
        case .manifestDecodeFailed:
            return "Manifest format is invalid."
        case .manifestValidationFailed(let reason):
            return "Manifest is missing required metadata: \(reason)"
        case .manifestEntryMissing(let modelId):
            return "Manifest entry missing for model \(modelId)."
        case .downloadHttpError(let status, let path):
            if status == 401 || status == 403 {
                return "Authentication failed while downloading \(path) (HTTP \(status))."
            }
            return "Download failed for \(path) (HTTP \(status))."
        case .invalidHttpResponse(let path):
            return "Download returned invalid response for \(path)."
        case .requiredFileMissing(let path):
            return "Installed model is incomplete: missing \(path)."
        case .requiredFileSizeMissing(let path):
            return "Manifest missing size for \(path)."
        case .requiredFileChecksumMissing(let path):
            return "Manifest missing checksum for \(path)."
        case .fileSizeMismatch(let path, let expected, let actual):
            return "File size mismatch for \(path) (expected \(expected), got \(actual))."
        case .checksumMismatch(let path):
            return "Checksum mismatch for \(path)."
        case .keychainError(let message):
            return "Could not access Keychain: \(message)"
        }
    }
}

private enum HuggingFaceTokenStore {
    private static let service = "com.translateanywhere.app"
    private static let account = "huggingface_read_token"

    static func loadToken() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            return nil
        }
        guard let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func saveToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ModelStoreError.tokenMissing
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw ModelStoreError.keychainError(message: "Token encoding failed.")
        }

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]

        let attrs: [CFString: Any] = [
            kSecValueData: data,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus == errSecItemNotFound {
            var add = query
            add[kSecValueData] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw ModelStoreError.keychainError(message: keychainMessage(for: addStatus))
            }
            return
        }

        throw ModelStoreError.keychainError(message: keychainMessage(for: updateStatus))
    }

    static func clearToken() throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ModelStoreError.keychainError(message: keychainMessage(for: status))
        }
    }

    private static func keychainMessage(for status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
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
    private let manifestCacheURL: URL

    private init() {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(AppConstants.appName, isDirectory: true)
        self.appSupportURL = base
        self.modelsRootURL = base.appendingPathComponent("models", isDirectory: true)
        self.downloadsRootURL = base.appendingPathComponent("downloads", isDirectory: true)
        self.manifestCacheURL = base.appendingPathComponent("manifest-v1.json", isDirectory: false)

        do {
            try fm.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
            try fm.createDirectory(at: modelsRootURL, withIntermediateDirectories: true)
            try fm.createDirectory(at: downloadsRootURL, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create model storage directories: \(error.localizedDescription, privacy: .public)")
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

    func refreshInstalledStates() async {
        let manifest = await loadManifestForValidation()

        for id in LocalModelID.allCases {
            let current = states[id] ?? .notInstalled
            if current == .downloading {
                continue
            }

            if let entry = manifestEntry(for: id, in: manifest) {
                switch validateInstalledModel(id, entry: entry) {
                case .success:
                    states[id] = .installed
                    progress[id] = 1.0
                    lastErrors[id] = nil
                case .failure(let error):
                    if modelDirectoryExists(id) {
                        states[id] = .failed
                        progress[id] = 0
                        lastErrors[id] = humanReadableError(error)
                    } else {
                        states[id] = .notInstalled
                        progress[id] = 0
                        lastErrors[id] = nil
                    }
                }
            } else if modelDirectoryExists(id) {
                states[id] = .failed
                progress[id] = 0
                lastErrors[id] = "Model files exist but cannot be validated. Configure Hugging Face token and retry."
            } else {
                states[id] = .notInstalled
                progress[id] = 0
                lastErrors[id] = nil
            }

            postInstallStateChanged(id)
        }
    }

    func hasAnyInstalledModels() -> Bool {
        LocalModelID.allCases.contains(where: { states[$0] == .installed })
    }

    func isInstalled(_ modelId: LocalModelID) -> Bool {
        states[modelId] == .installed
    }

    func installedModelDirectory(for modelId: LocalModelID) -> String? {
        guard states[modelId] == .installed else {
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
        for id in LocalModelID.allCases where states[id] != .installed {
            installModel(id)
        }
    }

    @discardableResult
    func installModelAndWait(_ modelId: LocalModelID) async -> Bool {
        installModel(modelId)
        if let task = installTasks[modelId] {
            await task.value
        }
        return states[modelId] == .installed
    }

    func hasConfiguredHuggingFaceToken() -> Bool {
        !(HuggingFaceTokenStore.loadToken() ?? "").isEmpty
    }

    @discardableResult
    func saveHuggingFaceToken(_ token: String) async -> String? {
        do {
            try HuggingFaceTokenStore.saveToken(token)
            attemptedRemoteManifest = false
            cachedManifest = nil
            _ = try await fetchRemoteManifest()
            await refreshInstalledStates()
            return nil
        } catch {
            await refreshInstalledStates()
            return humanReadableError(error)
        }
    }

    @discardableResult
    func clearHuggingFaceToken() async -> String? {
        do {
            try HuggingFaceTokenStore.clearToken()
            attemptedRemoteManifest = false
            cachedManifest = nil
            await refreshInstalledStates()
            return nil
        } catch {
            return humanReadableError(error)
        }
    }

    func invalidateManifestCache() {
        attemptedRemoteManifest = false
        cachedManifest = nil
    }

    // MARK: - Install Logic

    private func performInstall(_ modelId: LocalModelID) async {
        states[modelId] = .downloading
        progress[modelId] = 0
        lastErrors[modelId] = nil
        postInstallStateChanged(modelId)
        postDownloadProgressChanged(modelId)

        do {
            let manifest = try await loadManifest(requireRemote: true)
            guard let entry = manifestEntry(for: modelId, in: manifest) else {
                throw ModelStoreError.manifestEntryMissing(modelId: modelId.rawValue)
            }
            let token = currentHuggingFaceToken()

            try purgeInvalidExistingModelIfNeeded(modelId, entry: entry)

            do {
                try await installModelFiles(modelId, entry: entry, token: token)
            } catch {
                if shouldRetryAfterPurge(error: error) {
                    logger.warning("Install integrity failure for \(modelId.rawValue, privacy: .public); purging and retrying once")
                    try? purgeModelDirectory(modelId)
                    try await installModelFiles(modelId, entry: entry, token: token)
                } else {
                    throw error
                }
            }

            try validateInstalledModelStrict(modelId, entry: entry)

            states[modelId] = .installed
            progress[modelId] = 1.0
            lastErrors[modelId] = nil
            postInstallStateChanged(modelId)
            postDownloadProgressChanged(modelId)
            logger.info("Installed model \(modelId.rawValue, privacy: .public)")

        } catch {
            logger.error("Install failed for \(modelId.rawValue, privacy: .public): \(self.humanReadableError(error), privacy: .public)")
            states[modelId] = .failed
            progress[modelId] = 0
            lastErrors[modelId] = humanReadableError(error)
            postInstallStateChanged(modelId)
            postDownloadProgressChanged(modelId)
        }

        installTasks[modelId] = nil
    }

    private func installModelFiles(_ modelId: LocalModelID,
                                   entry: ModelManifestEntry,
                                   token: String?) async throws {
        let tempInstallURL = downloadsRootURL
            .appendingPathComponent("\(modelId.rawValue)-\(UUID().uuidString)", isDirectory: true)

        if fm.fileExists(atPath: tempInstallURL.path) {
            try? fm.removeItem(at: tempInstallURL)
        }
        try fm.createDirectory(at: tempInstallURL, withIntermediateDirectories: true)

        defer {
            if fm.fileExists(atPath: tempInstallURL.path) {
                try? fm.removeItem(at: tempInstallURL)
            }
        }

        var totalBytes: UInt64 = 0
        for file in entry.files {
            guard let size = file.sizeBytes, size > 0 else {
                throw ModelStoreError.requiredFileSizeMissing(path: file.path)
            }
            guard let sha = file.sha256, !sha.isEmpty else {
                throw ModelStoreError.requiredFileChecksumMissing(path: file.path)
            }
            totalBytes += size
        }

        var completedBytes: UInt64 = 0

        for file in entry.files {
            let fileURL = try resolveFileURL(for: modelId, file: file)
            let (tmpDownloadURL, response) = try await downloadFile(from: fileURL, token: token, path: file.path)

            let destination = tempInstallURL.appendingPathComponent(file.path)
            let destinationDir = destination.deletingLastPathComponent()
            try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)

            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: tmpDownloadURL, to: destination)

            try validateDownloadedFile(destination, manifestFile: file)

            completedBytes += file.sizeBytes ?? 0
            if totalBytes > 0 {
                progress[modelId] = min(0.99, Double(completedBytes) / Double(totalBytes))
            }
            postDownloadProgressChanged(modelId)

            logger.info("Downloaded \(file.path, privacy: .public) status=\(response.statusCode)")
        }

        let finalURL = modelDirectory(for: modelId)
        if fm.fileExists(atPath: finalURL.path) {
            try fm.removeItem(at: finalURL)
        }
        try fm.moveItem(at: tempInstallURL, to: finalURL)
    }

    private func downloadFile(from url: URL,
                              token: String?,
                              path: String) async throws -> (URL, HTTPURLResponse) {
        var request = URLRequest(url: url)
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (tmpDownloadURL, response) = try await URLSession.shared.download(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw ModelStoreError.invalidHttpResponse(path: path)
        }

        guard (200...299).contains(http.statusCode) else {
            throw ModelStoreError.downloadHttpError(status: http.statusCode, path: path)
        }

        return (tmpDownloadURL, http)
    }

    private func validateDownloadedFile(_ fileURL: URL, manifestFile: ModelManifestFile) throws {
        guard let expectedSize = manifestFile.sizeBytes else {
            throw ModelStoreError.requiredFileSizeMissing(path: manifestFile.path)
        }
        let actualSize = try Self.fileSize(of: fileURL)
        guard actualSize == expectedSize else {
            throw ModelStoreError.fileSizeMismatch(path: manifestFile.path,
                                                   expected: expectedSize,
                                                   actual: actualSize)
        }

        guard let expectedSHA = manifestFile.sha256, !expectedSHA.isEmpty else {
            throw ModelStoreError.requiredFileChecksumMissing(path: manifestFile.path)
        }
        let actualSHA = try Self.sha256Hex(for: fileURL)
        guard actualSHA.caseInsensitiveCompare(expectedSHA) == .orderedSame else {
            throw ModelStoreError.checksumMismatch(path: manifestFile.path)
        }
    }

    // MARK: - Manifest

    private func manifestEntry(for modelId: LocalModelID, in manifest: ModelManifest?) -> ModelManifestEntry? {
        manifest?.models.first(where: { $0.id == modelId.rawValue })
    }

    private func loadManifestForValidation() async -> ModelManifest? {
        if let cachedManifest {
            return cachedManifest
        }

        if let disk = readManifestFromDisk() {
            cachedManifest = disk
            return disk
        }

        if !attemptedRemoteManifest, hasConfiguredHuggingFaceToken() {
            attemptedRemoteManifest = true
            do {
                return try await fetchRemoteManifest()
            } catch {
                logger.error("Remote manifest validation fetch failed: \(self.humanReadableError(error), privacy: .public)")
            }
        }

        return nil
    }

    private func loadManifest(requireRemote: Bool) async throws -> ModelManifest {
        if let cachedManifest {
            return cachedManifest
        }

        if !requireRemote, let disk = readManifestFromDisk() {
            cachedManifest = disk
            return disk
        }

        return try await fetchRemoteManifest()
    }

    private func fetchRemoteManifest() async throws -> ModelManifest {
        guard let remoteURL = URL(string: AppConstants.modelsManifestURL) else {
            throw ModelStoreError.invalidManifestURL
        }

        var request = URLRequest(url: remoteURL)
        if let token = currentHuggingFaceToken(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ModelStoreError.invalidHttpResponse(path: "manifest-v1.json")
        }
        guard (200...299).contains(http.statusCode) else {
            throw ModelStoreError.manifestHttpError(status: http.statusCode)
        }

        let decoded: ModelManifest
        do {
            decoded = try JSONDecoder().decode(ModelManifest.self, from: data)
        } catch {
            throw ModelStoreError.manifestDecodeFailed
        }

        try validateManifest(decoded)
        cachedManifest = decoded
        attemptedRemoteManifest = true

        do {
            try data.write(to: manifestCacheURL, options: .atomic)
        } catch {
            logger.error("Failed to write manifest cache: \(error.localizedDescription, privacy: .public)")
        }

        logger.info("Loaded remote model manifest")
        return decoded
    }

    private func readManifestFromDisk() -> ModelManifest? {
        guard fm.fileExists(atPath: manifestCacheURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: manifestCacheURL)
            let manifest = try JSONDecoder().decode(ModelManifest.self, from: data)
            try validateManifest(manifest)
            return manifest
        } catch {
            logger.error("Ignoring invalid cached manifest: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func validateManifest(_ manifest: ModelManifest) throws {
        guard manifest.schemaVersion == 1 else {
            throw ModelStoreError.manifestValidationFailed(reason: "Unsupported schema_version \(manifest.schemaVersion)")
        }

        for model in LocalModelID.allCases {
            guard let entry = manifest.models.first(where: { $0.id == model.rawValue }) else {
                throw ModelStoreError.manifestValidationFailed(reason: "Missing model \(model.rawValue)")
            }
            if entry.files.isEmpty {
                throw ModelStoreError.manifestValidationFailed(reason: "\(model.rawValue) has no files")
            }
            for file in entry.files {
                guard let size = file.sizeBytes, size > 0 else {
                    throw ModelStoreError.manifestValidationFailed(reason: "\(model.rawValue)/\(file.path) missing size_bytes")
                }
                guard let sha = file.sha256, !sha.isEmpty else {
                    throw ModelStoreError.manifestValidationFailed(reason: "\(model.rawValue)/\(file.path) missing sha256")
                }
            }
        }
    }

    private func currentHuggingFaceToken() -> String? {
        let token = HuggingFaceTokenStore.loadToken()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return token.isEmpty ? nil : token
    }

    private func shouldRetryAfterPurge(error: Error) -> Bool {
        guard let err = error as? ModelStoreError else {
            return false
        }

        switch err {
        case .requiredFileMissing,
             .requiredFileSizeMissing,
             .requiredFileChecksumMissing,
             .fileSizeMismatch,
             .checksumMismatch:
            return true
        default:
            return false
        }
    }

    private func humanReadableError(_ error: Error) -> String {
        if let store = error as? ModelStoreError, let desc = store.errorDescription {
            return desc
        }
        return error.localizedDescription
    }

    // MARK: - Filesystem

    private func modelDirectory(for modelId: LocalModelID) -> URL {
        modelsRootURL.appendingPathComponent(modelId.rawValue, isDirectory: true)
    }

    private func modelDirectoryExists(_ modelId: LocalModelID) -> Bool {
        let dir = modelDirectory(for: modelId)
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func purgeModelDirectory(_ modelId: LocalModelID) throws {
        let dir = modelDirectory(for: modelId)
        if fm.fileExists(atPath: dir.path) {
            try fm.removeItem(at: dir)
        }
    }

    private func purgeInvalidExistingModelIfNeeded(_ modelId: LocalModelID, entry: ModelManifestEntry) throws {
        guard modelDirectoryExists(modelId) else {
            return
        }

        switch validateInstalledModel(modelId, entry: entry) {
        case .success:
            return
        case .failure(let error):
            logger.warning("Purging invalid existing model \(modelId.rawValue, privacy: .public): \(self.humanReadableError(error), privacy: .public)")
            try purgeModelDirectory(modelId)
        }
    }

    private func validateInstalledModel(_ modelId: LocalModelID, entry: ModelManifestEntry) -> Result<Void, Error> {
        let dir = modelDirectory(for: modelId)

        for file in entry.files {
            let fileURL = dir.appendingPathComponent(file.path)
            guard fm.fileExists(atPath: fileURL.path) else {
                return .failure(ModelStoreError.requiredFileMissing(path: file.path))
            }
            guard let expected = file.sizeBytes else {
                return .failure(ModelStoreError.requiredFileSizeMissing(path: file.path))
            }

            do {
                let actual = try Self.fileSize(of: fileURL)
                if actual != expected {
                    return .failure(ModelStoreError.fileSizeMismatch(path: file.path, expected: expected, actual: actual))
                }
            } catch {
                return .failure(error)
            }
        }

        return .success(())
    }

    private func validateInstalledModelStrict(_ modelId: LocalModelID, entry: ModelManifestEntry) throws {
        let dir = modelDirectory(for: modelId)
        for file in entry.files {
            let fileURL = dir.appendingPathComponent(file.path)
            guard fm.fileExists(atPath: fileURL.path) else {
                throw ModelStoreError.requiredFileMissing(path: file.path)
            }
            try validateDownloadedFile(fileURL, manifestFile: file)
        }
    }

    private func resolveFileURL(for modelId: LocalModelID, file: ModelManifestFile) throws -> URL {
        if let explicit = file.url, let url = URL(string: explicit) {
            return url
        }

        guard let base = URL(string: AppConstants.modelsArtifactsBaseURL) else {
            throw ModelStoreError.invalidModelBaseURL
        }

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
