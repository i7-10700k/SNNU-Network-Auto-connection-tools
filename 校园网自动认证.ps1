# =====================================================================
#  校园网自动认证工具  (陕西师范大学 SNNU Portal / Dr.COM-深澜架构)
# ---------------------------------------------------------------------
#  用途：连上校园网后自动完成 Portal 认证，并自动选择"移动代拨"。
#
#  常用命令：
#    .\校园网自动认证.ps1 -Action Setup      # 首次配置（输入账号密码）
#    .\校园网自动认证.ps1                     # 后台守护：掉线就自动认证
#    .\校园网自动认证.ps1 -Action Login       # 立刻认证一次
#    .\校园网自动认证.ps1 -Action Status      # 查看当前状态
#    .\校园网自动认证.ps1 -Action Logout      # 主动断开
#    .\校园网自动认证.ps1 -Action Diagnose    # 抓取登录页，排查问题
#    .\校园网自动认证.ps1 -Action Install     # 注册开机自启
#    .\校园网自动认证.ps1 -Action Uninstall   # 取消开机自启
# =====================================================================

[CmdletBinding()]
param(
    [ValidateSet('Run','UI','Setup','Login','Status','Logout','Diagnose','Install','Uninstall','Stop','StopAll','SelfTest')]
    [string]$Action = 'Run',

    # 调试用：只跑一轮就退出
    [switch]$Once,

    # 配合 -Action StopAll：顺便询问是否断开当前网络登录
    [switch]$Disconnect
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------
# 基础路径
# ---------------------------------------------------------------------
$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptDir)) { $ScriptDir = (Get-Location).Path }

$ConfigPath   = Join-Path $ScriptDir 'config.json'
$LogDir       = Join-Path $ScriptDir 'logs'
$LogPath      = Join-Path $LogDir 'auto-login.log'
$PidPath      = Join-Path $LogDir 'daemon.pid'
$TaskName     = '校园网自动认证'

# 启动文件夹快捷方式（不需要管理员权限，作为计划任务失败时的备选）
$StartupDir   = [Environment]::GetFolderPath('Startup')
$StartupLnk   = Join-Path $StartupDir '校园网自动认证.lnk'

# 门户入口（80 端口页面里带着真正的登录页地址），若失效会自动重新探测
$PortalEntry  = 'http://202.117.144.205/'
$PortalBase   = 'http://202.117.144.205:8602/snnuportal/'

$UserAgent    = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36'
$HttpTimeout  = 10

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

# ---------------------------------------------------------------------
# 日志
# ---------------------------------------------------------------------
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','OK','WARN','ERROR','DEBUG')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8

    # 日志超过 1MB 自动截断，避免无限增长
    try {
        $fi = Get-Item -LiteralPath $LogPath
        if ($fi.Length -gt 1MB) {
            $tail = Get-Content -LiteralPath $LogPath -Tail 500
            Set-Content -LiteralPath $LogPath -Value $tail -Encoding UTF8
        }
    } catch { }
}

function Write-Console {
    param(
        [string]$Message,
        [string]$Color = 'Gray'
    )
    Write-Host $Message -ForegroundColor $Color
}

# ---------------------------------------------------------------------
# 配置读写
# ---------------------------------------------------------------------
function Get-DefaultConfig {
    [ordered]@{
        portalEntry          = $PortalEntry
        portalBase           = $PortalBase
        account              = ''
        passwordSec          = ''      # DPAPI 加密（仅当前 Windows 用户可解），-Setup 自动写入
        passwordPlain        = ''      # 明文（不推荐，仅在没有 passwordSec 时使用）
        service              = 'mobile'  # 代拨方式：campus=校园网 / mobile=移动 / unicom=联通 / telecom=电信
        accountWithSuffix    = 'auto'    # auto | always | never ：是否用 账号@mobile 形式提交
        checkIntervalSeconds = 45        # 在线时的巡检间隔（秒）
        retryIntervalSeconds = 10        # 掉线后的重试间隔（秒）
        maxLoginAttempts     = 2         # 单次掉线最多尝试几轮（避免连续输错触发风控）
    }
}

function Get-Config {
    $default = Get-DefaultConfig
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        $default | ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
        return $default
    }
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($k in $default.Keys) {
        if (-not ($cfg.PSObject.Properties.Name -contains $k)) {
            $cfg | Add-Member -NotePropertyName $k -NotePropertyValue $default[$k] -Force
        }
    }
    return $cfg
}

