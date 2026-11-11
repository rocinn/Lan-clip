# 跨设备自动同步（新内容提示条）修订计划

> **面向 AI 代理的工作者：** 必需子技能：使用 subagent-driven-development（推荐）或 executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 让局域网内其他设备发送的剪贴板内容，自动出现在当前页面的列表顶部，用户不必手动刷新，且插入过程不打断当前浏览位置。

**架构：** 后端新增轻量状态接口 `GET /api/cards/status`，只返回卡片 id / 数量 / 置顶签名，不返回正文，因此可以高频轮询；该接口的鉴权走 60 秒缓存，避免每 2 秒一次的轮询都跑一遍 scrypt。前端每 2 秒轮询一次状态，发现 `latest_id` 增长时用一次带 `size` 的 `/api/cards` 请求把新卡片插到列表顶部；插入不可用、或处于搜索态时，改为底部悬浮的「有新内容」提示条，由用户点击后整表刷新。

**技术栈：** Flask 2.x（Python 3）、原生 JavaScript（无构建步骤）、CSS 主题变量（`[data-theme="dark"]`）、`python3 -c` + `urllib` 做接口验证

**规格：** 本计划直接来源于工作区的未暂存变更（`git diff` + `git status --porcelain`），当前仓库没有独立的设计文档；下文的接口契约与行为约定即为本计划的规格来源。

---

## 全局约束

- 卡片落盘为 `cards/<数字 id>.txt`，id 自增（`save_card` 取当前最大 id + 1），**最大 id 即最新卡片**；id 不保证连续（删除卡片会留下空洞）。
- 可见性窗口：默认只展示 3 天内的卡片；携带管理员密码解锁后才展示全部（`get_filtered_cards`）。
- 状态接口**不得返回任何卡片正文**；未解锁时，响应中不得出现受保护卡片的存在痕迹或数量。
- 置顶卡片在服务端排序中永远排在最前，因此「取最新 N 条」必须多取置顶条数，否则真正的新卡片会被挤出窗口。
- 静态资源缓存：`templates/index.html` 用 `?v=` 查询串控制 `static/main.js` 与 `static/style.css` 的缓存；**改动这两个文件必须同步递增版本号**，否则浏览器继续用旧缓存。
- 仓库没有自动化测试框架；验证手段固定为 `python3 -m py_compile`、`node --check`、`bash -n` 与启动服务后的 `python3 -c` + `urllib` 请求（本机没有 `curl`）。
- 任何 `git add` / `git commit` / `git push` 必须由用户显式发起（全局 Git 红线），本计划只列出待提交清单，不代替用户执行。

## 审查重点（Review Focus）

1. **未解锁时轮询是否泄露受保护卡片。** 未输入管理员密码的访客，状态接口的 `total` / `visible` 只能反映 3 天内的卡片，正文一律不返回——否则局域网内任何人都能靠轮询探测出旧内容的存在。
2. **手动刷新后是否误报「新内容」。** 用户点刷新按钮后本地基线应与 DOM 重新对齐；否则下一轮轮询会把已看过的卡片当成新卡片，反复弹提示条。
3. **卡片被删除导致 id 不连续时，新卡片条数会算多。** `latest_id - knownLatest_id` 把删除掉的 id 也算进增量；插入时必须按 id 去重，宁可多取几条也不能漏掉真正的新卡片。
4. **搜索 / 类型筛选状态下插入新卡片是否破坏当前结果。** 搜索中不应把卡片插进结果列表，应改为提示条；类型筛选开启时新插入的卡片同样要遵循筛选条件，否则会漏显示。
5. **轮询失败 / 服务不可用时的表现。** 网络抖动、页面休眠、后台标签页降频都不应弹出错误或打断操作：静默忽略，等下一个周期或切回前台再检查。

---

## 文件结构

