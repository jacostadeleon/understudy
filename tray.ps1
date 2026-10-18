# understudy tray (Windows)
# - green/red dot in the system tray showing proxy status
# - right-click menu: start/stop proxy, launch Claude Code, pick routed model
# - model pick applies instantly (proxy re-reads selected.json, no restart)

param(
  [string]$Dir = $PSScriptRoot
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$ProxyPid = $null
$LastError = ""
$AutoStarted = $false

# ---------- helpers ----------

function Get-ConfigModels {
  $cfgPath = Join-Path $Dir "config.json"
  try {
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $models = @()
    if ($cfg.models) {
      foreach ($prop in $cfg.models.PSObject.Properties) {
        $models += [pscustomobject]@{
          provider = if ($prop.Value.provider) { $prop.Value.provider } else { $cfg.default_provider }
          model = $prop.Name
          label = if ($prop.Value.label) { $prop.Value.label } else { $prop.Name }
        }
      }
    }
    return , $models
  } catch {
    return , @()
  }
}

function Get-SelectedJsonPath { Join-Path $Dir "selected.json" }

function Set-Selection([string]$Provider, [string]$Model) {
  @{
    provider = $Provider
    model = $Model
  } | ConvertTo-Json -Compress | Set-Content -Path (Get-SelectedJsonPath) -Encoding UTF8
}

function Clear-Selection {
  @{ default = $true } | ConvertTo-Json -Compress | Set-Content -Path (Get-SelectedJsonPath) -Encoding UTF8
}

function Get-SelectionLabel {
  try {
    $sel = Get-Content (Get-SelectedJsonPath) -Raw -ErrorAction Stop | ConvertFrom-Json
    if ($sel.default) { return "default (Claude haiku)" }
    if ($sel.model) { return $sel.model }
  } catch {}
  return "unset"
}

function Get-Health {
  try {
    $resp = Invoke-RestMethod -Uri "http://127.0.0.1:8793/healthz" -TimeoutSec 3
    return $resp
  } catch {
    return $null
  }
}

function Test-PortFree {
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $iar = $client.BeginConnect("127.0.0.1", 8793, $null, $null)
    $ok = $iar.AsyncWaitHandle.WaitOne(400)
    if (-not $ok) { return $true }
    $client.EndConnect($iar)
    return $false
  } catch {
    return $true
  } finally {
    $client.Close()
  }
}

function Start-Proxy {
  if (-not (Test-PortFree)) { return $true }
  $nodeExe = "node.exe"
  $found = Get-Command $nodeExe -ErrorAction SilentlyContinue
  if (-not $found) {
    $script:LastError = "node.exe not found in PATH"
    return $false
  }
  $proc = Start-Process -FilePath $found.Source `
    -ArgumentList "`"$(Join-Path $Dir 'proxy.mjs')`"" `
    -WindowStyle Hidden -PassThru
  $script:ProxyPid = $proc.Id
  $script:AutoStarted = $true
  return $true
}

function Stop-Proxy {
  $running = Get-Health
  if ($running) {
    try {
      Invoke-RestMethod -Uri "http://127.0.0.1:8793/shutdown" -Method Post -TimeoutSec 3 | Out-Null
    } catch {}
  }
  if ($script:ProxyPid) {
    try { Stop-Process -Id $script:ProxyPid -Force -ErrorAction SilentlyContinue } catch {}
    $script:ProxyPid = $null
  }
  # wait briefly for the port to clear
  for ($i = 0; $i -lt 10; $i++) {
    if (Test-PortFree) { break }
    Start-Sleep -Milliseconds 200
  }
}

function Launch-Claude {
  $inner = @"
`$env:ANTHROPIC_BASE_URL = 'http://127.0.0.1:8793'
`$env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'
Set-Location -Path '$Dir'
claude
Write-Host ''
Write-Host '[claude exited - this window can be closed]'
Read-Host 'press enter to close'
"@
  $bytes = [System.Text.Encoding]::Unicode.GetBytes($inner)
  $enc = [Convert]::ToBase64String($bytes)
  Start-Process powershell -ArgumentList "-NoLogo", "-EncodedCommand", $enc
}

