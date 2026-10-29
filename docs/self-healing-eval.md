# RubyCog 自修复 eval 设计

## 1. 目标与非目标

目标：eval 抛错时，把可诊断的错误报告交还模型；模型先分诊，再按错因处置。属于 RubyCog 自身缺陷的，直接在仓库内改源码、跑测试、留审计，最后提示重启生效。属于用户代码的，模型改写后重跑。属于依赖或环境的，只报告，不擅改系统。

非目标：

- 不做无人监督的后台自动改码；改源码必须经用户审批（`--yolo` 除外）。
- 不修改第三方 gem 源码，只在 RubyCog 层做 workaround 并说明。
- 不修环境（装系统包、改 Ruby 版本、改全局配置）。
- 不做 git 提交、推送、发布。
- 不承诺热修立即生效；v1 以重启为准。

## 2. 现状与缺口

| 位置 | 现状 | 缺口 |
| --- | --- | --- |
| `lib/rubycog/eval_tool.rb` | 2026-10-29 已扩为 `rescue Exception`（`Interrupt` 重抛），`LoadError`/`SystemExit`/栈溢出等回传为文本；成功路径仍返回 `"类名: 消息"` | 仍无 backtrace、出错行与源码上下文 |
| `lib/rubycog/eval_tool.rb` | 2026-10-29 已给 eval 传入 `<cwd>/(eval)` 作为文件名与起始行 1 | `require_relative` 可用；用户帧显示绝对路径而非 `(eval)` |
| `lib/rubycog/agent.rb` | 2026-10-29 已扩为 `rescue Exception`（`Interrupt` 重抛） | 非 StandardError 不再跳过事件流、打穿工作线程 |
| `lib/rubycog/agent.rb:108-111` | `emit(:tool_result, result.content)` | **真实 RubyLLM 2.1.1 的 `after_tool_result` 回调收到的是工具原始返回值（String），`String#content` 不存在**。此处必然 `NoMethodError`，且异常发生在 `add_tool_result_message` 之前，工具结果不会写入对话，模型看不到 eval 输出。已于 2026-10-29 修复：回调改为 `result.respond_to?(:content) ? result.content : result.to_s`，测试替身也改为真实 String 形态 |
| `lib/rubycog/agent.rb:8-14` | 指令只说明"用 eval、别谎称执行" | 无错误分诊协议，无框架/用户代码边界 |
| `lib/rubycog/agent.rb:91` | 唯一工具是 `EvalTool` | 无只读源码、无受控编辑、无测试执行入口 |
| `lib/rubycog/tui.rb:155-167` | `converse` 循环只处理审批 | 无修复轮次、预算、审计展示；重启无会话恢复 |
| `lib/rubycog/tui.rb:195-196` | 工具结果显示原文 | 长 backtrace 挤满屏幕，无折叠与分类标识 |

## 3. 闭环总览

```
用户消息
  → 模型调用 eval（审批）
  → EvalTool 执行
      ├─ 成功：返回 inspect
      └─ 异常：ErrorReport 采集（类型 / 消息 / 栈 / 源码片段 / 来源分类证据）
  → 工具结果回填对话（模型可见）
  → 模型分诊（user_code / framework / dependency / environment）
      ├─ user_code   → 改写代码，重跑 eval（同轮，最多 3 次）
      ├─ framework   → read_source → 形成最小补丁 → 审批 diff → edit_source
      │                → ruby -c → run_tests → 失败回滚 → 成功提示重启
      ├─ dependency  → 报告根因 + 最小 workaround 建议（需审批才执行）
      └─ environment → 报告缺失项与修复命令，不自行执行
  → 每步写审计日志 .rubycog/repairs/
  → 达到预算上限：停止，输出诊断报告交还用户
```

关键设计：**错误已经自动回到模型**（RubyLLM 的工具结果回填）。本功能不是新增"回传"通道，而是提升回传信息的可诊断性，并给模型补上"判定为系统缺陷后如何修"的能力与护栏。

## 4. 错误报告 ErrorReport

新文件 `lib/rubycog/error_report.rb`，纯函数，无副作用，可单测。

### 4.1 采集规则

