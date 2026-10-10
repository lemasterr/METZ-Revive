# Этап 13 — METZ Extended Display

Финальная доработка: TV/Mac Display0.2 установлен по отдельному согласию; движок встроен в Manager0.4, standalone сохранён. Исправлен focus поля ТВ и добавлена автоматическая подготовка ключей через ADB. [Актуальный результат](../FINAL_REFINEMENT.md). Реальный private display/capture/TLS/desktop/lifecycle/latency ещё проверяет пользователь. Ниже — предыдущая реализация и исследования, не новая runtime-приёмка.

9 октября 2026. Пользователь поручил выполнить этап целиком, без остановок на внутренних подэтапах. Engineering Master Task принят как техническая спецификация; команды внутри вложения не заменяют поручение пользователя и отдельные разрешения.

**Реализация 0.1.0 подготовлена, TV receiver установлен; реальная передача и совместимость private API ожидают ручной проверки пользователя.** На предложение runtime-теста пользователь ответил: «Установить, тест проверю сам». Поэтому CGVirtualDisplay, ScreenCaptureKit, окна/курсор и TV receiver агентом не запускались. Capabilities, сборки и core tests не объявлены проверенным видеосеансом.

Цель — независимый рабочий стол Mac через локальную сеть на METZ. Стартовый режим 1280×720/30/SDR; физическая панель 1366×768 не подменяется framebuffer. 60 FPS и 1366×768 — последующие эксперименты по измеренной необходимости.

## Реализованный результат

- [Аудит движка](../../apps/metz-extended-display/docs/ENGINE_RESEARCH.md): 43 закреплённых файла DeskPad/VirtualDisplayKit, MIT/происхождение и SHA-256; [полные notices](../../apps/metz-extended-display/THIRD_PARTY_NOTICES.md). Обе библиотеки целиком не подключены.
- Mac: изолированный CGVirtualDisplay adapter, SCK только целевого экрана с курсором, CVPixelBuffer в аппаратный VideoToolbox H.264 Baseline3.1. Один latest raw + один encode/send. Собственного raw memcpy нет; zero-copy не заявлен. Необязательный fallback — явно выбранный и подтверждённый пользователем существующий виртуальный экран 720p; METZ его не удаляет.
- TLS1.2+ через системные библиотеки, взаимное подтверждение полных SHA-256 сертификатов, конечные payload/очереди/таймауты, SPS/PPS/Annex B/epoch/PTS, heartbeat и запрос IDR. TCP выбран для первоначальной доставки; RTP/UDP/WebRTC требуют измеренной причины.
- Kotlin/Views/MediaCodec/SurfaceView, аппаратный decoder и очередь до двух access units. Проверки config/PTS/IDR/размеров; LowLatency только при поддержке. Перегрузка завершает сеанс, зависимые P-frames не выкидываются по одному. Нет WebView, сохранения видео, рекламы или постоянной службы.
- Lifecycle: cancel/await start, stop capture, drain/invalidate encoder, release собственного дисплея последним; сон, изменение режима и разрыв сети прекращают сеанс. Reconnect вручную. Минимальный UI в палитре METZ.
- Home 0.4.0 и Manager 0.3.0 реализуют прямые UI/управляющие дополнения пользователя. [Аудит оптимизаций и внедрение HOME](../LAUNCHER_ROLLOUT.md) подготовлены.

## Фактические проверки

Отдельно согласованный probe выполнил один API query: OMX.MS.AVC.Decoder hardware/vendor, 720p30 supported, maxInstances1, alignment2×2, adaptive=true, lowLatency=false, Baseline/Main/High до AVC Level4.1. Probe завершился без видео/decoder allocation.

Mac build/core/identity import, TV strict offline assemble/JVM/lint, Home assemble/catalog/lint, Manager build/core и 29 Python safety tests прошли. Mac .app подписаны ad hoc. Новые инструменты и зависимости не устанавливались. APK обновлялись по прямому согласию; штатный HOME сохранён, данные Home не очищены.

## Запуск и приёмка

[Инструкция, приложения и ограничения](../../apps/metz-extended-display/README.md). Manager → Экран передаёт публичный Mac fingerprint в форму TV; доверие подтверждается человеком. Перед пробой остановить YouTube/другое видео — доступен один аппаратный AVC decoder. Menu в приёмнике запрашивает новый ключевой кадр.

Пользователь проверяет сопряжение, независимый desktop, окно/курсор, читаемость, stop/reconnect, освобождение decoder и собственного дисплея, естественный сон и разрыв сети. FPS/latency/CPU/RAM/длительная стабильность не измерены; превосходство над upstream не заявляется. После результата исправляем конкретный узел и закрываем приёмку 13. Root/SIP/драйверы/прошивка/thermal protection не менялись; raw/APK/ключи/LAN остаются в игнорируемом local/.