function Show-Journal {
  $logPath = Join-Path $env:TEMP "understudy-journal.txt"
  $health = Get-Health
  $lines = @()
  $lines += "understudy journal - $(Get-Date -Format s)"
  $lines += ""
  if ($health) {
    $lines += "proxy: RUNNING (uptime $($health.uptimeSec)s)"
    $lines += "passthrough: $($health.passthrough)"
    $lines += "providers: $($health.providers -join ', ')"
    if ($health.selected.default) { $lines += "selected: default (Claude haiku)" }
    else { $lines += "selected: $($health.selected.provider)/$($health.selected.model)" }
  } else {
    $lines += "proxy: STOPPED"
  }
  if ($script:LastError) { $lines += "last error: $($script:LastError)" }
  if ($script:ProxyPid) { $lines += "spawned proxy pid: $($script:ProxyPid)" }
  $lines += ""
  $lines += "(the proxy console is hidden when started from the tray;"
  $lines += " run node proxy.mjs in a terminal to see request logs live)"
  Set-Content -Path $logPath -Value $lines -Encoding UTF8
  Start-Process notepad -ArgumentList "`"$logPath`""
}

# ---------- icons ----------

function New-DotIcon([System.Drawing.Color]$color) {
  $bmp = New-Object System.Drawing.Bitmap 16, 16
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $brush = New-Object System.Drawing.SolidBrush $color
  $g.FillEllipse($brush, 3, 3, 10, 10)
  $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::Gray), 1
  $g.DrawEllipse($pen, 3, 3, 10, 10)
  $g.Dispose()
  $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
  $bmp.Dispose()
  return $icon
}

$GreenIcon = New-DotIcon ([System.Drawing.Color]::LimeGreen)
$RedIcon = New-DotIcon ([System.Drawing.Color]::IndianRed)
$OrangeIcon = New-DotIcon ([System.Drawing.Color]::Orange)

# ---------- tray UI ----------

$form = New-Object System.Windows.Forms.Form
$form.WindowState = "Minimized"
$form.ShowInTaskbar = $false
$form.FormBorderStyle = "None"
$form.StartPosition = "Manual"
$form.Location = New-Object System.Drawing.Point(-32000, -32000)
$form.Show()
$form.Hide()

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = $OrangeIcon
$notify.Text = "understudy: starting..."
$notify.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip

$miStatusHeader = New-Object System.Windows.Forms.ToolStripMenuItem ("understudy - checking...")
$miStatusHeader.Enabled = $false
$menu.Items.Add($miStatusHeader) | Out-Null
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$miModel = New-Object System.Windows.Forms.ToolStripMenuItem "Route this project via"
$miModels = New-Object System.Windows.Forms.ToolStripMenuItem
$menu.Items.Add($miModel) | Out-Null

$sep1 = New-Object System.Windows.Forms.ToolStripSeparator
$menu.Items.Add($sep1) | Out-Null

$miLaunch = $menu.Items.Add("Launch Claude Code here")
$miJournal = $menu.Items.Add("Show journal")
$miRefresh = $menu.Items.Add("Refresh status")
$miStopStart = $menu.Items.Add("Start proxy")
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$miExit = $menu.Items.Add("Exit (keeps proxy running)")

function Build-ModelMenu {
  $miModels.DropDownItems.Clear()

  $miDefault = New-Object System.Windows.Forms.ToolStripMenuItem "&default (unrouted, Claude haiku)"
  $miDefault.Tag = "__default__"
  $miDefault.Add_Click({
      Clear-Selection
      Update-Tray $true
    })
  $miModels.DropDownItems.Add($miDefault) | Out-Null
  $miModels.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

  foreach ($m in (Get-ConfigModels)) {
    $label = "$($m.label)  [$($m.provider)]"
    $item = New-Object System.Windows.Forms.ToolStripMenuItem $label
    $item.Tag = "$($m.provider)|$($m.model)"
    $item.Add_Click({
        $parts = $this.Tag.Split("|", 2)
        Set-Selection $parts[0] $parts[1]
        Update-Tray $true
      })
    $miModels.DropDownItems.Add($item) | Out-Null
  }

  $miModel.DropDown = $miModels.DropDown
}

function Update-Tray([switch]$Ping) {
  $health = $null
  if ($Ping) { $health = Get-Health }

  if ($health) {
    $script:LastError = ""
    $selLabel = ""
    if ($health.selected.default) { $selLabel = "default (Claude haiku)" }
    elseif ($health.selected.model) { $selLabel = "$($health.selected.provider)/$($health.selected.model)" }
    else { $selLabel = "not configured" }

    $notify.Icon = $GreenIcon
    $notify.Text = "understudy: running - $selLabel"
    $miStatusHeader.Text = "RUNNING - routing: $selLabel"
    $miStopStart.Text = "Stop proxy"
    $miStopStart.Tag = "stop"
  } else {
    if (-not (Test-PortFree)) {
      # port busy but health failed - starting up or wedged
      $notify.Icon = $OrangeIcon
      $notify.Text = "understudy: not responding"
      $miStatusHeader.Text = "NOT RESPONDING on 127.0.0.1:8793"
      $miStopStart.Text = "Start proxy"
      $miStopStart.Tag = "start"
    } else {
      $msg = if ($script:LastError) { $script:LastError } else { "stopped" }
      $notify.Icon = $RedIcon
      $notify.Text = "understudy: stopped"
      $miStatusHeader.Text = "STOPPED - $msg"
      $miStopStart.Text = "Start proxy"
      $miStopStart.Tag = "start"
    }
  }

  Build-ModelMenu
  $currentSel = Get-SelectionLabel
  foreach ($entry in $miModels.DropDownItems) {
    if ($entry -is [System.Windows.Forms.ToolStripMenuItem]) {
      if ($entry.Tag -eq "__default__") {
        $entry.Checked = ($currentSel -eq "default (Claude haiku)")
      } elseif ($entry.Tag) {
        $entry.Checked = ($currentSel.EndsWith(([string]$entry.Tag.Split("|", 2)[1])))
      }
    }
  }
}

# ---------- menu actions ----------

$miStopStart.Add_Click({
    if ($miStopStart.Tag -eq "start") {
      $beforeWasDown = $null -eq (Get-Health)
      if (Start-Proxy) {
        for ($i = 0; $i -lt 20; $i++) {
          Start-Sleep -Milliseconds 250
          if (Get-Health) { break }
        }
        Update-Tray -Ping
        if (Get-Health) { $notify.ShowBalloonTip(2500, "understudy", "proxy started on 127.0.0.1:8793", "Info") }
      }
    } else {
      Stop-Proxy
      Update-Tray -Ping
    }
  })

$miLaunch.Add_Click({
    if ($null -eq (Get-Health)) {
      if (Start-Proxy) {
        for ($i = 0; $i -lt 20; $i++) {
          Start-Sleep -Milliseconds 250
          if (Get-Health) { break }
        }
        Update-Tray -Ping
      }
    }
    Launch-Claude
  })

$miJournal.Add_Click({ Show-Journal })
$miRefresh.Add_Click({ Update-Tray -Ping })

$miExit.Add_Click({
    $notify.Visible = $false
    $form.Close()
    [System.Windows.Forms.Application]::Exit()
  })

$notify.ContextMenuStrip = $menu
$notify.Add_DoubleClick({ Launch-Claude })

# ---------- status poller ----------

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({ Update-Tray -Ping })
$timer.Start()

# auto-start the proxy on tray launch unless it is already up
if ($null -eq (Get-Health)) {
  if (Start-Proxy) {
    for ($i = 0; $i -lt 20; $i++) {
      Start-Sleep -Milliseconds 250
      if (Get-Health) { break }
    }
  }
}
Update-Tray -Ping

$form.SendToBack()
[System.Windows.Forms.Application]::Run($form)

# cleanup when the tray loop exits
try {
  $notify.Visible = $false
  $notify.Dispose()
} catch {}
