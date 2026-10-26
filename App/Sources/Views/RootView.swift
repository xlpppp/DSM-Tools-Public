import SwiftUI
import DSMKit

struct RootView: View {
    @Environment(DeviceStore.self) private var store
    @Environment(SessionManager.self) private var session
    @State private var addingDevice = false

    var body: some View {
        Group {
            if let device = store.selected {
                NavigationStack {
                    HomeView(device: device)
                }
            } else {
                welcome
            }
        }
        .task(id: store.selectedID) {
            guard let device = store.selected else { return }
            await session.connect(to: device, store: store)
        }
        .sheet(isPresented: $addingDevice) {
            DeviceEditorView(profile: nil)
        }
    }

    private var welcome: some View {
        VStack(spacing: 20) {
            Spacer()
            NASIllustration().scaleEffect(1.4)
            Text("管理你的群晖 NAS").font(.title2.bold())
            Text("添加一台设备开始使用，支持局域网和外网地址自动切换。")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                addingDevice = true
            } label: {
                Text("添加群晖").font(.headline).frame(maxWidth: .infinity).frame(height: 50)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }
}
