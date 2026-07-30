# ============================================================
#  Agent-Wallpaper.ps1  (roda no PC do cliente)
#  Processo continuo: checa o Firebase a cada poucos segundos e aplica
#  a imagem na hora que mudar. Inicia com o Windows (Tarefa Agendada);
#  se cair, a tarefa o reinicia em ate 1 min.
# ============================================================

# ---------- CONFIGURACAO ----------
$FirebaseDbUrl = "https://wallpaper-mdf-default-rtdb.firebaseio.com"
$FirebaseNode  = "wallpaper"   # no do RTDB com a imagem atual
$FirebaseAuth  = ""            # opcional: secret do DB se as regras exigirem auth
$IntervaloSeg  = 5             # de quanto em quanto checa (segundos)
$HeartbeatSeg  = 30            # de quanto em quanto avisa "estou online"
$AgentVersao   = 35            # versao deste agente (auto-update via Firebase /agent)
# ----------------------------------

$PastaTrabalho  = Join-Path $env:LOCALAPPDATA "WallpaperSync"
$CaminhoImagem  = Join-Path $PastaTrabalho "wallpaper"
$CaminhoEstado  = Join-Path $PastaTrabalho "agent-state.json"
$CaminhoLog     = Join-Path $PastaTrabalho "log.txt"
$CaminhoNome    = Join-Path $PastaTrabalho "nome.txt"   # nome amigavel (opcional)
$CaminhoSetor   = Join-Path $PastaTrabalho "setor.txt"  # setor(es), separados por virgula
$CaminhoCargo   = Join-Path $PastaTrabalho "cargo.txt"  # cargo (diretor, gerente, supervisor, funcionario)
$CaminhoAlive   = Join-Path $PastaTrabalho "alive.txt"  # "sinal de vida": atualizado a cada ciclo
$CaminhoPid     = Join-Path $PastaTrabalho "agent.pid"  # PID da instancia viva (watchdog)

if (-not (Test-Path $PastaTrabalho)) { New-Item -ItemType Directory -Path $PastaTrabalho -Force | Out-Null }

# Garante uma unica instancia, MAS com watchdog: se a instancia que detem o mutex
# estiver TRAVADA (processo vivo mas parado - acontece apos sleep/hibernacao ou
# socket morto), ela ficaria offline por horas e o relancamento de 5min so bateria
# no mutex e sairia. Por isso: se nao pegar o mutex, verifico o "sinal de vida"
# (alive.txt). Fresco = outra instancia esta saudavel, saio. Velho = instancia
# travada: mato o processo antigo (pelo PID, so se for powershell) e assumo.
$JANELA_TRAVADO_SEG = 150   # alive.txt mais velho que isto = instancia travada (o loop atualiza a cada ~5s)
$mutex = New-Object System.Threading.Mutex($false, "Local\WallpaperSyncAgent")
$relancouTravado = $false
$temMutex = $false
try { $temMutex = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $temMutex = $true }
if (-not $temMutex) {
    $viva = $false
    if (Test-Path $CaminhoAlive) {
        try { if (((Get-Date) - (Get-Item $CaminhoAlive).LastWriteTime).TotalSeconds -lt $JANELA_TRAVADO_SEG) { $viva = $true } } catch {}
    }
    if ($viva) { exit }   # outra instancia esta viva e saudavel: nao duplica
    # Instancia travada: mata o processo antigo (so se realmente for powershell) e assume.
    if (Test-Path $CaminhoPid) {
        $oldPid = (Get-Content $CaminhoPid -Raw -ErrorAction SilentlyContinue)
        if ($oldPid) { $oldPid = $oldPid.Trim() }
        if ($oldPid -match '^\d+$' -and [int]$oldPid -ne $PID) {
            $p = Get-Process -Id ([int]$oldPid) -ErrorAction SilentlyContinue
            if ($p -and $p.ProcessName -in @('powershell', 'pwsh', 'powershell_ise')) {
                try { Stop-Process -Id ([int]$oldPid) -Force -ErrorAction SilentlyContinue } catch {}
                $relancouTravado = $true
            }
        }
    }
    try { $temMutex = $mutex.WaitOne(5000) } catch [System.Threading.AbandonedMutexException] { $temMutex = $true }
    if (-not $temMutex) { exit }   # nao consegui assumir agora; tento de novo no proximo ciclo
}
# Registra o PID desta instancia e ja marca sinal de vida.
try { Set-Content -Path $CaminhoPid   -Value $PID -Encoding ASCII -ErrorAction SilentlyContinue } catch {}
try { [IO.File]::WriteAllText($CaminhoAlive, (Get-Date -Format o)) } catch {}

function Configurado($valor) { return ($valor -and $valor.Trim() -ne "" -and $valor -notmatch "^__.*__$") }

function Escreve-Log($mensagem) {
    "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $mensagem | Add-Content $CaminhoLog -Encoding UTF8
    $linhas = Get-Content $CaminhoLog -ErrorAction SilentlyContinue
    if ($linhas.Count -gt 200) { $linhas[-200..-1] | Set-Content $CaminhoLog -Encoding UTF8 }
}

function Url-Firebase($caminho) {
    $u = "$($FirebaseDbUrl.TrimEnd('/'))/$caminho.json"
    if (Configurado $FirebaseAuth) { $u += "?auth=$FirebaseAuth" }
    return $u
}

