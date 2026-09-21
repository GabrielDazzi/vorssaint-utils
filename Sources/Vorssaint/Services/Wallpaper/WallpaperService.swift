// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers

/// Apple stills + bookmarked own images. Apply-all hits WallpaperAgent's store.
final class WallpaperService: ObservableObject {
    static let shared = WallpaperService()

    @Published private(set) var entries: [WallpaperSupport.Entry] = []
    @Published private(set) var filter: WallpaperSupport.Filter = .all
    @Published private(set) var lastError: String?
    @Published private(set) var appliedPath: String?
    @Published private(set) var isLoading = false

    private var ownBookmarks: [Data] = []
    private var scopedURLs: [URL] = []
    private var openPanel: NSOpenPanel?
    // Apple catalog barely changes; keep after first scan to avoid tab hitch
    private var cachedApple: [WallpaperSupport.Entry]?
    private var refreshToken = UUID()

    private init() {
        loadBookmarks()
        loadFilter()
    }

    var isAvailable: Bool { AppFeature.wallpaper.isAvailable }

    var visibleEntries: [WallpaperSupport.Entry] {
        WallpaperSupport.filtered(entries, by: filter)
    }

    var applyAllDisplays: Bool {
        get {
            if UserDefaults.standard.object(forKey: DefaultsKey.wallpaperApplyAllDisplays) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: DefaultsKey.wallpaperApplyAllDisplays)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.wallpaperApplyAllDisplays)
            objectWillChange.send()
        }
    }

    func syncWithPreferences() {
        if !isAvailable {
            refreshToken = UUID()
            stopAccessing()
            cachedApple = nil
            WallpaperThumbnailCache.clear()
            entries = []
            lastError = nil
            appliedPath = nil
            isLoading = false
            return
        }
        // warm catalog before first open
        refresh(forceAppleRescan: false)
    }

    func suspend() {
        stopAccessing()
    }

    func setFilter(_ filter: WallpaperSupport.Filter) {
        self.filter = filter
        UserDefaults.standard.set(filter.rawValue, forKey: DefaultsKey.wallpaperFilter)
        // prefetch page 1 so filter switch does not hitch
        let firstPage = WallpaperSupport.pageSlice(
            WallpaperSupport.filtered(entries, by: filter), page: 1)
        WallpaperThumbnailCache.prefetch(firstPage.map(\.previewURL))
    }

    // scan off-main; publish when ready
    func refresh(forceAppleRescan: Bool = false) {
        guard isAvailable else {
            entries = []
            isLoading = false
            return
        }
        startAccessing()
        let roots = ownRoots()
        let appleCache = forceAppleRescan ? nil : cachedApple
        let token = UUID()
        refreshToken = token
        if entries.isEmpty {
            isLoading = true
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let apple = appleCache ?? WallpaperSupport.enumerateAppleEntries()
            var imageURLs: [URL] = []
            for root in roots {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) else {
                    continue
                }
                if isDir.boolValue {
                    imageURLs.append(contentsOf: WallpaperSupport.images(inFolder: root))
                } else if WallpaperSupport.isStillImageURL(root) {
                    imageURLs.append(root)
                }
            }
            let own = WallpaperSupport.ownEntries(from: imageURLs)
            let merged = WallpaperSupport.merge(apple: apple, own: own)
            // HEIC decode here, not on first filter flip
            WallpaperThumbnailCache.prefetchSync(apple.map(\.previewURL))
            WallpaperThumbnailCache.prefetchSync(own.map(\.previewURL))
            DispatchQueue.main.async {
                guard let self, self.refreshToken == token else { return }
                if appleCache == nil {
                    self.cachedApple = apple
                }
                self.entries = merged
                self.isLoading = false
            }
        }
    }

    func apply(_ entry: WallpaperSupport.Entry) {
        guard isAvailable else { return }
        lastError = nil
        let url = entry.imageURL.standardizedFileURL
        let chosen = targetScreens()
        guard !chosen.isEmpty else {
            lastError = FeatureStrings.wallpaper(L10n.shared.language).applyFailed
            return
        }

        // AppKit first (feels instant), then store for all Spaces
        let currentOK = setDesktopImage(url, on: chosen)
        if applyAllDisplays {
            let allOK = WallpaperStore.setImageOnAllSpaces(url)
            if allOK || currentOK {
                appliedPath = url.path
                if !allOK {
                    lastError = FeatureStrings.wallpaper(L10n.shared.language).applyFailed
                }
            } else {
                lastError = FeatureStrings.wallpaper(L10n.shared.language).applyFailed
            }
            return
        }

        if currentOK {
            appliedPath = url.path
        } else {
            lastError = FeatureStrings.wallpaper(L10n.shared.language).applyFailed
        }
    }

    private func targetScreens() -> [NSScreen] {
        if applyAllDisplays {
            return NSScreen.screens
        }
        if let screen = NSScreen.withMouse {
            return [screen]
        }
        return NSScreen.screens.first.map { [$0] } ?? []
    }

    // fill crop; clear same-URL first (macOS skips refresh otherwise)
    private func setDesktopImage(_ url: URL, on screens: [NSScreen]) -> Bool {
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true,
        ]
        var needsPause = false
        for screen in screens {
            if NSWorkspace.shared.desktopImageURL(for: screen)?.standardizedFileURL == url {
                do {
                    try NSWorkspace.shared.setDesktopImageURL(
                        URL(fileURLWithPath: ""), for: screen, options: [:])
                    needsPause = true
                } catch {
                    // still try the set below
                }
            }
        }
        if needsPause {
            Thread.sleep(forTimeInterval: 0.4)
        }
        var ok = true
        for screen in screens {
            do {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
            } catch {
                ok = false
            }
        }
        return ok
    }

    func addImages() {
        guard isAvailable, openPanel == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.message = FeatureStrings.wallpaper(L10n.shared.language).addImagePrompt
        present(panel) { [weak self] urls in
            self?.remember(urls: urls)
        }
    }

    func addFolder() {
        guard isAvailable, openPanel == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = FeatureStrings.wallpaper(L10n.shared.language).addFolderPrompt
        present(panel) { [weak self] urls in
            self?.remember(urls: urls)
        }
    }

    func openSystemWallpaperSettings() {
        guard let url = WallpaperSupport.systemWallpaperSettingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Bookmarks

    private func present(_ panel: NSOpenPanel, completion: @escaping ([URL]) -> Void) {
        openPanel = panel
        panel.begin { [weak self] response in
            guard let self else { return }
            self.openPanel = nil
            guard response == .OK else { return }
            completion(panel.urls)
        }
    }

    private func remember(urls: [URL]) {
        for url in urls {
            guard let data = try? url.bookmarkData(options: .withSecurityScope,
                                                   includingResourceValuesForKeys: nil,
                                                   relativeTo: nil)
            else { continue }
            if !ownBookmarks.contains(data) {
                ownBookmarks.append(data)
            }
        }
        persistBookmarks()
        refresh(forceAppleRescan: false)
    }

    private func loadBookmarks() {
        ownBookmarks = UserDefaults.standard.array(forKey: DefaultsKey.wallpaperOwnBookmarks) as? [Data]
            ?? []
    }

    private func persistBookmarks() {
        UserDefaults.standard.set(ownBookmarks, forKey: DefaultsKey.wallpaperOwnBookmarks)
    }

    private func loadFilter() {
        let raw = UserDefaults.standard.string(forKey: DefaultsKey.wallpaperFilter) ?? ""
        filter = WallpaperSupport.Filter(rawValue: raw) ?? .all
    }

    private func stopAccessing() {
        for url in scopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        scopedURLs.removeAll()
    }

    private func startAccessing() {
        stopAccessing()
        for data in ownBookmarks {
            guard let url = resolveBookmark(data) else { continue }
            if url.startAccessingSecurityScopedResource() {
                scopedURLs.append(url)
            }
        }
    }

    // bookmark roots only; folder walk is off-main
    private func ownRoots() -> [URL] {
        ownBookmarks.compactMap(resolveBookmark)
    }

    private func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: data,
                        options: [.withSecurityScope, .withoutUI],
                        relativeTo: nil,
                        bookmarkDataIsStale: &stale)
    }
}

