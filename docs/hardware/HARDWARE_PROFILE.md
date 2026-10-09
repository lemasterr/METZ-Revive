# Аппаратный профиль METZ 32MTC6000Z

Дата: 9 октября 2026. Измерения получены с физического ТВ через авторизованный ADB shell без root. Модель 32MTC6000Z сообщена пользователем; Android идентифицирует устройство общим именем `METZ 2K TV`.

## Подтверждённые данные

| Компонент | Значение | Доказательство / предел вывода |
|---|---|---|
| Платформа | `m5621`, board `SW1`, device `shinagawa`, manufacturer `skyworth` | Выбранные `getprop`, `/proc/cpuinfo`; MediaTek/MStar vendor services. Точное коммерческое название и ревизия кристалла неизвестны |
| CPU | 4 × ARM Cortex-A53, revision 4 | 4 процессора, implementer `0x41`, part `0xd03`; соответствие part Cortex-A53 — [Arm TRM](https://documentation-service.arm.com/static/5e9075f9c8052b1608761519) |
| Исполняемая архитектура | 32-bit ARM: `armv7l`, `armeabi-v7a,armeabi` | Ядро и ABI; A53 не означает наличие 64-bit Android или совместимость ARM64 APK |
| Частоты CPU | 1000, 1100, 1200, 1300 МГц; governor `interactive` | cpufreq policy0–3, доступны `interactive` и `performance`; один файл `policy0/scaling_max_freq` закрыт |
| GPU | ARM Mali-470 MP, OpenGL ES 2.0 | SurfaceFlinger GLES; число GPU-ядер и частота не установлены |
| RAM, доступная ядру | 929 000 КиБ = 907,2 МиБ | `MemTotal`; это не точный объём установленной DRAM. Номинальные ~1 ГБ остаются предварительными |
| CMA | 122 880 КиБ = 120 МиБ; свободно 420 КиБ в первом снимке | `/proc/meminfo`; используется мультимедийными буферами, малая свободная CMA сама по себе не доказывает утечку |
| zRAM / swap | 511 996 КиБ общего swap, 313 464 КиБ занято при `meminfo`; 112 200 КиБ физически занимает zRAM | `dumpsys meminfo`; `/proc/swaps` и zram sysfs закрыты. Алгоритм компрессии и writeback неизвестны |
| `/data` | 4 500 256 КиБ = 4,292 ГиБ; доступно 2 257 240 КиБ = 2,153 ГиБ; 49% занято | `df -k`; ёмкость userdata, не всего накопителя |
| Накопитель | MMC block device, MStar MCI, отдельные system/vendor/boot/recovery/userdata | by-name и mounts. Полная ёмкость, модель и показатели износа закрыты; eMMC вероятен, не идентифицирован полностью |
| Android display | 1280×720, ~60 Гц, density 213; один exposed mode, HDR types отсутствуют | `wm size`, `dumpsys display`; override-размер не задан |
| Панель модели | 1366×768 по официальному листу модели | [METZ datasheet](https://metzblue.com/fileadmin/Datasheet/MTC6000/32MTC6000Z_Data__Sheet_EN.pdf); физическая панель экземпляра непосредственно не измерялась |
| Wi-Fi | `wlan0`, текущая частота 2432 МГц, RSSI −53 dBm, Tx link rate 57 Мбит/с | Первый снимок wifi; это PHY rate, не пропускная способность интернета. Поддержка 5 ГГц не установлена |
| Ethernet | `eth0` присутствует, `NO-CARRIER` | Возможность проводного сравнения; кабель в снимке не подключён |
| Bluetooth / USB | Bluetooth, BLE и USB host объявлены | `pm list features`; USB-клавиатура работает по сообщению пользователя |
| HDMI | 2 входа, оба CEC, ARC у порта 1; CEC service включён | `dumpsys hdmi_control`; ARC не установлен. Входные разрешения/частоты и задержка не измерены |
| Сенсоры | SensorService: `No Sensors on the device`; 2 thermal zone nodes | Thermal HAL `Ready: false`, температуры/limits sysfs закрыты. Это не доказывает отсутствие аппаратных термодатчиков |

## Android и прошивка

| Поле | Значение |
|---|---|
| Release / SDK | Android 11 / API 30 |
| Security patch | `2025-06-01` |
| Display build | `RTO9.250817.002` |
| Incremental | `13948470` |
| Fingerprint | `Metz/Metz_EU/shinagawa:11/RTO9.250817.002/13948470:user/release-keys` |
| Vendor fingerprint | Совпадает с системным |
| Kernel | `4.9.243+`, SMP PREEMPT, build 12 августа 2025, 32-bit ARM |
| Тип / подпись | `user`, `release-keys` |
| Verified Boot / SELinux | `green` / `Enforcing` |
| Low-RAM | `ro.config.low_ram=true`, `android.hardware.ram.low` |

Лист модели METZ описывает исходный Android 9; измеренный экземпляр работает на Android 11. Fingerprint и release-keys не подтверждают путь OTA, происхождение установочного файла или совместимость произвольной прошивки. Состояние bootloader lock не установлено: соответствующее свойство пустое. A/B OTA также не подтверждён; пустое свойство нельзя считать окончательным доказательством отсутствия.

## Видеодекодирование

Из `/vendor/etc/media_codecs.xml`: vendor OMX-декодеры M4V, H.263, AVC/H.264, HEVC/H.265, MPEG-2, VP8, VP9, FLV, VC1, WMV3, MJPEG. Для AVC/HEVC/VP9 есть secure варианты. У основных video-декодеров заявлен **один concurrent instance**; для AVC/HEVC/VP9 максимум указан 1920×1088.

В `media.metrics` есть реальное использование `OMX.MS.VP9.Decoder` приложением YouTube, включая поток 1920×1080. Это подтверждает использование vendor-видеотракта для данного воспроизведения. Плавность, Twitch, secure playback и каждый перечисленный codec отдельно не проверялись.

Присутствуют software OMX Google и C2 Android configurations. Запись AV1 в C2 XML относится к программному декодеру и условию `!slow-cpu`; она не подтверждает доступность AV1 на этом low-RAM ТВ. Vendor hardware AV1 не обнаружен. Числа `measured-frame-rate` в vendor XML — метаданные поставщика, не измеренные нами FPS. Не обещать 1080p60 и не считать codec latency из накопленной статистики задержкой end-to-end.

## Ограничения доступа и будущей архитектуры

- ADB shell UID 2000, SELinux Enforcing, без root. Доступны package inventory, системные dumpsys, выбранные props, CPU/memory и ограниченные logcat.
- Недоступны kernel log, `/proc/partitions`, `/proc/diskstats`, `/proc/asound/*`, zRAM tuning, eMMC health и thermal sysfs. Swap-rate counters в доступном `/proc/vmstat` не представлены; PSI paths отсутствуют.
- Для METZ Home нужен 32-bit совместимый APK и малый расход RAM. Штатный HOME сохранять до ручной проверки замены.
- Для casting один video instance означает, что параллельное декодирование нескольких потоков нельзя закладывать как гарантированную возможность. H.264 — кандидат для будущей проверки, а не готовая архитектура.
- Система не предоставляет надёжной температуры через проверенные интерфейсы. CPU frequency не доказывает отсутствие throttling; энергопотребление без ваттметра не измерено.

## Источники и воспроизводимость

Локальные приватные снимки: `initial.json` (`identity`, `cpu`, `memory`, `storage`, `display`, `thermal`, `media`), `focused.json` (`soc_detail`, `codec_config`, `capabilities`), `context.json` (`codec_additions`, `agent_libraries`). Они находятся в `local/diagnostics/`, исключены из Git и не являются безопасными для публикации.

Справочная интерпретация RAM/zRAM: [Android memory management](https://developer.android.com/topic/performance/memory-management). Эти общие материалы не доказывают конкретный размер DRAM, алгоритм zRAM или наличие новых механизмов Android на прошивке API 30.
