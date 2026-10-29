# RubyCog

一个极简的 Ruby Agent：通过 [RubyLLM](https://rubyllm.com/) 接入模型，只提供一个 `eval` 工具，并附带流式终端界面（TUI）。

## 特性

- RubyLLM 2.1：同一套代码使用 OpenAI、Anthropic、Gemini、DeepSeek、OpenRouter、Ollama 等提供商。
- 唯一工具 `eval`：执行 Ruby，保留局部变量，返回结果或异常。
- 每次工具执行前显示代码，必须按 `y` 批准，按 `n` 拒绝。
- Curses TUI：流式回答、工具输出、历史滚动和 UTF-8 输入。
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

配置所选模型的提供商密钥，然后启动：

```sh
# 任选一家，只需配置要使用的提供商
export OPENAI_API_KEY='...'
# export ANTHROPIC_API_KEY='...'
# export GEMINI_API_KEY='...'
# export DEEPSEEK_API_KEY='...'
# export OPENROUTER_API_KEY='...'

bin/rubycog
# 如果通过 gem 安装：rubycog
```

默认使用 RubyLLM 的模型。建议明确指定你的提供商支持的模型：

```sh
bin/rubycog --model gpt-5-mini
bin/rubycog --model claude-sonnet-4-6
bin/rubycog --model gemini-3-flash-preview
# 或设置默认模型
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
| `y` / `n` | 批准一次 eval / 拒绝本次 eval |
| `Ctrl-C` | 生成时取消；空闲时退出 |
| `Page Up` / `Page Down` | 滚动历史 |
| `←` / `→` / `Home` / `End` | 移动输入光标 |
| `/clear` | 新建会话（局部变量会重置） |
| `/help` | 显示命令 |
| `/quit` | 退出 |

## 安全说明

**`eval` 不是沙箱。** 模型生成的 Ruby 代码拥有当前用户的完整权限，可以读写文件、访问网络、读取环境变量及执行系统命令。审批前仔细检查完整代码，仅在可信环境中使用；生产环境或多租户环境应在额外隔离中运行。程序没有自动批准开关。

## 开发

```sh
bundle exec rake test
bin/rubycog --help
gem build rubycog.gemspec
```

测试使用假的聊天对象，不需要 API Key，也不会发起模型请求。

核心文件：

- `lib/rubycog/eval_tool.rb`：唯一工具及执行上下文。
- `lib/rubycog/agent.rb`：RubyLLM 会话、流式事件与工具审批。
- `lib/rubycog/tui.rb`：终端交互与绘制。

## License

[MIT](LICENSE.txt)
