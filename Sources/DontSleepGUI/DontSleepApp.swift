import AppKit
import Foundation
import SwiftUI
import UserNotifications

@main
struct DontSleepApp: App {
    @NSApplicationDelegateAdaptor(NotificationDelegate.self) private var notificationDelegate
    @StateObject private var controller = SleepController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(controller)
                .onAppear {
                    notificationDelegate.sleepController = controller
                }
        }
    }
}

@MainActor
final class NotificationDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var sleepController: SleepController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationWillTerminate(_ notification: Notification) {
        sleepController?.cancelForApplicationTermination()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

@MainActor
final class SleepController: ObservableObject {
    enum State {
        case ready
        case running
        case finished
        case cancelled
        case error
    }

    @Published var minutesText = "60"
    @Published var keepDisplayAwake = true
    @Published private(set) var state: State = .ready
    @Published private(set) var remainingSeconds = 0
    @Published private(set) var startDate: Date?
    @Published private(set) var endDate: Date?
    @Published private(set) var errorMessage = ""
    @Published private(set) var notificationMessage = "Проверяю системные уведомления…"

    private var process: Process?
    private var timer: Timer?
    private var selectedMinutes = 0
    private var cancellationRequested = false

    init() {
        updateNotificationStatus(requestPermission: false)
    }

    var isRunning: Bool {
        state == .running
    }

    var statusTitle: String {
        switch state {
        case .ready:
            return "Готово к запуску"
        case .running:
            return "Mac не будет переходить в сон"
        case .finished:
            return "Период бодрствования завершён"
        case .cancelled:
            return "Период бодрствования отменён"
        case .error:
            return "Не удалось запустить защиту от сна"
        }
    }

    var statusDetail: String {
        switch state {
        case .ready:
            return "Укажите длительность и нажмите «Начать»."
        case .running:
            guard let startDate, let endDate else { return "Идёт обратный отсчёт." }
            let displayDetail = keepDisplayAwake
                ? " Экран останется включённым."
                : " Экран будет работать по обычным настройкам."
            return "Сейчас \(formatted(date: startDate)). Обычный режим электропитания вернётся \(formatted(date: endDate)).\(displayDetail)"
        case .finished:
            return "Время истекло — Mac снова может спать."
        case .cancelled:
            return "Отмена — Mac снова может спать."
        case .error:
            return "Защита от сна не была включена."
        }
    }

    var statusColor: Color {
        switch state {
        case .ready:
            return .secondary
        case .running:
            return .blue
        case .finished:
            return .green
        case .cancelled:
            return .orange
        case .error:
            return .red
        }
    }

    var remainingText: String {
        let hours = remainingSeconds / 3_600
        let minutes = (remainingSeconds % 3_600) / 60
        let seconds = remainingSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    var progress: Double {
        guard selectedMinutes > 0 else { return 0 }
        let totalSeconds = Double(selectedMinutes * 60)
        return min(1, max(0, 1 - (Double(remainingSeconds) / totalSeconds)))
    }

    func setMinutes(_ minutes: Int) {
        guard !isRunning else { return }
        minutesText = String(minutes)
    }

    func start() {
        guard !isRunning else { return }

        guard let minutes = validMinutes else {
            errorMessage = "Введите положительное целое число минут."
            state = .error
            return
        }

        selectedMinutes = minutes
        remainingSeconds = minutes * 60
        startDate = Date()
        endDate = startDate?.addingTimeInterval(TimeInterval(remainingSeconds))
        cancellationRequested = false
        errorMessage = ""

        let newProcess = Process()
        newProcess.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        let caffeinateFlags = keepDisplayAwake ? "-di" : "-i"
        newProcess.arguments = [caffeinateFlags, "-t", String(remainingSeconds)]
        newProcess.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.caffeinateDidFinish()
            }
        }

        do {
            try newProcess.run()
        } catch {
            startDate = nil
            endDate = nil
            selectedMinutes = 0
            remainingSeconds = 0
            state = .error
            errorMessage = "Не удалось запустить системную команду caffeinate: \(error.localizedDescription)"
            return
        }

        process = newProcess
        state = .running
        updateNotificationStatus(requestPermission: true)
        startTimer()
    }

    func cancel() {
        guard isRunning else { return }

        cancellationRequested = true
        timer?.invalidate()
        timer = nil
        process?.terminate()
        process = nil
        remainingSeconds = 0
        state = .cancelled
    }

    func dismissError() {
        errorMessage = ""
        if state == .error {
            state = .ready
        }
    }

