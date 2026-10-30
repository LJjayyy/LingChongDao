import AppKit
import IslandConnections
import IslandCore
import SwiftUI
import UniformTypeIdentifiers

struct WorkbenchView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var connections: ConnectionManager
    @ObservedObject private var keepAwake = KeepAwakeController.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var page = "tasks"
    @ViewState private var heroHover = false
    @ViewState private var bossReaction = 0

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(BossWorkbenchStyle.border).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if page != "connections" { bossWelcome }
                    if let error = model.bridgeError {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(error).foregroundStyle(.red).font(.system(size: 13))
                            Button("重试启动") { model.startBridge() }
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).bossCard()
                    }
                    if let error = model.actionError {
                        HStack(alignment: .top, spacing: 12) {
                            Text(error).foregroundStyle(BossWorkbenchStyle.muted).font(.system(size: 13))
                            Spacer(minLength: 8)
                            Button("关闭提示") { model.actionError = nil }.buttonStyle(BossButtonStyle(kind: .quiet))
                        }.padding(14).bossCard()
                    }
                    if let error = keepAwake.errorMessage {
                        HStack(alignment: .top, spacing: 12) {
                            Text(error).font(.system(size: 13)).foregroundStyle(BossWorkbenchStyle.muted)
                            Spacer(minLength: 8)
                            if keepAwake.isEnabled {
                                Button("重试恢复休眠") { keepAwake.stop() }.buttonStyle(BossButtonStyle(kind: .quiet)).disabled(keepAwake.isChanging)
                            } else {
                                Button("关闭提示") { keepAwake.clearError() }.buttonStyle(BossButtonStyle(kind: .quiet))
                            }
                        }.padding(14).bossCard()
                    }
                    Group {
                        switch page {
                        case "settings": ScreenSettingsView(settings: settings)
                        case "connections": ConnectionsView(manager: connections)
                        default: tasks
                        }
                    }
                    .id(page)
                    .transition(.opacity)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: page)
                }
                .padding(28)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }.background(page == "connections" ? Color(hex: 0xFAFAFA) : BossWorkbenchStyle.canvas)
        }
        .frame(minWidth: 850, minHeight: 650)
        .background(BossWorkbenchStyle.canvas)
        .preferredColorScheme(.light)
        .font(.system(size: 13))
        .foregroundStyle(BossWorkbenchStyle.text)
        .tint(BossWorkbenchStyle.copperText)
        .buttonStyle(BossButtonStyle())
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                DefaultPetView(size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text("灵宠岛").font(.system(size: 17, weight: .semibold))
                    Text("老板鼠的工作台").font(.system(size: 12)).foregroundStyle(BossWorkbenchStyle.muted)
                }
            }.padding(.top, 8).padding(.bottom, 28)
            sideButton("任务总览", symbol: "rectangle.stack", id: "tasks")
            sideButton("屏幕顶部", symbol: "menubar.rectangle", id: "settings")
            sideButton("连接的应用", symbol: "point.3.connected.trianglepath.dotted", id: "connections")
            Spacer(minLength: 24)
            Rectangle().fill(BossWorkbenchStyle.border).frame(height: 1).padding(.bottom, 8)
            HStack(spacing: 7) {
                Circle().fill(model.bridgeRunning ? IslandStyle.settingsGreen : Color.red).frame(width: 6, height: 6)
                Text(model.bridgeRunning ? "本地接入已启动" : "本地接入不可用")
                    .font(.system(size: 12)).foregroundStyle(BossWorkbenchStyle.muted)
            }
            Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版").font(.system(size: 12)).foregroundStyle(BossWorkbenchStyle.muted).padding(.top, 3)
        }
        .padding(18)
        .frame(width: 212)
        .background(page == "connections" ? Color(hex: 0xF5F4F2) : BossWorkbenchStyle.sidebar)
    }

    private var bossWelcome: some View {
        HStack(spacing: 18) {
            Button {
                bossReaction = bossReaction == Int.max ? 1 : bossReaction + 1
            } label: {
                DefaultPetView(size: 72, isAttentive: heroHover, reactionToken: bossReaction)
                    .padding(4)
                    .background(heroHover ? BossWorkbenchStyle.selected : BossWorkbenchStyle.canvas,
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(BossPressStyle())
            .onHover { heroHover = $0 }
            .accessibilityLabel("点点老板鼠")
            .accessibilityValue(bossGreeting)
            .accessibilityHint("让老板鼠说一句开工提醒，不会控制任务")
            .help("点点老板鼠")
            VStack(alignment: .leading, spacing: 7) {
                Text("老板鼠办公室").font(.system(size: 12, weight: .semibold)).foregroundStyle(BossWorkbenchStyle.copperText)
                Text(bossGreeting).font(.system(size: 17, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: bossReaction)
                Text("点点老板鼠").font(.system(size: 12)).foregroundStyle(BossWorkbenchStyle.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { keepAwake.toggle() } label: {
                Label(keepAwake.actionTitle,
                      systemImage: keepAwake.isEnabled ? "cup.and.saucer.fill" : "cup.and.saucer")
            }
            .buttonStyle(BossButtonStyle(kind: keepAwake.isEnabled ? .primary : .secondary))
            .fixedSize()
            .accessibilityLabel("保持唤醒")
            .accessibilityValue(keepAwake.accessibilityValue)
            .disabled(keepAwake.isChanging)
            .help(KeepAwakeController.scopeDescription)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BossWorkbenchStyle.sidebar.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var bossGreeting: String {
        guard bossReaction > 0 else { return "别摸鱼，开工了。" }
        let greetings = ["这班我替你上，工资你替我领？", "需求又改？我耳朵都听大了。", "饼先别画，给灵宠加个鸡腿。", "再点我，可就算工伤了。", "牛马已就位，老板请躺平。", "别摸鱼，开工了。"]
        return greetings[(bossReaction - 1) % greetings.count]
    }

    private func sideButton(_ title: String, symbol: String, id: String) -> some View {
        Button { page = id } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(width: 18)
                Text(title).font(.system(size: 13, weight: page == id ? .semibold : .regular))
                Spacer(minLength: 0)
                Capsule().fill(page == id ? BossWorkbenchStyle.copper : .clear).frame(width: 3, height: 14)
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            .foregroundStyle(page == id ? BossWorkbenchStyle.text : BossWorkbenchStyle.muted)
            .background(page == id ? BossWorkbenchStyle.selected : .clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(BossPressStyle())
        .accessibilityAddTraits(page == id ? .isSelected : [])
    }

    private var tasks: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text("任务总览").font(.system(size: 22, weight: .semibold))
                Text("查看任务进展，处理需要你决定的事。").foregroundStyle(BossWorkbenchStyle.muted)
            }
            if model.demoMode {
                HStack(spacing: 12) {
                    Text("交互预览已开启，示例任务不会执行真实操作。").foregroundStyle(BossWorkbenchStyle.muted)
                    Spacer(minLength: 8)
                    Button("结束预览") { model.endPreview() }
                }.padding(14).bossCard()
            }
            if model.workbenchSessions.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("目前没有会话活动").font(.system(size: 16, weight: .medium))
                    Text("老板鼠正在等新活。连接 Claude Code、Qoder CN、Codex 等应用后，新任务会显示在这里。")
                        .foregroundStyle(BossWorkbenchStyle.muted).fixedSize(horizontal: false, vertical: true)
                    Button("连接应用") { page = "connections" }.buttonStyle(BossButtonStyle(kind: .primary)).padding(.top, 4)
                }
                .padding(22).frame(maxWidth: .infinity, alignment: .leading).bossCard()
            } else {
                VStack(spacing: 12) {
                    ForEach(model.workbenchSessions) { session in
                        SwipeDismissRow(reduceMotion: reduceMotion, haptic: { model.haptic() },
                                        catchesMouse: false, showsCloseButton: canDismiss(session),
                                        dismiss: { model.dismiss(session, force: true) }) {
                            HStack(spacing: 12) {
                                PetView(source: session.source, phase: session.phase, sourceApplication: session.petSourceApplication, size: 32)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.displayTitle).fontWeight(.medium).lineLimit(1)
                                    Text("\(session.sourceDisplayName) · \(session.cwd.isEmpty ? session.detail : URL(fileURLWithPath: session.cwd).lastPathComponent)")
                                        .font(.system(size: 12)).foregroundStyle(BossWorkbenchStyle.muted).lineLimit(1)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Text(phaseTitle(session)).font(.system(size: 12)).foregroundStyle(BossWorkbenchStyle.muted)
                                Button(model.navigationLabel(for: session)) { model.navigate(to: session) }.buttonStyle(BossButtonStyle(kind: .quiet)).help(model.navigationHelp(for: session))
                                if session.unread && session.phase != .running {
                                    Button("清除提示") { model.dismiss(session) }.buttonStyle(BossButtonStyle(kind: .quiet))
                                }
                            }
                            .padding(16)
                            .bossCard()
                        }
                    }
                }
                .animation(reduceMotion ? nil : .spring(duration: IslandMotion.surfaceDuration, bounce: IslandMotion.surfaceBounce, blendDuration: 0.08),
                           value: model.workbenchSessions.map(\.id))
            }
            DisclosureGroup("交互预览") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("仅用于检查岛的状态与操作，不执行命令。").font(.system(size: 12)).foregroundStyle(BossWorkbenchStyle.muted)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 8) {
                        ForEach([("运行中", "running"), ("等待回答", "question"), ("命令批准", "approval"), ("复杂批准", "complex"), ("已完成", "completed"), ("执行失败", "failed"), ("已中断", "interrupted"), ("请求过期", "expired"), ("空闲", "idle")], id: \.1) { item in
                            Button(item.0) { settings.enabled = true; model.loadPreview(item.1) }.frame(maxWidth: .infinity)
                        }
                    }
                }.padding(.top, 12)
            }.font(.system(size: 13)).padding(16).bossCard()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func phaseTitle(_ session: IslandSession) -> String {
        if session.approval != nil { return session.approval?.isExpired() == true ? "请求已过期" : "等待批准" }
        if session.question != nil { return "等待回答" }
        switch session.phase { case .running: return "正在执行"; case .completed: return "已完成"; case .failed: return "执行失败"; case .interrupted: return "已中断"; default: return "本轮结束" }
    }

    /// macOS shows the hover × on every notification; a live approval or
    /// question still needs its decision, so the × stays hidden until it
    /// expires.
    private func canDismiss(_ session: IslandSession) -> Bool {
        session.approval?.isExpired() != false && session.question?.isExpired() != false
    }
}

