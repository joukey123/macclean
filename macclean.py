#!/usr/bin/env python3
"""
macclean — 나만 쓰는 맥 클리너

  python3 macclean.py                     # 전체 스캔 → 번호 골라서 휴지통으로
  python3 macclean.py --scan-only         # 보기만 (아무것도 안 건드림)
  python3 macclean.py --uninstall Slack   # 앱 + 남은 파일까지 완전 삭제
  python3 macclean.py --empty-trash       # 휴지통 비우기 (영구 삭제)

  옵션
  --days 30        '오래된' 기준 일수 (기본 14)
  --big-mb 1000    대용량 파일 기준 MB (기본 500)
  --dupe-mb 5      중복 파일 검사 최소 크기 MB (기본 10)
  --root ~/work    스캔 위치 추가 (여러 번 가능)

--empty-trash 를 빼면 절대 바로 삭제하지 않고 휴지통(~/.Trash)으로만 옮깁니다.
휴지통을 비워야 실제 용량이 늘어나요.
"""
import argparse
import glob
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import time
from collections import defaultdict

HOME = os.path.expanduser("~")
LIB = os.path.join(HOME, "Library")
NOW = time.time()
IS_MAC = sys.platform == "darwin"

SAFE, CHECK = "✅", "⚠️ "

# 다시 설치/생성 가능한 개발 찌꺼기
JUNK_DIRS = {
    "node_modules": "npm install 로 복구",
    ".venv": "가상환경 재생성으로 복구",
    "venv": "가상환경 재생성으로 복구",
    "__pycache__": "자동 재생성",
    ".next": "다시 빌드하면 생김",
    ".turbo": "캐시",
    ".parcel-cache": "캐시",
    "win-unpacked": "빌드 결과물",
}
SKIP_DESCEND = {".git", "Library", ".Trash", "Applications"}
BUNDLE_EXT = (".app", ".photoslibrary", ".photolibrary", ".fcpbundle", ".logicx",
              ".imovielibrary", ".musiclibrary", ".tvlibrary", ".band", ".xcarchive")
INSTALLER_EXT = (".dmg", ".pkg", ".iso", ".xip", ".mpkg")

DEV_ROOTS = ["Documents", "Desktop", "Downloads", "Developer", "Projects", "dev", "code", "work"]
FILE_ROOTS = DEV_ROOTS + ["Movies", "Music", "Pictures"]

APP_DIRS = os.environ.get("MACCLEAN_APP_DIRS", "").split(os.pathsep) if os.environ.get("MACCLEAN_APP_DIRS") \
    else ["/Applications", os.path.join(HOME, "Applications"), "/System/Applications"]

# 앱이 흔적을 남기는 곳
LEFTOVER_DIRS = ["Application Support", "Caches", "Preferences", "Preferences/ByHost", "Containers",
                 "Group Containers", "Saved Application State", "Logs", "HTTPStorages", "WebKit",
                 "Cookies", "LaunchAgents", "Application Scripts"]


# ───────────────────────── 유틸 ─────────────────────────
def size_of(path):
    """심볼릭 링크를 따라가지 않고 실제 디스크 사용량(바이트)."""
    try:
        st = os.lstat(path)
    except OSError:
        return 0
    if not os.path.isdir(path) or os.path.islink(path):
        return st.st_blocks * 512
    total = 0
    stack = [path]
    while stack:
        d = stack.pop()
        try:
            with os.scandir(d) as it:
                for e in it:
                    try:
                        if e.is_dir(follow_symlinks=False):
                            stack.append(e.path)
                        else:
                            total += e.stat(follow_symlinks=False).st_blocks * 512
                    except OSError:
                        pass
        except OSError:
            pass
    return total


def human(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.0f}{unit}" if unit in ("B", "KB") else f"{n:.1f}{unit}"
        n /= 1024


def short(p):
    return p.replace(HOME, "~", 1)


def mtime(p):
    try:
        return os.lstat(p).st_mtime
    except OSError:
        return NOW


def last_used(p):
    """마지막 사용 = 수정/접근 중 최근 것."""
    try:
        st = os.lstat(p)
        return max(st.st_mtime, st.st_atime)
    except OSError:
        return NOW


def age_days(p, used=False):
    return (NOW - (last_used(p) if used else mtime(p))) / 86400


def listdir(p):
    try:
        return os.listdir(p)
    except OSError:
        return []


def item(cat, label, paths, level, note="", size=None, show=False):
    paths = [p for p in paths if os.path.lexists(p)]
    if not paths:
        return None
    if size is None:
        size = sum(size_of(p) for p in paths)
    return {"cat": cat, "label": label, "paths": paths, "level": level,
            "note": note, "size": size, "show": show}


def skip_dir(name):
    return (name in SKIP_DESCEND or name in JUNK_DIRS or name.startswith(".")
            or name.lower().endswith(BUNDLE_EXT))


class Claimed:
    """이미 다른 항목에 들어간 경로 (같은 걸 두 번 지우지 않도록)."""
    def __init__(self):
        self.s = set()

    def add(self, items):
        for it in items:
            if it:
                self.s.update(os.path.normpath(p) for p in it["paths"])

    def __contains__(self, p):
        p = os.path.normpath(p)
        while True:
            if p in self.s:
                return True
            parent = os.path.dirname(p)
            if parent == p:
                return False
            p = parent


# ───────────────────────── 1. AI 앱 ─────────────────────────
AI_PAT = re.compile(r"(anthropic|claude|openai|chatgpt|codex)", re.I)


# 대화 이력·기억·설정 보호: 이 경로들은 어떤 기능으로도 절대 건드리지 않음
PROTECT_DIRS = [os.path.join(HOME, d) for d in (".claude", ".codex", ".chatgpt", ".openai", ".anthropic")]
PROTECT_ALLOW = [os.path.join(HOME, ".codex", "cache")]  # 순수 캐시만 예외
PROTECT_LIB_SUBS = ["Application Support", "Containers", "Group Containers", "Preferences",
                    "Saved Application State", "WebKit", "HTTPStorages", "Cookies"]


