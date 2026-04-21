param(
    [switch]$Yes,
    [switch]$Uninstall,
    [string]$LombokVersion,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

$DefaultLombokVersion = '1.18.34'
$UserHome = [Environment]::GetFolderPath('UserProfile')
$ConfigDir = Join-Path $UserHome '.config\opencode'
$ConfigFile = Join-Path $ConfigDir 'opencode.json'
$LombokDownloadDir = Join-Path $UserHome '.opencode-jdtls-lombok'
$MavenCentralBaseUrl = 'https://repo1.maven.org/maven2/org/projectlombok/lombok'
$script:TotalSteps = 0
$script:CurrentStep = 0

function Show-Help {
@"
opencode-jdtls-lombok installer (PowerShell)

Usage:
  powershell -File install.ps1
  powershell -File install.ps1 -Yes
  powershell -File install.ps1 -LombokVersion 1.18.34
  powershell -File install.ps1 -Uninstall
  powershell -File install.ps1 -Help
"@
}

function Write-Info($Message)    { Write-Host "ℹ  $Message" -ForegroundColor Blue }
function Write-Success($Message) { Write-Host "✓  $Message" -ForegroundColor Green }
function Write-Warn($Message)    { Write-Host "⚠  $Message" -ForegroundColor Yellow }
function Write-Err($Message)     { Write-Host "✗  $Message" -ForegroundColor Red }
function Write-Action($Message)  { Write-Host "➜  $Message" -ForegroundColor Cyan }
function Write-Hint($Message)    { Write-Host "   $Message" -ForegroundColor DarkGray }

function Step-Title([string]$Title) {
    $script:CurrentStep += 1
    Write-Host ''
    Write-Host "▶ [步骤 $($script:CurrentStep)/$($script:TotalSteps)] $Title" -ForegroundColor Blue
    Write-Host '─────────────────────────────────────────────────────────' -ForegroundColor DarkGray
}

function Show-Banner([string]$Title) {
    Write-Host ''
    Write-Host '╔═══════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
    Write-Host (("║ {0,-57} ║" -f $Title)) -ForegroundColor Cyan
    Write-Host '╚═══════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
}

function Get-Timestamp {
    Get-Date -Format 'yyyyMMddHHmmss'
}

function Get-BackupPath([string]$Path) {
    "$Path.bak.$(Get-Timestamp)"
}

function Test-CanPrompt {
    if (-not [Environment]::UserInteractive) {
        return $false
    }

    try {
        $null = $Host.UI.RawUI
        return $true
    } catch {
        return $false
    }
}

function Confirm-Action([string]$Prompt) {
    if ($Yes) {
        Write-Hint "(-Yes 模式)自动确认: $Prompt"
        return $true
    }

    if (-not (Test-CanPrompt)) {
        throw "当前环境不可交互,请改用 -Yes: $Prompt"
    }

    Write-Host ''
    Write-Host "❓ $Prompt" -ForegroundColor Magenta
    Write-Hint '请输入 y 确认 / N 取消(默认 N,直接回车=取消)'
    $reply = Read-Host '❯'
    return $reply -match '^[Yy]$'
}

function Backup-File([string]$Path) {
    $backup = Get-BackupPath -Path $Path
    Write-Action '💾 正在备份原配置...'
    Copy-Item -Path $Path -Destination $backup -Force
    Write-Success "已备份: $backup"
    Write-Hint "如需回滚,可手动执行: Copy-Item '$backup' '$Path' -Force"
}

function Get-JdtlsCandidates {
    @(
        (Join-Path $UserHome '.local\share\opencode\bin\jdtls\bin\jdtls'),
        (Join-Path $env:LOCALAPPDATA 'Programs\opencode\bin\jdtls\bin\jdtls'),
        (Join-Path $env:ProgramFiles 'opencode\bin\jdtls\bin\jdtls')
    ) | Where-Object { $_ -and $_.Trim() -ne '' }
}

function Find-OpencodeJdtls {
    $candidates = Get-JdtlsCandidates
    Write-Action "🔍 正在搜索 opencode 内置 jdtls (扫描 $($candidates.Count) 个常用安装位置)..."
    foreach ($path in $candidates) {
        Write-Hint "检查: $path"
        if (Test-Path $path) {
            return $path
        }
    }
    throw '找不到 opencode jdtls,请先安装 opencode'
}

function Get-MavenRepository {
    $defaultRepo = Join-Path $UserHome '.m2\repository'
    $mvn = Get-Command mvn -ErrorAction SilentlyContinue
    if (-not $mvn) {
        return $defaultRepo
    }

    try {
        Write-Action '🔍 检测到 mvn 命令,正在解析本地 Maven 仓库路径(可能耗时几秒)...'
        $customRepo = & $mvn.Source help:evaluate -Dexpression=settings.localRepository -q -DforceStdout 2>$null
        if ($customRepo -is [array]) {
            $customRepo = $customRepo | Select-Object -Last 1
        }
        $customRepo = ("$customRepo").Trim()
        if ($customRepo -and (Test-Path $customRepo)) {
            Write-Hint "使用自定义 Maven 仓库: $customRepo"
            return $customRepo
        }
    } catch {
    }

    return $defaultRepo
}

function Find-LocalLombok {
    $mavenRepo = Get-MavenRepository
    $lombokDir = Join-Path $mavenRepo 'org\projectlombok\lombok'
    Write-Action "🔍 在 $lombokDir 中扫描已安装的 Lombok 版本..."

    if (-not (Test-Path $lombokDir)) {
        Write-Hint '目录不存在,跳过本地查找'
        return $null
    }

    $best = $null
    foreach ($dir in (Get-ChildItem -Path $lombokDir -Directory | Sort-Object Name)) {
        $jar = Join-Path $dir.FullName ("lombok-{0}.jar" -f $dir.Name)
        if (Test-Path $jar) {
            $best = $jar
        }
    }
    return $best
}

function Download-Lombok([string]$Version) {
    New-Item -ItemType Directory -Force -Path $LombokDownloadDir | Out-Null
    $targetJar = Join-Path $LombokDownloadDir "lombok-$Version.jar"
    if (Test-Path $targetJar) {
        Write-Info "使用已缓存的 Lombok: $targetJar"
        return $targetJar
    }

    $url = "$MavenCentralBaseUrl/$Version/lombok-$Version.jar"
    Write-Action "⬇️ 即将从 Maven Central 下载 Lombok $Version"
    Write-Hint "源地址: $url"
    Write-Hint "保存到: $targetJar"
    Invoke-WebRequest -Uri $url -OutFile $targetJar
    Write-Success "下载完成: $targetJar"
    return $targetJar
}

function Resolve-LombokJar {
    if ($LombokVersion) {
        Write-Info "用户指定 Lombok 版本: $LombokVersion,跳过本地查找"
        return Download-Lombok -Version $LombokVersion
    }

    $localJar = Find-LocalLombok
    if ($localJar) {
        Write-Success "在本地 Maven 仓库找到: $localJar"
        return $localJar
    }

    Write-Warn "本地 Maven 仓库未找到 Lombok,将下载默认版本 $DefaultLombokVersion"
    return Download-Lombok -Version $DefaultLombokVersion
}

function Read-ConfigObject([string]$Path) {
    if (-not (Test-Path $Path)) {
        return [ordered]@{}
    }

    $raw = Get-Content -Path $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [ordered]@{}
    }

    try {
        $obj = $raw | ConvertFrom-Json -AsHashtable
        if ($null -eq $obj) {
            return [ordered]@{}
        }
        return $obj
    } catch {
        throw "现有 $Path 不是合法 JSON,请先手动修复"
    }
}

