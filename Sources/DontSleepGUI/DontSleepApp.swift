import AppKit
import Foundation
import SwiftUI
import UserNotifications

@main
struct DontSleepApp: App {
    @NSApplicationDelegateAdaptor(NotificationDelegate.self) private var notificationDelegate
    @StateObject private var controller = SleepController()
    @StateObject private var dimController = DimController()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(controller)
                .environmentObject(dimController)
                .background(WindowFrameRestorer())
                .onAppear {
                    notificationDelegate.sleepController = controller
                    notificationDelegate.dimController = dimController
                    dimController.sleepController = controller
                }
        }

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(controller)
                .environmentObject(dimController)
        } label: {
            StatusBarIconView(controller: controller)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Сохраняет размер и положение окна между запусками приложения
/// (штатный механизм AppKit — NSWindow Frame Autosave).
private struct WindowFrameRestorer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        Task { @MainActor in
            view.attachToWindowForFrameAutosave()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.attachToWindowForFrameAutosave()
    }
}

private extension NSView {
    func attachToWindowForFrameAutosave() {
        guard let window, window.frameAutosaveName.isEmpty else { return }
        window.setFrameAutosaveName("MainWindow")
        window.setFrameUsingName("MainWindow")
    }
}

@MainActor
final class NotificationDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var sleepController: SleepController?
    weak var dimController: DimController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationWillTerminate(_ notification: Notification) {
        sleepController?.cancelForApplicationTermination()
        dimController?.shutDown()
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

    /// Быстрый запуск из меню статус-бара: задаёт длительность и стартует.
    func start(minutes: Int) {
        guard !isRunning else { return }
        minutesText = String(minutes)
        start()
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

// MARK: - Затемнение экрана по таймеру бездействия

/// Отдельная функция: если включена — после заданного времени бездействия
/// плавно снижает яркость экрана до минимума. Любая активность пользователя
/// (мышь, клавиатура, трекпад) возвращает яркость и перезапускает отсчёт.
@MainActor
final class DimController: ObservableObject {
    /// Максимальная непрозрачность затемняющего слоя (0.9 ≈ минимальная яркость).
    private static let maxDimAlpha: CGFloat = 0.9

    @Published private(set) var isEnabled = false
    @Published var minutesText = "5"
    @Published private(set) var remainingSeconds = 0
    @Published private(set) var isDimmed = false
    @Published private(set) var validationMessage = ""

    /// Затемнение работает только при активном режиме «Не давать Mac спать».
    weak var sleepController: SleepController?

    private var timer: Timer?
    private var deadline: Date?
    private var lastIdleSeconds: Double = 0
    private var overlayWindows: [NSWindow] = []

    var mainProtectionActive: Bool {
        sleepController?.isRunning ?? false
    }

    var intervalSeconds: Int {
        let trimmed = minutesText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let minutes = Int(trimmed), minutes > 0 else { return 0 }
        return minutes * 60
    }

    var remainingText: String {
        let hours = remainingSeconds / 3_600
        let minutes = (remainingSeconds % 3_600) / 60
        let seconds = remainingSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    var statusText: String {
        if isDimmed {
            return "Экран затемнён — двигайте мышью или нажмите клавишу, чтобы вернуть яркость."
        }
        if isEnabled && !mainProtectionActive {
            return "Отсчёт начнётся, когда будет включён режим «Не давать Mac спать»."
        }
        let minutes = intervalSeconds / 60
        return minutes > 0
            ? "Экран будет затемнён после \(minutes) мин бездействия. Любая активность перезапускает отсчёт."
            : "Введите положительное целое число минут."
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled else {
            stopCompletely()
            return
        }
        guard intervalSeconds > 0 else {
            validationMessage = "Введите положительное целое число минут."
            return
        }
        validationMessage = ""
        isEnabled = true
        if mainProtectionActive {
            startMonitoring()
        } else {
            stopMonitoring()
        }
    }

    /// Вызывается при изменении значения минут: перезапускает отсчёт без сброса защиты.
    func restartIfActive() {
        guard isEnabled, mainProtectionActive, !isDimmed, intervalSeconds > 0 else { return }
        deadline = Date().addingTimeInterval(TimeInterval(intervalSeconds))
    }

    func setMinutes(_ minutes: Int) {
        minutesText = String(minutes)
        restartIfActive()
    }

    func shutDown() {
        stopCompletely()
    }

    /// Полностью выключает функцию (сброс чекбокса).
    private func stopCompletely() {
        isEnabled = false
        stopMonitoring()
    }

    /// Останавливает отсчёт и снимает затемнение, не трогая состояние чекбокса.
    private func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        deadline = nil
        remainingSeconds = 0
        restoreBrightness()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        tick()
    }

    private func tick() {
        guard isEnabled, mainProtectionActive, deadline != nil else { return }

        let idle = Self.idleSeconds()
        // Небольшой допуск, чтобы не считать «потроганием» шум.
        let hadActivity = idle + 0.05 < lastIdleSeconds
        lastIdleSeconds = idle

        if hadActivity {
            if isDimmed { restoreBrightness() }
            self.deadline = Date().addingTimeInterval(TimeInterval(intervalSeconds))
        }

        guard let currentDeadline = self.deadline else { return }
        remainingSeconds = max(0, Int(ceil(currentDeadline.timeIntervalSinceNow)))
        if remainingSeconds == 0, !isDimmed {
            dimScreen()
        }
    }

    private func startMonitoring() {
        guard intervalSeconds > 0 else { return }
        lastIdleSeconds = Self.idleSeconds()
        deadline = Date().addingTimeInterval(TimeInterval(intervalSeconds))
        remainingSeconds = intervalSeconds
        startTimer()
    }

    private func dimScreen() {
        showOverlays()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 2.0
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for window in overlayWindows {
                window.animator().alphaValue = Self.maxDimAlpha
            }
        }
        isDimmed = true
    }

    private func restoreBrightness() {
        guard isDimmed else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.4
            for window in overlayWindows {
                window.animator().alphaValue = 0
            }
        }
        isDimmed = false
    }

    /// Полноэкранный чёрный слой поверх всех экранов (окно не перехватывает мышь).
    /// Яркость подсветки приватными API на современных macOS надёжно менять нельзя,
    /// поэтому «минимальная яркость» реализуется затемняющим слоем.
    private func showOverlays() {
        let screens = NSScreen.screens
        if overlayWindows.count != screens.count {
            overlayWindows = screens.map { screen in
                let window = NSWindow(
                    contentRect: screen.frame,
                    styleMask: .borderless,
                    backing: .buffered,
                    defer: false,
                    screen: screen)
                window.backgroundColor = .black
                window.isOpaque = false
                window.alphaValue = 0
                window.level = .screenSaver
                window.ignoresMouseEvents = true
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                return window
            }
        }
        for (window, screen) in zip(overlayWindows, screens) {
            window.setFrame(screen.frame, display: false)
            window.orderFrontRegardless()
        }
    }

    /// Секунды с последней активности пользователя (мышь, клавиатура, колесо и т.п.).
    private static func idleSeconds() -> Double {
        var result = Double.greatestFiniteMagnitude
        for eventType in watchedEventTypes {
            let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: eventType)
            result = min(result, seconds)
        }
        return result
    }

    private static let watchedEventTypes: [CGEventType] = [
        .mouseMoved,
        .leftMouseDown, .leftMouseDragged,
        .rightMouseDown, .rightMouseDragged,
        .otherMouseDown, .otherMouseDragged,
        .keyDown,
        .scrollWheel
    ]
}