```ruby
# eval_tool.rb
def execute(code:)
  @binding.eval(code, '(eval)', 1).inspect
rescue Interrupt
  raise
rescue Exception => e   # rubocop:disable Lint/RescueException
  ErrorReport.new(e, code: code, root: Rubycog.root).to_s
end
```

- 文件名固定 `(eval)`、起始行 1，保证栈帧可读为 `(eval):3`。
- `Interrupt` 重抛，Ctrl-C 仍能中断。
- `SystemExit` 转为错误文本（eval 内 `exit` 不应杀掉 TUI），`SystemStackError`、`NoMemoryError`、`SignalException` 同样转文本。
- 只捕获异常不改变成功路径；成功仍返回 `inspect`。

### 4.2 分类证据（generate）

| 证据 | 判定提示 |
| --- | --- |
| 首帧为 `(eval):N` | 用户代码直接失败 |
| 栈中出现 `lib/rubycog/**` 帧 | 可能框架问题（需模型进一步证明） |
| 栈中出现 gem 路径帧（`gems/ruby_llm-*`、`gems/curses-*`） | 依赖问题候选 |
| `LoadError` / `Errno::ENOENT` / `Errno::EACCES` | 环境问题候选 |
| `SyntaxError` 且位置在 `(eval)` | 用户代码语法错误 |
| `NoMethodError` 且接收者为 RubyCog 内部对象 | 框架问题候选 |

证据只作提示，最终分类由模型给出并说明理由；审批人看 diff 兜底。

### 4.3 报告格式（回填给模型）

```text
[EVAL ERROR]
class: NoMethodError
message: undefined method 'content' for an instance of String
origin_hint: framework
frames:
  1. (eval):2 in '<main>'                                  [user]
  2. lib/rubycog/eval_tool.rb:29 in 'Rubycog::EvalTool#execute'   [framework]
  3. lib/rubycog/agent.rb:109 in 'block in configure_callbacks'    [framework]
frame_count: 3 (user 1, framework 2, dependency 0)
source: lib/rubycog/agent.rb:109
  107 |       @chat.after_tool_result do |result|
  108 |         # ...
  109 |         emit(:tool_result, result.content)
file_state: clean (git)
```

约束：

- 栈最多 12 帧，总文本上限 2000 字符（沿用 AgentOS 先例：先截前 100 帧再取头 12 帧，避免尾部噪音）。
- 框架帧不删，只标记；否则无法判断系统问题。
- `source` 取首个框架帧对应的文件行，附 ±2 行上下文；用户帧只给 `(eval):N`，不回显整段用户代码。
- `file_state` 标明该文件是否有未提交改动，供后续"是否允许覆盖"判断。
- 报告中不得出现环境变量值、凭据、token；只出现类名、消息、路径。

## 5. 分诊协议

### 5.1 四类与处置

| 分类 | 判据 | 处置 | 边界 |
| --- | --- | --- | --- |
| `user_code` | 首帧 `(eval)`；失败由本次代码逻辑、参数、未定义状态导致 | 改代码重跑，最多 3 次 | 不得改 RubyCog 源码 |
| `framework` | 栈中存在 `lib/rubycog/**` 帧，且该帧行为违反工具契约（如返回值类型、回调参数、错误格式、UI 渲染）；可写出最小复现 | 写失败测试 → 改源码 → 跑测试 → 提示重启 | 必须引用 `file:line` 证据 |
| `dependency` | 栈中出现 gem 帧；gem 版本不兼容或 API 变更 | 不改 gem，改为在 RubyCog 层适配；给出升级/降级建议 | 不写 `Gemfile.lock`，不改 vendor |
| `environment` | `LoadError`、权限、网络、磁盘、Ruby 版本 | 输出精确修复命令，等待用户执行 | 不自动执行系统命令 |

强制要求：**"在 eval 里失败"不是框架问题的证据**。模型必须给出框架帧的具体行为错误，例如"`after_tool_result` 在 RubyLLM 2.1.1 传 String，而 `agent.rb:109` 调 `result.content`"。仅凭栈里出现框架帧不足以改源码。

### 5.2 复现与验证（防误判）

v1 硬门禁：

1. 模型必须给出最小复现片段（纯 Ruby，不经用户代码的业务逻辑）。
2. 模型必须说明框架当前行为与期望行为的差异，并引用源码行。
3. 修改前先跑相关测试基线，确认基线绿（防止把既有失败当成本次引入）。
4. 修改后 `ruby -c` 全部改动文件 + 相关测试 + 全量 `rake test`。