// panel thumbs; process lifetime, cleared on uninstall
enum WallpaperThumbnailCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        return cache
    }()

    private static let prefetchQueue = DispatchQueue(
        label: "com.vorssaint.utils.wallpaper-thumbs",
        qos: .utility,
        attributes: .concurrent
    )

    static func image(for url: URL, maxPixel: Int = 160) -> NSImage? {
        cache.object(forKey: key(url, maxPixel))
    }

    static func store(_ image: NSImage, for url: URL, maxPixel: Int = 160) {
        cache.setObject(image, forKey: key(url, maxPixel))
    }

    static func clear() {
        cache.removeAllObjects()
    }

    static func prefetch(_ urls: [URL], maxPixel: Int = 160) {
        guard !urls.isEmpty else { return }
        prefetchQueue.async {
            prefetchSync(urls, maxPixel: maxPixel)
        }
    }

    // call from a background queue only
    static func prefetchSync(_ urls: [URL], maxPixel: Int = 160) {
        for url in urls {
            _ = loadSync(url: url, maxPixel: maxPixel)
        }
    }

    static func loadSync(url: URL, maxPixel: Int = 160) -> NSImage? {
        if let hit = image(for: url, maxPixel: maxPixel) { return hit }
        guard let cgImage = decodeCGThumbnail(url: url, maxPixel: maxPixel) else { return nil }
        let image = NSImage(cgImage: cgImage,
                            size: NSSize(width: cgImage.width, height: cgImage.height))
        store(image, for: url, maxPixel: maxPixel)
        return image
    }

    private static func decodeCGThumbnail(url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func key(_ url: URL, _ maxPixel: Int) -> NSString {
        "\(url.standardizedFileURL.path)#\(maxPixel)" as NSString
    }
}