struct ScreenSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject private var keepAwake = KeepAwakeController.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("屏幕顶部").font(.system(size: 22, weight: .semibold)).padding(.bottom, 4)
            VStack(spacing: 0) {
                settingToggle("显示灵宠岛", detail: "在屏幕顶部查看会话进展、回答问题和处理权限请求。", value: $settings.enabled)
                settingToggle("空闲时显示", detail: "没有会话活动时，显示默认灵宠老板鼠。点击可打开工作台。", value: $settings.idleVisible)
                settingToggle("在其他显示器上显示", detail: "连接多个显示器时，在各屏幕顶部同步显示灵宠岛。", value: $settings.additionalDisplays)
                settingToggle("回到应用后收起结束提示", detail: "来源应用在前台停留 1 秒后，收起该应用已有的结束提示。多条结束提示会一起收起；运行中、待回答和权限请求仍保留。", value: $settings.autoClearFinishedOnAppFocus)
                settingToggle("需要处理时自动展开", detail: "来源任务出现待批准、待回答、本轮结束、完成、失败或中断等需要你处理的状态时，顶部岛自动下拉提示，不需要把鼠标移上去；无操作 8 秒后自动收起，鼠标停在岛上时延后收起。", value: $settings.autoRevealOnFinish)
                settingToggle("触觉反馈", detail: "通过 Force Touch 触控板提供交互反馈，其他设备暂不支持。", value: $settings.haptics)
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("灵宠岛大小").font(.system(size: 13, weight: .medium))
                            Text("只调整收起时的宽度和高度，不影响展开内容。100% 为紧凑默认宽度，并保留宠物和刘海所需空间。")
                                .font(.system(size: 12)).foregroundStyle(BossWorkbenchStyle.muted).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                        Button("恢复默认大小") { settings.resetSize() }.buttonStyle(BossButtonStyle(kind: .quiet))
                            .disabled(settings.widthPercent == 100 && settings.heightPercent == 100).opacity(settings.widthPercent == 100 && settings.heightPercent == 100 ? 0.55 : 1)
                    }
                    HStack(spacing: 12) { preview(notch: true); preview(notch: false) }
                }.padding(.vertical, 16)
                dashedDivider
                sliderRow("宽度", value: $settings.widthPercent, range: 100...130)
                dashedDivider
                sliderRow("高度", value: $settings.heightPercent, range: 75...125)
            }.padding(.horizontal, 18).bossCard()
            Text("实用工具").font(.system(size: 13, weight: .medium)).foregroundStyle(BossWorkbenchStyle.muted).padding(.leading, 16).padding(.top, 12)
            VStack(spacing: 0) {
                settingToggle("保持唤醒（含合盖）", detail: "开启时申请管理员授权，阻止 Mac 休眠并包含合盖场景。关闭或退出后恢复原电源状态，每次启动默认关闭。开盖解锁仍按 macOS 设置。",
                              value: Binding(get: { keepAwake.state != .off }, set: { keepAwake.setEnabled($0) }), separator: false)
                    .disabled(keepAwake.isChanging)
            }.padding(.horizontal, 18).bossCard()
            Text("显示的来源").font(.system(size: 13, weight: .medium)).foregroundStyle(BossWorkbenchStyle.muted).padding(.leading, 16).padding(.top, 12)
            VStack(spacing: 0) {
                settingToggle("Qoder CN / IDE", detail: "显示 Qoder CN 与 Qoder CN IDE 的会话，并标明各自来源。", value: $settings.showQoder)
                settingToggle("Codex", detail: "在灵宠岛中显示来自 Codex 的会话。", value: $settings.showCodex)
                settingToggle("ZCode", detail: "显示 ZCode 的任务与工具进展，简单 Bash 权限可在岛内处理。", value: $settings.showZCode)
                settingToggle("Claude Code", detail: "显示本机 Claude 任务状态，可在岛内处理支持的单次审批。", value: $settings.showClaude)
                settingToggle("DeepSeek Harness", detail: "显示 DeepSeek Harness 的任务与工具进展；权限请求仍在来源处理。", value: $settings.showDSH)
                settingToggle("CodeBuddy CN", detail: "显示 CodeBuddy CN 的任务与工具进展。", value: $settings.showCodeBuddy)
                settingToggle("WorkBuddy", detail: "显示 WorkBuddy 的任务与工具进展。", value: $settings.showWorkBuddy, separator: false)
            }.padding(.horizontal, 18).bossCard()
        }.foregroundStyle(BossWorkbenchStyle.text)
    }
    private func settingToggle(_ title: String, detail: String, value: Binding<Bool>, separator: Bool = true) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(detail).font(.system(size: 12)).foregroundStyle(BossWorkbenchStyle.muted).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Toggle(title, isOn: value).labelsHidden().toggleStyle(SettingsSwitchStyle())
            }.padding(.vertical, 16)
            if separator { dashedDivider }
        }
    }
    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .medium)); Spacer()
            Text("\(Int(value.wrappedValue))%").font(.system(size: 12)).monospacedDigit().foregroundStyle(BossWorkbenchStyle.muted).frame(width: 40, alignment: .trailing)
            SettingsSlider(value: value, range: range, label: "灵宠岛\(title)").frame(width: 132)
        }.frame(height: 49)
    }
    private func preview(notch: Bool) -> some View {
        VStack(spacing: 8) {
            GeometryReader { proxy in
                // Preview a scaled camera gap with the same compact content rules.
                let cameraGap: CGFloat = notch ? min(120, max(0, proxy.size.width - 104)) : 0
                let minimumWidth: CGFloat = notch ? cameraGap + 80 : 40
                let width = min(proxy.size.width - 24, minimumWidth * max(1, settings.widthPercent / 100))
                let height = max(notch ? 32 : 24, 32 * settings.heightPercent / 100)
                HStack(spacing: 0) {
                    DefaultPetView(size: 20)
                    if notch { Spacer(minLength: cameraGap + 16); Color.clear.frame(width: 20, height: 20) }
                }
                    .padding(.horizontal, notch ? 12 : 10).frame(width: width, height: height)
                    .foregroundStyle(.white).background(IslandShell(notch: notch, expanded: false).fill(.black))
                    .position(x: proxy.size.width / 2, y: (notch ? 12 : 18) + height / 2)
            }.frame(height: 80).background(BossWorkbenchStyle.canvas, in: RoundedRectangle(cornerRadius: 8))
            Text(notch ? "内置显示器" : "外接显示器").font(.system(size: 12)).foregroundStyle(BossWorkbenchStyle.muted)
        }.frame(maxWidth: .infinity)
    }
    private var dashedDivider: some View { Line().stroke(BossWorkbenchStyle.border, style: StrokeStyle(lineWidth: 1, dash: [3, 2])).frame(height: 1) }
    private struct Line: Shape { func path(in rect: CGRect) -> Path { Path { $0.move(to: CGPoint(x: 0, y: 0)); $0.addLine(to: CGPoint(x: rect.width, y: 0)) } } }
}

