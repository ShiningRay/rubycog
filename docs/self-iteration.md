# RubyCog 自我迭代机制

自我迭代指 RubyCog 在运行中读取自己的源码、做最小编辑、跑测试、留下审计记录，再通过重启加载新代码并验证。它解决的是“模型能改自己的文件”之后的工程问题：改哪里、怎么改、怎么验、何时生效、失败怎么退。

本文描述当前已实现的机制。未实现的部分在第 11 节单列，避免把计划当成现状。

## 1. 设计原则

1. **不假装热重载**。运行中的 Ruby 进程持有旧类；文件改动不会自动生效。必须 `/restart` 或重新启动进程。
2. **只改本项目**。工具只允许 RubyCog 项目内的白名单文件；第三方 gem、`.git`、密钥、会话文件一律不碰。
3. **先读后写**。编辑前用 `read_source` 定位；编辑只做唯一匹配替换，不做整文件覆盖。
4. **每次写都可回退**。写前备份，写后 `ruby -c`；语法失败自动恢复。
5. **不验证不算完成**。修改后必须 `run_tests`；模型不得声称“已修复”而没有工具输出。
6. **审批是最后一道闸**。`edit_source` 与 `run_tests` 默认逐次审批；`--yolo` 只省交互，不省备份、检查与审计。

## 2. 组成

| 组件 | 位置 | 职责 |
| --- | --- | --- |
| `Agent` | `lib/rubycog/agent.rb` | 注册七个工具；推送 `tool_call` / `tool_result` 事件；会话持久化 |
| `EvalTool` | `lib/rubycog/eval_tool.rb` | 执行任意 Ruby；保留进程内定义；错误转为文本 |
| `ReadSourceTool` | `lib/rubycog/tools/read_source.rb` | 只读白名单源码，带行号与区间 |
| `SearchDocsTool` | `lib/rubycog/tools/search_docs.rb` | 按关键词检索源码文档注释 |
| `GetDocTool` | `lib/rubycog/tools/get_doc.rb` | 读类/方法文档注释，`ri` 兜底 |
| `GetSourceTool` | `lib/rubycog/tools/get_source.rb` | 读方法源码，索引 + 运行时回退 |
| `EditSourceTool` | `lib/rubycog/tools/edit_source.rb` | 唯一匹配替换；备份、原子写、语法检查、回滚、审计 |
| `RunTestsTool` | `lib/rubycog/tools/run_tests.rb` | 在项目根执行指定测试或全量测试；超时与输出截断 |
| `SourcePath` | `lib/rubycog/source_path.rb` | 路径白名单、目录逃逸与符号链接检查、受保护文件 |
| `SourceEdit` | `lib/rubycog/source_edit.rb` | 读取、diff、备份、原子写、`ruby -c`、恢复 |
| `SourceDocs` | `lib/rubycog/source_docs.rb` | 文档注释索引、搜索、方法源码提取 |
| `SelfIteration` | `lib/rubycog/self_iteration.rb` | 追加式审计记录 `.rubycog/self_iteration.json` |
| `ToolPreview` | `lib/rubycog/tool_preview.rb` | 审批与 TUI 展示用的调用摘要 |
| `TUI` | `lib/rubycog/tui.rb` | 审批提示、`/self`、`/restart`、源码变更提示、会话恢复 |
| `CLI` | `lib/rubycog/cli.rb` | 创建 `SelfIteration`、会话与参数传递 |

## 3. 完整流程

```
用户请求 / eval 错误 / 测试失败
  → search_docs / get_doc / get_source 定位能力与契约（只读，免审批）
  → read_source 读取目标文件（只读，免审批）
  → edit_source 计划修改（唯一匹配）
  → 用户批准
  → 备份 → 原子写 → ruby -c
      ├─ 语法失败：自动恢复备份，返回错误
      └─ 语法通过：返回 diff，等待测试
  → run_tests（指定文件或全量）
      ├─ 通过：记录审计，提示重启
      └─ 失败：返回输出；模型修复或从备份恢复
  → /restart：保存会话 → exec 重启
  → 新进程：恢复会话，重跑复现步骤，确认行为
  → /self 查看审计
```

### 3.1 触发方式

- 用户直接要求修改 RubyCog。
- `eval` 报错后，模型判断为 RubyCog 框架契约问题（见 `docs/self-healing-eval.md`）。
- `run_tests` 失败后继续修复。

### 3.2 定位

`read_source` 返回带行号的片段，默认最多 200 行、20 KB；支持 `start_line` / `end_line`。模型应先读目标文件与相关测试，再提出编辑。

### 3.3 编辑

`edit_source` 的 `old_string` 必须在目标文件中恰好出现一次；否则拒绝。新文件只允许在 `test/` 或 `docs/` 下创建（`old_string` 为空）。每次编辑必须给 `reason`，会写入审计记录。

### 3.4 验证

