/*
 * ClipboardManager.swift
 * TranslateAnywhere
 *
 * Saves, restores, and manipulates the system pasteboard (clipboard).
 * Preserves ALL pasteboard item types (images, RTF, files, etc.), not
 * just plain strings, so that user clipboard contents survive the
 * capture/replace cycle.
 */

import AppKit
import os.log

final class ClipboardManager {

    // MARK: - Logger

    private let logger = Logger(
        subsystem: AppConstants.bundleIdentifier,
        category: "clipboard"
    )

    // MARK: - Types

    /// Represents the data for a single pasteboard item across every type it provides.
    struct PasteboardItemData {
        let types: [NSPasteboard.PasteboardType]
        let dataByType: [NSPasteboard.PasteboardType: Data]
    }

    /// A snapshot of the entire general pasteboard that can be restored later.
    struct SavedState {
        let items: [PasteboardItemData]
        let changeCount: Int
    }

    // MARK: - Public API

    /// Takes a complete snapshot of the general pasteboard.
    func save() -> SavedState {
        let pasteboard = NSPasteboard.general
        var items: [PasteboardItemData] = []

        if let pbItems = pasteboard.pasteboardItems {
            for item in pbItems {
                var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
                let types = item.types
                for type in types {
                    if let data = item.data(forType: type) {
                        dataByType[type] = data
                    }
                }
                items.append(PasteboardItemData(types: types, dataByType: dataByType))
            }
        }

        logger.debug("Saved pasteboard state: \(items.count) items")
        return SavedState(items: items, changeCount: pasteboard.changeCount)
    }

    /// Restores the general pasteboard from a previously saved snapshot.
    func restore(_ state: SavedState) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        var newItems: [NSPasteboardItem] = []
        for savedItem in state.items {
            let item = NSPasteboardItem()
            for type in savedItem.types {
                if let data = savedItem.dataByType[type] {
                    item.setData(data, forType: type)
                }
            }
            newItems.append(item)
        }

        if !newItems.isEmpty {
            pasteboard.writeObjects(newItems)
        }
        logger.debug("Restored pasteboard state: \(newItems.count) items")
    }

    /// Replaces the pasteboard contents with a single plain-text string.
    func setPlainText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        logger.debug("Set pasteboard to plain text (\(text.count) chars)")
    }
}
