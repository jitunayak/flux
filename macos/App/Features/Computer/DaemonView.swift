import AppKit
import FluxKit
import SwiftUI

/// The This Mac destination: the devices that the local `fluxd` knows,
/// including the phone. The daemon is the computer; this window is its
/// front end on the Mac.
struct DaemonView: View {
    @State private var daemon = DaemonModel()
    @Environment(\.tn) private var tn
    @State private var clipboard = ""
    @State private var notifyTitle = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !daemon.connected {
                    offlineNotice
                }
                if let error = daemon.lastError {
                    errorBar(error)
                }
                deviceList
                transfersSection
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(tn.bg)
        .navigationTitle("This Mac")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    daemon.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: daemon.state.selfInfo.type == "laptop" ? "laptopcomputer" : "desktopcomputer")
                .font(.title2)
                .foregroundStyle(tn.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(daemon.state.selfInfo.name.isEmpty ? "Flux daemon" : daemon.state.selfInfo.name)
                    .font(.headline)
                    .foregroundStyle(tn.text)
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(tn.sub)
            }
            Spacer()
            Circle()
                .fill(daemon.connected ? .green : .secondary)
                .frame(width: 9, height: 9)
        }
    }

    private var statusLine: String {
        var parts: [String] = []
        if !daemon.state.selfInfo.version.isEmpty { parts.append("fluxd \(daemon.state.selfInfo.version)") }
        parts.append(daemon.connected ? "daemon reachable" : "daemon not reachable")
        return parts.joined(separator: " · ")
    }

    private var offlineNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("fluxd is not running", systemImage: "bolt.horizontal.circle")
                .font(.body.weight(.medium))
            Text("Start the daemon on this Mac with `fluxd`, or `flux on`. This window reads it over \(DaemonClient.defaultSocketPath()).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tn.line, in: RoundedRectangle(cornerRadius: 10))
    }

    private func errorBar(_ text: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
            Text(text).font(.caption)
            Spacer()
            Button("Dismiss") { daemon.clearError() }
                .buttonStyle(.link)
                .font(.caption)
        }
        .foregroundStyle(.orange)
        .padding(10)
        .background(tn.line, in: RoundedRectangle(cornerRadius: 10))
    }

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Devices")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tn.sub)
            if daemon.state.devices.isEmpty {
                Text(daemon.connected ? "No devices. Pair a phone on the computer." : "Waiting for the daemon…")
                    .font(.caption)
                    .foregroundStyle(tn.sub)
            } else {
                ForEach(daemon.state.devices) { dev in
                    DeviceCard(daemon: daemon, device: dev, clipboard: $clipboard)
                }
            }
        }
    }

    private var transfersSection: some View {
        Group {
            if !daemon.state.transfers.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Transfers")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tn.sub)
                    ForEach(daemon.state.transfers) { transfer in
                        DaemonTransferRow(transfer: transfer)
                    }
                    if !daemon.state.downloadDir.isEmpty {
                        Text("Received files go to \(daemon.state.downloadDir).")
                            .font(.caption2)
                            .foregroundStyle(tn.sub)
                    }
                }
            }
        }
    }
}

/// 1 transfer of the daemon outbox or inbox.
private struct DaemonTransferRow: View {
    let transfer: DaemonState.Transfer
    @Environment(\.tn) private var tn

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: transfer.dir == "in" ? "arrow.down.circle" : "arrow.up.circle")
                    .foregroundStyle(tn.accent)
                Text(transfer.name).font(.caption).foregroundStyle(tn.text).lineLimit(1)
                Spacer()
                Text(transfer.deviceName).font(.caption2).foregroundStyle(tn.sub)
                Text(stateText).font(.caption2).foregroundStyle(tn.sub)
            }
            ProgressView(value: transfer.progress)
                .progressViewStyle(.linear)
                .tint(tn.accent)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tn.line, in: RoundedRectangle(cornerRadius: 10))
    }

    private var stateText: String {
        transfer.state == "done" ? "done" : "\(transfer.done)/\(transfer.size)"
    }
}