| 文件 | 职责（本次修订） |
| --- | --- |
| `app.py` | 新增鉴权缓存 `is_authenticated_cached()` 与轻量状态接口 `/api/cards/status` |
| `static/main.js` | 新增自动同步模块（轮询、状态判定、插入新卡片、提示条）；`loadMoreCards` 增加按 id 去重 |
| `static/style.css` | 提示条样式（含暗色主题）与新卡片高亮动画 |
| `templates/index.html` | 新增提示条按钮；递增 `style.css` / `main.js` 的 `?v=` 版本号 |
| `.gitignore` | 忽略本机部署产生的 `run/`、`logs/` 目录 |
| `start.sh` / `stop.sh` | 未跟踪的本机 Linux 部署脚本（守护进程 + systemd 用户级自启），配套上面的忽略规则 |

---

## 接口契约

`GET /api/cards/status?show_old=<true|false>`，请求头可选携带 `X-Admin-Password`（与 `/api/cards` 相同的鉴权方式）。

```json
{
  "latest_id": 128,          // 当前可见范围内最大的卡片 id
  "latest_ts": 1762830000.0, // 该卡片的 mtime（秒）
  "total": 42,               // 可见卡片总数（未解锁时等于 visible）
  "visible": 42,             // 3 天窗口内的卡片数
  "pinned_count": 3,         // 可见且置顶的卡片数，前端据此多取几条
  "pinned_sig": "12,45,77"   // 置顶 id 集合签名；未解锁时固定为 ""
}
```

前端判定规则（`handleCardStatus`）：

- `latest_id > knownLatestId` → 有新卡片；`knownLatestId` 取插入前基线，插入目标为 `id > sinceId` 的卡片。
- 首次拿到状态只建立基线，不弹提示（首屏内容由服务端渲染，已包含全部可见卡片）。
- `total` 或 `pinned_sig` 变化 → 列表结构变了（卡片被删、被置顶、导入覆盖），弹「内容有更新」提示条。

---

## 任务 1：后端鉴权缓存与轻量状态接口

**文件：**
- 修改：`app.py:61-83`（新增 `_auth_cache` / `AUTH_CACHE_TTL` / `is_authenticated_cached()`）
- 修改：`app.py:517-575`（新增 `/api/cards/status` 路由）

- [ ] **步骤 1：确认鉴权缓存按密码缓存、TTL 为 60 秒**

  `is_authenticated_cached(ttl=AUTH_CACHE_TTL)` 的取值顺序必须与 `is_authenticated()` 一致：`X-Admin-Password` 请求头 → JSON body 的 `password` → `admin_password` cookie；缓存键是密码本身，命中且未超 TTL 时直接返回上次结果，超时后重算并写回 `_auth_cache`。

- [ ] **步骤 2：确认状态接口只返回元信息**

  遍历 `cards/*.txt`，以文件名的数字部分作为 id、`os.path.getmtime` 作为时间戳；非数字文件名跳过，`getmtime` 抛 `OSError` 也跳过。响应字段严格为 `latest_id` / `latest_ts` / `total` / `visible` / `pinned_count` / `pinned_sig`，**不得包含 `content`**。

- [ ] **步骤 3：确认未解锁时的可见性口径**

  `show_old=true` 且通过 `is_authenticated_cached()` 才算 `unlocked`。未解锁时：超过 3 天的卡片既不计入 `pinned_count`，也不参与 `latest_id` 计算；`total` 收窄为 `visible`；`pinned_sig` 返回空串（前端据此判断「置顶变化」不会对未解锁用户误报）。

- [ ] **步骤 4：静态检查**

  运行：`python3 -m py_compile app.py`
  预期：无输出、退出码 0。

---

## 任务 2：前端自动同步与新内容提示条

**文件：**
- 修改：`static/main.js:3360-3565`（新增自动同步模块）
- 修改：`templates/index.html:567-570`（新增提示条按钮）
- 修改：`static/style.css:2173-2248`（提示条样式 + 新卡片高亮动画）

- [ ] **步骤 1：确认轮询入口与基线**

  `startAutoSync()` 在 `window.onload` 末尾调用（`static/main.js:341`）：先 `syncKnownStateFromDom()` 从首屏 DOM 取最大 `data-id` 作为 `knownLatestId`，再 `setInterval(pollCardStatus, AUTO_SYNC_INTERVAL)`，`AUTO_SYNC_INTERVAL = 2000`；同时注册 `visibilitychange` 监听，页面回到前台时立刻检查一次。