def is_protected(p):
    p = os.path.normpath(os.path.abspath(p))
    under = lambda base: p == base or p.startswith(base + os.sep)
    if any(under(a) for a in PROTECT_ALLOW):
        return False
    if any(under(d) for d in PROTECT_DIRS):
        return True
    for sub in PROTECT_LIB_SUBS:
        base = os.path.join(LIB, sub) + os.sep
        if p.startswith(base):
            entry = p[len(base):].split(os.sep)[0]
            if AI_PAT.search(entry):
                return True
    return False


def scan_ai(days):
    """캐시만 정리. 대화 기록·세션·기억·생성 이미지는 보호 대상이라 다루지 않음."""
    out = [item("AI 앱", "Codex 캐시", [os.path.join(HOME, ".codex", "cache")], SAFE, "자동 재생성 · 대화 이력과 무관")]
    caches = os.path.join(LIB, "Caches")
    for n in sorted(listdir(caches)):
        if AI_PAT.search(n):
            out.append(item("AI 앱", f"앱 캐시: {n}", [os.path.join(caches, n)], SAFE, "자동 재생성", show=True))
    return [x for x in out if x]


# ───────────────────── 2. 개발 폴더 (중복 빌드 / 찌꺼기) ─────────────────────
def stems(name):
    """'windows-dist-0.5.4' → ['windows', 'windows-dist', 'windows-dist-0', ..., 'windows-dist-0.5.4']"""
    parts = re.split(r"([-_. ])", name)
    res, acc = [], ""
    for i, p in enumerate(parts):
        acc += p
        if i % 2 == 0 and acc and acc != name:
            res.append(acc)
    res.append(name)
    return res


