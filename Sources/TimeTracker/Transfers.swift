import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Intra-app drag payload identifiers (declared in the bundle's Info.plist by build.sh).
    static let timeTrackerEntry = UTType(exportedAs: "com.almax.timetracker.entry")
    static let timeTrackerPin = UTType(exportedAs: "com.almax.timetracker.pin")
    static let timeTrackerFavorite = UTType(exportedAs: "com.almax.timetracker.favorite")
}

/// Dragged from a history row → dropped on the Pins area to create a pin.
struct EntryDrag: Codable, Transferable, Sendable {
    let projectID: UUID
    let note: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .timeTrackerEntry)
    }
}

/// Dragged from a pin → dropped on the main pane to unpin it.
struct PinDrag: Codable, Transferable, Sendable {
    let pinID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .timeTrackerPin)
    }
}

/// Dragged from a favorite → dropped on the main pane to remove it.
struct FavoriteDrag: Codable, Transferable, Sendable {
    let favoriteID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .timeTrackerFavorite)
    }
}
