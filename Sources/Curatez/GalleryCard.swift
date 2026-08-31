import AVKit
import SwiftUI

struct GalleryCard: View {
    let item: GalleryItem
    let isSuspended: Bool
    let onToggleSaved: () -> Void
    let onTrash: () -> Void
    let onRestore: () -> Void
    let onOpenSource: () -> Void
    let onOpenDetails: () -> Void
    let onReplaceCover: () -> Void
    let onCopyContext: () -> Void

    @State private var isHovered = false
    @State private var didCopyContext = false
    @State private var copyFeedbackGeneration = 0

    var body: some View {
        ZStack {
            item.background
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            remoteImage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            videoPreview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            artworkOverlay
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .allowsHitTesting(false)
            actionOverlay
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .overlay {
                Rectangle()
                    .stroke(.black.opacity(0.055), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.045), radius: 2, y: 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpenDetails)
        .onHover { hovering in
            isHovered = hovering
        }
        .layoutValue(key: GalleryAspectRatioKey.self, value: item.aspectRatio)
    }

    @ViewBuilder
    private var remoteImage: some View {
        if let url = item.imageURL {
            if url.isFileURL {
                CachedLocalImage(url: url, maxPixelSize: 1_200, contentMode: .fill)
                    .scaleEffect(isHovered ? 1.025 : 1)
                    .animation(.easeOut(duration: 0.65), value: isHovered)
            } else {
                AsyncImage(url: url, transaction: Transaction(animation: .easeIn(duration: 0.3))) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .scaleEffect(isHovered ? 1.035 : 1)
                            .animation(.easeOut(duration: 0.65), value: isHovered)
                    case .failure:
                        fallbackTexture
                    case .empty:
                        fallbackTexture
                            .overlay { ProgressView().controlSize(.small).tint(.white.opacity(0.7)) }
                    @unknown default:
                        fallbackTexture
                    }
                }
            }
        }
    }

    private var fallbackTexture: some View {
        LinearGradient(
            colors: [item.background.opacity(0.65), .black.opacity(0.35)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    @ViewBuilder
    private var videoPreview: some View {
        if let url = item.videoURL {
            GalleryVideoPreview(url: url, isSuspended: isSuspended)
        }
    }

    @ViewBuilder
    private var artworkOverlay: some View {
        if item.hasCustomCover {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(2)
                    Text(item.domain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(17)
            }
        } else {
            defaultArtworkOverlay
        }
    }

    @ViewBuilder
    private var defaultArtworkOverlay: some View {
        switch item.style {
        case .block:
            ZStack {
                Color.orange.opacity(0.37).blendMode(.multiply)
                LinearGradient(colors: [.clear, Color(red: 0.70, green: 0.16, blue: 0.02).opacity(0.75)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading) {
                    Text("BLOCK")
                        .font(.system(size: 58, weight: .black))
                        .tracking(-4)
                    Spacer()
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Chloé Robinson")
                            Text("Bobby Analog")
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Ulster Sports Club")
                            Text("20.05")
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Color(red: 1, green: 0.94, blue: 0.86))
                .padding(24)
            }

        case .bread:
            ZStack {
                Color.blue.opacity(0.18).blendMode(.multiply)
                VStack(alignment: .leading) {
                    HStack {
                        RoundedRectangle(cornerRadius: 3).frame(width: 14, height: 14)
                        Text("Bread").font(.system(size: 20, weight: .bold))
                        Spacer()
                        Text("generalbread.co").font(.system(size: 12, weight: .semibold))
                    }
                    Spacer()
                    Text("The only modern Bitcoin app, **built for everyone.** Earn, spend, trade, and get your daily bread.")
                        .font(.system(size: 15, weight: .medium))
                        .frame(maxWidth: 310, alignment: .leading)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.22), radius: 4, y: 2)
                .padding(24)
            }

        case .dark:
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.92)], startPoint: .center, endPoint: .bottom)
                HStack(alignment: .top) {
                    VStack(alignment: .leading) {
                        Text("January 5th").foregroundStyle(.white.opacity(0.8))
                        Text("Good Room:")
                    }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("Bad Room:").foregroundStyle(.white.opacity(0.8))
                        Text("Nasty Nigel")
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .padding(24)
            }

        case .seve:
            VStack(spacing: 0) {
                Text("ISSU DE L'ARBRE")
                    .font(.system(size: 10, weight: .medium, design: .serif))
                    .tracking(3)
                    .padding(.top, 28)
                Spacer()
                Text("SÈVE")
                    .font(.system(size: 96, weight: .black))
                    .tracking(-7)
                Spacer()
            }
            .foregroundStyle(.black.opacity(0.92))

        case .blue:
            ZStack(alignment: .top) {
                Color.blue.opacity(0.35).blendMode(.color)
                LinearGradient(colors: [.clear, Color(red: 0.02, green: 0.05, blue: 0.12)], startPoint: .top, endPoint: .bottom)
                HStack {
                    Text("DESIGN THAT INSPIRES")
                    Spacer()
                    Text("JUNE TWENTY 23")
                    Spacer()
                    Text("SAYAN SENAPATI")
                }
                .font(.system(size: 8, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 22)
                .padding(.top, 19)
            }

        case .cin:
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.57)
                LinearGradient(colors: [.clear, .black], startPoint: .center, endPoint: .bottom)
                Text("CIN")
                    .font(.system(size: 116, weight: .black))
                    .tracking(-8)
                    .foregroundStyle(
                        LinearGradient(colors: [.white.opacity(0.9), .gray], startPoint: .top, endPoint: .bottom)
                    )
                    .padding(.bottom, 34)
            }

        case .editorial:
            ZStack(alignment: .bottomLeading) {
                Color.red.opacity(0.2).blendMode(.multiply)
                VStack(alignment: .leading) {
                    HStack {
                        Text("FORM")
                        Spacer()
                        Text("MMXXVI")
                    }
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1)
                    Spacer()
                    Text("FORM &\nFUNCTION")
                        .font(.system(size: 38, weight: .black))
                        .tracking(-2)
                        .lineSpacing(-8)
                }
                .foregroundStyle(.white)
                .padding(22)
            }

        case .mono:
            ZStack {
                Color.gray.opacity(0.22).blendMode(.color)
                Text("OBJECTS 01")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(3)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 13)
                    .overlay(Rectangle().stroke(.black, lineWidth: 1))
            }

        case .capturedText:
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "text.quote")
                    .font(.system(size: 17, weight: .medium))
                Text(item.title)
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                    .lineLimit(4)
                    .minimumScaleFactor(0.72)
                if let description = item.itemDescription, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                } else if let caption = item.caption, caption != item.title {
                    Text(caption)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Spacer()
                HStack {
                    Text(item.tags.isEmpty ? item.domain : item.tags.map { "#\($0)" }.joined(separator: " "))
                        .lineLimit(1)
                    Spacer()
                    Text(item.createdAt, style: .date)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            }
            .foregroundStyle(.black.opacity(0.86))
            .padding(24)

        case .capturedLink:
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "link")
                    .font(.system(size: 17, weight: .semibold))
                Text(item.title)
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                    .lineLimit(5)
                    .minimumScaleFactor(0.72)
                if let description = item.itemDescription, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Spacer()
                HStack {
                    Text(item.domain)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            }
            .foregroundStyle(.black.opacity(0.86))
            .padding(24)

        case .capturedVideo:
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [.clear, .black.opacity(0.62)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(2)
                    HStack {
                        Label(item.domain, systemImage: "play.rectangle")
                            .lineLimit(1)
                        Spacer()
                        if let duration = item.durationSeconds {
                            Text(formattedDuration(duration))
                        }
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                }
                .foregroundStyle(.white)
                .padding(17)
            }

        case .capturedImage:
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "photo")
                    .font(.system(size: 20, weight: .medium))
                Text(item.title)
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                    .lineLimit(4)
                if let description = item.itemDescription, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.64))
                        .lineLimit(3)
                }
                Spacer()
                Text(item.tags.isEmpty ? item.domain : item.tags.map { "#\($0)" }.joined(separator: " "))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(22)

        case .browserSnapshot:
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [.clear, .black.opacity(0.66)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(2)
                    Label(item.domain, systemImage: "link")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                }
                .foregroundStyle(.white)
                .padding(17)
            }
        }
    }

    private var actionOverlay: some View {
        VStack {
            HStack {
                Spacer()
                if isHovered {
                    Button(action: copyContext) {
                        Image(systemName: didCopyContext ? "checkmark" : "doc.on.doc")
                            .frame(width: 34, height: 34)
                            .background(didCopyContext ? Color.green : Color.white.opacity(0.94))
                            .foregroundStyle(didCopyContext ? .white : .black)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.14), radius: 7, y: 2)
                    }
                    .buttonStyle(.plain)
                    .help(didCopyContext ? "已复制 Context" : "复制 Context")

                    Button(action: onToggleSaved) {
                        Image(systemName: item.isSaved ? "bookmark.fill" : "bookmark")
                            .frame(width: 34, height: 34)
                            .background(item.isSaved ? .black : .white.opacity(0.94))
                            .foregroundStyle(item.isSaved ? .white : .black)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.14), radius: 7, y: 2)
                    }
                    .buttonStyle(.plain)

                    Menu {
                        Button("View details", systemImage: "info.circle", action: onOpenDetails)
                        Button("Replace cover", systemImage: "photo.badge.arrow.down", action: onReplaceCover)
                        Button("Open source", systemImage: "arrow.up.right.square", action: onOpenSource)
                            .disabled(item.sourceURL == nil && item.videoURL == nil && item.imageURL?.isFileURL != false)
                        if item.isTrashed {
                            Button("Restore", systemImage: "arrow.uturn.backward", action: onRestore)
                        } else {
                            Button("Move to Trash", systemImage: "trash", role: .destructive, action: onTrash)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 34, height: 34)
                            .background(.white.opacity(0.94))
                            .foregroundStyle(.black)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.14), radius: 7, y: 2)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            Spacer()
        }
        .padding(13)
        .animation(.easeOut(duration: 0.16), value: isHovered)
    }

    private func copyContext() {
        onCopyContext()
        copyFeedbackGeneration += 1
        let generation = copyFeedbackGeneration
        withAnimation(.easeOut(duration: 0.16)) { didCopyContext = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            guard generation == copyFeedbackGeneration else { return }
            withAnimation(.easeOut(duration: 0.16)) { didCopyContext = false }
        }
    }

    private func formattedDuration(_ duration: Double) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

extension GalleryCard: @MainActor Equatable {
    static func == (lhs: GalleryCard, rhs: GalleryCard) -> Bool {
        lhs.item == rhs.item && lhs.isSuspended == rhs.isSuspended
    }
}

private struct GalleryVideoPreview: View {
    let url: URL
    let isSuspended: Bool

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var shouldResumeAfterSuspension = false

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
                    .opacity(isPlaying ? 1 : 0)
            }

            if !isPlaying {
                Button {
                    if player == nil {
                        let newPlayer = AVPlayer(url: url)
                        newPlayer.isMuted = true
                        player = newPlayer
                    }
                    player?.play()
                    isPlaying = true
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(.black.opacity(0.68))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(isPlaying ? Color.black : Color.clear)
        .onChange(of: isSuspended) { _, suspended in
            if suspended {
                shouldResumeAfterSuspension = isPlaying
                player?.pause()
            } else if shouldResumeAfterSuspension {
                player?.play()
                shouldResumeAfterSuspension = false
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
            isPlaying = false
            shouldResumeAfterSuspension = false
        }
    }
}
