import FluxKit
import Observation
import SwiftUI

/// The state of the local `fluxd`, for the This Mac destination. It reads the
/// daemon over its Unix socket and sends the commands of the device rows.
@MainActor
@Observable
final class DaemonModel {
    private(set) var state = DaemonState()
    private(set) var connected = false
    private(set) var lastError: String?

    @ObservationIgnored private let client = DaemonClient()

    init() {
        client.onOpen = { [weak self] in
            Task { @MainActor in
                self?.connected = true
                self?.refresh()
            }
        }
        client.onClose = { [weak self] in
            Task { @MainActor in self?.connected = false }
        }
        client.onEvent = { [weak self] event, data in
            guard event == "state" else { return }
            let next = DaemonState.decode(data)
            Task { @MainActor in self?.state = next }
        }
        client.start()
    }

    func refresh() {
        client.call("state") { [weak self] result in
            switch result {
            case .success(let value):
                let next = DaemonState.decode(value)
                Task { @MainActor in self?.state = next }
            case .failure(let error):
                Task { @MainActor in self?.lastError = error.localizedDescription }
            }
        }
    }

    // MARK: Commands

    func ring(_ dev: DaemonState.Device) {
        command("ring", ["device": .string(dev.id)])
    }

    func sendClipboard(_ dev: DaemonState.Device, text: String) {
        guard !text.isEmpty else { return }
        command("clipboard.send", ["device": .string(dev.id), "text": .string(text)])
    }

    func sendURL(_ dev: DaemonState.Device, url: String) {
        guard !url.isEmpty else { return }
        command("share.url", ["device": .string(dev.id), "url": .string(url)])
    }

    func notify(_ dev: DaemonState.Device, title: String, body: String) {
        command("notify.send", ["device": .string(dev.id), "title": .string(title), "body": .string(body)])
    }

    func sendFiles(_ dev: DaemonState.Device, paths: [String]) {
        guard !paths.isEmpty else { return }
        command("share.files", ["device": .string(dev.id), "paths": .array(paths.map { .string($0) })])
    }

    func sendSms(_ dev: DaemonState.Device, to addresses: [String], body: String) {
        let to = addresses.filter { !$0.isEmpty }
        guard !body.isEmpty, !to.isEmpty else { return }
        command("sms.send", [
            "device": .string(dev.id),
            "addresses": .array(to.map { .string($0) }),
            "body": .string(body),
        ])
    }

    func refreshSms(_ dev: DaemonState.Device) {
        command("sms.refresh", ["device": .string(dev.id)])
    }

    func dismiss(_ dev: DaemonState.Device, notification: DaemonState.Notification) {
        command("notification.dismiss", ["device": .string(dev.id), "id": .string(notification.id)])
    }

    func accept(_ dev: DaemonState.Device) {
        command("pair.accept", ["device": .string(dev.id), "key": .string(dev.pairKey)])
    }

    func reject(_ dev: DaemonState.Device) {
        command("pair.reject", ["device": .string(dev.id), "key": .string(dev.pairKey)])
    }

    func unpair(_ dev: DaemonState.Device) {
        command("unpair", ["device": .string(dev.id)])
    }

    func clearError() { lastError = nil }

    private func command(_ method: String, _ params: [String: JSONValue]) {
        client.call(method, .object(params)) { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success:
                    self?.lastError = nil
                    self?.refresh()
                case .failure(let error):
                    self?.lastError = error.localizedDescription
                }
            }
        }
    }
}
