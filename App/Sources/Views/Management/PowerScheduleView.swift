import SwiftUI
import DSMKit

/// 系统 › 开关机计划. Edits stay local until 保存, which asks for confirmation
/// because a wrong power-off time shuts the NAS down.
struct PowerScheduleView: View {
    enum Kind: String, Identifiable { case on = "开机", off = "关机"; var id: String { rawValue } }

    struct Editing: Identifiable {
        let id = UUID()
        let kind: Kind
        var task: PowerTask
        let isNew: Bool
    }

    @Environment(SessionManager.self) private var session
    @State private var original: PowerSchedule?
    @State private var schedule = PowerSchedule()
    @State private var loadError: String?
    @State private var editing: Editing?
    @State private var confirmSave = false
    @State private var saving = false
    @State private var alert: String?
    @State private var saved = false

    private var dirty: Bool { original != nil && original != schedule }

    var body: some View {
        List {
            if let loadError {
                Section { Text(loadError).foregroundStyle(Theme.warning) }
            }
            if original != nil {
                section(.on, tasks: $schedule.powerOn, symbol: "power.circle.fill", color: Theme.good)
                section(.off, tasks: $schedule.powerOff, symbol: "moon.circle.fill", color: Theme.warning)
                Section {
                } footer: {
                    Text("自动开机需要 NAS 接通电源且主板支持定时开机。开机与关机时间至少相隔几分钟，避免刚开机就被关掉。")
                }
            }
        }
        .overlay { if original == nil && loadError == nil { ProgressView() } }
        .navigationTitle("开关机计划")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving {
                    ProgressView()
                } else {
                    Button(saved && !dirty ? "已保存" : "保存") { confirmSave = true }.disabled(!dirty)
                }
            }
        }
        .task { await load() }
        .sheet(item: $editing) { item in
            PowerTaskEditor(kind: item.kind, task: item.task, isNew: item.isNew) { result in
                apply(result, kind: item.kind, isNew: item.isNew)
            }
        }
        .confirmationDialog("保存开关机计划？", isPresented: $confirmSave, titleVisibility: .visible) {
            Button("保存到 NAS") { Task { await save() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
        .alert("操作失败", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alert ?? "")
        }
    }

    private var confirmMessage: String {
        let off = schedule.powerOff.filter(\.enabled).map(\.summary)
        let on = schedule.powerOn.filter(\.enabled).map(\.summary)
        var lines: [String] = []
        lines.append(on.isEmpty ? "自动开机：无" : "自动开机：" + on.joined(separator: "；"))
        lines.append(off.isEmpty ? "自动关机：无" : "自动关机：" + off.joined(separator: "；"))
        if !off.isEmpty { lines.append("到点后 NAS 会直接关机，正在运行的任务和连接都会中断。") }
        return lines.joined(separator: "\n")
    }

    private func section(_ kind: Kind, tasks: Binding<[PowerTask]>, symbol: String, color: Color) -> some View {
        Section {
            ForEach(tasks) { $task in
                Button {
                    editing = Editing(kind: kind, task: task, isNew: false)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: symbol).font(.title2).foregroundStyle(task.enabled ? color : Theme.secondaryText)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: "%02d:%02d", task.hour, task.minute))
                                .font(.title3.weight(.semibold).monospacedDigit())
                                .foregroundStyle(task.enabled ? .primary : Theme.secondaryText)
                            Text(PowerTask.describe(task.weekdays)).font(.caption).foregroundStyle(Theme.secondaryText)
                        }
                        Spacer()
                        Toggle("", isOn: $task.enabled).labelsHidden()
                    }
                }
                .buttonStyle(.plain)
            }
            .onDelete { tasks.wrappedValue.remove(atOffsets: $0) }
            Button {
                let preset = kind == .on ? PowerTask(hour: 8, minute: 0) : PowerTask(hour: 23, minute: 0)
                editing = Editing(kind: kind, task: preset, isNew: true)
            } label: {
                Label("添加自动\(kind.rawValue)", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("自动\(kind.rawValue)")
        }
    }

    private func apply(_ task: PowerTask, kind: Kind, isNew: Bool) {
        func upsert(_ list: inout [PowerTask]) {
            if !isNew, let i = list.firstIndex(where: { $0.id == task.id }) { list[i] = task } else { list.append(task) }
        }
        switch kind {
        case .on: upsert(&schedule.powerOn)
        case .off: upsert(&schedule.powerOff)
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            let s = try await client.powerSchedule()
            original = s
            schedule = s
        } catch {
            loadError = "无法读取开关机计划：\(error.userMessage)（需要管理员账号）"
        }
    }

    private func save() async {
        guard let client = session.client else { return }
        saving = true
        do {
            try await client.savePowerSchedule(schedule)
            original = schedule
            saved = true
        } catch {
            alert = error.userMessage
        }
        saving = false
    }
}

private struct PowerTaskEditor: View {
    let kind: PowerScheduleView.Kind
    let isNew: Bool
    let onDone: (PowerTask) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var task: PowerTask
    @State private var time: Date

    init(kind: PowerScheduleView.Kind, task: PowerTask, isNew: Bool, onDone: @escaping (PowerTask) -> Void) {
        self.kind = kind
        self.isNew = isNew
        self.onDone = onDone
        _task = State(initialValue: task)
        _time = State(initialValue: Calendar.current.date(from: DateComponents(hour: task.hour, minute: task.minute)) ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("时间", selection: $time, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                }
                Section {
                    HStack(spacing: 6) {
                        ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { day in
                            let on = task.weekdays.contains(day)
                            Button {
                                if on { task.weekdays.remove(day) } else { task.weekdays.insert(day) }
                            } label: {
                                Text(String(PowerTask.weekdayNames[day].suffix(1)))
                                    .font(.subheadline.weight(.semibold))
                                    .frame(width: 36, height: 36)
                                    .foregroundStyle(on ? .white : .primary)
                                    .background(on ? Theme.accent : Theme.subtle, in: Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    HStack {
                        Button("每天") { task.weekdays = Set(0...6) }
                        Spacer()
                        Button("工作日") { task.weekdays = Set(1...5) }
                        Spacer()
                        Button("周末") { task.weekdays = [0, 6] }
                    }
                    .buttonStyle(.borderless)
                    .font(.subheadline)
                } header: {
                    Text("重复")
                } footer: {
                    Text(PowerTask.describe(task.weekdays))
                }
                Section {
                    Toggle("启用", isOn: $task.enabled)
                }
            }
            .navigationTitle(isNew ? "添加自动\(kind.rawValue)" : "编辑自动\(kind.rawValue)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
                        task.hour = c.hour ?? 0
                        task.minute = c.minute ?? 0
                        onDone(task)
                        dismiss()
                    }
                    .disabled(task.weekdays.isEmpty)
                }
            }
        }
        .presentationDetents([.large])
    }
}