def find_dup_groups(parent, children, min_group=3):
    """이름 앞부분이 같고 크기도 비슷한 형제 폴더 묶음. 반환: {stem: (members, sizes)}"""
    stem_members = defaultdict(set)
    for c in children:
        for s in stems(c):
            if len(s) >= 4:
                stem_members[s].add(c)
    cands = {s: m for s, m in stem_members.items() if len(m) >= min_group}
    if not cands:
        return {}
    sizes = {}

    def sz(c):
        if c not in sizes:
            sizes[c] = size_of(os.path.join(parent, c))
        return sizes[c]

    scored = []
    for s, members in cands.items():
        vals = sorted(sz(c) for c in members)
        med = vals[len(vals) // 2]
        if med <= 0:
            continue
        similar = {c for c in members if 0.7 * med <= sz(c) <= 1.4 * med}
        if len(similar) >= min_group:
            scored.append((len(similar), len(s), s, similar))
    scored.sort(reverse=True)
    taken, groups = set(), {}
    for _, _, s, similar in scored:
        free = similar - taken
        if len(free) >= min_group:
            groups[s] = (sorted(free), {c: sizes[c] for c in free})
            taken |= free
    return groups


def scan_dev(roots, days, min_mb):
    dups, junk = [], []
    for root in roots:
        if not os.path.isdir(root):
            continue
        root_depth = root.rstrip(os.sep).count(os.sep)
        for cur, dirs, files in os.walk(root, topdown=True):
            if cur.count(os.sep) - root_depth >= 8:
                dirs[:] = []
                continue
            dirs[:] = [d for d in dirs if d not in SKIP_DESCEND and not d.lower().endswith(BUNDLE_EXT)]
            skip = set()
            for stem, (members, msizes) in find_dup_groups(cur, dirs).items():
                paths = sorted((os.path.join(cur, m) for m in members), key=mtime, reverse=True)
                if sum(msizes.values()) < 100 * 1024 * 1024:
                    continue
                keep, rest = paths[0], paths[1:]
                dups.append({
                    "cat": "중복 빌드 폴더", "level": CHECK, "show": False,
                    "label": f"'{stem}*' 폴더 {len(paths)}개 중 최신 1개 빼고 {len(rest)}개",
                    "paths": rest, "size": sum(msizes[os.path.basename(p)] for p in rest),
                    "note": f"남김: {os.path.basename(keep)}  (위치: {short(cur)})",
                })
                skip.update(members)
            for d in dirs:
                if d in JUNK_DIRS and d not in skip:
                    p = os.path.join(cur, d)
                    if age_days(p) >= days:
                        s = size_of(p)
                        if s >= min_mb * 1024 * 1024:
                            junk.append({"cat": "개발 찌꺼기", "label": f"{d} — {short(cur)}",
                                         "paths": [p], "size": s, "level": SAFE, "show": False,
                                         "note": JUNK_DIRS[d]})
                    skip.add(d)
            dirs[:] = [d for d in dirs if d not in skip]
    return dups + sorted(junk, key=lambda x: -x["size"])


# ───────────────────────── 3. 시스템 정크 ─────────────────────────
# ───────────────────────── 인터넷·브라우저 캐시 ─────────────────────────
def _chromium(cache_dirs, support):
    """크롬 계열: 캐시 폴더 + 프로필별 코드/GPU/서비스워커 캐시 (쿠키·기록·비밀번호는 제외)."""
    pats = [f"Library/Caches/{c}" for c in cache_dirs]
    for prof in ("*",):
        for sub in ("Code Cache", "GPUCache", "Service Worker/CacheStorage", "Service Worker/ScriptCache",
                    "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache"):
            pats.append(f"Library/Application Support/{support}/{prof}/{sub}")
    for sub in ("ShaderCache", "GrShaderCache", "GraphiteDawnCache", "component_crx_cache"):
        pats.append(f"Library/Application Support/{support}/{sub}")
    return pats


# (이름, 실행 중 확인용 프로세스 이름, 캐시 경로 패턴)
BROWSERS = [
    ("Safari", "Safari", ["Library/Caches/com.apple.Safari",
                          "Library/Containers/com.apple.Safari/Data/Library/Caches"]),
    ("Chrome", "Google Chrome", _chromium(["Google/Chrome", "com.google.Chrome"], "Google/Chrome")),
    ("Whale", "Whale", _chromium(["Naver/Whale", "com.naver.Whale"], "Naver/Whale")),
    ("Edge", "Microsoft Edge", _chromium(["Microsoft Edge", "com.microsoft.edgemac"], "Microsoft Edge")),
    ("Brave", "Brave Browser", _chromium(["BraveSoftware/Brave-Browser", "com.brave.Browser"], "BraveSoftware/Brave-Browser")),
    ("Arc", "Arc", _chromium(["Arc", "company.thebrowser.Browser"], "Arc/User Data")),
    ("Vivaldi", "Vivaldi", _chromium(["Vivaldi", "com.vivaldi.Vivaldi"], "Vivaldi")),
    ("Opera", "Opera", ["Library/Caches/com.operasoftware.Opera",
                        "Library/Application Support/com.operasoftware.Opera/Code Cache",
                        "Library/Application Support/com.operasoftware.Opera/GPUCache"]),
    ("Firefox", "firefox", ["Library/Caches/Firefox/Profiles/*/cache2",
                            "Library/Caches/Firefox/Profiles/*/startupCache",
                            "Library/Caches/Firefox/Profiles/*/thumbnails",
                            "Library/Caches/org.mozilla.firefox"]),
]
# 시스템 정크의 '큰 앱 캐시'에서 중복으로 잡히지 않도록
BROWSER_CACHE_NAMES = {"Google", "com.google.Chrome", "Naver", "com.naver.Whale", "Microsoft Edge",
                       "com.microsoft.edgemac", "BraveSoftware", "com.brave.Browser", "Arc",
                       "company.thebrowser.Browser", "Vivaldi", "com.vivaldi.Vivaldi", "Firefox",
                       "org.mozilla.firefox", "com.operasoftware.Opera", "com.apple.Safari"}


def browser_running(proc):
    if not IS_MAC:
        return False
    checks = (["pgrep", "-x", proc],                                  # 프로세스 이름
              ["pgrep", "-if", f"{proc}.app/Contents/MacOS/"])        # 앱 실행 파일 경로
    for cmd in checks:
        try:
            if subprocess.run(cmd, capture_output=True, timeout=5).returncode == 0:
                return True
        except Exception:
            pass
    return False


def scan_browsers():
    out = []
    for name, proc, pats in BROWSERS:
        paths = []
        for pat in pats:
            paths += [p for p in glob.glob(os.path.join(HOME, pat)) if os.path.isdir(p)]
        # 바깥 폴더가 이미 들어 있으면 안쪽은 빼기
        paths = sorted(set(paths))
        paths = [p for p in paths if not any(p != q and p.startswith(q + os.sep) for q in paths)]
        it = item("인터넷·브라우저 캐시", f"{name} 캐시", paths, SAFE,
                  "쿠키·방문 기록·비밀번호·로그인은 그대로 · 웹페이지 임시 파일만 정리")
        if not it or it["size"] < 1024 * 1024:
            continue
        if browser_running(proc):
            it["level"] = CHECK
            it["note"] = f"{name}가 실행 중이에요 — 종료 후 정리하면 더 깔끔해요 · 쿠키·기록·비밀번호는 그대로"
        out.append(it)
    return sorted(out, key=lambda x: -x["size"])


def scan_system(days):
    out = []
    j = lambda *a: os.path.join(HOME, *a)
    out.append(item("시스템 정크", "Xcode DerivedData", [j("Library", "Developer", "Xcode", "DerivedData")], SAFE, "다시 빌드하면 생김"))
    out.append(item("시스템 정크", "Xcode 기기 지원 파일", [j("Library", "Developer", "Xcode", "iOS DeviceSupport")], SAFE, "기기 연결 시 다시 받음"))
    out.append(item("시스템 정크", "iOS 시뮬레이터 캐시", [j("Library", "Developer", "CoreSimulator", "Caches")], SAFE))
    out.append(item("시스템 정크", "Homebrew 캐시", [j("Library", "Caches", "Homebrew")], SAFE, "brew cleanup 과 동일"))
    out.append(item("시스템 정크", "npm 캐시", [j(".npm", "_cacache")], SAFE))
    out.append(item("시스템 정크", "pip 캐시", [j("Library", "Caches", "pip")], SAFE))

    # 앱 로그 (오래된 것)
    logs = []
    for root, dirs, files in os.walk(os.path.join(LIB, "Logs")):
        logs += [os.path.join(root, f) for f in files if age_days(os.path.join(root, f)) > days]
    if logs:
        out.append(item("시스템 정크", f"앱 로그 {days}일 이상 ({len(logs)}개)", logs, SAFE, "~/Library/Logs"))

    # 큰 앱 캐시
    caches = os.path.join(LIB, "Caches")
    for n in listdir(caches):
        if n in ("Homebrew", "pip") or n in BROWSER_CACHE_NAMES or AI_PAT.search(n):
            continue
        p = os.path.join(caches, n)
        s = size_of(p)
        if s >= 100 * 1024 * 1024:
            out.append(item("시스템 정크", f"앱 캐시: {n}", [p], SAFE, "자동 재생성", size=s))
    return [x for x in out if x and x["size"] > 0]


# ───────────────────────── 4. 다운로드 ─────────────────────────
def scan_downloads(days):
    out = []
    dl = os.path.join(HOME, "Downloads")
    installers = []
    for n in listdir(dl):
        p = os.path.join(dl, n)
        if n.lower().endswith(INSTALLER_EXT):
            if age_days(p) > 3:
                installers.append(p)
            continue
        s = size_of(p)
        if s >= 300 * 1024 * 1024 and age_days(p, used=True) > days:
            out.append(item("다운로드", n, [p], CHECK, f"{int(age_days(p, True))}일째 안 씀", size=s))
    if installers:
        out.insert(0, item("다운로드", f"설치 파일 .dmg/.pkg ({len(installers)}개)", installers, SAFE,
                           "이미 설치했다면 필요 없음", show=True))
    return [x for x in out if x]


# ───────────────────────── 5. 남은 앱 찌꺼기 ─────────────────────────
DNS = re.compile(r"^(?:[A-Z0-9]{10}\.)?((?:group\.)?[a-z0-9-]+\.[a-z0-9-]+(?:\.[\w-]+)*)", re.I)


def installed_apps():
    """{bundle_id: app_path}"""
    apps = {}
    for d in APP_DIRS:
        for root, dirs, files in os.walk(d):
            if root.count(os.sep) - d.count(os.sep) >= 2:
                dirs[:] = []
            for x in list(dirs):
                if x.endswith(".app"):
                    dirs.remove(x)
                    p = os.path.join(root, x)
                    bid = bundle_id(p)
                    if bid:
                        apps[bid.lower()] = p
    return apps


def bundle_id(app):
    try:
        with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
            return plistlib.load(f).get("CFBundleIdentifier")
    except Exception:
        return None


def vendor(bid):
    parts = bid.lower().replace("group.", "", 1).split(".")
    return ".".join(parts[:2])


def scan_orphans():
    apps = installed_apps()
    if not apps:  # 앱 목록을 못 읽으면 전부 고아로 오판하니 건너뜀
        return []
    vendors = {vendor(b) for b in apps}
    found = defaultdict(list)
    for sub in LEFTOVER_DIRS:
        base = os.path.join(LIB, sub)
        for n in listdir(base):
            stem = re.sub(r"\.(plist|savedState|binarycookies)$", "", n)
            m = DNS.match(stem)
            if not m:
                continue
            bid = m.group(1).lower()
            if bid.startswith(("com.apple", "group.com.apple", "apple")) or bid.count(".") < 2:
                continue
            if vendor(bid) in vendors:
                continue
            found[bid].append(os.path.join(base, n))
    out = []
    for bid, paths in found.items():
        it = item("삭제한 앱의 남은 파일", bid, paths, CHECK,
                  f"설치된 앱 없음 · {len(paths)}곳에 흔적")
        if it and it["size"] >= 1024 * 1024:
            out.append(it)
    return sorted(out, key=lambda x: -x["size"])


# ───────────────────────── 6. 대용량 / 중복 파일 ─────────────────────────
def scan_files(roots, days, big_mb, dupe_mb, claimed):
    big, by_size = [], defaultdict(list)
    seen = set()
    for root in roots:
        if not os.path.isdir(root):
            continue
        for cur, dirs, files in os.walk(root, topdown=True):
            dirs[:] = [d for d in dirs if not skip_dir(d) and os.path.join(cur, d) not in claimed]
            for f in files:
                p = os.path.join(cur, f)
                try:
                    st = os.lstat(p)
                except OSError:
                    continue
                if not os.path.isfile(p) or os.path.islink(p) or (st.st_dev, st.st_ino) in seen:
                    continue
                seen.add((st.st_dev, st.st_ino))
                if p in claimed:
                    continue
                if st.st_size >= dupe_mb * 1024 * 1024:
                    by_size[st.st_size].append(p)
                if st.st_size >= big_mb * 1024 * 1024 and age_days(p, used=True) > days:
                    big.append(p)

    # 중복: 크기 같음 → 앞/뒤 64KB 해시 → 전체 해시
    def h(p, full):
        d = hashlib.blake2b(digest_size=16)
        try:
            with open(p, "rb") as fh:
                if full:
                    for chunk in iter(lambda: fh.read(1 << 20), b""):
                        d.update(chunk)
                else:
                    d.update(fh.read(65536))
                    fh.seek(max(0, os.path.getsize(p) - 65536))
                    d.update(fh.read(65536))
        except OSError:
            return None
        return d.hexdigest()

    dupes = []
    for size, paths in by_size.items():
        if len(paths) < 2:
            continue
        quick = defaultdict(list)
        for p in paths:
            quick[h(p, False)].append(p)
        for qk, qs in quick.items():
            if qk is None or len(qs) < 2:
                continue
            full = defaultdict(list)
            for p in qs:
                full[h(p, True)].append(p)
            for fk, same in full.items():
                if fk is None or len(same) < 2:
                    continue
                # 원본 추정: 다운로드 폴더 밖 + 가장 오래된 것
                dl = os.path.join(HOME, "Downloads") + os.sep
                same.sort(key=lambda p: (p.startswith(dl), mtime(p)))
                keep, rest = same[0], same[1:]
                dupes.append({"cat": "중복 파일", "level": CHECK, "show": True,
                              "label": f"{os.path.basename(keep)} — 똑같은 파일 {len(same)}개",
                              "paths": rest, "size": sum(size_of(p) for p in rest),
                              "note": f"남김: {short(keep)}"})

    big_items = [item("대용량·오래된 파일", os.path.basename(p), [p], CHECK,
                      f"{int(age_days(p, True))}일째 안 씀 · {short(os.path.dirname(p))}")
                 for p in big if not any(p in d["paths"] for d in dupes)]
    big_items = sorted([x for x in big_items if x], key=lambda x: -x["size"])[:20]
    return big_items + sorted(dupes, key=lambda x: -x["size"])


# ───────────────────────── 휴지통 ─────────────────────────
TRASH = os.path.join(HOME, ".Trash")


TRASH_LOG = os.path.join(LIB, "Application Support", "MacClean", "trash-log.json")


def log_trash(orig, dest):
    """MacClean이 휴지통에 넣은 항목의 원래 위치 기록 (앱에서 '되돌리기'에 사용)."""
    try:
        os.makedirs(os.path.dirname(TRASH_LOG), exist_ok=True)
        try:
            with open(TRASH_LOG, encoding="utf-8") as f:
                data = json.load(f)
        except Exception:
            data = []
        data.append({"trash": dest, "orig": os.path.abspath(orig), "time": time.time()})
        tmp = TRASH_LOG + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data[-5000:], f, ensure_ascii=False)
        os.replace(tmp, TRASH_LOG)
    except Exception:
        pass