- [ ] **步骤 2：确认轮询的三道闸门**

  `pollCardStatus()` 在 `autoSyncBusy` 为真、`document.hidden` 为真、或请求失败时直接返回 / 静默忽略；请求用 `cache: 'no-store'` 并带上 `getAuthHeaders()`；`show_old` 跟随 `oldContentLoaded`。

- [ ] **步骤 3：确认状态判定三分支**

  `handleCardStatus()`：有新卡片 → 搜索态直接弹提示条、否则走 `insertNewCards()`；首次检查 → 只建基线；`total` / `pinned_sig` 变化 → 弹「内容有更新」提示条。`knownLatestId` 在每次判定后都要前移，避免重复处理同一批卡片。

- [ ] **步骤 4：确认插入逻辑**

  `insertNewCards()` 拉 `/api/cards?page=1&size=need&show_old=...`，其中 `need = min(count + pinnedCount + 1, 200)`（多取置顶条数，因为置顶排在最前）；只保留 `id > sinceId` 且 DOM 中不存在的卡片，按 id 倒序；插到列表首个 `.card-wrapper` 之前（无卡片时插到 `.grid-new-card` 占位符之后）。插入后：加 `card-fresh` 高亮类并在 2 秒后移除；按新卡片实际高度补偿 `window.scrollBy`，保持用户视口不位移；`currentTypeFilter !== 'all'` 时调用 `applyClientCardFilter(getActiveSearchQuery(), false)` 让新卡片遵循筛选。

- [ ] **步骤 5：确认提示条行为**

  `showNewContentPill(count)` 在 `count > 0` 时累加 `pendingUpdateCount` 并显示「有 N 条新内容」，`count === 0` 时显示「内容有更新」；`applyPendingUpdate()` 点击后先退出搜索态，否则调用 `window.refreshCards` 刷新，再滚回顶部并 `syncKnownStateFromDom()` 重置基线。

- [ ] **步骤 6：确认静态资源版本号已递增**

  `templates/index.html:14` 为 `style.css?v=19`，`templates/index.html:561` 为 `main.js?v=25`；两者都必须在服务端渲染页面上生效（刷新页面后 DevTools 能看到新版本号）。

- [ ] **步骤 7：静态检查**

  运行：`node --check static/main.js`
  预期：无输出、退出码 0。

---

## 任务 3：分页加载去重

**文件：**
- 修改：`static/main.js:668-675`（`loadMoreCards` 去重）

- [ ] **步骤 1：确认去重依据**

  追加分页内容前，先从 DOM 收集所有 `.card-wrapper[data-id]` 的 `data-id` 成 `Set`，再过滤掉 `data.cards` 中已存在的 id。新卡片插入到列表顶部会使服务端分页整体后移，不去重会出现重复卡片。

- [ ] **步骤 2：静态检查**

  运行：`node --check static/main.js`
  预期：无输出、退出码 0。

---

## 任务 4：仓库卫生与本机部署脚本

**文件：**
- 修改：`.gitignore:11-12`（新增 `run/`、`logs/`）
- 新增（未跟踪）：`start.sh`、`stop.sh`

- [ ] **步骤 1：确认忽略规则**

  `.gitignore` 末尾追加 `run/` 与 `logs/`，覆盖本机部署脚本产生的 PID 文件与日志目录；`git status --porcelain` 输出中不再出现 `run/`、`logs/`。

- [ ] **步骤 2：确认脚本可执行且与仓库约定一致**

  运行：`bash -n start.sh && bash -n stop.sh`
  预期：无输出、退出码 0。

  `start.sh` 支持 `start / status / restart / stop / enable / disable`，`stop.sh` 按「systemd 用户服务 → 自管守护进程 → 残留 `app.py` 进程」顺序停止；两者都通过 `LANCLIP_PORT`（默认 5000）与 `LANCLIP_PYTHON`（默认 `python3`）取配置，PID 与日志落在 `run/`、`logs/`。

---

## 任务 5：端到端验证

**文件：** 无（只做验证，不改代码）

- [ ] **步骤 1：启动服务**

  运行：`python3 app.py --port 5099`（另开终端；端口避开本机已在使用的 5000）
  预期：监听 5099 端口，控制台无异常堆栈。

