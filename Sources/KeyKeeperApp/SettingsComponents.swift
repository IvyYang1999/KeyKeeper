import SwiftUI

/// Settings laid out like System Settings: a few titled groups, each one card of rows, with the
/// label on the left and the control on the right, sized to its content.
///
/// 【曾经的 bug】2026-11-07 yyt：设置页「真的很丑」——十张卡平铺成一长列；「界面语言」一张卡里横着一个
/// 整页宽的下拉框；iCloud 的「重试」「关闭同步」竖着叠、宽度不一。
struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text(title)
                .font(.headline)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .surface(.card, radius: DS.Radius.md)
        }
    }
}

/// One line of a group: what it is (and a short note) on the left, its control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String? = nil
    var detailColor: Color = .secondary
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: DS.Spacing.lg) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(detailColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

extension SettingsRow where Control == EmptyView {
    init(title: String, detail: String? = nil, detailColor: Color = .secondary) {
        self.init(title: title, detail: detail, detailColor: detailColor) { EmptyView() }
    }
}

/// A switch that reads as a setting, not a checkbox.
struct SettingsSwitch: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(label, isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
    }
}

/// The hairline between two rows of a group, inset like System Settings.
struct SettingsDivider: View {
    var body: some View {
        GlassSeparator().padding(.leading, 14)
    }
}

/// A small coloured dot: green only for "working", orange for "needs you", grey for off.
struct StatusDot: View {
    enum Tone { case good, attention, off }
    let tone: Tone

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch tone {
        case .good: .green
        case .attention: .orange
        case .off: Color.secondary.opacity(0.5)
        }
    }
}
