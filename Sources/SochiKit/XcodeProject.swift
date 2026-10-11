import Foundation

/// An `.xcodeproj` or `.xcworkspace` on disk.
public struct XcodeProject: Sendable, Equatable {
    public enum Kind: Sendable { case project, workspace }

    public let kind: Kind
    public let url: URL

    public init(kind: Kind, url: URL) {
        self.kind = kind
        self.url = url
    }

    public var name: String { url.deletingPathExtension().lastPathComponent }
    public var directory: URL { url.deletingLastPathComponent() }

    public var xcodebuildArguments: [String] {
        [kind == .workspace ? "-workspace" : "-project", url.path]
    }

    /// Resolves `path` (a directory or a project/workspace file) to a single project.
    /// In a directory, a workspace wins over a project since it usually wraps it (CocoaPods, SPM locals).
    public static func locate(_ path: String) throws -> XcodeProject {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let url = URL(fileURLWithPath: path, relativeTo: cwd).standardizedFileURL

        switch url.pathExtension {
        case "xcworkspace": return try existing(XcodeProject(kind: .workspace, url: url), path: path)
        case "xcodeproj": return try existing(XcodeProject(kind: .project, url: url), path: path)
        default: break
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SochiError.notFound(path)
        }

        let entries = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let workspaces = entries.filter { $0.pathExtension == "xcworkspace" }
        let projects = entries.filter { $0.pathExtension == "xcodeproj" }

        if workspaces.count == 1 { return XcodeProject(kind: .workspace, url: workspaces[0]) }
        if workspaces.count > 1 { throw SochiError.ambiguousProject(workspaces) }
        if projects.count == 1 { return XcodeProject(kind: .project, url: projects[0]) }
        if projects.count > 1 { throw SochiError.ambiguousProject(projects) }
        if entries.contains(where: { $0.lastPathComponent == "Package.swift" }) {
            throw SochiError.swiftPackageOnly(url)
        }
        throw SochiError.noProject(url)
    }

    private static func existing(_ project: XcodeProject, path: String) throws -> XcodeProject {
        guard FileManager.default.fileExists(atPath: project.url.path) else { throw SochiError.notFound(path) }
        return project
    }
}