`run_tests` 默认运行全量 `bundle exec rake test`；传入逗号分隔的测试文件时运行 `bundle exec ruby -Itest <files>`。路径必须是 `test/` 下的文件。超时 120 秒，输出截断 4,000 字符。

### 3.5 生效

`/restart` 先保存会话（`chat.messages` 中 user/assistant 文本），再 `exec` 当前 Ruby 与 `bin/rubycog`，保留原始命令行参数。启动后 footer 显示 `resumed N turns`，模型上下文与会话文本恢复。

源码文件变化后，TUI 每 2 秒比较 `lib/**/*.rb`、`Gemfile`、`bin/rubycog` 的 mtime 与大小；变化时 footer 显示：

```
code changed — /restart to apply
```

这只是提示，不会自动重启。

## 4. 工具契约

| 工具 | 参数 | 审批 | 边界 |
| --- | --- | --- | --- |
| `eval` | `code` | 是 | 全权限；错误文本回传；`require_relative` 以当前目录为基准 |
| `read_source` | `path`, `start_line?`, `end_line?` | 否 | 只读白名单；拒绝绝对路径、`..`、符号链接逃逸 |
| `edit_source` | `path`, `old_string`, `new_string`, `reason` | 是 | 写白名单；唯一匹配；备份；语法检查；失败回滚 |
| `run_tests` | `paths?` | 是 | 只跑 `test/` 下文件；超时 120s；输出截断 |

`edit_source` 没有整文件覆盖入口，避免误删用户改动。新建文件只允许 `test/`、`docs/`。

### 4.1 允许写入的路径

```
lib/**/*.rb
test/**/*.rb
docs/**/*.md
bin/rubycog
README.md
Gemfile
rubycog.gemspec
```

### 4.2 禁止与受保护

禁止读写：

```
.git/**
.rubycog/**
.env*
**/*.pem
**/*.key
tmp/**
vendor/**
Gemfile.lock
```

只允许读、禁止自我写入（防止改坏编辑器后无法再修）：

```
lib/rubycog/source_path.rb
lib/rubycog/source_edit.rb
lib/rubycog/self_iteration.rb
lib/rubycog/tools/edit_source.rb
```

这些文件需要人工修改。

## 5. 安全护栏

1. **路径**：相对路径；拒绝绝对路径、`..` 逃逸、符号链接逃逸；写入前解析真实路径。
2. **备份**：`.rubycog/backups/<UTC 时间戳>-<pid>/<相对路径>`；备份保留供人工回退。
3. **原子写**：同目录临时文件 + `File.rename`；保留原文件权限。
4. **语法门禁**：写入后立即 `ruby -c`；失败自动恢复备份（新文件则删除）。
5. **测试门禁**：`run_tests` 独立审批；模型必须报告真实退出码与输出。
6. **受保护工具**：编辑器、路径守卫、审计、自身编辑工具不可自我写入。
7. **审计权限**：`.rubycog/` 与会话文件权限 0600，且被 `.gitignore` 忽略。
8. **不碰版本控制**：不执行 `git add` / `commit` / `reset` / `checkout`；不自动推送。
9. **不碰密钥**：不读取 `.env`、`*.pem`、`*.key`；不在工具输出中传播敏感值（仅路径级限制，非内容扫描）。
10. **`--yolo`**：自动批准所有工具，但仍备份、检查、审计；只应在完全可信的项目中使用。

## 6. 状态与审计

审计文件：`.rubycog/self_iteration.json`，最多保留 50 条，权限 0600。示例：

```json
{
  "version": 1,
  "updated_at": "2026-10-29T10:40:00Z",
  "records": [
    {
      "at": "2026-10-29T10:39:58Z",
      "kind": "edit",
      "path": "lib/rubycog/agent.rb",
      "reason": "keep tool results as strings",
      "ok": true,
      "diff": "--- a/lib/rubycog/agent.rb\n+++ b/lib/rubycog/agent.rb\n...",
      "backup": ".rubycog/backups/20261029T103958Z-1234/lib/rubycog/agent.rb"
    },
    {
      "at": "2026-10-29T10:40:00Z",
      "kind": "test",
      "paths": ["test/agent_test.rb"],
      "ok": true,
      "exit_status": 0,
      "output": "4 runs, 12 assertions, 0 failures"
    }
  ]
}
```

TUI 命令：

- `/self`：显示审计文件路径与最近 5 条记录。
- `/restart`：保存会话并重启。
- `/session`：显示会话文件与轮数。
- footer 的 `code changed — /restart to apply`：源码已变但进程未重启。

## 7. 提示词协议

`Agent::INSTRUCTIONS` 第 5 条要求模型：

1. 改 RubyCog 自身时使用 `read_source` / `edit_source`，不要用裸 `eval` 写文件。
2. 每次编辑后运行 `run_tests`，并报告真实失败。
3. 运行中进程保留旧类：必须说明需要重启，不得声称改动已生效。
4. 重启后在新进程验证行为，再宣布完成。

