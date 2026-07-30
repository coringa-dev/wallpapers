#!/usr/bin/env python3
# ============================================================
#  agent-wallpaper.py  (roda no PC Linux do cliente)
#  Equivalente Linux do Agent-Wallpaper.ps1. Checa o Firebase a cada poucos
#  segundos e troca o papel de parede quando muda; tambem abre video/imagem
#  no navegador quando o painel manda. Cobre Cinnamon (Mint padrao), MATE,
#  Xfce e GNOME, com deteccao automatica do ambiente.
#
#  Inicia via systemd --user (Restart=always): se cair, volta sozinho em
#  segundos -- sem o problema de "ficar offline sozinho" do Windows.
#  So usa a biblioteca padrao do Python 3 (nada de pip).
# ============================================================

import os
import re
import sys
import glob
import json
import time
import base64
import shutil
import socket
import subprocess
import unicodedata
import uuid
import urllib.request
import urllib.error
from datetime import datetime

# ---------- CONFIGURACAO ----------
FIREBASE_DB_URL = "https://wallpaper-mdf-default-rtdb.firebaseio.com"
FIREBASE_NODE   = "wallpaper"   # no do RTDB com a imagem atual
FIREBASE_AUTH   = ""            # opcional: secret do DB se as regras exigirem auth
INTERVALO_SEG   = 5             # de quanto em quanto checa
HEARTBEAT_SEG   = 30            # de quanto em quanto avisa "estou online"
AGENT_VERSAO    = 6             # versao deste agente Linux
# ----------------------------------

BASE            = os.path.join(os.path.expanduser("~"), ".local", "share", "WallpaperSync")
CAMINHO_IMAGEM  = os.path.join(BASE, "wallpaper")
CAMINHO_ESTADO  = os.path.join(BASE, "agent-state.json")
CAMINHO_LOG     = os.path.join(BASE, "log.txt")
CAMINHO_NOME    = os.path.join(BASE, "nome.txt")
CAMINHO_SETOR   = os.path.join(BASE, "setor.txt")
CAMINHO_CARGO   = os.path.join(BASE, "cargo.txt")
CAMINHO_ALIVE   = os.path.join(BASE, "alive.txt")  # sinal de vida, lido pelo resgate.sh

os.makedirs(BASE, exist_ok=True)