v2 增强：强制先提交一个会失败的测试（失败测试先行），在临时 worktree 中验证"修前红、修后绿"，再落主仓库。

## 6. 自修执行层

执行层与重启闭环的完整说明见 [self-iteration.md](self-iteration.md)；本节保留分诊视角的契约。

### 6.1 工具集

保持"小工具、可审批"的风格，已实现三个工具（`lib/rubycog/tools/`）：

| 工具 | 参数 | 审批 | 状态 |
| --- | --- | --- | --- |
| `read_source` | `path`, `start_line?`, `end_line?` | 否 | 已实现：只读白名单，带行号；默认 200 行 / 20 KB |
| `edit_source` | `path`, `old_string`, `new_string`, `reason` | 是 | 已实现：唯一匹配替换；备份 + 原子写 + `ruby -c`；失败回滚；结果含 unified diff |
| `run_tests` | `paths`（逗号分隔，可选） | 是 | 已实现：`bundle exec ruby -Itest <paths>` 或全量 `bundle exec rake test`；超时 120s；输出截断 4000 字符 |

`edit_source` 不提供整文件覆盖，避免误删用户改动。新建文件时 `old_string: ""`，仅允许 `test/` 与 `docs/`。

定位阶段优先用 `search_docs` / `get_doc` / `get_source`（见 [source-docs.md](source-docs.md)），确认类、方法与注释后再决定是否改文件。

### 6.2 路径白名单

允许：

```
lib/**/*.rb
test/**/*.rb
bin/rubycog
README.md
Gemfile
rubycog.gemspec
docs/**/*.md
```

禁止（硬拒，返回错误给模型）：

```
.git/**
.rubycog/**
.env*
**/*.pem
**/*.key
**/credentials*
**/id_rsa*
Gemfile.lock
tmp/**
vendor/**
```

实现：

```ruby
ALLOWED = [%r{\Alib/.+\.rb\z}, %r{\Atest/.+\.rb\z}, ...].freeze
def resolve(path)
  full = File.expand_path(path, Rubycog.root)
  raise ArgumentError, 'path escapes rubycog root' unless full.start_with?("#{Rubycog.root}/")
  raise ArgumentError, 'path not allowed' unless ALLOWED.any? { |re| path.match?(re) }
  full
end
```

`Rubycog.root` 通过 `File.expand_path('..', __dir__)` 计算，并在启动时校验存在 `rubycog.gemspec`。gem 安装目录通常不可写：当前写入失败会把错误返回给模型；尚未实现“只读安装时输出补丁”的降级。

### 6.3 写入安全

- 读原始内容 → 计算 diff（`Diff::LCS` 或手写简单行 diff，避免新增依赖；v1 可用 `diff -u` 子进程）→ 审批 → 备份到 `.rubycog/backups/<UTC 时间戳>/<相对路径>` → 临时文件写入 → `File.rename` 原子替换。
- 写前检查 `git status --porcelain <path>`：若文件已有未提交改动，diff 中额外标注 `pre-existing changes`，由审批人决定；v1 不禁止，只警告。
- 写后强制 `ruby -c`；语法失败立即回滚。
- 测试失败回滚并返回测试输出，模型可再试一次。
- 每次写操作生成审计记录。

### 6.4 生效策略

| 版本 | 策略 |
| --- | --- |
| v1 | 已实现：`/restart` 保存会话（`Session` 文件）并 `exec` 重启，启动时恢复；TUI 检测 `lib/**/*.rb` 变化并在 footer 提示 `code changed — /restart to apply` |
| v2 | `/reload` 用 `load` 重载改动文件；仅对无实例状态的模块（`error_report`、`text`）安全；`Agent`/`TUI` 仍建议重启 |

设计取舍：不假装热修复成功。当前进程里的 `EvalTool` 实例、`Agent` 的 `chat` 工具注册表、`TUI` 的渲染逻辑都持有旧对象；`load` 只换方法，不换对象，容易出现"改完还是旧行为"的假象。v1 用重启换确定性。

## 7. 循环控制与预算

