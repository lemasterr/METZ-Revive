# METZ Home — внедрение и проверка оптимизаций

10 октября2026: Home0.6 выбран default; com.google.android.tvlauncher отключён для user0, APK/data сохранены. Cached-empty процесс stock завершён адресно. Версии/data/IME/ADB/HOME проверены чтением. HomeEntry включён подписанным манифестом, поскольку shell изменение отдельного компонента запрещено для nondebuggable app. На этой прошивке включённый stock priority2 перекрывал set-home-activity до отключения. [Актуальный результат и точный возврат](USABILITY_REFINEMENT.md). Ниже — исторический аудит/план0.4–0.5; фактическая последовательность0.6 описана в новом отчёте.

Home0.5/TV Display0.2 localOptimized установлены после отдельного согласия; данные/stock HOME сохранены. Подготовлены rollback APK старого кода с равными code5/code3 и той же подписью. После nondebuggable обновления downgrade исходными APK не гарантирован — используйте подготовленный возврат с равными versionCode. Default HOME ещё не менялся. [Актуальная доработка](FINAL_REFINEMENT.md).

9 октября 2026. Home0.4.0 установлен после отдельного согласия, METZ Display0.1.0 также установлен. Штатный HOME всё ещё выбран, HomeEntry ещё не допущен в HOME resolver. Пользователь подтвердил ручные Cast/Manager прежней версии; новые UI/управление и Display он проверит сам. Смена HOME/отключение старого launcher **не выполнялись**.

## Что проверено перед сменой HOME

Повторный maintenance-срез: 6/6 команд, Home0.4.0, enabled штатный HOME/новый Home/Kick/atvTools/No BS/TV Bro/Cast, disabled Recommendations, enabled Anoki. Отдельное чтение подтвердило stock default и отсутствие HomeEntry среди кандидатов, ADB enabled=1. RAM MemAvailable254736 КиБ, /data available2456900 КиБ — один срез, не замер улучшения. Meminfo SwapTotal511996/SwapFree249224 КиБ; `/proc/swaps` и `zram0/disksize` повторно недоступны (permission denied), поэтому текущий zRAM backend из этого чтения не подтверждается. Защита не обходилась.

| Пункт | Реально выполнено/проверено | Что осталось |
|---|---|---|
| Безопасный baseline/возврат | Снимки пакетов/HOME и сохранённые APK; возврат согласованной пачки Recommendations/Anoki практически проверен | Аварийное recovery/firmware не подтверждено |
| Реклама/фон | Recommendations отключён; Anoki возвращён в default после отсутствия подтверждённого полезного эффекта | Ручная оценка лишнего контента/уведомлений; прочие vendor-службы без доказательств не отключать |
| Браузер | No BS установлен, TCL адресно удалён ранее, TV Bro сохранён | Детальный сценарий сайтов/видео и сравнение скорости не представлены |
| Лёгкий Home | Views, нет сети/permissions/Recent/диагностики; пять иконок на странице; bounded2МиБ icon cache, один worker только пока visible, debounce package changes | Проверить0.4.0 пультом/поиском/свайпом, после standby и долгого использования |
| Оптимизация APK | Выявлено: установленный debug не выполняет полную R8 code optimization. Добавлен отдельный localOptimized: debuggable=false, minify/R8, shrinkResources, та же локальная подпись | Оптимизированный APK пока не установлен; перед default HOME обновить без очистки данных и проверить вручную. Это не магазинная подпись |
| Cast/Manager | Пользователь прямо сообщил «проверки прошли» | Новые Manager0.3.0 controls/UI ещё не проверены; скорости не измерены |
| Звук | После отдельно согласованного reboot пользователь сообщил улучшение | Причина, тембр на разных источниках и повтор после сна открыты; бессистемно EQ/DSP не менять |
| Память/swap | meminfo/data читаются; раньше zRAM исследован, параметры вручную не менялись | Новые backend/thermal данные ограничены доступом; не выдавать CPU за энергопотребление |
| Автообслуживание | On-demand snapshot/report работает, 29 safety tests | Расписание/автоочистка/автоперезагрузка не реализованы и сейчас не нужны для смены HOME |
| Extended Display | Нативные приложения/протокол собраны, hardware AVC query выполнен | Пользовательская end-to-end проверка, latency/lifecycle/decoder release; это не оптимизация Android HOME |

