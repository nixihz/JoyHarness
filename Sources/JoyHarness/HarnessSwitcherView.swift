import SwiftUI

struct HarnessSwitcherView: View {
    @ObservedObject var state: HarnessSwitcherState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                if state.options.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "square.grid.2x2")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(L10n.text("没有已启用的 Harness", "No enabled Harnesses"))
                            .font(.headline)
                    }
                    .frame(
                        width: HarnessSwitcherPanelLayout.width - 40,
                        height: HarnessSwitcherPanelLayout.itemHeight
                    )
                    .padding(20)
                } else {
                    HStack(spacing: 12) {
                        ForEach(state.options) { option in
                            HarnessSwitcherItemView(
                                option: option,
                                isSelected: option.id == state.selectedOption?.id
                            )
                            .id(option.id)
                        }
                    }
                    .frame(
                        minWidth: HarnessSwitcherPanelLayout.width - 40,
                        alignment: .center
                    )
                    .padding(20)
                }
            }
            .onAppear {
                scrollToSelection(at: state.selectedIndex, using: proxy)
            }
            .onChange(of: state.selectedIndex) { selectedIndex in
                scrollToSelection(at: selectedIndex, using: proxy)
            }
        }
        .frame(
            width: HarnessSwitcherPanelLayout.width,
            height: HarnessSwitcherPanelLayout.height
        )
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func scrollToSelection(at index: Int, using proxy: ScrollViewProxy) {
        guard state.options.indices.contains(index) else { return }
        proxy.scrollTo(state.options[index].id, anchor: .center)
    }
}

private struct HarnessSwitcherItemView: View {
    let option: HarnessSwitcherOption
    let isSelected: Bool

    private var statusTitle: String {
        option.applicationStatus.localizedDescription
    }

    private var statusColor: Color {
        option.applicationStatus == .connected ? .green : .secondary
    }

    var body: some View {
        VStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.07))
                Image(systemName: option.systemImage)
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            }
            .frame(width: 48, height: 48)

            Text(option.displayName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)

            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(statusTitle)
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
        .accessibilityValue(statusTitle)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

enum HarnessSwitcherPanelLayout {
    static let width: CGFloat = 568
    static let height: CGFloat = 152
    static let itemWidth: CGFloat = 120
    static let itemHeight: CGFloat = 112
}