- [ ] **步骤 2：验证状态接口的公开字段**

  运行：`python3 -c "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:5099/api/cards/status?show_old=false').read().decode())"`
  预期：返回 JSON，含 `latest_id` / `latest_ts` / `total` / `visible` / `pinned_count` / `pinned_sig`；**响应中不出现卡片正文**。

  （本机未安装 `curl`，统一用 `python3 -c` + `urllib` 发请求。）

- [ ] **步骤 3：验证未解锁不泄露旧内容**

  运行：`python3 -c "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:5099/api/cards/status?show_old=true').read().decode())"`（不带密码）
  预期：`total` 与 `visible` 相等，`pinned_sig` 为空串，不返回任何 3 天前卡片的计数。

- [ ] **步骤 4：验证插入链路**

  浏览器打开 `http://127.0.0.1:5099`，另开终端发送一条内容：`python3 -c "import json,urllib.request;req=urllib.request.Request('http://127.0.0.1:5099/api/add_card',data=json.dumps({'text':'自动同步验证'}).encode(),headers={'Content-Type':'application/json'});print(urllib.request.urlopen(req).read().decode())"`
  预期：2 秒内列表顶部出现该卡片并有一次高亮动画；页面滚动位置不跳动。

- [ ] **步骤 5：验证搜索态不被打断**

  在搜索框输入关键词后重复步骤 4。
  预期：列表结果不被插入，底部出现「有 1 条新内容」提示条；点击后退出搜索并刷新到顶部。

- [ ] **步骤 6：记录待提交清单（不执行）**

  运行：`git status --porcelain`
  预期待提交：`M .gitignore`、`M app.py`、`M static/main.js`、`M static/style.css`、`M templates/index.html`，以及未跟踪的 `start.sh`、`stop.sh`（是否纳入版本库由用户决定）。

  提交动作由用户显式发起后再执行，提交信息建议走 `/commit-msg` 技能，依据暂存区变更生成 Conventional Commits 中文信息。

---

## 自检记录

- **规格覆盖度**：本计划的规格来源是工作区未暂存 diff 的全部 5 个改动文件 + 2 个未跟踪脚本，均在任务 1-4 中有对应步骤；无遗漏。
- **步骤扫描**：每一步都能确定唯一的检查对象与判定结果，没有「待定 / 补充合适的验证」这类空行；接口契约已在「接口契约」一节写明，正文不复述实现代码。
- **类型一致性**：接口字段名（`latest_id` / `total` / `visible` / `pinned_count` / `pinned_sig`）与前端 `handleCardStatus()` / `insertNewCards()` 中的读取一致；`pinned_sig` 空串代表「未解锁」，与前端 `knownPinnedSig` 初值 `''` 语义一致。
- **审查重点覆盖**：5 条审查重点分别落在任务 2 步骤 2/3/4（可见性口径在任务 1 步骤 3）、任务 2 步骤 1/5（基线与提示条）、任务 2 步骤 4（去重与筛选）、任务 2 步骤 2（静默失败）。
- **比例**：正文约 150 行，与 diff 的 393 行新增相比属于说明与约束，不是代码抄本。

## 已执行的验证（2026-11-11）

以下命令已在当前工作区实跑，任务 5 的浏览器步骤（步骤 4 / 5）尚未人工验证：

| 命令 | 结果 |
| --- | --- |
| `python3 -m py_compile app.py` | 通过，退出码 0 |
| `node --check static/main.js` | 通过，退出码 0 |
| `bash -n start.sh && bash -n stop.sh` | 通过，退出码 0 |
| `python3 app.py --port 5099` | 启动正常，waitress 监听 5099 |
| `GET /api/cards/status?show_old=false` | `{"latest_id":12,"latest_ts":1794360373.67,"pinned_count":0,"pinned_sig":"","total":12,"visible":12}` —— 字段齐全且**无正文** |
| `GET /api/cards/status?show_old=true`（不带密码） | 与上面一致，`total == visible`、`pinned_sig` 为空串，未解锁不外泄旧卡片 |
| `git status --porcelain` | 5 个已修改文件 + 未跟踪的 `start.sh`、`stop.sh`（另有本文档目录 `docs/`） |
