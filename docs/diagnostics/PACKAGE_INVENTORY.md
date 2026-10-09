# Инвентаризация пакетов

9 октября 2026. Источник первоначального среза: `pm list packages -f -U`, `-s`, `-3`, `-d`, выборочные `dumpsys package` и `dumpsys meminfo`. После него пользователь отдельно разрешил удалить TCL Browser и установить TV Bro 2.1.6; результат указан ниже. Другие пакеты не отключались и не удалялись.

## Кандидаты и защищаемые компоненты

PSS указан в КиБ ровно как в одном `meminfo`; это не гарантированная экономия после отключения. Пакет UID 1000 может делить процесс/права/зависимости с системой. Подробные receivers/providers и runtime связи проверены не для всех пакетов.

| Пакет / назначение | Факт / ресурсы | Можно ли отключать сейчас, последствия и возврат |
|---|---|---|
| `com.google.android.tvlauncher` — штатный HOME | HOME resolver подтверждён; PSS 46656 | Нет. Потеря HOME; сохранить до ручной проверки METZ Home. Возврат HOME — план в recovery |
| `com.google.android.tvrecommendations` — TV recommendations | PSS 17088, системный обновлённый пакет | Категория B: связь с launcher/channels требует проверки. Возможна потеря рекомендаций; вернуть исходное enabled-state |
| `com.smartdevice.leanbacklauncher.customizer` — vendor HOME customizer | PSS 4159, shared UID 1000 | Категория B: возможная интеграция OEM-каналов/launcher. До анализа связей не отключать; нужен возврат state |
| `tv.anoki.acr.controller` — ACR controller по имени пакета | PSS 12496, SYSTEM/PERSISTENT, INTERNET permission | Категория B: назначение и функция ACR не прослежены до пользователя/контента. Не считать доказанным единственным источником рекламы; возврат state до пробы |
| `fusion.android.tv.demo` — vendor demo | PSS 4750, shared UID 1000 | Категория B: возможные TV demo/картинка; низкая измеренная доля памяти. Сначала receivers/зависимости, потом точный возврат |
| `com.smartdevice.common.demonow` — предустановленный demo по имени | Установлен; отдельный расход не измерен | Категория B: неизвестные зависимости; не удалять по имени. Сохранить/вернуть исходное state |
| `com.tcl.browser` — TCL Browser | Пользователь сообщил о тормозах и лишних элементах; отдельно разрешил удаление | Удалён для user 0 с `-k`; нет в обычном package list, Leanback activity не разрешается. APK/splits сохранены локально; данные не экспортированы и восстановление ещё не испытано |
| `com.phlox.tvwebbrowser` — TV Bro | Установлен по отдельному согласию, 2.1.6 / code 69, WebView, 32-битный ARM | Сохранить. Подпись/хеш и установка проверены; скорость, RAM и UI не проверены |
| `com.kick.mobile` — пользовательское приложение Kick | Пользователь подтвердил использование; отдельная нагрузка не измерена | Сохранить. Не является кандидатом очистки |
| `tv.twitch.android.app` — Twitch | User package, версия 13.0.0.2; не активен в сценарии | Сохранить: пользовательская целевая функция. Нужна диагностика активного потока |
| `dev.vodik7.atvtoolsserver` — helper atvTools | User package, версия 1.4.1, процесс `:i`, PSS 22317 | Сохранить: пользователь управляет через atvTools. Отключение может ухудшить пульт; пользу удаления не измеряли |
| `com.google.android.apps.mediashell` — Google Cast | PSS 22730, CastReceiver/Warg services запущены | Сохранить. Не считать рекламоносителем по RAM; выключение нарушит casting |
| `com.google.android.tv.remote.service` — Android TV Remote | PSS 7067, Discovery/Remote services запущены | Сохранить. Это отдельный от atvTools компонент; не отключать по предположению о дублировании |
| `mtktvapi.agent` — vendor API/event agent | 3 crash, shared UID 1000, targetSdk 23 | Не отключать как «исправление»: роль событий громкости/TV не определена, возможны системные последствия |
| `com.heyzqt.wifimonitor` — OEM MetzFirewall | shared UID 1000 | Название не доказывает ненужность; сохранить до выяснения сетевой роли |
| `com.netflix.ninja` — Netflix | Уже отключён до диагностики | Не включать и не удалять самостоятельно; сохранить пользовательское исходное состояние |

Источник блоков рекомендаций исследован до состава компонентов: штатный Google HOME, recommendations, OEM customizer и Anoki. Какой компонент отвечает за каждый видимый рекламный блок, не установлено: screenshot/UI/network tracing не выполнялись. Обещать удаление всей рекламы отключением одного пакета нельзя.