    private var validMinutes: Int? {
        let trimmed = minutesText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let minutes = Int(trimmed), minutes > 0 else { return nil }
        return minutes
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateCountdown()
            }
        }
        updateCountdown()
    }

    private func updateCountdown() {
        guard isRunning, let endDate else { return }
        remainingSeconds = max(0, Int(ceil(endDate.timeIntervalSinceNow)))
    }

    private func caffeinateDidFinish() {
        guard isRunning, !cancellationRequested else { return }

        timer?.invalidate()
        timer = nil
        process = nil
        remainingSeconds = 0
        state = .finished
        sendCompletionNotification()
    }

    func cancelForApplicationTermination() {
        guard process?.isRunning == true else { return }
        cancellationRequested = true
        process?.terminate()
    }

    private func updateNotificationStatus(requestPermission: Bool) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            switch settings.authorizationStatus {
            case .authorized:
                Task { @MainActor in
                    self?.notificationMessage = "Системные уведомления включены."
                }
            case .notDetermined where requestPermission:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    Task { @MainActor in
                        self?.notificationMessage = granted
                            ? "Системные уведомления включены."
                            : "Уведомления выключены в настройках macOS."
                    }
                }
            case .notDetermined:
                Task { @MainActor in
                    self?.notificationMessage = "Разрешение на уведомления будет запрошено при запуске."
                }
            default:
                Task { @MainActor in
                    self?.notificationMessage = "Уведомления выключены в настройках macOS."
                }
            }
        }
    }

    private func sendCompletionNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Активность завершена"
        content.subtitle = "Система вернулась к обычному плану"
        let completionTime = endDate.map { formatted(date: $0) } ?? "сейчас"
        content.body = "Период бодрствования: \(selectedMinutes) мин. Окончание: \(completionTime)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in
                self?.notificationMessage = "Не удалось показать системное уведомление."
            }
        }
    }

    private func formatted(date: Date) -> String {
        Self.russianDateFormatter.string(from: date)
    }

    private static let russianDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = .current
        formatter.dateFormat = "EEEE, dd MMMM yyyy 'г.' HH:mm:ss (zzz)"
        return formatter
    }()
}

struct ContentView: View {
    @EnvironmentObject private var controller: SleepController

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.blue)
                    if controller.isRunning {
                        Image(systemName: "nosign")
                            .font(.system(size: 38))
                            .foregroundStyle(.red)
                    }
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Не давать Mac спать")
                        .font(.title2.weight(.semibold))
                    Text("Временная защита от сна и сна дисплея")
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Сколько минут не давать Mac спать?")
                        .font(.headline)

                    HStack(spacing: 8) {
                        TextField("Например, 60", text: $controller.minutesText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 132)
                            .disabled(controller.isRunning)
                            .onSubmit { controller.start() }
                        Text("минут")
                    }

                    HStack(spacing: 8) {
                        ForEach([15, 30, 60, 120], id: \.self) { minutes in
                            Button("\(minutes) мин") {
                                controller.setMinutes(minutes)
                            }
                            .disabled(controller.isRunning)
                        }
                    }

                    Toggle("Оставить экран включённым", isOn: $controller.keepDisplayAwake)
                        .disabled(controller.isRunning)

                    Text(controller.keepDisplayAwake
                        ? "Блокирует сон Mac и выключение дисплея."
                        : "Блокирует только сон Mac; экран может выключаться как обычно.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox("Статус") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(controller.statusColor)
                            .frame(width: 9, height: 9)
                        Text(controller.statusTitle)
                            .font(.headline)
                    }

                    Text(controller.statusDetail)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.secondary)

                    if controller.isRunning {
                        ProgressView(value: controller.progress)
                        HStack {
                            Text("Осталось")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(controller.remainingText)
                                .font(.system(.title3, design: .monospaced).weight(.medium))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            HStack {
                Button(controller.isRunning ? "Защита включена" : "Начать") {
                    controller.start()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(controller.isRunning)

                if controller.isRunning {
                    Button("Отменить") {
                        controller.cancel()
                    }
                    .keyboardShortcut(.cancelAction)
                }

                Spacer()
            }

            Divider()

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "bell.badge")
                    .foregroundStyle(.secondary)
                Text(controller.notificationMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text("⌘Q сразу прекращает защиту от сна.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 530)
        .alert("Не удалось запустить", isPresented: Binding(
            get: { !controller.errorMessage.isEmpty },
            set: { if !$0 { controller.dismissError() } }
        )) {
            Button("OK", role: .cancel) {
                controller.dismissError()
            }
        } message: {
            Text(controller.errorMessage)
        }
    }
}
