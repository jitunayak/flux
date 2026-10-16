#if os(macOS)
import Foundation

/// The parts of the `fluxd` state that the computer window shows. It decodes
/// leniently from the `state` result or a `state` event, so a field that an
/// older or newer `fluxd` omits or adds does not stop the window.
public struct DaemonState: Sendable, Equatable {
    public struct SelfInfo: Sendable, Equatable {
        public var id = ""
        public var name = ""
        public var type = ""
        public var tcpPort = 0
        public var version = ""
        public var pendingVersion = ""
    }

    public struct Battery: Sendable, Equatable {
        public var charge = 0
        public var charging = false
    }

    public struct Notification: Sendable, Equatable, Identifiable {
        public var id = ""
        public var app = ""
        public var title = ""
        public var text = ""

        public init(id: String = "", app: String = "", title: String = "", text: String = "") {
            self.id = id
            self.app = app
            self.title = title
            self.text = text
        }
    }

    /// 1 SMS conversation of a phone.
    public struct Conversation: Sendable, Equatable, Identifiable {
        public var thread = 0
        public var name = ""
        public var address = ""
        public var last = ""
        public var time = 0
        public var unread = false
        public var outgoing = false

        public var id: Int { thread }
    }

    /// 1 file in the transfer outbox or inbox.
    public struct Transfer: Sendable, Equatable, Identifiable {
        public var id = ""
        public var name = ""
        public var deviceName = ""
        public var size = 0
        public var done = 0
        public var dir = ""
        public var state = ""

        public var progress: Double { size > 0 ? Double(done) / Double(size) : (state == "done" ? 1 : 0) }
    }

    public struct Device: Sendable, Equatable, Identifiable {
        public var id = ""
        public var name = ""
        public var type = ""
        public var ip = ""
        public var paired = false
        public var online = false
        public var pairState = ""
        public var pairKey = ""
        public var app = ""
        public var appVersion = ""
        public var battery: Battery?
        public var addresses: [String] = []
        public var notifications: [Notification] = []
        public var conversations: [Conversation] = []
        public var plugins: [String] = []
        public var fingerprint = ""

        /// True while the device asks to pair with this computer.
        public var wantsToPair: Bool { pairState == "incoming" || pairState == "confirm" }

        /// True while the device offers the SMS plugin.
        public var hasSms: Bool { plugins.contains("sms") }
    }

    public var selfInfo = SelfInfo()
    public var devices: [Device] = []
    public var transfers: [Transfer] = []
    public var downloadDir = ""

    public init() {}

    /// Decodes a `state` result or event data.
    public static func decode(_ value: JSONValue) -> DaemonState {
        var out = DaemonState()
        if let s = value["self"] {
            out.selfInfo = SelfInfo(
                id: s["id"]?.string ?? "",
                name: s["name"]?.string ?? "",
                type: s["type"]?.string ?? "",
                tcpPort: s["tcpPort"]?.int ?? 0,
                version: s["version"]?.string ?? "",
                pendingVersion: s["pendingVersion"]?.string ?? ""
            )
        }
        out.devices = (value["devices"]?.array ?? []).compactMap { d in
            guard let id = d["id"]?.string else { return nil }
            var dev = Device()
            dev.id = id
            dev.name = d["name"]?.string ?? id
            dev.type = d["type"]?.string ?? ""
            dev.ip = d["ip"]?.string ?? ""
            dev.paired = d["paired"]?.bool ?? false
            dev.online = d["online"]?.bool ?? false
            dev.pairState = d["pairState"]?.string ?? ""
            dev.pairKey = d["pairKey"]?.string ?? ""
            dev.app = d["app"]?.string ?? ""
            dev.appVersion = d["appVersion"]?.string ?? ""
            dev.addresses = d["addresses"]?.strings ?? []
            dev.plugins = d["plugins"]?.strings ?? []
            dev.fingerprint = d["fingerprint"]?.string ?? ""
            if let b = d["battery"] {
                dev.battery = Battery(charge: b["charge"]?.int ?? 0, charging: b["charging"]?.bool ?? false)
            }
            dev.notifications = (d["notifications"]?.array ?? []).map { n in
                Notification(
                    id: n["id"]?.string ?? "",
                    app: n["app"]?.string ?? "",
                    title: n["title"]?.string ?? "",
                    text: n["text"]?.string ?? ""
                )
            }
            dev.conversations = (d["conversations"]?.array ?? []).map { c in
                Conversation(
                    thread: c["thread"]?.int ?? 0,
                    name: c["name"]?.string ?? "",
                    address: c["address"]?.string ?? "",
                    last: c["last"]?.string ?? "",
                    time: c["time"]?.int ?? 0,
                    unread: c["unread"]?.bool ?? false,
                    outgoing: c["outgoing"]?.bool ?? false
                )
            }
            return dev
        }
        out.transfers = (value["transfers"]?.array ?? []).compactMap { t in
            guard let id = t["id"]?.string else { return nil }
            return Transfer(
                id: id,
                name: t["name"]?.string ?? "",
                deviceName: t["deviceName"]?.string ?? "",
                size: t["size"]?.int ?? 0,
                done: t["done"]?.int ?? 0,
                dir: t["dir"]?.string ?? "",
                state: t["state"]?.string ?? ""
            )
        }
        out.downloadDir = value["settings"]?["downloadDir"]?.string ?? ""
        return out
    }

    /// The device with the ID.
    public func device(_ id: String) -> Device? { devices.first { $0.id == id } }
}
#endif
