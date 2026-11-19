#!/usr/bin/env python3
"""Run Strata's setup.py with the model downloads started at once and overlapped with each other.

Colab VM 上で Strata の .venv の Python から実行する。Strata の setup.sh の代わりに使う。

setup.py は「Python パッケージ → エンジン → シャード 1 の取得 → その SHA-256 → シャード 2 の取得 → その SHA-256 →
画像エンコーダー → MTP の取得」を順番に行う。ここでは setup.py をモジュールとして読み込み、取得を別プロセスで先に始める。

  * シャード 1 と MTP は起動直後から取得する。setup.py が Python パッケージやエンジンを入れている間も進む
  * シャード 1 の転送が終わって SHA-256 の検証に入ったら、シャード 2 の取得を始める
  * シャード 2 の転送が終わったら、画像エンコーダーを取得する
  * MTP の変換 (setup.py と同じ mtp_pack.py / mtp_rt.py) は、MTP の取得が済み、setup.py が Python パッケージを入れ終え
    (Step 4 に入り)、llama.cpp の gguf-py が展開されたら始める。結果は別フォルダに作り、両方成功したら mtp/ に移す

取得と検証には setup.py 自身の download() と fetch_mtp() を使う。ピン留めされたサイズと SHA-256 の検証、完了印 (.done)、
途中からの再開は Strata のものがそのまま働く。検証は省かない。

setup.py 側の download() / fetch_mtp() は、同じファイルの先行取得が終わるまで待ってから元の処理を呼ぶ。先行取得が済んで
いれば元の処理は完了印を見てすぐに戻る。先行取得が失敗していれば、元の処理が続きから取得し直す。
MTP の変換が先に済めば setup.py は mtp/rt を見て変換を飛ばす。間に合わなければ fetch_mtp() で待ち、済んだ変換の
コマンドは実行しない。先行変換が失敗していれば setup.py が自分で変換する。
同じファイルを 2 つのプロセスが同時に書くことはない。

想定と違う Strata（関数が無い、ファミリーの形が違うなど）では先行取得をせず、setup.py をそのまま実行する。

各工程の時刻は STRATA_TIMELINE_LOG（既定 /content/strata-timeline.log）に JSON Lines で残す。
`python3 strata_fast.py --report <timeline.log>` で工程ごとの時間を表にする。この使い方は Strata を読み込まない。
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

TIMELINE = os.environ.get("STRATA_TIMELINE_LOG") or "/content/strata-timeline.log"
PREFETCH_DIR = Path(os.environ.get("STRATA_PREFETCH_LOG_DIR") or "/content/strata-prefetch")
DRIVE_WAIT_SEC = float(os.environ.get("STRATA_DRIVE_WAIT_SEC") or 240)   # how long the MTP decision waits for the mount
T0 = float(os.environ.get("STRATA_FAST_T0") or time.time())
os.environ["STRATA_FAST_T0"] = repr(T0)
_tl_lock = threading.Lock()


def tl(event: str, **kw) -> None:
    """One timeline record. Never raises: timing must not break the setup."""
    now = time.time()
    rec = {"t": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(now)) + f".{int(now % 1 * 1000):03d}",
           "s": round(now - T0, 1), "pid": os.getpid(), "event": event, **kw}
    try:
        with _tl_lock, open(TIMELINE, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    except OSError:
        pass


def say(msg: str) -> None:
    print(f"[fast] {msg}", flush=True)


def load_setup(root: Path):
    """Strata's setup.py as a module. ROOT inside it is the folder of setup.py, as when setup.sh runs it."""
    sys.path.insert(0, str(root))
    spec = importlib.util.spec_from_file_location("strata_setup", root / "setup.py")
    m = importlib.util.module_from_spec(spec)
    sys.modules["strata_setup"] = m
    sys.modules.setdefault("setup", m)
    spec.loader.exec_module(m)
    return m


# ---------------------------------------------------------------------------------------------------------------------
# The plan: which files to fetch early, where Strata itself will look for them