// MARK: - Иконка и меню статус-бара

/// Иконка в меню-баре: спящая чашка, когда Mac может уснуть,
/// и дымящаяся — пока защита от сна активна.
struct StatusBarIconView: View {
    @ObservedObject var controller: SleepController

    var body: some View {
        if controller.isRunning {
                Image("StatusBarAwake", bundle: .main)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 18, height: 18)
            } else {
                Image("StatusBarIdle", bundle: .main)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: 18, height: 18)
            }
    }
}

/// Панель меню статус-бара (стиль .window).
struct MenuBarPanel: View {
    @EnvironmentObject private var controller: SleepController
    @EnvironmentObject private var dimController: DimController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            menuRow(icon: "macwindow", title: "Открыть приложение") {
                openWindow(id: "main")
            }

            Divider()
                .padding(.vertical, 4)

            if controller.isRunning {
                menuRow(icon: "stop.circle", title: "Остановить — осталось \(controller.remainingText)") {
                    controller.cancel()
                }
            } else {
                menuRow(icon: "cup.and.saucer.fill", title: "Не спать 15 минут") {
                    controller.start(minutes: 15)
                }
                menuRow(icon: "cup.and.saucer.fill", title: "Не спать 30 минут") {
                    controller.start(minutes: 30)
                }
                menuRow(icon: "cup.and.saucer.fill", title: "Не спать 60 минут") {
                    controller.start(minutes: 60)
                }
                menuRow(icon: "cup.and.saucer.fill", title: "Не спать 120 минут") {
                    controller.start(minutes: 120)
                }
            }

