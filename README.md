# opencode-jdtls-lombok

为 [opencode](https://opencode.ai) 内置的 jdtls 注入 Lombok javaagent，**消除 Java 项目中 `@Data` / `@Slf4j` / `@RequiredArgsConstructor` 等 Lombok 注解导致的 LSP 假阳性报错**。

仓库地址：<https://github.com/itguang/opencode-jdtls-lombok>

> 本工具仅在本机修改 opencode 配置，与 LLM 运行时、模型提供方均无关。

---

## 解决了什么

opencode 的 LSP 默认不加载 Lombok 注解处理器，导致编辑 Java 文件后频繁出现以下虚假错误：

```
ERROR The method getXxx() is undefined for the type Foo
ERROR log cannot be resolved
ERROR The constructor Foo(...) is undefined
```

这些错误在 IDEA 或 `mvn compile` 中并不存在。本脚本通过覆盖 opencode 的 jdtls 启动命令，注入 `-javaagent:lombok.jar`，让 LSP 真正识别 Lombok 生成的方法/字段。

---

## 一键安装

**交互式安装（推荐）**：

```bash
curl -fsSL https://raw.githubusercontent.com/itguang/opencode-jdtls-lombok/main/install.sh | bash
```

**非交互安装**（CI 或不想被打扰）：

```bash
curl -fsSL https://raw.githubusercontent.com/itguang/opencode-jdtls-lombok/main/install.sh | bash -s -- --yes
```

**指定 Lombok 版本**：

```bash
curl -fsSL https://raw.githubusercontent.com/itguang/opencode-jdtls-lombok/main/install.sh | bash -s -- --lombok-version 1.18.30
```

> 💡 通过 `curl | bash` 管道执行时，脚本会**自动接管 `/dev/tty`** 用于交互确认，无需额外操作。如果你的环境完全没有 TTY（如某些 CI），脚本会明确报错并提示加 `--yes`。

---

## 安装时你会看到什么

脚本运行后会以分步骤、彩色输出的方式引导你完成安装，整体约耗时 10 秒～1 分钟：

```
[opencode-jdtls-lombok] 脚本启动中...
   检测到 stdin 不是 TTY (管道执行模式),尝试接管 /dev/tty 用于交互...
   ✓ 已接管 /dev/tty,可正常交互

╔═══════════════════════════════════════════════════════════╗
║ 🚀 opencode jdtls Lombok 集成器                           ║
╚═══════════════════════════════════════════════════════════╝

  本脚本会自动完成以下事情(整体约耗时 10 秒~1 分钟):
    1. 检测当前操作系统
    2. 定位 opencode 内置的 jdtls 可执行文件
    3. 从本地 Maven 仓库或 Maven Central 获取 Lombok jar
    4. 预览即将写入 ~/.config/opencode/opencode.json 的配置
    5. 备份原配置并合并写入

  你需要做的:
    ❯ 在脚本提示 "确认应用?" 时输入 y 回车 (跳过用 --yes)
    ❯ 配置完成后退出并重启 opencode

▶ [步骤 1/5] 检测操作系统
─────────────────────────────────────────────────────────
✓  操作系统: macos

▶ [步骤 2/5] 查找 opencode 内置 jdtls
─────────────────────────────────────────────────────────
➜  🔍 正在搜索 opencode 内置 jdtls (扫描 3 个常用安装位置)...
✓  找到 opencode jdtls: /Users/you/.local/share/opencode/bin/jdtls/bin/jdtls

... (步骤 3/4/5 类似) ...

❓ 确认应用?
   请输入 y 确认 / N 取消(默认 N,直接回车=取消)
❯ y

💾 正在备份原配置...
✓  已备份: /Users/you/.config/opencode/opencode.json.bak.20260421120000
✓  配置已写入

╔═══════════════════════════════════════════════════════════╗
║ 🎉 安装完成!                                              ║
╚═══════════════════════════════════════════════════════════╝

  下一步(必须):
    ▸ 1. 退出当前 opencode 会话 (Ctrl+C / exit)
    ▸ 2. 重新启动 opencode
  ...
```

每一步都明确告诉你「正在做什么」、「需要你做什么」、「完成后下一步是什么」，无需猜测。

---

## 安装后

1. **退出当前 opencode 会话**（Ctrl+C / `exit`）
2. **重启 opencode**
3. 打开任意 Java 项目，编辑带 `@Data` / `@Slf4j` 的类，验证 LSP 不再误报 Lombok 假阳性

如果重启后仍然报错，可能是 jdtls workspace 索引缓存陈旧，清掉再试：

```bash
# macOS
rm -rf ~/Library/Caches/jdtls/
# Linux
rm -rf ~/.cache/jdtls/
```

---

## 卸载

**远程一键卸载**：

```bash
curl -fsSL https://raw.githubusercontent.com/itguang/opencode-jdtls-lombok/main/install.sh | bash -s -- --uninstall
```

**本地脚本卸载**：

```bash
bash install.sh --uninstall
# 或非交互
bash install.sh --uninstall --yes
```

卸载向导也是分步骤的，同样有完成总结框。

**卸载行为**：

- 从 `~/.config/opencode/opencode.json` 中移除 `lsp.jdtls` 块（如果移除后 `lsp` 为空对象，会一并删除）。
- 如果之前曾下载过 Lombok jar 到 `~/.opencode-jdtls-lombok/`，会询问是否删除该目录。
- 其他 opencode 配置（`mcp` / `permission` / `provider` 等）原样保留。
- 每次写入前都会自动备份到 `~/.config/opencode/opencode.json.bak.<时间戳>`。

---

## 工作原理

opencode 支持通过 `lsp.<server>.command` 字段覆盖默认的 LSP 启动命令（[官方文档](https://opencode.ai/docs/lsp/#custom-lsp-servers)）。

脚本做的事情：

1. **检测操作系统**：macOS / Linux / WSL，原生 Windows 不支持（请使用 WSL）。
2. **查找 opencode jdtls**：按以下优先级搜索可执行文件：
   - `~/.local/share/opencode/bin/jdtls/bin/jdtls`
   - `/usr/local/share/opencode/bin/jdtls/bin/jdtls`
   - `/opt/opencode/bin/jdtls/bin/jdtls`
3. **解析 Lombok jar 路径**：
   - 优先从本机 Maven 仓库选最高版本（如有 `mvn` 命令，会调用 `mvn help:evaluate -Dexpression=settings.localRepository` 自动解析自定义本地仓库目录）。
   - 找不到则从 Maven Central 下载默认版本 `1.18.34` 到 `~/.opencode-jdtls-lombok/lombok-<version>.jar`。
   - 通过 `--lombok-version` 强制指定版本时，直接从 Maven Central 下载到上述目录。
4. **写入 opencode 配置**：将以下 JSON 合并到 `~/.config/opencode/opencode.json`（不存在则创建）：

```json
{
  "$schema": "https://opencode.ai/config.json",
  "lsp": {
    "jdtls": {
      "command": [
        "/path/to/opencode/bin/jdtls/bin/jdtls",
        "--jvm-arg=-javaagent:/path/to/lombok-x.y.z.jar"
      ],
      "extensions": [".java"]
    }
  }
}
```

5. **安全合并**：使用 `jq` 或 `python3` 做 JSON merge，仅修改 `lsp.jdtls` 块；写入前自动备份原文件到 `opencode.json.bak.<时间戳>`。

opencode 启动 jdtls 时，Java 进程会加载 Lombok agent，编译期注解处理器生效，所有由 Lombok 生成的方法/字段被 LSP 正确识别。

---

## 平台支持

| 系统 | 支持 | opencode jdtls 默认路径 |
|------|------|----------------------|
| macOS | ✅ | `~/.local/share/opencode/bin/jdtls/bin/jdtls` |
| Linux | ✅ | `~/.local/share/opencode/bin/jdtls/bin/jdtls` |
| WSL | ✅ | `~/.local/share/opencode/bin/jdtls/bin/jdtls` |
| 原生 Windows | ❌ | 请使用 WSL |

> 脚本同时会检查 `/usr/local/share/opencode/bin/jdtls/bin/jdtls` 与 `/opt/opencode/bin/jdtls/bin/jdtls`，覆盖部分系统级安装方式。

---

## 依赖

- `bash` 3.2+（macOS 自带版本可直接运行，无需升级）
- `jq` **或** `python3`（任选其一，用于安全合并 JSON 配置）
- `curl` 或 `wget`（仅当本地 `~/.m2` 没有 Lombok 且未通过 `--lombok-version` 命中已下载缓存时需要）
- `mvn`（可选，用于解析 `~/.m2/settings.xml` 中自定义的 `<localRepository>`，无 `mvn` 时回退到默认 `~/.m2/repository`）

macOS 用户如果没有 jq：

```bash
brew install jq
```

通常 macOS / Linux 自带 python3，无需额外安装。

---

## 文件清单

脚本运行后可能涉及的文件/目录：

| 路径 | 用途 | 卸载是否清理 |
|------|------|------------|
| `~/.config/opencode/opencode.json` | opencode 配置文件，注入/移除 `lsp.jdtls` 块 | 仅移除 `lsp.jdtls`，文件保留 |
| `~/.config/opencode/opencode.json.bak.<时间戳>` | 写入前自动备份 | 保留（手动清理） |
| `~/.opencode-jdtls-lombok/lombok-<version>.jar` | 从 Maven Central 下载的 Lombok jar 缓存 | 卸载时询问是否删除 |

---

## 命令参考

```
bash install.sh [OPTIONS]

OPTIONS:
  -y, --yes                     跳过所有交互确认（非交互模式下输出会明确提示自动确认了什么）
  --lombok-version <version>    强制使用指定 Lombok 版本（从 Maven Central 下载）
  --uninstall                   卸载（移除 lsp.jdtls 配置）
  -h, --help                    显示帮助
```

**退出码**：

- `0`：成功 / 用户主动取消
- `1`：环境问题（无 TTY 又未带 `--yes`、找不到 jdtls、依赖缺失、JSON 损坏等）

---

## FAQ

### Q1：本地有多个 Lombok 版本，会用哪个？

脚本扫描 `~/.m2/repository/org/projectlombok/lombok/`（或 `mvn` 解析出的自定义仓库目录）下所有版本目录，选**最高版本**（按 `sort -V` 语义版本排序）。如果想强制指定，使用 `--lombok-version`。

### Q2：我的本地 Maven 仓库不在 `~/.m2`，怎么办？

脚本会调用 `mvn help:evaluate -Dexpression=settings.localRepository` 自动解析 `~/.m2/settings.xml` 中配置的 `<localRepository>`，无需手工干预。如果本机没装 `mvn`，会回退到默认 `~/.m2/repository`。

### Q3：为什么不做成 opencode plugin？

[opencode plugin 文档](https://opencode.ai/docs/plugins/) 列出的 LSP 事件只有 `lsp.client.diagnostics`（被动接收诊断）和 `lsp.updated`（状态变化），**没有任何"修改 LSP 启动命令"的钩子**。即便能拦截 diagnostics 事件，也只能在 opencode 内部消化，无法阻止错误信息回传给 AI 模型上下文。所以唯一可行的口子就是 `lsp.command` 配置覆盖。

### Q4：会影响其他 opencode 配置吗？

不会。脚本使用 jq / python3 安全 merge JSON，仅修改 `lsp.jdtls` 块，且每次写入前自动备份。`mcp` / `permission` / `provider` 等配置原样保留。

### Q5：支持升级吗？

直接重跑安装命令即可。脚本会检测已有配置并提示「将被覆盖（原文件会先备份）」，自动选用本地 Maven 仓库中新版本的 Lombok jar。

### Q6：Lombok 版本和我项目用的不一致会有问题吗？

**通常不会**。Lombok agent 仅做编译期注解处理，与项目运行时 classpath 无关。jdtls 加载哪个版本的 Lombok agent 决定了 LSP 能识别哪些注解语法，所有近年版本（1.18.20+）的注解集合基本一致。极少数情况（项目使用最新预览注解）下可能不识别，此时用 `--lombok-version` 指定项目用的版本即可。

### Q7：opencode 配置文件不存在怎么办？

脚本会自动创建 `~/.config/opencode/opencode.json`（写入空 `{}` 后再 merge）。同时会注入 `$schema: "https://opencode.ai/config.json"`，方便编辑器获得 schema 提示。

### Q8：如果 opencode 安装在非默认路径怎么办？

当前脚本搜索路径写在 `find_opencode_jdtls()` 函数的 `candidates` 数组中（`~/.local/share/opencode`、`/usr/local/share/opencode`、`/opt/opencode`）。如果你的 opencode 装在其他位置，目前需要手动修改 `install.sh` 中的该数组。后续如有需要可加 `--jdtls-path` 参数支持。

### Q9：`curl ... | bash` 执行后完全静默，没有任何输出怎么办？

99% 是 GitHub raw 的 CDN 缓存命中了旧版本（缓存时间约 5 分钟）。两种处理方式：

```bash
# 方案 1: 加时间戳绕过 CDN 缓存
curl -fsSL "https://raw.githubusercontent.com/itguang/opencode-jdtls-lombok/main/install.sh?t=$(date +%s)" | bash

# 方案 2: 改用 process substitution，stdin 仍是 TTY,行为最稳定
bash <(curl -fsSL https://raw.githubusercontent.com/itguang/opencode-jdtls-lombok/main/install.sh)
```

最新版脚本启动后会**立即**输出一行 `[opencode-jdtls-lombok] 脚本启动中...`，如果你看到这行就说明脚本正常运行；如果连这行都没有，则一定是缓存或网络问题。

### Q10：在 CI / Docker / 完全无 TTY 的环境里怎么用？

脚本检测到既无 stdin TTY、也无 `/dev/tty` 时，会在需要交互的地方明确报错并退出，提示你加 `--yes`。CI 中正确用法：

```bash
curl -fsSL https://raw.githubusercontent.com/itguang/opencode-jdtls-lombok/main/install.sh | bash -s -- --yes
```

`--yes` 模式下脚本会逐条输出 `(--yes 模式)自动确认: <动作>`，便于在日志中审计实际跳过了哪些确认。

---

## 反馈与贡献

欢迎提 Issue / PR：<https://github.com/itguang/opencode-jdtls-lombok/issues>

---

## License

MIT
