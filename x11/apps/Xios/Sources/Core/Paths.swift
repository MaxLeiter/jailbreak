import Foundation

enum XiosRuntimePaths {
    static func trimTrailingSlash(_ path: String) -> String {
        var out = path
        while out.count > 1 && out.hasSuffix("/") {
            out.removeLast()
        }
        return out
    }

    static var runtimeTmp: String {
        if let tmp = ProcessInfo.processInfo.environment["XIOS_RUNTIME_TMP"], !tmp.isEmpty {
            return trimTrailingSlash(tmp)
        }
        if let root = ProcessInfo.processInfo.environment["XIOS_PREFIX"], !root.isEmpty {
            let trimmed = trimTrailingSlash(root)
            return (trimmed == "/" ? "" : trimmed) + "/tmp"
        }
        if FileManager.default.fileExists(atPath: "/var/jb/usr") {
            return "/var/jb/tmp"
        }
        return "/var/tmp"
    }

    static var jbroot: String {
        if let root = ProcessInfo.processInfo.environment["XIOS_PREFIX"], !root.isEmpty {
            let trimmed = trimTrailingSlash(root)
            return trimmed == "/" ? "" : trimmed
        }
        if FileManager.default.fileExists(atPath: "/var/jb/usr") {
            return "/var/jb"
        }
        return ""
    }

    static func join(_ dir: String, _ name: String) -> String {
        dir == "/" ? "/" + name : dir + "/" + name
    }

    static func tmp(_ name: String) -> String {
        join(runtimeTmp, name)
    }

    static func prefixed(_ suffix: String) -> String {
        jbroot.isEmpty ? suffix : jbroot + suffix
    }

    static func tmpCandidates(_ name: String) -> [String] {
        var paths: [String] = []
        if let tmp = ProcessInfo.processInfo.environment["XIOS_RUNTIME_TMP"], !tmp.isEmpty {
            paths.append(join(trimTrailingSlash(tmp), name))
        }
        paths.append("/var/jb/tmp/" + name)
        paths.append("/var/tmp/" + name)
        return Array(NSOrderedSet(array: paths)) as? [String] ?? paths
    }

    static func firstExisting(_ name: String) -> String {
        tmpCandidates(name).first { FileManager.default.fileExists(atPath: $0) } ?? tmp(name)
    }
}
