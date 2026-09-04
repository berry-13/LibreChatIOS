import SwiftUI

/// LibreChat-web's default user avatar: the dicebear "initials" style its
/// `useAvatar` hook generates locally when no image is uploaded — a solid
/// background picked deterministically from its fixed 14-color palette,
/// with white initials. Same seed, same color, on every launch.
struct InitialsAvatar: View {
    let seed: String
    var size: CGFloat

    var body: some View {
        let initials = Self.initials(for: seed)
        ZStack {
            Circle().fill(Self.backgroundColor(for: seed))
            if initials.isEmpty {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.46, weight: .medium))
                    .foregroundStyle(.white)
            } else {
                Text(initials)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }

    /// The exact palette from the web client's `useAvatar` hook.
    private static var palette: [Color] {
        [
            "d81b60", "8e24aa", "5e35b1", "3949ab", "DB3733", "1B79CC",
            "027CB8", "008291", "008577", "58802F", "8A761D", "9C6D00",
            "B06200", "D1451A",
        ].compactMap { hex in
            var value: UInt64 = 0
            guard hex.count == 6, Scanner(string: hex).scanHexInt64(&value) else { return nil }
            return Color(
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255
            )
        }
    }

    static func backgroundColor(for seed: String) -> Color {
        // djb2 over the UTF-8 seed keeps the choice stable per name.
        var hash: UInt64 = 5381
        for byte in seed.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        let colors = palette
        return colors.isEmpty ? .secondary : colors[Int(hash % UInt64(colors.count))]
    }

    /// Dicebear's initials derivation: the first letters of the first two
    /// whitespace-separated words.
    static func initials(for seed: String) -> String {
        seed.split(whereSeparator: \.isWhitespace)
            .prefix(2)
            .compactMap(\.first)
            .map { String($0).uppercased() }
            .joined()
    }
}
