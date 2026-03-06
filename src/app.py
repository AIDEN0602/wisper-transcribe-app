#!/usr/bin/env python3
from __future__ import annotations

import os
import queue
import re
import sys
import threading
import time
import traceback
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable, List, Optional

import tkinter as tk
import tkinter.font as tkfont
from tkinter import filedialog, messagebox, ttk

try:
    from tkinterdnd2 import DND_FILES, TkinterDnD  # type: ignore
    DND_AVAILABLE = True
except Exception:
    DND_FILES = None
    TkinterDnD = None
    DND_AVAILABLE = False

from faster_whisper import WhisperModel

try:
    from deep_translator import GoogleTranslator
except Exception:
    GoogleTranslator = None

try:
    import deepl as deepl_sdk
except Exception:
    deepl_sdk = None

try:
    from openai import OpenAI
except Exception:
    OpenAI = None

try:
    import anthropic as anthropic_sdk
except Exception:
    anthropic_sdk = None

try:
    import google.generativeai as genai_sdk
except Exception:
    genai_sdk = None

try:
    from huggingface_hub import snapshot_download
except Exception:
    snapshot_download = None

# ── Constants ────────────────────────────────────────────────────────────────
APP_NAME   = "ClassTranscribe"
BUILD_TAG  = "2026-03-06-r8"
CREDIT_NAME  = "Minje Seo"
CREDIT_EMAIL = "ms15059@nyu.edu"
DEFAULT_MODEL = "small"

# ── Palette (Figma-inspired, warm & friendly) ────────────────────────────────
BG          = "#F7F8FC"
SURFACE     = "#FFFFFF"
SURFACE2    = "#F0F2F8"
ACCENT      = "#5B6AF0"       # indigo
ACCENT_DARK = "#4250D4"
SUCCESS     = "#22C55E"
WARNING     = "#F59E0B"
DANGER      = "#EF4444"
FG          = "#1A1D2E"
FG_MUTED    = "#6B7280"
FG_LIGHT    = "#9CA3AF"
BORDER      = "#E2E5F0"
TAG_BG      = "#EEF0FD"
TAG_FG      = ACCENT

FONT_TITLE  = ("SF Pro Display", 17, "bold")
FONT_HEAD   = ("SF Pro Display", 13, "bold")
FONT_BODY   = ("SF Pro Text",    12)
FONT_SMALL  = ("SF Pro Text",    11)
FONT_MONO   = ("SF Mono",        11)

# ── Model descriptions ────────────────────────────────────────────────────────
MODEL_DESCRIPTIONS = {
    "tiny":      "Fastest · lowest accuracy · ~75MB",
    "tiny.en":   "Fastest English-only · ~75MB",
    "base":      "Fast & balanced · ~145MB",
    "base.en":   "Fast English-only · better than tiny.en · ~145MB",
    "small":     "⭐ Recommended · best balance for most users · ~465MB",
    "small.en":  "High quality English-only · ~465MB",
    "medium":    "Higher accuracy · slower · ~1.5GB",
    "medium.en": "Higher accuracy English-only · ~1.5GB",
    "large-v1":  "Very high accuracy · heavy on CPU · ~3GB",
    "large-v2":  "Very high accuracy · heavy on CPU · ~3GB",
    "large-v3":  "Best multilingual · slowest/heaviest · ~3GB",
}
DOWNLOADABLE_MODELS = list(MODEL_DESCRIPTIONS.keys())

LANGUAGE_MAP = {
    "English":    "en",
    "Korean":     "ko",
    "Chinese":    "zh",
    "Russian":    "ru",
    "Japanese":   "ja",
    "Spanish":    "es",
    "French":     "fr",
    "German":     "de",
    "Auto-detect": "auto",
}
CODE_TO_LANG = {v: k for k, v in LANGUAGE_MAP.items()}
CODE_TO_LANG["zh-CN"] = "Chinese"

TRANSLATE_TO_MAP = {
    "English": "en", "Korean": "ko", "Chinese": "zh-CN",
    "Russian": "ru", "Japanese": "ja", "Spanish": "es",
    "French": "fr",  "German": "de",
}

ENGINES = ["Google (free)", "DeepL", "OpenAI", "Claude", "Gemini"]

SUPPORTED_EXT = {
    ".m4a",".mp3",".wav",".flac",".ogg",".opus",
    ".aac",".mp4",".mov",".mkv",".webm",".m4v",
}

LAUGHTER_RE = re.compile(
    r"(\b(?:ha){2,}\b|\b(?:he){2,}\b|\b(?:lol)+\b"
    r"|\b(?:laugh(?:s|ing|ed)?)\b|[ㅋㅎ]{2,})",
    re.IGNORECASE,
)


@dataclass
class Seg:
    start: float
    end: float
    text: str


def resource_base() -> Path:
    if hasattr(sys, "_MEIPASS"):
        return Path(getattr(sys, "_MEIPASS"))
    return Path(__file__).resolve().parent.parent


def bundled_model_dir(name: str) -> Path:
    return resource_base() / "models" / f"faster-whisper-{name}"


def ts(s: float) -> str:
    t = max(0, int(s))
    return f"{t//3600:02d}:{(t%3600)//60:02d}:{t%60:02d}"


def normalize(text: str) -> str:
    t = (text or "").strip()
    if not t:
        return ""
    t = LAUGHTER_RE.sub("[laughter]", t)
    t = re.sub(r"\s+", " ", t).strip()
    if t.lower() in {"[ laughter ]", "[laughter ]", "[ laughter]"}:
        t = "[laughter]"
    return t


def parse_drop(raw: str, root: tk.Tk) -> List[Path]:
    return [Path(p) for p in root.tk.splitlist(raw) if Path(p).is_file()]


# ── Rounded helpers ──────────────────────────────────────────────────────────
def card(parent, **kw):
    f = tk.Frame(parent, bg=SURFACE, relief="flat", bd=0, **kw)
    return f


def divider(parent):
    tk.Frame(parent, bg=BORDER, height=1).pack(fill="x", padx=0, pady=6)