/// 1 device of the daemon, with its state and the quick actions.
private struct DeviceCard: View {
    let daemon: DaemonModel
    let device: DaemonState.Device
    @Binding var clipboard: String
    @Environment(\.tn) private var tn
    @State private var composing = false
    @State private var composeTo = ""
    @State private var composeBody = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(tn.accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.body.weight(.medium)).foregroundStyle(tn.text)
                    Text(subtitle).font(.caption).foregroundStyle(tn.sub)
                }
                Spacer()
                if let battery = device.battery {
                    Label("\(battery.charge)%", systemImage: battery.charging ? "battery.100.bolt" : "battery.100")
                        .font(.caption)
                        .foregroundStyle(tn.sub)
                }
                actions
            }

            if device.wantsToPair {
                pairRow
            }
            if device.hasSms && !device.conversations.isEmpty {
                conversations
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tn.line, in: RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: $composing) { composeSheet }
    }

    private var symbol: String {
        switch device.type {
        case "laptop": return "laptopcomputer"
        case "desktop": return "desktopcomputer"
        case "tablet": return "ipad"
        case "tv": return "tv"
        default: return "iphone"
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        parts.append(status)
        if !device.app.isEmpty { parts.append("\(device.app) \(device.appVersion)") }
        if !device.ip.isEmpty { parts.append(device.ip) }
        if !device.notifications.isEmpty { parts.append("\(device.notifications.count) notifications") }
        return parts.joined(separator: " · ")
    }

    private var status: String {
        if device.wantsToPair { return "Wants to pair" }
        if device.paired { return device.online ? "Connected" : "Offline" }
        return device.online ? "Not paired" : "Offline"
    }

    private var actions: some View {
        Menu {
            Button("Ring") { daemon.ring(device) }
                .disabled(!device.online)
            Button("Send clipboard") { daemon.sendClipboard(device, text: clipboard) }
                .disabled(!device.paired || !device.online || clipboard.isEmpty)
            Button("Notify…") {
                daemon.notify(device, title: clipboard.isEmpty ? "Flux" : clipboard, body: "")
            }
            .disabled(!device.paired || !device.online)
            Divider()
            Button("Send file…") { pickFiles() }
                .disabled(!device.paired || !device.online)
            if device.hasSms {
                Button("New message…") { composeTo = ""; composing = true }
                    .disabled(!device.paired || !device.online)
                Button("Refresh messages") { daemon.refreshSms(device) }
                    .disabled(!device.paired || !device.online)
            }
            Divider()
            if device.paired {
                Button("Unpair", role: .destructive) { daemon.unpair(device) }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var conversations: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Messages").font(.caption.weight(.semibold)).foregroundStyle(tn.sub)
                Spacer()
                Button("Refresh") { daemon.refreshSms(device) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            ForEach(device.conversations.prefix(4)) { c in
                HStack(spacing: 8) {
                    Circle()
                        .fill(c.unread ? tn.accent : Color.clear)
                        .frame(width: 6, height: 6)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.name.isEmpty ? c.address : c.name)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(tn.text)
                        Text(c.last)
                            .font(.caption2)
                            .foregroundStyle(tn.sub)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        composeTo = c.address
                        composing = true
                    } label: {
                        Image(systemName: "arrowshape.turn.up.left")
                    }
                    .buttonStyle(.link)
                    .disabled(!device.paired || !device.online)
                }
            }
        }
        .padding(.top, 2)
    }

    private var composeSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New message to \(device.name)").font(.headline)
            TextField("Number or contact", text: $composeTo)
                .textFieldStyle(.roundedBorder)
            TextField("Message", text: $composeBody, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
            HStack {
                Spacer()
                Button("Cancel") { composing = false }
                Button("Send") {
                    daemon.sendSms(device, to: [composeTo], body: composeBody)
                    composeBody = ""
                    composing = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(composeTo.isEmpty || composeBody.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Send"
        panel.message = "Send to \(device.name)"
        if panel.runModal() == .OK {
            daemon.sendFiles(device, paths: panel.urls.map(\.path))
        }
    }

    private var pairRow: some View {
        HStack(spacing: 8) {
            Text("Key \(formattedKey)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(tn.text)
            Spacer()
            Button("Reject", role: .destructive) { daemon.reject(device) }
            Button("Accept") { daemon.accept(device) }
                .buttonStyle(.borderedProminent)
        }
    }

    private var formattedKey: String {
        let k = device.pairKey
        guard k.count == 16 else { return k }
        let groups = stride(from: 0, to: 16, by: 4).map { i -> String in
            let start = k.index(k.startIndex, offsetBy: i)
            let end = k.index(start, offsetBy: 4)
            return String(k[start..<end])
        }
        return groups.joined(separator: " ")
    }
}
