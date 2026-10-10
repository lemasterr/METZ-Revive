# Manager 0.8.1 / TV Display 0.6.1: устойчивость и подключение

10 октября 2026. **Manager0.8.1/build13 и TV Display0.6.1/code14 установлены** по сохранённому разрешению пользователя ставить готовые обновления. Пользователь сообщил обрыв при быстром курсоре на60FPS, отказ других разрешений и зависимость от Terminal; уточнил, что Manager остаётся открыт, исчезает экран ТВ.

## Доказательства и уверенность

| Наблюдение | Вывод |
|---|---|
| Экран исчезает, Manager открыт | Сообщение пользователя об обрыве сеанса; crash Manager не подтверждён |
| Два STREAM_READ_OR_FORMAT в ограниченной выборке | Старый код объединял ошибку формата и закрытие сокета; точная причина обрыва не установлена |
| Receiver отвергал изменённый JSON после запуска codec | Подтверждённая хрупкость при обновлении SPS/PPS; связь с быстрым курсором остаётся гипотезой |
| Режим Quartz не выбирался явно, ID мог появиться после applySettings | Подтверждённые проблемы создания/смены режима; реальный WindowServer не проверен |
| ICMP/TCP доступны, общий daemon ADB сообщает отсутствие маршрута; собственный helper подключается | Подтверждено различие между daemon и собственным helper. Причина отказа общего daemon, включая разрешения macOS, не доказана |

## Изменения

Receiver проверяет неизменность размеров/FPS/audio/epoch, но принимает обновлённые SPS/PPS внутри сеанса. Параметры передаются с последующим IDR в одном decoder input buffer; MediaCodec не пересоздаётся при обновлении CSD. Лишний первоначальный запрос ключевого кадра удалён. Ограниченная очередь, один compressed frame в полёте и admission ACK сохранены; это ограничивает память, но не доказывает60FPS.

READ_TIMEOUT, PEER_CLOSED и IO отделены от ошибок формата. TV передаёт фиксированный stage code при отклонении пакета, Manager сохраняет последнюю ошибку после исчезновения экрана. Содержимое кадров и ключи не записываются в журналы.

Serial виртуального экрана зависит от режима. После applySettings движок ограниченно ждёт ID/регистрации, явно выбирает соответствующий CGDisplayMode через Quartz, отключает зеркалирование только собственного экрана и ждёт применения. После остановки ждёт удаления прежнего экрана. Физические экраны не перенастраиваются, ошибки освобождают принадлежащий сеансу handle.

Manager запускает собственный foreground ADB helper по пользовательскому действию на отдельном loopback-порту, использует его для команд/пульта/диагностики и завершает свой PID при штатном выходе. Общий daemon не перезапускается и не завершается. При простом открытии Manager helper не запускается. Для helper отключены mDNS auto-connect и сканирование emulator transport; постоянного опроса ТВ нет. CPU/RAM после сеанса не измерены.

Сохранённый адрес доступен при пустом списке устройств. Подключение экрана всегда заново проверяет ADB. Нормальные сообщения cold-start daemon в stderr больше не считаются ошибкой. HOME/ADB_VENDOR_KEYS сохранены, ключи не сброшены. Ошибка ADB требует минуты до новой ручной попытки; автоматического цикла нет.

По нажатию подключения Manager выполняет ограниченную пустую TCP-проверку, чтобы macOS могла запросить Local Network для приложения. При localNetworkDenied выводится путь к настройке «Локальная сеть». TCC не сбрасывается, доступ не обходится.

Одноразовое доверие Mac/TV, сертификаты, optional system audio и восемь режимов до1366×768/60 сохранены. Отдельного Mac Display в Applications нет; Android Display необходим как приёмник. На ТВ не добавлены services/boot/alarm/polling; listener и decoder существуют только во время пользовательского сеанса.

## Проверки

- Manager core/fakeADB и loopback fixture: isolation/reuse/stop/restart helper, cold-start, key environment, whitelist и bounded commands — passed.
- Display core/native adapter doubles: ACK, nonfatal dropped frame, режимы, ID после настроек и cleanup — passed; private API не вызван.
- Аппаратный encoder:16 синтетических кадров, по два для каждого из восьми режимов — passed. Это не capture,60FPS/stress-тест или проверка TV decoder.
- Реальный собственный ADB helper в минимальном окружении с PATH=/usr/bin:/bin: подключение ТВ и protected metadata восьми режимов — passed. Activity/input/TLS/capture не запускались; helper завершён после проверки.
- TV JVM protocol, strict offline localOptimized Android build/lint — passed,0ошибок/7предупреждений. Native Manager build/codesign — passed. Новые зависимости/инструменты не устанавливались.
- После установки перечитаны версии, прежние APK certificate/Mac designated requirement, исполняемость backup, data inode/HOME/IME и protected metadata. Приёмник сообщает восемь режимов.

**Не проверено:** Manager GUI при закрытом Terminal и его Local Network permission, реальные создание/смена режима, быстрый курсор/окно, decoder60FPS/audio/latency/ресурсы после сеанса. CLI metadata check не заменяет runtime.

## Возврат и ручная приёмка

Прежние Manager0.8.0/TV0.6.0, исходники до/после и готовый rollback хранятся приватно в игнорируемом local/display-reliability.noindex/. receiver-rollback.apk содержит прежний TV0.6.0 с **code15**, тем же сертификатом и сохранением данных. Возврат: остановить сеанс/закрыть Manager; проверить adb devices-l и выбранный device; установить rollback через adb -s <проверенный target> install-r; архивировать текущий Manager в .noindex и вернуть installed-manager-before.app в Applications; проверить подпись/версию/HOME/IME/data. Следующему обновлению после возврата нужен code выше15. Полный возврат пары не выполнялся.

1. Cmd+Q, открыть Manager из Applications при закрытом Terminal. Подключить ТВ; если macOS спрашивает Local Network, разрешить Manager и повторить кнопку.
2. Проверить720p/30, остановить, выбрать1366×768/60; затем другое разрешение. Переместить курсор и окно обычным способом.
3. При обрыве скопировать сохранённую последнюю ошибку из «Экран»; сравнить режим30FPS.
4. Проверить повторное подключение с прежним доверенным ключом и звук по переключателю; после остановки изображение/звук должны прекратиться.

Этап13 активен до ручных результатов. Доработка установлена; следующая цель — принять устойчивость, смену режима и работу без Terminal, затем оставшуюся проверку звука/standby/ресурсов. Новый этап не добавлен.

## Основания API

[Apple TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) описывает атрибуцию сетевых действий helper ответственному приложению; это основание диагностики, а не доказательство конкретного отказа. [ADB man page](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/docs/user/adb.1.md) описывает отдельный server socket и foreground server. [Android MediaCodec](https://developer.android.com/reference/android/media/MediaCodec) описывает обновлённый CSD с ключевым кадром при adaptive Surface decode. [Quartz Display Services](https://developer.apple.com/documentation/coregraphics/quartz-display-services) — выбор режима собственного экрана.

Отключение auto-connect использует ADB_MDNS_AUTO_CONNECT=0 согласно [исходнику ADB](https://android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/adb_mdns.cpp); пустое значение сохраняет default allowlist.