# Reporta o ultimo erro deste PC pro Firebase (erros/<chave>), para o admin ver
# no painel sem precisar acessar o PC. Best-effort: nunca derruba o agente.
# Evita spam: o mesmo erro so e reenviado a cada 10 ocorrencias.
$script:ultErroMsg   = ""
$script:ultErroVezes = 0
function Reporta-Erro($mensagem) {
    try {
        if ("$mensagem" -eq $script:ultErroMsg) {
            $script:ultErroVezes++
            if ($script:ultErroVezes % 10 -ne 0) { return }   # mesmo erro repetido: nao reenvia toda vez
        } else {
            $script:ultErroMsg   = "$mensagem"
            $script:ultErroVezes = 1
        }
        $corpo = @{
            mensagem    = "$mensagem"
            em          = @{ ".sv" = "timestamp" }
            agentVersao = $AgentVersao
            nome        = $nomeExib
            so          = $so
            vezes       = $script:ultErroVezes
        } | ConvertTo-Json
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($corpo)
        Invoke-RestMethod -Uri (Url-Firebase "erros/$chave") -Method Put -Body $bytes -ContentType "application/json; charset=utf-8" -TimeoutSec 15 | Out-Null
    } catch {}
}

# Sobe as ultimas linhas do log deste PC pro Firebase (logs/<chave>), pra o admin
# ver no painel sem acessar o PC. Best-effort: nunca derruba o agente. Enviado no
# ritmo do heartbeat (a cada ~30s). So reenvia se o conteudo mudou (economiza banda).
$script:ultLogEnviado = ""
function Sobe-Log {
    try {
        if (-not (Test-Path $CaminhoLog)) { return }
        $linhas = Get-Content $CaminhoLog -Tail 6 -ErrorAction SilentlyContinue
        if (-not $linhas) { return }
        $texto = ($linhas -join "`n")
        if ("$texto" -eq $script:ultLogEnviado) { return }   # nada novo: nao reenvia
        $corpo = @{
            texto        = "$texto"
            atualizadoEm = @{ ".sv" = "timestamp" }
            agenteVersao = [int]$AgentVersao
            nome         = $nomeExib
        } | ConvertTo-Json
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($corpo)
        Invoke-RestMethod -Uri (Url-Firebase "logs/$chave") -Method Put -Body $bytes -ContentType "application/json; charset=utf-8" -TimeoutSec 15 | Out-Null
        $script:ultLogEnviado = "$texto"   # so marca como enviado se o PUT deu certo (nao lancou)
    } catch {}
}

# Diagnostico de "offline no painel": o PC some do painel quando o heartbeat para
# de chegar no Firebase. Registra no log SO as transicoes (caiu / voltou), pra
# depois dar pra descobrir a causa (queda de internet x PC dormiu x travou).
$script:hbOnline    = $true    # comeca assumindo online (o painel so mostra apos 1o hb)
$script:hbCaiuEm    = $null    # quando o heartbeat comecou a falhar
function Registra-Heartbeat($ok, $erro) {
    if ($ok) {
        if (-not $script:hbOnline) {
            $seg = if ($script:hbCaiuEm) { [int]((Get-Date) - $script:hbCaiuEm).TotalSeconds } else { 0 }
            Escreve-Log ("CONEXAO OK: heartbeat voltou apos {0}s sem conexao (estava offline no painel)." -f $seg)
            $script:hbOnline = $true; $script:hbCaiuEm = $null
        }
    } else {
        if ($script:hbOnline) {
            $script:hbOnline = $false; $script:hbCaiuEm = Get-Date
            Escreve-Log ("SEM CONEXAO: heartbeat falhou (internet/Firebase fora); PC fica offline no painel. " + $erro)
        }
    }
}

function Define-PapelDeParede($caminho) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Wp {
  [DllImport("user32.dll", CharSet=CharSet.Auto)]
  public static extern int SystemParametersInfo(int a,int u,string p,int f);
}
"@ -ErrorAction SilentlyContinue
    $chave = "HKCU:\Control Panel\Desktop"
    Set-ItemProperty $chave WallpaperStyle "10"
    Set-ItemProperty $chave TileWallpaper  "0"
    Set-ItemProperty $chave Wallpaper      $caminho
    # O Windows guarda um cache (TranscodedWallpaper). Se o caminho/conteudo
    # "parecer" o mesmo, ele as vezes nao repinta. Apaga o cache para forcar.
    $temas = Join-Path $env:APPDATA "Microsoft\Windows\Themes"
    foreach ($f in @("TranscodedWallpaper", "CachedFiles")) {
        $alvo = Join-Path $temas $f
        if (Test-Path $alvo) { Remove-Item $alvo -Recurse -Force -ErrorAction SilentlyContinue }
    }
    # SPIF_UPDATEINIFILE(1) | SPIF_SENDCHANGE(2) = 3. Retorno != 0 = sucesso.
    return ([Wp]::SystemParametersInfo(20, 0, $caminho, 3) -ne 0)
}