def to_trash(path):
    if is_protected(path):  # 마지막 안전장치
        return False
    os.makedirs(TRASH, exist_ok=True)
    base = os.path.basename(path.rstrip(os.sep))
    dest = os.path.join(TRASH, base)
    if os.path.lexists(dest):  # Finder처럼 '이름 2.ai', '이름 3.ai' …
        stem, ext = os.path.splitext(base)
        if not stem:  # '.venv' 같은 숨김 폴더
            stem, ext = base, ""
        n = 2
        while os.path.lexists(os.path.join(TRASH, f"{stem} {n}{ext}")):
            n += 1
        dest = os.path.join(TRASH, f"{stem} {n}{ext}")
    try:
        shutil.move(path, dest)
        log_trash(path, dest)
        return True
    except Exception:
        if IS_MAC:  # Finder 경유 (처음 한 번 권한 팝업, 관리자 앱은 암호 요청)
            r = subprocess.run(["osascript", "-e",
                                f'tell application "Finder" to delete POSIX file "{path}"'],
                               capture_output=True)
            return r.returncode == 0
        return False


def trash_size():
    try:
        os.listdir(TRASH)
    except FileNotFoundError:
        return 0
    except OSError:
        return None  # 터미널에 '전체 디스크 접근' 권한이 없으면 못 읽음
    return size_of(TRASH)