Не всё проверено полностью: нет сравнительных speed/latency и длительной стабильности. По доступным фактам новой общей пачки «ускорений» сейчас не требуется. Самые полезные следующие проверки — Home0.4.0 focus/standby и освобождение decoder после Display. Не менять частоты, thermal/SIP/SELinux, не очищать данные и не отключать Cast/ввод/сеть/atvTools ради неподтверждённого ускорения.

Оптимизированные локальные артефакты подготовлены: Home — 52 308 байт, Display — 51 224 байта. Strict offline assembleLocalOptimized/lintLocalOptimized прошли; подпись совпадает с установленным debug, manifest не debuggable. Lint: Home 0 ошибок/10 предупреждений, Display 0 ошибок/6 предупреждений. Это уменьшение APK и включённая оптимизация сборки, не измеренный выигрыш latency/RAM. Артефакты сохранены приватно в local/display с суффиксом local-optimized; установка не выполнялась.

## Следующий шаг внедрения

1. Проверить Home0.4.0, особенно запуск/возврат приложений, поиск, перелистывание и настройки. Перед выбором default обновить на подготовленный localOptimized APK той же версии/подписи без очистки данных, после отдельного согласия на установку; повторить короткую ручную пробу. Держать ADB и USB-клавиатуру доступными.
2. В **METZ Home → Настройки → Использовать METZ Home** включить его HOME alias и выбрать METZ Home в настройках Android. Это адресное действие пользователя; приложение не выбирает себя скрытно. Затем проверить обычную кнопку HOME и возврат после standby.
3. Первую пробу провести с установленным/включённым штатным launcher. Он даёт быстрый возврат. Выбор нового default и отключение старого — два разных изменения.
4. После устойчивой работы при необходимости отдельно согласовать отключение только `com.google.android.tvlauncher` для user0. Сначала сохранить его текущее состояние и default компонент, затем отключить пакет, проверить HOME/настройки/standby/ADB. Удалять системный APK или данные не нужно. Отключение Recommendations уже применено, повторять его не требуется.

При необходимости ADB-шаги для текущего устройства, **после отдельного согласия непосредственно перед записью**:

```sh
adb devices -l
# Home0.6: HOME alias уже доступен через манифест; shell enable компонента запрещён.
adb -s '<текущий serial>' shell cmd package set-home-activity --user 0 com.metzrevive.home/.HomeEntry
adb -s '<текущий serial>' shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME
# Только после устойчивой ручной пробы и отдельного согласия:
adb -s '<текущий serial>' shell pm disable-user --user 0 com.google.android.tvlauncher
```

Возврат при рабочем ADB; stock component предварительно перепроверить на актуальном ТВ:

```sh
adb -s '<текущий serial>' shell pm default-state --user 0 com.google.android.tvlauncher
adb -s '<текущий serial>' shell cmd package set-home-activity --user 0 com.google.android.tvlauncher/.MainActivity
# Для Home0.6 вернуть alias можно установкой подписанного rollback APK после восстановления stock HOME.
adb -s '<текущий serial>' shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME
```

Текущий stock package исходно имеет default override; при иной будущей исходной настройке возвращать точно сохранённое состояние. Версию Home можно вернуть APK0.3.0 той же подписи с `install -r -d`, без удаления данных; такой downgrade из0.4.0 пока не испытан. Эти шаги не являются аварийным восстановлением при потере загрузки/ADB. План находится здесь; команды смены/отключения в этом сеансе не запускались.
