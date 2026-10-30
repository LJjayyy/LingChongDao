import AppKit
import IslandCore
import SwiftUI

struct IslandView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var context: IslandWindowContext
    @ObservedObject private var keepAwake = KeepAwakeController.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var draft = ""
    @ViewState private var pinned: IslandSession?
    @ViewState private var lockError: String?
    @ViewState private var measuredHeight: CGFloat = 160
    @FocusState private var answerFocused: Bool
    @Namespace private var petTransition

    /// Automatic reveals select from the announced sessions; message details
    /// show only the current item. The compact shell keeps the full overview.
    private var displaySessions: [IslandSession] {
        guard let focus = context.attentionFocus else { return model.visibleSessions }
        return model.visibleSessions.filter { focus.contains($0.id) }
    }
    private var top: IslandSession? { displaySessions.first }
    private var shown: IslandSession? { pinned ?? top }
    private var showsTaskList: Bool { context.attentionFocus == nil && pinned == nil && top != nil && top?.isAwaitingInteraction == false && (top?.phase == .running || displaySessions.count > 1) }
    private var width: CGFloat { context.expanded ? context.expandedWidth : context.compactWidth + (context.hovering ? IslandMotion.hoverWidth : 0) }
    private var height: CGFloat { context.expanded ? min(480, context.compactHeight + measuredHeight) : context.compactHeight + (context.hovering ? IslandMotion.hoverHeight : 0) }
    private var sidePadding: CGFloat { context.hasNotch ? 39 : 20 }
    private var requestKey: String { shown?.question?.id ?? shown?.approval?.id ?? shown?.id ?? "idle" }
    private var expired: Bool {
        guard let session = shown else { return false }
        if let question = session.question {
            let live = model.sessions.first(where: { $0.id == session.id })
            return question.isExpired() || live?.question?.id != question.id || live?.hasPendingQuestion != true
        }
        if let approval = session.approval {
            let live = model.sessions.first(where: { $0.id == session.id })
            return approval.isExpired() || live?.approval?.id != approval.id || live?.hasPendingApproval != true
        }
        return false
    }

    private struct SurfaceTarget: Equatable {
        let expanded: Bool
        let width: CGFloat
        let height: CGFloat
    }
    private var surfaceTarget: SurfaceTarget { SurfaceTarget(expanded: context.expanded, width: width, height: height) }
    private var shell: IslandShell { IslandShell(notch: context.hasNotch, expansion: context.expanded ? 1 : 0) }
    private var surfaceAnimation: Animation? {
        guard !reduceMotion else { return nil }
        return .spring(duration: IslandMotion.surfaceDuration,
                       bounce: IslandMotion.surfaceBounce, blendDuration: 0.08)
    }
    private var contentAnimation: Animation? {
        guard !reduceMotion else { return nil }
        return context.expanded
            ? .easeOut(duration: IslandMotion.contentEnterDuration).delay(IslandMotion.contentEnterDelay)
            : .easeOut(duration: IslandMotion.contentExitDuration)
    }
    /// Rows collapsing after a neighbor is swiped away reuse the surface spring,
    /// so the list and the island shell settle together.
    private var rowListAnimation: Animation? {
        guard !reduceMotion else { return nil }
        return .spring(duration: IslandMotion.surfaceDuration,
                       bounce: IslandMotion.surfaceBounce, blendDuration: 0.08)
    }

    var body: some View {
        // Both layers keep their identity and final layout while concealed. This
        // prepares the destination before the shell starts moving, so its height
        // never begins at a guessed value and snaps after the first measurement.
        ZStack(alignment: .top) {
            compact
                .frame(width: min(context.compactWidth + (context.hovering ? IslandMotion.hoverWidth : 0), context.availableWidth))
                .animation(reduceMotion ? nil : .easeOut(duration: context.expanded ? 0.09 : 0.14)) { layer in
                    layer.opacity(context.expanded ? 0 : 1)
                }
                .allowsHitTesting(!context.expanded)
                .disabled(context.expanded)
                .accessibilityHidden(context.expanded)
            expandedLayer
                .animation(contentAnimation) { layer in layer.opacity(context.expanded ? 1 : 0) }
                .allowsHitTesting(context.expanded)
                .disabled(!context.expanded)
                .accessibilityHidden(!context.expanded)
        }
        .frame(width: min(width, context.availableWidth), height: height, alignment: .top)
        .background(shell.fill(.black))
        .contentShape(shell)
        .clipShape(shell)
        .shadow(color: .black.opacity(context.expanded ? 0.18 : 0), radius: 14, y: 8)
        .font(IslandStyle.bodyFont).foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .animation(surfaceAnimation, value: surfaceTarget)
        .transaction { if reduceMotion { $0.animation = nil } }
        .onHover { context.setHovered(active: $0, hasActivity: top != nil) }
        .onAppear { updateSize(); reloadDraft() }
        .onChange(of: displaySessions.map { $0.id + ($0.approval?.id ?? $0.question?.id ?? $0.phase.rawValue) }) { _, _ in
            updateSize(); if pinned == nil { reloadDraft() }
        }
        .onChange(of: displaySessions.map(\.id)) { _, _ in
            // A focused reveal ends when its last attention row is handled or
            // dismissed; never let the surface turn into a blank panel.
            if context.attentionFocus != nil, displaySessions.isEmpty, !context.busy { context.collapse() }
        }
        .onChange(of: statusCounts) { _, _ in updateSize() }
        .onChange(of: keepAwake.isEnabled) { _, _ in updateSize() }
        .onChange(of: keepAwake.isChanging) { _, _ in updateSize() }
        .onChange(of: context.compactWidth) { _, _ in updateSize() }
        .onChange(of: model.sessions) { _, _ in
            if let previous = pinned, previous.source == .claude,
               let live = model.sessions.first(where: { $0.id == previous.id }),
               live.hasPendingApproval, previous.approval?.id != live.approval?.id { pinned = live }
            if pinned != nil && expired {
                // Keep the visible draft until collapse, but release the editor
                // lock so a finished request cannot keep the island pinned open.
                answerFocused = false
                context.endEditing()
            }
        }
        .onChange(of: context.expanded) { _, expanded in
            if !expanded { answerFocused = false; pinned = nil; lockError = nil }
            else { reloadDraft(); updateSize() }
        }
        .onChange(of: draft) { _, value in
            if draft.count > 20_000 { draft = String(draft.prefix(20_000)) }
            if let session = shown { model.saveDraft(value, session: session) }
        }
        .onExitCommand { context.collapse() }
    }

    private var expandedLayer: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                expandedBody
                if showsTaskList || shown == nil { keepAwakeToolbar }
            }
                .padding(.horizontal, sidePadding)
                .padding(.top, 8).padding(.bottom, showsTaskList ? 8 : 16)
                .frame(width: context.expandedWidth, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { contentDidMeasure(proxy.size.height) }
                            .onChange(of: proxy.size.height) { _, value in contentDidMeasure(value) }
                    }
                }
        }
        .scrollIndicators(.hidden)
        .frame(width: context.expandedWidth, height: min(480 - context.compactHeight, measuredHeight))
        .padding(.top, context.compactHeight)
    }

    private var compactPetWidth: CGFloat {
        20 + CGFloat(max(0, min(3, model.visibleSessions.count) - 1)) * 15
    }
    private var statusCounts: [SessionStatusCount] { SessionStatusSummary.counts(for: model.visibleSessions) }
    private func badgeWidth(_ count: SessionStatusCount) -> CGFloat { 18 + CGFloat(count.displayCount.count) * 6 }
    private var compactBadgeWidth: CGFloat {
        statusCounts.reduce(0) { $0 + badgeWidth($1) } + CGFloat(max(0, statusCounts.count - 1)) * 4
    }
    private var showsAwakeIndicator: Bool { keepAwake.isEnabled || keepAwake.isChanging }
    private var compactTrailingWidth: CGFloat {
        compactBadgeWidth + (showsAwakeIndicator ? (compactBadgeWidth > 0 ? 4 : 0) + 20 : 0)
    }
    private var compactStatusDescription: String {
        let awake = keepAwake.isChanging ? keepAwake.actionTitle + "，" : keepAwake.state == .partial ? "保持唤醒需恢复休眠，" : (keepAwake.isEnabled ? "保持唤醒中，" : "")
        guard !statusCounts.isEmpty else { return awake + "没有会话活动" }
        let states = statusCounts.map { "\($0.kind.title) \($0.count) 个" }.joined(separator: "，")
        return awake + "\(states)，共 \(model.visibleSessions.count) 个会话"
    }
    private var statusBadges: some View {
        HStack(spacing: 4) {
            ForEach(statusCounts) { count in
                Text(count.displayCount).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .frame(width: badgeWidth(count), height: 20)
                    .foregroundStyle(statusColor(count.kind))
                    .background(statusColor(count.kind).opacity(0.16), in: Capsule())
                    .accessibilityLabel("\(count.kind.title) \(count.count) 个")
            }
        }.fixedSize(horizontal: true, vertical: false)
    }
    private var compactIndicators: some View {
        HStack(spacing: 4) {
            if !statusCounts.isEmpty { statusBadges }
            if showsAwakeIndicator {
                Image(systemName: keepAwake.isChanging ? "hourglass" : "cup.and.saucer.fill").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(IslandStyle.orange).frame(width: 20, height: 20)
                    .accessibilityLabel(keepAwake.isChanging ? keepAwake.actionTitle : (keepAwake.state == .partial ? "保持唤醒需恢复休眠" : "保持唤醒中"))
            }
        }.fixedSize(horizontal: true, vertical: false)
    }
    private var keepAwakeToolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
            HStack {
                Button { keepAwake.toggle(); model.haptic() } label: {
                    Label(keepAwake.actionTitle,
                          systemImage: keepAwake.isEnabled ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .foregroundStyle(keepAwake.isEnabled ? IslandStyle.orange : IslandStyle.secondary)
                }
                .buttonStyle(IslandActionStyle())
                .accessibilityLabel("保持唤醒")
                .accessibilityValue(keepAwake.accessibilityValue)
                .disabled(keepAwake.isChanging)
                .help(KeepAwakeController.scopeDescription)
                Spacer(minLength: 8)
                Text(keepAwake.statusText)
                    .font(.system(size: 11)).foregroundStyle(IslandStyle.secondary)
            }
            if let error = keepAwake.errorMessage {
                Text(error).foregroundStyle(IslandStyle.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var compact: some View {
        Button {
            if top == nil { model.openWorkbench?() }
            else { context.toggle(); model.haptic() }
        } label: {
            HStack(spacing: 0) {
                compactPets
                    .frame(width: context.hasNotch ? max(compactPetWidth, compactTrailingWidth) : compactPetWidth, alignment: .leading)
                Spacer(minLength: context.hasNotch ? context.notchWidth + 16 : (top == nil && !showsAwakeIndicator ? 0 : 10))
                if context.hasNotch {
                    Group {
                        if top != nil || showsAwakeIndicator { compactIndicators }
                        else { Color.clear.frame(width: compactPetWidth, height: 20) }
                    }.frame(width: max(compactPetWidth, compactTrailingWidth), alignment: .trailing)
                } else if top != nil || showsAwakeIndicator { compactIndicators }
            }.padding(.horizontal, context.hasNotch ? 12 : 10)
                .frame(height: context.compactHeight + (context.hovering ? IslandMotion.hoverHeight : 0))
        }.buttonStyle(.plain)
            .accessibilityLabel(top == nil ? "打开工作台" : "展开灵宠岛")
            .accessibilityValue(compactStatusDescription)
            .help(compactStatusDescription)
    }
    private var compactPets: some View {
        HStack(spacing: -5) {
            if model.visibleSessions.isEmpty {
                DefaultPetView(size: 20, isAttentive: context.hovering)
                    .animation(reduceMotion ? nil : .spring(duration: IslandMotion.hoverDuration, bounce: 0.04)) { pet in
                        pet.scaleEffect(!reduceMotion && context.hovering ? 1.08 : 1)
                    }
            } else {
                ForEach(Array(model.visibleSessions.prefix(3))) { session in
                    sessionPet(session, size: 20, expandedPet: false)
                        .animation(reduceMotion ? nil : .spring(duration: IslandMotion.hoverDuration, bounce: 0.04)) { pet in
                            pet.scaleEffect(!reduceMotion && context.hovering ? 1.08 : 1)
                        }
                }
            }
        }
    }

    @ViewBuilder private func sessionPet(_ session: IslandSession, size: CGFloat, expandedPet: Bool) -> some View {
        // Only the leading session participates: one compact and one expanded
        // copy, with exactly one geometry source. Editing pins keep their layout.
        if !reduceMotion, pinned == nil, top?.id == session.id {
            PetView(source: session.source, phase: session.phase, sourceApplication: session.petSourceApplication, size: size)
                .matchedGeometryEffect(id: session.id, in: petTransition, properties: .frame,
                                       isSource: expandedPet == context.expanded)
        } else {
            PetView(source: session.source, phase: session.phase, sourceApplication: session.petSourceApplication, size: size)
        }
    }

    @ViewBuilder private var expandedBody: some View {
        if showsTaskList {
            VStack(spacing: 2) {
                ForEach(displaySessions) { session in taskRow(session) }
            }
            .animation(rowListAnimation, value: displaySessions.map(\.id))
        } else if let session = shown {
            VStack(alignment: .leading, spacing: 10) {
                Button { openMessageSource(session) } label: {
                    identity(session)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(model.navigationLabel(for: session))：\(session.displayTitle)，\(identityStatus(session))")
                .accessibilityValue(session.question?.prompt ?? session.approval?.summary ?? (session.detail.isEmpty ? session.displayTitle : session.detail))
                .help(model.navigationHelp(for: session))
                if let question = session.question { questionCard(question, session: session) }
                else if let approval = session.approval { approvalCard(approval, session: session) }
                else { resultFooter(session) }
                if let error = lockError ?? model.actionError {
                    Text(error).foregroundStyle(IslandStyle.red).fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            IdleBossEncounterView(isActive: context.idleEncounterActive,
                                 encounterNumber: context.idleEncounterNumber) {
                context.collapse()
                model.openWorkbench?()
            }
            .id(context.idleEncounterNumber)
        }
    }

    private func taskRow(_ session: IslandSession) -> some View {
        SwipeDismissRow(reduceMotion: reduceMotion, haptic: { model.haptic() },
                        tap: { model.navigate(to: session); context.collapse() },
                        dismiss: { removeBySwipe(session) }) {
            taskRowContent(session)
        }
    }

    /// Swiping a row away is an explicit manual clear; it also works while the
    /// task is running, which is the only way to retire a source that stopped
    /// speaking. A live approval or question is never swallowed.
    private func removeBySwipe(_ session: IslandSession) -> Bool {
        let applied = model.dismiss(session, force: true)
        if applied, model.visibleSessions.isEmpty { context.collapse() }
        return applied
    }

    private func taskRowContent(_ session: IslandSession) -> some View {
        HStack(spacing: 8) {
            sessionPet(session, size: 32, expandedPet: true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(session.displayTitle).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    expandedStateBadge(session)
                }
                if !session.detail.isEmpty {
                    Text(session.detail).foregroundStyle(IslandStyle.secondary).lineLimit(1)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 6).padding(.horizontal, 8)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(session.displayTitle)，\(sessionStateTitle(session))，\(session.sourceDisplayName)")
            .accessibilityValue(session.detail)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: Text("打开会话")) { model.navigate(to: session); context.collapse() }
            .help(model.navigationHelp(for: session))
    }

    private func sessionStateTitle(_ session: IslandSession) -> String {
        if session.approval?.isExpired() == true || session.question?.isExpired() == true { return "已过期" }
        if session.hasPendingQuestion { return "待回答" }
        if session.hasPendingApproval { return session.approval?.canApprove == true ? "待批准" : "待确认" }
        switch session.phase {
        case .running: return "运行中"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .interrupted: return "已中断"
        default: return "本轮结束"
        }
    }

    private func expandedStateBadge(_ session: IslandSession) -> some View {
        let isExpired = session.approval?.isExpired() == true || session.question?.isExpired() == true
        let color = isExpired ? IslandStyle.secondary : statusColor(SessionStatusKind(session: session))
        return Text(sessionStateTitle(session)).font(.system(size: 10, weight: .medium))
            .foregroundStyle(color).padding(.horizontal, 6).padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
    }

    private func identity(_ session: IslandSession) -> some View {
        HStack(alignment: .top, spacing: 8) {
            sessionPet(session, size: context.hasNotch ? 35 : 38, expandedPet: true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(session.displayTitle).fontWeight(.semibold).lineLimit(1).truncationMode(.tail).layoutPriority(1)
                    expandedStateBadge(session)
                }
                Text(session.question?.prompt ?? session.approval?.summary ?? (session.detail.isEmpty ? session.displayTitle : session.detail))
                    .foregroundStyle(IslandStyle.body).lineLimit(4).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if session.question == nil && session.approval == nil {
                Text(session.updatedAt, style: .relative).foregroundStyle(IslandStyle.secondary).font(.system(size: 11)).lineLimit(1)
            }
        }.frame(minHeight: 43, alignment: .top)
    }

    @ViewBuilder private func questionCard(_ question: QuestionRequest, session: IslandSession) -> some View {
        if question.canAnswer || (pinned != nil && expired) {
            VStack(spacing: 6) {
                ForEach(Array(question.options.prefix(12).enumerated()), id: \.offset) { index, option in
                    Button { submitAnswer(option, session: session) } label: {
                        HStack(spacing: 8) {
                            Text("\(index + 1)").fontWeight(.semibold).frame(width: 22, height: 22)
                                .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
                            Text(option).fontWeight(.medium).frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
                        }.padding(.horizontal, 10).padding(.vertical, 7).frame(minHeight: 48)
                            .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }.buttonStyle(.plain).disabled(expired)
                }
            }
            HStack(spacing: 6) {
                TextField(question.options.isEmpty ? "输入你的回答" : "或输入自定义回答", text: $draft)
                    .textFieldStyle(.plain).font(.system(size: 12)).focused($answerFocused)
                    .disabled(expired)
                    .onSubmit {
                        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.hasMarkedText() { return }
                        submitAnswer(draft, session: session)
                    }
                    .onChange(of: answerFocused) { _, focused in
                        if focused {
                            if context.beginEditing(requestID: question.id) { pinned = session }
                            else { answerFocused = false; lockError = "请先完成另一块屏幕上的输入。" }
                        }
                    }
                Button { submitAnswer(draft, session: session) } label: {
                    Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold)).frame(width: 24, height: 24)
                        .foregroundStyle(Color.black).background(Color.white, in: Circle())
                }.buttonStyle(.plain).disabled(expired || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("发送回答")
            }.padding(.leading, 12).padding(.trailing, 4).frame(height: 32)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            Text("请在完整会话中回答这个问题。").foregroundStyle(IslandStyle.body)
        }
        if expired { expiredNotice }
        footer {
            Button("稍后") { context.collapse() }.buttonStyle(IslandActionStyle())
            Spacer()
            Button(model.navigationLabel(for: session)) { model.navigate(to: session); context.collapse() }.buttonStyle(IslandActionStyle())
        }
    }

    @ViewBuilder private func approvalCard(_ request: ApprovalRequest, session: IslandSession) -> some View {
        if request.canApprove, let command = request.command {
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(IslandStyle.orange).frame(width: 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack { Text(request.previewLabel ?? "命令"); Spacer(); Text(request.cwd).lineLimit(1).truncationMode(.middle) }.foregroundStyle(IslandStyle.secondary)
                    Text(command).font(.system(size: 12, design: .monospaced)).foregroundStyle(IslandStyle.body)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).lineLimit([ProviderID.claude, .codex, .qoder].contains(session.source) ? nil : 8)
                }
            }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 2)
        } else if !expired {
            Text("请打开完整会话，核对这次操作的详细信息。").foregroundStyle(IslandStyle.body)
        }
        if expired { expiredNotice }
        else if (request.canApprove || request.canDeny), let deadline = request.expiresAt {
            Text("\(max(0, Int(deadline.timeIntervalSinceNow))) 秒后返回原工具处理").foregroundStyle(IslandStyle.orange).font(.system(size: 11))
        }
        footer {
            Spacer()
            if request.canDeny || expired {
                Button("拒绝") { model.respond(to: session, decision: .deny) }.buttonStyle(IslandActionStyle()).disabled(expired)
            }
            if request.canApprove {
                Button([ProviderID.claude, .codex, .qoder].contains(session.source) ? "批准一次" : "批准") { model.respond(to: session, decision: .allow) }.buttonStyle(IslandActionStyle(primary: true)).disabled(expired)
            }
            if expired || ([ProviderID.claude, .codex, .qoder].contains(session.source) && !request.canApprove && !request.canDeny) {
                Button("关闭提示") { model.dismiss(session); context.collapse() }.buttonStyle(IslandActionStyle())
            }
        }
    }

    private var expiredNotice: some View {
        Text(shown?.question != nil
             ? "岛内处理已结束，草稿已保留，请回来源应用继续。"
             : "灵宠岛的审批通道已结束，请回来源应用确认最新权限状态。")
            .foregroundStyle(IslandStyle.body).padding(9).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func resultFooter(_ session: IslandSession) -> some View {
        footer {
            if session.phase == .failed || session.phase == .interrupted || session.phase == .idle {
                Button("关闭提示") { model.dismiss(session); context.collapse() }.buttonStyle(IslandActionStyle())
            } else { Text("\(displaySessions.filter { $0.unread }.count) 个新结果").foregroundStyle(IslandStyle.secondary) }
            Spacer()
            Button(model.navigationLabel(for: session)) { model.navigate(to: session); context.collapse() }.buttonStyle(IslandActionStyle(primary: true))
        }
    }

    private func footer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 8) { Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1); HStack(spacing: 4, content: content) }
    }

    private func openMessageSource(_ session: IslandSession) {
        if let request = session.approval, !expired, request.canApprove || request.canDeny {
            model.respond(to: session, decision: .fallback)
        }
        model.navigate(to: session)
        context.collapse()
    }

    private func statusColor(_ kind: SessionStatusKind) -> Color {
        switch kind {
        case .question: return IslandStyle.cyan
        case .approval: return IslandStyle.orange
        case .attention: return IslandStyle.red
        case .running: return IslandStyle.green
        case .result: return IslandStyle.blue
        }
    }
    private func identityStatus(_ session: IslandSession) -> String {
        if session.question != nil { return expired ? "岛内处理已结束" : "正在询问" }
        if let approval = session.approval {
            if expired { return "岛内处理已结束" }
            return approval.canApprove || approval.canDeny ? "需要你的批准" : "请在来源确认"
        }
        switch session.phase { case .completed: return "本轮已完成"; case .failed: return "本轮执行失败"; case .interrupted: return "本轮已中断"; case .running: return "正在工作"; default: return "本轮已结束" }
    }
    private func updateSize() {
        context.setCompactContentSize(leadingWidth: compactPetWidth, trailingWidth: compactTrailingWidth)
        let baseWidth: CGFloat = (top == nil || showsTaskList) ? 420 : (context.hasNotch ? 590 : 552)
        context.setContentSize(width: max(baseWidth, context.compactWidth), height: min(480, context.compactHeight + measuredHeight))
    }
    private func contentDidMeasure(_ value: CGFloat) {
        // Measure natural content at its final expanded width even while closed.
        // The hidden layer cannot receive clicks, keyboard focus or accessibility.
        // Later live content changes still retarget the same surface spring.
        guard value.isFinite, value > 0 else { return }
        guard abs(measuredHeight - value) > 0.5 else { return }
        measuredHeight = value
        updateSize()
        if ProcessInfo.processInfo.environment["LINGCHONGDAO_VERIFY_WINDOWS"] == "1" {
            let message = "LingChongDao content-height screen=\(context.screenID) request=\(requestKey) body=\(value) total=\(height)\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
    }
    private func reloadDraft() { if let session = shown { draft = model.draft(for: session) } else { draft = "" } }
    private func submitAnswer(_ value: String, session: IslandSession) {
        guard !expired else { return }
        model.answer(value, session: session)
        if model.actionError == nil { pinned = nil; draft = ""; context.endEditing(); answerFocused = false }
    }
}