def empty_trash(yes=False):
    s = trash_size()
    if not yes:
        print(f"🗑  휴지통: {human(s) if s is not None else '크기 확인 불가 (권한)'}")
        if s == 0:
            print("이미 비어 있어요.")
            return True
        if input("휴지통을 비울까요? 되돌릴 수 없어요. [y/N]: ").strip().lower() != "y":
            print("취소했어요.")
            return False
    if IS_MAC:
        r = subprocess.run(["osascript", "-e", 'tell application "Finder" to empty trash'], capture_output=True)
        ok = r.returncode == 0
    else:
        for n in listdir(TRASH):
            p = os.path.join(TRASH, n)
            shutil.rmtree(p, ignore_errors=True) if os.path.isdir(p) and not os.path.islink(p) else os.remove(p)
        ok = True
    if not yes:
        print("✨ 휴지통을 비웠어요." if ok else "⚠️  비우지 못했어요. Finder에서 직접 비워주세요.")
    return ok


# ───────────────────────── 앱 완전 삭제 ─────────────────────────
def user_apps():
    """사용자가 지울 수 있는 앱 (시스템 앱 제외)."""
    apps = []
    for d in APP_DIRS:
        if d.startswith("/System"):
            continue
        for root, dirs, files in os.walk(d):
            if root.count(os.sep) - d.count(os.sep) >= 2:
                dirs[:] = []
            for x in list(dirs):
                if x.endswith(".app"):
                    dirs.remove(x)
                    apps.append(os.path.join(root, x))
    return sorted(apps, key=lambda p: os.path.basename(p).lower())


def app_leftovers(app):
    """(번들ID, 지울 흔적, 보호해서 남길 흔적)"""
    bid = (bundle_id(app) or "").lower()
    appname = os.path.basename(app)[:-4].lower()
    found = []
    for sub in LEFTOVER_DIRS:
        base = os.path.join(LIB, sub)
        for n in listdir(base):
            low = n.lower()
            stem = re.sub(r"\.(plist|savedstate|binarycookies)$", "", low)
            if (bid and bid in low) or stem == appname:
                found.append(os.path.join(base, n))
    return bid, [p for p in found if not is_protected(p)], [p for p in found if is_protected(p)]


def uninstall(name):
    q = name.lower().removesuffix(".app")
    cands = [p for p in user_apps() if q in os.path.basename(p).lower()]
    if not cands:
        print(f"'{name}' 앱을 /Applications 에서 찾지 못했어요.")
        return
    if len(cands) > 1:
        for i, c in enumerate(cands, 1):
            print(f"  {i}. {c}")
        try:
            app = cands[int(input("어느 앱인가요? 번호: ")) - 1]
        except (ValueError, IndexError):
            return
    else:
        app = cands[0]

    bid, leftovers, kept = app_leftovers(app)

    print(f"\n📦 {os.path.basename(app)}  ({bid or '번들 ID 없음'})")
    if kept:
        print("   🔒 대화 이력·기억·설정은 남겨둬요 (다시 설치하면 그대로 이어서 사용):")
        for p in kept:
            print(f"      {short(p)}")
    total = 0
    for p in [app] + leftovers:
        s = size_of(p)
        total += s
        print(f"   {human(s):>8}  {short(p)}")
    print(f"   {'─' * 8}\n   {human(total):>8}  합계")
    print("\n⚠️  먼저 앱을 완전히 종료해주세요 (Dock에서 우클릭 → 종료).")
    if input(f"위 {1 + len(leftovers)}개를 휴지통으로 옮길까요? [y/N]: ").strip().lower() != "y":
        print("취소했어요.")
        return
    failed = [p for p in [app] + leftovers if not to_trash(p)]
    print(f"\n🗑  {1 + len(leftovers) - len(failed)}개를 휴지통으로 옮겼어요.")
    for p in failed:
        print("   ⚠️  못 옮김:", short(p))


# ───────────────────────── 선택 / 메인 ─────────────────────────
def parse_selection(s, n, items):
    s = s.strip().lower()
    if s == "a":
        return [i for i, it in enumerate(items) if it["level"] == SAFE]
    sel = set()
    for part in s.replace(" ", "").split(","):
        if not part:
            continue
        if "-" in part:
            a, b = part.split("-", 1)
            sel.update(range(int(a) - 1, int(b)))
        else:
            sel.add(int(part) - 1)
    return sorted(i for i in sel if 0 <= i < n)