            Divider()
                .padding(.vertical, 4)

            Toggle("Не гасить экран", isOn: $controller.keepDisplayAwake)
                .toggleStyle(.checkbox)
                .disabled(controller.isRunning)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)

            Toggle(isOn: Binding(
                get: { dimController.isEnabled },
                set: { dimController.setEnabled($0) }
            )) {
                Text("Затемнять экран")
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)

            Divider()
                .padding(.vertical, 4)

            menuRow(icon: "power", title: "Выход") {
                NSApp.terminate(nil)
            }
        }
        .padding(10)
        .frame(width: 270)
    }

    private func menuRow(
        icon: String,
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

struct ContentView: View {
    @EnvironmentObject private var controller: SleepController
    @EnvironmentObject private var dimController: DimController

    @State private var dimSectionExpanded = false

    /// Версия приложения из Info.plist (fallback — текущая версия из репозитория).
    private static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.4.0"
    }

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

            // Раздвижная секция затемнения (по умолчанию свёрнута/скрыта)
            GroupBox {
                DisclosureGroup(isExpanded: $dimSectionExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: Binding(
                            get: { dimController.isEnabled },
                            set: { dimController.setEnabled($0) }
                        )) {
                            Text("Затемнять экран после бездействия")
                        }

                        HStack(spacing: 8) {
                            TextField("Например, 5", text: $dimController.minutesText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 132)
                                .disabled(dimController.isEnabled)
                                .onChange(of: dimController.minutesText) { _ in
                                    dimController.restartIfActive()
                                }
                            Text("минут бездействия")
                        }

                        HStack(spacing: 8) {
                            ForEach([1, 5, 15], id: \.self) { minutes in
                                Button("\(minutes) мин") {
                                    dimController.setMinutes(minutes)
                                }
                                .disabled(dimController.isEnabled)
                            }
                        }

                        if dimController.isEnabled && dimController.mainProtectionActive {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle()
                                    .fill(dimController.isDimmed ? Color.orange : Color.blue)
                                    .frame(width: 8, height: 8)
                                Text(dimController.isDimmed
                                    ? "Экран затемнён"
                                    : "До затемнения осталось")
                                    .foregroundStyle(.secondary)
                                if !dimController.isDimmed {
                                    Spacer()
                                    Text(dimController.remainingText)
                                        .font(.system(.body, design: .monospaced).weight(.medium))
                                }
                            }
                        }

                        Text(dimController.validationMessage.isEmpty
                            ? dimController.statusText
                            : dimController.validationMessage)
                            .font(.footnote)
                            .foregroundStyle(dimController.validationMessage.isEmpty ? Color.secondary : Color.red)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                } label: {
                    Label("Затемнение экрана по таймеру", systemImage: "sun.min")
                }
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

            Text("Версия \(Self.appVersion)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
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
