# Ourix's Quest Handbook

任务链手册 · A quest chain handbook for World of Warcraft **Forever** (`Interface: 16001`)

|           |                     |
| --------- | ------------------- |
| [中文](#中文) | [English](#english) |

---

## 中文

一个把任务链摊开来看的任务手册：左侧分类，右侧任务链，每条任务都带当前角色的状态。

- 客户端：World of Warcraft **Forever**（`Interface: 16001`）
- 依赖：**[QuestieDB](https://github.com/Questie/QuestieDB)**（硬依赖，缺少时不加载）

### 关于这个项目

**这是一个纯 AI 工程**，而不是一个严谨的软件工程作品。

### 维护状态

- 出于**我个人使用**的目的开发，不承诺长期维护，也不保证跟进客户端版本或 QuestieDB 的结构变更。
- **欢迎任何人继续开发、修改、分发、二次发布，不必向我索要任何许可。**
- **尽可能保留原作者署名**（`Ourix 或 洋芋`）与项目链接。这是礼貌请求，不是附加条款。

### 功能

- **任务链视图**：按地区 / 副本 / 职业 / 专业 / 特殊分类浏览，绘制任务链关系，前置关系一眼可见。
- **任务状态**：已完成、进行中、可交付、可接取、条件不足分色显示，状态直接读客户端，不存本地记录。
- **奖励物品图标**：任务行按数据列出该任务的奖励物品图标，悬停图标显示原生游戏物品提示。
- **详情提示**：悬停显示等级、接取地点、前置清单、是否为无限服新增内容。
- **NPC 伴随面板**：与 NPC 对话任务信息时，右侧同步显示该 NPC 的前序 / 当前 / 后续任务。
- 纯原生 `CreateFrame` 实现，除 QuestieDB 外不依赖任何库。

### 多语言

界面文案完整翻译 **9 种客户端语言**：

| 语言        | 代码     | 语言       | 代码     |
| --------- | ------ | -------- | ------ |
| 简体中文      | `zhCN` | 意大利语     | `itIT` |
| 繁体中文      | `zhTW` | 葡萄牙语（巴西） | `ptBR` |
| 德语        | `deDE` | 俄语       | `ruRU` |
| 法语        | `frFR` | 韩语       | `koKR` |
| 西班牙语（西班牙） | `esES` |          |        |

- `esMX` 自动复用 `esES`；`enUS` / `enGB` 直接显示英文原文。
- 任务名与任务正文不写入插件，始终由客户端提供（拿不到时回退 QuestieDB 的本地化名），因此**换语言后任务文本会跟着客户端变**。

### 安装

1. **从 CurseForge 安装（推荐）**：[Ourix's Quest Handbook](https://www.curseforge.com/wow/addons/ourixs-quest-handbook) —— 用 CurseForge 客户端一键安装，或下载压缩包解压到 `Interface/AddOns/`。
2. **手动安装**：把 `OurixsQuestHandbook` 文件夹放进 `Interface/AddOns/`。
3. 确认 **[QuestieDB](https://github.com/Questie/QuestieDB)** 也已安装（本插件把它作为硬依赖）。
4. 游戏内 `/oqh` 打开主面板。

### 致谢

本插件的**全部任务数据**都来自 [QuestieDB](https://github.com/Questie/QuestieDB)。感谢 QuestieDB 的**每一位贡献者** —— 没有他们长期的整理与维护，这个插件不可能存在。

### 许可

**GNU General Public License v3.0**，全文见 [LICENSE](LICENSE)。

Copyright (C) 2026 Ourixs。`Core/AreaMap.lua` 的区域 / 副本地图映射由 [QuestieDB](https://github.com/Questie/QuestieDB) 的公开数据整理而成，QuestieDB 同样以 GPLv3 发布。

---

## English

A quest chain handbook: categories on the left, quest chains on the right, every quest shown with its current character state.

- Client: World of Warcraft **Forever** (`Interface: 16001`)
- Requires: **[QuestieDB](https://github.com/Questie/QuestieDB)** (hard dependency — not loaded without it)

### About

**This is a pure AI project**, not a rigorous piece of software engineering.

### Maintenance

- Built for **my own use**; no long-term maintenance promise, and no guarantee of following client updates or QuestieDB schema changes.
- **Anyone is welcome to continue development, modify, redistribute or republish it — no permission needed from me.**
- **Keep the original author credit** (`Ourix` or `洋芋`) and a link back to this project where possible. That is a courtesy, not an extra license term.

### Features

- **Chain view** — browse by zone / dungeon / class / profession / special; quest chain relationships are drawn out, so prerequisites are visible at a glance.
- **Quest state** — completed, in progress, ready to hand in, available and locked are colour-coded; read live from the client (no local bookkeeping).
- **Reward icons** — each row lists the quest's reward items as game icons; hovering one shows the native item tooltip.
- **Rich tooltip** — level, accept location, prerequisite list, and whether the quest is Forever-only content.
- **NPC companion panel** — while an NPC's quest dialogue is open, its previous / current / next quests are shown alongside.
- Plain `CreateFrame` implementation; no library dependencies besides QuestieDB.

### Localization

The UI is fully translated into **9 client locales**:

| Locale | Code | Locale | Code |
| ------ | ---- | ------ | ---- |
| Simplified Chinese | `zhCN` | Italian | `itIT` |
| Traditional Chinese | `zhTW` | Portuguese (Brazil) | `ptBR` |
| German | `deDE` | Russian | `ruRU` |
| French | `frFR` | Korean | `koKR` |
| Spanish (Spain) | `esES` | | |

- `esMX` reuses `esES`; `enUS` / `enGB` show the English source strings.
- Quest names and quest text are never stored in the addon — they always come from the client (with a QuestieDB localized name as fallback), so **quest text follows whatever language the client is set to**.

### Install

1. **Install via CurseForge (recommended)** — [Ourix's Quest Handbook](https://www.curseforge.com/wow/addons/ourixs-quest-handbook): one click in the CurseForge app, or download the archive and extract it into `Interface/AddOns/`.
2. **Manual install** — drop the `OurixsQuestHandbook` folder into `Interface/AddOns/`.
3. Make sure **[QuestieDB](https://github.com/Questie/QuestieDB)** is installed as well (the addon treats it as a hard dependency).
4. Type `/oqh` in game to open the main window.

### Credits

**All quest data** in this addon comes from [QuestieDB](https://github.com/Questie/QuestieDB). Thanks to **every QuestieDB contributor** — this addon could not exist without their years of data work.

### License

**GNU General Public License v3.0** — see [LICENSE](LICENSE).

Copyright (C) 2026 Ourixs. `Core/AreaMap.lua` (zone / dungeon map mapping) is derived from [QuestieDB](https://github.com/Questie/QuestieDB)'s public data, which is released under the same license.
