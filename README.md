# RubyCog

一个极简的 Ruby Agent：通过 [RubyLLM](https://rubyllm.com/) 接入模型，只提供一个 `eval` 工具，并附带流式终端界面（TUI）。

## 特性

- RubyLLM 2.1：同一套代码使用 OpenAI、Anthropic、Gemini、DeepSeek、OpenRouter、Ollama 等提供商。
- 工具：`eval` 执行 Ruby；`read_source`、`edit_source`、`run_tests` 用于受控的自我迭代；`search_docs`、`get_doc`、`get_source` 检索源码文档。
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
```

密钥只从环境变量读取，不会写入项目或日志。如需其他提供商，可配置 `OPENAI_API_KEY`、`ANTHROPIC_API_KEY`、`GEMINI_API_KEY` 或 `OPENROUTER_API_KEY`，并用 `--model` 选择对应模型：

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

修改 RubyCog 自身源码后，当前进程仍运行旧类。模型应先跑相关测试，再明确提示重启；TUI 检测到 `lib/**/*.rb` 变化时 footer 会显示 `code changed — /restart to apply`。按 `/restart` 保存会话并重启，新的进程才会加载改动。

自我迭代与源码检索使用这些工具：`eval` 执行 Ruby；`read_source` 读取白名单源码；`search_docs` 按关键词搜索类/方法上方的文档注释；`get_doc` 读取注释；`get_source` 读取方法源码；`edit_source` 做唯一匹配替换（审批、备份、`ruby -c`、失败回滚）；`run_tests` 跑指定或全量测试（审批、超时、输出截断）。写入只允许 `lib/`、`test/`、`docs/`、`bin/rubycog`、`README.md`、`Gemfile`、`rubycog.gemspec`；`.git`、`.env`、密钥、`.rubycog/`、`Gemfile.lock` 禁止；编辑器与路径守卫本身不可自我写入。每次编辑与测试记录在 `.rubycog/self_iteration.json`，用 `/self` 查看。机制细节见 [docs/self-iteration.md](docs/self-iteration.md)，源码文档检索见 [docs/source-docs.md](docs/source-docs.md)。

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
