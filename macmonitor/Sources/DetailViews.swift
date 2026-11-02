import SwiftUI

// MARK: - 每核热力图（主面板与详情窗口共用）
//
// E 核青色、P 核蓝色，颜色深浅表示占用高低。
// Apple Silicon 上 E 核编号在前、P 核在后（实测确认）。

struct CoreHeatmap: View {
    let cores: [Double]
    let pCount: Int
    var barHeight: CGFloat = 30

    var body: some View {
        let eCount = max(0, cores.count - min(pCount, cores.count))
        HStack(spacing: 4) {
            ForEach(Array(cores.enumerated()), id: \.offset) { i, v in
                let isP = i >= eCount
                let base = isP ? Theme.accent : Theme.teal
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(base.opacity(0.13 + 0.87 * min(1, v / 100)))
                        .frame(height: barHeight)
                        .overlay(
                            Text("\(Int(v.rounded()))")
                                .font(.system(size: 8.5, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(v > 42 ? Color.white : Color.primary.opacity(0.5))
                        )
                    Text(isP ? "P\(i - eCount + 1)" : "E\(i + 1)")
                        .font(.system(size: 7.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