function Write-ConfigObject([string]$Path, $Config) {
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $json = $Config | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

function Merge-JdtlsConfig([string]$Path, [string]$JdtlsPath, [string]$LombokJar) {
    $cfg = Read-ConfigObject -Path $Path
    $cfg['$schema'] = 'https://opencode.ai/config.json'
    if (-not $cfg.ContainsKey('lsp') -or $cfg['lsp'] -eq $null) {
        $cfg['lsp'] = [ordered]@{}
    }
    if (-not ($cfg['lsp'] -is [System.Collections.IDictionary])) {
        throw '现有配置中的 lsp 字段不是对象,请先手动修复'
    }
    $cfg['lsp']['jdtls'] = [ordered]@{
        command = @($JdtlsPath, "--jvm-arg=-javaagent:$LombokJar")
        extensions = @('.java')
    }
    Write-ConfigObject -Path $Path -Config $cfg
}

function Remove-JdtlsConfig([string]$Path) {
    $cfg = Read-ConfigObject -Path $Path
    if ($cfg.ContainsKey('lsp') -and ($cfg['lsp'] -is [System.Collections.IDictionary])) {
        $null = $cfg['lsp'].Remove('jdtls')
        if ($cfg['lsp'].Count -eq 0) {
            $null = $cfg.Remove('lsp')
        }
    }
    Write-ConfigObject -Path $Path -Config $cfg
}

function Show-InstallPreview([string]$JdtlsPath, [string]$LombokJar) {
    Write-Info "即将合并写入以下内容到 $ConfigFile:"
    Write-Host ''
    Write-Host '  "lsp": {'
    Write-Host '    "jdtls": {'
    Write-Host '      "command": ['
    Write-Host ("        \"{0}\"," -f $JdtlsPath)
    Write-Host ("        \"--jvm-arg=-javaagent:{0}\"" -f $LombokJar)
    Write-Host '      ],'
    Write-Host '      "extensions": [".java"]'
    Write-Host '    }'
    Write-Host '  }'
    Write-Host ''
    Write-Hint '说明: 这只会修改 lsp.jdtls 段,你已有的其他 opencode 配置都会保留'
    Write-Hint '原 opencode.json 会备份为 opencode.json.bak.<时间戳>'
}

function Invoke-Uninstall {
    $script:CurrentStep = 0
    $script:TotalSteps = 3

    Show-Banner '🧹 opencode jdtls Lombok 卸载向导'
    Write-Host ''
    Write-Host '  本脚本会执行以下操作:'
    Write-Host '    1. 检测 opencode 配置文件是否存在'
    Write-Host '    2. 备份现有 opencode.json'
    Write-Host '    3. 从配置中移除 lsp.jdtls 段'
    Write-Host '    4. (可选) 删除下载的 Lombok jar 缓存目录'
    Write-Host ''
    Write-Host '  过程中会询问你 1~2 次确认,请按提示输入 y/N'

    Step-Title '检测环境'
    Write-Success '操作系统: windows'
    if (-not (Test-Path $ConfigFile)) {
        Write-Warn "opencode 配置不存在($ConfigFile),无需卸载"
        return
    }
    Write-Success "找到配置文件: $ConfigFile"

    Step-Title '移除 lsp.jdtls 配置'
    if (-not (Confirm-Action "确认从 $ConfigFile 中移除 lsp.jdtls 配置?(将先备份)")) {
        Write-Info '已取消,未做任何修改'
        return
    }
    Backup-File -Path $ConfigFile
    Write-Action '正在重写配置文件...'
    Remove-JdtlsConfig -Path $ConfigFile
    Write-Success '已移除 lsp.jdtls 配置'

    Step-Title '清理缓存(可选)'
    if (Test-Path $LombokDownloadDir) {
        if (Confirm-Action "是否同时删除下载的 Lombok jar 目录 $LombokDownloadDir?") {
            Remove-Item -Recurse -Force $LombokDownloadDir
            Write-Success "已删除 $LombokDownloadDir"
        } else {
            Write-Info "保留 $LombokDownloadDir(下次安装可复用)"
        }
    } else {
        Write-Info '无下载缓存目录,跳过'
    }

    Show-Banner '✅ 卸载完成'
    Write-Host ''
    Write-Host '  下一步:'
    Write-Host '    - 退出当前 opencode 会话(Ctrl+C / exit)'
    Write-Host '    - 重新启动 opencode 后生效'
    Write-Host ''
    Write-Host '  重新安装: powershell -File install.ps1'
}

function Invoke-Install {
    $script:CurrentStep = 0
    $script:TotalSteps = 5

    Show-Banner '🚀 opencode jdtls Lombok 集成器'
    Write-Host ''
    Write-Host '  本脚本会自动完成以下事情(整体约耗时 10 秒~1 分钟):'
    Write-Host '    1. 检测当前操作系统'
    Write-Host '    2. 定位 opencode 内置的 jdtls 可执行文件'
    Write-Host '    3. 从本地 Maven 仓库或 Maven Central 获取 Lombok jar'
    Write-Host '    4. 预览即将写入 ~/.config/opencode/opencode.json 的配置'
    Write-Host '    5. 备份原配置并合并写入'
    Write-Host ''
    Write-Host '  你需要做的:'
    Write-Host '    - 在脚本提示 "确认应用?" 时输入 y 回车 (跳过用 -Yes)'
    Write-Host '    - 配置完成后退出并重启 opencode'
    Write-Host ''
    Write-Host '  回滚: powershell -File install.ps1 -Uninstall'

    Step-Title '检测操作系统'
    Write-Success '操作系统: windows'

    Step-Title '查找 opencode 内置 jdtls'
    $jdtlsPath = Find-OpencodeJdtls
    Write-Success "找到 opencode jdtls: $jdtlsPath"

    Step-Title '解析 Lombok jar'
    $lombokJar = Resolve-LombokJar
    Write-Success "Lombok jar: $lombokJar"

    Step-Title '准备 opencode 配置文件'
    if (Test-Path $ConfigFile) {
        $null = Read-ConfigObject -Path $ConfigFile
        Write-Success "现有配置 JSON 合法: $ConfigFile"
        $current = Get-Content -Path $ConfigFile -Raw -Encoding UTF8
        if ($current -match '"jdtls"') {
            Write-Warn '检测到 lsp.jdtls 配置已存在,稍后将被覆盖(原文件会先备份)'
        }
    } else {
        New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
        [System.IO.File]::WriteAllText($ConfigFile, "{}$([Environment]::NewLine)", [System.Text.UTF8Encoding]::new($false))
        Write-Info "未发现现有配置,已创建新文件: $ConfigFile"
    }

    Step-Title '预览并写入配置'
    Show-InstallPreview -JdtlsPath $jdtlsPath -LombokJar $lombokJar
    if (-not (Confirm-Action '确认应用?')) {
        Write-Info '已取消,未做任何修改'
        return
    }

    Backup-File -Path $ConfigFile
    Write-Action '正在合并 JSON 配置...'
    Merge-JdtlsConfig -Path $ConfigFile -JdtlsPath $jdtlsPath -LombokJar $lombokJar
    Write-Success '配置已写入'

    Show-Banner '🎉 安装完成!'
    Write-Host ''
    Write-Host '  下一步(必须):'
    Write-Host '    - 1. 退出当前 opencode 会话 (Ctrl+C / exit)'
    Write-Host '    - 2. 重新启动 opencode'
    Write-Host ''
    Write-Host '  如何验证生效:'
    Write-Host '    - 打开任意 Java 项目,编辑一个带 @Data / @Slf4j 的类'
    Write-Host '    - LSP 不再报 "log cannot be resolved" / "method getXxx() is undefined" 等假阳性'
    Write-Host '    - 若仍有报错,先检查是否真正重启了 opencode'
    Write-Host ''
    Write-Host '  遇到问题:'
    Write-Host '    - 回滚: powershell -File install.ps1 -Uninstall'
    Write-Host "    - 备份文件: $ConfigFile.bak.*"
    Write-Host '    - 升级 Lombok 版本: powershell -File install.ps1 -LombokVersion 1.18.34'
}

if ($Help) {
    Show-Help
    exit 0
}

Write-Host ''
Write-Host '[opencode-jdtls-lombok] 脚本启动中...' -ForegroundColor Cyan

if ($Uninstall) {
    Invoke-Uninstall
} else {
    Invoke-Install
}
