// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

// Sonoma+ Index.plist + kill WallpaperAgent = Show on all Spaces
// (setDesktopImageURL alone only hits the current Space)
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

    @discardableResult
    static func setImageOnAllSpaces(_ imageURL: URL) -> Bool {
        let url = imageURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let index = indexURL
        guard FileManager.default.fileExists(atPath: index.path) else { return false }

        let data: Data
        do {
            data = try Data(contentsOf: index)
        } catch {
            return false
        }
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard var root = try? PropertyListSerialization.propertyList(
            from: data, options: [.mutableContainers], format: &format
        ) as? [String: Any]
        else { return false }

        guard WallpaperSupport.patchStoreRoot(&root, imageURL: url) else { return false }

        let backup = index.deletingLastPathComponent()
            .appendingPathComponent("Index.plist.vorssaint-bak", isDirectory: false)
        do {
            if FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.removeItem(at: backup)
            }
            try FileManager.default.copyItem(at: index, to: backup)
        } catch {
            return false
        }
        guard FileManager.default.fileExists(atPath: backup.path) else { return false }

        guard let written = try? PropertyListSerialization.data(
            fromPropertyList: root, format: .binary, options: 0
        ) else { return false }

        do {
            try written.write(to: index, options: .atomic)
        } catch {
            return false
        }

        // agent keeps the old tree until restarted
        _ = Shell.run("/usr/bin/killall", ["WallpaperAgent"])
        return true
    }
}