/// Xcode-style read-only code card: header with filename and copy button,
/// monospaced syntax-highlighted body, long lines scroll instead of wrapping.
private struct CodeBlockView: View {
    let title: String
    let code: String
    @ViewState private var copied = false

    private enum Token {
        case key(String), string(String), number(String), literal(String), punctuation(String), plain(String)

        var text: String {
            switch self {
            case .key(let t), .string(let t), .number(let t), .literal(let t), .punctuation(let t), .plain(let t): t
            }
        }

        var color: Color {
            switch self {
            case .key: Color(hex: 0x3E6E9E)
            case .string: Color(hex: 0x3F7A45)
            case .number: Color(hex: 0x8A5BA6)
            case .literal: Color(hex: 0x9C6128)
            case .punctuation: BossWorkbenchStyle.muted
            case .plain: BossWorkbenchStyle.text
            }
        }
    }

    /// Lightweight JSON scanner; malformed input degrades to plain tokens.
    private static func tokenize(_ source: String) -> [Token] {
        let chars = Array(source)
        var tokens: [Token] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                var value = "\""
                var j = i + 1
                while j < chars.count {
                    if chars[j] == "\\", j + 1 < chars.count {
                        value.append(chars[j]); value.append(chars[j + 1]); j += 2; continue
                    }
                    value.append(chars[j])
                    j += 1
                    if chars[j - 1] == "\"" { break }
                }
                var k = j
                while k < chars.count, chars[k] == " " || chars[k] == "\t" { k += 1 }
                tokens.append(k < chars.count && chars[k] == ":" ? .key(value) : .string(value))
                i = j
            } else if c.isNumber || (c == "-" && i + 1 < chars.count && chars[i + 1].isNumber) {
                var j = i
                while j < chars.count, chars[j].isNumber || "+-eE.".contains(chars[j]) { j += 1 }
                tokens.append(.number(String(chars[i..<j])))
                i = j
            } else if let word = ["true", "false", "null"].first(where: { chars.count - i >= $0.count && String(chars[i..<i + $0.count]) == $0 }) {
                tokens.append(.literal(word))
                i += word.count
            } else if "{}[]:,".contains(c) {
                tokens.append(.punctuation(String(c)))
                i += 1
            } else {
                tokens.append(.plain(String(c)))
                i += 1
            }
        }
        return tokens
    }

    private static func highlighted(_ source: String) -> AttributedString {
        var result = AttributedString()
        for token in tokenize(source) {
            var run = AttributedString(token.text)
            run.foregroundColor = token.color
            result += run
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "curlybraces").font(.system(size: 10, weight: .medium))
                    .foregroundStyle(BossWorkbenchStyle.muted)
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(BossWorkbenchStyle.muted)
                Spacer(minLength: 8)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10))
                        Text(copied ? "已复制" : "复制").font(.system(size: 11))
                    }
                    .foregroundStyle(copied ? IslandStyle.settingsGreen : BossWorkbenchStyle.muted)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(BossWorkbenchStyle.muted.opacity(0.07), in: Capsule())
                    .overlay(Capsule().stroke(BossWorkbenchStyle.border, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "已复制代码" : "复制代码")
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(BossWorkbenchStyle.sidebar,
                        in: UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 10, style: .continuous))
            Rectangle().fill(BossWorkbenchStyle.border).frame(height: 1)
            ScrollView([.horizontal, .vertical]) {
                Text(Self.highlighted(code))
                    .font(.system(size: 11, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: false)
                    .textSelection(.enabled)
                    .padding(10)
            }.frame(maxHeight: 160)
        }
        .background(BossWorkbenchStyle.paper, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(BossWorkbenchStyle.border, lineWidth: 1))
    }
}

