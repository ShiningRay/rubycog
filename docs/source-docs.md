# 源码文档与检索

本机制来自 `../ruby` AgentOS 的做法：把「定义上方的注释块」当作可检索的源码文档，让 Agent 在改代码前先找到能力、读文档、再读源码。RubyCog 已迁移为只读工具 `search_docs`、`get_doc`、`get_source`，不依赖 Ruby 解析器或运行时加载。

## 1. 文档注释约定

在类、模块或方法定义的正上方写连续注释块：

```ruby
# 会话保存与恢复。
#
# 只保存 user/assistant 文本；工具调用不重放。
class Session
  # 读取路径；损坏或缺文件时返回空数组。
  def initialize(path = self.class.default_path)
    # ...
  end
end
```

规则：

- 注释与定义之间不能有空行；空行会结束注释块。
- 第一段用一句话说明「做什么」，后续段落写限制、副作用、边界。
- 注释可以中文或英文；索引按原样保存。
- 方法注释写在 `def` 正上方；类方法同样适用。
- 顶层方法会归类为 `(top-level)#name`。
- 嵌套类/模块按缩进拼出完整名：`module Rubycog` + `class Agent` → `Rubycog::Agent`。
- 单行无限方法（`def short = "hi"`）也会被索引。

## 2. 工具

| 工具 | 参数 | 作用 |
| --- | --- | --- |
| `search_docs` | `query` | 多关键词空格分隔、全部命中；类名、方法名、文件路径、注释都参与匹配；返回 label、file:line、注释摘要 |
| `get_doc` | `class_name`, `method?`, `kind?` | 读取类/模块或方法的文档注释；没有项目注释时回退 `ri` |
| `get_source` | `class_name`, `method`, `kind?` | 读取方法源码；优先项目索引，找不到时用运行时 `source_location` 回退 |
| `read_source` | `path`, `start_line?`, `end_line?` | 按文件路径读取完整片段；适合查看上下文，不要求类已定义 |

`kind` 取 `instance`（默认）或 `class`；类方法用 `Foo.bar` 的标签，实例方法用 `Foo#bar`。

`read_source` 与 `edit_source` 只作用于 RubyCog 项目；`search_docs`、`get_doc`、`get_source` 的索引还包含当前工作目录，因此可以检索用户项目里的类与方法。

示例：

```text
search_docs query="approval session"
get_doc class_name="Rubycog::TUI" method="handle_key"
get_source class_name="Rubycog::SourcePath" method="resolve"
read_source path="lib/rubycog/tui.rb" start_line=150 end_line=190
```

## 3. 索引范围

- 根目录：RubyCog 项目根 + 当前工作目录（realpath 去重）。
- 文件：`**/*.rb`，最多 500 个。
- 排除目录：`.git`、`.rubycog`、`.bundle`、`node_modules`、`vendor`、`tmp`、`log`、`coverage`、`build`、`dist`、`db`、`storage`、`pkg`、`data`，以及隐藏目录。
- 只做文本扫描，不加载文件；不可读或编码异常的文件跳过。

这使 `search_docs` 可以在不启动用户项目的情况下检索它的注释；`get_source` 对已加载的类/方法还可以回退到运行时源码。

## 4. 与 AgentOS 的差异

AgentOS 的 `search_docs` / `get_doc` / `get_source` 建立在进程内反射和运行中定义之上，`get_source` 优先读 `define_class` / `define_method` 的登记表。RubyCog 没有运行中定义工具，因此：

- 索引以磁盘文件为准，不读取运行时改写。
- `get_source` 先查索引，再用 `source_location` 回退。
- `get_doc` 保留 `ri` 兜底，但项目注释优先。
- 不提供 `define_class` / `define_method`；修改源码走 `edit_source` + `run_tests` + `/restart`。

## 5. 在自我迭代中的用法

1. 用户说「某能力在哪」或准备改 RubyCog 时，先 `search_docs` 找类/方法。
2. 不熟悉接口时，`get_doc` 读注释；注释不足时 `get_source` 读实现。
3. 需要完整文件上下文时，用 `read_source`。
4. 修改后，在新类/方法上方补文档注释；这样下一次 `search_docs` 能命中。
5. 刷新注释不需要重启：索引每次调用重新扫描磁盘。修改代码本身仍需 `/restart` 才能生效。

## 6. 提示词约束

`Agent::INSTRUCTIONS` 要求模型：

- 涉及已有代码时先 `search_docs`，再 `get_doc` / `get_source`，不要猜类名或方法名。
- 新建类、模块、方法时写简短文档注释：第一段说明做什么，后续段落写细节。
- 改 RubyCog 自身时用 `read_source` / `get_source` / `edit_source`，不直接用 `eval` 写文件。

## 7. 已知限制

- 文本近似扫描，不解析 Ruby 语法；`class << self`、`define_method`、动态常量、单行多定义可能漏索引或归错 owner。
- 注释在字符串/heredoc 中时可能被误认为文档注释。
- 嵌套判断依赖缩进；格式异常的代码可能归错类。
- 只索引 Ruby 文件；Markdown 文档不在 `search_docs` 范围，可直接用 `read_source` 读取（白名单支持 `docs/*.md`）。
- `ri` 兜底依赖本机安装；缺失时返回「没有文档」。
- 索引 500 个文件上限；超大项目请用更具体的关键词或直接 `read_source`。

## 8. 测试

`test/source_docs_test.rb` 覆盖：

- 模块/类/实例方法/类方法/无限方法索引；
- 多词 AND 搜索；
- 类与方法文档读取；
- 方法源码边界与无限方法；
- 排除目录；
- 三个工具的输入输出。

手工验收：

```sh
bin/rubycog
```

然后输入：

```text
search_docs approval
get_doc class_name="Rubycog::SourcePath"
get_source class_name="Rubycog::SourcePath" method="resolve"
```
