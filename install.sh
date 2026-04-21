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

set -euo pipefail

# ---------- 常量 ----------
DEFAULT_LOMBOK_VERSION="1.18.34"   # 当本地 ~/.m2 没有时,从 Maven Central 下载的版本
LOMBOK_DOWNLOAD_DIR="$HOME/.opencode-jdtls-lombok"
MAVEN_CENTRAL_URL="https://repo1.maven.org/maven2/org/projectlombok/lombok"

# ---------- 颜色输出 ----------
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()     { echo -e "${RED}[ERR ]${NC}  $*" >&2; }
die()     { err "$*"; exit 1; }

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
            grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) die "未知参数: $1 (使用 --help 查看用法)" ;;
    esac
done

confirm() {
    $ASSUME_YES && return 0
    local prompt="$1"
    read -r -p "$(echo -e "${YELLOW}?${NC} $prompt [y/N] ")" reply
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
    for path in "${candidates[@]}"; do
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
        local custom_repo
        custom_repo="$(mvn help:evaluate -Dexpression=settings.localRepository -q -DforceStdout 2>/dev/null || true)"
        if [[ -n "$custom_repo" && -d "$custom_repo" ]]; then
            maven_repo="$custom_repo"
        fi
    fi

    local lombok_dir="$maven_repo/org/projectlombok/lombok"
    [[ -d "$lombok_dir" ]] || return 1

    # 选最高版本(纯版本号目录,排除 _remote.repositories 等文件)
    local best_version=""
    while IFS= read -r ver; do
        [[ -f "$lombok_dir/$ver/lombok-$ver.jar" ]] || continue
        if [[ -z "$best_version" ]] || [[ "$(printf '%s\n%s\n' "$best_version" "$ver" | sort -V | tail -1)" == "$ver" ]]; then
            best_version="$ver"
        fi
    done < <(ls -1 "$lombok_dir" 2>/dev/null)

    [[ -n "$best_version" ]] || return 1
    echo "$lombok_dir/$best_version/lombok-$best_version.jar"
}

download_lombok() {
    local version="$1"
    local target_dir="$LOMBOK_DOWNLOAD_DIR"
    local target_jar="$target_dir/lombok-$version.jar"
    if [[ -f "$target_jar" ]]; then
        echo "$target_jar"
        return 0
    fi

    mkdir -p "$target_dir"
    local url="$MAVEN_CENTRAL_URL/$version/lombok-$version.jar"
    info "下载 Lombok $version 自 $url" >&2
    if command -v curl >/dev/null 2>&1; then
        curl -fSL --progress-bar "$url" -o "$target_jar.tmp" >&2 || die "下载失败: $url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --show-progress "$url" -O "$target_jar.tmp" >&2 || die "下载失败: $url"
    else
        die "未找到 curl 或 wget,无法下载 Lombok"
    fi
    mv "$target_jar.tmp" "$target_jar"
    echo "$target_jar"
}

resolve_lombok_jar() {
    if [[ -n "$LOMBOK_VERSION_OVERRIDE" ]]; then
        download_lombok "$LOMBOK_VERSION_OVERRIDE"
        return
    fi
    local local_jar
    if local_jar="$(find_local_lombok)"; then
        info "在本地 Maven 仓库找到: $local_jar" >&2
        echo "$local_jar"
    else
        warn "本地 Maven 仓库未找到 Lombok,将从 Maven Central 下载 $DEFAULT_LOMBOK_VERSION" >&2
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
    cp "$file" "$backup"
    info "已备份原配置: $backup"
}

# ---------- 主流程 ----------
main() {
    info "opencode jdtls Lombok 集成器"
    echo

    local os; os="$(detect_os)"
    info "操作系统: $os"

    local jdtls_path
    if ! jdtls_path="$(find_opencode_jdtls)"; then
        die "找不到 opencode jdtls,请先安装 opencode (https://opencode.ai/docs/)"
    fi
    success "找到 opencode jdtls: $jdtls_path"

    # opencode 配置目录
    local config_dir="$HOME/.config/opencode"
    local config_file="$config_dir/opencode.json"
    mkdir -p "$config_dir"

    if [[ "$ACTION" == "uninstall" ]]; then
        if [[ ! -f "$config_file" ]]; then
            warn "opencode 配置不存在,无需卸载"
            exit 0
        fi
        confirm "确认从 $config_file 中移除 lsp.jdtls 配置?" || { info "取消"; exit 0; }
        backup_file "$config_file"
        remove_jdtls_from_config "$config_file"
        success "已移除 lsp.jdtls 配置"
        if [[ -d "$LOMBOK_DOWNLOAD_DIR" ]]; then
            if confirm "是否同时删除下载的 Lombok jar 目录 $LOMBOK_DOWNLOAD_DIR?"; then
                rm -rf "$LOMBOK_DOWNLOAD_DIR"
                success "已删除 $LOMBOK_DOWNLOAD_DIR"
            fi
        fi
        info "重启 opencode 后生效"
        exit 0
    fi

    local lombok_jar; lombok_jar="$(resolve_lombok_jar)"
    success "Lombok jar: $lombok_jar"

    # 配置文件不存在则创建空 JSON
    if [[ ! -f "$config_file" ]]; then
        echo '{}' > "$config_file"
        info "创建新配置: $config_file"
    else
        # 校验现有配置是 JSON
        if ! python3 -c "import json,sys; json.load(open('$config_file'))" 2>/dev/null \
           && ! (command -v jq >/dev/null && jq empty "$config_file" 2>/dev/null); then
            die "现有 $config_file 不是合法 JSON,请先手动修复"
        fi
        # 检查是否已配置过
        if grep -q '"jdtls"' "$config_file" 2>/dev/null; then
            warn "检测到 lsp.jdtls 配置已存在,将覆盖"
        fi
    fi

    echo
    info "即将写入以下配置到 $config_file:"
    cat <<EOF
  "lsp": {
    "jdtls": {
      "command": [
        "$jdtls_path",
        "--jvm-arg=-javaagent:$lombok_jar"
      ],
      "extensions": [".java"]
    }
  }
EOF
    echo
    confirm "确认应用?" || { info "取消"; exit 0; }

    backup_file "$config_file"
    merge_config "$config_file" "$jdtls_path" "$lombok_jar"
    success "配置已写入"

    echo
    info "下一步:"
    echo "  1. 退出当前 opencode 会话(Ctrl+C / exit)"
    echo "  2. 重新启动 opencode"
    echo "  3. 打开任意 Java 项目验证: 编辑带 @Data/@Slf4j 的类,LSP 应不再报 Lombok 假阳性"
    echo
    info "回滚: bash $0 --uninstall"
}

main "$@"