class Item:
    def __init__(self, name: str, kind: str, dst: Path, url: str = "", what: str = ""):
        self.name, self.kind, self.dst, self.url, self.what = name, kind, dst, url, what
        self.proc: subprocess.Popen | None = None
        self.log = PREFETCH_DIR / f"{name}.log"
        self.started = self.ended = None
        self.rc: int | None = None
        self.skipped = False                         # never launched: setup.py does this part itself
        self.size = 0                                # pinned bytes, when known
        self.env: dict[str, str] = {}                # extra environment for its job

    def key(self) -> str:
        return _key(self.dst)

    def running(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def finished(self) -> bool:
        return self.proc is not None and self.proc.poll() is not None

    def over(self) -> bool:
        return self.skipped or self.finished()

    def transfer_over(self) -> bool:
        """The bytes are on the disk: download() renamed the .part (the SHA-256 check may still run), or the job ended."""
        if self.finished():
            return True
        if self.proc is None or self.kind != "download":
            return False
        return self.dst.exists() and not self.dst.with_name(self.dst.name + ".part").exists()

    def last_line(self) -> str:
        try:
            with open(self.log, "rb") as f:
                f.seek(0, 2)
                f.seek(max(0, f.tell() - 600))
                text = f.read().decode("utf-8", "replace")
        except OSError:
            return ""
        lines = [x.strip() for x in text.replace("\r", "\n").split("\n") if x.strip()]
        return lines[-1] if lines else ""


def parse_setup_args(args: list[str]):
    ap = argparse.ArgumentParser(add_help=False)
    for opt in ("--family", "--model", "--data-dir", "--models-dir", "--gguf-dir", "--vision", "--mtp", "--drafter",
                "--port"):
        ap.add_argument(opt)
    return ap.parse_known_args(args)[0]


class Plan:
    def __init__(self):
        self.big: list[Item] = []        # shards, one after another: the next starts when the last one's bytes are in
        self.small: list[Item] = []      # after the last shard's bytes are in
        self.early: list[Item] = []      # at once, beside the first shard
        self.later: list[Item] = []      # when their conditions hold (the MTP items, see Prefetch._mtp)
        self.llama: Path | None = None   # llama.cpp's source folder (gguf-py for the MTP conversion)
        self.own_gguf = False            # 0.2.16+: the MTP tools write GGUF with Strata's own tools/strata_gguf.py, no llama.cpp
        # where this version's converted draft layer is cached: "hf://<owner>/<repo>/mtp-rt/<key>" (a private Hugging Face
        # repo) or a folder on the mounted Google Drive
        self.mtp_cache: str | None = None

    def all(self) -> list[Item]:
        return [*self.big, *self.small, *self.early, *self.later]


def make_plan(m, args: list[str]) -> Plan:
    """What to fetch and prepare early. Empty when this Strata or these arguments are not the expected shape."""
    plan = Plan()
    if os.environ.get("STRATA_FAST_PREFETCH", "1").strip() == "0":
        say("prefetch is off (STRATA_FAST_PREFETCH=0)")
        return plan
    if not sys.platform.startswith("linux"):
        return plan
    need = ("download", "fetch_mtp", "done", "model_file", "model_hf", "model_shards", "FAMILIES", "MODELS")
    missing = [n for n in need if not hasattr(m, n)]
    if missing:
        say(f"this Strata has no {', '.join(missing)}: no prefetch, setup.py runs as it is")
        tl("plan-skip", why="missing " + ",".join(missing))
        return plan
    a = parse_setup_args(args)
    if not (a.family and a.model and a.data_dir):
        tl("plan-skip", why="family/model/data-dir not given")
        return plan
    fam = m.FAMILIES.get(a.family)
    model = m.model_alias(a.model) if hasattr(m, "model_alias") else a.model
    if not isinstance(fam, dict) or fam.get("ready") or "hf" not in fam or model not in m.MODELS:
        say(f"family {a.family} / {model} is not the GGUF-shard layout this prefetch knows: setup.py runs as it is")
        tl("plan-skip", why="family layout")
        return plan

    data = Path(a.data_dir).expanduser().resolve()
    models_root = Path(a.models_dir).expanduser() if a.models_dir else data / "models"
    big = plan.big
    if not a.gguf_dir:
        shard_dir = models_root / (fam.get("tag", "") + model)
        for i in range(1, m.model_shards(fam, model) + 1):
            name = m.model_file(fam, model, i)
            dst = shard_dir / name
            if dst.exists() and m.done(dst):
                continue
            # setup.py links the original's shard 2 from another size that already has it, instead of downloading it
            if a.family in ("qwen", "coder") and name.endswith("00002-of-00002.gguf") and not dst.exists() and any(
                    m.done(p) for p in models_root.glob("*/Qwen3.8-Flash-Next-GSQ-RCO-*-00002-of-00002.gguf")):
                continue
            big.append(Item(f"shard{i}", "download", dst, m.model_hf(fam, model) + name, name))
        # fetched at once (fast_download): the connections shared in proportion to the bytes, so the shards end together
        if callable(getattr(m, "file_pin", None)):
            for it in big:
                pin = m.file_pin(it.url)
                it.size = int(pin[0]) if pin else 0
            total = sum(it.size for it in big)
            if total and all(it.size for it in big):
                for it in big:
                    it.env["STRATA_FAST_CONNS"] = str(max(4, min(28, round(FAST_CONNS * len(big) * it.size / total))))

    if a.vision in ("yes", "gpu", "cpu") and fam.get("mmproj") and fam.get("mmproj_hf"):
        dst = models_root / fam["mmproj"]
        if not (dst.exists() and m.done(dst)):
            plan.small.append(Item("mmproj", "download", dst, fam["mmproj_hf"] + fam["mmproj"], "vision encoder"))
    if a.mtp == "on" and a.drafter != "dflash2":
        mtp = data / "mtp"
        if not (mtp / "rt" / "experts.bin").exists():
            # Either the converted draft layer from the Google Drive cache, or: the ~5 GB of MTP tensors beside the first
            # shard, then setup.py's own conversion (mtp_pack.py, mtp_rt.py: minutes of CPU) as soon as its Python packages
            # and llama.cpp's gguf-py are there, and a copy of the result into the cache
            plan.later.append(Item("mtp", "mtp", mtp))
            tools = Path(m.ROOT) / "tools" if hasattr(m, "ROOT") else None
            if tools and (tools / "mtp_pack.py").is_file() and (tools / "mtp_rt.py").is_file():
                plan.own_gguf = own_gguf(tools)
                if not plan.own_gguf:
                    plan.llama = (m.home() if hasattr(m, "home") else Path(m.ROOT)) / "third_party" / "llama.cpp"
                plan.later.append(Item("mtpconv", "mtp-convert", mtp))
                plan.mtp_cache = cache_location(m, tools)
                if plan.mtp_cache:
                    plan.later.append(Item("mtprestore", "mtp-restore", mtp, plan.mtp_cache))
                    plan.later.append(Item("mtpsave", "mtp-save", mtp, plan.mtp_cache))
    return plan


def cache_location(m, tools: Path) -> str | None:
    """The cache entry for this version: a private Hugging Face repo (STRATA_HF_CACHE_REPO, "auto" for
    <user>/strata-colab-cache) when a token file is given, else the mounted Google Drive folder, else none."""
    key = mtp_cache_key(m, tools)
    repo = os.environ.get("STRATA_HF_CACHE_REPO", "").strip()
    if repo:
        token = _hf_token()
        if not token:
            say("MTP cache: STRATA_HF_CACHE_REPO is set but there is no HF token; no cache")
            tl("mtp-cache-skip", why="no hf token")
            return None
        if repo == "auto":
            user = hf_whoami(token)
            if not user:
                return None
            repo = f"{user}/strata-colab-cache"
        if repo.count("/") != 1:
            say(f"MTP cache: {repo} is not <owner>/<name>; no cache")
            return None
        return f"{HF_PREFIX}{repo}/mtp-rt/{key}"
    drive = os.environ.get("STRATA_DRIVE_CACHE_DIR", "").strip()
    if drive and os.environ.get("STRATA_DRIVE_TOKEN"):
        return str(Path(drive) / "mtp-rt" / key)
    return None


def own_gguf(tools: Path) -> bool:
    """0.2.16 and later: tools/_paths.py gives the MTP tools Strata's own GGUF writer (tools/strata_gguf.py), so the
    conversion needs no llama.cpp source (2026-11-19: waiting for llama.cpp skipped the early conversion: 246 s more)."""
    return (tools / "_paths.py").is_file() and (tools / "strata_gguf.py").is_file()


def mtp_cache_key(m, tools: Path) -> str:
    """What the converted draft layer depends on: the three MTP tools (the pinned checkpoint revision is in mtp_fetch.py),
    the expert format and llama.cpp's commit (its gguf-py writes the intermediate GGUF). Another version: another folder."""
    import hashlib
    h = hashlib.sha256(b"strata-colab mtp-rt v1\nq2_0\n")
    names = ("mtp_fetch.py", "mtp_pack.py", "mtp_rt.py") + (("_paths.py", "strata_gguf.py") if own_gguf(tools) else ())
    for name in names:
        p = tools / name
        h.update(name.encode() + b"\n" + (p.read_bytes() if p.is_file() else b"-"))
    h.update(str(getattr(m, "LLAMA_CPP_COMMIT", "")).encode())
    return h.hexdigest()[:20]


# ---------------------------------------------------------------------------------------------------------------------
# The prefetch jobs (one process per file) and their order


class Prefetch:
    def __init__(self, root: Path, plan: Plan):
        self.root, self.plan = root, plan
        self.big, self.small, self.early, self.later = plan.big, plan.small, plan.early, plan.later
        self.every = plan.all()
        self.items = {it.key(): it for it in self.every if it.kind == "download"}   # setup.py's download() by file
        self.by_name = {it.name: it for it in self.every}
        self.stop = threading.Event()
        self.step_seen = 0                           # the highest "Step n" setup.py has announced
        self.gate_waiting: set[str] = set()          # items setup.py is waiting for right now
        self.mtp_mode: str | None = None             # hit / miss / off once decided
        self.t_start = time.time()
        self.thread = threading.Thread(target=self._schedule, name="prefetch", daemon=True)

    def start(self) -> None:
        PREFETCH_DIR.mkdir(parents=True, exist_ok=True)
        say("prefetch: " + ", ".join(it.name for it in self.every) +
            f" (logs in {PREFETCH_DIR}, timeline in {TIMELINE})")
        self.thread.start()

    def note_step(self, n) -> None:
        try:
            self.step_seen = max(self.step_seen, int(n))
        except (TypeError, ValueError):
            pass

    def _llama_ready(self) -> bool:
        if self.plan.own_gguf:                       # nothing to wait for: the tools carry their own GGUF writer
            return True
        ll = self.plan.llama
        return ll is not None and (ll / "ggml" / "CMakeLists.txt").exists() and (ll / "gguf-py").is_dir()

    def _skip(self, it: Item, why: str, quiet: bool = False) -> None:
        it.skipped = True
        tl("prefetch-skip", item=it.name, why=why)
        if not quiet:
            say(f"{it.name}: not done early ({why}); setup.py does it itself")

    # ---- the MTP draft layer: from the Drive cache, or fetched and converted here (and then saved to the cache)

    def _drive_state(self) -> str | None:
        """What the Drive mount beside this run reported (bridge.sh / up.sh write "<token> <state>"), None while unknown."""
        path, token = os.environ.get("STRATA_DRIVE_STATUS", ""), os.environ.get("STRATA_DRIVE_TOKEN", "")
        try:
            got = Path(path).read_text(encoding="utf-8").split()
        except OSError:
            return None
        return got[1] if len(got) >= 2 and got[0] == token else None

    def _decide_mtp(self) -> None:
        if self.mtp_mode is not None or "mtp" not in self.by_name:
            return
        cache = self.plan.mtp_cache
        detail = None
        where = "Hugging Face" if cache and cache.startswith(HF_PREFIX) else "Google Drive"
        if cache is None:
            mode = "off"
        elif cache.startswith(HF_PREFIX):
            mode, detail = hf_probe(cache)
        else:
            drive = self._drive_state()
            waited = time.time() - self.t_start
            if drive is None and waited < DRIVE_WAIT_SEC and "mtp" not in self.gate_waiting:
                return                                   # the mount is still being tried
            detail = f"drive: {drive}"
            mode = "off" if drive != "mounted" else "hit" if (Path(cache) / "manifest.json").is_file() else "miss"
        self.mtp_mode = mode
        tl("mtp-cache", mode=mode, detail=detail, cache=cache)
        say({"hit": f"MTP draft layer: restoring the converted copy from {where} ({cache})",
             "miss": f"MTP draft layer: not in the {where} cache yet; it is converted here and saved to {cache}",
             "off": "MTP draft layer: no cache" + (f" ({where}: {detail})" if cache is not None else "")}[mode])
        for name in (("mtpsave",) if mode == "hit" else ("mtprestore",) if mode == "miss" else ("mtprestore", "mtpsave")):
            if name in self.by_name:
                self._skip(self.by_name[name], f"cache {mode}", quiet=True)

    def _mtp(self) -> None:
        self._decide_mtp()
        if self.mtp_mode is None:
            return
        fetch, conv = self.by_name.get("mtp"), self.by_name.get("mtpconv")
        restore, save = self.by_name.get("mtprestore"), self.by_name.get("mtpsave")
        if self.mtp_mode == "hit":
            if restore.proc is None and not restore.skipped:
                self._launch(restore)
                return
            if not restore.finished():
                return
            if restore.rc == 0:                          # the draft layer is in place: nothing else to do for it
                for it in (fetch, conv):
                    if it is not None and it.proc is None and not it.skipped:
                        self._skip(it, "restored from the cache", quiet=True)
                return
            # fetch and convert here after all. A copy that did not match its manifest (exit 4) is replaced by a new save;
            # an unreadable one (network, permissions) is left alone
            self.mtp_mode = "miss" if restore.rc == 4 else "off"
            tl("mtp-cache", mode=self.mtp_mode, after="restore failed")
            if self.mtp_mode == "miss" and save is not None and save.proc is None:
                save.skipped = False
        if fetch.proc is None and not fetch.skipped:
            self._launch(fetch)
        if conv is not None and conv.proc is None and not conv.skipped:
            if fetch.skipped or (fetch.finished() and fetch.rc != 0):
                self._skip(conv, "the MTP tensors were not fetched early")
            elif fetch.finished():
                # after setup.py installed its Python packages (Step 4 announced) and unpacked llama.cpp's gguf-py
                if self.step_seen >= 4 and self._llama_ready():
                    self._launch(conv)
                elif "mtp" in self.gate_waiting:
                    self._skip(conv, "Python packages or llama.cpp not ready when setup.py reached it")
        if save is not None and save.proc is None and not save.skipped and conv is not None and conv.over():
            if conv.rc == 0 and self.mtp_mode == "miss":
                self._launch(save)
            else:
                self._skip(save, "nothing converted here to save", quiet=True)

    def _shards_may_start(self) -> bool:
        """After the restore of the cached draft layer (or at once without one); 45 s at most."""
        restore = self.by_name.get("mtprestore")
        if restore is None or time.time() - self.t_start > 45:
            return True
        return self.mtp_mode is not None and (restore.skipped or restore.over())

    def rt_ready(self) -> bool:
        """The draft layer was put in place early (restored or converted)."""
        return any(self.by_name.get(n) is not None and self.by_name[n].rc == 0 for n in ("mtprestore", "mtpconv"))

    def wait_mtp(self) -> bool:
        """setup.py's fetch_mtp() is about to run: wait for the early MTP work. True when the tensors are fetched or the draft
        layer is in place, so setup.py's own fetch can be skipped."""
        t, last_say = time.time(), 0.0
        tl("gate-wait", item="mtp")
        self.gate_waiting.add("mtp")
        names = ("mtprestore", "mtp", "mtpconv")
        while True:
            self._reap()
            if self.mtp_mode is not None:
                items = [self.by_name[n] for n in names if n in self.by_name]
                if all(it.over() for it in items):
                    break
            if self.stop.is_set():
                break
            if time.time() - last_say >= 15:
                last_say = time.time()
                busy = next((self.by_name[n] for n in names if n in self.by_name and self.by_name[n].running()), None)
                line = busy.last_line() if busy else ""
                say(f"waiting for the early MTP work ({busy.name if busy else 'starting'}): {line}")
            time.sleep(1)
        self.gate_waiting.discard("mtp")
        self._reap()
        fetch = self.by_name.get("mtp")
        ok = self.rt_ready() or (fetch is not None and fetch.rc == 0)
        tl("gate-go", item="mtp", waited=round(time.time() - t, 1), ok=ok, rt_ready=self.rt_ready())
        return ok

    def _launch(self, it: Item) -> None:
        it.dst.parent.mkdir(parents=True, exist_ok=True)
        cmd = [sys.executable, str(Path(__file__).resolve()), "--job", it.kind, str(it.dst), it.url, it.what]
        log = open(it.log, "ab", buffering=0)
        it.proc = subprocess.Popen(cmd, cwd=str(self.root), stdout=log, stderr=subprocess.STDOUT,
                                   stdin=subprocess.DEVNULL, env=dict(os.environ, PYTHONUNBUFFERED="1", **it.env))
        log.close()
        it.started = time.time()
        tl("prefetch-start", item=it.name, file=it.dst.name)

    def _reap(self) -> None:
        for it in self.every:
            if it.finished() and it.ended is None:
                it.ended, it.rc = time.time(), it.proc.returncode
                tl("prefetch-end", item=it.name, rc=it.rc, secs=round(it.ended - it.started, 1))
                if it.rc != 0:
                    say(f"early {it.name} stopped (exit {it.rc}); setup.py does it itself. Log: {it.log}")

    def _schedule(self) -> None:
        try:
            queue = list(self.big)
            current: Item | None = None
            small_started = False
            said: set[str] = set()
            for it in self.early:
                self._launch(it)
            held: list[Item] = []
            if FAST_DL:
                # the shards are fetched with O_DIRECT and hashed as they arrive (fast_download): no SHA-256 pass afterwards to wait
                # for, so they all start at once and share the link. The cached MTP draft layer (0.8 GB, ~20 s alone) goes first:
                # beside the shards it took 229 s
                held, queue = queue, []
            while not self.stop.is_set():
                self._reap()
                self._mtp()
                if held and self._shards_may_start():
                    for it in held:
                        self._launch(it)
                    held = []
                    continue
                free = current is None or current.transfer_over()
                if current is not None and free and current.name not in said:
                    said.add(current.name)
                    tl("transfer-over", item=current.name)
                if free and queue:
                    current = queue.pop(0)
                    self._launch(current)
                    continue
                if not small_started and not queue and free:
                    for it in self.small:
                        self._launch(it)
                    small_started = True
                if small_started and all(it.over() for it in self.every):
                    self._reap()
                    tl("prefetch-all-ended")
                    return
                time.sleep(1)
        except Exception as e:                       # noqa: BLE001 - the gate then lets setup.py fetch what is left
            tl("prefetch-error", error=repr(e))
            say(f"prefetch scheduler failed ({e!r}); setup.py fetches what is left")
        finally:
            self.stop.set()

    def wait_for(self, it: Item, label: str) -> None:
        """Block until the job of `it` ended (or never will). Prints a progress line now and then for the status poll."""
        t = time.time()
        last_say = 0.0
        tl("gate-wait", item=it.name)
        self.gate_waiting.add(it.name)
        while True:
            self._reap()
            if it.over():
                break
            if it.proc is None and self.stop.is_set():   # the scheduler stopped before launching it
                break
            if time.time() - last_say >= 15:
                last_say = time.time()
                line = it.last_line()
                say(f"waiting for the prefetch of {label}: {line}" if line else f"waiting for the prefetch of {label}")
            time.sleep(1)
        self.gate_waiting.discard(it.name)
        self._reap()
        tl("gate-go", item=it.name, waited=round(time.time() - t, 1), rc=it.rc)

    def terminate(self) -> None:
        self.stop.set()
        for it in self.every:
            if it.running():
                it.proc.terminate()
        for it in self.every:
            if it.proc is not None:
                try:
                    it.proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    it.proc.kill()


# ---------------------------------------------------------------------------------------------------------------------
# Hooks in setup.py: the gate before its own download / fetch_mtp, and timing of its steps


def install_hooks(m, pf: Prefetch | None, port: str | None) -> None:
    if hasattr(m, "step"):
        orig_step = m.step

        def step(n, title, *a, **k):
            tl("step", n=n, title=str(title))
            if pf:
                pf.note_step(n)
            return orig_step(n, title, *a, **k)
        m.step = step

    if hasattr(m, "run"):
        orig_run = m.run

        def run(cmd, *a, **k):
            t = time.time()
            what = " ".join(Path(str(c)).name for c in list(cmd)[:3])
            mtp_item = pf.by_name.get("mtp") if pf else None
            if mtp_item is not None and pf.rt_ready() and any(Path(str(c)).name in ("mtp_pack.py", "mtp_rt.py") for c in cmd) \
                    and (mtp_item.dst / "rt" / "experts.bin").exists():
                # the draft layer is already in place (converted early with the same commands, or restored from Drive)
                tl("run-skip", cmd=what)
                say(f"{what}: already done early (prefetch)")
                return subprocess.CompletedProcess([str(c) for c in cmd], 0)
            tl("run-start", cmd=what)
            r = None
            try:
                r = orig_run(cmd, *a, **k)
                return r
            finally:
                tl("run-end", cmd=what, secs=round(time.time() - t, 1),
                   rc=getattr(r, "returncode", None))
        m.run = run

    if hasattr(m, "verify_sha256"):
        orig_verify = m.verify_sha256

        def verify_sha256(s, *a, **k):
            t = time.time()
            r = orig_verify(s, *a, **k)
            tl("sha256", file=Path(s).name, secs=round(time.time() - t, 1))
            return r
        m.verify_sha256 = verify_sha256

    if hasattr(m, "download"):
        orig_download = m.download

        def download(url, dst, *a, **k):
            it = pf.items.get(_key(dst)) if pf else None
            if it is not None:
                pf.wait_for(it, Path(dst).name)
            t = time.time()
            r = orig_download(url, dst, *a, **k)
            tl("download", file=Path(dst).name, secs=round(time.time() - t, 1), prefetched=it is not None)
            return r
        m.download = download

    if hasattr(m, "fetch_mtp"):
        orig_fetch_mtp = m.fetch_mtp

        def fetch_mtp(mtp, *a, **k):
            it = pf.by_name.get("mtp") if pf else None
            if it is not None and _key(mtp) == it.key():
                # setup.py runs mtp_pack.py and mtp_rt.py right after this: the early work finishes first
                if pf.wait_mtp():
                    tl("fetch_mtp", secs=0, prefetched=True)
                    say("the MTP draft layer is already " + ("in place (early)" if pf.rt_ready() else "fetched and checked (early)"))
                    return None
            t = time.time()
            r = orig_fetch_mtp(mtp, *a, **k)
            tl("fetch_mtp", secs=round(time.time() - t, 1), prefetched=False)
            return r
        m.fetch_mtp = fetch_mtp

    if callable(getattr(m, "get_llama_cpp", None)):
        m.__dict__["get_llama_cpp"] = shm_llama(m, m.get_llama_cpp)
    if callable(getattr(m, "engine_from_feed", None)):
        m.__dict__["engine_from_feed"] = feed_watch(m, m.engine_from_feed)

    # what Step 3 / Step 4 spend their time on (llama.cpp's source, the ready-made engine, the CUDA wheels)
    for name in ("pip_install", "get_llama_cpp", "get_prebuilt", "engine_from_feed", "pip_cuda_libs", "install_unpacked"):
        if callable(getattr(m, name, None)):
            m.__dict__[name] = _timed(name, getattr(m, name))

    if hasattr(m, "start"):
        orig_start = m.start

        def start(*a, **k):
            tl("start")
            no_fsync_off()                            # the server and everything it starts: the normal os.fsync
            shm_tmp_off()                             # ... and the normal temporary folder
            if port:
                threading.Thread(target=_watch_health, args=(port,), daemon=True).start()
            return orig_start(*a, **k)
        m.start = start


def _timed(name: str, fn):
    def wrapper(*a, **k):
        t = time.time()
        tl("fn-start", fn=name)
        ok = False
        try:
            r = fn(*a, **k)
            ok = True
            return r
        finally:
            tl("fn-end", fn=name, secs=round(time.time() - t, 1), ok=ok)
    return wrapper


def _key(p) -> str:
    """The same file whatever form of its path setup.py passes (no symlink resolution: the file may not exist yet)."""
    return os.path.normpath(os.path.abspath(str(p)))


def _watch_health(port: str) -> None:
    url = f"http://127.0.0.1:{port}/health"
    end = time.time() + 3 * 3600
    while time.time() < end:
        try:
            with urllib.request.urlopen(url, timeout=5) as r:
                if r.status == 200:
                    tl("healthy")
                    return
        except Exception:                            # noqa: BLE001 - still starting
            pass
        time.sleep(3)


# ---------------------------------------------------------------------------------------------------------------------
# Entry points


def run_job(root: Path, argv: list[str]) -> int:
    kind, dst = argv[0], Path(argv[1])
    url = argv[2] if len(argv) > 2 else ""
    what = (argv[3] if len(argv) > 3 else "") or None
    if kind == "mtp-restore":                         # these two do not need Strata's code
        return hf_restore(dst, url) if url.startswith(HF_PREFIX) else restore_mtp(dst, Path(url))
    if kind == "mtp-save":
        return hf_save(dst, url) if url.startswith(HF_PREFIX) else save_mtp(dst, Path(url))
    m = load_setup(root)
    if hasattr(m, "verify_sha256"):
        orig_verify = m.verify_sha256

        def verify_sha256(s, *a, **k):
            t = time.time()
            tl("sha256-start", file=Path(s).name)
            r = orig_verify(s, *a, **k)
            tl("sha256", file=Path(s).name, secs=round(time.time() - t, 1))
            return r
        m.verify_sha256 = verify_sha256
    if kind == "download":
        if fast_download(m, url, dst, what) is None:
            m.download(url, dst, what)
    elif kind == "mtp":
        m.fetch_mtp(dst, dict(os.environ))
    elif kind == "mtp-convert":
        return convert_mtp(m, dst)
    else:
        print(f"unknown job {kind}", file=sys.stderr)
        return 2
    return 0


# ---- the model's big files: fetched over many connections, hashed while they arrive, written past the page cache
#
# Strata's download() writes through the page cache and hashes the file again afterwards. On Colab that costs twice:
#   * vm.dirty_ratio is 2 (1.6 GB of unwritten data at most; /proc/sys is read-only). While a shard is written at 330 MB/s the
#     limit is always reached, and every other process that writes (pip, the engine's unpacking) waits: Step 3's pip took 241 s
#     instead of 15 s
#   * the SHA-256 is CPU bound (no SHA instructions, ~360 MB/s on one core): reading 54.8 GB back took 307 s after the transfer
# Here the pieces are hashed in order straight from memory, and written with O_DIRECT. The check is the same as Strata's: the
# pinned size and SHA-256 (file_pin), and the same finish mark ("sha256 <hex>" in <file>.done). Anything unexpected (no pin, a
# proxy, another size, a wrong hash) returns None, and Strata's own download() runs as before.

FAST_DL = os.environ.get("STRATA_FAST_DOWNLOAD", "1").strip() != "0"
FAST_CHUNK = 32 << 20                                 # bytes per request; a multiple of 4096 for O_DIRECT
FAST_CONNS = int(os.environ.get("STRATA_FAST_CONNS") or 16)
FAST_MIN_BYTES = int(os.environ.get("STRATA_FAST_MIN_BYTES") or (256 << 20))


class _Status(OSError):
    def __init__(self, code: int):
        super().__init__(f"HTTP {code}")
        self.code = code


class _RangeConn:
    """One kept-alive connection to the file's final URL, filling a buffer with one byte range at a time."""

    def __init__(self, src):
        self.src, self.c, self.url = src, None, None

    def reset(self):
        if self.c is not None:
            try:
                self.c.close()
            except Exception:                         # noqa: BLE001
                pass
        self.c = None

    def get(self, a: int, b: int, buf) -> None:
        import http.client
        import urllib.parse
        url = self.src()
        if url != self.url:                           # a fresh signed URL: a new connection for it
            self.reset()
            self.url = url
        u = urllib.parse.urlsplit(url)
        if self.c is None:
            cls = http.client.HTTPSConnection if u.scheme == "https" else http.client.HTTPConnection
            self.c = cls(u.hostname, u.port, timeout=60)
        self.c.request("GET", u.path + ("?" + u.query if u.query else ""),
                       headers={"Range": f"bytes={a}-{b}", "User-Agent": "strata-colab-cli"})
        r = self.c.getresponse()
        if r.status != 206:
            r.read()
            raise _Status(r.status)
        if not (r.headers.get("Content-Range") or "").startswith(f"bytes {a}-{b}/"):
            r.read()
            raise OSError(f"another range than {a}-{b}: {r.headers.get('Content-Range')}")
        mv, n, want = memoryview(buf), 0, b - a + 1
        while n < want:
            k = r.readinto(mv[n:want])
            if not k:
                raise OSError(f"the connection ended after {n} of {want} bytes")
            n += k
        if r.read(1):
            raise OSError("more bytes than the range")


def _resolve_final(url: str) -> tuple[str, int]:
    """The URL the file is served from after the Hub's redirect (a signed CDN address) and the file's length."""
    req = urllib.request.Request(url, headers={"User-Agent": "strata-colab-cli", "Range": "bytes=0-0"})
    with urllib.request.urlopen(req, timeout=60) as r:
        total = (r.headers.get("Content-Range") or "").rpartition("/")[2]
        return r.geturl(), int(total) if r.status == 206 and total.isdigit() else 0


# ---- the tensors iq_pack.py reads, kept in the page cache
# setup.py's Step 6 (tools/iq_pack.py) reads every non-expert tensor of both shards through np.memmap, right after the last
# shard is in.  The shards are written with O_DIRECT, so none of it is cached: live run 6 spent 41.5 s there (7.7 s in run 3,
# where it ran two minutes after the download).  The hasher reads the GGUF header from the first pieces (each tensor runs to the
# next one's offset); once the shard is complete and checked, those ranges are read back by 16 threads at once, so iq_pack
# finds them in the page cache instead of faulting them in one by one.
# Tried first, and dropped: writing those parts a second time through a buffered descriptor while the shard came in (run 7 in
# the hasher, run 8 from a thread of its own).  iq_pack went to 4.2 s, but the 777 scattered buffered writes held the shard
# back (shard 1: 243 s and 236 s instead of 187 s), so the start was later, not earlier.

PRECACHE = os.environ.get("STRATA_FAST_PRECACHE", "1").strip() != "0"
GGUF_HEADER_MAX = 256 << 20
PRECACHE_MAX = 8 << 30


class _NeedMore(Exception):
    pass


def gguf_ranges(buf, file_size: int, keep=lambda name, ggml_type: True) -> list[tuple[int, int]]:
    """[(start, end)] in the file of the tensors keep(name, ggml type) accepts, from a GGUF (v2/v3) header at the start of buf; _NeedMore when
    buf ends inside the header, ValueError when it is not GGUF."""
    with memoryview(buf) as mv:                       # released on the way out: buf (a bytearray) grows between tries
        return _gguf_ranges(mv, file_size, keep)


def _gguf_ranges(mv, file_size: int, keep) -> list[tuple[int, int]]:
    import struct
    pos = 0

    def take(fmt: str):
        nonlocal pos
        n = struct.calcsize(fmt)
        if pos + n > len(mv):
            raise _NeedMore
        v = struct.unpack_from(fmt, mv, pos)
        pos += n
        return v[0] if len(v) == 1 else v

    def string() -> str:
        nonlocal pos
        n = take("<Q")
        if pos + n > len(mv):
            raise _NeedMore
        s = bytes(mv[pos:pos + n]).decode("utf-8", "replace")
        pos += n
        return s

    scalar = {0: "<B", 1: "<b", 2: "<H", 3: "<h", 4: "<I", 5: "<i", 6: "<f", 7: "<?", 10: "<Q", 11: "<q", 12: "<d"}

    def value(t: int):
        nonlocal pos
        if t in scalar:
            return take(scalar[t])
        if t == 8:
            return string()
        if t == 9:
            et, count = take("<I"), take("<Q")
            if et in scalar:                          # skipped whole
                n = struct.calcsize(scalar[et]) * count
                if pos + n > len(mv):
                    raise _NeedMore
                pos += n
            else:
                for _ in range(count):
                    value(et)
            return None
        raise ValueError(f"GGUF value type {t}")

    if bytes(mv[:4]) != b"GGUF" and len(mv) >= 4:
        raise ValueError("not GGUF")
    take("<4s")
    if take("<I") not in (2, 3):
        raise ValueError("GGUF version")
    n_tensors, n_kv = take("<Q"), take("<Q")
    align = 32
    for _ in range(n_kv):
        key = string()
        v = value(take("<I"))
        if key == "general.alignment" and isinstance(v, int) and v > 0:
            align = v
    infos = []
    for _ in range(n_tensors):
        name = string()
        dims = take("<I")
        for _ in range(dims):
            take("<Q")
        ggml_type = take("<I")
        infos.append((take("<Q"), name, ggml_type))
    data = (pos + align - 1) // align * align
    infos.sort()
    out = []
    for j, (off, name, ggml_type) in enumerate(infos):
        end = infos[j + 1][0] if j + 1 < len(infos) else file_size - data
        if keep(name, ggml_type) and end > off:
            out.append((data + off, data + end))
    return out


GGML_FLOAT = {0, 1, 30}                               # F32, F16, BF16


def pack_reads(name: str, ggml_type: int) -> bool:
    """The tensors iq_pack.py reads the bytes of: not an expert (is_expert), not NOT_IN_PACK, stored as a float (FLOAT;
    quantized ones are served from the GGUF without being read).  Real shards (11/08): 1079 non-expert tensors in shard 1,
    and shard 2 is the single 26.8 GiB per_layer_token_embd.weight, which iq_pack leaves to the engine."""
    if name.startswith("blk.") and name.endswith("_exps.weight"):
        return False
    return name != "per_layer_token_embd.weight" and ggml_type in GGML_FLOAT


PRECACHE_THREADS = 16
PRECACHE_PIECE = 4 << 20


class _Precache:
    """Fed every piece in order (offset, bytes) until the GGUF header is read; warm(path) then reads the ranges iq_pack reads
    into the page cache with PRECACHE_THREADS threads."""

    def __init__(self, size: int):
        self.size, self.head, self.ranges = size, bytearray(), None
        self.bytes, self.secs, self.error = 0, 0.0, None

    def feed(self, off: int, mv) -> None:
        if self.ranges is not None or self.error:
            return
        t = time.time()
        try:
            self.head += mv
            try:
                ranges = gguf_ranges(self.head, self.size, pack_reads)
            except _NeedMore:
                if len(self.head) >= GGUF_HEADER_MAX:
                    raise ValueError("GGUF header longer than %d bytes" % GGUF_HEADER_MAX)
                return
            self.head = None
            total = sum(e - s for s, e in ranges)
            if total > PRECACHE_MAX:                  # not what iq_pack reads of a model like this one: leave it alone
                self.ranges = []
                raise ValueError(f"{total / 2**30:.1f} GiB of tensors to cache, more than {PRECACHE_MAX >> 30} GiB")
            self.ranges = ranges
        except ValueError as e:
            self.error = repr(e)[:200]
            self.head = None
        finally:
            self.secs += time.time() - t

    def warm(self, path: Path) -> dict:
        """Reads the ranges (in pieces of PRECACHE_PIECE, by several threads) so they are in the page cache."""
        import queue
        t = time.time()
        jobs: queue.Queue = queue.Queue()
        for s, e in self.ranges or []:
            for a in range(s // 4096 * 4096, e, PRECACHE_PIECE):
                jobs.put((a, min(PRECACHE_PIECE, e - a)))
        if not jobs.empty() and not self.error:
            fd = os.open(path, os.O_RDONLY)
            lock = threading.Lock()

            def reader() -> None:
                while True:
                    try:
                        a, n = jobs.get_nowait()
                    except queue.Empty:
                        return
                    try:
                        got = len(os.pread(fd, n, a))
                    except OSError as ex:
                        self.error = repr(ex)[:200]
                        return
                    with lock:
                        self.bytes += got
            try:
                ths = [threading.Thread(target=reader, daemon=True) for _ in range(PRECACHE_THREADS)]
                for th in ths:
                    th.start()
                for th in ths:
                    th.join()
            finally:
                os.close(fd)
        return {"bytes": self.bytes, "warm_secs": round(time.time() - t, 1), "header_secs": round(self.secs, 1),
                "tensors": len(self.ranges or []), "error": self.error}


def fast_download(m, url: str, dst: Path, what=None) -> int | None:
    """0 when dst was fetched, matched its pin and was marked; None when Strata's download() should do it (or redo it)."""
    import hashlib
    import queue
    dst = Path(dst)
    if not FAST_DL or not url.startswith(("https://", "http://")) or not hasattr(os, "pwrite"):
        return None
    if not all(callable(getattr(m, n, None)) for n in ("file_pin", "mark", "done")):
        return None
    if callable(getattr(m, "model_source", None)) and m.model_source() == "modelscope":
        return None
    if any(os.environ.get(k) for k in ("HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy")):
        return None
    pin = m.file_pin(url)
    if not pin or pin[0] < FAST_MIN_BYTES:
        return None
    size, sha = int(pin[0]), str(pin[1])
    if dst.exists() or dst.with_name(dst.name + ".part").exists():
        return None                                   # a finished or half-finished file of Strata's: its own logic knows it
    label = what or dst.name
    try:
        final, total = _resolve_final(url)
    except Exception as e:                            # noqa: BLE001
        print(f"[fast-dl] {label}: cannot ask the server ({e}); Strata's download takes over", flush=True)
        return None
    if total != size:
        print(f"[fast-dl] {label}: the server says {total:,} bytes, the pin {size:,}; Strata's download takes over", flush=True)
        return None

    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_name(dst.name + ".fastpart")
    direct = hasattr(os, "O_DIRECT")
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | (os.O_DIRECT if direct else 0), 0o644)
    except OSError:
        direct = False
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    import mmap
    if direct:                                        # a filesystem that takes the flag but refuses the writes: plain writes
        probe = mmap.mmap(-1, 4096)
        try:
            os.pwrite(fd, probe, 0)
        except OSError:
            os.close(fd)
            direct = False
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
        probe.close()
    t0 = time.time()
    n_chunks = -(-size // FAST_CHUNK)
    conns = max(1, min(FAST_CONNS, n_chunks))
    free: queue.Queue = queue.Queue()
    for _ in range(conns + 24):                       # page-aligned buffers (O_DIRECT needs aligned memory)
        free.put(mmap.mmap(-1, FAST_CHUNK))
    lock, cond = threading.Lock(), threading.Condition()
    state = {"next": 0, "got": 0, "hashed": 0, "url": final, "direct": direct}
    ready: dict[int, tuple] = {}
    errors: list[str] = []
    stop = threading.Event()
    digest: list[str] = []

    def src() -> str:
        return state["url"]

    def refresh() -> None:
        with lock:
            try:
                state["url"] = _resolve_final(url)[0]
            except Exception:                         # noqa: BLE001 - the retry says what went wrong
                pass

    def write(buf, n: int, off: int) -> None:
        mv = memoryview(buf)
        if state["direct"]:
            padded = (n + 4095) // 4096 * 4096        # the tail past the file's end is cut off by the final ftruncate
            try:
                if os.pwrite(fd, mv[:padded], off) == padded:
                    return
            except OSError:
                pass
            raise OSError("O_DIRECT write failed")
        done_n = 0
        while done_n < n:
            done_n += os.pwrite(fd, mv[done_n:n], off + done_n)

    def worker() -> None:
        conn = _RangeConn(src)
        try:
            while not stop.is_set():
                try:
                    buf = free.get(timeout=1)
                except queue.Empty:
                    continue
                with lock:                            # buffer first, then the next piece: the lowest piece in flight always has one
                    i = state["next"]
                    if i >= n_chunks:
                        free.put(buf)
                        return
                    state["next"] = i + 1
                a = i * FAST_CHUNK
                b = min(size, a + FAST_CHUNK) - 1
                for attempt in range(8):
                    if stop.is_set():
                        return
                    try:
                        conn.get(a, b, buf)
                        break
                    except _Status as e:
                        conn.reset()
                        if e.code in (401, 403, 410):     # the signed URL expired
                            refresh()
                        err = str(e)
                    except Exception as e:            # noqa: BLE001
                        conn.reset()
                        err = repr(e)
                    time.sleep(min(2 ** attempt, 15))
                else:
                    errors.append(f"bytes {a}-{b}: {err}")
                    stop.set()
                    return
                write(buf, b - a + 1, a)
                with cond:
                    state["got"] += b - a + 1
                    ready[i] = (buf, b - a + 1)
                    cond.notify_all()
        except Exception as e:                        # noqa: BLE001
            errors.append(repr(e))
            stop.set()
        finally:
            conn.reset()

    pre = _Precache(size) if PRECACHE and dst.suffix == ".gguf" and "-of-" in dst.name else None   # the shards, not mmproj

    def hasher() -> None:
        h = hashlib.sha256()
        for k in range(n_chunks):
            with cond:
                while k not in ready and not stop.is_set():
                    cond.wait(1)
                if k not in ready:
                    return
                buf, n = ready.pop(k)
            h.update(memoryview(buf)[:n])             # hashlib lets go of the GIL for big buffers
            if pre:
                pre.feed(k * FAST_CHUNK, memoryview(buf)[:n])
            state["hashed"] += n
            free.put(buf)
        digest.append(h.hexdigest())

    print(f"[fast-dl] {label}: {size / 1e9:.2f} GB over {conns} connections, hashed while it arrives"
          f"{' (O_DIRECT)' if direct else ''}", flush=True)
    tl("fast-dl-start", file=dst.name, bytes=size, conns=conns, direct=direct)
    threads = [threading.Thread(target=worker, daemon=True) for _ in range(conns)]
    hth = threading.Thread(target=hasher, daemon=True)
    for th in (*threads, hth):
        th.start()
    last = 0.0
    while hth.is_alive():
        hth.join(1)
        if time.time() - last >= 5:
            last = time.time()
            secs = max(time.time() - t0, 0.1)
            print(f"  {label}: {state['got'] / 1e9:6.2f} / {size / 1e9:.2f} GB received, {state['hashed'] / 1e9:6.2f} GB "
                  f"checked ({state['got'] / secs / 1e6:.0f} MB/s)", flush=True)
    stop.set()
    for th in threads:
        th.join(5)
    secs = time.time() - t0
    try:
        if digest:
            # no fsync: on Colab an fsync waits until every other big write on the disk has ended (measured: 56 s), and a VM that
            # crashes loses the whole disk anyway. The O_DIRECT writes are on the device already
            os.ftruncate(fd, size)
    finally:
        os.close(fd)
    if errors or not digest:
        print(f"[fast-dl] {label}: stopped ({'; '.join(errors[:3]) or 'incomplete'}); Strata's download takes over", flush=True)
        tl("fast-dl-end", file=dst.name, ok=False, secs=round(secs, 1), error=(errors[:1] or ["incomplete"])[0][:200])
        tmp.unlink(missing_ok=True)
        return None
    if digest[0] != sha or tmp.stat().st_size != size:
        print(f"[fast-dl] {label}: SHA-256 {digest[0][:12]}... is not the pinned {sha[:12]}...; the file is removed and "
              "Strata downloads it again", flush=True)
        tl("fast-dl-end", file=dst.name, ok=False, secs=round(secs, 1), error="sha256 mismatch")
        tmp.unlink(missing_ok=True)
        return None
    os.replace(tmp, dst)
    m.mark(dst, f"sha256 {sha}")                      # the same mark Strata writes after its own check
    tl("fast-dl-end", file=dst.name, ok=True, secs=round(secs, 1), mbps=round(size / secs / 1e6))
    print(f"[fast-dl] {label}: done and checked in {secs:.0f} s ({size / secs / 1e6:.0f} MB/s)", flush=True)
    if pre:
        try:
            tl("precache", file=dst.name, **pre.warm(dst))
        except OSError as e:
            tl("precache", file=dst.name, error=repr(e)[:200])
    return 0


def convert_mtp(m, mtp: Path) -> int:
    """setup.py's two MTP commands (mtp_pack.py, mtp_rt.py) with the same arguments, written into a folder beside `mtp` and
    moved into place only when both succeeded, so setup.py never sees half a draft layer (it checks mtp/rt/experts.bin)."""
    import shutil
    root = Path(m.ROOT)
    env = dict(os.environ, STRATA_EXIT_WITH_PARENT="1")
    if not own_gguf(root / "tools"):                 # older Strata: llama.cpp's gguf-py, as setup.py passes it
        llama = (m.home() if hasattr(m, "home") else root) / "third_party" / "llama.cpp"
        env["STRATA_GGUF_PY"] = str(llama / "gguf-py")
    tmp = mtp.parent / ".mtp-fast-convert"
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir(parents=True)
    steps = [
        [sys.executable, str(root / "tools" / "mtp_pack.py"), "--src", str(mtp), "--experts", "q2_0",
         "--out", str(tmp / "mtp-q2_0.gguf")],
        [sys.executable, str(root / "tools" / "mtp_rt.py"), "--gguf", str(tmp / "mtp-q2_0.gguf"), "--out", str(tmp / "rt")],
    ]
    for cmd in steps:
        t = time.time()
        print("  > " + " ".join(cmd), flush=True)
        r = subprocess.run(cmd, env=env)
        tl("convert-step", tool=Path(cmd[1]).name, rc=r.returncode, secs=round(time.time() - t, 1))
        if r.returncode != 0:
            shutil.rmtree(tmp, ignore_errors=True)
            return r.returncode
    if (mtp / "rt").exists():                         # setup.py made its own meanwhile: keep that one
        print("mtp/rt already exists; the early conversion is not used", flush=True)
        shutil.rmtree(tmp, ignore_errors=True)
        return 3
    # what mtp_rt.py wrote: the files a cache copy holds (setup.py adds draft_vocab.bin to rt/ later, by its own choice)
    names = sorted(p.name for p in (tmp / "rt").iterdir() if p.is_file())
    os.replace(tmp / "mtp-q2_0.gguf", mtp / "mtp-q2_0.gguf")
    os.replace(tmp / "rt", mtp / "rt")                # experts.bin appears together with the rest of rt/
    (mtp / RT_FILES).write_text(json.dumps(names), encoding="utf-8")
    shutil.rmtree(tmp, ignore_errors=True)
    return 0


RT_FILES = ".strata-fast-rt-files.json"


def _sha256(path: Path) -> str:
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(16 << 20), b""):
            h.update(b)
    return h.hexdigest()


def save_mtp(mtp: Path, cache: Path) -> int:
    """Copy the draft layer converted here into the Drive cache: <cache>/manifest.json lists each file's size and SHA-256.
    Written into a temporary folder and renamed, so a cut-off copy is never taken for a cache entry."""
    import shutil
    names = json.loads((mtp / RT_FILES).read_text(encoding="utf-8"))
    if cache.exists():
        print(f"{cache} is already there", flush=True)
        return 0
    t = time.time()
    tmp = cache.with_name(cache.name + f".tmp-{os.getpid()}")
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir(parents=True)
    files = {}
    for n in names:
        src = mtp / "rt" / n
        files[n] = {"bytes": src.stat().st_size, "sha256": _sha256(src)}
        shutil.copyfile(src, tmp / n)
    for n, meta in files.items():                     # read back what Drive holds now
        if (tmp / n).stat().st_size != meta["bytes"]:
            print(f"{n}: size differs after the copy", flush=True)
            shutil.rmtree(tmp, ignore_errors=True)
            return 4
    (tmp / "manifest.json").write_text(json.dumps({"files": files, "saved": time.strftime("%Y-%m-%d %H:%M:%S")},
                                                  indent=1), encoding="utf-8")
    try:
        os.rename(tmp, cache)
    except OSError as e:
        print(f"could not finish the cache entry ({e})", flush=True)
        shutil.rmtree(tmp, ignore_errors=True)
        return 5
    size = sum(v["bytes"] for v in files.values())
    secs = time.time() - t
    tl("mtp-saved", bytes=size, secs=round(secs, 1))
    print(f"saved {size / 1e9:.2f} GB to {cache} in {secs:.0f} s", flush=True)
    return 0


def restore_mtp(mtp: Path, cache: Path) -> int:
    """The cached draft layer into mtp/rt: copied beside it, every file checked against the manifest's size and SHA-256,
    then moved into place in one rename (setup.py looks for mtp/rt/experts.bin)."""
    import shutil
    t = time.time()
    files = json.loads((cache / "manifest.json").read_text(encoding="utf-8"))["files"]
    tmp = mtp.parent / ".mtp-fast-restore"
    shutil.rmtree(tmp, ignore_errors=True)
    (tmp / "rt").mkdir(parents=True)
    for n, meta in files.items():
        dst = tmp / "rt" / n
        shutil.copyfile(cache / n, dst)
        if dst.stat().st_size != meta["bytes"] or _sha256(dst) != meta["sha256"]:
            print(f"{n}: the cached copy does not match its manifest; it is set aside and made again", flush=True)
            shutil.rmtree(tmp, ignore_errors=True)
            try:                                       # the next save writes a good one in its place
                os.rename(cache, cache.with_name(cache.name + time.strftime(".bad-%Y%m%d-%H%M%S")))
            except OSError:
                pass
            return 4
    return _install_restored(mtp, tmp, files, t, str(cache))


def _install_restored(mtp: Path, tmp: Path, files: dict, t: float, src: str) -> int:
    """Move the checked copy in tmp/rt to mtp/rt in one rename (setup.py looks for mtp/rt/experts.bin)."""
    import shutil
    mtp.mkdir(parents=True, exist_ok=True)
    if (mtp / "rt").exists():
        print("mtp/rt already exists; the cached copy is not used", flush=True)
        shutil.rmtree(tmp, ignore_errors=True)
        return 3
    os.replace(tmp / "rt", mtp / "rt")
    shutil.rmtree(tmp, ignore_errors=True)
    size = sum(v["bytes"] for v in files.values())
    secs = time.time() - t
    tl("mtp-restored", bytes=size, secs=round(secs, 1))
    print(f"restored {size / 1e9:.2f} GB from {src} in {secs:.0f} s", flush=True)
    return 0


# ---- the cache in a private Hugging Face repo: read with the standard library (no installation before the restore), written
# with huggingface_hub in a folder of its own (pip --target) (the save is not in a hurry). The token is read from a file (STRATA_HF_TOKEN_FILE,
# mode 600); it never appears on a command line, and only the Hub itself is sent it.

HF_ENDPOINT = (os.environ.get("HF_ENDPOINT") or "https://huggingface.co").rstrip("/")
HF_PREFIX = "hf://"


def _hf_token() -> str:
    path = os.environ.get("STRATA_HF_TOKEN_FILE", "")
    try:
        return Path(path).read_text(encoding="utf-8").strip() if path else ""
    except OSError:
        return ""


def _hf_split(loc: str) -> tuple[str, str]:
    """"hf://owner/name/mtp-rt/<key>" -> ("owner/name", "mtp-rt/<key>")."""
    parts = loc[len(HF_PREFIX):].split("/", 2)
    return f"{parts[0]}/{parts[1]}", parts[2]


def _hf_url(repo: str, path: str) -> str:
    import urllib.parse
    return f"{HF_ENDPOINT}/{repo}/resolve/main/{urllib.parse.quote(path)}"


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_hf_opener = urllib.request.build_opener(_NoRedirect)


def _hf_open(url: str, token: str, headers: dict | None = None, timeout: float = 60):
    """GET `url`, following redirects by hand so that the token goes only to the Hub, never to the storage host a file
    redirects to (its signed URL is its own authorization). Returns (response, final url)."""
    import urllib.error
    import urllib.parse
    hub = urllib.parse.urlsplit(HF_ENDPOINT).netloc
    for _ in range(8):
        h = {"User-Agent": "strata-colab-cli", **(headers or {})}
        if token and urllib.parse.urlsplit(url).netloc == hub:
            h["Authorization"] = f"Bearer {token}"
        try:
            return _hf_opener.open(urllib.request.Request(url, headers=h), timeout=timeout), url
        except urllib.error.HTTPError as e:
            if e.code in (301, 302, 303, 307, 308) and e.headers.get("Location"):
                url = urllib.parse.urljoin(url, e.headers["Location"])
                e.close()
                continue
            raise
    raise OSError(f"too many redirects for {url}")


def hf_whoami(token: str) -> str | None:
    try:
        r, _ = _hf_open(f"{HF_ENDPOINT}/api/whoami-v2", token, timeout=20)
        with r:
            who = json.loads(r.read())
    except Exception as e:                           # noqa: BLE001 - no cache, the setup goes on
        say(f"MTP cache: could not ask Hugging Face who the token belongs to ({e}); no cache")
        tl("mtp-cache-skip", why=f"whoami: {e}")
        return None
    role = ((who.get("auth") or {}).get("accessToken") or {}).get("role")
    tl("hf-whoami", user=who.get("name"), role=role)
    if role == "read":
        say("MTP cache: the HF token can only read; a missing cache entry cannot be saved")
    return who.get("name")


def hf_probe(loc: str) -> tuple[str, str]:
    """hit when this version's manifest is in the repo, miss when it (or the repo) is not, off when the Hub cannot be asked."""
    import urllib.error
    repo, path = _hf_split(loc)
    try:
        r, _ = _hf_open(_hf_url(repo, path + "/manifest.json"), _hf_token(), timeout=20)
        with r:
            json.loads(r.read())["files"]
        return "hit", "manifest found"
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return "miss", e.headers.get("X-Error-Code") or "404"
        return "off", f"HTTP {e.code}"
    except Exception as e:                           # noqa: BLE001
        return "off", repr(e)


class _Mismatch(OSError):
    """The file in the repo is not the one its manifest describes."""


def _hf_fetch(repo: str, path: str, token: str, dst: Path, size: int, conns: int = 8) -> None:
    """One file of the repo into dst, in `conns` byte ranges at once (one stream from the CDN is slower than the VM's link)."""
    r, final = _hf_open(_hf_url(repo, path), token, headers={"Range": "bytes=0-0"})
    total = (r.headers.get("Content-Range") or "").rpartition("/")[2]
    r.close()
    if total.isdigit() and int(total) != size:
        raise _Mismatch(f"the repo holds {total} bytes, the manifest says {size}")
    with open(dst, "wb") as f:
        f.truncate(size)
    if size == 0:
        return
    parts = 1 if size < (64 << 20) else conns
    step = -(-size // parts)
    errors: list[Exception] = []

    def get(a: int, b: int) -> None:
        for attempt in range(3):
            try:
                resp, _ = _hf_open(final, token, headers={"Range": f"bytes={a}-{b}"}, timeout=120)
                n = 0
                with resp, open(dst, "r+b") as f:
                    if resp.status != 206 and not (a == 0 and b == size - 1):
                        raise OSError(f"the server ignored the byte range (HTTP {resp.status})")
                    f.seek(a)
                    while chunk := resp.read(8 << 20):
                        f.write(chunk)
                        n += len(chunk)
                if n != b - a + 1:
                    raise OSError(f"got {n} of {b - a + 1} bytes")
                return
            except Exception as e:                   # noqa: BLE001 - retried, then reported
                if attempt == 2:
                    errors.append(e)
                time.sleep(2)

    threads = [threading.Thread(target=get, args=(a, min(size, a + step) - 1)) for a in range(0, size, step)]
    for th in threads:
        th.start()
    for th in threads:
        th.join()
    if errors:
        raise errors[0]


def hf_restore(mtp: Path, loc: str) -> int:
    """The cached draft layer from the repo into mtp/rt, every file checked against the manifest's size and SHA-256.
    Exit 4: a file did not match (the save after the conversion here uploads a good copy over it); 5: could not read."""
    import shutil
    t = time.time()
    repo, path = _hf_split(loc)
    token = _hf_token()
    try:
        r, _ = _hf_open(_hf_url(repo, path + "/manifest.json"), token)
        with r:
            files = json.loads(r.read())["files"]
    except Exception as e:                           # noqa: BLE001
        print(f"could not read the manifest of {loc}: {e}", flush=True)
        return 5
    tmp = mtp.parent / ".mtp-fast-restore"
    shutil.rmtree(tmp, ignore_errors=True)
    (tmp / "rt").mkdir(parents=True)
    for n, meta in files.items():
        dst = tmp / "rt" / n
        try:
            _hf_fetch(repo, f"{path}/{n}", token, dst, int(meta["bytes"]))
        except _Mismatch as e:
            print(f"{n}: {e}; it is made here and uploaded again", flush=True)
            shutil.rmtree(tmp, ignore_errors=True)
            return 4
        except Exception as e:                       # noqa: BLE001
            print(f"{n}: could not fetch it ({e})", flush=True)
            shutil.rmtree(tmp, ignore_errors=True)
            return 5
        if dst.stat().st_size != meta["bytes"] or _sha256(dst) != meta["sha256"]:
            print(f"{n}: the cached copy does not match its manifest; it is made here and uploaded again", flush=True)
            shutil.rmtree(tmp, ignore_errors=True)
            return 4
    return _install_restored(mtp, tmp, files, t, loc)


HF_UPLOAD_PY = r"""
import sys
from huggingface_hub import HfApi
repo, path, folder, token_file = sys.argv[1:5]
api = HfApi(token=open(token_file, encoding="utf-8").read().strip())
print("repo:", api.create_repo(repo, private=True, exist_ok=True), flush=True)
info = api.upload_folder(repo_id=repo, folder_path=folder, path_in_repo=path,
                         commit_message="strata-colab: converted MTP draft layer " + path.rsplit("/", 1)[-1])
print("commit:", getattr(info, "commit_url", info), flush=True)
"""


def hf_save(mtp: Path, loc: str) -> int:
    """Upload the draft layer converted here with its manifest, in one commit (a half-uploaded entry is never seen). The repo is
    created private if it is missing. huggingface_hub goes into a folder of its own (STRATA_HF_LIB), not into Strata's."""
    import shutil
    t = time.time()
    names = json.loads((mtp / RT_FILES).read_text(encoding="utf-8"))
    repo, path = _hf_split(loc)
    # huggingface_hub goes into a folder of its own with the pip of this Python (Strata's .venv): Strata's packages are not
    # touched, and no venv is needed (Colab's system Python has no ensurepip)
    lib = Path(os.environ.get("STRATA_HF_LIB") or "/content/.strata-colab/hf-lib")
    py = sys.executable
    env = dict(os.environ, HF_HUB_DISABLE_TELEMETRY="1", PYTHONPATH=str(lib))
    have_hub = lib.is_dir() and subprocess.run([py, "-c", "import huggingface_hub"], env=env,
                                               capture_output=True).returncode == 0
    if not have_hub:
        print(f"installing huggingface_hub into {lib}", flush=True)
        if subprocess.run([py, "-m", "pip", "install", "-q", "--disable-pip-version-check", "--upgrade",
                           "--target", str(lib), "huggingface_hub[hf_xet]"]).returncode != 0:
            print("could not install huggingface_hub", flush=True)
            return 6
    tmp = mtp.parent / ".mtp-fast-upload"
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir(parents=True)
    files = {}
    for n in names:
        src = mtp / "rt" / n
        try:
            os.link(src, tmp / n)                     # same disk: no copy of 0.8 GB
        except OSError:
            shutil.copyfile(src, tmp / n)
        files[n] = {"bytes": src.stat().st_size, "sha256": _sha256(tmp / n)}
    (tmp / "manifest.json").write_text(json.dumps({"files": files, "saved": time.strftime("%Y-%m-%d %H:%M:%S")},
                                                  indent=1), encoding="utf-8")
    r = subprocess.run([py, "-c", HF_UPLOAD_PY, repo, path, str(tmp), os.environ.get("STRATA_HF_TOKEN_FILE", "")],
                       env=env)
    shutil.rmtree(tmp, ignore_errors=True)
    if r.returncode != 0:
        print(f"the upload to {repo} failed (exit {r.returncode})", flush=True)
        return 7
    size = sum(v["bytes"] for v in files.values())
    secs = time.time() - t
    tl("mtp-saved", bytes=size, secs=round(secs, 1))
    print(f"saved {size / 1e9:.2f} GB to {loc} in {secs:.0f} s", flush=True)
    return 0


# ---- fsync during the setup
# On Colab an fsync waits until every big write in flight on the disk has been flushed (measured: 56 s while one 22 GB file was
# written; Step 3's pip stood 280 s in jbd2_log_wait_commit while the shards came in, after its real work took 11 s). pip fsyncs
# each package's RECORD, so the cache setting alone does not help. During the setup, setup.py's Python subprocesses (pip, the
# engine feed, the tools) get an os.fsync that does nothing, through a sitecustomize.py on PYTHONPATH. The disk of a Colab VM
# goes away with the VM, so nothing durable is lost. It is switched off again before the server starts (the start hook).

NO_FSYNC = os.environ.get("STRATA_FAST_NO_FSYNC", "1").strip() != "0"
_SITECUSTOMIZE = '''\
# strata_fast.py: no fsync for the setup's Python processes on a Colab VM (see strata_fast.py, "fsync during the setup")
import os
if os.environ.get("STRATA_FAST_NOFSYNC_ACTIVE") == "1":
    os.fsync = lambda fd: None
    if hasattr(os, "fdatasync"):
        os.fdatasync = lambda fd: None
'''
_saved_pythonpath: list = []
# setup.py itself also fsyncs (download_single, the marks; all through os.fsync): the user's run of 11/08 stood 220 s in
# get_llama_cpp for a 40 MB zip while the shards came in.  This process gets the no-op too, and its own functions back after.
_saved_fsync: dict = {}


def _no_fsync(fd) -> None:
    return None


def no_fsync_on() -> None:
    if not NO_FSYNC or not sys.platform.startswith("linux") or _saved_pythonpath:
        return
    d = PREFETCH_DIR / "nofsync"
    try:
        d.mkdir(parents=True, exist_ok=True)
        (d / "sitecustomize.py").write_text(_SITECUSTOMIZE, encoding="utf-8")
    except OSError:
        return
    for name in ("fsync", "fdatasync"):
        if hasattr(os, name):
            _saved_fsync[name] = getattr(os, name)
            setattr(os, name, _no_fsync)
    _saved_pythonpath.append(os.environ.get("PYTHONPATH"))
    os.environ["PYTHONPATH"] = str(d) + (os.pathsep + _saved_pythonpath[0] if _saved_pythonpath[0] else "")
    os.environ["STRATA_FAST_NOFSYNC_ACTIVE"] = "1"
    tl("no-fsync", on=True)


def no_fsync_off() -> None:
    if not _saved_pythonpath:
        return
    old = _saved_pythonpath.pop()
    if old is None:
        os.environ.pop("PYTHONPATH", None)
    else:
        os.environ["PYTHONPATH"] = old
    os.environ.pop("STRATA_FAST_NOFSYNC_ACTIVE", None)
    for name, fn in _saved_fsync.items():
        setattr(os, name, fn)
    _saved_fsync.clear()
    tl("no-fsync", on=False)


# ---- the setup's small writes on the VM's memory
# With fsync gone (above), the setup's ordinary writes still waited while the shards filled the disk (vm.dirty_ratio=2: a writer
# is held until the disk takes its pages).  Live run 3 (11/08): pip's downloads took 8 s and unpacking into .venv 103 s, ending
# right after shard 2; llama.cpp's 40 MB zip 54 s, its unpacking 64 s.  So what the setup writes besides the model goes to
# /dev/shm (tmpfs; a Colab A100 VM has 83 GB of RAM and /dev/shm 41 GB free; this is about 2 GB):
#   .venv, engine, engine-feed - links made by fast-setup.sh (remote-setup.sh) before .venv is created;
#   third_party/llama.cpp       - third_party is in the repository, so get_llama_cpp is done here into /dev/shm and linked;
#   TMPDIR                      - pip's unpacking, for the setup only (back before the server starts).
# Anything unexpected leaves the disk path as it was.  STRATA_FAST_SHM=0 turns it off.

SHM = os.environ.get("STRATA_FAST_SHM", "1").strip() != "0"
# the tmpfs fast-setup.sh mounted (Colab's /dev/shm is noexec: the engine could not run from it); empty: none
SHM_ROOT = Path(os.environ.get("STRATA_FAST_SHM_DIR", "").strip() or "/nonexistent-strata-mem")
SHM_MIN_FREE = 8 << 30
SHM_LINKS = (".venv", "engine", "engine-feed")
_saved_tmpdir: list = []


def shm_ok() -> bool:
    if not SHM or not sys.platform.startswith("linux"):
        return False
    try:
        st = os.statvfs(SHM_ROOT)
    except OSError:
        return False
    return st.f_bavail * st.f_frsize >= SHM_MIN_FREE and os.access(SHM_ROOT, os.W_OK)


def shm_tmp_on(root: Path) -> None:
    links = [d for d in SHM_LINKS if (root / d).is_symlink()]
    if not shm_ok() or _saved_tmpdir:
        tl("shm", on=False, links=links)
        return
    d = SHM_ROOT / "tmp"
    try:
        d.mkdir(parents=True, exist_ok=True)
    except OSError:
        tl("shm", on=False, links=links)
        return
    _saved_tmpdir.append(os.environ.get("TMPDIR"))
    os.environ["TMPDIR"] = str(d)
    import tempfile
    tempfile.tempdir = None                         # read TMPDIR again
    tl("shm", on=True, links=links)


def shm_tmp_off() -> None:
    if not _saved_tmpdir:
        return
    old = _saved_tmpdir.pop()
    if old is None:
        os.environ.pop("TMPDIR", None)
    else:
        os.environ["TMPDIR"] = old
    import tempfile
    tempfile.tempdir = None


def shm_packs(args: list[str]) -> None:
    """<data-dir>/packs a link into memory: iq_pack.py writes dense.bin (1.5 GB for IQ3_S) there right after the shards, when the
    disk is slow (live run 6), and the engine reads it when it starts.  Only when packs does not exist yet."""
    if not shm_ok():
        return
    try:
        a = parse_setup_args(args)
        if not a.data_dir:
            return
        packs = Path(a.data_dir).expanduser() / "packs"
        if packs.exists() or packs.is_symlink():
            tl("shm-packs", linked=False, why="exists")
            return
        target = SHM_ROOT / "packs"
        target.mkdir(parents=True, exist_ok=True)
        packs.parent.mkdir(parents=True, exist_ok=True)
        os.symlink(target, packs)
        tl("shm-packs", linked=True)
    except (OSError, SystemExit) as e:
        tl("shm-packs", linked=False, why=repr(e)[:200])


def shm_llama(m, orig):
    """get_llama_cpp with the source unpacked in /dev/shm and home()/third_party/llama.cpp a link to it.  setup.py's own
    get_llama_cpp then finds the source in place and returns it; on any problem it runs as it is (on the disk)."""
    def get_llama_cpp(*a, **k):
        try:
            llama = Path(m.home()) / "third_party" / "llama.cpp"
            commit, url = m.LLAMA_CPP_COMMIT[:7], m.LLAMA_CPP_ZIP
        except (AttributeError, TypeError):
            return orig(*a, **k)
        if not shm_ok() or llama.exists() or llama.is_symlink():
            return orig(*a, **k)
        base = SHM_ROOT / "third_party"
        dst, tmp, z = base / f"llama.cpp-{commit}", base / "_unpack", base / f"llama.cpp-{commit}.zip"
        t = time.time()
        try:
            base.mkdir(parents=True, exist_ok=True)
            shutil.rmtree(tmp, ignore_errors=True)
            shutil.rmtree(dst, ignore_errors=True)
            m.download(url, z, "llama.cpp source")
            with zipfile.ZipFile(z) as f:              # as setup.py does: llama.cpp's web UI (tools/ui) is left out
                f.extractall(tmp, [n for n in f.namelist() if "/tools/ui/" not in n])
            next(tmp.iterdir()).rename(dst)
            if not ((dst / "ggml" / "CMakeLists.txt").exists() and (dst / "gguf-py").is_dir()):
                raise OSError("the unpacked source has no ggml/CMakeLists.txt or gguf-py")
            llama.parent.mkdir(parents=True, exist_ok=True)
            os.symlink(dst, llama)
            tl("shm-llama", ok=True, secs=round(time.time() - t, 1))
        except (Exception, SystemExit) as e:           # noqa: BLE001 - setup.py's own way (on the disk) follows
            tl("shm-llama", ok=False, error=repr(e)[:300])
            if llama.is_symlink():
                llama.unlink()
            shutil.rmtree(dst, ignore_errors=True)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
            for p in (z, z.with_name(z.name + ".done")):
                try:
                    p.unlink()
                except OSError:
                    pass
        return orig(*a, **k)
    return get_llama_cpp


FEED_REPO_DEFAULT = "Niko1221/Strata"
FEED_FILES = ("strata-feed.json", "strata-feed.json.sig")


class _FeedMirror:
    """A loopback stand-in for the release's update feed, for when GitHub answers 5xx for strata-feed.json (2026-11-08: the
    `releases/latest/download/` and the tagged URL both gave 504 for strata-feed.json for over an hour, while its .sig, the engine
    packages and the API's asset download all worked; setup then built the engine from source, ~18 min).

    strata-feed.json and its .sig come through the API's asset download; every other file the feed names (relative to the feed)
    is a redirect to the signed download URL the API's asset endpoint points at (the tagged release URL gave 504 for the cuda12
    engine package on the next start, while that signed URL worked), else to the tagged release URL.  The feed's signature and
    each package's sha256 in it are still checked by Strata: nothing here is trusted more."""

    def __init__(self, repo: str = FEED_REPO_DEFAULT):
        import http.server
        rel = self._get_json(f"https://api.github.com/repos/{repo}/releases/latest")
        self.tag = rel["tag_name"]
        ids = {a["name"]: a["id"] for a in rel.get("assets", [])}
        self.files = {}
        for name in FEED_FILES:
            self.files[name] = self._get(f"https://api.github.com/repos/{repo}/releases/assets/{ids[name]}",
                                         {"Accept": "application/octet-stream"})
        base = f"https://github.com/{repo}/releases/download/{self.tag}/"
        files, signed = self.files, self._signed_url

        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                name = self.path.split("?", 1)[0].lstrip("/")
                if name in files:
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(files[name])))
                    self.end_headers()
                    self.wfile.write(files[name])
                elif name and "/" not in name and ".." not in name:
                    loc = signed(repo, ids.get(name)) or base + name
                    tl("feed-mirror-file", name=name, via="api" if not loc.startswith(base) else "tag")
                    self.send_response(302)
                    self.send_header("Location", loc)
                    self.end_headers()
                else:
                    self.send_error(404)

            def log_message(self, *a):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}/strata-feed.json"

    @staticmethod
    def _get(url: str, headers: dict | None = None, tries: int = 3) -> bytes:
        err = None
        for i in range(tries):
            try:
                req = urllib.request.Request(url, headers={"User-Agent": "strata-colab-cli", **(headers or {})})
                with urllib.request.urlopen(req, timeout=30) as r:
                    return r.read()
            except Exception as e:                      # noqa: BLE001 - retried, then raised
                err = e
                time.sleep(2 * (i + 1))
        raise err

    @staticmethod
    def _signed_url(repo: str, asset_id) -> str | None:
        """Where the API's asset download redirects to (a short-lived signed URL), without following it; None if not had."""
        if asset_id is None:
            return None

        class NoFollow(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *a, **k):
                return None
        req = urllib.request.Request(f"https://api.github.com/repos/{repo}/releases/assets/{asset_id}",
                                     headers={"User-Agent": "strata-colab-cli", "Accept": "application/octet-stream"})
        for i in range(3):
            try:
                urllib.request.build_opener(NoFollow).open(req, timeout=30).close()
                return None                             # answered 200 itself: no redirect to give
            except urllib.error.HTTPError as e:
                if e.code in (301, 302, 303, 307, 308) and e.headers.get("Location", "").startswith("https://"):
                    return e.headers["Location"]
            except Exception:                           # noqa: BLE001 - retried, then the tagged URL
                pass
            time.sleep(2 * (i + 1))
        return None

    @classmethod
    def _get_json(cls, url: str):
        return json.loads(cls._get(url, {"Accept": "application/vnd.github+json"}))

    def close(self):
        self.server.shutdown()
        self.server.server_close()