def collect(a, progress):
    extra = [os.path.expanduser(r) for r in a.root]
    claimed = Claimed()
    items = []
    steps = [
        ("AI 앱", lambda: scan_ai(a.days)),
        ("개발 폴더", lambda: scan_dev([os.path.join(HOME, r) for r in DEV_ROOTS] + extra, a.days, a.min_mb)),
        ("인터넷·브라우저 캐시", scan_browsers),
        ("시스템 정크", lambda: scan_system(a.days)),
        ("다운로드", lambda: scan_downloads(a.days)),
        ("남은 앱 찌꺼기", scan_orphans),
        ("대용량·중복 파일", lambda: scan_files([os.path.join(HOME, r) for r in FILE_ROOTS] + extra,
                                          a.days, a.big_mb, a.dupe_mb, claimed)),
    ]
    for i, (name, fn) in enumerate(steps):
        progress(i, len(steps), name)
        found = []
        for x in fn():
            if not x:
                continue
            keep = [p for p in x["paths"] if not is_protected(p)]
            if len(keep) != len(x["paths"]):
                x["paths"], x["size"] = keep, sum(size_of(p) for p in keep)
            if keep and x["size"] > 0 and not any(p in claimed for p in keep):
                found.append(x)
        claimed.add(found)
        items += found
    return items


# ───────────────────────── 개인정보 (브라우저 기록·쿠키) ─────────────────────────
# 비밀번호·키체인은 어떤 경우에도 건드리지 않음
PASSWORD_MARKERS = ("Login Data", "logins.json", "logins-backup.json", "key4.db", "key3.db",
                    "Keychains", "signons.sqlite", "Passwords")

PRIV_ITEMS = [("history", "방문 기록"), ("downloads", "다운로드 기록"),
              ("autofill", "자동완성 입력 기록"), ("cookies", "쿠키·로그인 상태")]

# 이름, 앱 번들 ID, 실행 확인용 프로세스 이름, 종류, 데이터 폴더(~/Library/Application Support 기준)
PRIV_BROWSERS = [
    ("Safari", "com.apple.Safari", "Safari", "safari", None),
    ("Chrome", "com.google.Chrome", "Google Chrome", "chromium", "Google/Chrome"),
    ("Whale", "com.naver.Whale", "Whale", "chromium", "Naver/Whale"),
    ("Edge", "com.microsoft.edgemac", "Microsoft Edge", "chromium", "Microsoft Edge"),
    ("Brave", "com.brave.Browser", "Brave Browser", "chromium", "BraveSoftware/Brave-Browser"),
    ("Arc", "company.thebrowser.Browser", "Arc", "chromium", "Arc/User Data"),
    ("Vivaldi", "com.vivaldi.Vivaldi", "Vivaldi", "chromium", "Vivaldi"),
    ("Opera", "com.operasoftware.Opera", "Opera", "chromium", "com.operasoftware.Opera"),
    ("Firefox", "org.mozilla.firefox", "firefox", "firefox", "Firefox/Profiles"),
]

CHROMIUM_HISTORY_SQL = ["DELETE FROM urls", "DELETE FROM visits", "DELETE FROM visit_source",
                        "DELETE FROM keyword_search_terms", "DELETE FROM segments", "DELETE FROM segment_usage",
                        "DELETE FROM content_annotations", "DELETE FROM context_annotations",
                        "DELETE FROM clusters", "DELETE FROM clusters_and_visits", "DELETE FROM cluster_keywords",
                        "DELETE FROM cluster_visit_duplicates", "DELETE FROM visited_links"]
CHROMIUM_DOWNLOADS_SQL = ["DELETE FROM downloads", "DELETE FROM downloads_url_chains", "DELETE FROM downloads_slices"]
FF_BOOKMARKED = "SELECT fk FROM moz_bookmarks WHERE fk IS NOT NULL"
FF_HISTORY_SQL = [
    "DELETE FROM moz_historyvisits",
    "DELETE FROM moz_inputhistory",
    f"DELETE FROM moz_annos WHERE place_id NOT IN ({FF_BOOKMARKED})",
    f"DELETE FROM moz_places WHERE id NOT IN ({FF_BOOKMARKED}) AND id NOT IN (SELECT place_id FROM moz_keywords)",
    "UPDATE moz_places SET visit_count = 0, last_visit_date = NULL",
    "DELETE FROM moz_origins WHERE id NOT IN (SELECT origin_id FROM moz_places)",
]
FF_DOWNLOADS_SQL = ["DELETE FROM moz_annos WHERE anno_attribute_id IN "
                    "(SELECT id FROM moz_anno_attributes WHERE name LIKE 'downloads/%')"]


def _sql_count(db, sql):
    """브라우저가 켜져 있어도 안전하게 읽기 전용으로 개수 세기."""
    import sqlite3
    import urllib.request
    if not os.path.isfile(db):
        return None
    try:
        con = sqlite3.connect("file:" + urllib.request.pathname2url(db) + "?mode=ro&immutable=1", uri=True)
        try:
            return int(con.execute(sql).fetchone()[0])
        finally:
            con.close()
    except Exception:
        return None


def _chromium_profiles(base):
    if os.path.isfile(os.path.join(base, "Preferences")):  # Opera처럼 폴더 자체가 프로필
        return [base]
    return sorted(os.path.join(base, d) for d in listdir(base)
                  if d != "System Profile" and os.path.isfile(os.path.join(base, d, "Preferences")))


