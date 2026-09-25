import SwiftUI

struct HarnessSwitcherView: View {
    @ObservedObject var state: HarnessSwitcherState

    var body: some View {
        // The coordinator sizes the panel to the enabled Harnesses and the
        // main-window card; scrolling only happens when they outgrow the screen.
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    content
                        .padding(HarnessSwitcherPanelLayout.contentPadding)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                }
                .onAppear {
                    scrollToSelection(at: state.selectedIndex, using: proxy)
                }
                .onChange(of: state.selectedIndex) { selectedIndex in
                    scrollToSelection(at: selectedIndex, using: proxy)
                }
            }
        }
        .modifier(HarnessSwitcherGlassBackground())
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var content: some View {
        if state.options.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(L10n.text("没有已启用的 Harness", "No enabled Harnesses"))
                    .font(.headline)
            }
            .frame(height: HarnessSwitcherPanelLayout.itemHeight)
        } else {
            HStack(spacing: HarnessSwitcherPanelLayout.itemSpacing) {
                ForEach(state.options) { option in
                    HarnessSwitcherItemView(
                        option: option,
                        isSelected: option.id == state.selectedOption?.id
                    )
                    .id(option.id)
                }
            }
        }
    }

    private func scrollToSelection(at index: Int, using proxy: ScrollViewProxy) {
        guard state.options.indices.contains(index) else { return }
        proxy.scrollTo(state.options[index].id, anchor: .center)
    }
}

private struct HarnessSwitcherItemView: View {
    let option: HarnessSwitcherOption
    let isSelected: Bool

    private var statusColor: Color {
        option.applicationStatus == .connected ? .green : .secondary
    }

    var body: some View {
        VStack(spacing: 9) {
            icon
                .frame(width: 48, height: 48)

            Text(option.displayName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)

            HStack(spacing: 5) {
                // The main-window card opens Joy Harness itself, so no status dot.
                if option.applicationStatus != nil {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                }
                Text(option.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: HarnessSwitcherPanelLayout.itemWidth, height: HarnessSwitcherPanelLayout.itemHeight)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.primary.opacity(0.10),
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(option.displayName)
        .accessibilityValue(option.detail)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var icon: some View {
        if let applicationIcon = option.applicationIcon {
            Image(nsImage: applicationIcon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            ZStack {
                Circle()
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.07))
                Image(systemName: option.systemImage)
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            }
        }
    }
}

/// Liquid Glass on macOS 26 and later, the translucent material before it.
private struct HarnessSwitcherGlassBackground: ViewModifier {
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: HarnessSwitcherPanelLayout.cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay {
                    shape.strokeBorder(.primary.opacity(0.12), lineWidth: 1)
                }
        }
    }
}

enum HarnessSwitcherPanelLayout {
    static let height: CGFloat = 152
    static let itemWidth: CGFloat = 120
    static let itemHeight: CGFloat = 112
    static let itemSpacing: CGFloat = 12
    static let contentPadding: CGFloat = 20
    /// Concentric with the 8 pt cards inset by `contentPadding`.
    static let cornerRadius: CGFloat = 28
    /// Space kept between the panel and the screen edges.
    static let screenMargin: CGFloat = 40
    /// Keeps the empty state and one or two cards from looking cramped.
    private static let minimumItemSlots = 3

    static func width(forItemCount itemCount: Int, maximumWidth: CGFloat) -> CGFloat {
        let slots = CGFloat(max(itemCount, minimumItemSlots))
        let fittedWidth = slots * itemWidth + (slots - 1) * itemSpacing + contentPadding * 2
        return min(fittedWidth, maximumWidth)
    }
}
