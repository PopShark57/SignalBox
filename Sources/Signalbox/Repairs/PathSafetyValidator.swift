import Darwin
import Foundation

enum PathSafetyError: LocalizedError, Equatable, Sendable {
    case notAFileURL(String)
    case nonAbsolutePath(String)
    case traversalComponent(String)
    case outsideAllowedRoot(path: String, root: String)
    case sourceIsAllowedRoot(String)
    case symbolicLink(String)
    case unexpectedLeaf(String)
    case unavailable(String)
    case notDirectory(String)

    var errorDescription: String? {
        switch self {
        case .notAFileURL(let path): return "Not a local file URL: \(path)"
        case .nonAbsolutePath(let path): return "The path is not absolute: \(path)"
        case .traversalComponent(let path): return "The path contains a traversal component: \(path)"
        case .outsideAllowedRoot(let path, let root): return "\(path) is outside the allowed root \(root)."
        case .sourceIsAllowedRoot(let path): return "The allowed root itself cannot be moved: \(path)"
        case .symbolicLink(let path): return "Symbolic links are not accepted: \(path)"
        case .unexpectedLeaf(let name): return "The directory name is not in the audited cache list: \(name)"
        case .unavailable(let path): return "The path is unavailable: \(path)"
        case .notDirectory(let path): return "The cache source is not a directory: \(path)"
        }
    }
}

struct ValidatedRepairPath: Hashable, Sendable {
    let sourceURL: URL
    let allowedRootURL: URL
}

struct FileSystemMetadataReader: Sendable {
    static func metadata(at url: URL) throws -> FileMetadata {
        var value = Darwin.stat()
        guard Darwin.lstat(url.path, &value) == 0 else {
            throw PathSafetyError.unavailable("\(url.path): \(posixMessage())")
        }
        return FileMetadata(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            mode: UInt32(value.st_mode),
            size: Int64(value.st_size),
            modificationSeconds: Int64(value.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(value.st_mtimespec.tv_nsec),
            isDirectory: (value.st_mode & S_IFMT) == S_IFDIR
        )
    }

    static func metadataIfPresent(at url: URL) throws -> FileMetadata? {
        var value = Darwin.stat()
        if Darwin.lstat(url.path, &value) == 0 {
            return FileMetadata(
                device: UInt64(value.st_dev),
                inode: UInt64(value.st_ino),
                mode: UInt32(value.st_mode),
                size: Int64(value.st_size),
                modificationSeconds: Int64(value.st_mtimespec.tv_sec),
                modificationNanoseconds: Int64(value.st_mtimespec.tv_nsec),
                isDirectory: (value.st_mode & S_IFMT) == S_IFDIR
            )
        }
        if errno == ENOENT || errno == ENOTDIR { return nil }
        throw PathSafetyError.unavailable("\(url.path): \(posixMessage())")
    }

    static func isSymbolicLink(at url: URL) throws -> Bool {
        var value = Darwin.stat()
        if Darwin.lstat(url.path, &value) == 0 {
            return (value.st_mode & S_IFMT) == S_IFLNK
        }
        if errno == ENOENT || errno == ENOTDIR { return false }
        throw PathSafetyError.unavailable("\(url.path): \(posixMessage())")
    }

    static func directorySummary(at url: URL) throws -> (fileCount: Int, byteCount: Int64) {
        let metadata = try metadata(at: url)
        guard metadata.isDirectory else { return (1, max(0, metadata.size)) }
        return try summarizeDirectory(at: url)
    }

    private static func summarizeDirectory(at url: URL) throws -> (fileCount: Int, byteCount: Int64) {
        let children = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        )
        var fileCount = 0
        var byteCount: Int64 = 0
        for child in children {
            if try isSymbolicLink(at: child) {
                throw PathSafetyError.symbolicLink(child.path)
            }
            let childMetadata = try metadata(at: child)
            if childMetadata.isDirectory {
                let nested = try summarizeDirectory(at: child)
                fileCount += nested.fileCount
                byteCount += nested.byteCount
            } else {
                fileCount += 1
                byteCount += max(0, childMetadata.size)
            }
        }
        return (fileCount, byteCount)
    }

