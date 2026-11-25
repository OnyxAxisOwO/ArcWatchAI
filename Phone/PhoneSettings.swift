import SwiftUI
import UIKit

struct PhoneSettings: View {
    @EnvironmentObject private var store: ChatStore

    var body: some View {
        Form {
            Section {
                Picker("显示模式", selection: $store.appearance) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("主题色")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 42, maximum: 60))], alignment: .leading, spacing: 4) {
                        ForEach(AccentTint.allCases, id: \.self) { tint in
                            Button {
                                store.tint = tint
                            } label: {
                                Circle()
                                    .fill(tint.color)
                                    .frame(width: 27, height: 27)
                                    .padding(4)
                                    .overlay(Circle().strokeBorder(Color.primary, lineWidth: store.tint == tint ? 2 : 0))
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(tint.label)
                            .accessibilityAddTraits(store.tint == tint ? .isSelected : [])
                        }
                    }
                }
                .padding(.vertical, 3)
                ColorPicker("自定义颜色", selection: Binding(
                    get: { store.tint.color },
                    set: { color in
                        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, alpha: CGFloat = 0
                        if UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &alpha) {
                            store.tint = AccentTint(red: Double(r), green: Double(g), blue: Double(b))
                        }
                    }
                ), supportsOpacity: false)
            } header: {
                Text("外观")
            } footer: {
                Text("外观与主题色会同步到 Apple Watch。")
            }

            Section {
                Toggle("渲染 Markdown", isOn: $store.markdownEnabled)
            } header: {
                Text("阅读")
            } footer: {
                Text("在 AI 回复中显示标题、列表、链接和代码块。")
            }
        }
        .navigationTitle("设置")
    }
}
