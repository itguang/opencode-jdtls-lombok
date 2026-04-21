#!/usr/bin/env bash
#
# opencode-jdtls-lombok installer
#
# 为 opencode 内置的 jdtls 注入 Lombok javaagent,消除 Java 项目中
# @Data / @Slf4j / @RequiredArgsConstructor 等 Lombok 注解导致的 LSP 假阳性。
#
# 使用:
#   bash install.sh                      # 交互式安装
#   bash install.sh --yes                # 跳过所有确认
#   bash install.sh --lombok-version 1.18.34
#   bash install.sh --uninstall          # 卸载
#

set -uo pipefail

# 立即给出一行输出,确认脚本已开始执行(便于排查 curl|bash 卡住的问题)
printf '\n\033[1;36m[opencode-jdtls-lombok] 脚本启动中...\033[0m\n'

# ---------- 修复管道执行 (curl ... | bash) 时 stdin 被占用导致 read 取不到输入 ----------
# 必须在 set -e 之前完成 stdin 重接,否则 exec 失败会直接静默退出。
PIPED_EXEC=false
NO_TTY=false
if [[ ! -t 0 ]]; then
    printf '\033[2m   检测到 stdin 不是 TTY (管道执行模式),尝试接管 /dev/tty 用于交互...\033[0m\n'
    # 先验证 /dev/tty 可读,再 exec(避免 bash 自己打印 "Device not configured")
    if [[ -e /dev/tty ]] && (exec </dev/tty) 2>/dev/null; then
        exec </dev/tty
        PIPED_EXEC=true
        printf '\033[0;32m   ✓ 已接管 /dev/tty,可正常交互\033[0m\n'
    else
        NO_TTY=true
        printf '\033[1;33m   ⚠ 无法打开 /dev/tty,将进入非交互模式(需配合 --yes)\033[0m\n'
    fi
fi

# 现在再开启 -e
set -e

# ---------- 常量 ----------
DEFAULT_LOMBOK_VERSION="1.18.34"   # 当本地 ~/.m2 没有时,从 Maven Central 下载的版本
LOMBOK_DOWNLOAD_DIR="$HOME/.opencode-jdtls-lombok"
MAVEN_CENTRAL_URL="https://repo1.maven.org/maven2/org/projectlombok/lombok"

# ---------- 颜色输出 ----------
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
    BOLD='\033[1m'; DIM='\033[2m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; DIM=''; CYAN=''; MAGENTA=''; NC=''
fi

info()    { echo -e "${BLUE}ℹ${NC}  $*"; }
success() { echo -e "${GREEN}✓${NC}  $*"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $*"; }
err()     { echo -e "${RED}✗${NC}  $*" >&2; }
die()     { err "$*"; exit 1; }
action()  { echo -e "${CYAN}➜${NC}  $*"; }   # 正在做某件事(短暂等待)
hint()    { echo -e "${DIM}   $*${NC}"; }    # 灰色辅助说明
prompt_h(){ echo -e "${MAGENTA}❓${NC} ${BOLD}$*${NC}"; }  # 需要用户操作的提示

# 步骤标题: step 1/5 标题
TOTAL_STEPS=0
CURRENT_STEP=0
step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    echo
    echo -e "${BOLD}${BLUE}▶ [步骤 ${CURRENT_STEP}/${TOTAL_STEPS}]${NC} ${BOLD}$*${NC}"
    echo -e "${DIM}─────────────────────────────────────────────────────────${NC}"
}

# 区块标题(用于欢迎页/总结页)
banner() {
    local title="$1"
    echo
    echo -e "${BOLD}${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
    printf "${BOLD}${CYAN}║${NC} ${BOLD}%-57s${NC} ${BOLD}${CYAN}║${NC}\n" "$title"
    echo -e "${BOLD}${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
}

# ---------- 参数解析 ----------
ASSUME_YES=false
LOMBOK_VERSION_OVERRIDE=""
ACTION="install"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)             ASSUME_YES=true; shift ;;
        --lombok-version)     LOMBOK_VERSION_OVERRIDE="$2"; shift 2 ;;
        --uninstall)          ACTION="uninstall"; shift ;;
        -h|--help)
            # 只输出文件头的说明块(到第一行非注释/空行为止)
            awk 'NR==1 && /^#!/{next} /^#/{sub(/^# ?/,""); print; next} /^[[:space:]]*$/{print; next} {exit}' "$0"
            exit 0 ;;
        *) die "未知参数: $1 (使用 --help 查看用法)" ;;
    esac