def feed_read_error(out: str) -> bool:
    """`strata.py update` could not read the feed or a file it names from GitHub (5xx, a timeout): GitHub's side, not this VM's."""
    import re
    return bool(re.search(r"answered 5\d\d|update feed could not be read|timed out", out or ""))


def feed_watch(m, orig):
    """engine_from_feed, with what `strata.py update` printed kept in the timeline when it gives no engine (setup.py shows only
    the last line of its stderr, which on live run 4 was a library's `warnings.warn(` line), and, when engine/ or engine-feed/
    are links to /dev/shm, one more try with both as ordinary folders on the disk (live run 4: the feed failed with the links)."""
    def once(*a, **k):
        real_run, seen = m.subprocess.run, {}

        def run(cmd, *ra, **rk):
            r = real_run(cmd, *ra, **rk)
            if isinstance(cmd, (list, tuple)) and "update" in cmd and "--no-control" in cmd:
                seen["r"] = r
            return r
        m.subprocess.run = run
        try:
            res = orig(*a, **k)
        finally:
            m.subprocess.run = real_run
        r = seen.get("r")
        if res is None and r is not None:
            tl("feed-fail", rc=r.returncode, stdout=str(r.stdout or "")[-2000:], stderr=str(r.stderr or "")[-2000:])
            seen_out[0] = str(r.stdout or "") + str(r.stderr or "")
        return res

    seen_out = [""]

    def via_mirror(*a, **k):
        """Through _FeedMirror, when no other feed was named (None then, and when the API cannot be reached either)."""
        if os.environ.get("STRATA_UPDATE_FEED", "").strip():
            return None
        t0 = time.time()
        try:
            mirror = _FeedMirror()
        except Exception as e:                          # noqa: BLE001 - the API is down too: setup goes on as it would
            tl("feed-mirror", ok=False, error=repr(e)[:300])
            return None
        say(f"reading the signed update feed ({mirror.tag}) through GitHub's API")
        os.environ["STRATA_UPDATE_FEED"] = mirror.url
        try:
            res = once(*a, **k)
        finally:
            os.environ.pop("STRATA_UPDATE_FEED", None)
            mirror.close()
        tl("feed-mirror", ok=res is not None, tag=mirror.tag, secs=round(time.time() - t0, 1))
        return res

    def engine_from_feed(*a, **k):
        # First through GitHub's API (11-08: the release URL gave 504 for the feed, then for an engine package, then timed out
        # after 218 s, on three starts in a row; each time setup built the engine from source, ~18 min). The usual URL after that.
        res = via_mirror(*a, **k)
        if res is not None:
            return res
        res = once(*a, **k)
        if res is not None:
            return res
        if feed_read_error(seen_out[0]):                # GitHub's side, not engine/ in memory: no point moving it to the disk
            return res
        try:
            eng = Path(a[0] if a else k["eng"])
            links = [p for p in (eng, Path(m.home()) / "engine-feed") if p.is_symlink()]
        except (KeyError, AttributeError, TypeError):
            return res
        if not links:
            return res
        for p in links:                                 # back on the disk, empty, as setup.py would have made them
            target = Path(os.path.realpath(p))
            p.unlink()
            p.mkdir()
            shutil.rmtree(target, ignore_errors=True)
        tl("shm-feed-retry", moved=[p.name for p in links])
        say("the engine from the update feed did not come with engine/ in memory: once more on the disk")
        return once(*a, **k)
    return engine_from_feed