struct ConnectionsView: View {
    private enum OperationAlert: Identifiable {
        case failure(String)
        case uninstall(ProviderID)
        case disconnect(ProviderID)

        var id: String {
            switch self {
            case .failure(let message): return "failure-\(message.hashValue)"
            case .uninstall(let provider): return "uninstall-\(provider.rawValue)"
            case .disconnect(let provider): return "disconnect-\(provider.rawValue)"
            }
        }
    }

    @ObservedObject var manager: ConnectionManager
    @ViewState private var plan: HookInstallationPlan?
    @ViewState private var busy: String?
    @ViewState private var error: String?
    @ViewState private var exportedPlugin: URL?
    @ViewState private var detailProvider: ProviderID?
    @ViewState private var refreshing = false
    @ViewState private var activeAlert: OperationAlert?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                Text("连接的应用").font(.system(size: 28, weight: .bold))
                Spacer()
                Button {
                    refreshing = true
                    Task { await manager.refresh(); refreshing = false }
                } label: {
                    Label(refreshing ? "正在检查…" : "检查连接", systemImage: "arrow.clockwise")
                }.disabled(busy != nil || refreshing)
            }
            Text("让应用中的任务进展，在灵宠岛同步呈现。")
                .foregroundStyle(BossWorkbenchStyle.muted).font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 14) {
                ForEach(manager.connections) { connection in
                    connectionCard(connection)
                }
            }
            if let exported = exportedPlugin {
                HStack(alignment: .top, spacing: 12) {
                    Text("已导出 \(exported.lastPathComponent)，解压后按包内说明手动安装。")
                        .font(.system(size: 13)).foregroundStyle(IslandStyle.settingsGreen).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("关闭提示") { exportedPlugin = nil }.buttonStyle(BossButtonStyle(kind: .quiet))
                }.padding(14).bossCard()
            }
        }
        .task { await manager.refresh() }
        .sheet(item: $plan) { item in
            VStack(alignment: .leading, spacing: 0) {
                Text("连接 \(item.displayName)").font(.system(size: 19, weight: .semibold))
                Text("向 \(abbreviatedPath(item.configurationURL.path)) 写入 \(item.hookLabels.count) 条同步命令")
                    .font(.system(size: 13)).foregroundStyle(BossWorkbenchStyle.muted).padding(.top, 5)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 6)], alignment: .leading, spacing: 6) {
                            ForEach(item.hookShortLabels, id: \.self) { label in
                                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(BossWorkbenchStyle.muted)
                                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                                    .background(BossWorkbenchStyle.muted.opacity(0.07), in: Capsule())
                                    .overlay(Capsule().stroke(BossWorkbenchStyle.border, lineWidth: 1))
                            }
                        }.padding(.top, 14)
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(keyPoints(item.reviewInstructions), id: \.self) { point in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "checkmark.circle").font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(IslandStyle.settingsGreen).padding(.top, 2)
                                    Text(point).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }.padding(.top, 14)
                        DisclosureGroup("高级选项") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(abbreviatedPath(item.configurationURL.path)).font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled).foregroundStyle(BossWorkbenchStyle.muted)
                                Text(item.summary).font(.system(size: 12)).foregroundStyle(BossWorkbenchStyle.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                                CodeBlockView(title: "\(item.configurationURL.lastPathComponent) · 灵宠岛片段", code: item.hookPreview)
                            }.padding(.top, 8)
                        }.font(.system(size: 13)).foregroundStyle(BossWorkbenchStyle.muted).padding(.top, 12)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.top, 2)
                Spacer(minLength: 14)
                HStack(spacing: 10) {
                    Link("来源文档", destination: item.documentationURL)
                    Spacer()
                    Button("取消") { plan = nil }
                    Button("安装") {
                        busy = item.provider.rawValue
                        Task { do { try await manager.install(provider: item.provider); plan = nil } catch { self.error = error.localizedDescription; plan = nil }; busy = nil }
                    }.buttonStyle(BossButtonStyle(kind: .primary)).disabled(busy != nil).keyboardShortcut(.defaultAction)
                }
            }
            .padding(24).frame(width: 560, height: 440)
            .background(BossWorkbenchStyle.canvas)
            .foregroundStyle(BossWorkbenchStyle.text)
            .tint(BossWorkbenchStyle.copperText)
            .buttonStyle(BossButtonStyle())
        }
        .alert(item: $activeAlert) { alert in
            switch alert {
            case .failure(let message):
                return Alert(title: Text("操作未完成"), message: Text(message),
                             dismissButton: .default(Text("好")))
            case .uninstall(let provider):
                return Alert(title: Text("卸载灵宠岛插件？"),
                             message: Text("将从 \(provider.displayName) 移除灵宠岛插件，之后的会话活动不再同步；已产生的工作台记录不受影响。"),
                             primaryButton: .destructive(Text("卸载")) { uninstallPlugin(provider) },
                             secondaryButton: .cancel(Text("取消")))
            case .disconnect(let provider):
                return Alert(title: Text("断开连接？"),
                             message: Text("将从 \(provider.displayName) 的配置中移除灵宠岛 Hook，之后的会话活动不再同步；其他设置保留，已产生的工作台记录不受影响。"),
                             primaryButton: .destructive(Text("断开")) { disconnect(provider) },
                             secondaryButton: .cancel(Text("取消")))
            }
        }
        .onChange(of: error) { _, value in
            guard let value else { return }
            error = nil
            activeAlert = .failure(value)
        }
    }

    private func uninstallPlugin(_ provider: ProviderID) {
        error = nil
        busy = provider.rawValue
        Task {
            do {
                switch provider {
                case .claude: try await manager.uninstallClaudePlugin()
                case .codex: try await manager.removeCodexPlugin()
                case .dsh: try await manager.uninstallDshPlugin()
                case .zcode: try await manager.uninstallZcodePlugin()
                case .qoder: try await manager.uninstallQoderPlugin()
                default: break
                }
            } catch { self.error = error.localizedDescription }
            busy = nil
        }
    }

    private func disconnect(_ provider: ProviderID) {
        error = nil
        busy = provider.rawValue
        Task {
            do { try await manager.remove(provider: provider) } catch { self.error = error.localizedDescription }
            busy = nil
        }
    }

    /// Install and update share one entry: it only appears when there is no
    /// working plugin, the bundled copy is newer, or something actually broke.
    private func pluginActionTitle(_ connection: ProviderConnection) -> String? {
        guard isPluginProvider(connection.provider) else { return nil }
        if connection.status == .needsRepair || connection.status == .needsReview || connection.status == .configurationError {
            return "修复插件接入"
        }
        if connection.pluginUpdateAvailable && connection.hasInstalledHooks { return "更新插件" }
        if !connection.hasInstalledHooks { return "安装插件" }
        return nil
    }

    private func isPluginProvider(_ provider: ProviderID) -> Bool {
        provider == .claude || provider == .codex || provider == .dsh || provider == .zcode || provider == .qoder
    }

    /// "Repair" only when the checked state actually reports a problem; a healthy
    /// installation gets a quiet config viewer instead of a scary primary button.
    private func hookActionTitle(_ connection: ProviderConnection) -> String {
        if connection.status == .needsRepair || connection.status == .configurationError { return "预览修复配置" }
        return connection.hasInstalledHooks ? "查看配置" : "预览连接配置"
    }

    private func hookActionIsPrimary(_ connection: ProviderConnection) -> Bool {
        !connection.hasInstalledHooks || connection.status == .needsRepair || connection.status == .configurationError
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private func keyPoints(_ instructions: String) -> [String] {
        instructions.split(separator: "。")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0 + "。" }
    }

    private func connectionCard(_ connection: ProviderConnection) -> some View {
        HStack(alignment: .top, spacing: 18) {
            PetView(source: connection.provider,
                    sourceApplication: connectionApplication(connection),
                    size: 48, requiresEnabledPet: true,
                    applicationURL: connection.detection.appURL)
                .frame(width: 52, height: 52)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(connection.displayName).font(.system(size: 19, weight: .semibold))
                        Text(connection.detection.appVersion.map { "版本 \($0)" }
                             ?? connection.detection.summary)
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(connection.detection.summary)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        Circle().fill(connectionStateColor(connection.status)).frame(width: 6, height: 6)
                        Text(connection.status.title)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(connectionStateColor(connection.status))
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(connectionStateColor(connection.status).opacity(0.08), in: Capsule())
                    .fixedSize()
                }
                // Actionable diagnostics stay visible. Healthy cards need no repeated explanation.
                if connection.status != .connected {
                    Text(connection.status == .installed
                         ? "请重启应用并开启新会话，完成连接验证。" : connection.message)
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ConnectionActionsLayout {
                    connectionActionButtons(connection)
                    connectionUtilities(connection)
                }
                .disabled(busy != nil)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(Color.black.opacity(0.07), lineWidth: 1))
        .shadow(color: .black.opacity(0.025), radius: 8, y: 3)
    }

    @ViewBuilder
    private func connectionActionButtons(_ connection: ProviderConnection) -> some View {
        Group {
            if isPluginProvider(connection.provider) {
                if let title = pluginActionTitle(connection) {
                    Button(busy == connection.id ? "正在处理…" : title) {
                        installPlugin(connection)
                    }.buttonStyle(BossButtonStyle(kind: .primary))
                    .disabled(connection.provider == .codex && connection.detection.cliURL == nil)
                }
            } else {
                Button(hookActionTitle(connection)) {
                    error = nil
                    busy = connection.id
                    Task {
                        do { plan = try await manager.prepare(provider: connection.provider) }
                        catch { self.error = error.localizedDescription }
                        busy = nil
                    }
                }.buttonStyle(BossButtonStyle(kind: hookActionIsPrimary(connection) ? .primary : .secondary))
            }
            if connection.detection.appURL != nil {
                Button { openSourceApplication(connection) } label: {
                    Label("打开 \(connection.provider == .qoder ? "Qoder" : connection.displayName)", systemImage: "arrow.up.forward.square")
                }
            }
            if isPluginProvider(connection.provider) {
                Button { exportPlugin(connection.provider) } label: {
                    Label("手动安装", systemImage: "shippingbox")
                }
                .help("导出插件包；解压后按包内说明手动安装")
            }
        }
    }

    private func connectionUtilities(_ connection: ProviderConnection) -> some View {
        HStack(spacing: 12) {
            if busy == connection.id { ProgressView().controlSize(.small) }
            Button { detailProvider = connection.provider } label: {
                Image(systemName: "info.circle").frame(width: 28, height: 30)
            }
            .help("连接详情与安装说明")
            .accessibilityLabel("\(connection.displayName)连接详情与安装说明")
            .popover(isPresented: Binding(
                get: { detailProvider == connection.provider },
                set: { if !$0 { detailProvider = nil } }
            )) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("连接详情").font(.system(size: 17, weight: .semibold))
                    Text(connection.detection.summary).textSelection(.enabled)
                    Text(connection.message)
                    if let instructions = installationNotes(connection.provider) {
                        Divider()
                        Text("安装说明").fontWeight(.semibold)
                        Text(instructions)
                    }
                }
                .font(.system(size: 14))
                .fixedSize(horizontal: false, vertical: true)
                .padding(22).frame(width: 380)
            }
            if connection.hasInstalledHooks {
                Button {
                    activeAlert = isPluginProvider(connection.provider)
                        ? .uninstall(connection.provider) : .disconnect(connection.provider)
                } label: {
                    Image(systemName: "trash").frame(width: 28, height: 30)
                }
                .help(isPluginProvider(connection.provider) ? "卸载插件" : "断开连接")
                .accessibilityLabel(isPluginProvider(connection.provider) ? "卸载插件" : "断开连接")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func installPlugin(_ connection: ProviderConnection) {
        error = nil
        busy = connection.id
        Task {
            do {
                switch connection.provider {
                case .claude: try await manager.installClaudePlugin()
                case .codex: try await manager.installCodexPlugin()
                case .dsh: try await manager.installDshPlugin()
                case .zcode: try await manager.installZcodePlugin()
                case .qoder: try await manager.installQoderPlugin()
                default: break
                }
            } catch { self.error = error.localizedDescription }
            busy = nil
        }
    }

    private func installationNotes(_ provider: ProviderID) -> String? {
        switch provider {
        case .claude: return "安装为 Claude 用户级插件，本机 CLI、Claude App 的 Code 和 IDE 共用。安装后重启 Claude，再开启新的本机会话；支持完整预览的 Bash 和网页搜索单次审批；复杂操作和问题回复返回 Claude 处理。"
        case .codex: return "安装成功后自动清理灵宠岛的旧版直接 Hook。首次使用请在 Codex 中审查钩子，再开启新会话。"
        case .dsh: return "安装为 dsh 组合包，可在 DeepSeek Harness 的「插件 → 已安装插件」里看到并开关。安装后请完全退出并重启应用，再开启新会话。"
        case .zcode: return "安装为 ZCode 本地插件市场的插件，可在 ZCode 的「插件管理 → 已安装」里看到并开关。安装会清理旧版写入配置的 Hook；完成后请重启 ZCode，再开启新会话。"
        case .qoder: return "安装为 Qoder 原生插件，可在 Qoder 的插件管理里看到并开关。安装会清理旧版写入 settings.json 的 Hook；完成后请重启 Qoder，再开启新会话。"
        default: return nil
        }
    }

    private func connectionApplication(_ connection: ProviderConnection) -> SourceApplicationID? {
        switch connection.provider {
        case .codebuddy: return .codebuddyCNIDE
        case .workbuddy: return .workbuddyDesktop
        case .claude: return .claudeDesktop
        case .codex: return .codexDesktop
        case .zcode: return .zcodeDesktop
        case .dsh: return .dshDesktop
        case .generic: return nil
        case .qoder:
            if let url = connection.detection.appURL,
               Bundle(url: url)?.bundleIdentifier == SourceApplicationID.qoderIDE.bundleIdentifier { return .qoderIDE }
            return .qoderDesktop
        }
    }

    private func connectionStateColor(_ status: ConnectionStatus) -> Color {
        switch status {
        case .connected, .installed: return IslandStyle.settingsGreen
        case .needsReview, .needsRepair: return Color(hex: 0x986123)
        case .configurationError: return Color(hex: 0xB54444)
        case .notDetected, .notInstalled: return BossWorkbenchStyle.muted
        }
    }

    /// Launch through `/usr/bin/open` with a sanitized environment. Forwarding
    /// `ELECTRON_RUN_AS_NODE` from an Electron host turns a cold Electron app
    /// into a Node process: it starts, opens no window and exits immediately.
    private func openSourceApplication(_ connection: ProviderConnection) {
        guard let application = connection.detection.appURL else {
            error = "未找到 \(connection.displayName) 的应用路径。"
            return
        }
        error = nil
        var environment = ProcessInfo.processInfo.environment
        for key in ["ELECTRON_RUN_AS_NODE", "ELECTRON_NO_ATTACH_CONSOLE", "ELECTRON_ENABLE_LOGGING",
                    "ELECTRON_ENABLE_STACK_DUMPING", "ELECTRON_DEFAULT_ERROR_MODE",
                    "NODE_OPTIONS", "NODE_ENV", "NODE_PATH", "NODE_EXTRA_CA_CERTS"] {
            environment.removeValue(forKey: key)
        }
        let name = connection.displayName
        Task { @MainActor in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", application.path]
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus != 0 else { return }
                self.error = "无法打开 \(name)。"
            } catch {
                self.error = "无法打开 \(name)：\(error.localizedDescription)"
            }
        }
    }

    private func exportPlugin(_ provider: ProviderID) {
        switch provider {
        case .claude: exportClaudePlugin()
        case .codex: exportCodexPlugin()
        case .dsh: exportDshPlugin()
        case .zcode: exportZcodePlugin()
        case .qoder: exportQoderPlugin()
        default: break
        }
    }

    private func exportClaudePlugin() {
        error = nil
        guard let source = Bundle.main.url(forResource: "ClaudePlugin", withExtension: "zip") else {
            error = "当前构建未包含 Claude 插件包，请使用完整发行版。"
            return
        }
        let panel = NSSavePanel()
        panel.title = "导出灵宠岛 Claude 插件"
        panel.nameFieldStringValue = "灵宠岛-Claude插件.zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try Data(contentsOf: source).write(to: destination, options: .atomic)
            exportedPlugin = destination
        } catch { self.error = "导出插件失败：\(error.localizedDescription)" }
    }

    private func exportCodexPlugin() {
        error = nil
        guard let source = Bundle.main.url(forResource: "LingChongDaoCodexPlugin", withExtension: "zip") else {
            error = "当前构建未包含 Codex 插件包，请使用完整发行版。"
            return
        }
        let panel = NSSavePanel()
        panel.title = "导出灵宠岛 Codex 插件"
        panel.nameFieldStringValue = "灵宠岛-Codex插件.zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let data = try Data(contentsOf: source)
            try data.write(to: destination, options: .atomic)
            exportedPlugin = destination
        } catch {
            self.error = "导出插件失败：\(error.localizedDescription)"
        }
    }

    private func exportDshPlugin() {
        error = nil
        guard let source = Bundle.main.url(forResource: "DshPlugin", withExtension: "zip") else {
            error = "当前构建未包含 dsh 插件包，请使用完整发行版。"
            return
        }
        let panel = NSSavePanel()
        panel.title = "导出灵宠岛 dsh 插件"
        panel.nameFieldStringValue = "灵宠岛-Dsh插件.zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let data = try Data(contentsOf: source)
            try data.write(to: destination, options: .atomic)
            exportedPlugin = destination
        } catch {
            self.error = "导出插件失败：\(error.localizedDescription)"
        }
    }

    private func exportZcodePlugin() {
        error = nil
        guard let source = Bundle.main.url(forResource: "ZcodePlugin", withExtension: "zip") else {
            error = "当前构建未包含 ZCode 插件包，请使用完整发行版。"
            return
        }
        let panel = NSSavePanel()
        panel.title = "导出灵宠岛 ZCode 插件"
        panel.nameFieldStringValue = "灵宠岛-ZCode插件.zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let data = try Data(contentsOf: source)
            try data.write(to: destination, options: .atomic)
            exportedPlugin = destination
        } catch {
            self.error = "导出插件失败：\(error.localizedDescription)"
        }
    }

    private func exportQoderPlugin() {
        error = nil
        guard let source = Bundle.main.url(forResource: "QoderPlugin", withExtension: "zip") else {
            error = "当前构建未包含 Qoder 插件包，请使用完整发行版。"
            return
        }
        let panel = NSSavePanel()
        panel.title = "导出灵宠岛 Qoder 插件"
        panel.nameFieldStringValue = "灵宠岛-Qoder插件.zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            let data = try Data(contentsOf: source)
            try data.write(to: destination, options: .atomic)
            exportedPlugin = destination
        } catch {
            self.error = "导出插件失败：\(error.localizedDescription)"
        }
    }

}
