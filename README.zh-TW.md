[English](README.md) | [Русский](README.ru.md) | 繁體中文

<h1 align="center">lightroom-agent</h1>

<p align="center">讓 AI 代理程式在 Adobe Lightroom Classic 中替你挑圖、編修相片、使用遮色片及轉存相片，並用 Lightroom 算出的影像檢查每一項變更。</p>

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
  <img src="docs/assets/demo-before.jpg" alt="未經編修的羅浮宮與塞納河" width="49%">
  <img src="docs/assets/demo-after.jpg" alt="同一張相片經代理程式編修後" width="49%">
</p>
<p align="center"><sub>左圖為以 CC0 釋出的 Sony 相機原始檔，保留拍攝原貌；右圖經代理程式整體調整，並以天空遮色片壓暗天空。</sub></p>

lightroom-agent 包含 MCP 伺服器與 Lightroom Classic 增效模組。Claude Code、Codex 或其他任何 MCP 用戶端都能使用管理編目、操作「編輯相片」模組、使用遮色片及轉存相片的工具。隨附的技能（skill）會指導代理程式用這些工具挑圖與編修。

> **適用於：** Claude Code、Codex CLI、Claude Desktop，以及任何透過 stdio 連線的 MCP 用戶端。<br>
> **需求：** macOS 版 Lightroom Classic 15.0 以上（Windows 尚未實測），以及 Node.js 20 以上。

<a id="quick-start"></a>

## 快速入門

1. 在 Claude Code 中安裝外掛：

   ```text
   /plugin marketplace add fadedDexofan/lightroom-agent
   /plugin install lightroom-agent@lightroom-agent
   ```

2. 結束 Claude Code 後重新啟動。它的 lightroom-agent 伺服器會隨工作階段啟動，並安裝 Lightroom 增效模組：這時會出現 `~/Library/Application Support/Adobe/Lightroom/Modules/LightroomAgent.lrplugin` 資料夾。
3. 如果 Lightroom Classic 正在執行，請先結束，再開啟它並將視窗切到前景。在 **檔案 → 增效模組管理員**（**File → Plug-in Manager**）中選取 **Lightroom Agent**：狀態會顯示 `Running: true`。如果顯示 `false`，請按一下 **Start Server**。
4. 問 Claude：*列出我的 Lightroom 集合。* 它會列出各個集合的名稱；如果編目中沒有集合，也會告訴你。

