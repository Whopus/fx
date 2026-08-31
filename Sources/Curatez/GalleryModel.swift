import Foundation
import SwiftUI

enum GalleryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case saved = "Saved"
    case unsorted = "Unsorted"
    case trash = "Trash"

    var id: Self { self }
}

enum GallerySort: String, CaseIterable, Identifiable {
    case recent = "Most recent"
    case oldest = "Oldest first"
    case title = "Title A–Z"

    var id: Self { self }
}

enum ArtworkStyle: String, Codable {
    case block, bread, dark, seve, blue, cin, editorial, mono
    case capturedText, capturedLink, capturedVideo, capturedImage, browserSnapshot
}

struct GalleryItem: Identifiable, Hashable {
    let id: UUID
    var title: String
    var domain: String
    var imageURL: URL?
    var videoURL: URL?
    var aspectRatio: CGFloat
    var background: Color
    var style: ArtworkStyle
    var caption: String?
    var sourceURL: String?
    var durationSeconds: Double?
    var hasCustomCover: Bool
    var tags: [String]
    var itemDescription: String?
    var createdAt: Date
    var isSaved: Bool
    var isSorted: Bool
    var isTrashed: Bool

    init(
        id: UUID = UUID(),
        title: String,
        domain: String,
        imageURL: String? = nil,
        videoURL: String? = nil,
        aspectRatio: CGFloat,
        background: Color,
        style: ArtworkStyle,
        daysAgo: Double,
        caption: String? = nil,
        sourceURL: String? = nil,
        durationSeconds: Double? = nil,
        hasCustomCover: Bool = false,
        tags: [String] = [],
        itemDescription: String? = nil,
        createdAt: Date? = nil,
        isSaved: Bool = false,
        isSorted: Bool = false,
        isTrashed: Bool = false
    ) {
        self.id = id
        self.title = title
        self.domain = domain
        self.imageURL = imageURL.flatMap(URL.init(string:))
        self.videoURL = videoURL.flatMap(URL.init(string:))
        self.aspectRatio = aspectRatio
        self.background = background
        self.style = style
        self.caption = caption
        self.sourceURL = sourceURL
        self.durationSeconds = durationSeconds
        self.hasCustomCover = hasCustomCover
        self.tags = tags
        self.itemDescription = itemDescription
        self.createdAt = createdAt ?? Date().addingTimeInterval(-daysAgo * 86_400)
        self.isSaved = isSaved
        self.isSorted = isSorted
        self.isTrashed = isTrashed
    }
}

extension GalleryItem {
    init(
        capture: CaptureRecord,
        coverPreviewURL: URL? = nil,
        coverVideoURL: URL? = nil
    ) {
        let width = capture.pixelWidth ?? 4
        let height = capture.pixelHeight ?? 5
        let ratio = min(2.2, max(0.62, width / max(1, height)))
        let fallbackDomain = switch capture.kind {
        case .browserSnapshot: "Browser"
        case .video: "Local video"
        default: "Clipboard"
        }
        let domain = capture.sourceURL
            .flatMap(URL.init(string:))?.host ?? fallbackDomain
        let style: ArtworkStyle = switch capture.kind {
        case .text: .capturedText
        case .link: .capturedLink
        case .video: .capturedVideo
        case .image: .capturedImage
        case .browserSnapshot: .browserSnapshot
        }

        self.init(
            id: capture.id,
            title: capture.title,
            domain: domain,
            imageURL: coverPreviewURL?.absoluteString,
            videoURL: coverVideoURL?.absoluteString,
            aspectRatio: capture.kind == .text || capture.kind == .link ? 1.15 : ratio,
            background: capture.kind == .text || capture.kind == .link
                ? Color(red: 0.94, green: 0.93, blue: 0.89)
                : Color(red: 0.08, green: 0.08, blue: 0.08),
            style: style,
            daysAgo: 0,
            caption: capture.text,
            sourceURL: capture.sourceURL,
            durationSeconds: capture.durationSeconds,
            hasCustomCover: coverPreviewURL != nil || coverVideoURL != nil,
            tags: capture.tags ?? [],
            itemDescription: capture.itemDescription,
            createdAt: capture.createdAt,
            isSaved: capture.isSaved,
            isSorted: true,
            isTrashed: capture.isTrashed
        )
    }

}

extension GalleryItem {
    static let samples: [GalleryItem] = [
        GalleryItem(
            title: "BLOCK", domain: "ulstersportsclub.com",
            imageURL: "https://images.unsplash.com/photo-1618005182384-a83a8bd57fbe?q=85&w=1400&auto=format&fit=crop",
            aspectRatio: 0.75, background: Color(red: 0.96, green: 0.38, blue: 0.06),
            style: .block, daysAgo: 0, isSaved: true, isSorted: true
        ),
        GalleryItem(
            title: "Bread", domain: "generalbread.co",
            imageURL: "https://images.unsplash.com/photo-1534088568595-a066f410cbda?q=85&w=1400&auto=format&fit=crop",
            aspectRatio: 1, background: Color(red: 0.48, green: 0.70, blue: 0.83),
            style: .bread, daysAgo: 1, isSorted: true
        ),
        GalleryItem(
            title: "Good Room", domain: "goodroombk.com",
            imageURL: "https://images.unsplash.com/photo-1550684848-fac1c5b4e853?q=85&w=1400&auto=format&fit=crop",
            aspectRatio: 0.64, background: .black,
            style: .dark, daysAgo: 2, isSaved: true, isSorted: true
        ),
        GalleryItem(
            title: "SÈVE", domain: "seve.studio",
            aspectRatio: 1.33, background: Color(red: 0.90, green: 0.87, blue: 0.80),
            style: .seve, daysAgo: 3, isSorted: true
        ),
        GalleryItem(
            title: "Design that inspires", domain: "sayansenapati.com",
            imageURL: "https://images.unsplash.com/photo-1550684376-efcbd6e3f031?q=85&w=1400&auto=format&fit=crop",
            aspectRatio: 2.33, background: Color(red: 0.03, green: 0.07, blue: 0.15),
            style: .blue, daysAgo: 4
        ),
        GalleryItem(
            title: "CIN", domain: "cin-archive.com",
            imageURL: "https://images.unsplash.com/photo-1605806616949-1e87b487cb2a?q=85&w=1400&auto=format&fit=crop",
            aspectRatio: 1, background: .black,
            style: .cin, daysAgo: 5, isSaved: true
        ),
        GalleryItem(
            title: "Form & Function", domain: "formandfunction.design",
            imageURL: "https://images.unsplash.com/photo-1547891654-e66ed7ebb968?q=85&w=1400&auto=format&fit=crop",
            aspectRatio: 0.8, background: Color(red: 0.77, green: 0.15, blue: 0.12),
            style: .editorial, daysAgo: 6
        ),
        GalleryItem(
            title: "Objects 01", domain: "objects.directory",
            imageURL: "https://images.unsplash.com/photo-1618172193763-c511deb635ca?q=85&w=1400&auto=format&fit=crop",
            aspectRatio: 1.33, background: Color(red: 0.83, green: 0.81, blue: 0.76),
            style: .mono, daysAgo: 7, isTrashed: true
        )
    ]
}
