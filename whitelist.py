#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
whitelist.py — B 站白名单管理 CLI（M1：PC 端标记脚本 + Gist 同步）
================================================================

为「B 站白名单点播安卓 App」维护 whitelist.json：
  - add    解析 BV 号 → 调 view 接口抓取信息 → 追加进 whitelist.json
  - remove 从白名单删除（带确认）
  - list   表格打印白名单
  - serve  启动 HTTP 服务：GET /whitelist.json 供手机 App 拉取；
           POST /api/add 供油猴脚本一键加白（仅限本机，可自动 push）
  - push   把 whitelist.json 同步到 GitHub Gist（需 sync_config.json 配置 token）

接口事实来自 M0 侦察（probe.md，2026-08 实测）：
  - view 接口匿名可用：GET /x/web-interface/view?bvid=xxx
  - 请求带浏览器 UA + Referer（防盗链双必需，统一带上）
  - 请求间隔 >= 1s；-412 指数退避（1s→2s→4s）；-352 停止并报错
  - M1 实测补充：2026-08 起 view 匿名请求需带完整浏览器头
    （Sec-Ch-Ua / Sec-Fetch-* / Accept-Language / Origin 等），
    精简头（只带 UA+Referer）会被 -412；本脚本已内置完整头 + wbi 签名

whitelist.json 结构 v3（向前兼容 v2）：
  {"version": 3, "updated_at": "ISO时间",
   "collections": [{"name": "动画", "created_at": "ISO时间"}],   // 可空，含空合集
   "videos": [
      {"bvid","cid","title","cover","duration","up_name","added_at",
       "pages": [{"cid","part","duration"}, ...],
       "collection": "合集名"}          // 缺失/空 = 未分类
  ]}
  pages 存全部分 P（单 P 视频仅 1 项，等价旧数据）；cid/duration = 默认集
  （单 P 即唯一集，多 P 时 = 第 1 集或 --p 指定集）。旧 version=1 数据无 pages、
  version=2 数据无 collections/collection 字段：读取兼容不迁移（App 端把缺失
  pages 视作单 P、缺失 collection 视作未分类），新增条目 pages 必填、collection
  缺省 ""（未分类）。保存统一写 version=3（结构含 collections 字段）。
  videos 按 added_at 倒序（最新在前）；文件不存在时自动初始化 v3 空结构。
  合集一致性（collections 数组 <-> videos.collection 引用）由 rename/delete
  子命令保证；App 端管理 UI 也应遵守同样规则。

用法：
    python whitelist.py add BV1xxx [BV2yyy ...] [--p N] [--collection 合集名]
    python whitelist.py add https://www.bilibili.com/video/BV1xxx
    python whitelist.py remove BV1xxx [-y]
    python whitelist.py list
    python whitelist.py collection list
    python whitelist.py collection add <合集名>
    python whitelist.py collection rename <旧名> <新名>
    python whitelist.py collection delete <合集名>
    python whitelist.py serve [--port 8124] [--no-autopush]
    python whitelist.py push
