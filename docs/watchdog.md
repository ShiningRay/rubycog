# RubyCog 崩溃看门狗（watchdog）

`scripts/watchdog.rb` 负责在 DSH 后台任务里看住 RubyCog：子进程意外退出时保留现场、按预算重启，并可选地调用 AI 修复命令。它只使用 Ruby 标准库，**不加载 bundler，也不依赖任何 gem**，因此即使 bundle 坏了也能启动。

## 1. 目标与非目标

目标：

- 子进程崩溃时写出可独立阅读的崩溃包（`meta.json`、`README.md`、日志尾部）。
- 按退避策略重启；稳定运行超过阈值后清空重启预算。
- 可选：把崩溃报告交给修复命令（例如 `dsh headless`），修好后再重启。
- 优雅停止时杀掉子进程并退出 0；被看门狗杀掉的子进程不算崩溃。

非目标：

- 不守护整棵进程树：只直接管理 `spawn` 出来的那个子进程。
- 不做热重载，不修改源码，不提交 git；修复由修复命令自己负责。
- 不替代 DSH 的作业管理：外层仍可用作业停止/进程树终止来兜底。

## 2. 用法

```sh
ruby scripts/watchdog.rb [options] -- CMD [ARGS...]
```

最基本的托管：

```sh
ruby scripts/watchdog.rb --log-dir .rubycog/watchdog -- bin/rubycog
```

崩溃后调用 AI 修复（PowerShell 用单引号包住整段命令）：

```sh
ruby scripts/watchdog.rb \
  --repair 'dsh headless --approval-policy never "读取崩溃报告 %{report}，按报告里的命令、日志尾部与 git 状态定位根因；做最小修复并运行相关测试，不要提交。"' \
  --log-dir .rubycog/watchdog \
  -- bin/rubycog
```

注意：

- **不要用 `bundle exec` 启动看门狗。** `bundle exec` 会通过 `RUBYOPT=-rbundler/setup` 预加载 bundle，bundle 坏掉时脚本根本跑不起来，正好失去它存在的意义。用系统 `ruby`（或 `RbConfig.ruby`）直接启动。
- 子进程继承看门狗的环境变量与工作目录；看门狗在启动时记下 cwd，后续都用它。

## 3. 选项

| 选项 | 默认值 | 说明 |
| --- | --- | --- |
| `--log-dir DIR` | `.rubycog/watchdog` | 日志、`status.json`、崩溃包所在目录 |
| `--repair CMD` | 不启用 | 崩溃后执行的 shell 命令；`%{report}` 会替换为崩溃报告路径 |
| `--repair-timeout SECONDS` | `900` | 修复命令超时，超时后杀掉它并按修复失败处理 |
| `--max-restarts N` | `5` | 连续重启预算；用尽后退出 2 |
| `--backoff SECONDS` | `5` | 首次重启等待，之后每次翻倍，最多 60 秒 |
| `--stable-seconds SECONDS` | `120` | 单次运行超过该时长就把重启计数清零 |
| `--no-restart` | 关 | 只记录崩溃，不重启（仍会执行 `--repair`） |
| `--once` | 关 | 只跑一次子进程，用于测试；不重启也不修复 |
| `--stop-file PATH` | 无 | 该文件出现时优雅停止（Windows 上比信号可靠） |
| `-h`, `--help` | — | 显示帮助 |

参数校验失败、命令无法启动、修复失败都返回 1。

## 4. 写出的文件

```text
.rubycog/watchdog/
├── status.json                       # 当前状态，原子写入
├── run-<UTCstamp>-<n>.log            # 每次运行的 stdout+stderr
└── crashes/
    └── <UTCstamp>/
        ├── meta.json                 # 机器可读的崩溃信息
        ├── README.md                 # 给 AI 修复代理看的报告
        ├── log_tail.txt              # 运行日志最后 120 行
        └── repair.log                # 有 --repair 时才有
```

`status.json` 的字段：

| 字段 | 说明 |
| --- | --- |
| `state` | `running` / `crashing` / `repairing` / `stopped` |
| `pid` | 当前子进程 pid；未运行时为 `null` |
| `started_at` | 本次子进程启动时间（UTC ISO8601） |
| `restarts` | 当前已用的连续重启次数 |
| `last_exit` | 最近一次子进程退出码；被信号杀死时为 `128 + signal` |
| `updated_at` | 状态写入时间（UTC ISO8601） |
| `supervisor_pid` | 看门狗自身 pid |
| `command` | 完整 argv 数组 |
| `log_file` | 最近一次运行日志路径 |
| `crash_dir` | 最近一次崩溃包路径（若有） |
| `note` | 预算耗尽、修复失败等补充说明（若有） |

写入方式：先写 `<path>.<pid>.tmp`，再 `File.rename` 覆盖，轮询方不会读到半个 JSON。

## 5. 崩溃包

`meta.json` 包含：

- `exit_code`、`signaled`、`termsig`
- `uptime_seconds`、`started_at`、`crash_at`
- `command`（argv 数组）与 `command_line`（可复制的形式）
- `cwd`、`ruby_version`、`ruby_platform`、`ruby_engine`
- `git_head`、`git_status_porcelain`（在 cwd 里执行；不是 git 仓库时为 `null`）
- `log_file`、`log_tail`（最后 120 行）、`log_tail_lines`
- `attempt`、`restarts`、`supervisor_pid`
- `repair_command`、`repair_log`

`README.md` 是修复代理真正要读的文档，包含退出码、运行时长、命令行、cwd、Ruby 版本、git HEAD、`git status --porcelain`、运行日志尾部（围栏代码块）以及“接下来怎么做”的简短步骤。重试次数、预算与修复信息也在里面。