def badge(parent, text, bg=TAG_BG, fg=TAG_FG):
    tk.Label(parent, text=text, bg=bg, fg=fg,
             font=FONT_SMALL, padx=8, pady=2).pack(side="left", padx=(0, 4))


def accent_btn(parent, text, command, width=None, bg=ACCENT, fg="white"):
    kw = dict(text=text, command=command, bg=bg, fg=fg,
              activebackground=ACCENT_DARK, activeforeground="white",
              relief="flat", bd=0, font=FONT_HEAD,
              padx=16, pady=8, cursor="hand2")
    if width:
        kw["width"] = width
    return tk.Button(parent, **kw)


def ghost_btn(parent, text, command):
    return tk.Button(parent, text=text, command=command,
                     bg=SURFACE2, fg=FG, activebackground=BORDER,
                     relief="flat", bd=0, font=FONT_BODY,
                     padx=12, pady=7, cursor="hand2")


def section_label(parent, text):
    tk.Label(parent, text=text, bg=BG, fg=FG_MUTED,
             font=("SF Pro Text", 10, "bold")).pack(anchor="w", pady=(10, 2))


# ── Canvas-based colored button (works on macOS where tk.Button ignores bg) ───
class _ColorBtn(tk.Canvas):
    """A button that reliably shows a background colour on macOS."""
    def __init__(self, parent, text, command,
                 bg=ACCENT, fg="white", font=FONT_HEAD, **kw):
        self._bg_on  = bg
        self._bg_dis = SURFACE2
        self._fg_on  = fg
        self._fg_dis = FG_MUTED
        self._cmd    = command
        self._enabled = True
        # measure text size
        _tmp = tk.Label(parent, text=text, font=font, padx=18, pady=9)
        _tmp.update_idletasks()
        w = _tmp.winfo_reqwidth()
        h = _tmp.winfo_reqheight()
        _tmp.destroy()
        super().__init__(parent, width=w, height=h,
                         bg=parent.cget("bg"),
                         highlightthickness=0, cursor="hand2", **kw)
        r = 6
        self._rect = self.create_rounded_rect(0, 0, w, h, r, fill=bg, outline="")
        self._text = self.create_text(w//2, h//2, text=text,
                                      fill=fg, font=font, anchor="center")
        self.bind("<Button-1>",  self._on_click)
        self.bind("<Enter>",     self._on_enter)
        self.bind("<Leave>",     self._on_leave)

    def create_rounded_rect(self, x1, y1, x2, y2, r, **kw):
        pts = [x1+r,y1, x2-r,y1, x2,y1, x2,y1+r, x2,y2-r, x2,y2,
               x2-r,y2, x1+r,y2, x1,y2, x1,y2-r, x1,y1+r, x1,y1]
        return self.create_polygon(pts, smooth=True, **kw)

    def _on_click(self, *_):
        if self._enabled:
            self._cmd()

    def _on_enter(self, *_):
        if self._enabled:
            self.itemconfig(self._rect, fill=ACCENT_DARK)

    def _on_leave(self, *_):
        if self._enabled:
            self.itemconfig(self._rect, fill=self._bg_on)

    def config(self, **kw):
        if "state" in kw:
            self._enabled = (kw["state"] != "disabled")
            fill = self._bg_on  if self._enabled else self._bg_dis
            fg   = self._fg_on  if self._enabled else self._fg_dis
            self.itemconfig(self._rect, fill=fill)
            self.itemconfig(self._text, fill=fg)
            self.configure(cursor="hand2" if self._enabled else "arrow")

    # alias so callers can use .config(state=…) or .configure(state=…)
    configure = config


