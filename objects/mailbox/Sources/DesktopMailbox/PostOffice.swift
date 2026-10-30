import AppKit

/// A handpicked letter from Resources/letters.json.
struct Letter: Codable, Equatable {
    var id: String
    var from: String
    var kind: MailKind
    /// Optional line under the greeting, like a movie or book title.
    var title: String?
    var body: String
    var signoff: String?
    /// Where the words come from, printed small at the foot of the letter (for letters from history).
    var source: String?
    /// Delivered on the first launch, before any random deliveries.
    var welcome: Bool?
}

/// A letter that has arrived.
struct Delivery: Codable, Equatable {
    var id: String
    var deliveredAt: Date
    var read: Bool
}

/// How often letters come. Chosen from the right-click menu.
enum DeliveryPace: String, CaseIterable {
    case often, sometimes, rarely, paused

    var title: String {
        switch self {
        case .often: return "About Once a Day"
        case .sometimes: return "A Few Times a Week"
        case .rarely: return "About Once a Week"
        case .paused: return "Pause Deliveries"
        }
    }

    /// Hours from now, before the daytime rule is applied.
    var hours: ClosedRange<Double>? {
        switch self {
        case .often: return 6...30
        case .sometimes: return 30...72
        case .rarely: return 120...216
        case .paused: return nil
        }
    }

    static var current: DeliveryPace {
        get { DeliveryPace(rawValue: UserDefaults.standard.string(forKey: "deliveryPace") ?? "") ?? .often }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "deliveryPace") }
    }
}

/// Delivers letters at random times, all offline. Keeps one one-shot alarm for the next delivery
/// and nothing else: no polling, no network.
final class PostOffice {
    private(set) var letters: [Letter] = []
    private(set) var inbox: [Delivery] = []
    private var delivered: Set<String> = []
    private(set) var nextDelivery: Date?
    private var alarm: Timer?

    /// Called on the main queue when a letter arrives.
    var onDelivery: ((Letter) -> Void)?

    private let fm = FileManager.default
    private var stateURL: URL { FileStore.folder.appendingPathComponent(".mailbox-post.json") }
    static let repliesFolder = FileStore.folder.appendingPathComponent(".replies", isDirectory: true)

    /// For trying it out: MAILBOX_DELIVERY_SECONDS=20 delivers a letter every 20 seconds.
    private let testInterval: TimeInterval? = ProcessInfo.processInfo.environment["MAILBOX_DELIVERY_SECONDS"]
        .flatMap(TimeInterval.init).map { max(3, $0) }

    init() {
        letters = PostOffice.loadLetters()
        load()
        // Forget letters that were removed from letters.json.
        let ids = Set(letters.map(\.id))
        inbox.removeAll { !ids.contains($0.id) }
    }

    func letter(_ id: String) -> Letter? { letters.first { $0.id == id } }
    var unreadCount: Int { inbox.filter { !$0.read }.count }
    var hasLettersLeft: Bool { letters.contains { !delivered.contains($0.id) } }