# Abre a imagem no navegador do PC: tenta Chrome, depois Edge (vem no Windows),
# e por fim o app associado (garante que algo abra mesmo sem Chrome/Edge).
function Abre-NoNavegador($caminho) {
    $candidatos = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    )
    # Abre em janela nova e em TELA CHEIA, vindo para a frente de tudo, para o
    # cliente ver na hora (passa por cima dos apps abertos). --start-fullscreen
    # cobre a tela inteira; --new-window garante uma janela dedicada.
    $argsNav = @("--new-window", "--start-fullscreen", "`"$caminho`"")
    foreach ($exe in $candidatos) {
        if ($exe -and (Test-Path $exe)) {
            try { Start-Process -FilePath $exe -ArgumentList $argsNav | Out-Null; return $true } catch {}
        }
    }
    try { Start-Process $caminho | Out-Null; return $true } catch {}   # fallback: app padrao
    return $false
}

# Gera uma pagina HTML local que toca o video. Abrir o .mov direto no navegador
# falha em varios PCs (tela branca), porque o player nativo nao reconhece o
# container QuickTime. Embutindo num <video> com type="video/mp4" o navegador usa
# o demuxer de MP4 (que le .mov/H.264) e roda igual em todo lugar. Autoplay com
# som as vezes e bloqueado: cai pra mudo automaticamente e um clique reativa o som.
function Escreve-PlayerHtml($caminhoVideo) {
    $nomeArq = [IO.Path]::GetFileName($caminhoVideo)
    $ext = [IO.Path]::GetExtension($caminhoVideo).ToLower()
    # O mesmo recurso de "video" tambem serve para enviar imagem. Quando o arquivo
    # e uma imagem, embrulhar num <video> mostra tela preta com controle de play.
    # Detecta a extensao e gera <img> em vez de <video>.
    $ehImagem = @('.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp') -contains $ext
    if ($ehImagem) {
        $html = @"
<!doctype html><html><head><meta charset="utf-8"><title>imagem</title>
<style>html,body{margin:0;height:100%;background:#000;overflow:hidden}
img{position:fixed;inset:0;width:100vw;height:100vh;object-fit:contain;background:#000}</style>
</head><body>
<img src="$nomeArq" alt="">
</body></html>
"@
    } else {
        $html = @"
<!doctype html><html><head><meta charset="utf-8"><title>video</title>
<style>html,body{margin:0;height:100%;background:#000;overflow:hidden}
video{position:fixed;inset:0;width:100vw;height:100vh;object-fit:contain;background:#000}</style>
</head><body>
<video id="v" autoplay controls playsinline>
<source src="$nomeArq" type="video/mp4"><source src="$nomeArq"></video>
<script>var v=document.getElementById("v");
function go(){var p=v.play();if(p&&p.catch){p.catch(function(){v.muted=true;v.play();});}}
v.addEventListener("canplay",go);
document.addEventListener("click",function(){v.muted=false;v.play();});go();</script>
</body></html>
"@
    }
    $caminhoHtml = "$caminhoVideo.html"
    try { [IO.File]::WriteAllText($caminhoHtml, $html, [Text.Encoding]::UTF8); return $caminhoHtml } catch { return $null }
}

function Estado-Padrao { [pscustomobject]@{ versaoAplicada=0; versaoPendente=0; extPendente=""; aplicarEm=$null; versaoIgnorada=0; abrirNavegadorPendente=$false; versaoVideoAberta=0; caminhoAplicado=""; versaoAdiadaExcl=0; versaoVideoAdiadaExcl=0; videoFalhaVersao=0; videoFalhas=0 } }

# Le o estado TOLERANDO arquivo corrompido. Sem isso, um agent-state.json truncado
# (queda de luz/desligamento no meio do Salva-Estado) fazia o ConvertFrom-Json
# falhar, $estado virava $null e TODO ciclo morria em "A propriedade
# 'versaoPendente' nao foi encontrada neste objeto" - para sempre, porque o arquivo
# ruim nunca era reescrito. O PC ficava vivo no painel mas nunca mais recebia
# imagem. Agora: JSON invalido = volta ao padrao e REGRAVA o arquivo (auto-cura).
function Carrega-Estado {
    if (-not (Test-Path $CaminhoEstado)) { return (Estado-Padrao) }
    $bruto = $null
    try { $bruto = Get-Content $CaminhoEstado -Raw -ErrorAction Stop } catch { return (Estado-Padrao) }
    $e = $null
    try { $e = $bruto | ConvertFrom-Json -ErrorAction Stop } catch { $e = $null }
    if ($null -eq $e -or -not $e.PSObject.Properties['versaoAplicada']) {
        $e = Estado-Padrao
        Salva-Estado $e
        Escreve-Log "Estado corrompido (agent-state.json invalido); recomecado do zero."
    }
    return $e
}

# Grava primeiro num .tmp e so entao renomeia: se o PC desligar no meio, o
# agent-state.json antigo continua inteiro (evita a corrupcao acima na origem).
function Salva-Estado($estado) {
    $tmp = "$CaminhoEstado.tmp"
    try {
        $estado | ConvertTo-Json | Set-Content $tmp -Encoding UTF8 -ErrorAction Stop
        Move-Item -Path $tmp -Destination $CaminhoEstado -Force -ErrorAction Stop
    } catch {
        try { $estado | ConvertTo-Json | Set-Content $CaminhoEstado -Encoding UTF8 } catch {}
    }
}

# Agendamento: data invalida NAO pode derrubar o ciclo. O [datetime]::Parse direto
# lancava excecao a cada 5s quando o aplicarEm vinha com lixo -> a imagem nunca era
# aplicada e o log so enchia de ERRO. Nao parseou = trata como "sem agendamento" e
# aplica na hora (mesmo comportamento do agente Python).
function Agendado-ParaFuturo($valor) {
    if (-not $valor) { return $false }
    $quando = [datetime]::MinValue
    if (-not [datetime]::TryParse("$valor", [ref]$quando)) { return $false }
    return ((Get-Date) -lt $quando.ToLocalTime())
}

# Garante que o agente volte a iniciar SOZINHO em todo logon/reboot, mesmo que o
# Setup nao tenha conseguido configurar isso. Tres redundancias (uma falhando, as
# outras cobrem): Tarefa Agendada (powershell direto, nao depende do wscript),
# chave Run (via .vbs, sem flash de console) e o proprio .vbs recriado.
# Idempotente e a prova de falhas: nunca derruba o agente.
function Garante-AutoInicio {
    try {
        $launcherVbs = Join-Path $PastaTrabalho "iniciar-oculto.vbs"
        # (re)cria o launcher .vbs se sumir ou apontar para outro caminho
        $vbs = 'CreateObject("WScript.Shell").Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""' + $PSCommandPath + '""", 0, False'
        $vbsAtual = if (Test-Path $launcherVbs) { Get-Content $launcherVbs -Raw -ErrorAction SilentlyContinue } else { "" }
        if ($vbsAtual -notlike "*$PSCommandPath*") { Set-Content -Path $launcherVbs -Value $vbs -Encoding ASCII -ErrorAction SilentlyContinue }

        # chave Run (inicia no logon, sem admin, sem flash)
        $runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
        Set-ItemProperty -Path $runKey -Name "WallpaperSync" -Value ("wscript.exe `"$launcherVbs`"") -ErrorAction SilentlyContinue

        # Tarefa Agendada: inicia no logon, ao DESBLOQUEAR a tela E se repete a cada
        # 2 min (watchdog). Se o agente morrer no meio da sessao (crash, auto-update
        # que nao subiu, etc.), a tarefa o relanca em ate 2 min - o mutex de instancia
        # unica evita duplicatas. Re-registra sempre (-Force) para que PCs com a tarefa
        # antiga ganhem a configuracao nova na proxima vez que o agente rodar.
        # IMPORTANTE: chama via wscript.exe + .vbs (janela 0 = oculta), NUNCA
        # powershell.exe direto, senao a repeticao PISCA um cmd na tela.
        $acao      = New-ScheduledTaskAction -Execute "wscript.exe" -Argument ("`"$launcherVbs`"")
        $gatilho   = New-ScheduledTaskTrigger -AtLogOn
        # A repeticao de 2 min (watchdog) fica num gatilho de TEMPO PROPRIO, NUNCA
        # anexada ao AtLogOn. Anexar ao logon gera um <LogonTrigger> SEM
        # <StartBoundary>: sem ancora de tempo o Windows nao agenda a repeticao
        # (NextRunTime fica vazio) e o watchdog NUNCA dispara -> se o agente morrer
        # no meio da sessao ele fica morto ate o proximo unlock/reboot.
        # Medido em 17/07/2026: com a repeticao no logon o agente NAO voltou em 240s
        # (nem apos um reboot); com gatilho de tempo proprio volta sozinho em ~2 min.
        # Mesma correcao ja aplicada no agente Python (ver _WATCHDOG_XML la).
        $gTempo    = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(-1) -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration (New-TimeSpan -Days 3650)
        # Gatilho extra: ao DESBLOQUEAR a tela (StateChange=8 = SessionUnlock). Cobre
        # o caso do usuario que bloqueia/desloga e volta - relanca na hora, sem esperar
        # os 2 min. Best-effort: se a classe CIM nao existir, segue so com logon+repeticao.
        $gatilhos = @($gatilho, $gTempo)
        try {
            $tUnlock = New-CimInstance -CimClass (Get-CimClass -Namespace root/Microsoft/Windows/TaskScheduler -ClassName MSFT_TaskSessionStateChangeTrigger) -ClientOnly
            $tUnlock.StateChange = 8
            $tUnlock.UserId = $env:USERNAME
            $gatilhos += $tUnlock
        } catch {}
        $cfg       = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName "WallpaperSync" -Action $acao -Trigger $gatilhos -Settings $cfg -Principal $principal -Force -ErrorAction Stop | Out-Null
    } catch {
        # Fallback final: schtasks repetindo a cada 2 min, tambem via wscript (oculto)
        try { & schtasks /Create /TN "WallpaperSync" /TR "wscript.exe `"$launcherVbs`"" /SC MINUTE /MO 2 /F 2>$null | Out-Null } catch {}
    }
}

