# Второй экран, компактный пульт и звук после сна

10 октября 2026. Manager **0.9.3/build17** установлен; TV Display остаётся **0.7.1/code18**, wire protocol совместим. Этап 13 активен до ручной приёмки плавности, звука, 50 FPS и поведения после сна.

## Ограничение передачи

Пользователь сообщил просадки во всех счётчиках:60→50–60,50→40–50,30→20–30. В коде нет постоянного вычитания10. Прежний sender начинал следующий encode только после подтверждения MediaCodec предыдущего кадра, сериализуя encode и network/admission.

Теперь один encode может идти параллельно с одной отправкой; допускается один ожидающий compressed packet и один latest raw. Закодированные H.264 reference frames не заменяются и передаются по порядку. При перегрузке заменяются только ещё не закодированные raw frames. ACK остаётся подтверждением MediaCodec admission, а не TCP delivery или Surface display. Протокол, TLS/pinning, single network send и timeout сохраняются.

Захват использует аппаратно поддерживаемый NV12 вместо BGRA и пять server-side surfaces. Оценка без stride:5×1.5 bytes/pixel меньше прежних3×4; это не измерение полной памяти WindowServer. Приложение не создаёт растущую очередь. Для собственного виртуального экрана используется native-refresh capture без второго throttle; для выбранного существующего экрана сохраняется explicit FPS cap.

В технические данные добавлены p95 длительности кодирования и ожидания подтверждения, число complete/idle/other capture samples и число фактически закодированных кадров. Idle не считается потерянным сетевым кадром. Реальные интервалы по PTS и admission доступны в приватном runtime отчёте.

## Локальные проверки

Аппаратный AVC:48 generated frames,12 modes, BGRA/NV12. Проверка удержанного fake ACK подтверждает bounded overlap, порядок compressed PTS, выбор latest raw, отсутствие изменения counters после stop при позднем ACK. Core/fake/helper/virtual-display doubles и сборка/подпись Manager проходят без UI.

На коротком неизменяемом generated buffer без capture/UI/сети/ТВ:при fake ACK0мс30/50/60FPS, без raw replacement. При искусственном ACK20мс target60 вырос примерно32.7→41.6FPS, target50 —31.3→40.7. Это демонстрация архитектурного улучшения, не измерение реальной RTT, сложного видео, Surface или плавности ТВ.

Первый реальный вариант NV12/overlap с прежним capture interval1/60:два audio1366×768/target60 сеанса дали capture50.01/56.01, admission49.81/56.01, decoder output49.73/56.04 при stimulus59.18/58.46. Оба были active до stop, PCM отправлялся, ресурсы освобождены и собственные дисплеи удалены. p95 encoder9.73/9.04мс, admission14.03/10.93мс. Приём почти совпадает с захватом; остаточное ограничение возникает upstream. Surface не измерен.

Итоговый вариант native-refresh:два повторных audio1366×768/target60 сеанса дали capture58.60/58.59, admission58.47/58.06, decoder output58.14/58.23 при stimulus58.60/58.66. p95 capture interval снизился33.33→16.67мс; p95 encoder8.60/8.43мс, admission21.29/10.80мс. В обоих сеансах отправлялся PCM, active сохранялся до stop, ресурсы освобождены и собственный дисплей удалён. Сравнение указывает на вклад второго capture throttle в просадки, но не доказывает устранение всех причин. Это короткие15с измерения после3с warm-up с AppKit moving-bar stimulus; стабильные ровно60FPS, Surface и long-run не подтверждены. Сравнение50/60 и визуальная приёмка выполняются пользователем. Кнопка питания агентом не нажималась.

Обычный GUI финального signed build также запущен в1366×768/60 со звуком:ТВ подтвердил декодирование, закрытие окна полностью завершило Manager и собственный ADB helper, удалило виртуальный дисплей. После выхода отдельное bounded read-only чтение подтвердило отсутствие receiver/decoder/audio workers; версия TV0.7.1, HOME/IME и timer1час сохранены. Это проверка жизненного цикла, не ещё один FPS benchmark.

## Пульт и питание

D-pad расположен по центру компактного блока шириной320pt. Слева Home/Back/Menu/Settings, справа volume+/volume−/mute/play-pause; сверху power/keyboard/apps/display. Все команды сохраняют tooltip и accessibility name; широких Spacer между боковыми кнопками и D-pad нет.

«Выключить ТВ» сначала завершает трансляцию и закрывает собственный remote channel, затем адресно отправляет KEYCODE_SLEEP223 через ADB. POWER26 не используется:он переключал бы состояние и мог разбудить спящий ТВ. Home bridge whitelist не расширяется, новый Home APK не нужен. Фактическое засыпание требует ручной проверки; агент не запускал новый sleep/wake сценарий.