## Полный список первоначальной установки

Системный пакет может быть обновлён в `/data/app`; место APK само по себе не определяет тип. Тип ниже взят из `pm -s` / `pm -3`. UID — числовой идентификатор Android, не имя/серийный номер пользователя. «Включён» означает отсутствие в списке `pm -d`, а не гарантированное состояние всех компонентов.

В первоначальном срезе 114 пакетов: 108 системных, 6 пользовательских; отключено 3. Таблица сохраняет этот срез. Последующая замена TCL Browser на TV Bro отражена выше, а не выдана за исходное состояние.

| Package name | Тип | UID | Состояние |
|---|---|---|---|
| `android` | Системный | 1000 | Включён |
| `android.auto_generated_rro_product__` | Системный | 10064 | Включён |
| `android.auto_generated_rro_vendor__` | Системный | 10072 | Включён |
| `android.autoinstalls.config.skyworth` | Системный | 10052 | Включён |
| `com.Smartdevice.emanual` | Системный | 10078 | Включён |
| `com.airoha.ble.ota` | Системный | 10037 | Включён |
| `com.android.backupconfirm` | Системный | 10009 | Включён |
| `com.android.bluetooth` | Системный | 1002 | Включён |
| `com.android.bluetooth.auto_generated_rro_product__` | Системный | 10065 | Включён |
| `com.android.bluetooth.auto_generated_rro_vendor__` | Системный | 10075 | Включён |
| `com.android.captiveportallogin` | Системный | 10047 | Включён |
| `com.android.certinstaller` | Системный | 10045 | Включён |
| `com.android.companiondevicemanager` | Системный | 10041 | Включён |
| `com.android.cts.ctsshim` | Системный | 10044 | Включён |
| `com.android.cts.priv.ctsshim` | Системный | 10030 | Включён |
| `com.android.deskclock` | Системный | 10080 | Включён |
| `com.android.documentsui` | Системный | 10077 | Включён |
| `com.android.dreams.basic` | Системный | 10034 | Включён |
| `com.android.dynsystem` | Системный | 1000 | Включён |
| `com.android.externalstorage` | Системный | 10027 | Включён |
| `com.android.hotspot2.osulogin` | Системный | 10083 | Включён |
| `com.android.htmlviewer` | Системный | 10038 | Включён |
| `com.android.inputdevices` | Системный | 1000 | Включён |
| `com.android.keychain` | Системный | 1000 | Включён |
| `com.android.localtransport` | Системный | 1000 | Включён |
| `com.android.location.fused` | Системный | 1000 | Включён |
| `com.android.networkstack.inprocess` | Системный | 1000 | Включён |
| `com.android.networkstack.permissionconfig` | Системный | 1073 | Включён |
| `com.android.networkstack.tethering.inprocess` | Системный | 1000 | Включён |
| `com.android.networkstack.tethering.inprocess.rro` | Системный | 10074 | Включён |
| `com.android.networkstack.tethering.rro` | Системный | 10076 | Включён |
| `com.android.pacprocessor` | Системный | 10060 | Включён |
| `com.android.printspooler` | Системный | 10035 | Включён |
| `com.android.providers.calendar` | Системный | 10016 | Включён |
| `com.android.providers.contacts` | Системный | 10025 | Включён |
| `com.android.providers.contacts.auto_generated_rro_product__` | Системный | 10046 | Включён |
| `com.android.providers.downloads` | Системный | 10003 | Включён |
| `com.android.providers.media` | Системный | 10003 | Включён |
| `com.android.providers.media.module` | Системный | 10084 | Включён |
| `com.android.providers.settings` | Системный | 1000 | Включён |
| `com.android.providers.settings.auto_generated_rro_product__` | Системный | 10069 | Включён |
| `com.android.providers.settings.auto_generated_rro_vendor__` | Системный | 10071 | Включён |
| `com.android.providers.tv` | Системный | 10010 | Включён |
| `com.android.providers.userdictionary` | Системный | 10025 | Включён |
| `com.android.proxyhandler` | Системный | 10028 | Включён |
| `com.android.se` | Системный | 1068 | Включён |
| `com.android.settings.intelligence` | Системный | 10014 | Включён |
| `com.android.sharedstoragebackup` | Системный | 10007 | Включён |
| `com.android.shell` | Системный | 2000 | Включён |
| `com.android.soundpicker` | Системный | 10003 | Включён |
| `com.android.statementservice` | Системный | 10012 | Включён |
| `com.android.systemui` | Системный | 10033 | Включён |
| `com.android.tv.overlay.lowram` | Системный | 10067 | Включён |
| `com.android.tv.settings` | Системный | 1000 | Включён |
| `com.android.tv.settings.overlay` | Системный | 10070 | Включён |
| `com.android.vending` | Системный | 10017 | Включён |
| `com.android.vpndialogs` | Системный | 10018 | Включён |
| `com.android.wallpaperbackup` | Системный | 1000 | Включён |
| `com.android.wifi.resources` | Системный | 10082 | Включён |
| `com.android.wifi.resources.rro` | Системный | 10073 | Включён |
| `com.coocaa.factory` | Системный | 1000 | Включён |
| `com.google.android.apps.mediashell` | Системный | 10032 | Включён |
| `com.google.android.apps.nbu.smartconnect.tv` | Пользовательский | 10029 | Включён |
| `com.google.android.backdrop` | Системный | 10031 | Включён |
| `com.google.android.boot.appsplashscreen` | Системный | 1000 | Включён |
| `com.google.android.ext.services` | Системный | 10006 | Включён |
| `com.google.android.ext.shared` | Системный | 10056 | Включён |
| `com.google.android.feedback` | Системный | 10020 | Включён |
| `com.google.android.gms` | Системный | 10002 | Включён |
| `com.google.android.gsf` | Системный | 10002 | Включён |
| `com.google.android.inputmethod.latin` | Системный | 10048 | Включён |
| `com.google.android.katniss` | Системный | 10023 | Включён |
| `com.google.android.marvin.talkback` | Системный | 10042 | Отключён |
| `com.google.android.modulemetadata` | Системный | 10079 | Включён |
| `com.google.android.onetimeinitializer` | Системный | 10022 | Включён |
| `com.google.android.overlay.modules.ext.services` | Системный | 10063 | Включён |
| `com.google.android.overlay.modules.modulemetadata.forframework` | Системный | 10066 | Включён |
| `com.google.android.overlay.modules.permissioncontroller` | Системный | 10062 | Включён |
| `com.google.android.overlay.modules.permissioncontroller.forframework` | Системный | 10068 | Включён |
| `com.google.android.packageinstaller` | Системный | 10013 | Включён |
| `com.google.android.partnersetup` | Системный | 10015 | Включён |
| `com.google.android.permissioncontroller` | Системный | 10085 | Включён |
| `com.google.android.play.games` | Системный | 10043 | Отключён |
| `com.google.android.sss.authbridge` | Системный | 10002 | Включён |
| `com.google.android.syncadapters.calendar` | Системный | 10036 | Включён |
| `com.google.android.tts` | Системный | 10040 | Включён |
| `com.google.android.tungsten.setupwraith` | Системный | 10021 | Включён |
| `com.google.android.tv.frameworkpackagestubs` | Системный | 10051 | Включён |
| `com.google.android.tv.remote.service` | Системный | 10011 | Включён |
| `com.google.android.tvlauncher` | Системный | 10019 | Включён |
| `com.google.android.tvrecommendations` | Системный | 10005 | Включён |
| `com.google.android.videos` | Пользовательский | 10049 | Включён |
| `com.google.android.webview` | Системный | 10054 | Включён |
| `com.google.android.youtube.tv` | Системный | 10039 | Включён |
| `com.google.android.youtube.tvmusic` | Системный | 10055 | Включён |
| `com.heyzqt.wifimonitor` | Системный | 1000 | Включён |
| `com.kick.mobile` | Пользовательский | 10026 | Включён |
| `com.mediatek.network` | Системный | 1000 | Включён |
| `com.mediatek.tv.service` | Системный | 1000 | Включён |
| `com.mediatek.tvinput` | Системный | 1000 | Включён |
| `com.mediatek.wwtv.mediaplayer` | Системный | 1000 | Включён |
| `com.mediatek.wwtv.setupwizard` | Системный | 1000 | Включён |
| `com.mediatek.wwtv.tvcenter.overlay` | Системный | 10001 | Включён |
| `com.mstar.android.tv.disclaimercustomization` | Системный | 1000 | Включён |
| `com.netflix.ninja` | Системный | 10050 | Отключён |
| `com.skyworth.backligthadjust` | Системный | 1000 | Включён |
| `com.smartdevice.common.demonow` | Системный | 10053 | Включён |
| `com.smartdevice.leanbacklauncher.customizer` | Системный | 1000 | Включён |
| `com.tcl.browser` | Пользовательский | 10061 | Включён |
| `dev.vodik7.atvtoolsserver` | Пользовательский | 10000 | Включён |
| `fusion.android.tv.demo` | Системный | 1000 | Включён |
| `mtktvapi.agent` | Системный | 1000 | Включён |
| `tv.anoki.acr.controller` | Системный | 10004 | Включён |
| `tv.twitch.android.app` | Пользовательский | 10057 | Включён |