    /// Delivers the welcome letter on the very first launch, catches up on anything due while the
    /// app was closed, and sets the alarm for the next one.
    func start() {
        if delivered.isEmpty, let welcome = letters.first(where: { $0.welcome == true }) ?? letters.first {
            deliver(welcome, announce: false)
        }
        if DeliveryPace.current != .paused, let due = nextDelivery, due <= Date() {
            deliverRandom(announce: false)
        }
        if nextDelivery == nil || nextDelivery! <= Date() { scheduleNext() }
        arm()

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.alarm?.invalidate()
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.alarmFired()
        }
    }

    func markRead(_ id: String) {
        guard let i = inbox.firstIndex(where: { $0.id == id }), !inbox[i].read else { return }
        inbox[i].read = true
        save()
    }

    /// Changes how often letters come and picks a new time for the next one.
    func setPace(_ pace: DeliveryPace) {
        DeliveryPace.current = pace
        scheduleNext()
        arm()
    }

    var readCount: Int { inbox.filter(\.read).count }

    /// Removes every letter that has been read.
    func throwAwayRead() {
        inbox.removeAll { $0.read }
        save()
    }

    /// Removes a letter from the mailbox. It will not be delivered again.
    func throwAway(_ id: String) {
        inbox.removeAll { $0.id == id }
        save()
    }

    // MARK: Replies (saved on this Mac only)

    func replyURL(for id: String) -> URL { PostOffice.repliesFolder.appendingPathComponent("\(id).txt") }

    func reply(for id: String) -> String? { try? String(contentsOf: replyURL(for: id), encoding: .utf8) }

    func saveReply(_ text: String, for id: String) {
        try? fm.createDirectory(at: PostOffice.repliesFolder, withIntermediateDirectories: true)
        try? text.write(to: replyURL(for: id), atomically: true, encoding: .utf8)
    }

    // MARK: Deliveries

    /// Delivers a letter right now. Once every letter has come, older ones come round again.
    func deliverNow() {
        if hasLettersLeft { deliverRandom(announce: true); return }
        let waiting = Set(inbox.filter { !$0.read }.map(\.id))
        guard let pick = letters.filter({ !waiting.contains($0.id) && $0.welcome != true }).randomElement() else { return }
        inbox.removeAll { $0.id == pick.id }
        deliver(pick, announce: true)
    }

    private func deliverRandom(announce: Bool) {
        let left = letters.filter { !delivered.contains($0.id) }
        // Prefer a different kind from the last letter, so it stays a surprise.
        let lastKind = inbox.last.flatMap { letter($0.id)?.kind }
        let fresh = left.filter { $0.kind != lastKind }
        guard let pick = (fresh.isEmpty ? left : fresh).randomElement() else { return }
        deliver(pick, announce: announce)
    }

    private func deliver(_ letter: Letter, announce: Bool) {
        delivered.insert(letter.id)
        inbox.append(Delivery(id: letter.id, deliveredAt: Date(), read: false))
        save()
        if announce { onDelivery?(letter) }
    }

    /// Somewhere between 6 and 30 hours from now, during the day (9:00 to 21:00).
    private func scheduleNext() {
        guard hasLettersLeft, let hours = DeliveryPace.current.hours else { nextDelivery = nil; save(); return }
        if let testInterval {
            nextDelivery = Date().addingTimeInterval(testInterval)
            save()
            return
        }
        var date = Date().addingTimeInterval(TimeInterval.random(in: hours.lowerBound * 3600...hours.upperBound * 3600))
        let cal = Calendar.current
        let hour = cal.component(.hour, from: date)
        if hour < 9 || hour >= 21 {
            var day = cal.startOfDay(for: date)
            if hour >= 21 { day = cal.date(byAdding: .day, value: 1, to: day)! }
            date = day.addingTimeInterval(TimeInterval.random(in: 9 * 3600...20.5 * 3600))
        }
        nextDelivery = date
        save()
    }

    private func arm() {
        alarm?.invalidate()
        guard let due = nextDelivery else { return }
        let timer = Timer(fire: max(due, Date().addingTimeInterval(1)), interval: 0, repeats: false) { [weak self] _ in
            self?.alarmFired()
        }
        timer.tolerance = testInterval == nil ? 60 : 0.5
        RunLoop.main.add(timer, forMode: .common)
        alarm = timer
    }

    private func alarmFired() {
        if let due = nextDelivery, due <= Date() {
            deliverRandom(announce: true)
            scheduleNext()
        }
        arm()
    }

    /// A friendly line for the menu.
    var nextDeliveryText: String {
        if DeliveryPace.current == .paused { return "Deliveries are paused" }
        guard hasLettersLeft, let due = nextDelivery else { return "All letters delivered" }
        let cal = Calendar.current
        if testInterval != nil { return "Next letter in a few seconds" }
        if cal.isDateInToday(due) { return due.timeIntervalSinceNow < 3 * 3600 ? "The mail carrier is close by" : "More mail later today" }
        if cal.isDateInTomorrow(due) { return "More mail tomorrow" }
        if due.timeIntervalSinceNow > 4 * 86400 { return "More mail next week" }
        return "More mail soon"
    }

    // MARK: Storage

    private struct State: Codable {
        var delivered: [String]
        var inbox: [Delivery]
        var nextDelivery: Date?
    }

    private func load() {
        guard let data = try? Data(contentsOf: stateURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(State.self, from: data) else { return }
        delivered = Set(state.delivered)
        inbox = state.inbox
        nextDelivery = state.nextDelivery
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let state = State(delivered: delivered.sorted(), inbox: inbox, nextDelivery: nextDelivery)
        guard let data = try? encoder.encode(state) else { return }
        try? fm.createDirectory(at: FileStore.folder, withIntermediateDirectories: true)
        try? data.write(to: stateURL, options: .atomic)
    }

    /// Reads letters.json plus every .json file in the Letters folder (one file per collection).
    /// In the app they sit in Resources; with `swift run` they are read from the source folder.
    private static func loadLetters() -> [Letter] {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Resources").standardizedFileURL
        let base = Bundle.main.url(forResource: "letters", withExtension: "json")?.deletingLastPathComponent() ?? source
        var files = [base.appendingPathComponent("letters.json")]
        let folder = base.appendingPathComponent("Letters")
        let extra = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        files += extra.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        var letters: [Letter] = []
        var seen = Set<String>()
        for url in files {
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                for letter in try JSONDecoder().decode([Letter].self, from: data) where seen.insert(letter.id).inserted {
                    letters.append(letter)
                }
            } catch {
                NSLog("\(url.lastPathComponent) could not be read: \(error)")
            }
        }
        return letters
    }
}