# Baixa um arquivo com timeout de LEITURA de verdade e confere o tamanho.
# O Invoke-WebRequest -TimeoutSec so vale para os cabecalhos: quando o servidor
# manda o Content-Length e para de enviar no meio, quem decide e o ReadWriteTimeout,
# cujo default do .NET e 300s - medido: o agente ficava 5 MINUTOS preso num download
# morto, sem heartbeat, sumindo do painel. Aqui: 30s sem receber um byte = desiste.
# O confere-tamanho evita o pior caso, que era abrir um video TRUNCADO na cara do
# cliente e marca-lo como visto (nunca mais tentava).
function Baixa-Arquivo($url, $destino, $timeoutSeg = 90) {
    $req = [Net.HttpWebRequest]::Create($url)
    $req.Timeout          = $timeoutSeg * 1000
    $req.ReadWriteTimeout = 30000
    $req.UserAgent        = "WallpaperSync"
    $resp = $req.GetResponse()
    try {
        $esperado = $resp.ContentLength
        $entrada  = $resp.GetResponseStream()
        $saida    = [IO.File]::Create($destino)
        try { $entrada.CopyTo($saida) } finally { $saida.Dispose(); $entrada.Dispose() }
    } finally { $resp.Dispose() }
    if ($esperado -ge 0) {
        $real = (Get-Item $destino).Length
        if ($real -ne $esperado) { throw "download incompleto: $real de $esperado bytes" }
    }
}

