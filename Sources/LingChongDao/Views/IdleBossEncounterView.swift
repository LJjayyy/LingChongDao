import SwiftUI

/// A short, hover-owned skit. Its destination keeps a stable size while hidden;
/// the animated pet is mounted only while this encounter is actually visible.
@MainActor
struct IdleBossEncounterView: View {
    let isActive: Bool
    let encounterNumber: Int
    var openWorkbench: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var reactionToken = 0
    @ViewState private var quipOffset = 0
    @ViewState private var hasSpoken = false

    private struct EntranceKey: Equatable {
        let active: Bool
        let reducedMotion: Bool
    }
    private static let quips = [
        "好家伙，全员带薪摸鱼？",
        "工位都空了？这班还得我替你们上？",
        "工资在跑，进度条怎么没动？",
        "人呢？我的牛马怎么都下线了？",
        "别装了，鼠标都来串门了。",
        "咖啡喝三杯了，活儿是一点没派。",
        "只有我在假装忙？这老板当亏了。",
        "再不来点活，我可要开始画饼了。"
    ]
    private var quip: String {
        Self.quips[(max(0, encounterNumber - 1) % Self.quips.count + quipOffset) % Self.quips.count]
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Button {
                quipOffset = (quipOffset + 1) % Self.quips.count
                reactionToken = reactionToken == Int.max ? 1 : reactionToken + 1
                hasSpoken = true
            } label: {
                Group {
                    if isActive { DefaultPetView(size: 68, reactionToken: reactionToken) }
                    else { Color.clear.frame(width: 68, height: 68) }
                }
                .frame(width: 76, height: 76)
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(BossPressStyle())
            .accessibilityLabel("戳戳老板鼠")
            .accessibilityValue(quip)
            .accessibilityHint("再查一次岗，换一句摸鱼吐槽")
            .help("戳戳老板鼠，再查一轮岗")

            Button(action: openWorkbench) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(hasSpoken ? "老板鼠突击查岗" : "老板鼠巡视工位…")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(IslandStyle.orange)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button { openWorkbench() } label: {
                            Label("工作台", systemImage: "arrow.up.right")
                        }
                        .buttonStyle(IslandActionStyle())
                        .contentShape(Rectangle())
                        .accessibilityLabel("打开工作台")
                        .help("打开灵宠岛工作台")
                    }
                    Text(quip)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40, alignment: .topLeading)
                        .opacity(hasSpoken ? 1 : 0)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hasSpoken)
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开工作台")
            .accessibilityHint("整个提示区域都可以点击")
            .help("打开灵宠岛工作台")
        }
        .frame(height: 84)
        .accessibilityHidden(!isActive)
        .task(id: EntranceKey(active: isActive, reducedMotion: reduceMotion)) {
            guard isActive else { hasSpoken = false; return }
            if reduceMotion {
                reactionToken = reactionToken == 0 ? 1 : reactionToken
                hasSpoken = true
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled else { return }
                // A click during the entrance already supplied the feedback.
                if reactionToken == 0 { reactionToken = 1 }
                try await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                hasSpoken = true
            } catch { /* Leaving cancels the skit instead of queuing another. */ }
        }
    }
}
