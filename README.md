# RubyCog

一个极简的 Ruby Agent：通过 [RubyLLM](https://rubyllm.com/) 接入模型，只提供一个 `eval` 工具，并附带流式终端界面（TUI）。

## 特性

- RubyLLM 2.1：同一套代码使用 OpenAI、Anthropic、Gemini、DeepSeek、OpenRouter、Ollama 等提供商。
- 工具：`eval` 执行 Ruby；`read_source`、`edit_source`、`run_tests` 用于受控的自我迭代；`search_docs`、`get_doc`、`get_source` 检索源码文档；`learn_from_url`、`save_experience`、`search_experiences` 从外部来源学习可复用经验；`propose_evolution`、`approve_proposal`、`run_evolution`、`evolution_edit`、`evolution_run_tests`、`evolution_benchmark`、`finish_evolution`、`rollback_evolution`、`suggest_proposals` 在隔离 worktree 中把经验转为代码改动；`introspect_code` 用 rubocop + reek + 启发式扫描发现坏味道、技术债、性能问题，并按 `category=refactor | performance` 分流提案。
- 空闲自驱动：`IdleWatcher` 后台线程，15 分钟无输入自动触发一轮演化或自省（交替），1 小时冷却，`/yolo` 决定是否走完整闭环。
- 编码工作流：先说明目标与约束，再写最小实现；跑通后审查可复用部分，满足条件才抽成方法、类或模块。
- 默认在写操作与测试执行前显示调用摘要，按 `y` 批准，按 `n` 拒绝；可用 `--yolo` 或 `/yolo` 切换为免审批。
- Curses TUI：流式回答、工具输出、历史滚动、UTF-8 输入，顶栏显示当前工作目录，底部显示对象数与进程内存。
- 无 Rails、无数据库、无额外 Agent 框架。

## 安装

要求 Ruby 3.2 或更高版本（在 Ruby 3.4.8 上测试）。

```sh
git clone https://github.com/ShiningRay/rubycog.git
cd rubycog
bundle install
```

也可安装 gem：

```sh
gem install rubycog
```

## 启动

默认使用 **DeepSeek V4.1 Flash**（官方 API 模型 ID：`deepseek-flash`），只需配置密钥：

```sh
export DEEPSEEK_API_KEY='你的 DeepSeek API 密钥'
bin/rubycog
# 跳过 eval 审批（危险，仅限可信项目）
bin/rubycog --yolo
# 每次 eval 使用独立 binding，局部变量不跨调用
bin/rubycog --isolated-eval
```

密钥也可以写在 `.env` 文件里，启动时自动读取（dotenv 解析，支持注释、`export`、引号与行尾注释）。查找顺序是**当前目录 `.env`，然后是 RubyCog 自身的 `.env`**；同一个键以先读到的为准。**已存在的 shell 变量一律优先**，所以临时换密钥仍可只 `export`。`.env` 已在 `.gitignore` 中，不会被提交；改完 `.env` 后输入 `/restart` 即重新读取。

密钥从环境变量或 `.env` 读取，不会写入项目或日志。如需其他提供商，可配置 `OPENAI_API_KEY`、`ANTHROPIC_API_KEY`、`GEMINI_API_KEY` 或 `OPENROUTER_API_KEY`，并用 `--model` 选择对应模型：

```sh
bin/rubycog --model gpt-5-mini
bin/rubycog --model claude-sonnet-4-6
bin/rubycog --model gemini-3-flash-preview
# 或用环境变量覆盖默认模型
export RUBYCOG_MODEL='gpt-5-mini'
```

也支持 `MISTRAL_API_KEY`、`PERPLEXITY_API_KEY`、`XAI_API_KEY`。支持自定义接口的提供商可使用 `OPENAI_API_BASE`、`ANTHROPIC_API_BASE`、`GEMINI_API_BASE`、`OPENROUTER_API_BASE` 或 `OLLAMA_API_BASE`。其他提供商可通过 RubyLLM 的 Ruby API 配置，而不必修改 Agent。

Ollama 示例：

```sh
export OLLAMA_API_BASE='http://localhost:11434'
bin/rubycog --model qwen3
```

试试输入：`Use Ruby to calculate 21 * 2.`

## 操作

| 按键 / 命令 | 行为 |
| --- | --- |
| `Enter` | 发送消息 |
| `y` / `n` | 批准一次工具调用 / 拒绝本次调用 |
| `/yolo` | 切换免审批模式：开启后 eval 直接执行，不再询问 |
| `Ctrl-C` | 生成时取消；空闲时退出 |
| `Page Up` / `Page Down` | 滚动历史 |
| `←` / `→` / `Home` / `End` | 移动输入光标 |
| `/gc` | 立即回收 VM 内存（`GC.start`），并显示回收的对象数与内存变化 |
| `/reset-eval` | 丢弃 eval 的局部变量表；常量、全局变量、线程等不会随之清除 |
| `/clear` | 新建对话（`eval` 的进程内定义仍保留） |
| `/session` | 显示会话文件路径与已保存的轮数 |
| `/self` | 显示自我迭代审计（最近编辑与测试） |
| `/restart` | 保存会话并重启进程，加载刚修改的 RubyCog 代码 |
| `/help` | 显示命令 |
| `/quit` | 退出 |

## 编码约定

写代码前，模型先用一两句说明目标、输入输出与关键假设；假设会改变实现时才追问。跑通后再做复用审查，只有满足下列之一才抽成方法、类或模块：

- 同一逻辑已经重复，或本任务内明确会再用；
- 用户明确要求可复用的组件；
- 边界稳定、接口小，且有具体的第二个使用场景。

一次性脚本保持内联，不引入没有第二使用场景的间接层、工厂或抽象基类。抽出组件时给清晰命名，并用一句话说明复用了什么、放在哪里。

`eval` 中定义的方法与类在当前进程内保留，`/clear` 不会清空；需要跨重启复用时，模型应先说明目标文件并等待审批，而不是假定定义会自动持久化。

`eval` 中的 `require_relative` 以进程当前目录为基准。`LoadError`、`SystemExit`、栈溢出等异常会作为错误文本返回给模型，不会终止 TUI 工作线程；`Ctrl-C` 仍可中断。

会话默认保存在启动目录的 `.rubycog_session.json`，启动时自动恢复，footer 显示 `resumed N turns`；可用 `-s/--session PATH` 或 `RUBYCOG_SESSION` 指定路径。只保存 user/assistant 文本，工具调用不重放；连续 assistant 消息会合并成一轮。会话文件含对话内容，已写入 `.gitignore` 且权限设为 0600，仍不要提交或分享。

一轮任务运行期间，footer 的状态词（`thinking`、`cancelling`、`compacting`）会沿颜色阶梯脉动，后面跟着该轮已用时间（`thinking · 0.6s`）；结束后耗时留在该轮应答的标签行（`RubyCog · 14:32 · 42s`）。等审批时页脚被固定的黄色提示接管，不参与脉动。颜色阶梯在 256 色终端上是 6 帧青色渐变，8 色终端降为 4 帧亮度阶梯，无色终端只保留加粗。帧由单调时钟推进，重绘仍受 `TICK_INTERVAL`（0.25s）节流，空闲时不重绘。

`eval` 收到的代码在转录区按 Ruby 语法高亮：关键字（青色加粗）、字符串（绿色）、注释（蓝色）、数字（黄色）、常量（品红加粗）、符号（红色）、`def` 后的方法名（青色）。这是逐行的显示辅助而非解析器：未闭合的字符串、插值、`%w[]` 字面量只会少一层颜色，文本不会变；换行与缩进和纯代码渲染完全相同，因此搜索和滚动行为不受影响。终端没有颜色或颜色对不足时，自动退回统一的代码色。

助手消息里标注了语言的围栏代码块也走同一套高亮：```` ```ruby ````（或 ```` ```rb ````）按 Ruby 上色，其它语言和未标注的围栏保持纯代码色——把 `json`、`sh` 当 Ruby 猜会让 `if`/`then`/`end` 亮错地方。围栏标记支持尾随参数（如 ```` ```ruby title=demo ````），大小写不敏感。

修改 RubyCog 自身源码后，当前进程仍运行旧类。模型应先跑相关测试，再明确提示重启；TUI 检测到 `lib/**/*.rb` 变化时 footer 会显示 `code changed — /restart to apply`。按 `/restart` 保存会话并重启，新的进程才会加载改动。

自我迭代与源码检索使用这些工具：`eval` 执行 Ruby；`read_source` 读取白名单源码；`search_docs` 按关键词搜索类/方法上方的文档注释；`get_doc` 读取注释；`get_source` 读取方法源码；`edit_source` 做唯一匹配替换（审批、备份、Ruby 文件跑 `ruby -c`、失败回滚）；`run_tests` 跑指定或全量测试（审批、超时、输出截断）。写入只允许 `lib/`、`test/`、`docs/`、`bin/rubycog`、`README.md`、`Gemfile`、`rubycog.gemspec`；`.git`、`.env`、密钥、`.rubycog/`、`Gemfile.lock` 禁止；编辑器与路径守卫本身不可自我写入。每次编辑与测试记录在 `.rubycog/self_iteration.json`，用 `/self` 查看。机制细节见 [docs/self-iteration.md](docs/self-iteration.md)，源码文档检索见 [docs/source-docs.md](docs/source-docs.md)。

外部学习使用三个工具：`learn_from_url` 抓取外部 URL 并返回可读文本；`save_experience` 把提炼后的可复用经验存为 YAML（`.rubycog/experiences/`）；`search_experiences` 在改自己之前按关键词召回相关经验。TUI 用 `/experiences` 查看已存条目。机制细节见 [docs/experience.md](docs/experience.md)。

自我进化把经验落地为代码改动：`propose_evolution` 写提案；`approve_proposal` 批准；`run_evolution` 在 `.rubycog/worktrees/<id>` 上开 `evo/<id>` 分支并进入 running 状态；`evolution_edit` 在 worktree 内做唯一匹配替换（备份、`ruby -c`、原子写、budget 强制 `max_files/max_lines`）；`evolution_run_tests` 在 worktree 内跑测试；`evolution_benchmark` 对比 main 与 worktree 下 `benchmarks/*.rb` 的数值分数，回归超 5% 自动阻止 `finish_evolution(success: true)`（可 `force: true` 覆盖）；`suggest_proposals` 扫描未被任何提案引用的经验，让模型自主设定下一步目标；用户手动 `git merge evo/<id>` 或 `rollback_evolution` 丢弃。所有写操作均限制在 worktree 内，主 checkout 不被修改。TUI 用 `/proposals` 查看提案，用 `/evolve` 一键驱动一轮自我进化闭环（每步仍需审批）。机制细节见 [docs/evolution.md](docs/evolution.md)。

自省环节用 `introspect_code` 扫描 RubyCog 自身：跑 `bundle exec rubocop` + `bundle exec reek`，再做纯 Ruby 启发式扫描（.bak 文件、超长方法/文件、多参数、重复块、注释掉的代码），把报告写到 `.rubycog/introspection/<stamp>.md` 并返回紧凑摘要。模型据此 `read_source` 读关键文件，写 `category=refactor`（允许基准回归）或 `category=performance`（必须基准改善且 `evolution_benchmark` 为必需）的提案。`benchmarks/` 自带 alloc/memsize/boot_time 三个数值基准（direction=lower）。TUI 用 `/introspect` 一键驱动自省 + 提案生成。机制细节见 [docs/introspection.md](docs/introspection.md)。

空闲触发由 `IdleWatcher` 后台线程驱动：TUI 启动时自动开启，15 分钟无输入触发一次演化或自省（两者交替），触发后 1 小时冷却；任何用户输入重置计时与冷却。`/yolo on` 时走完整闭环（含 approve/run/edit/test/benchmark/finish），`/yolo off` 时只写提案等用户回来审批。`/idle on|off|status` 控制开关与查看状态。机制细节见 [docs/idle.md](docs/idle.md)。

## eval 内存与会话隔离

默认模式下，`eval` 的局部变量在当前进程中保留，跨调用可复用。这些变量由 binding 持有，直到重置或进程退出；大量临时对象会一直可达，`GC.start` 不会回收。

- `/reset-eval`：丢弃当前 eval 局部变量表并触发 GC。旧 binding 失去引用后，仅被它引用的对象可以被回收。
- `--isolated-eval`：每次 `eval` 使用新的 binding，局部变量、局部方法和 `self` 都不跨调用；适合一次性脚本。
- 方法、常量与类（默认落在 `Object`）、全局变量、线程、信号处理器、打开的文件/连接不会因 `/reset-eval` 清除；需要彻底清理时重启进程。
- `/gc` 只触发 GC；`/restart` 会重启进程并恢复会话文本。

隔离模式每次调用的 `self` 是匿名对象，不是 `main`；默认模式仍保持 `main`。

## 安全说明

**`eval` 不是沙箱。** 模型生成的 Ruby 代码拥有当前用户的完整权限，可以读写文件、访问网络、读取环境变量及执行系统命令。`edit_source` 虽受路径白名单与备份保护，但仍会改项目源码，审批前应看清算要改的文件与原因。生产环境或多租户环境应在额外隔离中运行。`--yolo` 启动参数或 `/yolo` 指令会跳过逐次审批，所有工具调用（含写文件）将直接执行；只应在完全可信的项目中使用，TUI 会持续显示 `YOLO` 标记。

## 开发

```sh
bundle exec rake test
bin/rubycog --help
gem build rubycog.gemspec
```

测试使用假的聊天对象，不需要 API Key，也不会发起模型请求。

核心文件：

- `lib/rubycog/eval_tool.rb`：任意 Ruby 执行工具及执行上下文。
- `lib/rubycog/tools/`：`read_source`、`edit_source`、`run_tests`、`search_docs`、`get_doc`、`get_source`。
- `lib/rubycog/source_path.rb`、`source_edit.rb`：路径白名单、备份、原子写、语法检查。
- `lib/rubycog/source_docs.rb`：源码文档注释索引与检索。
- `lib/rubycog/self_iteration.rb`：自我迭代审计。
- `lib/rubycog/agent.rb`：RubyLLM 会话、流式事件与工具审批。
- `lib/rubycog/tui.rb`：终端交互与绘制。

## License

[MIT](LICENSE.txt)