`lib/rubycog/self_repair.rb` 维护单轮状态：

- 错误指纹：`class + message + 首个框架帧位置`（无框架帧则用首帧）。同一指纹最多处理 3 次。
- 单轮最多修改 3 个文件、累计 80 行 diff。
- 单轮最多 1 次全量测试。
- 同一文件连续两次补丁后测试仍失败：停止，输出"已排除"清单。
- 连续两个不同指纹都指向同一文件同一区域：停止，提示可能是架构问题。
- 达到上限后返回结构化结论：`status: gave_up | fixed | needs_restart | needs_user`。

预算参数进 `SelfRepair::Limits`，便于测试注入。

## 8. 审计

` .rubycog/repairs/<UTC 时间戳>-<指纹短哈希>.json`：

```json
{
  "error": {"class": "NoMethodError", "message": "...", "top_frame": "lib/rubycog/agent.rb:109"},
  "classification": "framework",
  "evidence": ["RubyLLM 2.1.1 after_tool_result yields raw String"],
  "changes": [{"path": "lib/rubycog/agent.rb", "diff": "..."}],
  "checks": {"syntax": true, "tests": {"command": "bundle exec rake test", "passed": 40, "failed": 0}},
  "decision": "approved",
  "result": "fixed_needs_restart"
}
```

`.gitignore` 增加 `.rubycog/`。审计内容不含环境变量值、密钥、完整用户代码。

## 9. 安全护栏汇总

1. 改源码需审批；`--yolo` 免审批但仍备份、仍跑检查、仍写审计。
2. 路径白名单 + 根目录逃逸检查；禁 `.git`、密钥、`.env`、`Gemfile.lock`。
3. 不执行 git 写操作（`add`/`commit`/`reset`/`checkout`），只允许只读 `git status`。
4. 不改自修工具自身（`source_path.rb`、`source_edit.rb`、`self_iteration.rb`、`tools/edit_source.rb`）——已由 `SourcePath` 的写保护实现；确需修改时提示用户手动处理。
5. 测试失败、语法失败一律回滚，保留备份路径供排查。
6. 报告与审计不记录凭据；错误消息中若疑似含密钥（如 URL 带 token），以 `[REDACTED]` 替换。
7. 会话结束或 `Ctrl-C` 时不再发起新补丁；已批准的操作允许完成当前原子写。

## 10. 提示词协议（`Agent::INSTRUCTIONS` 增补）

```text
## Error triage
When a tool result starts with [EVAL ERROR]:
1. Classify before acting:
   - user_code: the top frame is (eval) and the failure follows from your own
     logic, arguments, or undefined state. Fix the snippet and retry. Never edit
     rubycog for this.
   - framework: a lib/rubycog frame behaves contrary to its contract. Quote the
     exact file:line and explain the contract violation. "It failed inside eval"
     is not evidence.
   - dependency: a gem frame fails or an API changed. Do not patch the gem. Adapt
     in rubycog only if the contract is still satisfied; otherwise report.
   - environment: missing file, binary, permission, disk, or Ruby version. Report
     the exact remedy and wait for the user.
2. For framework defects: read_source, then propose the smallest edit_source diff.
   Add or extend a test that fails before the fix when practical.
3. After editing: ruby -c every changed file, then run_tests. If anything fails,
   revert and report. Never leave the tree broken.
4. Report cause, classification, evidence, changed files, test output, and that a
   restart is required.
5. Stop after 3 attempts on one error fingerprint and report what you ruled out.
```

同时注入两条系统上下文（由 `Agent` 在构建 chat 时写入，不依赖模型猜）：

- `Rubycog.root`、版本、Ruby 版本、运行模式（源码 / gem）、可编辑路径清单。
- 当前 git 分支与脏文件列表（只读）。

## 11. 代码落点