# ═══════════════════════════════════════════════════════════════════════════════
class App:
    def __init__(self):
        self.root, self.dnd_ok = self._make_root()
        self.root.title(f"{APP_NAME}  ·  {BUILD_TAG}")
        self.root.geometry("980x860")
        self.root.configure(bg=BG)
        self.root.resizable(True, True)

        # state
        self.files: List[Path] = []
        self.model_cache: dict[str, WhisperModel] = {}
        self.model_locations: dict[str, Path] = {}
        self.worker: Optional[threading.Thread] = None
        self.log_q: "queue.Queue[str]" = queue.Queue()
        self.prog_q: "queue.Queue[tuple]" = queue.Queue()
        self.translator_cache: dict = {}
        self._start_time: float = 0.0
        self._files_done: int = 0
        self._files_total: int = 0

        # discover models
        models, locations = self._discover()
        self.model_locations = locations
        self.model_choices   = models
        picked = DEFAULT_MODEL if DEFAULT_MODEL in models else (models[0] if models else DEFAULT_MODEL)

        # tk vars
        self.model_var        = tk.StringVar(value=picked)
        self.install_var      = tk.StringVar(value="medium")
        self.lang_var         = tk.StringVar(value="English")
        self.trans_mode_var   = tk.StringVar(value="Disabled")   # Disabled / Enabled
        self.trans_from_var   = tk.StringVar(value="Auto-detect")
        self.trans_to_var     = tk.StringVar(value="English")
        self.engine_var       = tk.StringVar(value="Google (free)")
        self.deepl_key_var    = tk.StringVar(value="")
        self.openai_key_var   = tk.StringVar(value="")
        self.claude_key_var   = tk.StringVar(value="")
        self.gemini_key_var   = tk.StringVar(value="")
        self.output_var       = tk.StringVar(value=str(Path.home() / "Desktop" / "transcripts"))
        self.prog_text_var    = tk.StringVar(value="Ready")
        self.eta_var          = tk.StringVar(value="")

        self._configure_theme()
        self._build_ui()

        # traces
        self.model_var.trace_add("write",      self._on_model_change)
        self.trans_mode_var.trace_add("write",  self._on_trans_mode)
        self.engine_var.trace_add("write",      self._on_engine_change)
        for v in (self.deepl_key_var, self.openai_key_var,
                  self.claude_key_var, self.gemini_key_var):
            v.trace_add("write", self._on_key_typed)

        self._update_model_desc()
        self._on_trans_mode()
        self._on_engine_change()
        self.root.after(120, self._drain)

    # ── root ────────────────────────────────────────────────────────────────
    def _make_root(self):
        if DND_AVAILABLE and TkinterDnD:
            try:
                return TkinterDnD.Tk(), True
            except Exception:
                pass
        return tk.Tk(), False

    def _configure_theme(self):
        try:
            self.root.tk.call("tk", "scaling", 1.3)
        except Exception:
            pass
        for fname, sz in (
            ("TkDefaultFont",12),("TkTextFont",12),("TkMenuFont",12),
            ("TkHeadingFont",13),("TkCaptionFont",12),
        ):
            try:
                tkfont.nametofont(fname).configure(size=sz)
            except Exception:
                pass
        style = ttk.Style(self.root)
        for t in ("clam","alt","default"):
            try:
                style.theme_use(t); break
            except Exception:
                pass
        style.configure(".", background=BG, foreground=FG)
        style.configure("TLabel", background=BG, foreground=FG)
        style.configure("TFrame", background=BG)
        style.configure("Prog.Horizontal.TProgressbar",
                        troughcolor=SURFACE2, bordercolor=SURFACE2,
                        background=ACCENT, lightcolor=ACCENT, darkcolor=ACCENT,
                        thickness=6)

    # ── UI ──────────────────────────────────────────────────────────────────
    def _build_ui(self):
        root = self.root

        # ── top bar
        topbar = tk.Frame(root, bg=SURFACE, pady=14)
        topbar.pack(fill="x")
        tk.Label(topbar, text="🎙  ClassTranscribe", bg=SURFACE, fg=FG,
                 font=("SF Pro Display", 16, "bold"), padx=20).pack(side="left")
        tk.Label(topbar, text="ʕ•ᴥ•ʔ wombat & (◕‿◕) quokka approved",
                 bg=SURFACE, fg=ACCENT, font=FONT_SMALL, padx=8).pack(side="left")
        tk.Label(topbar, text=f"build {BUILD_TAG}", bg=SURFACE, fg=FG_LIGHT,
                 font=FONT_SMALL, padx=20).pack(side="right")
        tk.Frame(root, bg=BORDER, height=1).pack(fill="x")

        # ── two-column layout
        body = tk.Frame(root, bg=BG, padx=18, pady=14)
        body.pack(fill="both", expand=True)
        body.columnconfigure(0, weight=1, minsize=340)
        body.columnconfigure(1, weight=2)
        body.rowconfigure(0, weight=1)

        left  = tk.Frame(body, bg=BG)
        right = tk.Frame(body, bg=BG)
        left.grid(row=0, column=0, sticky="nsew", padx=(0,10))
        right.grid(row=0, column=1, sticky="nsew")

        self._build_left(left)
        self._build_right(right)

    def _build_left(self, parent):
        # ── Model card
        section_label(parent, "TRANSCRIPTION MODEL")
        mc = card(parent)
        mc.pack(fill="x", pady=(0,4))
        inner = tk.Frame(mc, bg=SURFACE, padx=14, pady=12)
        inner.pack(fill="x")

        mrow = tk.Frame(inner, bg=SURFACE)
        mrow.pack(fill="x")
        tk.Label(mrow, text="Model", bg=SURFACE, fg=FG, font=FONT_HEAD).pack(side="left")
        self.model_menu = ttk.Combobox(mrow, textvariable=self.model_var,
                                       values=self.model_choices,
                                       state="readonly", width=16)
        self.model_menu.pack(side="right")
        # macOS readonly Combobox sometimes doesn't update textvariable — force sync
        self.model_menu.bind("<<ComboboxSelected>>",
                             lambda e: self.model_var.set(self.model_menu.get()))

        self.model_desc_lbl = tk.Label(inner, text="", bg=SURFACE, fg=FG_MUTED,
                                       font=FONT_SMALL, anchor="w", wraplength=280)
        self.model_desc_lbl.pack(fill="x", pady=(6,0))
        tk.Label(inner, text="↑ Shows installed models only",
                 bg=SURFACE, fg=FG_LIGHT, font=("SF Pro Text", 10), anchor="w"
                 ).pack(fill="x")

        divider(inner)

        tk.Label(inner, text="Download & install more models:",
                 bg=SURFACE, fg=FG_MUTED, font=FONT_SMALL, anchor="w").pack(fill="x")
        irow = tk.Frame(inner, bg=SURFACE)
        irow.pack(fill="x", pady=(4,0))
        tk.Label(irow, text="Model", bg=SURFACE, fg=FG, font=FONT_BODY).pack(side="left")
        self.install_cb = ttk.Combobox(irow, textvariable=self.install_var,
                                       values=DOWNLOADABLE_MODELS, state="readonly", width=12)
        self.install_cb.pack(side="right")
        # macOS readonly Combobox sometimes doesn't update textvariable — force sync
        self.install_cb.bind("<<ComboboxSelected>>",
                             lambda e: self.install_var.set(self.install_cb.get()))
        self.dl_btn = accent_btn(inner, "⬇  Download", self._install_clicked,
                                 bg="#F0F2F8")
        self.dl_btn.configure(fg=ACCENT, activeforeground=ACCENT,
                               activebackground=BORDER)
        self.dl_btn.pack(fill="x", pady=(6,0))

        # ── Language card
        section_label(parent, "LANGUAGE")
        lc = card(parent)
        lc.pack(fill="x", pady=(0,4))
        lin = tk.Frame(lc, bg=SURFACE, padx=14, pady=12)
        lin.pack(fill="x")
        lr = tk.Frame(lin, bg=SURFACE)
        lr.pack(fill="x")
        tk.Label(lr, text="Transcribe in", bg=SURFACE, fg=FG, font=FONT_BODY).pack(side="left")
        _lang_cb = ttk.Combobox(lr, textvariable=self.lang_var,
                                values=list(LANGUAGE_MAP.keys()),
                                state="readonly", width=14)
        _lang_cb.pack(side="right")
        _lang_cb.bind("<<ComboboxSelected>>",
                      lambda e: self.lang_var.set(_lang_cb.get()))

        # ── Translation card  (options ALWAYS visible)
        section_label(parent, "TRANSLATION")
        tc = card(parent)
        tc.pack(fill="x", pady=(0,4))
        self.trans_inner = tk.Frame(tc, bg=SURFACE, padx=14, pady=10)
        self.trans_inner.pack(fill="x")

        # Row 1: toggle
        tr = tk.Frame(self.trans_inner, bg=SURFACE)
        tr.pack(fill="x")
        tk.Label(tr, text="Translate output", bg=SURFACE, fg=FG,
                 font=FONT_BODY).pack(side="left")
        _trans_mode_cb = ttk.Combobox(tr, textvariable=self.trans_mode_var,
                                      values=["Disabled", "Enabled"],
                                      state="readonly", width=10)
        _trans_mode_cb.pack(side="right")
        _trans_mode_cb.bind("<<ComboboxSelected>>",
                            lambda e: self.trans_mode_var.set(_trans_mode_cb.get()))

        # Status hint (updates dynamically)
        self.trans_status_lbl = tk.Label(
            self.trans_inner,
            text="○  Disabled — options below are ready when you enable",
            bg=SURFACE, fg=FG_LIGHT, font=FONT_SMALL, anchor="w", wraplength=300)
        self.trans_status_lbl.pack(fill="x", pady=(3,6))

        # Divider
        tk.Frame(self.trans_inner, bg=BORDER, height=1).pack(fill="x", pady=(0,8))

        # Row 2: From → To  (always visible)
        self.trans_options_frame = tk.Frame(self.trans_inner, bg=SURFACE)
        self.trans_options_frame.pack(fill="x")

        ft_row = tk.Frame(self.trans_options_frame, bg=SURFACE)
        ft_row.pack(fill="x", pady=(0,4))
        tk.Label(ft_row, text="From", bg=SURFACE, fg=FG_MUTED,
                 font=FONT_SMALL, width=6, anchor="w").pack(side="left")
        _from_cb = ttk.Combobox(ft_row, textvariable=self.trans_from_var,
                                values=list(LANGUAGE_MAP.keys()),
                                state="readonly", width=11)
        _from_cb.pack(side="left")
        _from_cb.bind("<<ComboboxSelected>>",
                      lambda e: self.trans_from_var.set(_from_cb.get()))
        tk.Label(ft_row, text="→  To", bg=SURFACE, fg=FG_MUTED,
                 font=FONT_SMALL, padx=6).pack(side="left")
        _to_cb = ttk.Combobox(ft_row, textvariable=self.trans_to_var,
                              values=list(TRANSLATE_TO_MAP.keys()),
                              state="readonly", width=10)
        _to_cb.pack(side="left")
        _to_cb.bind("<<ComboboxSelected>>",
                    lambda e: self.trans_to_var.set(_to_cb.get()))

        # Row 3: Engine (always visible)
        eng_row = tk.Frame(self.trans_options_frame, bg=SURFACE)
        eng_row.pack(fill="x", pady=(0,2))
        tk.Label(eng_row, text="Engine", bg=SURFACE, fg=FG_MUTED,
                 font=FONT_SMALL, width=6, anchor="w").pack(side="left")
        _engine_cb = ttk.Combobox(eng_row, textvariable=self.engine_var,
                                  values=ENGINES, state="readonly", width=15)
        _engine_cb.pack(side="left")
        _engine_cb.bind("<<ComboboxSelected>>",
                        lambda e: self.engine_var.set(_engine_cb.get()))

        # API keys (shown/hidden per engine — always in correct place)
        self.keys_frame = tk.Frame(self.trans_options_frame, bg=SURFACE)
        self.keys_frame.pack(fill="x", pady=(4,0))
        self._build_key_fields(self.keys_frame)

        # ── Output card
        section_label(parent, "OUTPUT FOLDER")
        oc = card(parent)
        oc.pack(fill="x", pady=(0,4))
        oin = tk.Frame(oc, bg=SURFACE, padx=14, pady=10)
        oin.pack(fill="x")
        self.out_entry = tk.Entry(oin, textvariable=self.output_var,
                                  bg=SURFACE2, fg=FG, relief="flat",
                                  font=FONT_SMALL, state="readonly")
        self.out_entry.pack(fill="x", pady=(0,6))
        ghost_btn(oin, "📁  Choose folder", self._choose_output).pack(fill="x")

    def _build_key_fields(self, parent):
        def key_row(p, label, var, placeholder="Paste API key…"):
            f = tk.Frame(p, bg=SURFACE)
            f.pack(fill="x", pady=2)
            tk.Label(f, text=label, bg=SURFACE, fg=FG_MUTED,
                     font=FONT_SMALL, width=8, anchor="w").pack(side="left")
            e = tk.Entry(f, textvariable=var, show="•",
                         bg=SURFACE2, fg=FG, relief="flat",
                         font=FONT_SMALL, insertbackground=FG)
            e.pack(side="left", fill="x", expand=True, padx=(4,0))
            return f

        self.deepl_row  = key_row(parent, "DeepL",   self.deepl_key_var)
        self.openai_row = key_row(parent, "OpenAI",  self.openai_key_var)
        self.claude_row = key_row(parent, "Claude",  self.claude_key_var)
        self.gemini_row = key_row(parent, "Gemini",  self.gemini_key_var)

        for r in (self.deepl_row, self.openai_row,
                  self.claude_row, self.gemini_row):
            r.pack_forget()

        note = tk.Label(parent, text="Google is free — no key needed.",
                        bg=SURFACE, fg=FG_LIGHT, font=FONT_SMALL, anchor="w")
        note.pack(fill="x", pady=(4,0))
        self.engine_note_lbl = note

    def _build_right(self, parent):
        # ── Drop zone
        section_label(parent, "FILES")
        self.drop_zone = tk.Frame(parent, bg=SURFACE, relief="flat",
                                  bd=2, height=130)
        self.drop_zone.pack(fill="x", pady=(0,4))
        self.drop_zone.pack_propagate(False)
        self._drop_label = tk.Label(
            self.drop_zone,
            text="ʕ•ᴥ•ʔ\n\nfeed wombat what you want to transcribe!",
            bg=SURFACE, fg=FG_MUTED,
            font=("SF Pro Text", 13), justify="center",
        )
        self._drop_label.pack(expand=True)

        if self.dnd_ok and DND_FILES:
            self.drop_zone.drop_target_register(DND_FILES)
            self.drop_zone.dnd_bind("<<Drop>>", self._on_drop)
            self._drop_label.drop_target_register(DND_FILES)
            self._drop_label.dnd_bind("<<Drop>>", self._on_drop)

        # file buttons
        fb = tk.Frame(parent, bg=BG)
        fb.pack(fill="x", pady=(0,6))
        ghost_btn(fb, "+ Add files", self._add_files).pack(side="left")
        ghost_btn(fb, "✕ Clear", self._clear_files).pack(side="left", padx=6)
        # Canvas-based button guarantees color on macOS (tk.Button bg ignored by Aqua)
        self.start_btn = _ColorBtn(fb, "▶  Start Transcribe",
                                   self._start, ACCENT, "white", FONT_HEAD)
        self.start_btn.pack(side="right")

        # file list
        list_frame = tk.Frame(parent, bg=SURFACE)
        list_frame.pack(fill="x", pady=(0,8))
        self.listbox = tk.Listbox(list_frame, height=5, bg=SURFACE, fg=FG,
                                  selectbackground=TAG_BG, selectforeground=ACCENT,
                                  relief="flat", bd=0, font=FONT_SMALL,
                                  highlightthickness=0)
        self.listbox.pack(fill="x", padx=2, pady=2)

        # ── Progress
        section_label(parent, "PROGRESS")
        prog_card = card(parent)
        prog_card.pack(fill="x", pady=(0,8))
        pin = tk.Frame(prog_card, bg=SURFACE, padx=14, pady=12)
        pin.pack(fill="x")

        self.progressbar = ttk.Progressbar(pin, mode="determinate",
                                           maximum=100,
                                           style="Prog.Horizontal.TProgressbar")
        self.progressbar.pack(fill="x", pady=(0,6))

        pl = tk.Frame(pin, bg=SURFACE)
        pl.pack(fill="x")
        self.prog_lbl = tk.Label(pl, textvariable=self.prog_text_var,
                                  bg=SURFACE, fg=FG, font=FONT_BODY, anchor="w")
        self.prog_lbl.pack(side="left")
        self.eta_lbl = tk.Label(pl, textvariable=self.eta_var,
                                 bg=SURFACE, fg=FG_MUTED, font=FONT_SMALL, anchor="e")
        self.eta_lbl.pack(side="right")

        # ── Log
        section_label(parent, "LOG")
        log_card = card(parent)
        log_card.pack(fill="both", expand=True)
        log_in = tk.Frame(log_card, bg=SURFACE, padx=4, pady=4)
        log_in.pack(fill="both", expand=True)

        scroll = tk.Scrollbar(log_in)
        scroll.pack(side="right", fill="y")
        self.log_text = tk.Text(log_in, bg="#F8F9FF", fg=FG,
                                 font=FONT_MONO, relief="flat",
                                 yscrollcommand=scroll.set,
                                 wrap="word", height=10,
                                 insertbackground=FG)
        self.log_text.pack(fill="both", expand=True)
        scroll.config(command=self.log_text.yview)

        # colour tags
        self.log_text.tag_config("ok",   foreground=SUCCESS)
        self.log_text.tag_config("err",  foreground=DANGER)
        self.log_text.tag_config("info", foreground=ACCENT)

        # credits
        tk.Label(parent, text=f"Made by {CREDIT_NAME}  ·  {CREDIT_EMAIL}",
                 bg=BG, fg=FG_LIGHT, font=FONT_SMALL).pack(anchor="e", pady=(4,0))

    # ── Callbacks ───────────────────────────────────────────────────────────
    def _on_model_change(self, *_):
        self._update_model_desc()

    def _update_model_desc(self):
        m = self.model_var.get().strip()
        desc = MODEL_DESCRIPTIONS.get(m, "Custom local model.")
        self.model_desc_lbl.configure(text=desc)

    def _on_trans_mode(self, *_):
        enabled = self.trans_mode_var.get() == "Enabled"
        if enabled:
            self.trans_status_lbl.configure(
                text="✅  Enabled — transcript will include translation",
                fg=SUCCESS)
        else:
            self.trans_status_lbl.configure(
                text="○  Disabled — options below are ready when you enable",
                fg=FG_LIGHT)

    def _on_engine_change(self, *_):
        eng = self.engine_var.get()
        for row, name in (
            (self.deepl_row,  "DeepL"),
            (self.openai_row, "OpenAI"),
            (self.claude_row, "Claude"),
            (self.gemini_row, "Gemini"),
        ):
            if name in eng:
                row.pack(fill="x", pady=2)
            else:
                row.pack_forget()

        if "Google" in eng:
            self.engine_note_lbl.configure(text="Google is free — no key needed.")
        elif "DeepL" in eng:
            self.engine_note_lbl.configure(
                text="Free key at deepl.com/pro-api  (no credit card needed)")
        elif "OpenAI" in eng:
            self.engine_note_lbl.configure(text="Get key at platform.openai.com")
        elif "Claude" in eng:
            self.engine_note_lbl.configure(text="Get key at console.anthropic.com")
        elif "Gemini" in eng:
            self.engine_note_lbl.configure(text="Get key at aistudio.google.com")

    def _on_key_typed(self, *_):
        """Auto-select engine when user pastes a key."""
        key_engine = {
            self.deepl_key_var:  "DeepL",
            self.openai_key_var: "OpenAI",
            self.claude_key_var: "Claude",
            self.gemini_key_var: "Gemini",
        }
        for var, eng in key_engine.items():
            if var.get().strip():
                # only switch if translation is enabled
                if self.trans_mode_var.get() == "Enabled":
                    self.engine_var.set(eng)
                break

    def _choose_output(self):
        d = filedialog.askdirectory(initialdir=self.output_var.get())
        if d:
            self.output_var.set(d)

    def _add_files(self):
        chosen = filedialog.askopenfilenames(
            title="Choose audio/video files",
            filetypes=[("Audio/Video",
                        "*.m4a *.mp3 *.wav *.flac *.ogg *.opus "
                        "*.aac *.mp4 *.mov *.mkv *.webm *.m4v")],
        )
        if chosen:
            self._append([Path(x) for x in chosen])

    def _on_drop(self, event):
        self._append(parse_drop(event.data, self.root))

    def _append(self, paths: Iterable[Path]):
        added = 0
        for p in paths:
            if p.suffix.lower() not in SUPPORTED_EXT:
                continue
            if p not in self.files:
                self.files.append(p)
                self.listbox.insert("end", f"  {p.name}")
                added += 1
        if added:
            self._log(f"Added {added} file(s).", "info")
            self._drop_label.configure(
                text=f"(◕‿◕)\n\n{len(self.files)} file(s) queued  ·  drop more to add")

    def _clear_files(self):
        self.files.clear()
        self.listbox.delete(0, "end")
        self._drop_label.configure(
            text="ʕ•ᴥ•ʔ\n\nfeed wombat what you want to transcribe!")

    # ── Start ───────────────────────────────────────────────────────────────
    def _start(self):
        if self.worker and self.worker.is_alive():
            messagebox.showinfo(APP_NAME, "Already running.", parent=self.root)
            return
        if not self.files:
            messagebox.showwarning(APP_NAME, "Add at least one file first.", parent=self.root)
            return

        out_dir = Path(self.output_var.get()).expanduser()
        out_dir.mkdir(parents=True, exist_ok=True)

        self.start_btn.config(state="disabled")
        self._files_done  = 0
        self._files_total = len(self.files)
        self._start_time  = time.monotonic()
        self._qprog(0.0, f"0 / {self._files_total} files")
        self.eta_var.set("Estimating…")
        self._log(f"Starting — {self._files_total} file(s)…", "info")

        # Read ALL tkinter vars in the main thread before handing off to worker
        # (tkinter StringVar.get() is NOT thread-safe — must only be called here)
        worker_opts = {
            "model_name":   self.model_var.get(),
            "lang":         self.lang_var.get(),
            "trans_mode":   self.trans_mode_var.get(),
            "trans_from":   self.trans_from_var.get(),
            "trans_to":     self.trans_to_var.get(),
            "engine":       self.engine_var.get(),
            "deepl_key":    self.deepl_key_var.get().strip(),
            "openai_key":   self.openai_key_var.get().strip(),
            "claude_key":   self.claude_key_var.get().strip(),
            "gemini_key":   self.gemini_key_var.get().strip(),
        }

        self.worker = threading.Thread(
            target=self._worker, args=(list(self.files), out_dir, worker_opts), daemon=True)
        self.worker.start()

    # ── Worker ──────────────────────────────────────────────────────────────
    def _worker(self, files: List[Path], out_dir: Path, opts: dict):
        try:
            model = self._load_model(opts["model_name"])
            lang_code = LANGUAGE_MAP.get(opts["lang"], "en")
            language  = None if lang_code == "auto" else lang_code

            trans_on        = opts["trans_mode"] == "Enabled"
            from_code       = LANGUAGE_MAP.get(opts["trans_from"], "auto")
            to_label        = opts["trans_to"]
            to_code         = TRANSLATE_TO_MAP.get(to_label)
            engine          = opts["engine"]
            total = len(files)

            for i, fp in enumerate(files, 1):
                self._qlog(f"[{i}/{total}]  {fp.name}")
                last: dict = {"pct": -1.0, "ts": 0.0}

                def on_prog(file_pct: float) -> None:
                    now = time.monotonic()
                    if file_pct - last["pct"] < 0.02 and now - last["ts"] < 0.5:
                        return
                    last["pct"] = file_pct
                    last["ts"]  = now
                    overall = ((i - 1) + max(0.0, min(1.0, file_pct))) / max(1, total) * 100.0
                    elapsed = now - self._start_time
                    if overall > 1:
                        eta_s = elapsed / (overall / 100.0) - elapsed
                        eta_str = f"ETA ~{int(eta_s // 60)}m {int(eta_s % 60)}s"
                    else:
                        eta_str = "Estimating…"
                    self._qprog(overall,
                                f"{i}/{total}  ·  {fp.name}  ({int(file_pct*100)}%)",
                                eta_str)

                transcript = self._transcribe(
                    model, fp, language,
                    trans_on, from_code, to_code,
                    opts["trans_from"], to_label, engine,
                    on_prog, opts,
                )
                out = out_dir / f"{fp.stem}.txt"
                out.write_text(transcript, encoding="utf-8")
                self._qlog(f"✓  Saved → {out}", "ok")
                self._files_done = i
                self._qprog(i / max(1, total) * 100.0, f"{i}/{total} done")

            self._qlog("✅  All files done!  (◕‿◕) quokka is smiling!", "ok")
            self._qprog(100.0, "Done", "")
            self.root.after(0, lambda: messagebox.showinfo(
                APP_NAME, "Transcription complete! 🎉\n\n(◕‿◕)\nQuokka is smiling!",
                parent=self.root))
        except Exception as e:
            self._qlog(f"ERROR: {e}", "err")
            self._qlog(traceback.format_exc(), "err")
            self.root.after(0, lambda: messagebox.showerror(APP_NAME, f"Failed:\n{e}", parent=self.root))
        finally:
            self.root.after(0, self._finish_ui)

    # ── Model loading ────────────────────────────────────────────────────────
    def _discover(self):
        found: dict[str, Path] = {}
        for root in (resource_base() / "models", self._user_models()):
            if not root.exists():
                continue
            for p in root.iterdir():
                if p.is_dir() and p.name.startswith("faster-whisper-"):
                    found[p.name.replace("faster-whisper-", "", 1)] = p
        order = ["small","base","tiny","medium","large-v3","large-v2","large-v1",
                 "small.en","base.en","tiny.en","medium.en"]
        ordered = [n for n in order if n in found]
        extras  = sorted(n for n in found if n not in order)
        models  = ordered + extras or [DEFAULT_MODEL]
        return models, found

    def _user_models(self) -> Path:
        return Path.home() / "Library" / "Application Support" / APP_NAME / "models"

    def _load_model(self, name: str) -> WhisperModel:
        if name in self.model_cache:
            self._qlog(f"Using cached model: {name}", "info")
            return self.model_cache[name]
        loc = self.model_locations.get(name)
        if loc is None or not loc.exists():
            raise RuntimeError(
                f"Model '{name}' not found.\n"
                f"Available: {list(self.model_locations.keys())}\n"
                "Use Install → Download Model first.")
        self._qlog(f"Loading model '{name}' from: {loc}", "info")
        try:
            m = WhisperModel(str(loc), device="cpu", compute_type="int8")
        except Exception:
            self._qlog("int8 failed, retrying with float32…", "info")
            m = WhisperModel(str(loc), device="cpu", compute_type="float32")
        self.model_cache[name] = m
        self._qlog(f"Model '{name}' loaded ✓", "ok")
        return m

    def _install_clicked(self):
        if self.worker and self.worker.is_alive():
            messagebox.showinfo(APP_NAME, "Transcription running — wait until done.", parent=self.root)
            return
        # Read directly from the widget — macOS readonly Combobox may not sync textvariable
        name = (self.install_cb.get() or self.install_var.get()).strip()
        if name in self.model_locations:
            messagebox.showinfo(APP_NAME, f"Model '{name}' is already installed.", parent=self.root)
            return
        desc = MODEL_DESCRIPTIONS.get(name, "")
        if not messagebox.askyesno(APP_NAME,
                                   f"Download model '{name}'?\n\n{desc}\n\n"
                                   "Anonymous download — no token needed.",
                                   parent=self.root):
            return
        self.dl_btn.config(state="disabled")
        self._log(f"Downloading {name}…", "info")
        threading.Thread(target=self._dl_worker, args=(name,), daemon=True).start()

    def _dl_worker(self, name: str):
        try:
            if snapshot_download is None:
                raise RuntimeError("huggingface_hub not available.")
            out = self._user_models() / f"faster-whisper-{name}"
            out.mkdir(parents=True, exist_ok=True)
            repo_id = f"Systran/faster-whisper-{name}"
            self._qlog(f"Connecting to HuggingFace: {repo_id}…", "info")
            # Disable hf-xet accelerator — can fail in bundled apps
            os.environ["HF_HUB_DISABLE_XET"] = "1"
            # Fix SSL certificate path for bundled apps (macOS PyInstaller)
            try:
                import certifi
                os.environ.setdefault("SSL_CERT_FILE",      certifi.where())
                os.environ.setdefault("REQUESTS_CA_BUNDLE", certifi.where())
            except Exception:
                pass
            try:
                # newer huggingface_hub (≥0.23) dropped local_dir_use_symlinks
                snapshot_download(repo_id=repo_id,
                                  token=None,
                                  local_dir=str(out))
            except TypeError:
                # fallback for older API
                snapshot_download(repo_id=repo_id,
                                  token=None,
                                  local_dir=str(out),
                                  local_dir_use_symlinks=False)
            self._qlog(f"Model '{name}' ready.", "ok")
            self.root.after(0, lambda: self._refresh_models(name))
            self.root.after(0, lambda: messagebox.showinfo(APP_NAME,
                                                            f"Model '{name}' installed!",
                                                            parent=self.root))
        except Exception as e:
            self._qlog(f"Download failed: {e}", "err")
            self._qlog(traceback.format_exc(), "err")
            self.root.after(0, lambda: messagebox.showerror(APP_NAME, str(e), parent=self.root))
        finally:
            self.root.after(0, lambda: self.dl_btn.config(state="normal"))

    def _refresh_models(self, select=None):
        cur = self.model_var.get()
        models, locs = self._discover()
        self.model_choices    = models
        self.model_locations  = locs
        self.model_menu["values"] = models
        chosen = select if select in models else (cur if cur in models else models[0])
        self.model_var.set(chosen)
        self._update_model_desc()

    # ── Transcription ────────────────────────────────────────────────────────
    def _transcribe(self, model, fp, language,
                    trans_on, from_code, to_code,
                    from_label, to_label, engine, prog_cb, opts=None):
        segs_raw, info = model.transcribe(
            str(fp),
            language=language,
            beam_size=8, best_of=5, temperature=0.0,
            vad_filter=True,
            vad_parameters={"min_silence_duration_ms": 450},
            word_timestamps=True,
        )
        lines: List[Seg] = []
        dur = float(getattr(info, "duration", 0.0) or 0.0)
        for s in segs_raw:
            txt = normalize(s.text)
            no_sp = float(getattr(s, "no_speech_prob", 0.0) or 0.0)
            logp  = float(getattr(s, "avg_logprob",    0.0) or 0.0)
            if not txt or (no_sp > 0.72 and logp < -1.0):
                txt = "[inaudible]"
            lines.append(Seg(float(s.start), float(s.end), txt))
            if dur > 0:
                prog_cb(min(1.0, float(s.end) / dur))

        if not lines:
            lines.append(Seg(0.0, 0.0, "[inaudible]"))
            prog_cb(1.0)

        do_trans = trans_on and bool(to_code)
        if do_trans and from_code != "auto" and from_code == to_code:
            self._qlog("Translation skipped: same source and target.")
            do_trans = False

        xlated: List[Seg] = []
        if do_trans and to_code:
            self._qlog(f"Translating {from_label} → {to_label}  [{engine}]", "info")
            xlated = self._translate(lines, from_code, to_code, engine, opts or {})

        detected = LANGUAGE_MAP.get(
            CODE_TO_LANG.get(getattr(info, "language", "?"), "?"), "?")
        header = [
            f"# {APP_NAME} Transcript",
            f"# File:      {fp.name}",
            f"# Created:   {datetime.now().isoformat(timespec='seconds')}",
            f"# Detected:  {CODE_TO_LANG.get(getattr(info,'language','?'), getattr(info,'language','?'))}",
            f"# Translation: {'Enabled' if do_trans else 'Disabled'}",
            f"# Trans from:  {from_label}",
            f"# Trans to:    {to_label}",
            f"# Engine:      {engine}",
            "",
        ]
        body = []
        for i, x in enumerate(lines):
            body.append(f"[{ts(x.start)} - {ts(x.end)}]  {x.text}")
            if xlated:
                body.append(f"  → [{to_label}]  {xlated[i].text}")
        return "\n".join(header + body) + "\n"

    # ── Translation ──────────────────────────────────────────────────────────
    def _translate(self, lines: List[Seg], src: str, tgt: str, engine: str,
                   opts: dict = None) -> List[Seg]:
        opts = opts or {}
        out: List[Seg] = []
        for line in lines:
            if line.text in {"[inaudible]", "[laughter]"}:
                out.append(Seg(line.start, line.end, line.text))
                continue
            try:
                result = self._translate_text(line.text, src, tgt, engine, opts)
            except Exception as e:
                self._qlog(f"Translation error: {e}", "err")
                result = line.text
            out.append(Seg(line.start, line.end, normalize(result) or line.text))
        return out

    def _translate_text(self, text: str, src: str, tgt: str, engine: str,
                        opts: dict = None) -> str:
        opts = opts or {}
        if "Google" in engine:
            return self._google_translate(text, src, tgt)
        if "DeepL" in engine:
            return self._deepl_translate(text, tgt, opts.get("deepl_key", ""))
        if "OpenAI" in engine:
            return self._openai_translate(text, src, tgt, opts.get("openai_key", ""))
        if "Claude" in engine:
            return self._claude_translate(text, src, tgt, opts.get("claude_key", ""))
        if "Gemini" in engine:
            return self._gemini_translate(text, src, tgt, opts.get("gemini_key", ""))
        return text

    def _google_translate(self, text, src, tgt):
        if GoogleTranslator is None:
            raise RuntimeError("deep-translator not installed.")
        key = f"{src}->{tgt}"
        if key not in self.translator_cache:
            self.translator_cache[key] = GoogleTranslator(
                source="auto" if src == "auto" else src, target=tgt)
        return self.translator_cache[key].translate(text) or text

    def _deepl_translate(self, text, tgt, key=""):
        if deepl_sdk is None:
            raise RuntimeError("deepl package not installed (pip install deepl).")
        key = key or os.environ.get("DEEPL_API_KEY", "")
        if not key:
            raise RuntimeError("DeepL API key is empty.")
        cache_key = f"deepl-{key[:8]}"
        if cache_key not in self.translator_cache:
            self.translator_cache[cache_key] = deepl_sdk.Translator(key)
        result = self.translator_cache[cache_key].translate_text(text, target_lang=tgt.upper())
        return result.text

    def _openai_translate(self, text, src, tgt, key=""):
        if OpenAI is None:
            raise RuntimeError("openai package not installed.")
        key = key or os.environ.get("OPENAI_API_KEY", "")
        if not key:
            raise RuntimeError("OpenAI API key is empty.")
        if "openai-client" not in self.translator_cache or \
                self.translator_cache.get("openai-key") != key:
            self.translator_cache["openai-client"] = OpenAI(api_key=key)
            self.translator_cache["openai-key"] = key
        client = self.translator_cache["openai-client"]
        src_name = CODE_TO_LANG.get(src, src)
        tgt_name = CODE_TO_LANG.get(tgt, tgt)
        resp = client.chat.completions.create(
            model="gpt-4o-mini",
            messages=[
                {"role": "system",
                 "content": f"Translate from {src_name} to {tgt_name}. Return translated text only."},
                {"role": "user", "content": text},
            ],
            temperature=0,
        )
        return (resp.choices[0].message.content or "").strip() or text

    def _claude_translate(self, text, src, tgt, key=""):
        if anthropic_sdk is None:
            raise RuntimeError("anthropic package not installed.")
        key = key or os.environ.get("ANTHROPIC_API_KEY", "")
        if not key:
            raise RuntimeError("Claude API key is empty.")
        if "claude-client" not in self.translator_cache or \
                self.translator_cache.get("claude-key") != key:
            self.translator_cache["claude-client"] = anthropic_sdk.Anthropic(api_key=key)
            self.translator_cache["claude-key"] = key
        client = self.translator_cache["claude-client"]
        src_name = CODE_TO_LANG.get(src, src)
        tgt_name = CODE_TO_LANG.get(tgt, tgt)
        msg = client.messages.create(
            model="claude-haiku-4-5-20251001",
            max_tokens=512,
            messages=[{"role": "user",
                       "content": f"Translate from {src_name} to {tgt_name}. "
                                  f"Return translated text only.\n\n{text}"}],
        )
        return (msg.content[0].text or "").strip() or text

    def _gemini_translate(self, text, src, tgt, key=""):
        if genai_sdk is None:
            raise RuntimeError("google-generativeai package not installed.")
        key = key or os.environ.get("GEMINI_API_KEY", "")
        if not key:
            raise RuntimeError("Gemini API key is empty.")
        genai_sdk.configure(api_key=key)
        src_name = CODE_TO_LANG.get(src, src)
        tgt_name = CODE_TO_LANG.get(tgt, tgt)
        model = genai_sdk.GenerativeModel("gemini-2.0-flash")
        resp = model.generate_content(
            f"Translate from {src_name} to {tgt_name}. "
            f"Return translated text only.\n\n{text}"
        )
        return (resp.text or "").strip() or text

    # ── UI helpers ───────────────────────────────────────────────────────────
    def _finish_ui(self):
        self.start_btn.config(state="normal")
        self.start_btn.itemconfig(self.start_btn._rect, fill=ACCENT)

    def _log(self, msg: str, tag: str = ""):
        self.log_text.insert("end", msg + "\n", tag)
        self.log_text.see("end")

    def _qlog(self, msg: str, tag: str = ""):
        self.log_q.put((msg, tag))

    def _qprog(self, pct: float, msg: str, eta: str = ""):
        self.prog_q.put((max(0., min(100., pct)), msg, eta))

    def _drain(self):
        try:
            while True:
                msg, tag = self.log_q.get_nowait()
                self._log(msg, tag)
        except queue.Empty:
            pass
        try:
            while True:
                pct, msg, eta = self.prog_q.get_nowait()
                self.progressbar["value"] = pct
                self.prog_text_var.set(msg)
                self.eta_var.set(eta)
        except queue.Empty:
            pass
        self.root.after(120, self._drain)

    def run(self):
        self.root.mainloop()


def main():
    App().run()


if __name__ == "__main__":
    main()
