import SwiftUI

enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system, dark, light
    var id: Self { self }
    var label: String { switch self { case .system: "跟随系统"; case .dark: "深色"; case .light: "浅色" } }
    var colorScheme: ColorScheme? { switch self { case .system: nil; case .dark: .dark; case .light: .light } }
}

struct AccentTint: Codable, Hashable, Identifiable, CaseIterable {
    let hex: Int
    var id: Int { hex }
    static let jade = Self(hex: 0x39AD98)
    static let allCases = [jade, Self(hex: 0x548FE5), Self(hex: 0xA281CF), Self(hex: 0xD4768F), Self(hex: 0xC78F48), Self(hex: 0x919399)]
    private static let names = ["翡翠", "海蓝", "藤紫", "蔷薇", "琥珀", "石墨"]
    var label: String { Self.allCases.firstIndex(of: self).map { Self.names[$0] } ?? "自定义" }
    var color: Color { Color(red: Double(hex >> 16 & 255) / 255, green: Double(hex >> 8 & 255) / 255, blue: Double(hex & 255) / 255) }
    init(hex: Int) { self.hex = hex & 0xffffff }
    init(red: Double, green: Double, blue: Double) {
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        self.init(hex: byte(red) << 16 | byte(green) << 8 | byte(blue))
    }
    init(hue: Double) {
        let angle = hue * 6
        func component(_ offset: Double) -> Double {
            let k = (offset + angle).truncatingRemainder(dividingBy: 6)
            return 0.82 * (1 - 0.62 * max(0, min(k, 4 - k, 1)))
        }
        self.init(red: component(5), green: component(3), blue: component(1))
    }
}

/// An open orbit around a four-point star, shared by the two app surfaces.
struct ArcMark: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 64
        var orbit = Path()
        orbit.addArc(center: CGPoint(x: 32, y: 32), radius: 26, startAngle: .degrees(30), endAngle: .degrees(304), clockwise: false)
        var path = orbit.strokedPath(.init(lineWidth: 4.4, lineCap: .round))
        var star = Path()
        star.move(to: CGPoint(x: 35, y: 10))
        star.addQuadCurve(to: CGPoint(x: 54, y: 30), control: CGPoint(x: 37, y: 27))
        star.addQuadCurve(to: CGPoint(x: 35, y: 50), control: CGPoint(x: 37, y: 33))
        star.addQuadCurve(to: CGPoint(x: 16, y: 30), control: CGPoint(x: 33, y: 33))
        star.addQuadCurve(to: CGPoint(x: 35, y: 10), control: CGPoint(x: 33, y: 27))
        star.closeSubpath()
        path.addPath(star)
        return path.applying(.init(a: unit, b: 0, c: 0, d: unit, tx: rect.midX - unit * 32, ty: rect.midY - unit * 32))
    }
}
