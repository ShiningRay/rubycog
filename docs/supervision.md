# 用 DSH 托管 RubyCog（崩溃监控 + AI 修复 + 自动重启）

本文描述一条已经在 Windows 上跑通的完整链路：由 DSH 的后台任务启动
`rubycog --headless --daemon`，看门狗（`scripts/watchdog.rb`）盯着它，
一旦非正常退出就写崩溃包，再调用 DSH 的无头模式（`dsh headless`）让 AI
读报告、改代码、跑测试，然后重新拉起进程。

三个零件各司其职：

| 组件 | 作用 | 详见 |
| --- | --- | --- |
| `bin/rubycog --headless --daemon` | 无 curses 的常驻 Agent，轮询 inbox、写心跳 | [headless.md](headless.md) |
| `scripts/watchdog.rb` | 拉起子进程、判定崩溃、写崩溃包、调用修复命令、重启 | [watchdog.md](watchdog.md) |
| `scripts/dsh_repair.rb` | 把崩溃包翻译成 DSH 修复提示词并执行 `dsh headless` | 本文第 3 节 |

## 1. 一次性配置

### 1.1 模型网关（`.env`）

RubyCog 通过 RubyLLM 访问模型，网关和 DSH 桌面端用的是同一个。`.env`
已被 `.gitignore` 忽略，**不要提交**：

```sh
OPENAI_API_KEY=<magpie 网关的 key>
OPENAI_API_BASE=http://192.168.2.22:3425/v1
RUBYCOG_PROVIDER=openai
RUBYCOG_MODEL=auto/deepseek-v4.1-flash
RUBYCOG_ASSUME_MODEL_EXISTS=1
```

`RUBYCOG_PROVIDER` 与 `RUBYCOG_ASSUME_MODEL_EXISTS` 由
`lib/rubycog/chat_factory.rb` 读取：自建网关的模型名不在 RubyLLM 的注册表里，
必须显式给出 provider 并允许未知模型。key 也可以只放在环境变量里，`.env`
只是方便常驻进程继承。

### 1.2 DSH 的无头 profile

`dsh --profile headless` 默认没有任何 provider，需要在
`~/.dsh/profiles/headless/cordis.patch.yml` 里补上和桌面端一致的 provider
（`agent-default-model` 指向 `magpie` / `auto/deepseek-v4.1-flash`，
`llm-pi-ai` 里声明 `apiKeyEnv: MAGPIE_API_KEY`、`baseURL` 和模型列表）。
key 本身不写进 profile：`dsh_repair.rb` 会从 `~/.dsh/.credentials.yaml`
的 `refs` 里取出 `*_API_KEY` 注入子进程环境，导出的变量优先于文件。

自检：

```sh
ruby scripts/dsh_repair.rb --report .rubycog/watchdog/crashes/<时间戳>/README.md --dry-run
```

`--dry-run` 只打印提示词，不调用模型。

## 2. 启动托管

在仓库根目录（PowerShell）：

```powershell
ruby scripts/watchdog.rb `
  --log-dir .rubycog\watchdog `
  --repair "ruby scripts\dsh_repair.rb --report %{report} --repo C:\Users\ShiningRay\projects\rubycog --timeout 900" `
  --max-restarts 5 --backoff 5 --stable-seconds 120 `
  -- ruby bin\rubycog --headless --daemon
```

要点：

- 子进程命令里**不要套 `bundle exec`**：看门狗只杀直接子进程，`bundle exec`
  会多一层包装，Windows 上信号传不下去。`bin/rubycog` 自己会设 `BUNDLE_GEMFILE`。
- `--stable-seconds 120` 表示活过两分钟的运行会把重启计数清零，避免一次偶发
  崩溃就耗尽预算。
- 修复命令里的 `%{report}` 会被替换成该次崩溃包的 `README.md` 路径。

在 DSH 里，这条命令作为后台任务运行即可（`run_in_background`），
stdout 可以另存为 `.rubycog\watchdog-supervisor.log`。

## 3. 崩溃之后发生什么

1. 子进程退出码非 0（或不是被看门狗主动停掉的），判定为崩溃。
2. 写出 `.rubycog/watchdog/crashes/<UTC 时间戳>/`：
   `meta.json`（退出码、运行时长、命令行、cwd、Ruby 版本、git HEAD 与
   `git status --porcelain`）、`log_tail.txt`（运行日志末尾）、
   `README.md`（人可读摘要 + 复现步骤）。
3. 执行修复命令，输出写进同目录的 `repair.log`，超时默认 900 秒。
4. `dsh_repair.rb` 拼出英文提示词（先复现、最小改动、不许改 `.env`/凭据、
   不许削弱测试、结束时给出根因/改动文件/测试结果），把
   `dsh --profile headless --approval-policy never -` 起在仓库根目录，
   提示词从 stdin 传入，输出实时转发到 `repair.log`。
5. 修复命令退出码为 0 就重启子进程；非 0 则停止循环并保留现场，等人工介入。
6. 超过 `--max-restarts` 次（默认 5）看门狗以退出码 2 结束，不再重启。

## 4. 投递任务与观察

```powershell
# 投递一个任务（文件名顺序即处理顺序）
Set-Content .rubycog\headless\inbox\task-001.txt -Value "Use the eval tool to compute 6 * 7."

# 看进程是否活着
Get-Content .rubycog\headless\heartbeat.json   # pid / last_tick / tasks_done
Get-Content .rubycog\watchdog\status.json      # state=running|repairing|stopped

# 看它刚才干了什么
Get-Content .rubycog\watchdog\run-*.log -Tail 30
```

任务成功后文件被移到 `inbox\done\`，失败移到 `inbox\failed\`，单个任务抛错
不会终止守护进程。

## 5. 停止

- 前台运行时按 `Ctrl+C`：看门狗杀掉子进程，`status.json` 写成 `stopped`，
  退出码 0，这次退出**不算崩溃**。
- 后台任务可以用看门狗的 `--stop-file`：`touch` 该文件后看门狗在下一个
  轮询周期收尾；或在 DSH 里直接结束该后台任务。

## 6. 已验证与限制

已在本机验证（Windows 11，Ruby 4.0.9 x64-mingw-ucrt）：

- 崩溃 → 崩溃包 → AI 修复 → 重启的完整闭环：先在
  `.rubycog/e2e/shop2` 的人造缺陷上跑通（dsh 用 28 秒把
  `items.map { |item| item[:price] }.sum` 改成
  `items.map { |item| item[:price] * item[:qty] }.sum`，重启后测试通过）。
- 真实 rubycog 守护进程：`--headless --daemon` 常驻、心跳更新、
  inbox 任务处理成功（`6 * 7` → 42，`[done] ok`）。
- 强制结束真实守护进程（模拟崩溃）后，看门狗记录了退出码、崩溃包与
  `repair.log`，并重新拉起新进程。

限制：

- Windows 上 `Process.kill` 对孙进程无效，所以托管命令要尽量直接；
  SIGTERM 语义也与 POSIX 不同，正常停止请用 `Ctrl+C` / 后台任务取消 /
  `--stop-file`。
- 修复代理用的是**当前仓库**：它会真的改代码。建议先在分支或干净工作区
  上观察，确认修复质量后再让它常驻。
- `dsh_repair.rb` 依赖本机 `dsh` 可执行文件和 `~/.dsh/.credentials.yaml`；
  两者缺失时会明确报错，而不是静默失败。