def run_setup(root: Path, args: list[str]) -> int:
    tl("setup-begin", args=args)
    # pip writes its download cache with fsync, and on Colab an fsync waits until the model's big writes have ended: Step 3's pip
    # stood still for 225 s at its first cache write. A fresh VM has nothing cached to gain from, so the cache is off for setup.py
    os.environ.setdefault("PIP_NO_CACHE_DIR", "1")
    no_fsync_on()
    shm_tmp_on(root)
    shm_packs(args)
    m = load_setup(root)
    pf = None
    try:
        plan = make_plan(m, args)
        if plan.all():
            pf = Prefetch(root, plan)
    except Exception as e:                           # noqa: BLE001 - a plan problem only means no prefetch
        tl("plan-error", error=repr(e))
        say(f"no prefetch ({e!r}); setup.py runs as it is")
    install_hooks(m, pf, parse_setup_args(args).port)
    if pf:
        pf.start()
    sys.argv = [str(root / "setup.py"), *args]
    rc = 1
    try:
        rc = m.main()
    except m.acquisition.AcquisitionRefused as e:     # the same endings as setup.py's own __main__
        m.say(f"\n  [X]  {e}")
        rc = e.exit_code
    except KeyboardInterrupt:
        m.say("\nstopped.")
        rc = 1
    except SystemExit as e:
        rc = e.code if isinstance(e.code, int) else (0 if e.code is None else 1)
        if isinstance(e.code, str):
            print(e.code, file=sys.stderr)
    finally:
        tl("setup-end", rc=rc)
        no_fsync_off()
        shm_tmp_off()
        if pf:
            pf.terminate()
    return rc


def report(path: str) -> int:
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            try:
                rows.append(json.loads(line))
            except ValueError:
                pass
    if not rows:
        print("no records")
        return 1
    for r in rows:
        extra = {k: v for k, v in r.items() if k not in ("t", "s", "pid", "event", "args")}
        s = r.get("s")
        print(f"{s if isinstance(s, (int, float)) else 0:8.1f}s  {str(r.get('t', ''))[11:19]:<8}  "
              f"{r.get('event', '?'):<18} " + " ".join(f"{k}={v}" for k, v in extra.items()))
    return 0


def main() -> int:
    argv = sys.argv[1:]
    if argv[:1] == ["--report"]:
        return report(argv[1] if len(argv) > 1 else TIMELINE)
    root = Path(os.environ.get("STRATA_ROOT") or os.getcwd()).resolve()
    if argv[:1] == ["--job"]:
        return run_job(root, argv[1:])
    return run_setup(root, argv)


if __name__ == "__main__":
    sys.exit(main())