def priv_plan(kind, support):
    """{항목키: {"files": [...], "sql": {db: [문장...]}, "count": int|None}}"""
    plan = {k: {"files": [], "sql": {}, "count": None} for k, _ in PRIV_ITEMS}

    def add_count(k, n):
        if n is not None:
            plan[k]["count"] = (plan[k]["count"] or 0) + n

    def files(k, paths):
        plan[k]["files"] += [p for p in paths if os.path.lexists(p)]

    def sql(k, db, stmts, count_sql=None):
        if os.path.isfile(db):
            plan[k]["sql"].setdefault(db, []).extend(stmts)
            if count_sql:
                add_count(k, _sql_count(db, count_sql))

    asup = os.path.join(LIB, "Application Support")
    if kind == "safari":
        s = os.path.join(LIB, "Safari")
        sql("history", os.path.join(s, "History.db"),
            ["DELETE FROM history_visits", "DELETE FROM history_items", "DELETE FROM history_tombstones"],
            "SELECT COUNT(*) FROM history_visits")
        dl = os.path.join(s, "Downloads.plist")
        files("downloads", [dl])
        try:
            with open(dl, "rb") as f:
                add_count("downloads", len(plistlib.load(f).get("DownloadHistory", [])))
        except Exception:
            pass
        files("autofill", [os.path.join(s, "Form Values")])
        files("cookies", [os.path.join(LIB, "Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"),
                          os.path.join(LIB, "Cookies/Cookies.binarycookies")])
    elif kind == "chromium":
        for p in _chromium_profiles(os.path.join(asup, support)):
            hist = os.path.join(p, "History")
            sql("history", hist, CHROMIUM_HISTORY_SQL, "SELECT COUNT(*) FROM visits")
            files("history", [os.path.join(p, n) for n in
                              ("Visited Links", "Top Sites", "Top Sites-journal", "Shortcuts", "Shortcuts-journal",
                               "Network Action Predictor", "Network Action Predictor-journal")])
            sql("downloads", hist, CHROMIUM_DOWNLOADS_SQL, "SELECT COUNT(*) FROM downloads")
            sql("autofill", os.path.join(p, "Web Data"), ["DELETE FROM autofill"], "SELECT COUNT(*) FROM autofill")
            for c in (os.path.join(p, "Cookies"), os.path.join(p, "Network", "Cookies")):
                if os.path.isfile(c):
                    files("cookies", [c, c + "-journal"])
                    add_count("cookies", _sql_count(c, "SELECT COUNT(*) FROM cookies"))
    elif kind == "firefox":
        for p in sorted(glob.glob(os.path.join(asup, support, "*"))):
            places = os.path.join(p, "places.sqlite")
            sql("history", places, FF_HISTORY_SQL, "SELECT COUNT(*) FROM moz_historyvisits")
            sql("downloads", places, FF_DOWNLOADS_SQL,
                "SELECT COUNT(*) FROM moz_annos WHERE anno_attribute_id IN "
                "(SELECT id FROM moz_anno_attributes WHERE name = 'downloads/destinationFileURI')")
            fh = os.path.join(p, "formhistory.sqlite")
            if os.path.isfile(fh):
                files("autofill", [fh, fh + "-wal", fh + "-shm"])
                add_count("autofill", _sql_count(fh, "SELECT COUNT(*) FROM moz_formhistory"))
            ck = os.path.join(p, "cookies.sqlite")
            if os.path.isfile(ck):
                files("cookies", [ck, ck + "-wal", ck + "-shm"])
                add_count("cookies", _sql_count(ck, "SELECT COUNT(*) FROM moz_cookies"))
    return plan


def _no_access(kind):
    if kind != "safari":
        return False
    try:
        os.listdir(os.path.join(LIB, "Safari"))
        return False
    except FileNotFoundError:
        return False
    except OSError:
        return True


def privacy_list():
    out = []
    for name, bundle, proc, kind, support in PRIV_BROWSERS:
        if kind != "safari" and not os.path.isdir(os.path.join(LIB, "Application Support", support)):
            continue
        plan = priv_plan(kind, support)
        items = []
        for key, label in PRIV_ITEMS:
            pl = plan[key]
            paths = pl["files"] + list(pl["sql"].keys())
            items.append({"key": key, "label": label, "count": pl["count"],
                          "size": sum(size_of(p) for p in set(paths)), "available": bool(paths)})
        no_access = _no_access(kind)
        if not no_access and not any(i["available"] for i in items):
            continue
        out.append({"name": name, "bundle": bundle, "running": browser_running(proc),
                    "noAccess": no_access, "items": items})
    return out


def _password_guard(path):
    return any(m in path for m in PASSWORD_MARKERS)


def _run_sql(db, stmts):
    import sqlite3
    con = sqlite3.connect(db, timeout=5)
    try:
        for s in stmts:
            try:
                con.execute(s)
            except sqlite3.OperationalError as e:
                if "no such table" in str(e) or "no such column" in str(e):
                    continue  # 브라우저 버전마다 표가 달라서 없는 건 넘어감
                raise
        con.commit()
        for s in ("PRAGMA wal_checkpoint(TRUNCATE)", "VACUUM"):  # 지운 내용이 파일에 남지 않게
            try:
                con.execute(s)
            except sqlite3.Error:
                pass
    finally:
        con.close()


def privacy_clean(requests):
    """requests: [{"browser": "Chrome", "items": ["history", ...]}]  → 영구 삭제 (비밀번호 제외)"""
    by_name = {b[0]: b for b in PRIV_BROWSERS}
    valid = {k for k, _ in PRIV_ITEMS}
    results = []
    for req in requests:
        spec = by_name.get(req.get("browser"))
        keys = [k for k in req.get("items", []) if k in valid]
        if not spec or not keys:
            continue
        name, bundle, proc, kind, support = spec
        res = {"browser": name, "done": [], "errors": [], "skipped": None}
        if browser_running(proc):
            res["skipped"] = f"{name}가 실행 중이라 건너뛰었어요. 종료 후 다시 해주세요."
            results.append(res)
            continue
        plan = priv_plan(kind, support)
        dbs = {}
        for k in keys:
            for db, stmts in plan[k]["sql"].items():
                dbs.setdefault(db, []).extend(stmts)
        failed = set()
        for db, stmts in dbs.items():
            if _password_guard(db):
                continue
            try:
                _run_sql(db, stmts)
            except Exception as e:
                failed.update(k for k in keys if db in plan[k]["sql"])
                res["errors"].append(f"{os.path.basename(db)}: {e}")
        for k in keys:
            for p in plan[k]["files"]:
                if _password_guard(p) or not os.path.lexists(p):
                    continue
                try:
                    if os.path.isdir(p) and not os.path.islink(p):
                        shutil.rmtree(p)
                    else:
                        os.remove(p)
                except Exception as e:
                    failed.add(k)
                    res["errors"].append(f"{os.path.basename(p)}: {e.__class__.__name__}")
        res["done"] = [k for k in keys if k not in failed]
        results.append(res)
    return results


