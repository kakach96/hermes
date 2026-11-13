# 赫尔墨斯 v0 —— 一键起停脚本
#
# 用法（在仓库任意位置）：
#   scripts\hermes.cmd up       # NATS + 存储 sidecar + server（已在跑的自动跳过）
#   scripts\hermes.cmd client   # 再开一个客户端窗口（可重复执行 = 双端）
#   scripts\hermes.cmd status   # 端口与进程状态
#   scripts\hermes.cmd down     # 停 server + NATS（客户端窗口不受影响）
#
# 进程一律经 WMI 脱离父进程启动：终端关闭不会带走服务。

param([string]$cmd = "up")

$Root = Split-Path -Parent $PSScriptRoot

# 本机工具链（不在 PATH 时兜底；路径来自 AGENTS.md 记录的本机布局）
$env:Path = "D:\programs\gleam;D:\programs\Erlang\bin;D:\programs\rebar3;$env:USERPROFILE\.cargo\bin;$env:Path"

function Test-Port([int]$port) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $t = $c.BeginConnect("127.0.0.1", $port, $null, $null)
        if ($t.AsyncWaitHandle.WaitOne(400) -and $c.Connected) { return $true }
    } catch { } finally { $c.Close() }
    return $false
}

function Start-Detached([string]$commandLine, [string]$cwd) {
    $r = (Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine = $commandLine; CurrentDirectory = $cwd }).ReturnValue
    if ($r -ne 0) { Write-Host "  启动失败 (WMI rc=$r): $commandLine" -ForegroundColor Red }
    return ($r -eq 0)
}

function Wait-Port([int]$port, [int]$seconds) {
    for ($i = 0; $i -lt ($seconds * 2); $i++) {
        if (Test-Port $port) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Start-Nats {
    if (Test-Port 4222) { Write-Host "NATS        已在跑 (4222)" -ForegroundColor DarkGray; return }
    Write-Host "NATS        启动中..."
    # 注意：WMI CommandLine 不嵌引号 —— 本仓库路径约定不含空格
    [void](Start-Detached "$Root\infra\nats-server.exe -c $Root\infra\nats.conf" $Root)
    if (Wait-Port 4222 10) { Write-Host "NATS        就绪 (4222)" -ForegroundColor Green }
    else { Write-Host "NATS        未监听 4222，查看 infra\boot*.log" -ForegroundColor Red }
}

function Start-Storage {
    $exe = "$Root\storage\target\release\hermes-storage.exe"
    if (Test-Path $exe) { Write-Host "存储 sidecar 已构建" -ForegroundColor DarkGray; return }
    Write-Host "存储 sidecar 首次构建（fjall，纯 Rust，很快）..."
    Push-Location "$Root\storage"
    cargo build --release 2>&1 | Out-Null
    Pop-Location
    if (Test-Path $exe) { Write-Host "存储 sidecar 构建完成" -ForegroundColor Green }
    else { Write-Host "sidecar 构建失败，server 起不来时先看 cargo 输出" -ForegroundColor Red }
}

function Start-Server {
    if (Test-Port 8080) { Write-Host "server      已在跑 (8080)" -ForegroundColor DarkGray; return }
    Write-Host "server      启动中（日志: infra\server.log）..."
    [void](Start-Detached "cmd /c $Root\tools\run_server.cmd" $Root)
    if (Wait-Port 8080 30) { Write-Host "server      就绪 ws://127.0.0.1:8080/ws" -ForegroundColor Green }
    else { Write-Host "server      30 秒未监听 8080，查看 infra\server.log" -ForegroundColor Red }
}

function Start-Client {
    $exe = "$Root\clients\desktop\src-tauri\target\release\hermes-desktop.exe"
    if (-not (Test-Path $exe)) {
        Write-Host "客户端首次构建（Tauri release，几分钟）..."
        Push-Location "$Root\clients\desktop"
        npm run tauri build -- --no-bundle 2>&1 | Out-Null
        Pop-Location
        if (-not (Test-Path $exe)) { Write-Host "客户端构建失败" -ForegroundColor Red; return }
    }
    [void](Start-Detached $exe $Root)
    Write-Host "客户端窗口已打开（多开就再执行一次 client）" -ForegroundColor Green
}

function Stop-Stack {
    Get-Process erl -ErrorAction SilentlyContinue | Stop-Process -Force
    Get-Process nats-server -ErrorAction SilentlyContinue | Stop-Process -Force
    Write-Host "server 与 NATS 已停止（客户端窗口未动）"
}

function Show-Status {
    $nats = Test-Port 4222
    $ws = Test-Port 8080
    $natsProc = Get-Process nats-server -ErrorAction SilentlyContinue | Measure-Object
    $gui = Get-Process hermes-desktop -ErrorAction SilentlyContinue | Measure-Object
    Write-Host ("NATS        : {0}" -f ($(if ($nats) { "运行中 (4222)" } else { "未运行" })))
    Write-Host ("server (WS) : {0}" -f ($(if ($ws) { "运行中 (8080)" } else { "未运行" })))
    Write-Host ("nats 进程   : $($natsProc.Count)")
    Write-Host ("客户端窗口  : $($gui.Count)")
}

switch ($cmd.ToLower()) {
    "up"     { Start-Nats; Start-Storage; Start-Server }
    "client" { Start-Client }
    "down"   { Stop-Stack }
    "status" { Show-Status }
    default  { Write-Host "用法: hermes.cmd up | client | down | status" }
}