function Save-Config {
    param($Config)
    $Config | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

function Get-ConfigPassword {
    param($Config)
    if (-not [string]::IsNullOrEmpty($Config.passwordSec)) {
        try {
            $ss = ConvertTo-SecureString -String $Config.passwordSec
            return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR(
                [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss))
        } catch {
            Write-Log '配置中的密码无法解密（可能换了 Windows 用户），请重新执行 -Action Setup' 'ERROR'
            return $null
        }
    }
    if (-not [string]::IsNullOrEmpty($Config.passwordPlain)) { return $Config.passwordPlain }
    return $null
}

# ---------------------------------------------------------------------
# 小工具函数
# ---------------------------------------------------------------------
function ConvertTo-UrlEncodedBody {
    param(
        [Parameter(Mandatory)]$Data,
        [string]$Charset = 'gb2312'
    )
    $enc = [System.Text.Encoding]::GetEncoding($Charset)
    $sb = New-Object System.Text.StringBuilder
    $first = $true
    foreach ($key in $Data.Keys) {
        if (-not $first) { [void]$sb.Append('&') }
        $first = $false

        foreach ($b in [System.Text.Encoding]::ASCII.GetBytes([string]$key)) {
            if (($b -ge 48 -and $b -le 57) -or ($b -ge 65 -and $b -le 90) -or
                ($b -ge 97 -and $b -le 122) -or $b -eq 45 -or $b -eq 95 -or
                $b -eq 46 -or $b -eq 126) {
                [void]$sb.Append([char]$b)
            } else {
                [void]$sb.AppendFormat('%{0:X2}', $b)
            }
        }
        [void]$sb.Append('=')

        foreach ($b in $enc.GetBytes([string]$Data[$key])) {
            if (($b -ge 48 -and $b -le 57) -or ($b -ge 65 -and $b -le 90) -or
                ($b -ge 97 -and $b -le 122) -or $b -eq 45 -or $b -eq 95 -or
                $b -eq 46 -or $b -eq 126) {
                [void]$sb.Append([char]$b)
            } else {
                [void]$sb.AppendFormat('%{0:X2}', $b)
            }
        }
    }
    return $sb.ToString()
}

function Get-HtmlAttribute {
    param([string]$TagText)
    $result = @{}
    $regex = [regex]'(?is)([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*("([^"]*)"|''([^'']*)''|([^\s>]+))'
    foreach ($m in $regex.Matches($TagText)) {
        $name = $m.Groups[1].Value.ToLower()
        $value = ''
        if ($m.Groups[3].Success)     { $value = $m.Groups[3].Value }
        elseif ($m.Groups[4].Success) { $value = $m.Groups[4].Value }
        elseif ($m.Groups[5].Success) { $value = $m.Groups[5].Value }
        $result[$name] = $value
    }
    return $result
}

function Get-Request {
    param(
        [Parameter(Mandatory)][string]$Uri,
        $Session,
        [int]$TimeoutSec = $HttpTimeout,
        [int]$MaxRedirect = 5
    )
    $params = @{
        Uri                = $Uri
        UseBasicParsing    = $true
        TimeoutSec         = $TimeoutSec
        MaximumRedirection = $MaxRedirect
        UserAgent          = $UserAgent
        Headers            = @{ 'Accept' = 'text/html,application/xhtml+xml,*/*' }
    }
    if ($Session) { $params['WebSession'] = $Session }
    return Invoke-WebRequest @params
}

function Get-FinalUri {
    param($Response)
    try {
        if ($Response.BaseResponse -and $Response.BaseResponse.ResponseUri) {
            return $Response.BaseResponse.ResponseUri.AbsoluteUri
        }
    } catch { }
    try { return $Response.BaseUri.AbsoluteUri } catch { }
    return ''
}

# ---------------------------------------------------------------------
# 登录表单解析（不硬编码 action，跟随门户实际页面）
# ---------------------------------------------------------------------
function Get-LoginForm {
    <#
        从登录页 HTML 中解析出：
          ActionUri : 表单提交地址（相对地址转成绝对地址）
          Method    : POST / GET
          Fields    : 隐藏域与文本框 name=value
          Radios    : 单选组 name -> @( @{ value; label } )
    #>
    param(
        [Parameter(Mandatory)][string]$Html,
        [Parameter(Mandatory)][string]$BaseUri
    )

    $formRegex = [regex]'(?is)<form\b([^>]*)>(.*?)</form>'
    $target = $null
    foreach ($m in $formRegex.Matches($Html)) {
        $bodyText = $m.Groups[2].Value
        if ($bodyText -match '(?i)name\s*=\s*["'']?(account|user_name|username|login)["'']?' -or
            $bodyText -match '(?i)name\s*=\s*["'']?(password|passwd|user_password)["'']?') {
            $target = $m
            break
        }
    }
    if (-not $target) { return $null }

    $formAttrs = Get-HtmlAttribute $target.Groups[1].Value
    $action = ''
    if ($formAttrs.ContainsKey('action')) { $action = $formAttrs['action'] }
    if ([string]::IsNullOrWhiteSpace($action)) { $action = $BaseUri }
    $actionUri = $BaseUri
    try { $actionUri = (New-Object System.Uri((New-Object System.Uri($BaseUri)), $action)).AbsoluteUri } catch { }

    $method = 'POST'
    if ($formAttrs.ContainsKey('method') -and $formAttrs['method'].ToUpper() -eq 'GET') { $method = 'GET' }

    $body = $target.Groups[2].Value
    $fields = [ordered]@{}
    $radios = [ordered]@{}

    foreach ($im in [regex]::Matches($body, '(?is)<input\b([^>]*)/?>')) {
        $attrs = Get-HtmlAttribute $im.Groups[1].Value
        if (-not $attrs.ContainsKey('name') -or $attrs['name'] -eq '') { continue }
        $name = $attrs['name']
        $type = 'text'
        if ($attrs.ContainsKey('type')) { $type = $attrs['type'].ToLower() }
        $value = ''
        if ($attrs.ContainsKey('value')) { $value = $attrs['value'] }

        if ($type -eq 'radio') {
            if (-not $radios.Contains($name)) { $radios[$name] = New-Object System.Collections.ArrayList }
            $tail = $body.Substring($im.Index + $im.Length)
            $nextIdx = $tail.IndexOf('<input', [System.StringComparison]::OrdinalIgnoreCase)
            if ($nextIdx -ge 0) { $tail = $tail.Substring(0, $nextIdx) }
            if ($tail.Length -gt 200) { $tail = $tail.Substring(0, 200) }
            $label = ($tail -replace '(?s)<[^>]*>', ' ')
            $label = ($label -replace '\s+', ' ').Trim()
            if ($label.Length -gt 40) { $label = $label.Substring(0, 40) }
            [void]$radios[$name].Add([pscustomobject]@{ value = $value; label = $label })
        }
        elseif ($type -eq 'checkbox' -or $type -eq 'submit' -or $type -eq 'button') {
            # 记住密码之类的复选框、按钮都不参与认证提交
        }
        else {
            $fields[$name] = $value
        }
    }

    # 下拉框取选中项
    foreach ($sm in [regex]::Matches($body, '(?is)<select\b([^>]*)>(.*?)</select>')) {
        $sattrs = Get-HtmlAttribute $sm.Groups[1].Value
        if (-not $sattrs.ContainsKey('name')) { continue }
        $sval = ''
        $sel = [regex]::Match($sm.Groups[2].Value, '(?is)<option\b([^>]*)>')
        if ($sel.Success) {
            $oattrs = Get-HtmlAttribute $sel.Groups[1].Value
            if ($oattrs.ContainsKey('value')) { $sval = $oattrs['value'] }
        }
        $fields[$sattrs['name']] = $sval
    }

    return [pscustomobject]@{
        ActionUri = $actionUri
        Method    = $method
        Fields    = $fields
        Radios    = $radios
    }
}

function Resolve-ServiceValue {
    <# 根据"移动/联通/电信/校园网"等字样，找出对应的单选值 #>
    param(
        [Parameter(Mandatory)][string]$Service,
        $Radios
    )
    if (-not $Radios -or $Radios.Count -eq 0) { return $null }

    $keywordMap = @{
        'mobile'  = @('移动','mobile')
        '移动'    = @('移动','mobile')
        'unicom'  = @('联通','unicom')
        '联通'    = @('联通','unicom')
        'telecom' = @('电信','telecom')
        '电信'    = @('电信','telecom')
        '校园网'  = @('校园网','教育网','snnu','campus','plain')
        'plain'   = @('校园网','教育网','snnu','campus','plain')
        'campus'  = @('校园网','教育网','snnu','campus','plain')
    }
    $keys = @($Service)
    $lower = $Service.ToLower()
    if ($keywordMap.ContainsKey($lower))      { $keys = $keywordMap[$lower] }
    elseif ($keywordMap.ContainsKey($Service)) { $keys = $keywordMap[$Service] }

    foreach ($gname in $Radios.Keys) {
        foreach ($r in $Radios[$gname]) {
            foreach ($kw in $keys) {
                if ($r.label -like "*$kw*" -or $r.value -like "*$kw*") {
                    return [pscustomobject]@{ Group = $gname; Value = $r.value }
                }
            }
        }
    }
    return $null
}

# ---------------------------------------------------------------------
# 门户交互
# ---------------------------------------------------------------------
function Resolve-PortalBase {
    <# 访问门户入口页，从它内嵌的 JS 跳转里找出真正的登录页目录 #>
    param([string]$Entry = $PortalEntry)
    try {
        $r = Get-Request -Uri $Entry -TimeoutSec $HttpTimeout -MaxRedirect 3
    } catch {
        return $null
    }
    $m = [regex]::Match($r.Content, "(?i)window\.location(?:\.href)?\s*=\s*['""]([^'""]+)['""]")
    $target = ''
    if ($m.Success) { $target = $m.Groups[1].Value }
    elseif ($r.Content -match '(?i)<meta[^>]+http-equiv=["'']?refresh["'']?[^>]+url=([^"''>\s]+)') {
        $target = $Matches[1]
    }
    if ([string]::IsNullOrWhiteSpace($target)) { return $null }

    try {
        $abs = (New-Object System.Uri((New-Object System.Uri($Entry)), $target)).AbsoluteUri
    } catch { return $null }

    $idx = $abs.LastIndexOf('/')
    if ($idx -ge 0) { return $abs.Substring(0, $idx + 1) }
    return $abs
}

function Get-PortalState {
    <#
        返回：
          online   -> 已认证
          offline  -> 未认证（附带登录页 HTML 与解析出的表单）
          unknown  -> 门户不可达/响应异常
    #>
    param(
        [string]$Base = $PortalBase,
        $Session
    )
    $loginUrl = ($Base.TrimEnd('/')) + '/login.jsp'
    try {
        $r = Get-Request -Uri $loginUrl -Session $Session -TimeoutSec $HttpTimeout -MaxRedirect 5
    } catch {
        $loc = ''
        try {
            $resp = $_.Exception.Response
            if ($resp -and $resp.Headers['Location']) {
                $loc = $resp.Headers['Location']
                if ($loc -is [array]) { $loc = $loc[0] }
            }
        } catch { }
        if ($loc -match 'userstatus') { return [pscustomobject]@{ State='online'; Html=''; Form=$null } }
        return [pscustomobject]@{ State='unknown'; Html=''; Form=$null; Error=$_.Exception.Message }
    }

    $final = Get-FinalUri $r
    if ($final -match 'userstatus') {
        return [pscustomobject]@{ State='online'; Html=$r.Content; Form=$null }
    }
    $form = Get-LoginForm -Html $r.Content -BaseUri $final
    if ($form) {
        return [pscustomobject]@{ State='offline'; Html=$r.Content; Form=$form }
    }
    return [pscustomobject]@{ State='unknown'; Html=$r.Content; Form=$null; Error=('未找到登录表单，最终地址 ' + $final) }
}

function Test-Internet {
    param([int]$TimeoutSec = 5)
    $targets = @(
        @{ Uri = 'http://connect.rom.miui.com/generate_204'; Expect = 204 },
        @{ Uri = 'http://www.baidu.com/';                    Expect = 200 }
    )
    foreach ($t in $targets) {
        try {
            $r = Get-Request -Uri $t.Uri -TimeoutSec $TimeoutSec -MaxRedirect 3
            if ($r.StatusCode -ne $t.Expect) { continue }
            # 被校园网拦截时返回的会是门户页面
            if ($r.Content -match '(?i)snnuportal|login\.jsp|auth_my_state') { continue }
            return $true
        } catch { }
    }
    return $false
}

function Try-PortalLogin {
    <# 返回 @{ Success = $true/$false; Message = '...' } #>
    param(
        [Parameter(Mandatory)]$Config,
        $Session,
        [string]$Base = $PortalBase
    )

    $account  = [string]$Config.account
    $password = Get-ConfigPassword $Config
    if ([string]::IsNullOrEmpty($account) -or [string]::IsNullOrEmpty($password)) {
        return @{ Success = $false; Message = '还没有可用的账号或密码，请先填写账号和密码' }
    }

    $state = Get-PortalState -Base $Base -Session $Session
    if ($state.State -eq 'online')  { return @{ Success = $true;  Message = '当前已在线，无需认证' } }
    if ($state.State -eq 'unknown' -and [string]::IsNullOrEmpty($state.Html)) {
        return @{ Success = $false; Message = ('无法打开认证页面：' + $state.Error) }
    }

    # ---- 候选提交地址：优先用页面里真实的 form action，其次用内置候选兜底 ----
    $baseDir = $Base.TrimEnd('/') + '/'
    $candidates = New-Object System.Collections.ArrayList
    if ($state.State -eq 'offline' -and $state.Form) {
        [void]$candidates.Add([pscustomobject]@{
            Uri = $state.Form.ActionUri; Method = $state.Form.Method
            Fields = $state.Form.Fields; Radios = $state.Form.Radios; From = '页面表单'
        })
    }
    foreach ($guess in @('login', 'login.jsp')) {
        $u = $baseDir + $guess
        $dup = $false
        foreach ($c in $candidates) { if ($c.Uri -eq $u) { $dup = $true } }
        if (-not $dup) {
            [void]$candidates.Add([pscustomobject]@{
                Uri = $u; Method = 'POST'; Fields = [ordered]@{}; Radios = [ordered]@{}; From = '内置候选'
            })
        }
    }

    # 代拨取值（内置候选用）
    $serviceValueMap = @{
        'mobile' = 'mobile'; 'unicom' = 'unicom'; 'telecom' = 'telecom'; 'campus' = ''
        '移动'   = 'mobile'; '联通'   = 'unicom'; '电信'    = 'telecom'; '校园网'  = ''
    }
    $plainServiceValue = ''
    $svcKey = ([string]$Config.service).ToLower()
    if ($serviceValueMap.ContainsKey($svcKey)) { $plainServiceValue = $serviceValueMap[$svcKey] }
    elseif ($serviceValueMap.ContainsKey([string]$Config.service)) { $plainServiceValue = $serviceValueMap[[string]$Config.service] }
    else { $plainServiceValue = [string]$Config.service }

    # 密码含非 ASCII 时，额外准备 UTF-8 编码的重试
    $charsets = @('gb2312')
    if ($password -match '[^\x00-\x7F]') { $charsets += 'utf-8' }

    $lastMsg   = '认证失败'
    $attempted = 0
    $maxPost   = 4

    foreach ($cand in $candidates) {
        if ($attempted -ge $maxPost) { break }

        $fields = [ordered]@{}
        foreach ($k in $cand.Fields.Keys) { $fields[$k] = $cand.Fields[$k] }

        # 账号 / 密码字段名自适应
        $accountField  = 'account'
        $passwordField = 'password'
        $hasCheckcode  = $false
        foreach ($k in $cand.Fields.Keys) {
            if ($k -match '(?i)^(account|user_name|username|login)$') { $accountField = $k }
            if ($k -match '(?i)^(password|passwd|user_password)$')    { $passwordField = $k }
            if ($k -match '(?i)^checkcode$')                          { $hasCheckcode = $true }
        }

        # 代拨方式：优先取页面里的单选值，内置候选时按映射传 yys
        $svc = Resolve-ServiceValue -Service ([string]$Config.service) -Radios $cand.Radios
        $suffix = ''
        if ($svc -and -not [string]::IsNullOrEmpty($svc.Value)) {
            $fields[$svc.Group] = $svc.Value
            $suffix = '@' + $svc.Value
        } elseif ($plainServiceValue) {
            $fields['yys'] = $plainServiceValue
            $suffix = '@' + $plainServiceValue
        }

        $variants = @([pscustomobject]@{ Desc = '账号原样'; Account = $account })
        if ($suffix -and ([string]$Config.accountWithSuffix) -ne 'never') {
            $variants += [pscustomobject]@{ Desc = ('账号带后缀 ' + $suffix); Account = $account + $suffix }
        }

        foreach ($v in $variants) {
            foreach ($cs in $charsets) {
                if ($attempted -ge $maxPost) { break }

                $postBody = [ordered]@{}
                foreach ($k in $fields.Keys) { $postBody[$k] = $fields[$k] }
                $postBody[$accountField]  = $v.Account
                $postBody[$passwordField] = $password

                $encoded = ConvertTo-UrlEncodedBody -Data $postBody -Charset $cs
                $bytes = [System.Text.Encoding]::ASCII.GetBytes($encoded)
                $attempted++

                $desc = ('{0} / {1} / {2}' -f $cand.From, $v.Desc, $cs)
                Write-Log ('提交认证：{0} -> {1}' -f $desc, $cand.Uri) 'INFO'

                $r = $null
                $final = ''
                try {
                    $r = Invoke-WebRequest -Uri $cand.Uri -Method $cand.Method -Body $bytes `
                            -ContentType 'application/x-www-form-urlencoded' -WebSession $Session `
                            -UseBasicParsing -MaximumRedirection 5 -TimeoutSec ($HttpTimeout + 5) `
                            -UserAgent $UserAgent
                    $final = Get-FinalUri $r
                } catch {
                    $loc = ''
                    try {
                        $resp = $_.Exception.Response
                        if ($resp -and $resp.Headers['Location']) {
                            $loc = $resp.Headers['Location']
                            if ($loc -is [array]) { $loc = $loc[0] }
                        }
                    } catch { }
                    if ($loc) { $final = $loc }
                    else {
                        $lastMsg = '提交失败：' + $_.Exception.Message
                        Write-Log ($desc + ' ' + $lastMsg) 'ERROR'
                        continue
                    }
                }

                $body = ''
                if ($r) { $body = [string]$r.Content }

                # 成功判定：跳到 userstatus 页（或页面出现成功标志）
                if ($final -match 'userstatus' -or
                    $body -match '(?i)userstatus\.jsp' -or
                    $body -match '\u5f53\u524d\u767b\u5f55\u8d26\u53f7' -or
                    $body -match '\u767b\u5f55\u6210\u529f') {
                    Write-Log ('认证成功（' + $desc + '）') 'OK'
                    return @{ Success = $true; Message = ('认证成功（' + $desc + '）') }
                }

                # 失败：尽量把门户的提示带出来
                $msg = ''
                $m = [regex]::Match($body, '(?is)(?:alert\(|toastr\.error\(|checkcodeMsg["'']?\s*[:=]\s*["''])\s*["'']?([^"''<>\r\n]{2,60})')
                if ($m.Success) { $msg = $m.Groups[1].Value.Trim() }

                if ($msg) { $lastMsg = ('认证被拒绝（' + $desc + '）：' + $msg) }
                else      { $lastMsg = ('认证被拒绝（' + $desc + '）') }
                if ($hasCheckcode) {
                    $lastMsg += '；登录页要求验证码，请先用浏览器手动登录一次'
                }
                Write-Log $lastMsg 'WARN'
            }
        }
    }
    return @{ Success = $false; Message = $lastMsg }
}

# ---------------------------------------------------------------------
# 各项操作
# ---------------------------------------------------------------------
function Invoke-Setup {
    $cfg = Get-Config
    Write-Console ''
    Write-Console '===== 校园网自动认证 · 首次配置 =====' 'Cyan'
    Write-Console ''

    $acc = Read-Host ('校园网账号/学号 (当前: {0})' -f $cfg.account)
    if ([string]::IsNullOrWhiteSpace($acc)) { $acc = $cfg.account }
    if ([string]::IsNullOrWhiteSpace($acc)) { Write-Console '账号不能为空。' 'Red'; return }

    Write-Console ''
    Write-Console '请选择上网方式（代拨）：' 'Cyan'
    Write-Console '  1) 移动代拨  (mobile)'
    Write-Console '  2) 校园网     (campus)'
    Write-Console '  3) 联通       (unicom)'
    Write-Console '  4) 电信       (telecom)'
    $svcIn = Read-Host ('当前: {0}，直接回车保持不变 [1]' -f $cfg.service)
    switch (($svcIn -as [string]).Trim()) {
        '1'       { $cfg.service = 'mobile' }
        '2'       { $cfg.service = 'campus' }
        '3'       { $cfg.service = 'unicom' }
        '4'       { $cfg.service = 'telecom' }
        'mobile'  { $cfg.service = 'mobile' }
        'campus'  { $cfg.service = 'campus' }
        'unicom'  { $cfg.service = 'unicom' }
        'telecom' { $cfg.service = 'telecom' }
        default   { }
    }

    $sec = Read-Host '校园网密码（输入时不显示）' -AsSecureString
    $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    if ([string]::IsNullOrEmpty($plain)) { Write-Console '密码不能为空。' 'Red'; return }

    $cfg.account       = $acc.Trim()
    $cfg.passwordSec   = ConvertFrom-SecureString -SecureString ($plain | ConvertTo-SecureString -AsPlainText -Force)
    $cfg.passwordPlain = ''
    Save-Config $cfg

    Write-Console ''
    Write-Console ('已保存：账号 {0} ，代拨 {1}' -f $cfg.account, $cfg.service) 'Green'
    Write-Console ('配置文件：{0}' -f $ConfigPath) 'DarkGray'

    Write-Console ''
    $ans = Read-Host '是否立即测试一次认证？（当前已在线会提示"已在线"）(Y/n)'
    if ($ans -eq '' -or $ans -match '(?i)^y') { Invoke-LoginOnce -Config $cfg | Out-Null }

    Write-Console ''
    $ans2 = Read-Host '是否注册开机自启（登录 Windows 后在后台自动运行）？(Y/n)'
    if ($ans2 -eq '' -or $ans2 -match '(?i)^y') { Install-Autostart }

    Write-Console ''
    Write-Console '正在后台启动自动认证守护进程…' 'DarkGray'
    if (Start-DaemonProcess) {
        Write-Console '守护进程已在后台运行。' 'Green'
        Write-Console '（如需全部关闭：双击 3.bat）' 'DarkGray'
    } else {
        Write-Console '后台启动失败，可手动双击 2.vbs。' 'Yellow'
    }
}

function Invoke-LoginOnce {
    param($Config)
    if (-not $Config) { $Config = Get-Config }
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession

    $result = Try-PortalLogin -Config $Config -Session $session -Base $Config.portalBase
    if ($result.Success) { Write-Console $result.Message 'Green' } else { Write-Console $result.Message 'Yellow' }
    Write-Log $result.Message $(if ($result.Success) { 'OK' } else { 'WARN' })
    return $result.Success
}

function Invoke-Status {
    $cfg = Get-Config
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $state = Get-PortalState -Base $cfg.portalBase -Session $session

    $accText = '(未配置)'
    if ($cfg.account) { $accText = (Get-MaskedAccount ([string]$cfg.account)) + '（完整账号见 config.json）' }

    Write-Console ''
    Write-Console '===== 校园网认证状态 =====' 'Cyan'
    Write-Console ('账号        : {0}' -f $accText)
    Write-Console ('代拨方式    : {0}' -f $cfg.service)
    $asState = Get-AutostartState
    if ($asState -eq '未注册') { Write-Console ('开机自启    : {0}' -f $asState) 'Yellow' }
    else                       { Write-Console ('开机自启    : 已注册（{0}）' -f $asState) 'Green' }
    switch ($state.State) {
        'online'  { Write-Console 'Portal 状态 : 已认证（在线）' 'Green' }
        'offline' { Write-Console 'Portal 状态 : 未认证（离线，工具会自动登录）' 'Yellow' }
        default   { Write-Console ('Portal 状态 : 无法确认（{0}）' -f $state.Error) 'Red' }
    }
    $net = Test-Internet
    if ($net) { Write-Console '外网连通性  : 正常' 'Green' } else { Write-Console '外网连通性  : 不通' 'Red' }
    Write-Console ('日志文件    : {0}' -f $LogPath) 'DarkGray'
    Write-Console ''
}

function Invoke-Logout {
    $cfg = Get-Config
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $url = ($cfg.portalBase.TrimEnd('/')) + '/logoff'
    $ok = $false
    for ($i = 1; $i -le 2 -and -not $ok; $i++) {
        try {
            Get-Request -Uri $url -Session $session -MaxRedirect 3 | Out-Null
        } catch { }
        Start-Sleep -Seconds 2
        try {
            $st = Get-PortalState -Base $cfg.portalBase -Session (New-Object Microsoft.PowerShell.Commands.WebRequestSession)
            if ($st.State -eq 'offline') { $ok = $true }
        } catch { }
    }
    if ($ok) {
        Write-Console '已断开当前网络登录，之后需要手动认证。' 'Green'
        Write-Log '断开当前网络登录（已在门户确认）' 'WARN'
    } else {
        Write-Console '断开请求已发送，但门户仍显示在线；若仍未断开，请在认证页面手动点"断开"。' 'Yellow'
        Write-Log '断开请求已发送，但门户仍显示在线' 'WARN'
    }
    return $ok
}

function Invoke-Diagnose {
    $cfg = Get-Config
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $state = Get-PortalState -Base $cfg.portalBase -Session $session

    Write-Console ('Portal 状态 : {0}' -f $state.State) 'Cyan'
    if ($state.Html) {
        $dump = Join-Path $LogDir 'login_page.html'
        [System.IO.File]::WriteAllText($dump, $state.Html, [System.Text.Encoding]::UTF8)
        Write-Console ('登录页已保存 : {0}' -f $dump) 'DarkGray'
    }
    if ($state.Form) {
        Write-Console ''
        Write-Console '----- 解析出的登录表单 -----' 'Cyan'
        Write-Console ('action : {0}' -f $state.Form.ActionUri)
        Write-Console ('method : {0}' -f $state.Form.Method)
        Write-Console '字段:'
        foreach ($k in $state.Form.Fields.Keys) { Write-Console ('    {0} = {1}' -f $k, $state.Form.Fields[$k]) }
        if ($state.Form.Radios.Count -gt 0) {
            Write-Console '单选项:'
            foreach ($g in $state.Form.Radios.Keys) {
                foreach ($r in $state.Form.Radios[$g]) {
                    Write-Console ("    {0} = '{1}'  标签: {2}" -f $g, $r.value, $r.label)
                }
            }
        }
        $svc = Resolve-ServiceValue -Service ([string]$cfg.service) -Radios $state.Form.Radios
        Write-Console ''
        if ($svc) { Write-Console ('代拨选择 : {0} = {1}' -f $svc.Group, $svc.Value) 'Green' }
        else      { Write-Console '代拨选择 : 页面中未找到匹配项（将按门户默认值提交）' 'Yellow' }
    } else {
        Write-Console '未解析到登录表单（当前可能已在线）。' 'Yellow'
    }
    Write-Console ''
}

function Install-Autostart {
    $ps1 = Join-Path $ScriptDir '校园网自动认证.ps1'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Action Run' -f $ps1)
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5) `
        -ExecutionTimeLimit (New-TimeSpan -Days 3650) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) `
        -LogonType Interactive -RunLevel Limited

    # 方式一：Windows 计划任务（功能最全，但普通用户可能被拒绝）
    $taskErr = ''
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Settings $settings -Principal $principal -Description '连上校园网后自动完成 Portal 认证' | Out-Null
        Write-Console '已注册开机自启（Windows 计划任务：校园网自动认证）' 'Green'
        Write-Log '已注册开机自启（计划任务）' 'OK'
        return
    } catch {
        $taskErr = $_.Exception.Message
    }

    # 方式二：启动文件夹快捷方式（无需管理员权限，登录后同样自动运行）
    Write-Console ('计划任务被系统拒绝（{0}），改用"启动文件夹"方式（不需要管理员）…' -f $taskErr) 'Yellow'
    try {
        # 启动器改名也不会失效：直接找目录里唯一的 .vbs
        $vbs = ''
        try {
            $cand = Get-ChildItem -LiteralPath $ScriptDir -Filter '*.vbs' -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($cand) { $vbs = $cand.FullName }
        } catch { }
        $shell = New-Object -ComObject WScript.Shell
        $lnk = $shell.CreateShortcut($StartupLnk)
        if (Test-Path -LiteralPath $vbs) {
            # 用 wscript 拉起 VBS，启动时完全没有黑框
            $lnk.TargetPath = (Join-Path $env:SystemRoot 'System32\wscript.exe')
            $lnk.Arguments = '"{0}"' -f $vbs
        } else {
            $lnk.TargetPath = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
            $lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Action Run' -f $ps1
        }
        $lnk.WorkingDirectory = $ScriptDir
        $lnk.WindowStyle = 7
        $lnk.Description = '连上校园网后自动完成 Portal 认证'
        $lnk.Save()

        Write-Console '已注册开机自启（启动文件夹）：' 'Green'
        Write-Console ('    {0}' -f $StartupLnk) 'DarkGray'
        Write-Console '登录 Windows 后它会自动在后台运行。' 'Green'
        Write-Log ('已注册开机自启（启动文件夹）。计划任务失败原因：' + $taskErr) 'OK'
    } catch {
        Write-Console ('两种自启方式都失败了：' + $_.Exception.Message) 'Red'
        Write-Console '可手动把 2.vbs 的快捷方式放进 shell:startup 文件夹。' 'Yellow'
        Write-Log ('自启注册彻底失败：' + $_.Exception.Message) 'ERROR'
    }
}

function Uninstall-Autostart {
    $removed = $false
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Console '已移除计划任务。' 'Yellow'
        $removed = $true
    } catch { }
    if (Test-Path -LiteralPath $StartupLnk) {
        Remove-Item -LiteralPath $StartupLnk -Force -ErrorAction SilentlyContinue
        Write-Console '已移除启动文件夹快捷方式。' 'Yellow'
        $removed = $true
    }
    if ($removed) { Write-Log '已取消开机自启' 'WARN' }
    else { Write-Console '未找到自启项（可能本来就没注册）。' 'DarkGray' }
}

function Get-AutostartState {
    $states = @()
    try {
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop) { $states += '计划任务' }
    } catch { }
    if (Test-Path -LiteralPath $StartupLnk) { $states += '启动文件夹' }
    if ($states.Count -eq 0) { return '未注册' }
    return ($states -join ' + ')
}

function Test-DaemonRunning {
    # 首选：用全局互斥量判断 —— 守护进程是否活着，这是最可靠的判据
    try {
        $m = [System.Threading.Mutex]::OpenExisting('Global\SNNUAutoLoginTool')
        try {
            if ($m.WaitOne(0)) {
                # 能立刻拿到锁，说明没有守护进程在跑
                try { $m.ReleaseMutex() } catch { }
            } else {
                return $true
            }
        } finally { $m.Dispose() }
    } catch {
        # 互斥量不存在，说明这次开机还没有守护进程跑过
    }
    # 退路：读 pid 文件
    if (-not (Test-Path -LiteralPath $PidPath)) { return $false }
    $text = (Get-Content -LiteralPath $PidPath -Raw -ErrorAction SilentlyContinue)
    $oldPid = 0
    if (-not [int]::TryParse(([string]$text).Trim(), [ref]$oldPid)) { return $false }
    $proc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
    if (-not $proc) { return $false }
    return ($proc.ProcessName -eq 'powershell')
}

function Start-DaemonProcess {
    $ps1 = Join-Path $ScriptDir '校园网自动认证.ps1'
    try {
        Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', $ps1, '-Action', 'Run'
        ) | Out-Null
        return $true
    } catch {
        Write-Log ('启动守护进程失败：' + $_.Exception.Message) 'ERROR'
        return $false
    }
}

function Stop-Background {
    <# 结束所有正在后台运行的守护进程（不含自己） #>
    $me = $PID
    $killed = 0

    # 方式一：读取守护进程自己记录的 PID（不依赖 WMI）
    if (Test-Path -LiteralPath $PidPath) {
        $text = (Get-Content -LiteralPath $PidPath -Raw -ErrorAction SilentlyContinue)
        $oldPid = 0
        if ([int]::TryParse(([string]$text).Trim(), [ref]$oldPid) -and $oldPid -gt 0 -and $oldPid -ne $me) {
            try {
                $proc = Get-Process -Id $oldPid -ErrorAction Stop
                if ($proc.ProcessName -eq 'powershell') {
                    Stop-Process -Id $oldPid -Force -ErrorAction Stop
                    $killed++
                }
            } catch { }
        }
    }

    # 方式二：按命令行匹配（WMI 不可用时自动跳过）
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue
    } catch {
        $procs = @()
    }
    foreach ($p in $procs) {
        if ($p.ProcessId -eq $me) { continue }
        # 只认守护进程（-Action Run），避免误杀配置窗口/界面进程
        if ($p.CommandLine -and $p.CommandLine -like '*校园网自动认证.ps1*' -and
            $p.CommandLine -like '*-Action Run*') {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
            $killed++
        }
    }
    if (Test-Path -LiteralPath $PidPath) { Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue }

    if ($killed -gt 0) {
        Write-Console ('已停止 {0} 个后台守护进程。' -f $killed) 'Yellow'
        Write-Log ("停止后台守护进程 {0} 个" -f $killed) 'WARN'
    } else {
        Write-Console '没有正在运行的后台守护进程。' 'DarkGray'
    }

    Start-Sleep -Milliseconds 600
    if (Test-DaemonRunning) {
        Write-Console '仍检测到守护进程在运行，请再执行一次。' 'Red'
    } else {
        Write-Console '后台守护已停止：之后掉线不会再自动重连。' 'Green'
        Write-Console '注意：当前这条网络会话仍处于登录状态（停止工具并不会让你下线）。' 'DarkGray'
        Write-Console '想同时退出登录并取消开机自启，请用 3.bat。' 'DarkGray'
    }
}

function Invoke-StopAll {
    <# 停止守护进程 + 取消开机自启（可选：同时断开当前网络登录） #>
    param([switch]$Disconnect)

    Write-Console ''
    Write-Console '===== 完全停止自动认证 =====' 'Cyan'
    Write-Console ''
    Stop-Background
    Write-Console ''
    Uninstall-Autostart
    Write-Console ''
    Write-Console ('开机自启当前状态：{0}' -f (Get-AutostartState)) 'Gray'

    if ($Disconnect) { Invoke-Logout }
    Write-Console ''
}

function Invoke-WatchLoop {
    param($Config, [switch]$OnceOnly)

    $mutex = New-Object System.Threading.Mutex($false, 'Global\SNNUAutoLoginTool')
    $hasLock = $false
    try {
        $hasLock = $mutex.WaitOne(0)
        if (-not $hasLock) {
            Write-Log '已有另一个自动认证进程在运行，本次退出。' 'WARN'
            return
        }

        Write-Log '自动认证守护进程启动' 'INFO'
        Set-Content -LiteralPath $PidPath -Value $PID -Encoding ASCII
        $consecutiveFail = 0
        $cycle = 0

        while ($true) {
            $cycle++
            # 每轮重新读取配置，这样在图形界面里改完就即时生效，无需重启守护进程
            try { $Config = Get-Config } catch { }
            $state = 'unknown'
            try {
                $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
                $st = Get-PortalState -Base $Config.portalBase -Session $session
                $state = $st.State

                if ($state -eq 'online') {
                    $consecutiveFail = 0
                    if (($cycle % 5) -eq 0 -and -not (Test-Internet -TimeoutSec 4)) {
                        Write-Log '门户显示在线，但外网不通，继续观察' 'WARN'
                    }
                }
                elseif ($state -eq 'offline') {
                    Write-Log '检测到未认证，开始自动认证' 'INFO'
                    $ok = $false
                    for ($i = 1; $i -le [int]$Config.maxLoginAttempts; $i++) {
                        $result = Try-PortalLogin -Config $Config -Session $session -Base $Config.portalBase
                        if ($result.Success) { $ok = $true; Write-Log $result.Message 'OK'; break }
                        Write-Log ('第 {0} 次尝试失败：{1}' -f $i, $result.Message) 'WARN'
                        Start-Sleep -Seconds 3
                    }
                    if ($ok) {
                        Start-Sleep -Seconds 3
                        if (Test-Internet -TimeoutSec 6) { Write-Log '认证后外网已通' 'OK' }
                        else { Write-Log '认证已完成，外网可能还需几秒' 'WARN' }
                        $consecutiveFail = 0
                    } else {
                        $consecutiveFail++
                    }
                }
                else {
                    $consecutiveFail++
                    Write-Log ('无法访问认证门户：' + $st.Error) 'WARN'
                }
            } catch {
                $consecutiveFail++
                Write-Log ('守护循环异常：' + $_.Exception.Message) 'ERROR'
            }

            if ($OnceOnly) { break }

            $sleepSec = [int]$Config.checkIntervalSeconds
            if ($state -eq 'offline' -or $state -eq 'unknown') {
                $sleepSec = [int]$Config.retryIntervalSeconds
                if ($consecutiveFail -gt 6) { $sleepSec = [Math]::Min(300, $sleepSec * 3) }
            }
            Start-Sleep -Seconds ([Math]::Max(5, $sleepSec))
        }
    } finally {
        # 只有真正持有锁的那个实例才有资格清理 pid 文件，
        # 否则"抢锁失败的第二个实例"会把正在运行实例的 pid 文件删掉。
        if ($hasLock) {
            try { if (Test-Path -LiteralPath $PidPath) { Remove-Item -LiteralPath $PidPath -Force } } catch { }
            try { $mutex.ReleaseMutex() } catch { }
        }
        $mutex.Dispose()
    }
}

# ---------------------------------------------------------------------
# 自检：用一份模拟登录页验证解析逻辑（不联网）
# ---------------------------------------------------------------------
function Read-HttpRequest {
    param($Stream, [System.Text.Encoding]$Encoding)
    $buffer = New-Object System.Collections.Generic.List[byte]
    $one = New-Object byte[] 1
    $headerEnd = -1
    while ($headerEnd -lt 0) {
        $n = $Stream.Read($one, 0, 1)
        if ($n -le 0) { return $null }
        [void]$buffer.Add($one[0])
        $c = $buffer.Count
        if ($c -ge 4 -and $buffer[$c-4] -eq 13 -and $buffer[$c-3] -eq 10 -and
            $buffer[$c-2] -eq 13 -and $buffer[$c-1] -eq 10) { $headerEnd = $c }
    }
    $headText = $Encoding.GetString($buffer.ToArray(), 0, $headerEnd)
    $lines = $headText -split "`r`n"
    $requestLine = $lines[0]
    $headers = @{}
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $idx = $lines[$i].IndexOf(':')
        if ($idx -gt 0) { $headers[$lines[$i].Substring(0,$idx).Trim().ToLower()] = $lines[$i].Substring($idx+1).Trim() }
    }
    $parts = $requestLine -split ' '
    $rawUrl = ''
    if ($parts.Count -gt 1) { $rawUrl = $parts[1] }
    $query = @{}
    $mark = $rawUrl.IndexOf('?')
    $pathOnly = $rawUrl
    if ($mark -ge 0) {
        $pathOnly = $rawUrl.Substring(0, $mark)
        foreach ($kv in ($rawUrl.Substring($mark+1) -split '&')) {
            $eq = $kv.IndexOf('=')
            if ($eq -gt 0) {
                $query[[uri]::UnescapeDataString($kv.Substring(0,$eq))] = [uri]::UnescapeDataString($kv.Substring($eq+1))
            }
        }
    }
    $bodyText = ''
    if ($headers.ContainsKey('content-length')) {
        $len = [int]$headers['content-length']
        if ($len -gt 0) {
            $bytes = New-Object byte[] $len
            $read = 0
            while ($read -lt $len) {
                $n = $Stream.Read($bytes, $read, $len - $read)
                if ($n -le 0) { break }
                $read += $n
            }
            $bodyText = $Encoding.GetString($bytes, 0, $read)
        }
    }
    return [pscustomobject]@{
        Method  = $parts[0]
        Path    = $pathOnly
        Query   = $query
        Headers = $headers
        Body    = $bodyText
    }
}

function Send-HttpResponse {
    param(
        $Stream,
        [int]$Status = 200,
        [string]$Reason = 'OK',
        [string]$ContentType = 'text/html; charset=utf-8',
        [byte[]]$Body
    )
    if (-not $Body) { $Body = New-Object byte[] 0 }
    $head = "HTTP/1.1 $Status $Reason`r`n" +
            "Server: SNNU-AutoLogin-UI`r`n" +
            "Content-Type: $ContentType`r`n" +
            "Content-Length: $($Body.Length)`r`n" +
            "Cache-Control: no-store`r`n" +
            "Connection: close`r`n`r`n"
    $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($hb, 0, $hb.Length)
    if ($Body.Length -gt 0) { $Stream.Write($Body, 0, $Body.Length) }
    $Stream.Flush()
}

function Send-JsonResponse {
    param($Stream, $Object, [int]$Status = 200)
    $json = ($Object | ConvertTo-Json -Depth 6 -Compress)
    $reason = 'OK'
    if ($Status -ne 200) { $reason = 'Error' }
    Send-HttpResponse -Stream $Stream -Status $Status -Reason $reason `
        -ContentType 'application/json; charset=utf-8' `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($json))
}

function Get-MaskedAccount {
    <# 把账号变成掩码，界面只用来"认得出是哪个账号"，不泄露原文 #>
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    if ($Value.Length -le 2) { return ('*' * $Value.Length) }
    return ($Value.Substring(0, 2) + '******')
}

function Build-UiStatusPayload {
    <# 汇总给界面显示的状态（不包含任何密码信息） #>
    $cfg = Get-Config
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $portal = 'unknown'
    try { $portal = (Get-PortalState -Base $cfg.portalBase -Session $session).State } catch { }
    $net = $false
    try { $net = Test-Internet -TimeoutSec 4 } catch { }

    $acc = [string]$cfg.account
    return [ordered]@{
        # 只回传掩码，绝不把账号原文交给页面，避免"打开界面就看到自己的账号"
        accountMasked = (Get-MaskedAccount $acc)
        service       = [string]$cfg.service
        hasPassword   = (-not [string]::IsNullOrEmpty($cfg.passwordSec)) -or (-not [string]::IsNullOrEmpty($cfg.passwordPlain))
        configured    = (-not [string]::IsNullOrEmpty($acc))
        portal        = $portal
        internet      = $net
        autostart     = (Get-AutostartState)
        daemonRunning = (Test-DaemonRunning)
        portalUrl     = $cfg.portalBase
        logPath       = $LogPath
    }
}

function Start-UiServer {
    <# 启动一个只监听 127.0.0.1 的迷你 Web 服务，用浏览器提供配置界面 #>
    $uiFile = Join-Path $ScriptDir 'ui\index.html'
    if (-not (Test-Path -LiteralPath $uiFile)) {
        Write-Console ('找不到界面文件：{0}' -f $uiFile) 'Red'
        return
    }
    $htmlTemplate = [System.IO.File]::ReadAllText($uiFile, [System.Text.Encoding]::UTF8)
    $token = [guid]::NewGuid().ToString('N')
    $utf8  = New-Object System.Text.UTF8Encoding($false)

    $listener = $null
    $port = 8901
    for ($i = 0; $i -lt 30 -and -not $listener; $i++) {
        try {
            $candidate = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $port)
            $candidate.Start()
            $listener = $candidate
        } catch {
            $port++
            $listener = $null
        }
    }
    if (-not $listener) {
        Write-Console '无法启动本地界面服务（端口都被占用）。' 'Red'
        return
    }

    $url = 'http://127.0.0.1:{0}/?t={1}' -f $port, $token
    Write-Console ''
    Write-Console '===== 校园网自动认证 · 配置界面 =====' 'Cyan'
    Write-Console ('浏览器地址：{0}' -f $url) 'DarkGray'
    Write-Console '（配置完成后可直接关闭本窗口，或回到页面点"完成并关闭"）' 'DarkGray'
    Write-Console ''
    Write-Log ('配置界面已启动：' + $url) 'INFO'

    if ($env:SNNU_UI_NO_BROWSER -ne '1') {
        try { Start-Process $url | Out-Null } catch { Write-Console '未能自动打开浏览器，请手动复制上面的地址。' 'Yellow' }
    }

    $deadline = (Get-Date).AddMinutes(20)
    $running = $true
    while ($running) {
        if (-not $listener.Pending()) {
            Start-Sleep -Milliseconds 100
            if ((Get-Date) -gt $deadline) { break }
            continue
        }

        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $req = Read-HttpRequest -Stream $stream -Encoding $utf8
            if (-not $req) { $client.Close(); continue }
            $deadline = (Get-Date).AddMinutes(20)

            $isApi = $req.Path -like '/api/*'
            $ok = $true
            if ($isApi) {
                $given = ''
                if ($req.Headers.ContainsKey('x-token')) { $given = $req.Headers['x-token'] }
                if ($given -ne $token) { $ok = $false }
            } elseif ($req.Path -eq '/' -or $req.Path -eq '/index.html') {
                if ($req.Query['t'] -ne $token) { $ok = $false }
            } else {
                $ok = $false
            }

            if (-not $ok) {
                Send-HttpResponse -Stream $stream -Status 403 -Reason 'Forbidden' `
                    -ContentType 'text/plain; charset=utf-8' `
                    -Body ($utf8.GetBytes('forbidden'))
                $client.Close()
                continue
            }

            switch ($req.Path) {
                '/' {
                    $page = $htmlTemplate.Replace('__TOKEN__', $token)
                    Send-HttpResponse -Stream $stream -Status 200 -Reason 'OK' `
                        -ContentType 'text/html; charset=utf-8' -Body ($utf8.GetBytes($page))
                }
                '/index.html' {
                    $page = $htmlTemplate.Replace('__TOKEN__', $token)
                    Send-HttpResponse -Stream $stream -Status 200 -Reason 'OK' `
                        -ContentType 'text/html; charset=utf-8' -Body ($utf8.GetBytes($page))
                }
                '/api/state' {
                    Send-JsonResponse -Stream $stream -Object (Build-UiStatusPayload)
                }
                '/api/save' {
                    $data = $null
                    try { $data = $req.Body | ConvertFrom-Json } catch { }
                    if (-not $data) {
                        Send-JsonResponse -Stream $stream -Status 400 -Object ([ordered]@{ ok = $false; message = '请求格式错误' })
                        $client.Close(); continue
                    }
                    $cfg = Get-Config
                    $newAcc = ([string]$data.account).Trim()
                    if ([string]::IsNullOrWhiteSpace($newAcc)) {
                        # 留空表示"沿用已保存的账号"，界面上不再回显账号
                        if ([string]::IsNullOrEmpty([string]$cfg.account)) {
                            Send-JsonResponse -Stream $stream -Object ([ordered]@{ ok = $false; message = '请先填写账号 / 学号' })
                            $client.Close(); continue
                        }
                    } else {
                        $cfg.account = $newAcc
                    }
                    if ($data.service) { $cfg.service = [string]$data.service }
                    if ($data.password -and ([string]$data.password).Length -gt 0) {
                        $cfg.passwordSec   = ConvertFrom-SecureString -SecureString (([string]$data.password) | ConvertTo-SecureString -AsPlainText -Force)
                        $cfg.passwordPlain = ''
                    }
                    Save-Config $cfg

                    $notes = @('配置已保存')
                    if ([string]::IsNullOrEmpty($cfg.passwordSec) -and [string]::IsNullOrEmpty($cfg.passwordPlain)) {
                        $notes += '但还没设置密码，自动认证不会生效'
                    }
                    if ($data.installAutostart -eq $true) {
                        Install-Autostart | Out-Null
                        $notes += ('开机自启：' + (Get-AutostartState))
                    }
                    if (-not (Test-DaemonRunning)) {
                        if (Start-DaemonProcess) { $notes += '已启动后台守护进程' }
                    } else {
                        $notes += '守护进程在运行中（新配置已生效）'
                    }
                    Write-Log ('通过界面保存配置：账号 ' + $cfg.account + ' ，代拨 ' + $cfg.service) 'OK'
                    Send-JsonResponse -Stream $stream -Object ([ordered]@{ ok = $true; message = ($notes -join '；') })
                }
                '/api/test' {
                    $data = $null
                    try { $data = $req.Body | ConvertFrom-Json } catch { }
                    $cfg = Get-Config
                    if ($data) {
                        if ($data.account)   { $cfg.account   = ([string]$data.account).Trim() }
                        if ($data.service)   { $cfg.service   = [string]$data.service }
                        if ($data.password -and ([string]$data.password).Length -gt 0) {
                            $cfg.passwordSec   = ConvertFrom-SecureString -SecureString (([string]$data.password) | ConvertTo-SecureString -AsPlainText -Force)
                            $cfg.passwordPlain = ''
                        }
                    }
                    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
                    $r = Try-PortalLogin -Config $cfg -Session $session -Base $cfg.portalBase
                    Send-JsonResponse -Stream $stream -Object ([ordered]@{ ok = [bool]$r.Success; message = [string]$r.Message })
                }
                '/api/stop' {
                    Stop-Background | Out-Null
                    Send-JsonResponse -Stream $stream -Object ([ordered]@{ ok = $true; message = '已停止后台守护进程' })
                }
                '/api/stopall' {
                    # 与 3.bat 完全等价：停守护 + 取消开机自启 + 断开当前网络登录
                    Stop-Background | Out-Null
                    Uninstall-Autostart | Out-Null
                    $disconnected = Invoke-Logout
                    $msg = '已停止后台守护；开机自启：' + (Get-AutostartState) + '；'
                    if ($disconnected) { $msg += '已断开当前网络登录（需要手动认证）' }
                    else               { $msg += '断开请求已发送，若仍在线请在认证页面手动断开' }
                    Send-JsonResponse -Stream $stream -Object ([ordered]@{ ok = $true; message = $msg })
                }
                '/api/quit' {
                    Send-JsonResponse -Stream $stream -Object ([ordered]@{ ok = $true; message = '界面服务已关闭' })
                    $running = $false
                    $client.Close()
                    continue
                }
                default {
                    Send-JsonResponse -Stream $stream -Status 404 -Object ([ordered]@{ ok = $false; message = 'not found' })
                }
            }
        } catch {
            Write-Log ('界面服务异常：' + $_.Exception.Message) 'ERROR'
        } finally {
            try { $client.Close() } catch { }
        }
    }

    try { $listener.Stop() } catch { }
    Write-Console '配置界面已关闭。' 'DarkGray'
}

# ---------------------------------------------------------------------
# 自检：用一份模拟登录页验证解析逻辑（不联网）
# ---------------------------------------------------------------------
function Invoke-SelfTest {
    Write-Console '开始自检（离线解析测试）...' 'Cyan'
    $sample = @'
<html><head><title>网络 Portal</title></head><body>
<form method="post" action="login.jsp" id="loginForm">
  <input type="hidden" name="wlanacname" value="SNNU-AC-01">
  <input type="hidden" name="nasip" value="202.117.144.1">
  <table>
    <tr><td>账号：</td><td><input type="text" name="account" value=""></td></tr>
    <tr><td>密码：</td><td><input type="password" name="password" value=""></td></tr>
    <tr><td>代拨：</td>
        <td><input type="radio" name="yys" value="plain" checked>校园网
            <input type="radio" name="yys" value="unicom">联通
            <input type="radio" name="yys" value="mobile">移动
            <input type="radio" name="yys" value="telecom">电信</td></tr>
    <tr><td><input type="checkbox" name="issave" value="1">记住密码</td>
        <td><input type="button" value="用户登录"></td></tr>
  </table>
</form>
</body></html>
'@
    $script:SelfTestOk = $true

    $form = Get-LoginForm -Html $sample -BaseUri 'http://202.117.144.205:8602/snnuportal/login.jsp'
    if (-not $form) {
        Write-Console '  [失败] 未能解析出登录表单' 'Red'
        Write-Console ''
        return
    }

    $checks = @(
        @{ Name = 'action';      Actual = $form.ActionUri;                        Expect = 'http://202.117.144.205:8602/snnuportal/login.jsp' },
        @{ Name = 'method';      Actual = $form.Method;                           Expect = 'POST' },
        @{ Name = '隐藏域 wlanacname'; Actual = $form.Fields['wlanacname'];        Expect = 'SNNU-AC-01' },
        @{ Name = '隐藏域 nasip';      Actual = $form.Fields['nasip'];             Expect = '202.117.144.1' },
        @{ Name = '移动代拨取值';      Actual = (Resolve-ServiceValue -Service 'mobile' -Radios $form.Radios).Value; Expect = 'mobile' },
        @{ Name = '中文"移动"取值';    Actual = (Resolve-ServiceValue -Service '移动'   -Radios $form.Radios).Value; Expect = 'mobile' },
        @{ Name = '中文"联通"取值';    Actual = (Resolve-ServiceValue -Service '联通'   -Radios $form.Radios).Value; Expect = 'unicom' },
        @{ Name = '中文"校园网"取值';  Actual = (Resolve-ServiceValue -Service '校园网' -Radios $form.Radios).Value; Expect = 'plain' },
        @{ Name = '表单编码';          Actual = (ConvertTo-UrlEncodedBody -Data ([ordered]@{ account='S0000000'; password='ab1'; yys='mobile' })); Expect = 'account=S0000000&password=ab1&yys=mobile' }
    )
    foreach ($c in $checks) {
        if ("$($c.Actual)" -eq "$($c.Expect)") {
            Write-Console ('  [通过] {0} = {1}' -f $c.Name, $c.Actual) 'Green'
        } else {
            Write-Console ('  [失败] {0}: 期望 {1}，实际 {2}' -f $c.Name, $c.Expect, $c.Actual) 'Red'
            $script:SelfTestOk = $false
        }
    }

    Write-Console ''
    if ($script:SelfTestOk) { Write-Console '自检全部通过。' 'Green' } else { Write-Console '自检存在失败项。' 'Red' }
    Write-Console ''
}

# ---------------------------------------------------------------------
# 主入口
# ---------------------------------------------------------------------
switch ($Action) {
    'UI'        { Start-UiServer }
    'Setup'     { Invoke-Setup }
    'Login'     { Invoke-LoginOnce | Out-Null }
    'Status'    { Invoke-Status }
    'Logout'    { Invoke-Logout }
    'Diagnose'  { Invoke-Diagnose }
    'Install'   { Install-Autostart }
    'Uninstall' { Uninstall-Autostart }
    'Stop'      { Stop-Background }
    'StopAll'   { Invoke-StopAll -Disconnect:$Disconnect }
    'SelfTest'  { Invoke-SelfTest }
    'Run' {
        $cfg = Get-Config
        if ([string]::IsNullOrEmpty($cfg.account) -or
            ([string]::IsNullOrEmpty($cfg.passwordSec) -and [string]::IsNullOrEmpty($cfg.passwordPlain))) {
            Write-Console '尚未配置账号密码，请先运行： .\校园网自动认证.ps1 -Action Setup' 'Yellow'
            exit 1
        }

        # 门户地址自适应（门户换 IP/端口也能自己找回来）
        try {
            $probe = Get-PortalState -Base $cfg.portalBase -Session (New-Object Microsoft.PowerShell.Commands.WebRequestSession)
            if ($probe.State -eq 'unknown') {
                $newBase = Resolve-PortalBase -Entry $cfg.portalEntry
                if ($newBase -and $newBase -ne $cfg.portalBase) {
                    Write-Log ('门户地址更新：{0} -> {1}' -f $cfg.portalBase, $newBase) 'INFO'
                    $cfg.portalBase = $newBase
                    Save-Config $cfg
                }
            }
        } catch { }

        Invoke-WatchLoop -Config $cfg -OnceOnly:$Once
    }
}