崩溃包是**证据**而不是结论：不会替修复代理判断根因。

## 6. 修复命令与 `%{report}`

看门狗用字符串替换把 `%{report}` 换成 `<crashes>/<stamp>/README.md` 的绝对路径，然后以**一整条 shell 字符串**启动修复命令（`Process.spawn(env, command, ...)`）。为兼顾命令行参数与提示词两种写法，替换规则是：

1. `%{report}` 位于引号之外 → 按平台加引号后插入：
   - Windows：`"C:/.../README.md"`
   - POSIX：`'.../README.md'`
2. `%{report}` 已位于双引号（POSIX 下还有单引号）内 → 原样插入，由外层引号保护。例如 `"读取 %{report} 并修复"` 在路径含空格时仍然正确。

因此推荐两种写法：

```sh
# 作为独立参数（校验/工具类命令）
--repair 'ruby tools/repair.rb %{report}'

# 嵌在提示词里（DSH 修复代理）
--repair 'dsh headless --approval-policy never "读取 %{report} 并修复崩溃"'
```

Windows 上只识别双引号作为引号（cmd 不把单引号当引号）；路径里出现双引号不是合法 Windows 路径，无需处理。POSIX 路径里的单引号会被正确转义。

除替换外，修复进程还会拿到以下环境变量作为兜底：

- `WATCHDOG_CRASH_REPORT`：README 路径
- `WATCHDOG_CRASH_DIR`：崩溃包目录
- `WATCHDOG_REPORT`：与上者相同，便于短命令使用

修复命令的 stdout/stderr 写入崩溃包内的 `repair.log`。修复超时（默认 900 秒）或被看门狗停止时，子进程会被杀掉；修复退出码非 0 视为修复失败：**停止循环并退出 1**，不会再重启，避免把坏状态带进下一轮。

DSH 的修复命令形状：

```sh
dsh headless --approval-policy never "<prompt>"
```

提示词里应明确要求：读取 `%{report}`、复现、最小修复、运行测试、不要提交。看门狗不检查修复是否真的改了代码，只检查修复进程是否成功退出。

## 7. 重启策略与退出码

一次崩溃后的顺序：

1. 写崩溃包，`status.json` 进入 `crashing`。
2. 若单次运行已超过 `--stable-seconds`，先把重启计数清零。
3. 若 `restarts >= --max-restarts`，退出 2。
4. 若有 `--repair`，进入 `repairing` 并执行；失败/超时退出 1。
5. `--no-restart` 时不重启，退出 1。
6. 重启计数加一，按 `backoff * 2^(n-1)` 等待（上限 60 秒），期间可被停止请求打断。

| 退出码 | 场景 |
| --- | --- |
| `0` | 子进程正常退出 0；或收到停止请求并已杀掉子进程 |
| `1` | 配置错误、命令无法启动、修复失败/超时、`--no-restart` 或 `--once` 下发生崩溃 |
| `2` | 连续重启预算耗尽 |

## 8. 与 DSH 集成

后台作业里用系统 Ruby 启动：

```sh
ruby scripts/watchdog.rb --log-dir .rubycog/watchdog -- bin/rubycog
```

停止方式：

- POSIX：`SIGINT` / `SIGTERM`；看门狗在轮询间隔（50ms）内响应，杀掉子进程、写 `state=stopped`、退出 0。
- Windows：信号不可靠，推荐 `--stop-file`，由外部写一个文件触发优雅停止；如果外层直接杀掉整个进程树（Job Object / `taskkill /T`），看门狗来不及走优雅路径，`status.json` 可能停留在 `running`，这是已知限制。
- 被看门狗自己杀掉的子进程**不会**产生崩溃包：等待循环先看到停止请求，再终止并回收子进程。

Windows 上 `Process.kill('KILL', pid)` 能终止直接子进程（Ruby 对子进程的 `TerminateProcess`），孙进程不在看门狗职责内。

## 9. 限制

- 单次运行的上限是 Python 记忆层的 120 行日志尾部；更早的内容仍在 `run-*.log` 里，但没有自动复制进崩溃包。
- 崩溃包写入是尽力而为：磁盘/权限错误只会在 stderr 报告，看门狗继续按预算重启。
- `git` 命令在启动 cwd 执行；不在仓库里或未安装 git 时相关字段为 `null`，README 显示 `unknown`。
- 修复命令按“整条 shell 字符串”交给系统解析。Windows 上引号规则由 `CreateProcess`/`cmd.exe` 决定；命令里含复杂重定向或管道时请自行保证引号正确。
- `--once` 只用于冒烟与测试：不重启、不执行修复。
- 看门狗不清理旧日志与旧崩溃包；长期运行需要外部清理 `.rubycog/watchdog/`。

## 10. 测试

```sh
ruby -Itest test/watchdog_test.rb
```

测试直接 `require 'minitest/autorun'` 而不走 `test_helper.rb`：`test_helper` 会加载 `lib/rubycog` 和 gems，而看门狗测试必须在 bundle 坏掉时也能运行。覆盖：

- 退出码 1 → 生成崩溃目录、`meta.json`、`README.md`，日志尾部含子进程 stderr。
- 退出码 0 → 不生成崩溃包，`status.json` 记录 `last_exit=0`。
- 修复命令收到真实存在的 README 路径，修复成功后重启并正常退出 0。
- `--max-restarts 2` → 初始运行 + 2 次重启后退出 2。
- `--once` → 子进程只运行一次。
- `--stop-file` → 杀掉子进程、不产生崩溃包、退出 0。