    private static func posixMessage() -> String {
        String(cString: strerror(errno))
    }
}

struct PathSafetyValidator: Sendable {
    func validate(
        source sourceURL: URL,
        inside allowedRootURL: URL,
        allowedLeafNames: Set<String>? = nil,
        requireExistingDirectory: Bool = false
    ) throws -> ValidatedRepairPath {
        try validateBasicURL(sourceURL)
        try validateBasicURL(allowedRootURL)

        let sourceLexical = sourceURL.standardizedFileURL
        let rootLexical = allowedRootURL.standardizedFileURL
        if try FileSystemMetadataReader.isSymbolicLink(at: rootLexical) {
            throw PathSafetyError.symbolicLink(rootLexical.path)
        }

        let canonicalRoot = rootLexical.resolvingSymlinksInPath().standardizedFileURL
        let rootLexicalComponents = rootLexical.pathComponents
        let sourceLexicalComponents = sourceLexical.pathComponents
        let canonicalRootComponents = canonicalRoot.pathComponents

        let relativeComponents: ArraySlice<String>
        if hasComponentPrefix(sourceLexicalComponents, prefix: rootLexicalComponents) {
            relativeComponents = sourceLexicalComponents.dropFirst(rootLexicalComponents.count)
        } else {
            let resolvedSourceComponents = sourceLexical.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            guard hasComponentPrefix(resolvedSourceComponents, prefix: canonicalRootComponents) else {
                throw PathSafetyError.outsideAllowedRoot(path: sourceLexical.path, root: canonicalRoot.path)
            }
            relativeComponents = resolvedSourceComponents.dropFirst(canonicalRootComponents.count)
        }

        guard !relativeComponents.isEmpty else {
            throw PathSafetyError.sourceIsAllowedRoot(sourceLexical.path)
        }
        if let allowedLeafNames, !allowedLeafNames.contains(relativeComponents.last!) {
            throw PathSafetyError.unexpectedLeaf(relativeComponents.last!)
        }

        var canonicalSource = canonicalRoot
        for component in relativeComponents {
            canonicalSource.appendPathComponent(component, isDirectory: false)
            if try FileSystemMetadataReader.isSymbolicLink(at: canonicalSource) {
                throw PathSafetyError.symbolicLink(canonicalSource.path)
            }
        }
        canonicalSource = canonicalSource.standardizedFileURL

        let resolvedSource = canonicalSource.resolvingSymlinksInPath().standardizedFileURL
        guard hasComponentPrefix(resolvedSource.pathComponents, prefix: canonicalRootComponents) else {
            throw PathSafetyError.outsideAllowedRoot(path: resolvedSource.path, root: canonicalRoot.path)
        }

        if requireExistingDirectory {
            guard let metadata = try FileSystemMetadataReader.metadataIfPresent(at: canonicalSource) else {
                throw PathSafetyError.unavailable(canonicalSource.path)
            }
            guard metadata.isDirectory else { throw PathSafetyError.notDirectory(canonicalSource.path) }
        }
        return ValidatedRepairPath(sourceURL: canonicalSource, allowedRootURL: canonicalRoot)
    }

    private func validateBasicURL(_ url: URL) throws {
        guard url.isFileURL else { throw PathSafetyError.notAFileURL(url.absoluteString) }
        guard url.path.hasPrefix("/") else { throw PathSafetyError.nonAbsolutePath(url.path) }
        guard !url.path.utf8.contains(0) else { throw PathSafetyError.traversalComponent(url.path) }
        guard !url.pathComponents.contains("..") else {
            throw PathSafetyError.traversalComponent(url.path)
        }
    }

    private func hasComponentPrefix(_ path: [String], prefix: [String]) -> Bool {
        path.count >= prefix.count && Array(path.prefix(prefix.count)) == prefix
    }
}