# Normaliza texto p/ comparar alvo: minusculas e sem acentos (igual ao painel)
function Normaliza($s) {
    if (-not $s) { return "" }
    $t = $s.ToString().Trim().ToLowerInvariant().Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object Text.StringBuilder
    foreach ($ch in $t.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}

# Decide se esta imagem se destina a este PC (alvo: todos/nome/setor/cargo).
# Aceita varios valores-alvo: valores[] (novo) ou valor unico (compat antigo).
function Alvo-Confere($alvo, $nome, $setor, $cargo) {
    if (-not $alvo) { return $true }                       # sem alvo = todos (agentes/servidores antigos)
    $tipo = "$($alvo.tipo)".Trim()
    if (-not $tipo -or $tipo -eq "todos") { return $true }

    # lista de valores-alvo normalizados
    $valores = @()
    if ($alvo.PSObject.Properties['valores'] -and $alvo.valores) {
        $valores = @($alvo.valores | ForEach-Object { Normaliza $_ } | Where-Object { $_ -ne "" })
    } elseif ($alvo.valor) {
        $valores = @(Normaliza $alvo.valor) | Where-Object { $_ -ne "" }
    }
    if ($valores.Count -eq 0) { return $true }             # alvo vazio = todos

    switch ($tipo) {
        "nome"  { return ($valores -contains (Normaliza $nome)) }
        "cargo" { return ($valores -contains (Normaliza $cargo)) }
        "setor" {
            $meusSetores = @("$setor".Split(',') | ForEach-Object { Normaliza $_ })
            foreach ($v in $valores) { if ($meusSetores -contains $v) { return $true } }
            return $false
        }
        default { return $true }
    }
}

# Setor excluido: PCs cujo setor esta na lista "excluidos" do Firebase NAO recebem
# NADA - nem imagem, nem video, mesmo num envio para "todos". Fail-open: se nao
# conseguir ler a lista, nao bloqueia.
function Setor-Excluido($setor) {
    $meus = @("$setor".Split(',') | ForEach-Object { Normaliza $_ } | Where-Object { $_ -ne "" })
    if ($meus.Count -eq 0) { return $false }
    $excl = $null
    try { $excl = Invoke-RestMethod -Uri (Url-Firebase "excluidos") -TimeoutSec 15 } catch { return $false }
    if (-not $excl) { return $false }
    $alvos = @()
    foreach ($p in $excl.PSObject.Properties) {
        $v = $p.Value
        if ($v -and $v.PSObject.Properties['norm'] -and $v.norm)        { $alvos += (Normaliza $v.norm) }
        elseif ($v -and $v.PSObject.Properties['setor'] -and $v.setor)  { $alvos += (Normaliza $v.setor) }
    }
    foreach ($m in $meus) { if ($alvos -contains $m) { return $true } }
    return $false
}

# Auto-update: baixa a versao mais nova do agente do Firebase e se reinicia
function Auto-Atualiza {
    $vRemota = 0
    try { $vRemota = [int](Invoke-RestMethod -Uri (Url-Firebase "agent/versao") -TimeoutSec 15) } catch { return }
    if ($vRemota -le $AgentVersao) { return }
    $codigo = $null
    try { $codigo = Invoke-RestMethod -Uri (Url-Firebase "agent/codigo") -TimeoutSec 60 } catch { return }
    if (-not $codigo -or $codigo.Length -lt 200) { return }   # sanidade
    Escreve-Log "Auto-update: v$AgentVersao -> v$vRemota."
    Set-Content -Path $PSCommandPath -Value $codigo -Encoding UTF8
    $launcher = Join-Path $PastaTrabalho "iniciar-oculto.vbs"
    try { $mutex.ReleaseMutex(); $mutex.Dispose() } catch {}
    if (Test-Path $launcher) { Start-Process "wscript.exe" -ArgumentList ("`"$launcher`"") | Out-Null }
    else { Start-Process "powershell.exe" -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" | Out-Null }
    exit
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$estado = Carrega-Estado
# Estado antigo (de versoes anteriores do agente) pode nao ter os campos; garante-os.
if ($null -eq $estado.PSObject.Properties['versaoIgnorada']) { $estado | Add-Member -NotePropertyName versaoIgnorada -NotePropertyValue 0 }
if ($null -eq $estado.PSObject.Properties['aplicadoEm'])     { $estado | Add-Member -NotePropertyName aplicadoEm -NotePropertyValue $null }
if ($null -eq $estado.PSObject.Properties['abrirNavegadorPendente']) { $estado | Add-Member -NotePropertyName abrirNavegadorPendente -NotePropertyValue $false }
if ($null -eq $estado.PSObject.Properties['versaoVideoAberta'])      { $estado | Add-Member -NotePropertyName versaoVideoAberta -NotePropertyValue 0 }
if ($null -eq $estado.PSObject.Properties['videoAbertoEm'])          { $estado | Add-Member -NotePropertyName videoAbertoEm -NotePropertyValue $null }
if ($null -eq $estado.PSObject.Properties['caminhoAplicado'])        { $estado | Add-Member -NotePropertyName caminhoAplicado -NotePropertyValue "" }
if ($null -eq $estado.PSObject.Properties['versaoAdiadaExcl'])       { $estado | Add-Member -NotePropertyName versaoAdiadaExcl -NotePropertyValue 0 }
if ($null -eq $estado.PSObject.Properties['versaoVideoAdiadaExcl'])  { $estado | Add-Member -NotePropertyName versaoVideoAdiadaExcl -NotePropertyValue 0 }
if ($null -eq $estado.PSObject.Properties['videoFalhaVersao'])       { $estado | Add-Member -NotePropertyName videoFalhaVersao -NotePropertyValue 0 }
if ($null -eq $estado.PSObject.Properties['videoFalhas'])            { $estado | Add-Member -NotePropertyName videoFalhas -NotePropertyValue 0 }

$chave  = $env:COMPUTERNAME -replace '[.#$\[\]/]', '_'   # chave unica no Firebase

# Identidade deste PC (usada para decidir se a imagem se destina a ele).
# Comeca pelos arquivos locais; o heartbeat sincroniza com o painel (Firebase).
$nomeExib  = $env:COMPUTERNAME
if (Test-Path $CaminhoNome)  { $v = (Get-Content $CaminhoNome  -Raw -ErrorAction SilentlyContinue); if ($v) { $nomeExib  = $v.Trim() } }
$setorExib = ""
if (Test-Path $CaminhoSetor) { $v = (Get-Content $CaminhoSetor -Raw -ErrorAction SilentlyContinue); if ($v) { $setorExib = $v.Trim() } }
$cargoExib = ""
if (Test-Path $CaminhoCargo) { $v = (Get-Content $CaminhoCargo -Raw -ErrorAction SilentlyContinue); if ($v) { $cargoExib = $v.Trim() } }
$so = try { if ([int](Get-CimInstance Win32_OperatingSystem).BuildNumber -ge 22000) { "Windows 11" } else { "Windows 10" } } catch { "Windows" }
$proximoHeartbeat = Get-Date
# Info de boot: mostra se o PC reiniciou e ha quanto tempo esta ligado (ajuda a
# distinguir "PC foi reiniciado/desligado" de "agente caiu com o PC ligado").
$infoBoot = try { $b = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime; "PC ligado desde {0} (ha {1}h)." -f $b.ToString('dd/MM HH:mm'), [math]::Round(((Get-Date) - $b).TotalHours, 1) } catch { "" }
Escreve-Log "Agente iniciado v$AgentVersao (PID $PID, loop ${IntervaloSeg}s). $infoBoot"
if ($relancouTravado) { Escreve-Log "Watchdog: instancia anterior estava travada; assumida por esta." }
Garante-AutoInicio   # auto-cura o inicio automatico (tarefa agendada + chave Run)

$ultimoCiclo = Get-Date
while ($true) {
    # Detecta buraco de tempo entre ciclos: se o loop (5s) ficou parado por varios
    # minutos, o PC provavelmente dormiu/hibernou/bloqueou ou o processo travou -
    # exatamente quando ele some do painel. Registra pra descobrir a causa depois.
    $gap = ((Get-Date) - $ultimoCiclo).TotalSeconds
    if ($gap -gt 180) {
        Escreve-Log ("Retomou apos {0} min parado (provavel suspensao/hibernacao/bloqueio de tela ou travamento) - ficou offline no painel nesse periodo." -f [math]::Round($gap / 60, 1))
    }
    $ultimoCiclo = Get-Date

    # Sinal de vida: permite ao watchdog detectar se esta instancia travar.
    try { [IO.File]::WriteAllText($CaminhoAlive, (Get-Date -Format o)) } catch {}
    try {
        # --- heartbeat periodico: aparece online no painel do admin ---
        if ((Get-Date) -ge $proximoHeartbeat) {
            try {
                $nomeLocal = $env:COMPUTERNAME
                if (Test-Path $CaminhoNome) { $n = (Get-Content $CaminhoNome -Raw -ErrorAction SilentlyContinue); if ($n) { $nomeLocal = $n.Trim() } }
                $setorLocal = ""
                if (Test-Path $CaminhoSetor) { $s = (Get-Content $CaminhoSetor -Raw -ErrorAction SilentlyContinue); if ($s) { $setorLocal = $s.Trim() } }
                $cargoLocal = ""
                if (Test-Path $CaminhoCargo) { $c = (Get-Content $CaminhoCargo -Raw -ErrorAction SilentlyContinue); if ($c) { $cargoLocal = $c.Trim() } }

                # O painel pode editar nome/setor/cargo: o Firebase e a fonte da verdade.
                # Se ja houver valor remoto, ele vence; senao usa o local (definido na instalacao).
                $nomeExib  = $nomeLocal
                $setorExib = $setorLocal
                $cargoExib = $cargoLocal
                try {
                    $remoto = Invoke-RestMethod -Uri (Url-Firebase "pcs/$chave") -TimeoutSec 15
                    if ($remoto) {
                        if ($remoto.nome)  { $nomeExib  = "$($remoto.nome)".Trim() }
                        if ($remoto.setor) { $setorExib = "$($remoto.setor)".Trim() }
                        if ($remoto.cargo) { $cargoExib = "$($remoto.cargo)".Trim() }
                    }
                } catch {}
                # Persiste localmente o que veio do painel (sobrevive a reinicios)
                if ($nomeExib  -and $nomeExib  -ne $nomeLocal)  { Set-Content -Path $CaminhoNome  -Value $nomeExib  -Encoding UTF8 }
                if ($setorExib -and $setorExib -ne $setorLocal) { Set-Content -Path $CaminhoSetor -Value $setorExib -Encoding UTF8 }
                if ($cargoExib -and $cargoExib -ne $cargoLocal) { Set-Content -Path $CaminhoCargo -Value $cargoExib -Encoding UTF8 }

                # "resgate": o para-quedas esta instalado neste PC? (coluna do painel)
                $temResgate = Test-Path (Join-Path $PastaTrabalho "Resgate.ps1")
                $corpoMapa = @{ nome = $nomeExib; setor = $setorExib; cargo = $cargoExib; vistoEm = @{ ".sv" = "timestamp" }; vistoPs = @{ ".sv" = "timestamp" }; versaoAplicada = [int]$estado.versaoAplicada; versaoIgnorada = [int]$estado.versaoIgnorada; versaoVideoAberta = [int]$estado.versaoVideoAberta; so = $so; agenteVersao = [int]$AgentVersao; resgate = [bool]$temResgate; versaoPs = [int]$AgentVersao }
                if ($estado.aplicadoEm) { $corpoMapa.aplicadoEm = [long]$estado.aplicadoEm }
                if ($estado.videoAbertoEm) { $corpoMapa.videoAbertoEm = [long]$estado.videoAbertoEm }
                $corpoPc = $corpoMapa | ConvertTo-Json
                # Envia como bytes UTF-8 explicitos: o Windows PowerShell 5.1 corrompe
                # acentos (�f§/�f£/�f©) quando o corpo vai como string sem charset.
                $bytesPc = [System.Text.Encoding]::UTF8.GetBytes($corpoPc)
                try {
                    Invoke-RestMethod -Uri (Url-Firebase "pcs/$chave") -Method Patch -Body $bytesPc -ContentType "application/json; charset=utf-8" -TimeoutSec 15 | Out-Null
                    Registra-Heartbeat $true $null
                } catch { Registra-Heartbeat $false $_.Exception.Message }
            } catch {}
            Sobe-Log        # sobe as ultimas linhas do log pro painel
            $proximoHeartbeat = (Get-Date).AddSeconds($HeartbeatSeg)
            Auto-Atualiza   # checa se ha versao nova do agente
        }

        # --- checagem barata: so o numero da versao ---
        $versaoRemota = 0
        try { $versaoRemota = [int](Invoke-RestMethod -Uri (Url-Firebase "$FirebaseNode/versao") -TimeoutSec 15) } catch {}

        if ($versaoRemota -gt 0 -and $versaoRemota -ne $estado.versaoAplicada -and $versaoRemota -ne $estado.versaoPendente -and $versaoRemota -ne $estado.versaoIgnorada) {
            # Exclusao vem PRIMEIRO e apenas ADIA: nao baixa a imagem toda e NAO queima
            # a versao (nada de versaoIgnorada). Enquanto o setor estiver excluido a
            # versao fica segurada; ao sair da lista de excluidos ela volta a ser
            # avaliada e aplicada sozinha, sem precisar reenviar.
            if (Setor-Excluido $setorExib) {
                if ($estado.versaoAdiadaExcl -ne $versaoRemota) {
                    $estado.versaoAdiadaExcl = $versaoRemota
                    Salva-Estado $estado
                    Escreve-Log "Versao $versaoRemota adiada (setor excluido); volta sozinha ao sair da exclusao."
                }
            } else {
                # Versao nova: agora sim baixa os dados inteiros (inclui o alvo)
                $dados = Invoke-RestMethod -Uri (Url-Firebase $FirebaseNode) -TimeoutSec 60
                if ($dados -and $dados.imagem) {
                    if (Alvo-Confere $dados.alvo $nomeExib $setorExib $cargoExib) {
                        $ext     = if ($dados.ext) { $dados.ext } else { ".jpg" }
                        # Nome unico por versao: o Windows ignora a troca se o caminho
                        # for sempre o mesmo. Limpa imagens antigas para nao acumular.
                        Get-ChildItem -Path $PastaTrabalho -Filter "wallpaper-*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
                        $destino = "$CaminhoImagem-$versaoRemota$ext"
                        # Base64 corrompido no Firebase fazia o FromBase64String lancar a
                        # cada 5s, para sempre (o ciclo inteiro morria junto: video e trava
                        # do wallpaper nem rodavam). Agora a versao ruim e DESCARTADA.
                        $bytesImg = $null
                        try { $bytesImg = [Convert]::FromBase64String($dados.imagem) } catch { $bytesImg = $null }
                        # So descarta quando o decode FALHOU/veio vazio. Nada de limiar de
                        # tamanho: um PNG minusculo (70 bytes) e uma imagem valida.
                        if ($null -eq $bytesImg -or $bytesImg.Length -eq 0) {
                            $estado.versaoIgnorada = $versaoRemota
                            Salva-Estado $estado
                            Escreve-Log "Versao $versaoRemota descartada: imagem invalida/corrompida no Firebase (reenvie o papel de parede)."
                        } else {
                            [IO.File]::WriteAllBytes($destino, $bytesImg)
                            $estado.versaoPendente = $versaoRemota
                            $estado.extPendente    = $ext
                            $estado.aplicarEm      = $dados.aplicarEm
                            $estado.abrirNavegadorPendente = [bool]$dados.abrirNavegador
                            Salva-Estado $estado
                            Escreve-Log "Baixada versao $versaoRemota (agendada: $($dados.aplicarEm))."
                        }
                    } else {
                        # Imagem destinada a outro PC/setor/cargo: marca como vista e ignora.
                        $estado.versaoIgnorada = $versaoRemota
                        Salva-Estado $estado
                        Escreve-Log "Versao $versaoRemota ignorada (alvo: $($dados.alvo.tipo)=$($dados.alvo.valor))."
                    }
                }
            }
        }

        # --- aplica o pendente (na hora, ou imediato se sem agendamento) ---
        if ($estado.versaoPendente -gt 0 -and $estado.versaoPendente -ne $estado.versaoAplicada) {
            $aplicar = -not (Agendado-ParaFuturo $estado.aplicarEm)
            if ($aplicar) {
                $destino = "$CaminhoImagem-$($estado.versaoPendente)$($estado.extPendente)"
                if (Test-Path $destino) {
                    # So marca como aplicada se o Windows confirmar (retorno != 0).
                    if (Define-PapelDeParede $destino) {
                        $estado.versaoAplicada  = $estado.versaoPendente
                        $estado.caminhoAplicado = $destino   # guarda p/ reforcar se o usuario trocar
                        $estado.aplicadoEm      = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                        # Abre a imagem no navegador, se o envio pediu (uma vez por versao).
                        if ($estado.abrirNavegadorPendente) {
                            if (Abre-NoNavegador $destino) { Escreve-Log "Imagem aberta no navegador." }
                            else { Escreve-Log "Nao foi possivel abrir a imagem no navegador." }
                            $estado.abrirNavegadorPendente = $false
                        }
                        Salva-Estado $estado
                        Escreve-Log "Papel de parede aplicado (versao $($estado.versaoAplicada))."
                        $proximoHeartbeat = Get-Date   # avisa o painel ja com a nova versao
                    } else {
                        Escreve-Log "Falha ao aplicar papel de parede (versao $($estado.versaoPendente)); tenta de novo no proximo ciclo."
                    }
                }
            }
        }

        # --- video: abre no navegador do PC; NAO mexe no papel de parede ---
        $versaoVideo = 0
        try { $versaoVideo = [int](Invoke-RestMethod -Uri (Url-Firebase "video/versao") -TimeoutSec 15) } catch {}
        if ($versaoVideo -gt 0 -and $versaoVideo -ne $estado.versaoVideoAberta) {
            # Exclusao vem PRIMEIRO e apenas ADIA: se o setor estiver excluido, segura o
            # video sem baixar nem marcar como visto; ao sair da exclusao ele abre sozinho.
            if (Setor-Excluido $setorExib) {
                if ($estado.versaoVideoAdiadaExcl -ne $versaoVideo) {
                    $estado.versaoVideoAdiadaExcl = $versaoVideo
                    Salva-Estado $estado
                    Escreve-Log "Video $versaoVideo adiado (setor excluido); volta sozinho ao sair da exclusao."
                }
            }
            # So baixa o video inteiro se NAO estiver excluido.
            elseif (($dadosV = Invoke-RestMethod -Uri (Url-Firebase "video") -TimeoutSec 120) -and ($dadosV.url -or $dadosV.video)) {
                if (-not (Alvo-Confere $dadosV.alvo $nomeExib $setorExib $cargoExib)) {
                    # Destinado a outro PC\setor\cargo: marca como visto e ignora.
                    Escreve-Log "Video $versaoVideo ignorado (alvo nao confere)."
                    $estado.versaoVideoAberta = $versaoVideo
                    Salva-Estado $estado
                }
                elseif (Agendado-ParaFuturo $dadosV.aplicarEm) {
                    # Agendado para o futuro: nao abre ainda e NAO marca como visto,
                    # para reavaliar nos proximos ciclos (abre quando a hora chegar,
                    # mesmo que o PC so ligue depois). Sem log para nao poluir.
                }
                else {
                    $extV = if ($dadosV.ext) { $dadosV.ext } else { ".mp4" }
                    # Nome unico por versao; limpa videos antigos para nao acumular.
                    Get-ChildItem -Path $PastaTrabalho -Filter "video-*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
                    $destinoV = Join-Path $PastaTrabalho "video-$versaoVideo$extV"
                    # Download protegido: URL 404/link quebrado repetia o erro a cada 5s
                    # PARA SEMPRE (nada marcava o video como resolvido). E o TimeoutSec de
                    # 300 deixava o agente 5 min preso num download que nao termina - sem
                    # heartbeat, ou seja, sumindo do painel. Agora: 90s de teto e desiste
                    # depois de 3 tentativas.
                    $erroV = ""
                    try {
                        if ($dadosV.url) {
                            # Novo: video hospedado fora do RTDB; baixa por URL.
                            Baixa-Arquivo $dadosV.url $destinoV 90
                        } else {
                            # Compat: versao antiga guardava o video em base64 no RTDB.
                            [IO.File]::WriteAllBytes($destinoV, [Convert]::FromBase64String($dadosV.video))
                        }
                        if (-not (Test-Path $destinoV) -or (Get-Item $destinoV).Length -lt 100) {
                            $erroV = "arquivo vazio/truncado"
                        }
                    } catch { $erroV = $_.Exception.Message }

                    if ($erroV) {
                        if ($estado.videoFalhaVersao -ne $versaoVideo) {
                            $estado.videoFalhaVersao = $versaoVideo
                            $estado.videoFalhas = 0
                        }
                        $estado.videoFalhas = [int]$estado.videoFalhas + 1
                        if ([int]$estado.videoFalhas -ge 3) {
                            $estado.versaoVideoAberta = $versaoVideo   # desiste: para de tentar
                            Escreve-Log "Video $versaoVideo abandonado apos 3 falhas de download: $erroV"
                        } else {
                            Escreve-Log "Falha ao baixar o video $versaoVideo (tentativa $($estado.videoFalhas)/3): $erroV"
                        }
                        Remove-Item $destinoV -Force -ErrorAction SilentlyContinue
                        Salva-Estado $estado
                    } else {
                        # Abre via pagina HTML (toca .mov/.mp4 igual em todo PC); se nao
                        # der pra gravar o HTML, abre o arquivo direto.
                        $alvoAbrir = Escreve-PlayerHtml $destinoV
                        if (-not $alvoAbrir) { $alvoAbrir = $destinoV }
                        if (Abre-NoNavegador $alvoAbrir) {
                            Escreve-Log "Video $versaoVideo aberto no navegador."
                            $estado.videoAbertoEm = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                        }
                        else { Escreve-Log "Nao foi possivel abrir o video $versaoVideo no navegador." }
                        $estado.versaoVideoAberta = $versaoVideo
                        Salva-Estado $estado
                    }
                }
            }
        }

        # --- trava: se o usuario trocar o papel de parede, devolve o oficial ---
        # A cada ciclo confere o que esta no registro do Windows; se for diferente
        # do que foi aplicado por nos, recoloca na hora. So age se ja aplicamos algo.
        if ($estado.versaoAplicada -gt 0) {
            # Em PCs que ja estavam atualizados, caminhoAplicado vem vazio: reconstroi
            # a partir da versao aplicada (ex.: wallpaper-44.jpg) e persiste.
            if (-not $estado.caminhoAplicado) {
                $ext = if ($estado.extPendente) { $estado.extPendente } else { ".jpg" }
                $reconstruido = "$CaminhoImagem-$($estado.versaoAplicada)$ext"
                if (Test-Path $reconstruido) {
                    $estado.caminhoAplicado = $reconstruido
                    Salva-Estado $estado
                }
            }
            if ($estado.caminhoAplicado -and (Test-Path $estado.caminhoAplicado)) {
                $atual = ""
                try { $atual = (Get-ItemProperty "HKCU:\Control Panel\Desktop" -Name Wallpaper -ErrorAction SilentlyContinue).Wallpaper } catch {}
                if ("$atual" -ne "$($estado.caminhoAplicado)") {
                    if (Define-PapelDeParede $estado.caminhoAplicado) {
                        Escreve-Log "Papel de parede foi alterado pelo usuario; oficial restaurado (versao $($estado.versaoAplicada))."
                    }
                }
            }
        }
    }
    catch {
        $msgErro = $_.Exception.Message
        Escreve-Log ("ERRO: " + $msgErro)
        Reporta-Erro $msgErro
    }

    Start-Sleep -Seconds $IntervaloSeg
}
