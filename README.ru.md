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

lightroom-agent — это сервер MCP и плагин Lightroom Classic. Claude Code, Codex или любой другой клиент MCP получает инструменты для каталога, модуля «Обработка» (Develop), масок и экспорта, а также скилл в комплекте, который учит агента отбирать и обрабатывать фотографии с их помощью. Это форк [Automaat/lightroom-mcp](https://github.com/Automaat/lightroom-mcp).

> Здесь «плагин Lightroom» — плагин, который работает внутри самого Lightroom Classic, а «плагин для агента» — расширение Claude Code или Codex, которое устанавливает lightroom-agent в агента.

## Что умеет агент

- **Отбор.** Поиск по рейтингу, дате, камере, объективу, ключевому слову или папке, сравнение кадров по превью и оценка резкости на фрагментах 1:1 из рендера в полном разрешении, а не по уменьшенному превью.
- **Обработка.** Ползунки обработки задаются по их именам в Lightroom SDK; диапазоны проверяются до записи, а значения считываются обратно после того, как Lightroom их нормализует. Обрезка и выпрямление (Crop, Straighten) в том кадре, который видит агент, применение стилей (Presets), перенос обработки одной фотографии на другие и возможность вернуться к предыдущей обработке через снимки (панель «Снимки экрана», Snapshots) и именованные виртуальные копии (Virtual Copies).
- **Маски.** Маски «Предмет» (Subject), «Небо» (Sky), «Фон» (Background), «Люди» (People) и «Пейзаж» (Landscape); линейные градиенты (Linear Gradient) и радиальные градиенты (Radial Gradient), кисти (Brush), цветовые диапазоны (Color Range), диапазоны яркости (Luminance Range) и диапазоны глубины (Depth Range; только для фотографий с данными глубины); ползунки, кривые (Curve) и «Точечный цвет» (Point Color) для каждой маски. Если Lightroom не находит небо или предмет, вызов удаляет пустую маску и сообщает об этом. Для построения масок нужна [сертификация](docs/reference.md#mask-construction-and-certification) вашей сборки Lightroom, которую повторяют после каждого обновления Lightroom; правка ползунков, кривых и «Точечного цвета» работает и без неё.
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
| Правка масок | Ползунки, кривые и удаление действуют на маску, выбранную в модуле «Обработка», а её может сменить щелчок прямо во время вызова | По id маски в сохранённых настройках фотографии, с обратным чтением после записи (`invert_mask` по-прежнему работает через модуль «Обработка») |
| Построение масок на новой сборке Lightroom | Разрешено для списка версий, заданного в исходном коде | Разрешено, когда тесты на живом Lightroom прошли на этой машине для этой сборки |
| Руководство для агента | Процесс построения стилей: отбор, правки с замкнутым циклом, стили по кластерам освещения, запасной путь через XMP | Скилл для отбора, обработки, маскирования и экспорта этими инструментами, с технической и редакторской проверкой |

Решения, стоящие за первыми тремя строками, описаны в [docs/adr](docs/adr/). [Набор тестов на живом Lightroom](tests/e2e/live/README.md) создаёт одноразовый каталог из фиксированных изображений и проверяет инструменты по рендерам Lightroom.

## Когда не стоит его использовать

- **Lightroom (облачное приложение) или Lightroom Classic ниже 15.0.** Плагин Lightroom запускается только в Lightroom Classic 15.0 и новее.
- **Windows, если нужна проверенная работа.** Сервер собирается и проходит CI на Windows, но с Lightroom там его никто не запускал.
- **Построение масок без Mac.** Сертификация запускает тесты на живом Lightroom, а им нужна macOS.
- **Каталог, который нельзя трогать.** Инструменты пишут в открытый каталог. Начните с `LIGHTROOM_AGENT_READ_ONLY=true` или пусть агент работает со снимками и виртуальными копиями — скилл в комплекте так и делает по умолчанию.

<a id="installation"></a>

## Установка

Нужны Lightroom Classic 15.0 или новее на macOS (живая проверка — на 15.6 и 16.0; 15.0–15.5 и Windows не тестировались) и Node.js 20 или новее. Установите lightroom-agent в каждый агент, которым пользуетесь; любой путь заканчивается одним и тем же [шагом в Lightroom](#finish-in-lightroom).

### Claude Code

```text
/plugin marketplace add fadedDexofan/lightroom-agent
/plugin install lightroom-agent@lightroom-agent
```

Плагин включает сервер со всеми наборами инструментов и [скилл](#the-bundled-skill) в комплекте. Для обновления выполните `claude plugin marketplace update lightroom-agent`, затем `claude plugin update lightroom-agent@lightroom-agent`; для удаления — `claude plugin uninstall lightroom-agent@lightroom-agent`.

<details>
<summary><b>Codex</b></summary>

```sh
codex plugin marketplace add fadedDexofan/lightroom-agent
codex plugin add lightroom-agent@lightroom-agent
```

Плагин включает сервер и скилл, как в Claude Code. В `codex exec` Codex пока не предлагает модели инструменты плагина. Для обновления выполните `codex plugin marketplace upgrade lightroom-agent` и добавьте плагин заново; для удаления — `codex plugin remove lightroom-agent@lightroom-agent`.

</details>

<details>
<summary><b>Claude Desktop</b></summary>

Скачайте `lightroom-agent-<version>.mcpb` из [последнего релиза](https://github.com/fadedDexofan/lightroom-agent/releases) и откройте его; Claude Desktop установит его как расширение. В настройках расширения задаются наборы инструментов и режим только для чтения. Для обновления откройте `.mcpb` более нового релиза; для удаления удалите расширение в настройках Claude Desktop.

</details>

<details>
<summary><b>Любой другой клиент MCP</b></summary>

Запускайте npm-пакет через stdio, закрепив версию [последнего релиза](https://github.com/fadedDexofan/lightroom-agent/releases):

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
<summary><b>Из исходного кода</b></summary>

```sh
git clone https://github.com/fadedDexofan/lightroom-agent.git
cd lightroom-agent
npm --prefix server ci
npm --prefix server run build

# Claude Code
claude mcp add lightroom -e LIGHTROOM_AGENT_TOOLSETS=all -- node "$PWD/server/dist/index.js"
# Codex
codex mcp add lightroom --env LIGHTROOM_AGENT_TOOLSETS=all -- node "$PWD/server/dist/index.js"
```

Для обновления выполните `git pull` и пересоберите. Работа с кодом описана в [CONTRIBUTING.md](CONTRIBUTING.md).

</details>

<a id="finish-in-lightroom"></a>

### Завершение в Lightroom

Сервер, который держит соединение с Lightroom, при запуске устанавливает плагин Lightroom. Затем закройте и снова откройте Lightroom Classic и выведите его окно на передний план: плагин Lightroom запустит свой сервер. Если в **Файл → Диспетчер плагинов** (File → Plug-in Manager) Lightroom Agent показан остановленным, нажмите **Start Server**.

Попросите агента: *Покажи мои коллекции Lightroom.* Он ответит списком ваших коллекций по названиям.

После любого обновления сначала перезапустите все клиенты, затем Lightroom: пока Lightroom не загрузит новый плагин, каждый сервер отклоняет вызовы инструментов и называет обе сборки.

<details>
<summary>Ручная установка плагина Lightroom и удаление</summary>

`node server/dist/index.js install-plugin` (или `npx -y lightroom-agent@<version> install-plugin`) копирует плагин Lightroom поверх уже установленной копии в папке Modules или Plugins Lightroom, а если её нет — в папку Modules (`~/Library/Application Support/Adobe/Lightroom/Modules/` на macOS, `%APPDATA%\Adobe\Lightroom\Modules\` на Windows). Установленную копию, файлы которой отличаются от его сборки, команда заменяет, а идентичную не трогает. Команда отказывается работать, пока плагином Lightroom владеет запущенный сервер lightroom-agent на тех же портах, поэтому сначала закройте клиенты; при нестандартных портах запускайте её с теми же переменными портов и закройте клиенты и на всех остальных портах, потому что каждая пара портов устанавливает плагин в одну и ту же папку. Если установлен `LightroomMCP.lrplugin`, команда тоже отказывается работать, поскольку оба плагина используют одни и те же порты: закройте Lightroom и сначала удалите эту папку.

Для удаления уберите плагин для агента или запись сервера, затем удалите установленную папку `LightroomAgent.lrplugin` (её расположение показывает Диспетчер плагинов) и `~/.config/lightroom-agent`.

</details>

<a id="the-bundled-skill"></a>

## Скилл в комплекте

[`skills/lightroom-agent`](skills/lightroom-agent/SKILL.md) учит агента работать с этими инструментами на фотографиях. Отбор идёт в два прохода (сначала технический, затем редакторский), на каждую ситуацию освещения сначала обрабатывается один репрезентативный кадр и только потом обработка копируется на остальные, края масок осматриваются, а каждый экспортированный файл проверяется.

Его загружают плагины для агентов Claude Code и Codex, а сервер предлагает его любому клиенту как промпт MCP `lightroom-agent`. Для ручной установки скопируйте папку или создайте на неё символическую ссылку в `~/.claude/skills/` для Claude Code или в `~/.codex/skills/` для Codex; `agents/openai.yaml` содержит метаданные для Codex. Скилл описывает инструменты того сервера, с которым поставляется, поэтому заменяйте скопированную папку при каждом обновлении сервера.

## Настройка и справочник

При запуске сервер читает `LIGHTROOM_AGENT_TOOLSETS`, `LIGHTROOM_AGENT_READ_ONLY`, две переменные портов и `LIGHTROOM_AGENT_TOKEN_PATH`. В [docs/reference.md](docs/reference.md) они перечислены со значениями по умолчанию; там же описаны наборы инструментов, режим только для чтения, командная строка и сертификация масок.

## Безопасность

При запуске сервер плагина Lightroom записывает случайный токен в `~/.config/lightroom-agent/token`. Сервер MCP отправляет его с каждым запросом, а плагин Lightroom слушает только localhost, поэтому остаётся риск со стороны другого пользователя или процесса на той же машине. Песочница плагинов Lightroom не умеет задавать права доступа к файлам; на общей машине выполните `chmod 700 ~/.config/lightroom-agent`. Как сообщить об уязвимости, описано в [SECURITY.md](SECURITY.md).

## Устранение неполадок

Сервер пишет диагностику в stderr, который клиенты MCP сохраняют в журнале сервера. **Диспетчер плагинов → Show Status** показывает оба сокета, последнее событие, число обработанных запросов и путь к журналу плагина Lightroom (по умолчанию `~/Documents/LrClassicLogs/LightroomAgent.log`).

| Что вы видите | Причина и решение |
| --- | --- |
| Инструменты отвечают "Lightroom plugin not connected" | Сервер плагина Lightroom не запущен. Lightroom запускает плагины только после того, как его окно выйдет на передний план, поэтому у Lightroom, запущенного в фоне, их ещё нет: переключитесь на него или нажмите **Start Server**. |
| `ECONNREFUSED` в журнале сервера или `failed to open localhost:58763` в журнале плагина Lightroom после «Перезагрузить плагин» (Reload Plug-in) | Старая задача плагина Lightroom всё ещё держит порты. Закройте Lightroom и откройте снова. |
| "Lightroom Agent token file not found" | **Start Server** ещё не запускался, или `LIGHTROOM_AGENT_TOKEN_PATH` указывает туда, куда плагин Lightroom никогда не пишет. |
| "The Lightroom Agent token does not match the running plug-in" | Сервер перечитывает файл токена при каждом подключении, поэтому так бывает, когда `LIGHTROOM_AGENT_TOKEN_PATH` указывает на старую копию. Нажмите **Stop Server**, затем **Start Server** и проверьте переменную. |
| "Lightroom has loaded a different plug-in build" | Загруженный плагин Lightroom — не той сборки, что этот сервер; сообщение называет обе. Если нужная сборка была установлена или восстановлена, перезапустите Lightroom. Иначе закройте подключённые клиенты, выполните `install-plugin` этой сборки, проверьте результат, перезапустите Lightroom и подключитесь заново. Одна из возможных причин — другой клиент с другой сборкой: используйте одну сборку во всех клиентах. |
| "This server and the server that owns the Lightroom connection differ in …" | Два клиента запускают разные сборки lightroom-agent, и соединение держит тот, что запустился первым. Используйте одну сборку во всех клиентах, затем перезапустите их. |
| "This server's build does not match its plug-in folder" | Рабочую копию обновили через `git pull` или изменили без пересборки. Выполните `npm --prefix server run build` в рабочей копии, затем перезапустите клиент. |
| "This server's installation is damaged" | Установка через npm или Claude Desktop, в которой плагин Lightroom больше не соответствует серверу. Переустановите lightroom-agent, затем перезапустите клиент. |
| "This server has no bundled Lightroom plug-in" | Установка неполная. Переустановите lightroom-agent. |
| Вызов завершается по тайм-ауту | Обработчик всё ещё выполняется в Lightroom. Проверьте **Last event** в Show Status и журнал плагина Lightroom; диалог в Lightroom (например, предложение обновить ИИ-модели во время экспорта) блокирует работу, пока его не закрыть. |

## Разработка

Подготовка окружения, проверки и pull request описаны в [CONTRIBUTING.md](CONTRIBUTING.md). Запланированная работа — в [issues](https://github.com/fadedDexofan/lightroom-agent/issues), сгруппированных по [milestones](https://github.com/fadedDexofan/lightroom-agent/milestones). [GLOSSARY.md](GLOSSARY.md) определяет термины, которые используют код и документы, а [CLAUDE.md](CLAUDE.md) (он же `AGENTS.md`) содержит инструкции для агентов, пишущих код.

## Лицензия

MIT, как и в исходном проекте. lightroom-agent сохраняет его архитектуру: сервер MCP на TypeScript общается через локальные сокеты с плагином на Lua внутри Lightroom. Проект не связан с Adobe и не одобрен ею.