done

confirm() {
    if $ASSUME_YES; then
        hint "(--yes 模式)自动确认: $1"
        return 0
    fi
    if $NO_TTY; then
        err "无可用 TTY,无法交互确认: $1"
        err "请改用以下方式之一重新执行:"
        err "  1) bash <(curl -fsSL <脚本URL>)         # 推荐,保留交互"
        err "  2) curl -fsSL <脚本URL> | bash -s -- --yes   # 跳过所有确认"
        exit 1
    fi
    local prompt="$1"
    echo
    prompt_h "$prompt"
    hint "请输入 y 确认 / N 取消(默认 N,直接回车=取消)"
    read -r -p "$(echo -e "${MAGENTA}❯${NC} ")" reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# ---------- 操作系统检测 ----------
detect_os() {
    case "$(uname -s)" in
        Darwin)              echo "macos" ;;
        Linux)
            # WSL 与原生 Linux 路径一致,opencode 安装路径都是 ~/.local/share/opencode
            if grep -qi "microsoft" /proc/version 2>/dev/null; then
                echo "wsl"
            else
                echo "linux"
            fi ;;
        MINGW*|MSYS*|CYGWIN*) die "原生 Windows 不支持,请使用 WSL" ;;
        *) die "未识别的操作系统: $(uname -s)" ;;
    esac
}