提示词是行为约束，不是安全边界；真正的边界在工具与审批。

## 8. 失败处理

| 失败 | 当前处理 |
| --- | --- |
| `old_string` 不存在或不唯一 | `edit_source` 拒绝，返回匹配数量 |
| 路径越界/受保护 | `SourcePath` 拒绝 |
| 写入异常 | 恢复备份（若有），返回错误 |
| `ruby -c` 失败 | 自动恢复备份，返回语法错误 |
| 测试失败 | 返回输出与退出码；模型必须修复或说明；**当前不自动回滚** |
| 测试超时 | 终止进程组，返回 timeout |
| 重启失败 | 保留会话文件，终端显示 CLI 错误 |

测试失败后的回退方式：审计记录里有 `backup` 路径，模型可读审计或用 `read_source` 确认；人工可用备份覆盖。自动回滚测试失败尚未实现。

## 9. 预算与终止（部分未实现）

当前已有：单次编辑的唯一匹配、语法门禁、测试超时、审计 50 条上限。

尚未实现但建议加入：

- 同一错误指纹最多 3 次修复尝试；
- 单轮最多修改 3 个文件、累计 80 行 diff；
- 同一文件连续两次测试失败后停止并请求人工；
- 失败测试先行（先在临时副本证明“修前红、修后绿”）；
- 修改后自动回滚（测试失败时）。

在这些实现前，模型必须依靠审计与人工判断，不能假装有硬预算。

## 10. 验收

自动：

```sh
bundle exec rake test
```

本次实现验证时覆盖：

- 路径白名单、目录逃逸、符号链接逃逸、受保护写入；
- 读取行号、唯一匹配、diff、备份、语法失败回滚；
- `edit_source` 写入并记录审计；
- `run_tests` 成功/失败、非 `test/` 路径拒绝；
- `SelfIteration` 记录、摘要、损坏文件容错、条数上限；
- `SourceDocs` 索引、搜索、类/方法文档读取、方法源码边界、排除目录；
- `search_docs` / `get_doc` / `get_source` 三个工具；
- Agent 注册四个工具；
- TUI `/self`、审批提示中的工具名、`ToolPreview`。

手工（建议每次改动自我迭代机制后执行）：

1. 启动 `bin/rubycog`。
2. 让模型 `read_source lib/rubycog/version.rb`。
3. 让模型在 `test/` 下新建一个临时测试，`run_tests` 指定它，确认通过。
4. `/self` 查看 edit/test 记录。
5. `/restart`，确认新进程 footer 显示 `resumed N turns`。
6. 删除临时测试（人工或再次 `edit_source`）。

## 11. 局限与后续

已明确不做：

- **热重载**：`load` 只替换方法，不替换已构建的 `Agent`、chat 工具表和 TUI 对象；会造成“改了但没生效”的假象。
- **自动提交/推送**：自我迭代停在文件与测试，版本控制由人决定。
- **修改第三方 gem**：依赖问题只在 RubyCog 层做 workaround。

后续优先级：

1. 测试失败自动回滚 + 失败测试先行。
2. 错误指纹与修复预算（3 次/3 文件/80 行）。
3. 启动自检：记录上次编辑的源码摘要与测试状态，启动时提示“已验证/未验证/测试失败”。
4. 审批前展示完整 diff（当前审批显示 path + reason，执行结果才含 diff）。
5. 会话与审计的加密或按项目隔离（当前按启动目录）。
6. `ErrorReport` 的 backtrace/分诊落地（见 `docs/self-healing-eval.md`）。

## 12. 与 eval 自修复的关系

`docs/self-healing-eval.md` 解决“错误怎么诊断”：eval 异常、框架帧、用户代码/依赖/环境的分诊。本文解决“诊断为框架问题后怎么安全地改并验证”。源码注释约定与 `search_docs` / `get_doc` / `get_source` 的用法见 [source-docs.md](source-docs.md)。

两者组合：

```
eval 错误 → ErrorReport（规划中） → 分诊
  ├─ user_code → 改 eval 代码重跑
  ├─ framework → read_source → edit_source → run_tests → /restart → 验证
  ├─ dependency → 报告，不直接改 gem
  └─ environment → 报告，不擅动系统
```

## 13. 快速使用

在项目目录启动：

```sh
bin/rubycog
```

对模型说：

```
给 read_source 增加一个可选参数，先读 agent.rb 和对应测试，
用 edit_source 改，改完跑相关测试，最后告诉我需要重启。
```

模型应执行：

1. `read_source` 读目标与测试；
2. `edit_source` 提交最小补丁，等待 `y` 批准；
3. `run_tests` 指定测试文件，等待 `y` 批准；
4. 报告 diff、测试输出与“需要重启”；
5. 你输入 `/restart`，新进程加载改动；
6. 用 `/self` 查看审计，确认测试通过。
