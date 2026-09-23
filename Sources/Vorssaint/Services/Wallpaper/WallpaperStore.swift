// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

// Sonoma+ Index.plist + kill WallpaperAgent = Show on all Spaces
// (setDesktopImageURL alone only hits the current Space)
//
// Backup policy:
// - Index.plist.vorssaint-bak is a one-shot copy taken before the first apply-all
//   write. Later applies leave that file alone.
// - Feature uninstall does not delete the bak (Index may stay patched; bak is
//   the only pre-Vorssaint snapshot for manual recovery).
// - restoreOriginalIndex() copies bak over Index.plist, restarts WallpaperAgent,
//   then deletes the bak. Nothing calls that automatically today.
enum WallpaperStore {
    static var indexURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("com.apple.wallpaper", isDirectory: true)
            .appendingPathComponent("Store", isDirectory: true)
            .appendingPathComponent("Index.plist", isDirectory: false)
    }

    static var backupURL: URL {
        indexURL.deletingLastPathComponent()
            .appendingPathComponent("Index.plist.vorssaint-bak", isDirectory: false)
    }

    @discardableResult
    static func setImageOnAllSpaces(_ imageURL: URL,
                                    shouldContinue: () -> Bool = { true }) -> Bool {
        let url = imageURL.standardizedFileURL
        guard shouldContinue() else { return false }
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let index = indexURL
        guard FileManager.default.fileExists(atPath: index.path) else { return false }

        let data: Data
        do {
            data = try Data(contentsOf: index)
        } catch {
            return false
        }
        guard shouldContinue() else { return false }
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard var root = try? PropertyListSerialization.propertyList(
            from: data, options: [.mutableContainers], format: &format
        ) as? [String: Any]
        else { return false }

        guard WallpaperSupport.patchStoreRoot(&root, imageURL: url) else { return false }
        guard shouldContinue() else { return false }

        let backup = backupURL
        // keep the first pre-feature copy; never overwrite it with a later apply
        if !FileManager.default.fileExists(atPath: backup.path) {
            do {
                try FileManager.default.copyItem(at: index, to: backup)
            } catch {
                return false
            }
        }
        guard FileManager.default.fileExists(atPath: backup.path) else { return false }
        guard shouldContinue() else { return false }

        guard let written = try? PropertyListSerialization.data(
            fromPropertyList: root, format: .binary, options: 0
        ) else { return false }

        guard shouldContinue() else { return false }
        do {
            try written.write(to: index, options: .atomic)
        } catch {
            return false
        }

        guard shouldContinue() else { return false }
        // agent keeps the old tree until restarted
        _ = Shell.run("/usr/bin/killall", ["WallpaperAgent"])
        return true
    }

    // recovery only — replace Index with bak via temp, bounce agent, drop bak
    @discardableResult
    static func restoreOriginalIndex() -> Bool {
        let index = indexURL
        let backup = backupURL
        guard FileManager.default.fileExists(atPath: backup.path) else { return false }
        let temp = index.deletingLastPathComponent()
            .appendingPathComponent("Index.plist.vorssaint-restore", isDirectory: false)
        do {
            if FileManager.default.fileExists(atPath: temp.path) {
                try FileManager.default.removeItem(at: temp)
            }
            try FileManager.default.copyItem(at: backup, to: temp)
            _ = try FileManager.default.replaceItemAt(index, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
        _ = Shell.run("/usr/bin/killall", ["WallpaperAgent"])
        removeBackup()
        return true
    }

    static func removeBackup() {
        let backup = backupURL
        guard FileManager.default.fileExists(atPath: backup.path) else { return }
        try? FileManager.default.removeItem(at: backup)
    }
}
