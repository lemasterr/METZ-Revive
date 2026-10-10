import Foundation
import ScreenCaptureKit

enum CaptureStage { case access, virtualDisplay, content, encoder, capture }

enum VirtualDisplayFailure: Error {
    case creation(Int), registration, mode, mirror, mirrorOperation(String, Int)

    var explanation: String {
        let reason: String
        switch self {
        case .creation(let code):
            // Stable codes from METZDisplayFailure in VirtualDisplay.h.
            switch code {
            case 1: reason = "В этой macOS недоступен API виртуального экрана."
            case 2, 3, 5: reason = "Интерфейс виртуального экрана изменился в этой macOS (код \(code))."
            case 4: reason = "macOS отклонила дескриптор виртуального экрана."
            case 6: reason = "macOS не смогла создать режим выбранное разрешение / 30."
            case 7: reason = "macOS отклонила режим выбранное разрешение / 30."
            case 8: reason = "macOS не выдала идентификатор виртуального экрана."
            default: reason = "API виртуального экрана завершился ошибкой (код \(code))."
            }
        case .registration: reason = "Виртуальный экран создан, но не активировался за 5 секунд."
        case .mode: reason = "Виртуальный экран не перешёл в режим выбранное разрешение."
        case .mirror: reason = "Второй экран остался в режиме зеркалирования. Отдельный рабочий стол не активирован."
        case .mirrorOperation(let operation, let code): reason = "Не выполнено \(operation) второго экрана (CoreGraphics \(code))."
        }
        return reason + " Подключение остановлено; созданный приложением экран освобождён."
    }
}

enum CaptureAccess {
    static func explanation(_ error: Error, stage: CaptureStage, application: String) -> String {
        if error is CancellationError { return "Подключение отменено" }
        if let failure = error as? VirtualDisplayFailure { return failure.explanation }
        let failure = error as NSError
        if failure.domain == SCStreamErrorDomain && failure.code == SCStreamError.Code.userDeclined.rawValue {
            return "macOS не разрешает запись экрана для \(application). Включите именно \(application) в настройках «Запись экрана и системного аудио», затем полностью закройте и откройте приложение. Разрешение другого приложения не подходит."
        }
        if failure.domain == SCStreamErrorDomain && failure.code == SCStreamError.Code.missingEntitlements.rawValue {
            return "macOS отклонила права сборки на захват. Требуется исправление подписи или конфигурации приложения."
        }
        switch stage {
        case .access: return "ScreenCaptureKit не смог проверить доступ к экрану. Перезапустите \(application) и повторите подключение."
        case .virtualDisplay: return "Не удалось создать второй экран. Проверьте совместимость macOS или выберите заранее созданный виртуальный экран."
        case .content: return "Выбранный виртуальный экран недоступен для захвата. Подключите его заново."
        case .encoder: return "Не удалось запустить аппаратный H.264-кодировщик. Подключение остановлено."
        case .capture: return "Не удалось начать захват выбранного экрана. Подключение остановлено."
        }
    }
}