# ---------- 查找 opencode jdtls ----------
# 不同安装方式可能放在不同位置,按优先级搜索
find_opencode_jdtls() {
    local candidates=(
        "$HOME/.local/share/opencode/bin/jdtls/bin/jdtls"
        "/usr/local/share/opencode/bin/jdtls/bin/jdtls"
        "/opt/opencode/bin/jdtls/bin/jdtls"
    )
    action "🔍 正在搜索 opencode 内置 jdtls (扫描 ${#candidates[@]} 个常用安装位置)..." >&2
    for path in "${candidates[@]}"; do
        hint "检查: $path" >&2
        if [[ -x "$path" ]]; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

# ---------- 查找/获取 Lombok jar ----------
# 优先从本地 Maven 仓库选最高版本,没有则从 Maven Central 下载默认版本
find_local_lombok() {
    # 支持自定义 ~/.m2/settings.xml 中的 localRepository
    local maven_repo="$HOME/.m2/repository"
    if command -v mvn >/dev/null 2>&1; then
        action "🔍 检测到 mvn 命令,正在解析本地 Maven 仓库路径(可能耗时几秒)..." >&2
        local custom_repo
        custom_repo="$(mvn help:evaluate -Dexpression=settings.localRepository -q -DforceStdout 2>/dev/null || true)"
        if [[ -n "$custom_repo" && -d "$custom_repo" ]]; then
            maven_repo="$custom_repo"
            hint "使用自定义 Maven 仓库: $maven_repo" >&2
        fi
    fi

    local lombok_dir="$maven_repo/org/projectlombok/lombok"
    action "🔍 在 $lombok_dir 中扫描已安装的 Lombok 版本..." >&2
    [[ -d "$lombok_dir" ]] || { hint "目录不存在,跳过本地查找" >&2; return 1; }

    # 选最高版本(纯版本号目录,排除 _remote.repositories 等文件)
    local best_version=""
    while IFS= read -r ver; do
        [[ -f "$lombok_dir/$ver/lombok-$ver.jar" ]] || continue
        if [[ -z "$best_version" ]] || [[ "$(printf '%s\n%s\n' "$best_version" "$ver" | sort -V | tail -1)" == "$ver" ]]; then
            best_version="$ver"
        fi
    done < <(ls -1 "$lombok_dir" 2>/dev/null)

    [[ -n "$best_version" ]] || { hint "未找到任何 Lombok 版本" >&2; return 1; }
    echo "$lombok_dir/$best_version/lombok-$best_version.jar"
}

download_lombok() {
    local version="$1"
    local target_dir="$LOMBOK_DOWNLOAD_DIR"
    local target_jar="$target_dir/lombok-$version.jar"
    if [[ -f "$target_jar" ]]; then
        info "使用已缓存的 Lombok: $target_jar" >&2
        echo "$target_jar"
        return 0
    fi

    mkdir -p "$target_dir"
    local url="$MAVEN_CENTRAL_URL/$version/lombok-$version.jar"
    echo >&2
    action "⬇️  即将从 Maven Central 下载 Lombok $version" >&2
    hint "源地址: $url" >&2
    hint "保存到: $target_jar" >&2
    hint "文件约 2 MB,正常网络几秒可完成,过程中可见进度条..." >&2
    echo >&2
    if command -v curl >/dev/null 2>&1; then
        curl -fSL --progress-bar "$url" -o "$target_jar.tmp" >&2 || die "下载失败: $url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --show-progress "$url" -O "$target_jar.tmp" >&2 || die "下载失败: $url"
    else
        die "未找到 curl 或 wget,无法下载 Lombok"
    fi
    mv "$target_jar.tmp" "$target_jar"
    success "✅ 下载完成: $target_jar" >&2
    echo "$target_jar"
}

resolve_lombok_jar() {
    if [[ -n "$LOMBOK_VERSION_OVERRIDE" ]]; then
        info "用户指定 Lombok 版本: $LOMBOK_VERSION_OVERRIDE,跳过本地查找" >&2
        download_lombok "$LOMBOK_VERSION_OVERRIDE"
        return
    fi
    local local_jar
    if local_jar="$(find_local_lombok)"; then
        success "在本地 Maven 仓库找到: $local_jar" >&2
        echo "$local_jar"
    else
        warn "本地 Maven 仓库未找到 Lombok,将从 Maven Central 下载默认版本 $DEFAULT_LOMBOK_VERSION" >&2
        download_lombok "$DEFAULT_LOMBOK_VERSION"
    fi
}

# ---------- JSON 合并 ----------
# 优先 jq,回退 python3
merge_config() {
    local config_file="$1"
    local jdtls_path="$2"
    local lombok_jar="$3"

    if command -v jq >/dev/null 2>&1; then
        merge_with_jq "$config_file" "$jdtls_path" "$lombok_jar"
    elif command -v python3 >/dev/null 2>&1; then
        merge_with_python "$config_file" "$jdtls_path" "$lombok_jar"
    else
        die "需要 jq 或 python3 来合并 JSON 配置 (brew install jq)"
    fi
}

merge_with_jq() {
    local config_file="$1" jdtls_path="$2" lombok_jar="$3"
    local tmp; tmp="$(mktemp)"
    jq \
        --arg jdtls "$jdtls_path" \
        --arg agent "-javaagent:$lombok_jar" \
        '. + {
            "$schema": "https://opencode.ai/config.json",
            lsp: ((.lsp // {}) + {
                jdtls: ((.lsp.jdtls // {}) + {
                    command: [$jdtls, ("--jvm-arg=" + $agent)],
                    extensions: ((.lsp.jdtls.extensions // [".java"]))
                })
            })
        }' "$config_file" > "$tmp"
    mv "$tmp" "$config_file"
}

merge_with_python() {
    local config_file="$1" jdtls_path="$2" lombok_jar="$3"
    OPENCODE_JDTLS_PATH="$jdtls_path" \
    OPENCODE_LOMBOK_JAR="$lombok_jar" \
    OPENCODE_CONFIG="$config_file" \
    python3 - <<'PY'
import json, os, sys
cfg_path = os.environ["OPENCODE_CONFIG"]
jdtls   = os.environ["OPENCODE_JDTLS_PATH"]
lombok  = os.environ["OPENCODE_LOMBOK_JAR"]
with open(cfg_path) as f:
    cfg = json.load(f)
cfg.setdefault("$schema", "https://opencode.ai/config.json")
lsp = cfg.setdefault("lsp", {})
jdtls_cfg = lsp.setdefault("jdtls", {})
jdtls_cfg["command"] = [jdtls, f"--jvm-arg=-javaagent:{lombok}"]
jdtls_cfg.setdefault("extensions", [".java"])
with open(cfg_path, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
}

# ---------- 卸载: 从 opencode.json 中移除 lsp.jdtls ----------
remove_jdtls_from_config() {
    local config_file="$1"
    if command -v jq >/dev/null 2>&1; then
        local tmp; tmp="$(mktemp)"
        jq 'if .lsp then (.lsp |= del(.jdtls)
                        | if (.lsp | length) == 0 then del(.lsp) else . end)
            else . end' "$config_file" > "$tmp"
        mv "$tmp" "$config_file"
    elif command -v python3 >/dev/null 2>&1; then
        OPENCODE_CONFIG="$config_file" python3 - <<'PY'
import json, os
p = os.environ["OPENCODE_CONFIG"]
with open(p) as f: cfg = json.load(f)
lsp = cfg.get("lsp")
if isinstance(lsp, dict):
    lsp.pop("jdtls", None)
    if not lsp:
        cfg.pop("lsp")
with open(p, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False); f.write("\n")
PY
    else
        die "需要 jq 或 python3"
    fi
}

# ---------- 备份 ----------
backup_file() {
    local file="$1"
    local backup="${file}.bak.$(date +%Y%m%d%H%M%S)"
    action "💾 正在备份原配置..."
    cp "$file" "$backup"
    success "已备份: $backup"
    hint "如需回滚,可手动执行: cp \"$backup\" \"$file\""
}

# ---------- 主流程 ----------
main() {
    if [[ "$ACTION" == "uninstall" ]]; then
        TOTAL_STEPS=3
        banner "🧹 opencode jdtls Lombok 卸载向导"
        if $PIPED_EXEC; then
            echo
            info "检测到管道执行模式 (curl|bash),已自动接管 /dev/tty 用于交互"
        fi
        cat <<EOF

  本脚本会执行以下操作:
    ${CYAN}1.${NC} 检测 opencode 配置文件是否存在
    ${CYAN}2.${NC} 备份现有 opencode.json
    ${CYAN}3.${NC} 从配置中移除 lsp.jdtls 段
    ${CYAN}4.${NC} (可选) 删除下载的 Lombok jar 缓存目录

  ${DIM}过程中会询问你 1~2 次确认,请按提示输入 y/N${NC}
EOF

        step "检测环境"
        local os; os="$(detect_os)"
        success "操作系统: $os"

        local config_dir="$HOME/.config/opencode"
        local config_file="$config_dir/opencode.json"
        if [[ ! -f "$config_file" ]]; then
            warn "opencode 配置不存在($config_file),无需卸载"
            exit 0
        fi
        success "找到配置文件: $config_file"

        step "移除 lsp.jdtls 配置"
        confirm "确认从 $config_file 中移除 lsp.jdtls 配置?(将先备份)" \
            || { info "已取消,未做任何修改"; exit 0; }
        backup_file "$config_file"
        action "正在重写配置文件..."
        remove_jdtls_from_config "$config_file"
        success "已移除 lsp.jdtls 配置"

        step "清理缓存(可选)"
        if [[ -d "$LOMBOK_DOWNLOAD_DIR" ]]; then
            if confirm "是否同时删除下载的 Lombok jar 目录 $LOMBOK_DOWNLOAD_DIR?"; then
                rm -rf "$LOMBOK_DOWNLOAD_DIR"
                success "已删除 $LOMBOK_DOWNLOAD_DIR"
            else
                info "保留 $LOMBOK_DOWNLOAD_DIR(下次安装可复用)"
            fi
        else
            info "无下载缓存目录,跳过"
        fi

        banner "✅ 卸载完成"
        cat <<EOF

  ${BOLD}下一步:${NC}
    ${CYAN}▸${NC} 退出当前 opencode 会话(Ctrl+C / exit)
    ${CYAN}▸${NC} 重新启动 opencode 后生效

  ${BOLD}重新安装:${NC} bash $0
EOF
        echo
        exit 0
    fi

    # ===== 安装流程 =====
    TOTAL_STEPS=5
    banner "🚀 opencode jdtls Lombok 集成器"
    if $PIPED_EXEC; then
        echo
        info "检测到管道执行模式 (curl|bash),已自动接管 /dev/tty 用于交互"
    fi
    cat <<EOF

  本脚本会自动完成以下事情(整体约耗时 10 秒~1 分钟):
    ${CYAN}1.${NC} 检测当前操作系统
    ${CYAN}2.${NC} 定位 opencode 内置的 jdtls 可执行文件
    ${CYAN}3.${NC} 从本地 Maven 仓库或 Maven Central 获取 Lombok jar
    ${CYAN}4.${NC} 预览即将写入 ~/.config/opencode/opencode.json 的配置
    ${CYAN}5.${NC} 备份原配置并合并写入

  ${BOLD}你需要做的:${NC}
    ${MAGENTA}❯${NC} 在脚本提示 "确认应用?" 时输入 y 回车 (跳过用 --yes)
    ${MAGENTA}❯${NC} 配置完成后退出并重启 opencode

  ${DIM}回滚: bash $0 --uninstall${NC}
EOF

    step "检测操作系统"
    local os; os="$(detect_os)"
    success "操作系统: $os"

    step "查找 opencode 内置 jdtls"
    local jdtls_path
    if ! jdtls_path="$(find_opencode_jdtls)"; then
        die "找不到 opencode jdtls,请先安装 opencode (https://opencode.ai/docs/)"
    fi
    success "找到 opencode jdtls: $jdtls_path"

    step "解析 Lombok jar"
    local lombok_jar; lombok_jar="$(resolve_lombok_jar)"
    success "Lombok jar: $lombok_jar"

    # opencode 配置目录
    local config_dir="$HOME/.config/opencode"
    local config_file="$config_dir/opencode.json"
    mkdir -p "$config_dir"

    step "准备 opencode 配置文件"
    # 配置文件不存在则创建空 JSON
    if [[ ! -f "$config_file" ]]; then
        echo '{}' > "$config_file"
        info "未发现现有配置,已创建新文件: $config_file"
    else
        info "找到现有配置: $config_file"
        # 校验现有配置是 JSON
        action "校验 JSON 合法性..."
        if ! python3 -c "import json,sys; json.load(open('$config_file'))" 2>/dev/null \
           && ! (command -v jq >/dev/null && jq empty "$config_file" 2>/dev/null); then
            die "现有 $config_file 不是合法 JSON,请先手动修复"
        fi
        success "现有配置 JSON 合法"
        # 检查是否已配置过
        if grep -q '"jdtls"' "$config_file" 2>/dev/null; then
            warn "检测到 lsp.jdtls 配置已存在,稍后将被覆盖(原文件会先备份)"
        fi
    fi

    step "预览并写入配置"
    info "即将合并写入以下内容到 $config_file:"
    echo
    cat <<EOF
${DIM}  "lsp": {
    "jdtls": {
      "command": [
        "$jdtls_path",
        "--jvm-arg=-javaagent:$lombok_jar"
      ],
      "extensions": [".java"]
    }
  }${NC}
EOF
    echo
    hint "说明: 这只会修改 lsp.jdtls 段,你已有的其他 opencode 配置都会保留"
    hint "原 opencode.json 会备份为 opencode.json.bak.<时间戳>"
    confirm "确认应用?" || { info "已取消,未做任何修改"; exit 0; }

    backup_file "$config_file"
    action "正在合并 JSON 配置..."
    merge_config "$config_file" "$jdtls_path" "$lombok_jar"
    success "配置已写入"

    banner "🎉 安装完成!"
    cat <<EOF

  ${BOLD}下一步(必须):${NC}
    ${CYAN}▸${NC} ${BOLD}1.${NC} 退出当前 opencode 会话 (Ctrl+C / exit)
    ${CYAN}▸${NC} ${BOLD}2.${NC} 重新启动 opencode

  ${BOLD}如何验证生效:${NC}
    ${CYAN}▸${NC} 打开任意 Java 项目,编辑一个带 ${YELLOW}@Data${NC} / ${YELLOW}@Slf4j${NC} 的类
    ${CYAN}▸${NC} LSP 不再报 "log cannot be resolved" / "method getXxx() is undefined" 等假阳性
    ${CYAN}▸${NC} 若仍有报错,先检查是否真正重启了 opencode

  ${BOLD}遇到问题:${NC}
    ${CYAN}▸${NC} 回滚: ${YELLOW}bash $0 --uninstall${NC}
    ${CYAN}▸${NC} 备份文件: $config_file.bak.*
    ${CYAN}▸${NC} 升级 Lombok 版本: ${YELLOW}bash $0 --lombok-version 1.18.34${NC}
EOF
    echo
}

main "$@"
