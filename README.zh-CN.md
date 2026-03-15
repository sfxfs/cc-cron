# cc-cron

[English](README.md) | [简体中文](README.zh-CN.md)

将 Claude Code 命令按 cron 任务进行调度。

## 安装

```bash
# 克隆或下载脚本
chmod +x cc-cron.sh

# 可选：添加到 PATH
ln -s $(pwd)/cc-cron.sh ~/.local/bin/cc-cron

# 可选：启用 bash 自动补全（添加到 ~/.bashrc）
eval "$(cc-cron completion)"
```

## 用法

### 添加定时任务

```bash
./cc-cron.sh add <cron-expression> <prompt> [options]
```

**选项：**

| 选项 | 说明 |
|--------|-------------|
| `--once` | 创建一次性任务（执行成功后自动删除） |
| `--workdir <path>` | 此任务的工作目录 |
| `--model <name>` | 使用的模型：sonnet、opus、haiku 等 |
| `--permission-mode <mode>` | 权限模式：acceptEdits、auto、default |
| `--timeout <seconds>` | 任务执行超时时间（0 = 不超时，默认） |

**示例：**

```bash
# 工作日每天上午 9 点执行，使用默认设置
./cc-cron.sh add "0 9 * * 1-5" "Run daily tests and report results"

# 使用指定模型和工作目录执行
./cc-cron.sh add "0 * * * *" "Check for issues" --model sonnet --workdir /home/user/myproject

# 一次性提醒，并指定权限模式
./cc-cron.sh add "30 14 28 2 *" "Quarterly review reminder" --once --permission-mode auto
```

### 列出任务

```bash
./cc-cron.sh list
```

### 查看日志

```bash
./cc-cron.sh logs <job-id>
```

### 删除任务

```bash
./cc-cron.sh remove <job-id>
```

### 暂停任务

临时禁用任务（不删除）：

```bash
./cc-cron.sh pause <job-id>
```

### 恢复任务

恢复已暂停的任务：

```bash
./cc-cron.sh resume <job-id>
```

### 查看任务详情

显示单个任务的完整信息：

```bash
./cc-cron.sh show <job-id>
```

显示内容包括：
- 任务元数据（ID、创建时间、调度、是否循环、工作目录、模型、权限）
- 完整的提示文本
- 最近执行状态（如有）
- 执行统计（总运行次数、成功/失败次数）

### 查看执行历史

显示任务的执行历史：

```bash
./cc-cron.sh history <job-id> [行数]
```

默认显示 20 行。每条记录显示开始时间、结束时间和状态。

### 立即运行任务

立即执行一次任务（用于测试）：

```bash
./cc-cron.sh run <job-id>
```

此命令同步运行任务并显示输出。

### 编辑任务

修改已有任务的设置：

```bash
./cc-cron.sh edit <job-id> [选项]
```

**选项：**

| 选项 | 说明 |
|--------|-------------|
| `--cron <表达式>` | 更新调度时间 |
| `--prompt <文本>` | 更新提示文本 |
| `--workdir <路径>` | 更新工作目录 |
| `--model <名称>` | 更新模型 |
| `--permission-mode <模式>` | 更新权限模式 |
| `--timeout <秒数>` | 更新超时时间 |

**示例：**
```bash
# 将调度改为每小时执行
./cc-cron.sh edit myjob --cron "0 * * * *"

# 更新提示文本
./cc-cron.sh edit myjob --prompt "新的提示文本"
```

### 导出任务

将任务导出为 JSON 格式，用于备份或迁移：

```bash
# 导出所有任务到标准输出
./cc-cron.sh export

# 导出所有任务到文件
./cc-cron.sh export "" backup.json

# 导出指定任务
./cc-cron.sh export myjob myjob.json
```

导出的 JSON 包含：
- 任务元数据（ID、创建时间、调度、是否循环等）
- 完整的提示文本
- 配置（工作目录、模型、权限模式、超时时间）
- 暂停状态

### 导入任务

从 JSON 文件导入任务：

```bash
./cc-cron.sh import backup.json
```

**注意：** 需要 `jq` 来解析 JSON。安装方式：
- Ubuntu/Debian：`apt-get install jq`
- macOS：`brew install jq`