# ───────────────────────── 맥 앱 연동 (JSON) ─────────────────────────
def emit(obj):
    print(json.dumps(obj, ensure_ascii=False))


def json_mode(a):
    if a.json:
        def progress(i, n, name):
            print(f"PROGRESS\t{i}\t{n}\t{name}", file=sys.stderr, flush=True)
        items = collect(a, progress)
        emit({"items": [{"id": i, "cat": x["cat"], "label": x["label"], "note": x["note"],
                         "level": "safe" if x["level"] == SAFE else "check",
                         "size": x["size"], "paths": x["paths"]} for i, x in enumerate(items)],
              "trash": trash_size()})
    elif a.trash_paths:
        paths = json.load(sys.stdin)
        failed = [p for p in paths if not to_trash(p)]
        emit({"moved": len(paths) - len(failed), "failed": failed})
    elif a.apps_json:
        emit([{"name": os.path.basename(p)[:-4], "path": p, "bundle": bundle_id(p) or "",
               "size": size_of(p)} for p in user_apps()])
    elif a.app_info:
        bid, left, kept = app_leftovers(a.app_info)
        emit({"path": a.app_info, "bundle": bid, "size": size_of(a.app_info),
              "leftovers": [{"path": p, "size": size_of(p)} for p in left], "kept": kept})
    elif a.trash_info:
        emit({"trash": trash_size()})
    elif a.privacy_json:
        emit(privacy_list())
    elif a.privacy_clean:
        emit(privacy_clean(json.load(sys.stdin)))
    else:
        return False
    return True


def main():
    ap = argparse.ArgumentParser(description="나만 쓰는 맥 클리너")
    ap.add_argument("--scan-only", action="store_true", help="보기만 하고 아무것도 안 건드림")
    ap.add_argument("--uninstall", metavar="앱이름", help="앱과 남은 파일까지 완전 삭제")
    ap.add_argument("--empty-trash", action="store_true", help="휴지통 비우기 (영구 삭제)")
    ap.add_argument("--yes", action="store_true", help=argparse.SUPPRESS)
    ap.add_argument("--days", type=int, default=14, help="'오래된' 기준 일수 (기본 14)")
    ap.add_argument("--min-mb", type=int, default=20, help="개발 찌꺼기 최소 크기 MB (기본 20)")
    ap.add_argument("--big-mb", type=int, default=500, help="대용량 파일 기준 MB (기본 500)")
    ap.add_argument("--dupe-mb", type=int, default=10, help="중복 파일 검사 최소 크기 MB (기본 10)")
    ap.add_argument("--root", action="append", default=[], help="스캔 위치 추가")
    # 맥 앱이 쓰는 옵션
    for f in ("--json", "--trash-paths", "--apps-json", "--trash-info", "--privacy-json", "--privacy-clean"):
        ap.add_argument(f, action="store_true", help=argparse.SUPPRESS)
    ap.add_argument("--app-info", help=argparse.SUPPRESS)
    a = ap.parse_args()

    if json_mode(a):
        return
    if a.uninstall:
        return uninstall(a.uninstall)
    if a.empty_trash:
        ok = empty_trash(yes=a.yes)
        if a.yes:
            emit({"ok": ok})
        return

    print("🔍 스캔 중… (macOS가 폴더 접근 권한을 물어보면 허용해주세요)")
    items = collect(a, lambda i, n, name: print(f"   · {name}", flush=True))

    ts = trash_size()
    if not items:
        print("\n정리할 게 없어요 👍")
    else:
        cat = None
        for i, it in enumerate(items, 1):
            if it["cat"] != cat:
                cat = it["cat"]
                print(f"\n── {cat} " + "─" * max(4, 40 - len(cat) * 2))
            print(f"{i:>3}. {it['level']} {human(it['size']):>8}  {it['label']}")
            pad = " " * 16
            if it["note"]:
                print(f"{pad}└ {it['note']}")
            if it["show"]:
                for p in it["paths"][:3]:
                    print(f"{pad}  {short(p)}")
                if len(it["paths"]) > 3:
                    print(f"{pad}  … 외 {len(it['paths']) - 3}개")
        total = sum(x["size"] for x in items)
        safe = sum(x["size"] for x in items if x["level"] == SAFE)
        print(f"\n합계 {human(total)}  (그중 {SAFE} 안전한 항목 {human(safe)})")
        print(f"{SAFE} = 지워도 다시 생김   {CHECK}= 내용 확인 후 결정")
    if ts:
        print(f"🗑  휴지통에 {human(ts)} 있어요 → 비우려면: python3 {sys.argv[0]} --empty-trash")

    if a.scan_only or not items:
        return
    try:
        s = input("\n정리할 번호 (예: 1,3,5-7 / a = ✅ 전부 / 엔터 = 종료): ")
    except (EOFError, KeyboardInterrupt):
        print()
        return
    if not s.strip():
        return
    try:
        sel = parse_selection(s, len(items), items)
    except ValueError:
        print("번호를 이해하지 못했어요.")
        return
    if not sel:
        return

    chosen = [items[i] for i in sel]
    print()
    for it in chosen:
        print(f"  • {human(it['size']):>8}  {it['label']}")
    size = sum(x["size"] for x in chosen)
    if input(f"\n위 {len(chosen)}개 항목({human(size)})을 휴지통으로 옮길까요? [y/N]: ").strip().lower() != "y":
        print("취소했어요.")
        return
    moved, failed = 0, []
    for it in chosen:
        for p in it["paths"]:
            if to_trash(p):
                moved += 1
            else:
                failed.append(p)
    print(f"\n🗑  {moved}개를 휴지통으로 옮겼어요. 휴지통을 비우면 약 {human(size)}가 확보돼요.")
    print(f"   비우기: python3 {sys.argv[0]} --empty-trash")
    if failed:
        print(f"⚠️  {len(failed)}개는 옮기지 못했어요 (권한 문제일 수 있음):")
        for p in failed[:10]:
            print("   ", short(p))


if __name__ == "__main__":
    main()