## Плохой звук после сна

Пользователь сообщил плохой звук и в приложениях ТВ, и с Mac. Сняты bounded read-only audio/HAL/driver/performance данные при активном YouTube. После отдельного согласия выполнена одна обычная перезагрузка; пользователь сообщил «Звук стал лучше». Вслед за этим сохранён второй снимок при активном YouTube.

| Показатель | Плохой звук | После перезагрузки, звук лучше |
|---|---|---|
| Источник/маршрут | YouTube / speaker | YouTube / speaker |
| Формат | PCM16 / stereo /48kHz | Совпадает |
| Master balance / gains |0 /1:1 | Совпадает |
| Mixer underruns |partial0 /empty0 | Совпадает |
|18 saved sound keys |Сохранённый набор |Все совпадают |
| HAL Dolby/DAP/downmix/sink fields |Доступный dump |Совпадают |
| Threadloop write latency avg |97.91мс |98.10мс |
| Оценка на слух |Плохо, user report |Лучше, user report |

Предыдущий хороший результат после перезагрузки также имел тот же сохранённый набор18 sound keys. Изменение слышимого звука при одинаковых доступных параметрах поддерживает гипотезу временного состояния vendor DSP/HAL/amplifier после standby; конкретный компонент и причина не доказаны. Количество effect chains0 в Android не доказывает отсутствие vendor DSP. Доступный threadloop latency похож в обоих случаях и не объясняет тембр. Перезагрузка — временная мера, не доказанное постоянное исправление.

Kernel ALSA cards/PCM, kernel log, GPU/display sysfs и thermal temperatures закрыты для shell. Thermalservice сообщает HAL Ready:false; его Status0 не доказывает отсутствие перегрева. Библиотеки audio.primary.m5621 и soundfx существуют;10 доступных файлов хешированы приватно. Загружены штатные MStar video/Mali/MT7668 network modules; их наличие не доказывает исправность каждого аппаратного блока. Firmware fingerprint совпадает с исходным. Драйверы не заменялись и службы не перезапускались вручную.

Во время разрешённой передачи Mac→ТВ выполнен тихий stereo test:500Hz поочерёдно left/right, без mic. Пользователь подтвердил:«Оба звучат нормально». Это ручная оценка слышимости обоих каналов сейчас; широкополосная АЧХ, калиброванная громкость и исправность после следующего сна не измерялись.

## Сверка оптимизаций

Сохраняются screen timeout1час, screensaver0, sleep timeout3часа, METZ default HOME, отключённые stock launcher/recommendations и прежние user overrides. Данные/IME/ADB сохранены при reboot. Anoki не отключался повторно. На активном YouTube один2с CPU interval36.1%, MemAvailable183460KiB, /data48%used. Это не сопоставимый benchmark с прежним idle HOME. CPU governor interactive, доступные пределы штатные1.0–1.3GHz; policy0 max закрыт. PSI отсутствует, часть zram/thermal данных недоступна. Из этих данных не выводятся энергопотребление или выигрыш оптимизаций.

Wi-Fi в read-only снимке:2.4GHz,RSSI−53dBm,reported link104Mbps; прежний idle snapshot сообщал144Mbps. Link rate не равен реальной скорости, режимы нагрузки различались. Замер фактической пропускной способности и потерь пакетов не проводился. Ничего не менялось в CPU/GPU/network/thermal/security controls.

## Возврат и продолжение

Приватно сохранены точный установленный Manager0.9.2/build16 и source-before, а также промежуточные signed bundles; текущий0.9.3 подписан прежней identity. Возврат Manager — завершить его, переместить новый bundle в приватный.noindex и восстановить точный прежний bundle; full rollback не запускался. TV receiver не обновлялся, старый подготовленный TV rollback0.7.0/code19 сохраняется.

После reboot совпали firmware/default HOME/IME/ADB/screen timeout. Перезагрузка не имеет точного возврата runtime DSP state и была отдельно согласована. Новых настроек ТВ не применяли. Raw logs, IP/SSID/identities, APK и bundles остаются только в игнорируемом local/.noindex.

Следующий шаг:ручная оценка компактного пульта/power/50FPS; сопоставление capture pacing на реальном контенте и последующее пробуждение. Постоянное устранение standby-audio дефекта, точная Surface cadence и Mac-original-audio/video sync остаются открытыми.

Источники: [Apple ScreenCaptureKit frame-rate/surface guidance](https://developer.apple.com/videos/play/wwdc2022/10155/), [minimumFrameInterval](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/minimumframeinterval), [Android Audio HAL](https://source.android.com/docs/core/audio/implement), [Android audio debugging](https://source.android.com/docs/core/audio/debugging). Данные конкретного ТВ получены bounded ADB readback; raw не публикуются.