### 清理旧数据

清理旧日志和孤立文件：

```bash
# 清理 7 天前的文件（默认）
./cc-cron.sh purge

# 清理 30 天前的文件
./cc-cron.sh purge 30

# 预览模式，查看将会删除什么
./cc-cron.sh purge --dry-run
```

purge 命令会删除：
- 超过指定天数的日志文件
- 超过指定天数的历史文件
- 孤立文件（已不在 crontab 中的任务相关文件）

### 查看版本

```bash
./cc-cron.sh version
```

### Bash 自动补全

为命令和任务 ID 启用 Tab 自动补全：

```bash
# 添加到 ~/.bashrc
eval "$(cc-cron completion)"
```

**功能：**
- 命令补全：`add`、`list`、`remove`、`logs`、`status`、`pause`、`resume`、`show`、`history`、`run`、`edit`、`export`、`import`、`purge`、`version`、`completion`
- `remove`、`logs`、`pause`、`resume`、`show`、`history`、`run`、`edit`、`export` 的任务 ID 补全
- 模型名：`sonnet`、`opus`、`haiku`
- 权限模式：`bypassPermissions`、`acceptEdits`、`auto`、`default`
- `--workdir` 的目录补全
- `add` 的常见 cron 表达式提示

### 检查状态

```bash
./cc-cron.sh status
```

显示执行状态（running/success/failure）、时间戳和最近任务结果摘要。

**状态值：**
- `RUNNING` - 任务正在执行
- `SUCCESS` - 任务执行成功
- `FAILED` - 任务以非零退出码结束
- `UNKNOWN` - 无可用状态信息

## 单任务配置与全局配置

每个任务都可以通过命令行选项指定自己的设置。未指定时，任务会回退到环境变量默认值。

| 设置项 | 单任务选项 | 环境变量 | 默认值 |
|---------|----------------|---------------------|---------|
| 工作目录 | `--workdir` | `CC_WORKDIR` | `$HOME` |
| 模型 | `--model` | `CC_MODEL` | Claude 默认 |
| 权限模式 | `--permission-mode` | `CC_PERMISSION_MODE` | `bypassPermissions` |
| 超时 | `--timeout` | `CC_TIMEOUT` | `0`（不超时） |

**优先级：** 单任务选项 > 环境变量 > 内置默认值

## Cron 表达式格式

```
┌───────────── 分钟 (0 - 59)
│ ┌───────────── 小时 (0 - 23)
│ │ ┌───────────── 每月第几天 (1 - 31)
│ │ │ ┌───────────── 月份 (1 - 12)
│ │ │ │ ┌───────────── 星期几 (0 - 6)
│ │ │ │ │
* * * * *
```

## 示例

### 每天下午 5 点进行代码审查
```bash
./cc-cron.sh add "0 17 * * *" "Review today's commits in the main branch"
```

### 每小时状态检查（指定模型）
```bash
./cc-cron.sh add "7 * * * *" "Check system status and report any issues" --model sonnet
```

### 每周一生成报告（自定义工作目录）
```bash
./cc-cron.sh add "0 9 * * 1" "Generate weekly summary report" --workdir /home/user/reports
```

### 项目专用任务
```bash
./cc-cron.sh add "0 12 * * *" "Run tests in the backend project" \
  --workdir /home/user/backend \
  --model opus \
  --permission-mode auto
```

## 说明

- 任务以非交互方式通过 `claude -p` 执行
- 任务会自动 source `~/.bashrc` 和 `~/.bash_profile` 以加载 API key
- 默认权限模式为 `bypassPermissions`（无权限提示）
- 数据存储在 `~/.cc-cron/`：
  - `logs/` - 任务日志和状态文件
  - `locks/` - 目录锁文件
  - `run-*.sh` - 生成的任务运行脚本
- 目录锁可防止在同一目录并发执行 Claude
- 单任务设置会被保存，并在重启后保持
- 一次性任务（`--once`）成功后自动删除；失败时会保留，便于调试/重试

## 开发

### 运行测试

```bash
make test
```

### 代码检查（Lint）

```bash
make lint
```

### 运行全部检查

```bash
make check
```

### 安装

```bash
make install
```
