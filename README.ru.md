[English](README.md) | Русский | [繁體中文](README.zh-TW.md)

<h1 align="center">lightroom-agent</h1>

<p align="center">Доверьте ИИ-агенту отбор, обработку, маски и экспорт ваших фотографий в Adobe Lightroom Classic — каждое изменение он проверяет на рендере самого Lightroom.</p>

<div align="center">

<!-- Project -->
[![CI](https://img.shields.io/github/actions/workflow/status/fadedDexofan/lightroom-agent/ci.yml?branch=main&logo=github&label=CI)](https://github.com/fadedDexofan/lightroom-agent/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/fadedDexofan/lightroom-agent?include_prereleases&logo=github&label=release)](https://github.com/fadedDexofan/lightroom-agent/releases)
[![License](https://img.shields.io/github/license/fadedDexofan/lightroom-agent)](LICENSE)
[![Issues](https://img.shields.io/github/issues/fadedDexofan/lightroom-agent)](https://github.com/fadedDexofan/lightroom-agent/issues)

<!-- Package -->
[![npm](https://img.shields.io/npm/v/lightroom-agent?logo=npm&label=npm)](https://www.npmjs.com/package/lightroom-agent)
[![npm downloads](https://img.shields.io/npm/dm/lightroom-agent?logo=npm&label=downloads)](https://www.npmjs.com/package/lightroom-agent)
[![Node.js](https://img.shields.io/node/v/lightroom-agent?logo=nodedotjs&label=node)](#installation)

<!-- Runs in -->
[![Claude Code](https://img.shields.io/badge/Claude_Code-plugin-D97757?logo=claude&logoColor=white)](#installation)
[![Codex](https://img.shields.io/badge/Codex-plugin-412991)](#installation)
[![Claude Desktop](https://img.shields.io/badge/Claude_Desktop-.mcpb-D97757?logo=claude&logoColor=white)](https://github.com/fadedDexofan/lightroom-agent/releases)
[![MCP](https://img.shields.io/badge/MCP-server-000000?logo=modelcontextprotocol&logoColor=white)](docs/reference.md)
[![Agent Skill](https://img.shields.io/badge/Agent_Skill-lightroom--agent-6E56CF)](skills/lightroom-agent/SKILL.md)

<!-- Lightroom -->
[![Lightroom Classic 15+](https://img.shields.io/badge/Lightroom_Classic-15%2B-31A8FF)](#installation)
[![macOS](https://img.shields.io/badge/macOS-tested-000000?logo=apple&logoColor=white)](#installation)

</div>

<p align="center">
  <img src="docs/assets/demo-before.jpg" alt="Лувр и Сена в исходном виде" width="49%">
  <img src="docs/assets/demo-after.jpg" alt="Та же фотография после обработки агентом" width="49%">
</p>
<p align="center"><sub>Слева — raw-файл Sony под лицензией CC0 в исходном виде. Справа — агент обработал весь кадр и затемнил небо маской «Небо».</sub></p>

lightroom-agent — это сервер MCP и плагин Lightroom Classic. Claude Code, Codex или любой другой клиент MCP получает инструменты для каталога, модуля «Обработка» (Develop), масок и экспорта, а также скилл в комплекте, который учит агента отбирать и обрабатывать фотографии с их помощью.

> Здесь «плагин Lightroom» — плагин, который работает внутри самого Lightroom Classic, а «плагин для агента» — расширение Claude Code или Codex, которое устанавливает lightroom-agent в агента.

> **Работает с:** Claude Code, Codex CLI, Claude Desktop и любым другим клиентом MCP через stdio.<br>
> **Нужно:** Lightroom Classic 15.0 или новее на macOS (Windows не тестировалась) и Node.js 20 или новее.

<a id="quick-start"></a>

## Быстрый старт

1. Установите в Claude Code плагин для агента:

   ```text
   /plugin marketplace add fadedDexofan/lightroom-agent
   /plugin install lightroom-agent@lightroom-agent
   ```

2. Закройте Claude Code и запустите его снова. Его сервер lightroom-agent запускается вместе с сессией и устанавливает плагин Lightroom: появляется папка `~/Library/Application Support/Adobe/Lightroom/Modules/LightroomAgent.lrplugin`.
3. Закройте Lightroom Classic, если он запущен, откройте его и выведите его окно на передний план. В **Файл → Диспетчер плагинов** (File → Plug-in Manager) выберите **Lightroom Agent**: его статус — `Running: true`. Если там `false`, нажмите **Start Server**.
4. Попросите Claude: *Покажи мои коллекции Lightroom.* Он ответит названиями ваших коллекций или сообщит, что в каталоге их нет.

Codex, Claude Desktop и другие клиенты описаны в разделе [Установка](#installation).

<a id="something-not-working"></a>

### Что-то не работает?

1. Один раз выведите окно Lightroom на передний план: только тогда Lightroom запускает плагины.
2. В **Диспетчере плагинов** нажмите **Show Status** для Lightroom Agent. Если `Running` — `false`, закройте окно и нажмите **Start Server**. Когда сервер агента подключится, `Request socket connected` и `Response socket connected` покажут `true`. Окно показывает состояние на момент открытия; чтобы увидеть свежие данные, откройте его снова. Если одна из строк остаётся `false`, проверьте, что клиент запустил свой сервер lightroom-agent и что его порты совпадают с портами в Диспетчере плагинов.
3. Найдите сообщение об ошибке агента в разделе [Устранение неполадок](#troubleshooting).

## Что умеет агент

- **Отбор.** Поиск по рейтингу, дате, камере, объективу, ключевому слову или папке, сравнение кадров по превью и оценка резкости на фрагментах 1:1 из рендера в полном разрешении, а не по уменьшенному превью. Фото, открытое в Develop, превью не получает; `render_photo` рендерит его, как и любое другое фото, коротким экспортом.
- **Обработка.** Ползунки обработки задаются по их именам в Lightroom SDK; диапазоны проверяются до записи, а значения считываются обратно после того, как Lightroom их нормализует. Обрезка и выпрямление (Crop, Straighten) в том кадре, который видит агент, применение стилей (Presets), перенос обработки одной фотографии на другие и возможность вернуться к предыдущей обработке через снимки (панель «Снимки экрана», Snapshots) и именованные виртуальные копии (Virtual Copies).
- **Маски.** Маски «Предмет» (Subject), «Небо» (Sky), «Фон» (Background), «Люди» (People) и «Пейзаж» (Landscape); линейные градиенты (Linear Gradient) и радиальные градиенты (Radial Gradient), кисти (Brush), цветовые диапазоны (Color Range), диапазоны яркости (Luminance Range) и диапазоны глубины (Depth Range; только для фотографий с данными глубины); ползунки, кривые (Curve) и «Точечный цвет» (Point Color) для каждой маски. Если Lightroom не находит небо или предмет, вызов удаляет пустую маску и сообщает об этом. Для построения масок нужна [сертификация](docs/reference.md#mask-construction-and-certification) на этой машине, которая охватывает вашу сборку Lightroom и версию процесса (Process Version) фотографии; её повторяют после каждого обновления Lightroom; правка ползунков, кривых и «Точечного цвета» работает и без неё.
- **Организация.** Рейтинги (Ratings), флажки (Flags), цветные метки (Color Labels), ключевые слова (Keywords), коллекции (Collections), метаданные (Metadata) и GPS, а также приватные оценка и причина для каждой фотографии, которые не попадают в IPTC и XMP.
- **Экспорт.** В папку или через стиль экспорта (export preset); ответ перечисляет записанные файлы.

Что можно попросить:

- *Отбери вчерашние фотографии птиц. Отклони те, что нерезки при ширине 1080 px, и объясни почему.*
- *Обработай DSC_0412 в спокойной тёплой гамме, но сначала сделай снимок текущей обработки.*
- *Затемни небо на выбранных фотографиях маской «Небо» и покажи до и после.*
- *Подготовь мои пятизвёздочные фотографии за эту неделю для ленты Instagram в формате 4:5.*

## Чем отличается от lightroom-mcp

| | lightroom-mcp | lightroom-agent |
| --- | --- | --- |
| Результат вызова | Обычные ошибки; неудачная запись выглядит так же, как запись с неизвестным результатом | Единый конверт: `done`, `partial`, `failed`, `unknown` — по тому, что было записано; `failed` означает, что ничего не изменилось |
| Правка масок | Правка ползунков и кривых принимает id маски, выбирает эту маску в модуле «Обработка» и меняет выбранное, а выбор может сменить щелчок по другой маске прямо во время вызова | По id маски в сохранённых настройках фотографии, с обратным чтением после записи (`invert_mask` по-прежнему работает через модуль «Обработка») |
| Построение масок на новой сборке Lightroom | Разрешено для списка версий, заданного в исходном коде | Разрешено, когда тесты на живом Lightroom прошли на этой машине для этой сборки и версии процесса фотографии |
| Руководство для агента | Процесс построения стилей: отбор, правки с замкнутым циклом, стили по кластерам освещения, запасной путь через XMP | Скилл для отбора, обработки, маскирования и экспорта этими инструментами, с технической и редакторской проверкой |

Решения, стоящие за первыми тремя строками, описаны в [docs/adr](docs/adr/). [Набор тестов на живом Lightroom](tests/e2e/live/README.md) создаёт одноразовый каталог из фиксированных изображений и проверяет инструменты по рендерам Lightroom.

## Когда не стоит его использовать

- **Lightroom (облачное приложение) или Lightroom Classic ниже 15.0.** Плагин Lightroom запускается только в Lightroom Classic 15.0 и новее.
- **Windows, если нужна проверенная работа.** Сервер собирается и проходит CI на Windows, но с Lightroom там его никто не запускал.
- **Построение масок без Mac.** Сертификация запускает тесты на живом Lightroom, а им нужна macOS.
- **Каталог, который должен остаться без изменений.** Инструменты пишут в открытый каталог, поэтому перед подключением откройте в Lightroom его копию. `LIGHTROOM_AGENT_READ_ONLY=true` отключает инструменты записи для просмотра, но каждый вызов, включая чтение (кроме превью), сохраняет правку ползунка, которую вы не завершили в модуле «Обработка».

<a id="installation"></a>

## Установка

Установите lightroom-agent в каждый агент, которым пользуетесь; любой путь заканчивается одним и тем же [шагом в Lightroom](#finish-in-lightroom).

### Claude Code

Установите плагин для агента, как описано в разделе [Быстрый старт](#quick-start). Плагин включает сервер со всеми наборами инструментов и [скилл](#the-bundled-skill) в комплекте. Для обновления выполните `claude plugin marketplace update lightroom-agent`, затем `claude plugin update lightroom-agent@lightroom-agent`; для удаления — `claude plugin uninstall lightroom-agent@lightroom-agent`. После установки или обновления перезапустите Claude Code.

<details>
<summary><b>Codex CLI</b></summary>

```sh
codex plugin marketplace add fadedDexofan/lightroom-agent
codex plugin add lightroom-agent@lightroom-agent
```

Для обновления выполните `codex plugin marketplace upgrade lightroom-agent`, начните новую сессию и один раз перезапустите Lightroom; если в сессии нет инструментов Lightroom, удалите плагин и добавьте его заново. Для удаления — `codex plugin remove lightroom-agent@lightroom-agent`. `codex exec` начинает первый ход, не дожидаясь серверов MCP, поэтому инструменты Lightroom могут появиться лишь через несколько секунд после начала сессии. В Codex CLI 0.170.0 при `approval_policy = "never"` `codex exec` не предлагал ни одного инструмента MCP.

Если инструменты плагина не появляются, объявите сервер в `~/.codex/config.toml`, заменив `<version>` на свой релиз (его показывает `codex plugin list`). Эта запись заменяет сервер плагина; при обновлении держите её версию равной версии плагина.

```toml
[mcp_servers.lightroom]
command = "npx"
args = ["-y", "lightroom-agent@<version>"]
env = { LIGHTROOM_AGENT_TOOLSETS = "all" }
```

</details>

<details>
<summary><b>Claude Desktop</b></summary>

Скачайте `lightroom-agent-<version>.mcpb` из [последнего релиза](https://github.com/fadedDexofan/lightroom-agent/releases) и откройте его; Claude Desktop установит его как расширение. В настройках расширения задаются наборы инструментов и режим только для чтения. Для обновления откройте `.mcpb` более нового релиза; для удаления удалите расширение в настройках Claude Desktop.

</details>

<details>
<summary><b>Любой другой клиент MCP</b></summary>

Задайте команду, аргументы и переменные окружения из примера ниже в настройках MCP вашего клиента. Пример подходит для клиентов, которые принимают объект `mcpServers`. Замените `<version>` на версию [последнего релиза](https://github.com/fadedDexofan/lightroom-agent/releases).

```json
{
  "mcpServers": {
    "lightroom": {
      "command": "npx",
      "args": ["-y", "lightroom-agent@<version>"],
      "env": { "LIGHTROOM_AGENT_TOOLSETS": "all" }
    }
  }
}
```

`all` добавляет инструменты модуля «Обработка» и масок к набору `core` по умолчанию. Не снимайте закрепление версии: сервер отказывается работать с плагином Lightroom другой сборки, поэтому все клиенты должны запускать одну и ту же. Для обновления смените версию во всех клиентах. Сервер предлагает скилл как промпт MCP `lightroom-agent`.

</details>

<details>
<summary><b>Плагин Lightroom из zip-архива релиза</b></summary>

Сервер устанавливает плагин Lightroom, когда его запускает клиент MCP. Команда `call` из командной строки этого не делает, поэтому если вы пользуетесь только `call`, сначала установите плагин Lightroom:

1. Закройте Lightroom Classic.
2. Из релиза, версия которого совпадает с версией вашего сервера, скачайте `LightroomAgent.lrplugin-<version>.zip` и распакуйте его.
3. Если `LightroomAgent.lrplugin` уже есть в папке Modules или Plugins Lightroom, обновите его на месте командой `npx -y lightroom-agent@<version> install-plugin` (см. [Завершение в Lightroom](#finish-in-lightroom)). Иначе переместите распакованную папку в папку Modules: `~/Library/Application Support/Adobe/Lightroom/Modules/` на macOS, `%APPDATA%\Adobe\Lightroom\Modules\` на Windows. Если папки `Modules` нет, создайте её. Если установлен `LightroomMCP.lrplugin`, удалите его: оба плагина используют одни и те же порты.
4. Откройте Lightroom и проверьте статус, как в шагах 2 и 3 раздела [Завершение в Lightroom](#finish-in-lightroom). Затем выполните `npx -y lightroom-agent@<version> call list_collections` с версией из шага 2. Команда выводит результат в JSON и при успешном вызове завершается с кодом 0.

Zip-архив и npm-пакет одного релиза содержат одну и ту же сборку плагина Lightroom, поэтому сервер этого релиза принимает такую копию и не трогает её.

</details>

<details>
<summary><b>Из исходного кода</b></summary>

```sh
git clone https://github.com/fadedDexofan/lightroom-agent.git
cd lightroom-agent
npm --prefix server ci
npm --prefix server run build

# Claude Code, только в этой папке (добавьте --scope user для всех проектов)
claude mcp add lightroom -e LIGHTROOM_AGENT_TOOLSETS=all -- node "$PWD/server/dist/index.js"
# Codex
codex mcp add lightroom --env LIGHTROOM_AGENT_TOOLSETS=all -- node "$PWD/server/dist/index.js"
```

Для обновления выполните `git pull` и `npm --prefix server run build`, закройте все клиенты, выполните `node server/dist/index.js install-plugin`, перезапустите Lightroom, затем запустите клиенты. Сервер автоматически обновляет плагин Lightroom до более новой версии. Если номер версии остался прежним, а сборка изменилась, установите её вручную командой `install-plugin`, как описано выше. Работа с кодом описана в [CONTRIBUTING.md](CONTRIBUTING.md).

</details>

<a id="finish-in-lightroom"></a>

### Завершение в Lightroom

1. Запустите агента. Его сервер lightroom-agent устанавливает плагин Lightroom, обновляет более старый или восстанавливает свою сборку.
2. Закройте Lightroom Classic, если он запущен, откройте его и выведите его окно на передний план. Только тогда Lightroom запускает плагины.
3. В **Файл → Диспетчер плагинов** (File → Plug-in Manager) выберите **Lightroom Agent**: его статус — `Running: true`. Если там `false`, нажмите **Start Server**.
4. Попросите агента: *Покажи мои коллекции Lightroom.* Он ответит названиями ваших коллекций или сообщит, что в каталоге их нет. Если ответа нет, см. [Что-то не работает?](#something-not-working)

После любого обновления сначала перезапустите все клиенты, затем Lightroom, чтобы он загрузил установленный плагин Lightroom. До этого вызовы инструментов завершаются ошибкой "Lightroom has loaded a different plug-in build". Если клиент отказывается работать с плагином, установленным на диске, найдите его сообщение в разделе [Устранение неполадок](#troubleshooting).

<details>
<summary>Установка плагина Lightroom командой <code>install-plugin</code> и удаление</summary>

`node server/dist/index.js install-plugin` (или `npx -y lightroom-agent@<version> install-plugin`) копирует плагин Lightroom этого сервера поверх уже установленной копии в папке Modules или Plugins Lightroom, а если её нет — в папку Modules. Команда заменяет установленную копию, если её Lua-файлы отличаются от файлов этой сборки, — неважно, старше эта копия или новее. Если при этом версия понижается, команда сообщает об этом. Если файлы совпадают, команда оставляет копию на месте. Команда отказывается работать, пока плагином Lightroom владеет запущенный сервер lightroom-agent на тех же портах, поэтому сначала закройте клиенты; о нестандартных портах см. [docs/reference.md](docs/reference.md#configuration). Если установлен `LightroomMCP.lrplugin`, команда тоже отказывается работать, поскольку оба плагина используют одни и те же порты: закройте Lightroom и сначала удалите эту папку. Ещё команда записывает два пресета Develop, в которых есть только профиль, `lightroom-agent Adobe Color.xmp` и `lightroom-agent Adobe Landscape.xmp`, в папку настроек Camera Raw (`~/Library/Application Support/Adobe/CameraRaw/Settings` на macOS, `%APPDATA%\Adobe\CameraRaw\Settings` на Windows), в группу «lightroom-agent profiles»; Lightroom регистрирует их при запуске, а применяет их `set_profile`. Их видит и Camera Raw. Каждая установка и каждый запуск сервера, который держит соединение с Lightroom, перезаписывают изменённую или удалённую копию, записанную ими же, а файл с тем же именем, записанный не ими, не трогают (тогда `set_profile` этот профиль не ставит).

Для удаления уберите плагин для агента или запись сервера, затем удалите установленную папку `LightroomAgent.lrplugin` (её расположение показывает Диспетчер плагинов), два пресета `lightroom-agent` в папке настроек Camera Raw и `~/.config/lightroom-agent`.

</details>

<a id="the-bundled-skill"></a>

## Скилл в комплекте

[`skills/lightroom-agent`](skills/lightroom-agent/SKILL.md) учит агента работать с этими инструментами на фотографиях. Отбор идёт в два прохода (сначала технический, затем редакторский), на каждую ситуацию освещения сначала обрабатывается один репрезентативный кадр и только потом обработка копируется на остальные, края масок осматриваются, а каждый экспортированный файл проверяется.

Его загружают плагины для агентов Claude Code и Codex, а сервер предлагает его любому клиенту как промпт MCP `lightroom-agent`. Для ручной установки скопируйте папку или создайте на неё символическую ссылку в `~/.claude/skills/` для Claude Code или в `~/.codex/skills/` для Codex; `agents/openai.yaml` содержит метаданные для Codex. Скилл описывает инструменты того сервера, с которым поставляется, поэтому заменяйте скопированную папку при каждом обновлении сервера.

## Настройка и справочник

При запуске сервер читает `LIGHTROOM_AGENT_TOOLSETS`, `LIGHTROOM_AGENT_READ_ONLY`, две переменные портов и `LIGHTROOM_AGENT_TOKEN_PATH`. В [docs/reference.md](docs/reference.md) они перечислены со значениями по умолчанию; там же описаны наборы инструментов, режим только для чтения, командная строка и сертификация масок.

## Безопасность

При запуске сервер плагина Lightroom записывает случайный токен в `~/.config/lightroom-agent/token`. Сервер MCP отправляет его с каждым запросом, а плагин Lightroom слушает только localhost, поэтому остаётся риск со стороны другого пользователя или процесса на той же машине. Песочница плагинов Lightroom не умеет задавать права доступа к файлам; на общей машине выполните `chmod 700 ~/.config/lightroom-agent`. Как сообщить об уязвимости, описано в [SECURITY.md](SECURITY.md).

<a id="troubleshooting"></a>

## Устранение неполадок

Сервер пишет диагностику в stderr, который клиенты MCP сохраняют в журнале сервера. **Диспетчер плагинов → Show Status** показывает оба сокета, последнее событие, число обработанных запросов и путь к журналу плагина Lightroom (по умолчанию `~/Documents/LrClassicLogs/LightroomAgent.log`).

| Что вы видите | Причина и решение |
| --- | --- |
| Инструменты отвечают "Lightroom plugin not connected" | У сервера нет соединения с одним или обоими сокетами плагина Lightroom. Lightroom запускает плагины только после того, как его окно выйдет на передний план, поэтому у Lightroom, запущенного в фоне, их ещё нет: переключитесь на него или нажмите **Start Server**. Иначе пройдите проверки из раздела [Что-то не работает?](#something-not-working) |
| `ECONNREFUSED` в журнале сервера или `failed to open localhost:58763` в журнале плагина Lightroom после «Перезагрузить плагин» (Reload Plug-in) | Старая задача плагина Lightroom всё ещё держит порты. Закройте Lightroom и откройте снова. |
| "Lightroom Agent token file not found" | **Start Server** ещё не запускался, или `LIGHTROOM_AGENT_TOKEN_PATH` указывает туда, куда плагин Lightroom никогда не пишет. |
| "The Lightroom Agent token does not match the running plug-in" | Сервер перечитывает файл токена при каждом подключении, поэтому так бывает, когда `LIGHTROOM_AGENT_TOKEN_PATH` указывает на старую копию. Нажмите **Stop Server**, затем **Start Server** и проверьте переменную. |
| "Lightroom has loaded a different plug-in build" | Загруженный плагин Lightroom — не той сборки, что этот сервер; сообщение называет обе. Если нужная сборка была установлена или восстановлена, перезапустите Lightroom. Иначе закройте подключённые клиенты, выполните `install-plugin` этой сборки, проверьте результат, перезапустите Lightroom и подключитесь заново. Одна из возможных причин — другой клиент с другой сборкой: используйте одну сборку во всех клиентах. |
| "Lightroom's installed plug-in is version …, newer than this server's" | В этом клиенте lightroom-agent старее установленного плагина Lightroom, поэтому его сервер не трогает плагин и не подключается. Обновите lightroom-agent в этом клиенте или удалите устаревшую запись сервера, затем перезапустите клиент. |
| "Lightroom's installed plug-in is another build" | Версии сервера и установленного плагина Lightroom совпадают, но сборки различаются. Например, сервер собран из исходного кода, а плагин установлен из опубликованного пакета. Эта же ошибка возникает, если сборки различаются и сервер не может сравнить их версии. В сообщении указаны версия и сборка каждой стороны. Чтобы установить сборку сервера, закройте остальные клиенты, выполните `install-plugin` из сборки сервера, перезапустите Lightroom и только затем запустите клиенты. |
| "This server and the server that owns the Lightroom connection differ in …" | Два клиента запускают разные сборки lightroom-agent, и соединение держит тот, что запустился первым. Используйте одну сборку во всех клиентах, затем перезапустите их. |
| "This server's build does not match its plug-in folder" | Рабочую копию обновили через `git pull` или изменили без пересборки. Выполните `npm --prefix server run build` в рабочей копии, затем перезапустите клиент. |
| "This server's installation is damaged" | Установка через npm или Claude Desktop, в которой плагин Lightroom больше не соответствует серверу. Переустановите lightroom-agent, затем перезапустите клиент. |
| "This server has no bundled Lightroom plug-in" | Установка неполная. Переустановите lightroom-agent. |
| Вызов завершается по тайм-ауту | Lightroom не ответил вовремя. Запись могла уже примениться или ещё выполняться. Диалог в Lightroom (например, предложение обновить ИИ-модели во время экспорта) блокирует работу, пока его не закрыть. Проверьте **Last event** в Show Status и журнал плагина Lightroom, а перед повтором записи прочитайте настройки или файлы заново. |

## Разработка

Подготовка окружения, проверки и pull request описаны в [CONTRIBUTING.md](CONTRIBUTING.md). Запланированная работа — в [issues](https://github.com/fadedDexofan/lightroom-agent/issues), сгруппированных по [milestones](https://github.com/fadedDexofan/lightroom-agent/milestones). [GLOSSARY.md](GLOSSARY.md) определяет термины, которые используют код и документы, а [CLAUDE.md](CLAUDE.md) (он же `AGENTS.md`) содержит инструкции для агентов, пишущих код.

## Лицензия

MIT. lightroom-agent — это сервер MCP на TypeScript, который общается через локальные сокеты с плагином на Lua внутри Lightroom. Проект не связан с Adobe и не одобрен ею.