Codex、Claude Desktop 與其他用戶端的安裝方式請見[安裝](#installation)。

<a id="something-not-working"></a>

### 無法正常運作？

1. 將 Lightroom 的視窗切到前景一次：Lightroom 只在這時啟動增效模組。
2. 在 **增效模組管理員**（**Plug-in Manager**）中，按一下 Lightroom Agent 的 **Show Status**。如果 `Running` 為 `false`，請關閉對話方塊，再按一下 **Start Server**。代理程式的伺服器連上後，`Request socket connected` 與 `Response socket connected` 都會顯示 `true`。對話方塊顯示的是開啟當下的狀態，要查看最新狀態請重新開啟。如果任一行一直顯示 `false`，請確認用戶端已啟動它的 lightroom-agent 伺服器，且連接埠與增效模組管理員中的設定相同。
3. 在[疑難排解](#troubleshooting)中查詢代理程式的錯誤訊息。

## 代理程式能做什麼

- **挑圖。** 依評等、日期、相機、鏡頭、關鍵字或資料夾搜尋，在預覽圖上比較各張相片，並從全解析度算圖結果中裁出局部，以 1:1 原始像素檢查銳利度，不靠縮放過的預覽圖判斷。
- **編修。** 使用 Lightroom SDK 定義的滑桿名稱調整「編輯相片」設定。寫入前會檢查數值範圍，寫入後則等 Lightroom 將數值正規化，再讀回結果。代理程式可以依照看到的畫面裁切、校正傾斜，也可以套用預設集、比照一張相片的風格調整其他相片，並可建立快照、為虛擬副本命名，以保留先前的編修版本。
- **遮色片。** 主體（Subject）、天空（Sky）、背景（Background）、人物（People）與風景（Landscape）遮色片；線性漸層、放射狀漸層、筆刷，以及顏色範圍、明度範圍與景深範圍（只有景深範圍需要相片含有深度資訊）；各遮色片的滑桿、曲線與點顏色（Point Color）。如果 Lightroom 找不到天空或主體，該次呼叫會移除空的遮色片並說明。建立遮色片需要先在這台電腦上完成[認證](docs/reference.md#mask-construction-and-certification)，且認證須涵蓋你的 Lightroom 組建與該相片的處理版本（Process Version），每次更新 Lightroom 後都要重新執行；滑桿、曲線與點顏色的編修不需要認證。
- **整理。** 評等、旗標、顏色標籤、關鍵字、集合、中繼資料與 GPS，每張相片還可以另記私人評分與理由，兩者都不會寫入 IPTC 或 XMP。
- **轉存。** 轉存到資料夾，或透過轉存預設集轉存；回覆會列出寫入的檔案。

可以這樣要求：

- *幫我篩選昨天拍的鳥照。以 1080 px 寬檢視時，把不夠銳利的相片標為「排除」，並告訴我原因。*
- *先為目前的編修建立快照，再把 DSC_0412 調成寧靜、溫暖的風格。*
- *用天空遮色片壓暗所選相片的天空，並讓我看前後對照。*
- *幫我把這週評為五星的相片整理成 4:5 比例，方便我在 Instagram 動態消息中發文。*

## 與 lightroom-mcp 的差異

| | lightroom-mcp | lightroom-agent |
| --- | --- | --- |
| 呼叫結果 | 發生錯誤時只回傳一般錯誤訊息，無法區分寫入失敗和寫入結果不明 | 統一的回應格式：`done`、`partial`、`failed`、`unknown`，依實際寫入的內容判定；`failed` 表示沒有任何變更 |
| 遮色片編修 | 調整滑桿或曲線時會接收遮色片 ID，接著在「編輯相片」中選取該遮色片，再調整目前的選取；呼叫途中只要點選其他遮色片，就可能改變選取 | 依相片已儲存設定中的遮色片 ID 操作，寫入後再讀回結果（`invert_mask` 仍在「編輯相片」模組中執行） |
| 在新的 Lightroom 組建上建立遮色片 | 原始碼中列出的版本才允許 | 要等實機測試套件在這台電腦上針對該組建與相片的處理版本通過後才允許 |
| 代理程式使用指引 | 建立預設集的工作流程：挑圖、每次調整後檢視結果再繼續編修、依光線條件分組建立預設集，以及用 XMP 作為備用方案 | 指導代理程式運用這些工具挑圖、編修、使用遮色片與轉存的技能，挑圖時分別檢查技術品質與選片價值 |

前三列背後的決策記錄在 [docs/adr](docs/adr/)。[實機測試套件](tests/e2e/live/README.md) 會用一組固定的影像建立臨時測試用的編目，並對照 Lightroom 的算圖結果檢查各項工具。

## 不適合使用的情況

- **Lightroom（雲端應用程式）或 15.0 之前的 Lightroom Classic。** 只有 Lightroom Classic 15.0 以上能執行這個增效模組。
- **需要已在 Windows 版 Lightroom 實測過的工具。** 伺服器能在 Windows 上建置並通過 CI，但還沒有人在 Windows 上搭配 Lightroom 實際執行過這個伺服器。
- **需要建立遮色片，但手邊沒有 Mac。** 認證必須執行實機測試套件，這套測試需要 macOS。
- **必須保持不變的編目。** 這些工具會寫入目前開啟的編目，所以連線前請先在 Lightroom 中開啟這個編目的副本。`LIGHTROOM_AGENT_READ_ONLY=true` 會關閉寫入工具，適合單純瀏覽；但除了預覽之外，包括讀取在內的每次呼叫，都會提交你在「編輯相片」中尚未完成的滑桿調整。

<a id="installation"></a>

## 安裝

請在你使用的每個代理程式中各自安裝 lightroom-agent。無論採用哪種安裝方式，最後都要[在 Lightroom 中完成設定](#finish-in-lightroom)。

### Claude Code

請依照[快速入門](#quick-start)安裝。這個外掛包含伺服器和隨附的[技能](#the-bundled-skill)，並啟用所有工具集。更新時執行 `claude plugin marketplace update lightroom-agent`，再執行 `claude plugin update lightroom-agent@lightroom-agent`；解除安裝則執行 `claude plugin uninstall lightroom-agent@lightroom-agent`。安裝或更新後，請重新啟動 Claude Code。

<details>
<summary><b>Codex CLI</b></summary>

```sh
codex plugin marketplace add fadedDexofan/lightroom-agent
codex plugin add lightroom-agent@lightroom-agent
```

更新時執行 `codex plugin marketplace upgrade lightroom-agent`，開始新的工作階段，再重新啟動 Lightroom 一次；如果工作階段中沒有 Lightroom 工具，請移除外掛後重新加入。解除安裝則執行 `codex plugin remove lightroom-agent@lightroom-agent`。`codex exec` 不會等 MCP 伺服器就緒就開始第一輪，所以 Lightroom 工具可能在工作階段開始幾秒後才出現。在 Codex CLI 0.170.0 中，`approval_policy` 設為 `"never"` 時，`codex exec` 不會提供任何 MCP 工具。

如果外掛的工具沒有出現，請在 `~/.codex/config.toml` 中宣告伺服器，並把 `<version>` 換成你使用的版本（`codex plugin list` 會顯示）。這個項目會取代外掛的伺服器；更新時請讓它的版本與外掛保持一致。

```toml
[mcp_servers.lightroom]
command = "npx"
args = ["-y", "lightroom-agent@<version>"]
env = { LIGHTROOM_AGENT_TOOLSETS = "all" }
```

</details>

<details>
<summary><b>Claude Desktop</b></summary>

從[最新發行版本](https://github.com/fadedDexofan/lightroom-agent/releases)下載 `lightroom-agent-<version>.mcpb` 並開啟；Claude Desktop 會將它安裝為擴充功能。你可以在擴充功能的設定中選擇工具集，以及是否啟用唯讀模式。更新時開啟較新版本的 `.mcpb`；解除安裝則在 Claude Desktop 的設定中移除該擴充功能。

</details>

<details>
<summary><b>其他 MCP 用戶端</b></summary>

在用戶端的 MCP 設定中填入下方範例的指令、引數與環境變數。這個範例適用於接受 `mcpServers` 物件的用戶端。請把 `<version>` 換成[最新發行版](https://github.com/fadedDexofan/lightroom-agent/releases)的版本號。

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

`all` 會在預設的 `core` 工具集之外加入「編輯相片」與遮色片工具。請固定版本號：伺服器拒絕與其他組建的增效模組搭配運作，所以每個用戶端都應執行同一個組建。更新時，在每個用戶端中修改版本號。伺服器會以 MCP 提示詞 `lightroom-agent` 提供這項技能。

</details>

<details>
<summary><b>從發行版 zip 檔安裝增效模組</b></summary>

MCP 用戶端啟動伺服器時，伺服器會安裝 Lightroom 增效模組。命令列的 `call` 不會安裝，所以如果你只使用 `call`，請先安裝增效模組：

1. 結束 Lightroom Classic。
2. 從與伺服器版本相符的發行版下載 `LightroomAgent.lrplugin-<version>.zip` 並解壓縮。
3. 如果 Lightroom 的 Modules 或 Plugins 資料夾中已有 `LightroomAgent.lrplugin`，請改用 `npx -y lightroom-agent@<version> install-plugin` 就地更新（參閱[在 Lightroom 中完成設定](#finish-in-lightroom)）。否則將解壓縮後的資料夾移到 Modules 資料夾：macOS 上為 `~/Library/Application Support/Adobe/Lightroom/Modules/`，Windows 上為 `%APPDATA%\Adobe\Lightroom\Modules\`。如果 `Modules` 不存在，請建立它。如果已安裝 `LightroomMCP.lrplugin`，請刪除它，因為兩個增效模組使用相同的連接埠。
4. 開啟 Lightroom，依照[在 Lightroom 中完成設定](#finish-in-lightroom)的步驟 2 和 3 檢查狀態。接著用步驟 2 的版本號執行 `npx -y lightroom-agent@<version> call list_collections`。這個指令會以 JSON 輸出結果，呼叫成功時以結束代碼 0 結束。

同一個發行版的 zip 檔與 npm 套件含有相同的增效模組組建，所以該發行版的伺服器會接受這份副本，不會更動它。

</details>

<details>
<summary><b>從原始碼安裝</b></summary>

```sh
git clone https://github.com/fadedDexofan/lightroom-agent.git
cd lightroom-agent
npm --prefix server ci
npm --prefix server run build

# Claude Code，只在這個目錄中使用（加上 --scope user 可用於所有專案）
claude mcp add lightroom -e LIGHTROOM_AGENT_TOOLSETS=all -- node "$PWD/server/dist/index.js"
# Codex
codex mcp add lightroom --env LIGHTROOM_AGENT_TOOLSETS=all -- node "$PWD/server/dist/index.js"
```

更新時，先拉取最新的原始碼並執行 `npm --prefix server run build`，接著結束所有用戶端，執行 `node server/dist/index.js install-plugin`，重新啟動 Lightroom，再啟動用戶端。伺服器會自動將舊版增效模組更新到新版。如果從原始碼建置的增效模組與已安裝的增效模組版本號相同，但組建不同，就需要依照上述步驟執行 `install-plugin` 手動安裝。[CONTRIBUTING.md](CONTRIBUTING.md) 說明如何參與程式碼開發。

</details>

<a id="finish-in-lightroom"></a>

### 在 Lightroom 中完成設定

1. 啟動代理程式。它的 lightroom-agent 伺服器會安裝 Lightroom 增效模組、更新較舊的版本，或修復自己的組建。
2. 如果 Lightroom Classic 正在執行，請先結束，再開啟它並將視窗切到前景。Lightroom 只在這時啟動增效模組。
3. 在 **檔案 → 增效模組管理員**（**File → Plug-in Manager**）中選取 **Lightroom Agent**：狀態會顯示 `Running: true`。如果顯示 `false`，請按一下 **Start Server**。
4. 問代理程式：*列出我的 Lightroom 集合。* 它會列出各個集合的名稱；如果編目中沒有集合，也會告訴你。如果沒有得到這樣的回答，請參閱[無法正常運作？](#something-not-working)

任何更新之後，先重新啟動所有用戶端，再重新啟動 Lightroom，讓它載入已安裝的增效模組。在那之前，工具呼叫會失敗並顯示 "Lightroom has loaded a different plug-in build"。如果用戶端拒絕使用磁碟上已安裝的增效模組，請在[疑難排解](#troubleshooting)中查詢它的訊息。

<details>
<summary>用 <code>install-plugin</code> 安裝增效模組與解除安裝</summary>

`node server/dist/index.js install-plugin`（或 `npx -y lightroom-agent@<version> install-plugin`）會檢查 Lightroom 的 Modules 或 Plugins 資料夾。若其中已有這個增效模組，就把伺服器的增效模組安裝到原來的位置；若兩處都沒有，就安裝到 Modules 資料夾。如果已安裝的 Lua 檔案與這個組建的檔案不同，無論已安裝的版本較舊或較新，安裝指令都會覆寫原有的增效模組。若這次安裝會降版，指令會在結果中說明。檔案相同時會保留原檔。如果同一組連接埠上仍有 lightroom-agent 伺服器負責這個增效模組，安裝指令會拒絕安裝，因此請先結束用戶端；若使用自訂連接埠，請參閱 [docs/reference.md](docs/reference.md#configuration)。如果已安裝 `LightroomMCP.lrplugin`，安裝指令也會拒絕安裝，因為兩個增效模組使用相同的連接埠。請先結束 Lightroom，再刪除該增效模組的資料夾。

解除安裝時，先移除代理程式中的外掛或伺服器設定項目，再刪除已安裝的 `LightroomAgent.lrplugin` 資料夾（增效模組管理員會顯示它的位置）以及 `~/.config/lightroom-agent`。

</details>

<a id="the-bundled-skill"></a>

## 隨附的技能

[`skills/lightroom-agent`](skills/lightroom-agent/SKILL.md) 指導代理程式用這些工具處理相片。代理程式會分兩輪挑圖，先檢查技術品質，再判斷哪些相片值得入選。每種光線條件下先編修一張代表相片，再把編修設定複製到同組的其餘相片。代理程式也會檢查遮色片邊緣，並逐一檢查轉存的檔案。

Claude Code 與 Codex 外掛會載入它，伺服器也會以 MCP 提示詞 `lightroom-agent` 將它提供給任何用戶端。若要手動安裝，請將資料夾複製到以下位置，或在該處建立指向它的符號連結：`~/.claude/skills/`（Claude Code）或 `~/.codex/skills/`（Codex）；`agents/openai.yaml` 含有 Codex 的中繼資料。這項技能說明的是同一發行版本的伺服器工具。如果採用複製的方式安裝，每次更新伺服器時也要換掉先前複製的資料夾。

## 設定與參考資料

伺服器啟動時會讀取 `LIGHTROOM_AGENT_TOOLSETS`、`LIGHTROOM_AGENT_READ_ONLY`、兩個連接埠變數，以及 `LIGHTROOM_AGENT_TOKEN_PATH`。[docs/reference.md](docs/reference.md) 列出這些變數及其預設值，並說明工具集、唯讀模式、命令列與遮色片認證。

## 安全性

啟動增效模組的伺服器時，會將隨機產生的權杖寫入 `~/.config/lightroom-agent/token`。MCP 伺服器每次送出請求都會附上這個權杖，而增效模組只監聽 localhost，所以剩下的風險來自同一台電腦上的其他使用者或程序。Lightroom 的增效模組沙箱無法設定檔案權限；在共用的電腦上請執行 `chmod 700 ~/.config/lightroom-agent`。回報安全漏洞請參閱 [SECURITY.md](SECURITY.md)。

<a id="troubleshooting"></a>

## 疑難排解

伺服器將診斷訊息寫到 stderr，MCP 用戶端會把它保留在伺服器記錄中。**增效模組管理員（Plug-in Manager）→ Show Status** 會顯示兩個 socket、最後一個事件、已處理的請求數，以及增效模組記錄檔的路徑（預設為 `~/Documents/LrClassicLogs/LightroomAgent.log`）。

| 你看到的情況 | 原因與解決方式 |
| --- | --- |
| 工具回覆 "Lightroom plugin not connected" | 伺服器與增效模組的一個或兩個 socket 之間沒有連線。Lightroom 要等視窗切換到最前面後才會啟動增效模組，所以在背景啟動的 Lightroom 還沒有任何增效模組在執行：切換到 Lightroom，或按一下 **Start Server**。否則請依照[無法正常運作？](#something-not-working)中的步驟檢查。 |
| 伺服器記錄中出現 `ECONNREFUSED`，或按下「重新載入增效模組」（Reload Plug-in）後，增效模組記錄中出現 `failed to open localhost:58763` | 先前的增效模組工作尚未釋放連接埠。請結束 Lightroom 再重新開啟。 |
| "Lightroom Agent token file not found" | 尚未執行 **Start Server**，或 `LIGHTROOM_AGENT_TOKEN_PATH` 指向增效模組從不寫入的位置。 |
| "The Lightroom Agent token does not match the running plug-in" | 伺服器每次連線都會重新讀取權杖檔，當 `LIGHTROOM_AGENT_TOKEN_PATH` 指向舊的權杖檔時，就會出現這個錯誤。按一下 **Stop Server**，再按 **Start Server**，並檢查該變數。 |
| "Lightroom has loaded a different plug-in build" | Lightroom 載入的增效模組不是這個伺服器的組建；訊息中會列出兩者。如果預期的組建已經安裝或修復，請重新啟動 Lightroom。否則請結束已連線的用戶端，執行這個組建的 `install-plugin`，確認其結果，重新啟動 Lightroom 並重新連線。可能的原因之一是另一個用戶端執行著不同的組建：請在每個用戶端中使用同一個組建。 |
| "Lightroom's installed plug-in is version …, newer than this server's" | 這個用戶端的 lightroom-agent 比已安裝的增效模組舊，所以它的伺服器不會更動增效模組，也不會連線。請更新這個用戶端中的 lightroom-agent，或移除過時的伺服器設定項目，然後重新啟動用戶端。 |
| "Lightroom's installed plug-in is another build" | 已安裝的增效模組與伺服器版本相同，但組建不同。例如，伺服器是從原始碼建置的，而增效模組來自發行版。如果組建不同，而且伺服器無法比較兩者的版本，也會出現這個訊息。訊息中會列出雙方的版本和組建。若要使用伺服器的組建，請先結束其他用戶端，執行該伺服器隨附的 `install-plugin`，重新啟動 Lightroom，再啟動用戶端。 |
| "This server and the server that owns the Lightroom connection differ in …" | 兩個用戶端執行不同的 lightroom-agent 組建，而最先啟動的那個持有連線。請在每個用戶端中使用同一個組建，然後重新啟動它們。 |
| "This server's build does not match its plug-in folder" | 拉取或修改本機原始碼後，尚未重新建置。請在該工作目錄中執行 `npm --prefix server run build`，然後重新啟動你的用戶端。 |
| "This server's installation is damaged" | 透過 npm 或 Claude Desktop 安裝的版本中，增效模組已與伺服器不相符。請重新安裝 lightroom-agent，然後重新啟動你的用戶端。 |
| "This server has no bundled Lightroom plug-in" | 安裝不完整。請重新安裝 lightroom-agent。 |
| 呼叫逾時 | Lightroom 沒有及時回應。寫入可能已經套用，也可能仍在執行。若 Lightroom 出現對話方塊（例如轉存時的 AI 更新提示），就必須先關閉對話方塊，處理作業才會繼續。請查看 Show Status 中的 **Last event** 與增效模組的記錄檔；重試寫入前，請先重新讀取相關設定或檔案。 |

## 開發

[CONTRIBUTING.md](CONTRIBUTING.md) 說明開發環境設定、檢查與 pull request。規劃中的工作列在 [issues](https://github.com/fadedDexofan/lightroom-agent/issues) 中，依[里程碑](https://github.com/fadedDexofan/lightroom-agent/milestones)分組。[GLOSSARY.md](GLOSSARY.md) 定義程式碼與文件使用的術語，[CLAUDE.md](CLAUDE.md)（也以 `AGENTS.md` 提供）收錄給程式開發代理程式的指示。

## 授權

MIT。lightroom-agent 是一個 TypeScript MCP 伺服器，透過本機 socket 與 Lightroom 內的 Lua 增效模組溝通。本專案與 Adobe 並無組織上的關聯，也未獲 Adobe 背書。