| 文件 | 动作 |
| --- | --- |
| `lib/rubycog/error_report.rb` | 未实现：异常分类证据、栈裁剪、源码片段、脱敏、文本渲染 |
| `lib/rubycog/self_iteration.rb` | 已实现：审计、摘要、条数上限、0600 权限 |
| `lib/rubycog/source_path.rb` | 已实现：白名单、目录逃逸、符号链接、写保护 |
| `lib/rubycog/source_edit.rb` | 已实现：读取、diff、备份、原子写、`ruby -c`、回滚 |
| `lib/rubycog/tools/read_source.rb` | 已实现：只读源码 |
| `lib/rubycog/tools/edit_source.rb` | 已实现：原子编辑 + diff + 审计 |
| `lib/rubycog/tools/run_tests.rb` | 已实现：受限测试执行 + 审计 |
| `lib/rubycog/eval_tool.rb` | 已完成扩 rescue、eval 文件名与起始行；余下 ErrorReport 的分类证据与源码片段 |
| `lib/rubycog/agent.rb` | 已完成 `result.content` 兼容、扩 rescue、注册四工具、指令增补 |
| `lib/rubycog/tui.rb` | 已完成 `/restart`、`/self`、源码变更提示；错误分类标识未做 |
| `lib/rubycog.rb` | 已 require 新文件 |
| `test/source_edit_test.rb` 等 | 已新增路径/编辑/工具/审计测试 |
| `README.md` | 已补自修说明与权限边界 |
| `.gitignore` | 已加 `.rubycog/` |

## 12. 测试计划

单元：

- `ErrorReport`：RuntimeError / SyntaxError / SystemExit / 框架帧标记 / gem 帧标记 / 栈裁剪 / 2000 字符上限 / 密钥脱敏。
- `SelfRepair`：指纹稳定、3 次上限、文件数上限、回滚、路径逃逸拒绝、`Gemfile.lock` 拒绝。
- `edit_source`：唯一匹配、非唯一拒绝、写后备份存在、语法失败回滚。
- `EvalTool`：`1/0` 报告含 `(eval):1`；`def` 语法错误；`exit` 不退出进程；变量跨调用保留仍成立。

集成（FakeChat）：

- 模拟"工具结果 → 分类 framework → read_source → edit_source → run_tests → 重启提示"的事件序列。
- 模拟测试失败 → 回滚 → 模型收到失败输出。
- `--yolo` 下不弹审批但仍写审计。

手工验收（真实进程）：

1. 故意在 `eval_tool.rb` 注入 `String#content` 类缺陷（或直接用现有 `agent.rb:109` bug），让模型跑一次 eval。
2. 确认错误报告含框架帧；模型请求 `edit_source` 并展示 diff。
3. 批准后确认文件变更、测试通过、审计文件生成。
4. 重启后确认修复生效，原复现步骤不再报错。

## 13. 分期

- v1：ErrorReport + 分诊 prompt + `agent.rb:109` 修复 + `read_source`/`edit_source`/`run_tests` + diff 审批 + 备份/回滚 + 审计 + `/restart`。
- v2：失败测试先行自动验证（临时 worktree）、`/reload`、错误指纹统计与 `/repairs` 查看、UI 折叠与预算显示。
- v3：可选自动提交补丁到分支并生成 PR 描述（仍需人工推送）。

## 14. 风险与对策

| 风险 | 对策 |
| --- | --- |
| 误判用户代码为框架缺陷，乱改源码 | 强制引用 `file:line` 契约证据；审批 diff；测试门禁；v2 失败测试先行 |
| 修改后当前进程仍跑旧代码，造成"修了没用" | v1 明确提示重启；不宣称热生效 |
| 自修工具自身有 bug，导致失控 | 禁止修改 `self_repair.rb` 与编辑工具；所有写操作有备份与审计 |
| 无限重试烧 token | 指纹 + 3 次上限 + 文件/行数预算 + 单轮全量测试一次 |
| 覆盖用户未提交改动 | 写前 `git status` 检查并标注；备份；只做唯一匹配替换 |
| 错误报告泄露密钥 | 消息与片段脱敏，只保留路径、类名、行号 |
| gem 安装目录不可写 | 检测可写性，降级为"输出补丁 + 手动应用" |

## 15. 待确认

1. **"系统本身"的边界**：是否包含 `ruby_llm`/`curses` 等依赖？本文按"改 RubyCog 层 workaround，不改 gem"处理。
2. **自修授权**：改源码默认逐次审批，还是需要额外 `--allow-self-edit` 显式开启？本文按"默认开启分诊、改源码需审批"处理。
3. **生效方式**：已按"重启生效"实现（`/restart` 保存会话 + 进程重启 + 启动恢复）；未实现热重载。