"""

import argparse
import hashlib
import json
import os
import re
import socket
import sys
import time
import urllib.parse
from datetime import datetime, timezone

import requests  # 仅 push 子命令使用（GitHub Gist API）

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------

UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
)
API = "https://api.bilibili.com"
REFERER = "https://www.bilibili.com/"

# 数据文件与脚本同目录，保证从任何位置调用都操作同一个项目目录
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
WHITELIST_FILE = os.path.join(BASE_DIR, "whitelist.json")
CONFIG_FILE = os.path.join(BASE_DIR, "sync_config.json")
CONFIG_EXAMPLE_FILE = os.path.join(BASE_DIR, "sync_config.example.json")

BV_RE = re.compile(r"BV[0-9A-Za-z]{10}")
REQUEST_INTERVAL = 1.0  # 请求最小间隔（秒）

# B 站公开的 wbi mixinKey 置换表（算法与 probe.py 一致，自行实现）
MIXIN_KEY_ENC_TAB = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5,
    49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55,
    40, 61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57,
    62, 11, 36, 20, 34, 44, 52,
]

# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------


class BiliError(Exception):
    """业务错误，main 里统一捕获并友好提示。"""


# ---------------------------------------------------------------------------
# wbi 签名（2026-08 实测：view 匿名请求需带 wbi+dm 参数才能绕过 -412）
# ---------------------------------------------------------------------------


def get_mixin_key(orig: str) -> str:
    """从 img_key+sub_key 拼接串按置换表生成 32 位 mixinKey。"""
    return "".join(orig[i] for i in MIXIN_KEY_ENC_TAB[:32])


def get_key_from_url(url: str) -> str:
    """从 wbi_img 的 img_url/sub_url 提取 key（取文件名去扩展名）。"""
    return url.split("/")[-1].split(".")[0]


def encode_wbi(params: dict, img_key: str, sub_key: str,
               with_dm: bool = True) -> dict:
    """给参数字典附加 wbi 签名（wts + 排序 + urlencode + md5 -> w_rid）。

    with_dm=True 时额外附带 dm_img_list / dm_img_str / dm_cover_img_str，
    实测这组参数能绕过 B 站 2026-08 起对匿名 view 请求的 -412 风控。
    """
    mixin_key = get_mixin_key(img_key + sub_key)
    p = dict(params)
    p["wts"] = int(time.time())
    if with_dm:
        p["dm_img_list"] = "[]"
        p["dm_img_str"] = "V2ViR0wgMS4w"
        p["dm_cover_img_str"] = "QU5HTEU="
    # B 站要求去除参数值中的非法字符 !'()*
    cleaned = {k: re.sub(r"[!'()*]", "", str(v)) for k, v in p.items()}
    # 按 key 排序后 urlencode（与 M0 probe.py 实测通过的方式一致），
    # 再拼上 mixin_key 做 md5；参数编码方式必须与服务端一致，否则 -412
    query = urllib.parse.urlencode(sorted(cleaned.items()))
    p["w_rid"] = hashlib.md5((query + mixin_key).encode()).hexdigest()
    return p


def now_iso() -> str:
    """当前 UTC 时间的 ISO 8601 字符串（秒级）。"""
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def extract_bvid(text: str) -> str:
    """从任意输入（BV 号 / 含 bvid 参数的 URL / 含 BV 的短链文案）提取 BV 号。"""
    m = BV_RE.search(text)
    if not m:
        raise BiliError(f"无法从输入中解析出 BV 号: {text!r}")
    return m.group(0)


def fmt_duration(seconds) -> str:
    """把秒数格式化成 12:34 / 1:02:03。"""
    try:
        seconds = int(seconds)
    except (TypeError, ValueError):
        return "?"
    if seconds < 0:
        return "?"
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"


def fmt_added_at(iso_str: str) -> str:
    """把 ISO 时间转成本地时间显示 YYYY-MM-DD HH:MM，解析失败则原样返回。"""
    try:
        dt = datetime.fromisoformat(iso_str.replace("Z", "+00:00"))
        return dt.astimezone().strftime("%Y-%m-%d %H:%M")
    except (ValueError, AttributeError, TypeError):
        return str(iso_str)


def disp_width(s: str) -> int:
    """粗略计算终端显示宽度：中文/全角字符按 2 列算。"""
    return sum(2 if ord(c) > 0x2E80 else 1 for c in s)


def pad(s: str, width: int) -> str:
    """按显示宽度右补空格，保证表格列对齐。"""
    return s + " " * max(1, width - disp_width(s))


def cut(s: str, width: int) -> str:
    """按显示宽度截断，超长加 …。"""
    if disp_width(s) <= width:
        return s
    out, w = [], 0
    for c in s:
        cw = 2 if ord(c) > 0x2E80 else 1
        if w + cw > width - 1:
            break
        out.append(c)
        w += cw
    return "".join(out) + "…"


# ---------------------------------------------------------------------------
# whitelist.json 读写
# ---------------------------------------------------------------------------


def load_whitelist() -> dict:
    """读白名单；文件不存在时自动初始化 v3 空结构。

    兼容旧版数据（向前兼容 v2）：
      - version=1/2 的 videos 无 collection 字段 → 视为未分类（""）；
      - 顶层缺 collections 字段 → 视为空数组 []。
    两者都只做读入兼容、不迁移写入（避免无谓改盘），由 save 统一写 version=3。
    """
    if not os.path.exists(WHITELIST_FILE):
        return {
            "version": 3,
            "updated_at": now_iso(),
            "collections": [],
            "videos": [],
        }
    try:
        with open(WHITELIST_FILE, encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:  # noqa: BLE001
        raise BiliError(f"读取 {WHITELIST_FILE} 失败: {e}") from e
    if not isinstance(data, dict) or not isinstance(data.get("videos"), list):
        raise BiliError(f"{WHITELIST_FILE} 结构异常：缺少 videos 列表")
    # v2 数据没有 collections 字段 → 归一化为空数组（不写盘，save 时才落盘）
    if not isinstance(data.get("collections"), list):
        data["collections"] = []
    return data


def save_whitelist(data: dict) -> None:
    """写回白名单：统一 v3 结构、videos 按 added_at 倒序、更新 updated_at。"""
    data["version"] = 3
    data["updated_at"] = now_iso()
    if not isinstance(data.get("collections"), list):
        data["collections"] = []
    data["videos"].sort(key=lambda v: v.get("added_at", ""), reverse=True)
    with open(WHITELIST_FILE, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


def _ensure_collection(wl: dict, name: str) -> bool:
    """确保 collections 里存在名为 name 的合集（name 去空白后非空才处理）。

    已存在返回 False（不改动）；不存在则追加 {"name", "created_at"} 并返回 True。
    collections 里的 name 保持唯一（重名合集无意义，rename/delete 都按名匹配）。
    """
    name = (name or "").strip()
    if not name:
        return False
    existing = {(c.get("name") or "").strip() for c in wl.get("collections") or []}
    if name in existing:
        return False
    wl.setdefault("collections", []).append(
        {"name": name, "created_at": now_iso()}
    )
    return True


def _collection_names(wl: dict) -> list:
    """返回 collections 数组里的合集名列表（保持原顺序，去重）。"""
    seen = []
    for c in wl.get("collections") or []:
        name = (c.get("name") or "").strip()
        if name and name not in seen:
            seen.append(name)
    return seen


# 完整浏览器请求头：2026-08 实测 B 站风控按请求头指纹拦截，精简头
# （只带 UA+Referer）匿名请求会被 -412；补齐 Sec-Ch-Ua / Sec-Fetch-* /
# Accept-Language / Origin 后 requests 即可正常通过（对照实验确认）
FULL_HEADERS = {
    "User-Agent": UA,
    "Referer": REFERER,
    "Accept": (
        "text/html,application/xhtml+xml,application/xml;q=0.9,"
        "image/avif,image/webp,*/*;q=0.8"
    ),
    "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
    "Sec-Ch-Ua": '"Not/A)Brand";v="8", "Chromium";v="126", "Google Chrome";v="126"',
    "Sec-Ch-Ua-Mobile": "?0",
    "Sec-Ch-Ua-Platform": '"Windows"',
    "Sec-Fetch-Dest": "empty",
    "Sec-Fetch-Mode": "cors",
    "Sec-Fetch-Site": "same-site",
    "Origin": "https://www.bilibili.com",
}

# ---------------------------------------------------------------------------
# B 站 API 客户端（间隔控制 + -412 退避 + -352 熔断）
# ---------------------------------------------------------------------------


class BiliClient:
    """带节流、wbi 签名与风控处理的 B 站 API 客户端。

    - 用 requests + 完整浏览器头（2026-08 对照实验：精简头被 -412，
      完整头通过；wbi 签名保留作防未来收紧的储备，缺一不可时也能兜底）
    - 请求间隔 >= interval，遇 -412 指数退避重试，遇 -352 熔断
    """

    def __init__(self, interval: float = REQUEST_INTERVAL):
        self.interval = interval
        self._last_ts = 0.0
        self._wbi_keys = None  # (img_key, sub_key)，首次需要时从 nav 获取并缓存
        self._headers = dict(FULL_HEADERS)

    def _throttle(self):
        """保证与上一次请求的间隔 >= interval 秒。"""
        now = time.time()
        wait = self.interval - (now - self._last_ts)
        if wait > 0:
            time.sleep(wait)
        self._last_ts = time.time()

    def _get_json(self, path: str, params: dict | None = None):
        """GET 一个 JSON 接口，返回 (http_status, dict 或 None)。"""
        self._throttle()
        url = f"{API}{path}"
        try:
            resp = requests.get(url, params=params, headers=self._headers,
                                timeout=10)
        except requests.RequestException as e:
            raise BiliError(f"网络请求失败: {e}") from e
        http_status = resp.status_code
        try:
            return http_status, resp.json()
        except ValueError:
            return http_status, None

    def _ensure_wbi_keys(self) -> tuple:
        """从 nav 接口拿 wbi 签名 key（匿名可得，长期不变，会话内缓存）。"""
        if self._wbi_keys:
            return self._wbi_keys
        _, data = self._get_json("/x/web-interface/nav")
        wbi_img = {}
        if isinstance(data, dict):
            wbi_img = (data.get("data") or {}).get("wbi_img") or {}
        img_key = get_key_from_url(wbi_img.get("img_url", ""))
        sub_key = get_key_from_url(wbi_img.get("sub_url", ""))
        if not img_key or not sub_key:
            raise BiliError("nav 未返回 wbi_img，无法签名")
        self._wbi_keys = (img_key, sub_key)
        return self._wbi_keys

    def get_view(self, bvid: str) -> dict:
        """调 view 接口拿视频信息 data。

        - 完整浏览器头为主防 -412；wbi 签名 + dm 参数作附加储备
        - -412 指数退避重试（1s→2s→4s）
        - -352 立即停止并报错
        - code != 0（如 62002 稿件不可见）直接报错
        """
        img_key, sub_key = self._ensure_wbi_keys()
        params = encode_wbi({"bvid": bvid}, img_key, sub_key, with_dm=True)
        backoff = 1
        for attempt in range(4):
            status, data = self._get_json("/x/web-interface/view", params)
            if not isinstance(data, dict) or "code" not in data:
                raise BiliError(f"接口返回异常（HTTP {status}）: {data}")

            code = data.get("code")
            if code == -412:
                if attempt < 3:
                    print(f"  触发 -412 风控，{backoff}s 后重试（第 {attempt + 1} 次）")
                    time.sleep(backoff)
                    backoff *= 2
                    continue
                raise BiliError(f"多次重试仍被 -412 拦截（{bvid}），已放弃")
            if code == -352:
                raise BiliError("触发 -352 风控校验失败，已停止（请过一会儿再试）")
            if code != 0:
                raise BiliError(
                    f"接口返回错误 code={code} message={data.get('message')}（{bvid}）"
                )
            info = data.get("data") or {}
            if not info:
                raise BiliError(f"接口未返回数据（{bvid}）")
            return info
        raise BiliError(f"多次重试仍被 -412 拦截（{bvid}），已放弃")


# ---------------------------------------------------------------------------
# 子命令：add
# ---------------------------------------------------------------------------


def fetch_video_entry(bvid: str, client: BiliClient, part: int = 1,
                      collection: str = "") -> dict:
    """调 view 接口抓取视频元数据，构造一条白名单记录 dict。

    只负责抓取与构造，不检查是否已存在、不写盘。
    pages 字段存全部分 P（cid/part/duration）；cid/duration 字段取第 part 个 P
    （默认第 1 集）的值，保持原有 --p 语义。collection 记录所属合集名，
    缺省 ""（未分类）。供 cmd_add 与 serve 的 POST /api/add 复用。
    """
    if part < 1:
        raise BiliError(f"--p 必须 >= 1，收到 {part}")
    info = client.get_view(bvid)

    # 多 P 处理：view 返回 data.pages[]，每个 P 有独立 cid/part/duration；
    # part 指定 cid/duration 取哪个 P，pages 始终存全部 P
    pages = [p for p in (info.get("pages") or []) if p.get("cid")]
    if part > len(pages):
        raise BiliError(f"{bvid} 只有 {len(pages)} 个 P，无法取第 {part} 个 P")
    if pages:
        cid = pages[part - 1].get("cid")
        duration = pages[part - 1].get("duration") or 0
        entry_pages = [
            {"cid": p["cid"],
             "part": p.get("part") or "",
             "duration": p.get("duration") or 0}
            for p in pages
        ]
    else:
        # 异常兜底：view 未返回 pages（正常不会发生），按单 P 构造
        cid = info.get("cid") if part == 1 else None
        duration = info.get("duration") or 0
        entry_pages = [{"cid": cid, "part": info.get("title") or "", "duration": duration}]
    if not cid:
        raise BiliError(f"{bvid} 未取到 cid")

    owner = info.get("owner") or {}
    return {
        "bvid": bvid,
        "cid": cid,
        "title": info.get("title") or "",
        "cover": info.get("pic") or "",
        "duration": duration,
        "up_name": owner.get("name") or "",
        "added_at": now_iso(),
        "pages": entry_pages,
        "collection": collection,
    }


def add_video(bvid: str, client: BiliClient, part: int = 1,
              collection: str = "") -> tuple[bool, str, dict | None]:
    """添加单个视频到白名单并写盘，返回 (是否新增, 提示消息, 记录dict或None)。

    供 CLI add 与 serve 的 POST /api/add 复用：已存在时返回 (False, 提示, None)，
    不重复添加；新增成功则保存文件并返回新记录。collection 非空时若合集不存在
    自动创建（add --collection 自动建合集）。
    """
    collection = (collection or "").strip()
    wl = load_whitelist()
    existing = {v["bvid"] for v in wl["videos"]}
    if bvid in existing:
        return False, f"{bvid} 已在白名单中，不重复添加", None
    entry = fetch_video_entry(bvid, client, part=part, collection=collection)
    wl["videos"].append(entry)
    if collection:
        _ensure_collection(wl, collection)
    save_whitelist(wl)
    n_p = len(entry.get("pages") or [])
    np_str = f"，共 {n_p} 集" if n_p > 1 else ""
    return True, (
        f"已添加: {entry['title']}（UP: {entry['up_name']}，"
        f"时长 {fmt_duration(entry['duration'])}）{np_str}"
    ), entry


def cmd_add(args, client: BiliClient) -> int:
    bvids = [extract_bvid(x) for x in args.inputs]
    added = 0

    for bvid in bvids:
        ok, msg, entry = add_video(bvid, client, part=args.part,
                                   collection=args.collection)
        pn = ""
        if ok and entry and args.part > 1:
            pn = f"  P{args.part} cid={entry['cid']}"
        print(f"[{'✓ 已添加' if ok else '跳过'}] {msg}{pn}")
        if ok:
            added += 1

    if added:
        wl = load_whitelist()
        print(f"完成：本次新增 {added} 个视频，白名单共 {len(wl['videos'])} 个")
    return 0


# ---------------------------------------------------------------------------
# 子命令：remove
# ---------------------------------------------------------------------------


def cmd_remove(args) -> int:
    bvid = extract_bvid(args.bvid)
    wl = load_whitelist()
    idx = next((i for i, v in enumerate(wl["videos"]) if v["bvid"] == bvid), None)
    if idx is None:
        print(f"白名单中不存在 {bvid}")
        return 0
    v = wl["videos"][idx]
    if not args.yes:
        ans = input(f"确认删除《{v['title']}》（{bvid}）？[y/N] ").strip().lower()
        if ans not in ("y", "yes"):
            print("已取消")
            return 0
    del wl["videos"][idx]
    save_whitelist(wl)
    print(f"已删除 {bvid}（《{v['title']}》），剩余 {len(wl['videos'])} 个")
    return 0


# ---------------------------------------------------------------------------
# 子命令：list
# ---------------------------------------------------------------------------


def cmd_list(args) -> int:
    wl = load_whitelist()
    videos = wl["videos"]
    if not videos:
        print("白名单为空（用 add 添加视频）")
        return 0
    print(f"共 {len(videos)} 个视频（updated_at={wl.get('updated_at', '?')}）")
    headers = ["#", "BVID", "标题", "时长", "UP主", "加入时间"]
    widths = [4, 13, 30, 8, 20, 16]
    print("  " + "  ".join(pad(h, w) for h, w in zip(headers, widths)))
    print("  " + "  ".join("-" * w for w in widths))
    for i, v in enumerate(videos, 1):
        # 多 P 视频在标题后标注 [N集]（pages 缺失 = 旧数据/单 P，不标注）；
        # 有归属合集的标注 [合集名]（未分类不标注），与 [N集] 可同时出现
        tags = []
        n_p = len(v.get("pages") or [])
        if n_p > 1:
            tags.append(f"[{n_p}集]")
        coll = (v.get("collection") or "").strip()
        if coll:
            tags.append(f"[{coll}]")
        tag = (" " + " ".join(tags)) if tags else ""
        title = v.get("title", "?")
        title_cell = cut(title, widths[2] - disp_width(tag)) + tag if tag else cut(title, widths[2])
        row = [
            str(i),
            v.get("bvid", "?"),
            title_cell,
            fmt_duration(v.get("duration")),
            cut(v.get("up_name", "?"), widths[4]),
            fmt_added_at(v.get("added_at", "")),
        ]
        print("  " + "  ".join(pad(r, w) for r, w in zip(row, widths)))
    return 0


# ---------------------------------------------------------------------------
# 子命令：collection（合集管理）
# ---------------------------------------------------------------------------


def cmd_collection_list(args) -> int:
    """collection list：列出所有合集（名字 + 内含视频数）。"""
    wl = load_whitelist()
    names = _collection_names(wl)
    if not names:
        print("暂无合集（用 collection add <名> 或 add --collection <名> 创建）")
        return 0
    # 统计每个合集的视频数（videos.collection 引用的名字统计）
    counts: dict = {}
    for v in wl["videos"]:
        c = (v.get("collection") or "").strip()
        if c:
            counts[c] = counts.get(c, 0) + 1
    print(f"共 {len(names)} 个合集（version={wl.get('version')}）")
    headers = ["合集名", "视频数"]
    widths = [30, 8]
    print("  " + "  ".join(pad(h, w) for h, w in zip(headers, widths)))
    print("  " + "  ".join("-" * w for w in widths))
    for name in names:
        row = [cut(name, widths[0]), str(counts.get(name, 0))]
        print("  " + "  ".join(pad(r, w) for r, w in zip(row, widths)))
    return 0


def cmd_collection_add(args) -> int:
    """collection add <名>：新建合集（已存在提示，不报错）。"""
    wl = load_whitelist()
    name = (args.name or "").strip()
    if not name:
        raise BiliError("合集名不能为空")
    if _ensure_collection(wl, name):
        save_whitelist(wl)
        print(f"已创建合集「{name}」")
    else:
        print(f"合集「{name}」已存在，未改动")
    return 0


def cmd_collection_rename(args) -> int:
    """collection rename <旧名> <新名>：改 collections 数组 + 所有视频引用。"""
    wl = load_whitelist()
    old = (args.old or "").strip()
    new = (args.new or "").strip()
    if not old or not new:
        raise BiliError("旧名/新名都不能为空")
    if old == new:
        print("新旧名相同，未改动")
        return 0
    names = _collection_names(wl)
    if old not in names:
        raise BiliError(f"合集「{old}」不存在（现有合集: {', '.join(names) or '无'}）")
    if new in names:
        raise BiliError(f"新名「{new}」已存在（重命名会合并合集，请先处理）")

    # 1) 改 collections 数组里的名字
    for c in wl.get("collections") or []:
        if (c.get("name") or "").strip() == old:
            c["name"] = new
    # 2) 同步改 videos.collection 引用（一致性：App 端管理也遵守此规则）
    moved = 0
    for v in wl["videos"]:
        if (v.get("collection") or "").strip() == old:
            v["collection"] = new
            moved += 1
    save_whitelist(wl)
    print(f"已重命名合集「{old}」→「{new}」，同步更新 {moved} 个视频的引用")
    return 0


def cmd_collection_delete(args) -> int:
    """collection delete <名>：删合集定义 + 该合集下视频 collection 置空。"""
    wl = load_whitelist()
    name = (args.name or "").strip()
    if not name:
        raise BiliError("合集名不能为空")
    names = _collection_names(wl)
    if name not in names:
        raise BiliError(f"合集「{name}」不存在（现有合集: {', '.join(names) or '无'}）")

    before = len(wl.get("collections") or [])
    wl["collections"] = [c for c in wl.get("collections") or []
                         if (c.get("name") or "").strip() != name]
    moved = 0
    for v in wl["videos"]:
        if (v.get("collection") or "").strip() == name:
            v["collection"] = ""  # 置空 = 移回未分类
            moved += 1
    save_whitelist(wl)
    print(f"已删除合集「{name}」（collections {before}→{len(wl['collections'])} 个），"
          f"{moved} 个视频回到未分类")
    return 0


# ---------------------------------------------------------------------------
# 子命令：serve
# ---------------------------------------------------------------------------


def local_ip() -> str:
    """获取本机局域网 IPv4 地址（UDP connect 技巧，不实际发包）。"""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        if ip and not ip.startswith("127."):
            return ip
    except OSError:
        pass
    # 回退：枚举主机名解析出的 IPv4 地址
    try:
        ips = [a[4][0] for a in socket.getaddrinfo(socket.gethostname(), None)
               if a[0] == socket.AF_INET]
        ips = [ip for ip in ips if not ip.startswith("127.")]
        if ips:
            return ips[0]
    except OSError:
        pass
    return "127.0.0.1"


def cmd_serve(args) -> int:
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    port = args.port
    ip = local_ip()
    autopush = args.autopush
    # serve 期间复用同一个客户端：wbi key 缓存 + 请求节流都在实例内
    client = BiliClient(interval=REQUEST_INTERVAL)

    class Handler(BaseHTTPRequestHandler):
        """白名单 HTTP 服务。

        - GET  /whitelist.json  返回 whitelist.json（允许局域网访问，供手机 App 拉取）
        - POST /api/add         添加视频到白名单（仅允许 127.0.0.1 调用）
        """

        def _send_json(self, status: int, obj: dict) -> None:
            """统一返回 JSON：带 CORS 头 + no-store，中文用 ensure_ascii=False。"""
            body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            # CORS：油猴 GM_xmlhttpRequest 本身不受同源限制，但加上保险，
            # 用户改用 fetch 方式调用时不会被 CORS 卡住
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = self.path.split("?")[0].rstrip("/")
            if path == "/whitelist.json":
                try:
                    if os.path.exists(WHITELIST_FILE):
                        with open(WHITELIST_FILE, "rb") as f:
                            body = f.read()
                    else:
                        # 文件还不存在时返回初始化后的空结构，手机端总能拉到合法 JSON
                        body = json.dumps(load_whitelist(),
                                          ensure_ascii=False).encode("utf-8")
                except OSError as e:
                    self.send_response(500)
                    self.end_headers()
                    self.wfile.write(f"read error: {e}".encode("utf-8"))
                    return
                self.send_response(200)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)
            else:
                self.send_response(404)
                self.end_headers()
                self.wfile.write(b"404 Not Found")

        def do_POST(self):
            path = self.path.split("?")[0].rstrip("/")
            if path != "/api/add":
                self.send_response(404)
                self.end_headers()
                self.wfile.write(b"404 Not Found")
                return

            # 安全约束：POST /api/add 只允许回环地址调用，
            # 防止局域网内其他设备往白名单里写数据
            if self.client_address[0] not in ("127.0.0.1", "::1"):
                self._send_json(403, {"ok": False, "msg": "仅允许本机(127.0.0.1)调用此接口"})
                print(f"  [serve] 拒绝非回环来源 {self.client_address[0]} 的 /api/add")
                return

            # 提取 bvid：支持查询参数 ?bvid=BVxxx，也支持 JSON body {"bvid": "BVxxx"}
            bvid = None
            qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            if qs.get("bvid"):
                bvid = qs["bvid"][0].strip()
            else:
                try:
                    length = int(self.headers.get("Content-Length") or 0)
                    if length > 0:
                        raw = self.rfile.read(length)
                        payload = json.loads(raw.decode("utf-8"))
                        bvid = str(payload.get("bvid") or "").strip()
                except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
                    bvid = None

            if not bvid:
                self._send_json(400, {"ok": False, "msg": "缺少 bvid 参数"})
                return

            # 复用 CLI add 的同一套逻辑（调 view 抓元数据 → 写 whitelist.json）
            try:
                bvid = extract_bvid(bvid)
                ok, msg, _entry = add_video(bvid, client, part=1)
            except BiliError as e:
                self._send_json(200, {"ok": False, "msg": str(e)})
                print(f"  [serve] POST /api/add bvid={bvid} fail: {e}")
                return

            print(f"  [serve] POST /api/add bvid={bvid} {'ok' if ok else 'dup'}")
            self._send_json(200, {"ok": ok, "msg": msg})

            # 新增成功且开启 autopush 时，自动把最新 whitelist.json 同步到 Gist
            if ok and autopush:
                print("  [serve] 触发自动 push（--no-autopush 可关闭）...")
                cmd_push(None)

        def log_message(self, fmt, *args):  # 精简访问日志
            print(f"  [serve] {self.client_address[0]} {fmt % args}")

    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print("白名单服务已启动（GET 局域网可读；POST /api/add 仅限本机）")
    print(f"  本机:       http://127.0.0.1:{port}/whitelist.json")
    print(f"  局域网:     http://{ip}:{port}/whitelist.json  （手机连同一 Wi-Fi 访问）")
    print(f"  加白接口:   POST http://127.0.0.1:{port}/api/add")
    print(f"  油猴脚本需连接 http://127.0.0.1:{port}")
    print(f"  自动push:   {'开启' if autopush else '关闭'}")
    print("  Ctrl+C 停止")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止")
    return 0


# ---------------------------------------------------------------------------
# 子命令：push（同步到 GitHub Gist）
# ---------------------------------------------------------------------------


def cmd_push(args) -> int:
    if not os.path.exists(CONFIG_FILE):
        print(f"未找到 {CONFIG_FILE}，跳过 push（可参考 {CONFIG_EXAMPLE_FILE} 配置）")
        return 0
    try:
        with open(CONFIG_FILE, encoding="utf-8") as f:
            cfg = json.load(f)
    except Exception as e:  # noqa: BLE001
        print(f"读取 {CONFIG_FILE} 失败: {e}，跳过 push")
        return 1

    token = (cfg.get("github_token") or "").strip()
    gist_id = (cfg.get("gist_id") or "").strip()
    if not token:
        print(
            f"{CONFIG_FILE} 中未配置 github_token，跳过 push"
            "（不影响 add/list/remove/serve）"
        )
        return 0

    if not os.path.exists(WHITELIST_FILE):
        print(f"{WHITELIST_FILE} 不存在，跳过 push")
        return 1
    with open(WHITELIST_FILE, encoding="utf-8") as f:
        content = f.read()

    headers = {
        "Authorization": f"token {token}",
        "Accept": "application/vnd.github+json",
    }
    if gist_id:
        url = f"https://api.github.com/gists/{gist_id}"
        payload = {"files": {"whitelist.json": {"content": content}}}
        method = "PATCH"
        desc = f"更新已有 Gist {gist_id}"
    else:
        url = "https://api.github.com/gists"
        payload = {
            "description": "B站白名单视频（bili-whitelist）",
            "public": False,
            "files": {"whitelist.json": {"content": content}},
        }
        method = "POST"
        desc = "创建新 Gist"

    print(f"[push] {desc} ...")
    try:
        resp = requests.request(method, url, json=payload, headers=headers, timeout=15)
    except requests.RequestException as e:
        print(f"push 网络请求失败: {e}")
        return 1

    if resp.status_code >= 400:
        print(f"push 失败: HTTP {resp.status_code}")
        try:
            msg = resp.json().get("message")
        except ValueError:
            msg = None
        print(f"  服务端信息: {msg or resp.text[:200]}")
        return 1

    data = resp.json()
    new_id = data.get("id")
    if not gist_id and new_id:
        cfg["gist_id"] = new_id
        with open(CONFIG_FILE, "w", encoding="utf-8") as f:
            json.dump(cfg, f, ensure_ascii=False, indent=2)
        print(f"  已把 gist_id 写回 {CONFIG_FILE}")
    print(f"push 成功 → https://gist.github.com/{new_id}")
    return 0


# ---------------------------------------------------------------------------
# 主入口
# ---------------------------------------------------------------------------


def main() -> int:
    # Windows 下 stdout 可能不是 UTF-8（中文 locale 重定向时为 GBK），
    # 统一重配置为 UTF-8，保证中文和 ✓ 等符号正常输出且不崩溃
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

    ap = argparse.ArgumentParser(
        prog="whitelist.py",
        description="B 站白名单管理：add / remove / list / serve / push",
    )
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_add = sub.add_parser("add", help="添加视频（BV号或视频URL，可多个）")
    p_add.add_argument("inputs", nargs="+", help="BV号或含BV的视频URL，可多个")
    p_add.add_argument("--p", type=int, default=1, dest="part",
                       help="多P视频取第几个P的cid（默认1）")
    p_add.add_argument("--collection", default="",
                       help="归属合集名（不存在自动创建；默认空=未分类）")
    p_add.set_defaults(func=cmd_add)

    p_rm = sub.add_parser("remove", help="从白名单删除")
    p_rm.add_argument("bvid", help="要删除的视频BV号或URL")
    p_rm.add_argument("-y", "--yes", action="store_true", help="不询问直接删除")
    p_rm.set_defaults(func=cmd_remove)

    p_ls = sub.add_parser("list", help="表格打印白名单")
    p_ls.set_defaults(func=cmd_list)

    # collection 子命令：list / add / rename / delete（合集管理，App 端同步参考）
    p_coll = sub.add_parser("collection", help="合集管理：list/add/rename/delete")
    coll_sub = p_coll.add_subparsers(dest="coll_cmd", required=True)
    p_cl = coll_sub.add_parser("list", help="列出所有合集（名字+视频数）")
    p_cl.set_defaults(func=cmd_collection_list)
    p_ca = coll_sub.add_parser("add", help="新建合集（已存在提示）")
    p_ca.add_argument("name", help="合集名")
    p_ca.set_defaults(func=cmd_collection_add)
    p_cr = coll_sub.add_parser("rename", help="重命名合集（同步更新视频引用）")
    p_cr.add_argument("old", metavar="旧名", help="原合集名")
    p_cr.add_argument("new", metavar="新名", help="新合集名")
    p_cr.set_defaults(func=cmd_collection_rename)
    p_cd = coll_sub.add_parser("delete", help="删除合集（视频回到未分类）")
    p_cd.add_argument("name", help="要删除的合集名")
    p_cd.set_defaults(func=cmd_collection_delete)

    p_ser = sub.add_parser("serve", help="启动HTTP服务：GET /whitelist.json + POST /api/add")
    p_ser.add_argument("--port", type=int, default=8124,
                       help="监听端口（默认8124，8123被遗留进程占用）")
    p_ser.add_argument("--autopush", dest="autopush", action="store_true",
                       default=True,
                       help="POST /api/add 成功后自动 push 到 Gist（默认开启）")
    p_ser.add_argument("--no-autopush", dest="autopush", action="store_false",
                       help="关闭自动 push（配合 --autopush 使用）")
    p_ser.set_defaults(func=cmd_serve)

    p_push = sub.add_parser("push", help="同步whitelist.json到GitHub Gist")
    p_push.set_defaults(func=cmd_push)

    args = ap.parse_args()

    try:
        if args.cmd == "add":
            return args.func(args, BiliClient(interval=REQUEST_INTERVAL))
        return args.func(args)
    except BiliError as e:
        print(f"错误: {e}")
        return 1
    except KeyboardInterrupt:
        print("\n已中断")
        return 130


if __name__ == "__main__":
    sys.exit(main())