# Ambiente grafico: os comandos de papel de parede (gsettings/xfconf) falam com
# o D-Bus da sessao. Sob systemd --user isso ja vem certo, mas garantimos defaults.
os.environ.setdefault("DISPLAY", ":0")
if "DBUS_SESSION_BUS_ADDRESS" not in os.environ:
    xdg = os.environ.get("XDG_RUNTIME_DIR")
    if xdg:
        os.environ["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=%s/bus" % xdg


# ---------- log ----------
def escreve_log(msg):
    try:
        linha = "%s  %s\n" % (datetime.now().strftime("%Y-%m-%d %H:%M:%S"), msg)
        with open(CAMINHO_LOG, "a", encoding="utf-8") as f:
            f.write(linha)
        # mantem so as ultimas 200 linhas
        with open(CAMINHO_LOG, "r", encoding="utf-8", errors="replace") as f:
            linhas = f.readlines()
        if len(linhas) > 200:
            with open(CAMINHO_LOG, "w", encoding="utf-8") as f:
                f.writelines(linhas[-200:])
    except Exception:
        pass


# ---------- helpers de Firebase (REST) ----------
def url_firebase(caminho):
    u = "%s/%s.json" % (FIREBASE_DB_URL.rstrip("/"), caminho)
    if FIREBASE_AUTH:
        u += "?auth=%s" % FIREBASE_AUTH
    return u


# fetch com novas tentativas so em falha de rede (igual ao servidor): erros HTTP
# nao sao repetidos, so quando a requisicao nem completa.
def _requisicao(url, metodo="GET", dados=None, timeout=15, tentativas=3):
    ultimo = None
    for i in range(tentativas):
        try:
            corpo = None
            req = urllib.request.Request(url, method=metodo)
            if dados is not None:
                corpo = json.dumps(dados).encode("utf-8")
                req.add_header("Content-Type", "application/json; charset=utf-8")
            with urllib.request.urlopen(req, corpo, timeout=timeout) as r:
                return r.read().decode("utf-8")
        except urllib.error.HTTPError:
            raise  # erro HTTP do Firebase: nao adianta repetir
        except Exception as e:
            ultimo = e
            if i < tentativas - 1:
                time.sleep(0.5 * (i + 1))
    raise ultimo


def fb_get(caminho, timeout=15):
    txt = _requisicao(url_firebase(caminho), "GET", None, timeout)
    return json.loads(txt) if txt else None


def fb_put(caminho, obj, timeout=15):
    return _requisicao(url_firebase(caminho), "PUT", obj, timeout)


# ---------- arquivos locais (nome/setor/cargo/estado) ----------
def le_local(caminho):
    try:
        with open(caminho, "r", encoding="utf-8") as f:
            return f.read().strip()
    except Exception:
        return ""


def escreve_local(caminho, valor):
    try:
        with open(caminho, "w", encoding="utf-8") as f:
            f.write(valor)
    except Exception:
        pass


def carrega_estado():
    padrao = {
        "versaoAplicada": 0, "versaoPendente": 0, "extPendente": "",
        "aplicarEm": None, "versaoIgnorada": 0, "abrirNavegadorPendente": False,
        "versaoVideoAberta": 0, "aplicadoEm": None, "caminhoAplicado": "",
        "videoAbertoEm": None,
        # setor excluido apenas ADIA (nao queima a versao): ao sair da exclusao a
        # versao volta a ser avaliada e aplicada sozinha, sem reenviar.
        "versaoAdiadaExcl": 0, "versaoVideoAdiadaExcl": 0,
        # tentativas de download do video atual (desiste apos 3 falhas)
        "videoFalhaVersao": 0, "videoFalhas": 0,
    }
    try:
        with open(CAMINHO_ESTADO, "r", encoding="utf-8") as f:
            atual = json.load(f)
        padrao.update(atual)  # garante campos novos sobre estado antigo
    except Exception:
        pass
    return padrao


def salva_estado(estado):
    # Grava num .tmp e so entao troca: desligamento no meio da escrita nao deixa o
    # agent-state.json truncado (o carrega_estado tolera, mas o PC perderia o estado
    # e reaplicaria tudo do zero).
    tmp = CAMINHO_ESTADO + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(estado, f)
        os.replace(tmp, CAMINHO_ESTADO)
    except Exception:
        try:
            with open(CAMINHO_ESTADO, "w", encoding="utf-8") as f:
                json.dump(estado, f)
        except Exception:
            pass


def baixa_arquivo(url, destino, timeout=90):
    """Baixa conferindo o tamanho. Sem essa checagem, uma conexao cortada no meio
    entregava um video TRUNCADO que era aberto na cara do cliente e marcado como
    visto (nunca mais tentava)."""
    with urllib.request.urlopen(url, timeout=timeout) as r, open(destino, "wb") as fh:
        shutil.copyfileobj(r, fh)
        esperado = r.headers.get("Content-Length")
    if esperado is not None:
        real = os.path.getsize(destino)
        if real != int(esperado):
            raise IOError("download incompleto: %d de %s bytes" % (real, esperado))


# ---------- alvo (todos/nome/setor/cargo) ----------
def normaliza(s):
    if not s:
        return ""
    t = unicodedata.normalize("NFD", str(s).strip().casefold())
    return "".join(c for c in t if unicodedata.category(c) != "Mn")


def alvo_confere(alvo, nome, setor, cargo):
    if not isinstance(alvo, dict):
        return True  # sem alvo = todos
    tipo = str(alvo.get("tipo", "")).strip()
    if not tipo or tipo == "todos":
        return True
    valores = []
    if alvo.get("valores"):
        valores = [normaliza(v) for v in alvo["valores"] if normaliza(v)]
    elif alvo.get("valor"):
        v = normaliza(alvo["valor"])
        if v:
            valores = [v]
    if not valores:
        return True
    if tipo == "nome":
        return normaliza(nome) in valores
    if tipo == "cargo":
        return normaliza(cargo) in valores
    if tipo == "setor":
        meus = [normaliza(x) for x in str(setor).split(",")]
        return any(v in meus for v in valores)
    return True


def esta_excluido(setor):
    """True se algum setor deste PC esta na lista de excluidos (Firebase 'excluidos').
    Setor excluido nao recebe NADA: nem imagem, nem video."""
    meus = [normaliza(x) for x in str(setor).split(",") if normaliza(x)]
    if not meus:
        return False
    try:
        excl = fb_get("excluidos")
    except Exception:
        return False  # sem acesso: nao bloqueia (fail-open)
    if not isinstance(excl, dict):
        return False
    alvos = set()
    for v in excl.values():
        if isinstance(v, dict):
            alvos.add(normaliza(v.get("norm") or v.get("setor")))
        elif v:
            alvos.add(normaliza(v))
    alvos.discard("")
    return any(m in alvos for m in meus)


# ---------- papel de parede (Cinnamon / GNOME / MATE / Xfce) ----------
def _run(cmd):
    # timeout obrigatorio: gsettings/xfconf-query falam com o D-Bus da sessao e, se
    # ele estiver morto/pendurado, o comando NUNCA retorna - o agente inteiro trava
    # (sem heartbeat, sumindo do painel) sem nenhum erro no log.
    try:
        return subprocess.run(cmd, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, timeout=15).returncode == 0
    except Exception:
        return False


def _saida(cmd, timeout=15):
    """Saida de um comando, "" se falhar/pendurar."""
    try:
        return subprocess.run(cmd, capture_output=True, text=True,
                              timeout=timeout).stdout.strip()
    except Exception:
        return ""


def _set_cinnamon(path, uri):
    ok = _run(["gsettings", "set", "org.cinnamon.desktop.background", "picture-uri", uri])
    _run(["gsettings", "set", "org.cinnamon.desktop.background", "picture-options", "zoom"])
    return ok


def _set_gnome(path, uri):
    ok = _run(["gsettings", "set", "org.gnome.desktop.background", "picture-uri", uri])
    _run(["gsettings", "set", "org.gnome.desktop.background", "picture-uri-dark", uri])
    _run(["gsettings", "set", "org.gnome.desktop.background", "picture-options", "zoom"])
    return ok


def _set_mate(path, uri):
    ok = _run(["gsettings", "set", "org.mate.background", "picture-filename", path])
    _run(["gsettings", "set", "org.mate.background", "picture-options", "zoom"])
    return ok


def _set_xfce(path, uri):
    props = _saida(["xfconf-query", "-c", "xfce4-desktop", "-l"]).splitlines()
    if not props:
        return False
    ok = False
    for p in props:
        if "last-image" in p or p.endswith("/image-path"):
            if _run(["xfconf-query", "-c", "xfce4-desktop", "-p", p, "-s", path]):
                ok = True
        if p.endswith("image-style"):  # 5 = zoomed (preenche a tela)
            _run(["xfconf-query", "-c", "xfce4-desktop", "-p", p, "-s", "5"])
    return ok


def _wallpaper_atual():
    """Papel de parede que o desktop diz estar usando (para a trava anti-troca).

    Antes so perguntava ao Cinnamon: em GNOME/MATE/Xfce o comando falhava, a
    resposta vinha vazia e a trava NUNCA restaurava - o usuario trocava o papel de
    parede e o agente deixava. Agora consulta os quatro."""
    for cmd in (
        ["gsettings", "get", "org.cinnamon.desktop.background", "picture-uri"],
        ["gsettings", "get", "org.gnome.desktop.background", "picture-uri"],
        ["gsettings", "get", "org.mate.background", "picture-filename"],
    ):
        v = _saida(cmd).strip("'\"")
        if v and v != "''":
            return v
    for p in _saida(["xfconf-query", "-c", "xfce4-desktop", "-l"]).splitlines():
        if "last-image" in p:
            v = _saida(["xfconf-query", "-c", "xfce4-desktop", "-p", p.strip()])
            if v:
                return v
    return ""


def define_papel_de_parede(path):
    uri = "file://" + path
    desktop = (os.environ.get("XDG_CURRENT_DESKTOP", "") + " " +
               os.environ.get("DESKTOP_SESSION", "")).lower()
    # tenta o ambiente atual primeiro; se nao colar, tenta os outros
    if "cinnamon" in desktop:
        ordem = [_set_cinnamon, _set_gnome, _set_mate, _set_xfce]
    elif "mate" in desktop:
        ordem = [_set_mate, _set_gnome, _set_cinnamon, _set_xfce]
    elif "xfce" in desktop:
        ordem = [_set_xfce, _set_gnome, _set_cinnamon, _set_mate]
    elif "gnome" in desktop:
        ordem = [_set_gnome, _set_cinnamon, _set_mate, _set_xfce]
    else:
        ordem = [_set_cinnamon, _set_gnome, _set_mate, _set_xfce]
    for fn in ordem:
        if fn(path, uri):
            return True
    return False


# Gera uma pagina HTML local que toca o video. Abrir o .mov direto no navegador
# falha em varios PCs (tela branca), porque o player nativo nao reconhece o
# container QuickTime. Embutindo num <video> com type="video/mp4" o navegador usa
# o demuxer de MP4 (que le .mov/H.264) e roda igual em todo lugar. Autoplay com
# som as vezes e bloqueado: cai pra mudo automaticamente e um clique reativa o som.
def escreve_player_html(caminho_video):
    nome_arq = os.path.basename(caminho_video)
    html = (
        '<!doctype html><html><head><meta charset="utf-8"><title>video</title>'
        '<style>html,body{margin:0;height:100%;background:#000;overflow:hidden}'
        'video{position:fixed;inset:0;width:100vw;height:100vh;object-fit:contain;'
        'background:#000}</style></head><body>'
        '<video id="v" autoplay controls playsinline>'
        '<source src="__SRC__" type="video/mp4"><source src="__SRC__"></video>'
        '<script>var v=document.getElementById("v");'
        'function go(){var p=v.play();if(p&&p.catch){p.catch(function(){v.muted=true;v.play();});}}'
        'v.addEventListener("canplay",go);'
        'document.addEventListener("click",function(){v.muted=false;v.play();});go();'
        '</script></body></html>'
    ).replace("__SRC__", nome_arq)
    caminho_html = caminho_video + ".html"
    try:
        with open(caminho_html, "w", encoding="utf-8") as f:
            f.write(html)
        return caminho_html
    except Exception:
        return ""


# Abre no navegador (Firefox/Chrome/etc.); por fim xdg-open (app padrao).
def abre_no_navegador(path):
    # Abre em TELA CHEIA, na frente de tudo, para o cliente ver na hora.
    # Chromium e derivados: --start-fullscreen; Firefox: --kiosk.
    # Ordem importa: Chrome/Edge/Brave/Firefox tocam mp4 (H.264); o Chromium puro
    # costuma faltar o codec ("No video with supported format..."), entao fica por
    # ultimo. Se so houver chromium, instale: sudo apt install chromium-codecs-ffmpeg-extra
    for b in ["google-chrome", "google-chrome-stable", "microsoft-edge",
              "brave-browser", "firefox", "chromium", "chromium-browser"]:
        if shutil.which(b):
            if b == "firefox":
                args = [b, "--kiosk", path]
            else:
                args = [b, "--new-window", "--start-fullscreen", path]
            try:
                subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                return True
            except Exception:
                pass
    if shutil.which("xdg-open"):
        try:
            subprocess.Popen(["xdg-open", path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return True
        except Exception:
            pass
    return False


# ---------- identidade do PC ----------
def descreve_so():
    de = os.environ.get("XDG_CURRENT_DESKTOP", "").split(":")[-1] or "Linux"
    nome = "Linux"
    try:
        with open("/etc/os-release") as f:
            for line in f:
                if line.startswith("PRETTY_NAME="):
                    nome = line.split("=", 1)[1].strip().strip('"')
                    break
    except Exception:
        pass
    return "%s (%s)" % (nome, de)


# id UNICO por instalacao. Muitos PCs Linux vem do mesmo hostname de fabrica E,
# pior, sao CLONADOS do mesmo disco -> /etc/machine-id e MAC vem IDENTICOS. Se a
# chave vier do hostname/machine-id, dois PCs colidem na mesma chave do Firebase e
# um herda a identidade do outro (nome/cargo duplicado, some do painel). Por isso
# sorteamos um id aleatorio na 1a execucao e guardamos em agent-id.txt: cada
# instalacao fica unica para sempre, mesmo em disco clonado.
CAMINHO_ID = os.path.join(BASE, "agent-id.txt")


def _id_instalacao():
    try:
        with open(CAMINHO_ID) as f:
            v = f.read().strip()
        if v:
            return v
    except Exception:
        pass
    # Sempre ALEATORIO: nao usar machine-id/MAC porque disco clonado os duplica.
    # Sorteado uma vez e guardado -> unico por instalacao, estavel para sempre.
    v = uuid.uuid4().hex[:12]
    try:
        with open(CAMINHO_ID, "w") as f:
            f.write(v)
    except Exception:
        pass
    return v


def _monta_chave():
    host = re.sub(r"[.#$\[\]/]", "_", socket.gethostname())
    iid = re.sub(r"[.#$\[\]/]", "_", _id_instalacao())
    return ("%s-%s" % (host, iid)) if iid else host


CHAVE = _monta_chave()
SO = descreve_so()

# valores correntes (sincronizados pelo heartbeat com o painel)
nome_exib = le_local(CAMINHO_NOME) or socket.gethostname()
setor_exib = le_local(CAMINHO_SETOR)
cargo_exib = le_local(CAMINHO_CARGO)


# ---------- reporta erro pro painel (erros/<chave>), com anti-spam ----------
_ult_erro_msg = ""
_ult_erro_vezes = 0


def reporta_erro(msg):
    global _ult_erro_msg, _ult_erro_vezes
    try:
        if str(msg) == _ult_erro_msg:
            _ult_erro_vezes += 1
            if _ult_erro_vezes % 10 != 0:  # mesmo erro repetido: nao reenvia toda vez
                return
        else:
            _ult_erro_msg = str(msg)
            _ult_erro_vezes = 1
        fb_put("erros/%s" % CHAVE, {
            "mensagem": str(msg),
            "em": {".sv": "timestamp"},
            "agentVersao": AGENT_VERSAO,
            "nome": nome_exib,
            "so": SO,
            "vezes": _ult_erro_vezes,
        })
    except Exception:
        pass


def deve_aplicar(aplicar_em):
    if not aplicar_em:
        return True
    try:
        quando = datetime.fromisoformat(str(aplicar_em).replace("Z", "+00:00")).astimezone()
        return datetime.now().astimezone() >= quando
    except Exception:
        return True


# Auto-update: baixa a versao mais nova do agente Linux (no "agent/linux" do
# Firebase, separado do codigo Windows que fica em "agent") e se reinicia.
def auto_atualiza():
    try:
        v = fb_get("agent/linux/versao", timeout=15)
        v_remota = int(v) if v else 0
    except Exception:
        return
    if v_remota <= AGENT_VERSAO:
        return
    try:
        codigo = fb_get("agent/linux/codigo", timeout=60)
    except Exception:
        return
    if not isinstance(codigo, str) or len(codigo) < 200:   # sanidade
        return
    # Sanidade DE VERDADE: se o codigo novo nao compilar (publicacao truncada, texto
    # cortado no RTDB), gravar por cima transforma o agente num script quebrado que o
    # systemd reinicia em loop para sempre - o PC morre e nao volta nem com update.
    try:
        compile(codigo, "agent-wallpaper.py", "exec")
    except SyntaxError as e:
        escreve_log("Auto-update IGNORADO: o codigo v%s nao compila (%s)." % (v_remota, e))
        return
    alvo = os.path.abspath(__file__)
    # Grava num .tmp e troca de uma vez: queda no meio da escrita deixaria o proprio
    # agente pela metade.
    try:
        tmp = alvo + ".novo"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(codigo)
        os.chmod(tmp, os.stat(alvo).st_mode)
        os.replace(tmp, alvo)
    except Exception as e:
        escreve_log("Falha ao gravar auto-update: %s" % e)
        return
    escreve_log("Auto-update: v%s -> v%s; reiniciando." % (AGENT_VERSAO, v_remota))
    try:
        os.execv(sys.executable, [sys.executable, alvo] + sys.argv[1:])
    except Exception as e:
        escreve_log("Falha ao reiniciar apos auto-update: %s" % e)


# ============================================================
#  loop principal
# ============================================================
def main():
    global nome_exib, setor_exib, cargo_exib

    estado = carrega_estado()
    proximo_heartbeat = 0.0
    escreve_log("Agente Linux iniciado (loop %ss) - %s." % (INTERVALO_SEG, SO))

    while True:
        # Sinal de vida a cada ciclo: e por ele que o resgate.sh distingue "vivo" de
        # "processo existe mas travado" (o systemd so enxerga processo morto).
        try:
            with open(CAMINHO_ALIVE, "w", encoding="utf-8") as fa:
                fa.write(datetime.now().isoformat())
        except Exception:
            pass

        try:
            agora = time.time()

            # --- heartbeat: aparece online no painel ---
            if agora >= proximo_heartbeat:
                # Auto-update junto do heartbeat (a cada ~30s), NAO a cada ciclo: no
                # loop de 5s eram 17 mil consultas por dia por PC so para perguntar
                # "tem versao nova?" (o agente Windows sempre fez no heartbeat).
                auto_atualiza()
                nome_local = le_local(CAMINHO_NOME) or socket.gethostname()
                setor_local = le_local(CAMINHO_SETOR)
                cargo_local = le_local(CAMINHO_CARGO)
                nome_exib, setor_exib, cargo_exib = nome_local, setor_local, cargo_local
                # painel e a fonte da verdade: se ja houver valor remoto, ele vence
                try:
                    remoto = fb_get("pcs/%s" % CHAVE)
                    if isinstance(remoto, dict):
                        if remoto.get("nome"):
                            nome_exib = str(remoto["nome"]).strip()
                        if remoto.get("setor"):
                            setor_exib = str(remoto["setor"]).strip()
                        if remoto.get("cargo"):
                            cargo_exib = str(remoto["cargo"]).strip()
                except Exception:
                    pass
                # persiste localmente o que veio do painel
                if nome_exib and nome_exib != nome_local:
                    escreve_local(CAMINHO_NOME, nome_exib)
                if setor_exib and setor_exib != setor_local:
                    escreve_local(CAMINHO_SETOR, setor_exib)
                if cargo_exib and cargo_exib != cargo_local:
                    escreve_local(CAMINHO_CARGO, cargo_exib)

                corpo = {
                    "nome": nome_exib, "setor": setor_exib, "cargo": cargo_exib,
                    "vistoEm": {".sv": "timestamp"},
                    "versaoAplicada": int(estado["versaoAplicada"]),
                    "versaoIgnorada": int(estado["versaoIgnorada"]),
                    "versaoVideoAberta": int(estado["versaoVideoAberta"]),
                    "so": SO, "agenteVersao": AGENT_VERSAO,
                }
                if estado.get("aplicadoEm"):
                    corpo["aplicadoEm"] = int(estado["aplicadoEm"])
                if estado.get("videoAbertoEm"):
                    corpo["videoAbertoEm"] = int(estado["videoAbertoEm"])
                try:
                    fb_put("pcs/%s" % CHAVE, corpo)
                except Exception:
                    pass
                proximo_heartbeat = time.time() + HEARTBEAT_SEG

            # --- checagem barata: so o numero da versao ---
            versao_remota = 0
            try:
                v = fb_get("%s/versao" % FIREBASE_NODE)
                versao_remota = int(v) if v else 0
            except Exception:
                versao_remota = 0

            if (versao_remota > 0 and versao_remota != estado["versaoAplicada"]
                    and versao_remota != estado["versaoPendente"]
                    and versao_remota != estado["versaoIgnorada"]):
                # Exclusao vem PRIMEIRO e apenas ADIA: nao baixa a imagem toda e NAO
                # queima a versao. Ao sair da lista de excluidos ela volta sozinha.
                if esta_excluido(setor_exib):
                    if estado.get("versaoAdiadaExcl") != versao_remota:
                        estado["versaoAdiadaExcl"] = versao_remota
                        salva_estado(estado)
                        escreve_log("Versao %s adiada (setor excluido); volta sozinha ao sair da exclusao." % versao_remota)
                else:
                    dados = fb_get(FIREBASE_NODE, timeout=60)
                    if isinstance(dados, dict) and dados.get("imagem"):
                        if alvo_confere(dados.get("alvo"), nome_exib, setor_exib, cargo_exib):
                            ext = dados.get("ext") or ".jpg"
                            for f in glob.glob(CAMINHO_IMAGEM + "-*"):
                                try:
                                    os.remove(f)
                                except Exception:
                                    pass
                            destino = "%s-%s%s" % (CAMINHO_IMAGEM, versao_remota, ext)
                            # Base64 corrompido no Firebase repetia o erro a cada 5s para
                            # sempre (e deixava um arquivo de 0 byte para tras). Descarta a
                            # versao ruim. So descarta se o decode FALHOU: um PNG de 70
                            # bytes e valido, entao nada de limiar de tamanho.
                            try:
                                bytes_img = base64.b64decode(dados["imagem"])
                            except Exception:
                                bytes_img = b""
                            if not bytes_img:
                                estado["versaoIgnorada"] = versao_remota
                                salva_estado(estado)
                                escreve_log("Versao %s descartada: imagem invalida/corrompida no Firebase (reenvie o papel de parede)." % versao_remota)
                            else:
                                with open(destino, "wb") as fh:
                                    fh.write(bytes_img)
                                estado["versaoPendente"] = versao_remota
                                estado["extPendente"] = ext
                                estado["aplicarEm"] = dados.get("aplicarEm")
                                estado["abrirNavegadorPendente"] = bool(dados.get("abrirNavegador"))
                                salva_estado(estado)
                                escreve_log("Baixada versao %s (agendada: %s)." % (versao_remota, dados.get("aplicarEm")))
                        else:
                            estado["versaoIgnorada"] = versao_remota
                            salva_estado(estado)
                            escreve_log("Versao %s ignorada (alvo nao confere)." % versao_remota)

            # --- aplica o pendente (na hora, ou no horario agendado) ---
            if estado["versaoPendente"] > 0 and estado["versaoPendente"] != estado["versaoAplicada"]:
                if deve_aplicar(estado.get("aplicarEm")):
                    destino = "%s-%s%s" % (CAMINHO_IMAGEM, estado["versaoPendente"], estado["extPendente"])
                    if os.path.exists(destino):
                        if define_papel_de_parede(destino):
                            estado["versaoAplicada"] = estado["versaoPendente"]
                            estado["caminhoAplicado"] = destino
                            estado["aplicadoEm"] = int(time.time() * 1000)
                            if estado["abrirNavegadorPendente"]:
                                if abre_no_navegador(destino):
                                    escreve_log("Imagem aberta no navegador.")
                                else:
                                    escreve_log("Nao foi possivel abrir a imagem no navegador.")
                                estado["abrirNavegadorPendente"] = False
                            salva_estado(estado)
                            escreve_log("Papel de parede aplicado (versao %s)." % estado["versaoAplicada"])
                            proximo_heartbeat = 0.0  # avisa o painel ja com a nova versao
                        else:
                            escreve_log("Falha ao aplicar papel de parede (versao %s); tenta no proximo ciclo." % estado["versaoPendente"])

            # --- video: abre no navegador; NAO mexe no papel de parede ---
            versao_video = 0
            try:
                vv = fb_get("video/versao")
                versao_video = int(vv) if vv else 0
            except Exception:
                versao_video = 0
            if versao_video > 0 and versao_video != estado["versaoVideoAberta"]:
                # Exclusao vem PRIMEIRO e apenas ADIA: nao baixa o video e nao marca
                # como visto. Ao sair da exclusao o video volta a ser aberto sozinho.
                if esta_excluido(setor_exib):
                    if estado.get("versaoVideoAdiadaExcl") != versao_video:
                        estado["versaoVideoAdiadaExcl"] = versao_video
                        salva_estado(estado)
                        escreve_log("Video %s adiado (setor excluido); volta sozinho ao sair da exclusao." % versao_video)
                else:
                    dadosv = fb_get("video", timeout=120)
                    if isinstance(dadosv, dict) and (dadosv.get("url") or dadosv.get("video")):
                        if not alvo_confere(dadosv.get("alvo"), nome_exib, setor_exib, cargo_exib):
                            # Destinado a outro PC/setor/cargo: marca como visto e ignora.
                            escreve_log("Video %s ignorado (alvo nao confere)." % versao_video)
                            estado["versaoVideoAberta"] = versao_video
                            salva_estado(estado)
                        elif not deve_aplicar(dadosv.get("aplicarEm")):
                            # Agendado para o futuro: nao abre ainda e NAO marca como visto,
                            # para reavaliar nos proximos ciclos (abre quando a hora chegar,
                            # mesmo que o PC so ligue depois).
                            pass
                        else:
                            extv = dadosv.get("ext") or ".mp4"
                            for f in glob.glob(os.path.join(BASE, "video-*")):
                                try:
                                    os.remove(f)
                                except Exception:
                                    pass
                            destinov = os.path.join(BASE, "video-%s%s" % (versao_video, extv))
                            # Download protegido: um link 404/quebrado repetia o erro a cada
                            # 5s PARA SEMPRE (nada marcava o video como resolvido). Agora
                            # confere o tamanho e desiste depois de 3 tentativas.
                            erro_v = ""
                            try:
                                if dadosv.get("url"):
                                    # Novo: video hospedado fora do RTDB; baixa por URL.
                                    baixa_arquivo(dadosv["url"], destinov, timeout=90)
                                else:
                                    # Compat: versao antiga guardava o video em base64 no RTDB.
                                    with open(destinov, "wb") as fh:
                                        fh.write(base64.b64decode(dadosv["video"]))
                                if not os.path.exists(destinov) or os.path.getsize(destinov) < 100:
                                    erro_v = "arquivo vazio/truncado"
                            except Exception as e:
                                erro_v = str(e)

                            if erro_v:
                                if estado.get("videoFalhaVersao") != versao_video:
                                    estado["videoFalhaVersao"] = versao_video
                                    estado["videoFalhas"] = 0
                                estado["videoFalhas"] = int(estado.get("videoFalhas") or 0) + 1
                                if estado["videoFalhas"] >= 3:
                                    estado["versaoVideoAberta"] = versao_video  # desiste
                                    escreve_log("Video %s abandonado apos 3 falhas de download: %s" % (versao_video, erro_v))
                                else:
                                    escreve_log("Falha ao baixar o video %s (tentativa %s/3): %s" % (versao_video, estado["videoFalhas"], erro_v))
                                try:
                                    os.remove(destinov)
                                except Exception:
                                    pass
                                salva_estado(estado)
                            else:
                                # Abre via pagina HTML (toca .mov/.mp4 igual em todo PC);
                                # se nao der pra gravar o HTML, abre o arquivo direto.
                                alvo_abrir = escreve_player_html(destinov) or destinov
                                if abre_no_navegador(alvo_abrir):
                                    escreve_log("Video %s aberto no navegador." % versao_video)
                                    estado["videoAbertoEm"] = int(time.time() * 1000)
                                else:
                                    escreve_log("Nao foi possivel abrir o video %s." % versao_video)
                                estado["versaoVideoAberta"] = versao_video
                                salva_estado(estado)

            # --- trava: se o usuario trocar o papel de parede, devolve o oficial ---
            if estado["versaoAplicada"] > 0 and estado.get("caminhoAplicado") and os.path.exists(estado["caminhoAplicado"]):
                atual = _wallpaper_atual()
                esperado = "file://" + estado["caminhoAplicado"]
                if atual and atual not in (esperado, estado["caminhoAplicado"]):
                    if define_papel_de_parede(estado["caminhoAplicado"]):
                        escreve_log("Papel de parede alterado pelo usuario; oficial restaurado (versao %s)." % estado["versaoAplicada"])

        except Exception as e:
            escreve_log("ERRO: %s" % e)
            reporta_erro(e)

        time.sleep(INTERVALO_SEG)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
