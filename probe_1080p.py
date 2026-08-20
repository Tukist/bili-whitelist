#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
probe_1080p.py — 登录态 1080P mp4 单流实测（M1 补充）
=====================================================

背景
----
为「B 站白名单点播安卓 App」判定播放器路线：
  - 路线 C：登录后 playurl(fnval=0, qn=80) 能直接返回 1080P mp4(durl)
            → 可用 Flutter video_player 单流播放（最简）
  - 路线 A：1080P 只能走 DASH 双流 → 需要原生通道

实测内容
--------
对 5 个视频（4 个来自 whitelist.json + 1 个自选热门）请求
  https://api.bilibili.com/x/player/wbi/playurl?bvid=&cid=&qn=80&fnval=0&fnver=0&fourk=1
请求头 = 完整浏览器头(FULL_HEADERS) + Cookie: <整串>
逐个记录：
  - data.quality / data.accept_quality
  - data.durl 是否非空、条数
  - data.support_formats 里 quality=80 是否存在
  - durl[0].url 是否可访问（带 Referer 读前 1KB 验证 200）
请求间隔 >= 1.5s；遇 -412 停止；-352 / -101（cookie 失效）也记录并停止。

安全纪律
--------
- 全程不回显 cookie，只输出"cookie 已配置"
- cookie 从同目录 cookie.txt 读取

用法
----
    python probe_1080p.py [--out probe_1080p_out.json] [--interval 1.5]

结果
----
- JSON 结果写入 --out 指定文件（默认 probe_1080p_out.json）
- 控制台打印可读摘要
"""

import argparse
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
COOKIE_FILE = os.path.join(BASE_DIR, "cookie.txt")
WHITELIST_FILE = os.path.join(BASE_DIR, "whitelist.json")

UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
)
API = "https://api.bilibili.com"
REFERER = "https://www.bilibili.com/"

# 完整浏览器头（取自 whitelist.py 的 FULL_HEADERS，保持一致性）
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

# 自选第 5 个视频候选（不同 UP 主、不同年代；view 逐个验证，取第一个 code=0）
#   BV1xW411J7tu 只有骨头EF《旭旭宝宝-九日梦想秀-特别篇》(2017) — M0 已验证 code=0
#   BV1Es411v7Vr 《千本樱》(2012) — VOCALOID 经典，存在 14 年
EXTRA_BVIDS = [
    "BV1xW411J7tu",
    "BV1Es411v7Vr",
]

# B 站公开的 mixinKey 置换表（与 probe.py 一致）
MIXIN_KEY_ENC_TAB = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5,
    49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55,
    40, 61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57,
    62, 11, 36, 20, 34, 44, 52,
]

STOP_CODES = (-412, -352, -101)  # -412 拦截 / -352 风控 / -101 cookie 失效


# ---------------------------------------------------------------------------
# WBI 签名（与 probe.py 相同实现）
# ---------------------------------------------------------------------------


def get_mixin_key(orig: str) -> str:
    """从 img_key+sub_key 拼接串按置换表生成 32 位 mixinKey。"""
    return "".join(orig[i] for i in MIXIN_KEY_ENC_TAB[:32])


def get_key_from_url(url: str) -> str:
    """从 wbi_img 的 img_url/sub_url 提取 key（取文件名去扩展名）。"""
    return url.split("/")[-1].split(".")[0]


def encode_wbi(params: dict, img_key: str, sub_key: str,
               with_dm: bool = False) -> dict:
    """给参数字典附加 wbi 签名（wts + 排序 + urlencode + md5 -> w_rid）。

    with_dm=True 时额外附带 dm_img_list / dm_img_str / dm_cover_img_str，
    为对抗风控的可选参数。
    """
    mixin_key = get_mixin_key(img_key + sub_key)
    p = dict(params)
    p["wts"] = int(time.time())
    if with_dm:
        p["dm_img_list"] = "[]"
        p["dm_img_str"] = "V2ViR0wgMS4w"
        p["dm_cover_img_str"] = "QU5HTEU="
    cleaned = {k: re.sub(r"[!'()*]", "", str(v)) for k, v in p.items()}
    query = urllib.parse.urlencode(sorted(cleaned.items()))
    p["w_rid"] = hashlib.md5((query + mixin_key).encode()).hexdigest()
    return p


# ---------------------------------------------------------------------------
# 请求工具（带 cookie、请求间隔、停止控制）
# ---------------------------------------------------------------------------


class HttpClient:
    """带 cookie + 间隔控制 + 停止控制的 urllib 封装。"""

    def __init__(self, cookie: str, interval: float = 1.5):
        self.cookie = cookie
        self.interval = interval
        self._last_ts = 0.0
        self.total_requests = 0
        self.stopped = False
        self.stop_reason = None

    def _throttle(self):
        """保证与上一次请求的间隔 >= interval 秒。"""
        now = time.time()
        wait = self.interval - (now - self._last_ts)
        if wait > 0:
            time.sleep(wait)
        self._last_ts = time.time()

    def _headers(self, extra: dict | None = None) -> dict:
        headers = dict(FULL_HEADERS)
        headers["Cookie"] = self.cookie
        if extra:
            headers.update(extra)
        return headers

    def _maybe_stop(self, data):
        """检查 API code，命中停止码则记录并置 stopped。"""
        if not isinstance(data, dict):
            return
        code = data.get("code")
        if code in STOP_CODES:
            self.stopped = True
            self.stop_reason = {"code": code, "message": data.get("message")}

    def get_json(self, url: str, params: dict | None = None,
                 referer: str = REFERER, timeout: float = 10.0):
        """GET 一个 JSON 接口，返回 (http_status, dict 或 None)。"""
        self._throttle()
        self.total_requests += 1
        if params:
            url = url + "?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(url, headers=self._headers(),
                                     method="GET")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                body = resp.read()
                http_status = resp.status
        except urllib.error.HTTPError as e:
            http_status = e.code
            body = e.read()
        except Exception as e:  # noqa: BLE001
            return "EXC:" + type(e).__name__, str(e)
        try:
            data = json.loads(body.decode("utf-8"))
        except Exception:
            data = None
        self._maybe_stop(data)
        return http_status, data

    def get_bytes(self, url: str, timeout: float = 10.0):
        """GET 一个非 JSON 资源（流 URL），只读取前 1KB 即断开。

        返回 (http_status, 实际读取字节数)。"""
        self._throttle()
        self.total_requests += 1
        req = urllib.request.Request(url, headers=self._headers(),
                                     method="GET")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                status = resp.status
                n = len(resp.read(1024))
        except urllib.error.HTTPError as e:
            status = e.code
            n = 0
        except Exception as e:  # noqa: BLE001
            return "EXC:" + type(e).__name__, str(e)
        return status, n


# ---------------------------------------------------------------------------
# 探针函数
# ---------------------------------------------------------------------------


def load_cookie() -> str:
    """从 cookie.txt 读取完整 cookie 串。"""
    with open(COOKIE_FILE, encoding="utf-8") as f:
        return f.read().strip()


def load_whitelist() -> list[dict]:
    """读 whitelist.json 的 videos 列表。"""
    with open(WHITELIST_FILE, encoding="utf-8") as f:
        data = json.load(f)
    return data.get("videos", [])


def probe_view(http: HttpClient, bvid: str) -> dict:
    """view 接口取视频信息（自选视频需要 cid）。"""
    status, data = http.get_json(f"{API}/x/web-interface/view",
                                 {"bvid": bvid})
    rec = {"bvid": bvid, "http_status": status, "code": None,
           "cid": None, "title": None, "up": None, "message": None}
    if isinstance(data, dict):
        rec["code"] = data.get("code")
        rec["message"] = data.get("message")
        d = data.get("data") or {}
        rec["cid"] = d.get("cid")
        rec["title"] = d.get("title")
        owner = d.get("owner") or {}
        rec["up"] = owner.get("name")
    return rec


def probe_nav_wbi(http: HttpClient) -> dict:
    """nav 接口拿 wbi_img（带 cookie 登录态），返回 img_key/sub_key。"""
    rec = {"http_status": None, "code": None, "img_key": None,
           "sub_key": None, "mixin_key": None, "login": None, "message": None}
    status, data = http.get_json(f"{API}/x/web-interface/nav")
    rec["http_status"] = status
    if isinstance(data, dict):
        rec["code"] = data.get("code")
        rec["message"] = data.get("message")
        d = data.get("data") or {}
        if isinstance(d, dict):
            rec["login"] = d.get("isLogin")
            wbi_img = d.get("wbi_img") or {}
            img_key = get_key_from_url(wbi_img.get("img_url", ""))
            sub_key = get_key_from_url(wbi_img.get("sub_url", ""))
            rec["img_key"] = img_key
            rec["sub_key"] = sub_key
            if img_key and sub_key:
                rec["mixin_key"] = get_mixin_key(img_key + sub_key)
    return rec


def probe_playurl_wbi(http: HttpClient, bvid: str, cid: int,
                      img_key: str, sub_key: str) -> tuple[dict, str | None]:
    """wbi playurl：qn=80 & fnval=0 & fnver=0 & fourk=1（mp4 单流探测）。

    返回 (记录, 第一条 durl 完整 URL 或 None)。
    记录里不含任何 cookie / 完整 URL，流 URL 只保留 host 前缀；
    完整 URL 仅保存在内存中供流可访问性验证用，不写入 JSON。
    """
    base = {"bvid": bvid, "cid": cid, "qn": 80, "fnval": 0, "fnver": 0,
            "fourk": 1}
    params = encode_wbi(base, img_key, sub_key, with_dm=False)
    status, data = http.get_json(f"{API}/x/player/wbi/playurl", params)
    rec = {"bvid": bvid, "cid": cid, "http_status": status, "code": None,
           "message": None, "quality": None, "accept_quality": None,
           "durl_count": 0, "durl_first_url_host": None,
           "support_q80": False, "support_formats": [],
           "dash_present": False}
    first_url = None
    if isinstance(data, dict):
        rec["code"] = data.get("code")
        rec["message"] = data.get("message")
        d = data.get("data") or {}
        rec["quality"] = d.get("quality")
        rec["accept_quality"] = d.get("accept_quality")
        durl = d.get("durl") or []
        rec["durl_count"] = len(durl)
        if durl:
            u = durl[0].get("url") or ""
            first_url = u
            # 只记 host 前缀，不落完整流 URL（避免长 URL 噪音）
            try:
                rec["durl_first_url_host"] = urllib.parse.urlsplit(u).netloc
            except Exception:
                rec["durl_first_url_host"] = None
        sfs = d.get("support_formats") or []
        rec["support_formats"] = [
            {"quality": sf.get("quality"), "format": sf.get("format"),
             "desc": sf.get("new_description")}
            for sf in sfs
        ]
        rec["support_q80"] = any(sf.get("quality") == 80 for sf in sfs)
        rec["dash_present"] = isinstance(d.get("dash"), dict)
    return rec, first_url


def probe_stream(http: HttpClient, url: str) -> dict:
    """验证流 URL 可访问性：带 Referer 读前 1KB。"""
    status, n = http.get_bytes(url)
    return {"status": status, "bytes_read": n,
            "reachable": status == 200 and n > 0}


def probe_dash_qn80(http: HttpClient, bvid: str, cid: int,
                    img_key: str, sub_key: str) -> dict:
    """对照实验：fnval=16 & qn=80（DASH）登录态探测。

    用于区分「1080P 只能走 DASH」还是「该视频/账号根本不提供 1080P」。
    """
    base = {"bvid": bvid, "cid": cid, "qn": 80, "fnval": 16, "fnver": 0,
            "fourk": 1}
    params = encode_wbi(base, img_key, sub_key, with_dm=False)
    status, data = http.get_json(f"{API}/x/player/wbi/playurl", params)
    rec = {"bvid": bvid, "http_status": status, "code": None,
           "message": None, "quality": None, "dash_video_ids": [],
           "dash_has_q80": False, "dash_video_count": 0}
    if isinstance(data, dict):
        rec["code"] = data.get("code")
        rec["message"] = data.get("message")
        d = data.get("data") or {}
        rec["quality"] = d.get("quality")
        dash = d.get("dash")
        if isinstance(dash, dict):
            videos = dash.get("video") or []
            rec["dash_video_count"] = len(videos)
            ids = sorted({v.get("id") for v in videos})
            rec["dash_video_ids"] = ids
            rec["dash_has_q80"] = 80 in ids
    return rec


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------


def main():
    ap = argparse.ArgumentParser(description="登录态 1080P mp4 单流实测（M1）")
    ap.add_argument("--out", default="probe_1080p_out.json",
                    help="JSON 结果输出文件")
    ap.add_argument("--interval", type=float, default=1.5,
                    help="请求间隔秒数（默认 1.5）")
    args = ap.parse_args()

    # cookie 读取（不回显内容）
    if not os.path.exists(COOKIE_FILE):
        print("!! cookie.txt 不存在，请先配置 cookie")
        sys.exit(1)
    cookie = load_cookie()
    if not cookie:
        print("!! cookie.txt 为空")
        sys.exit(1)
    print("cookie 已配置")

    http = HttpClient(cookie=cookie, interval=args.interval)
    out = {
        "meta": {
            "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
            "interval": args.interval,
            "targets": "qn=80&fnval=0&fnver=0&fourk=1 (mp4 单流)",
        },
        "cookie": "configured",  # 只标记已配置，绝不落内容
        "videos": [],
        "playurl": [],
        "streams": [],
        "stop_reason": None,
        "total_requests": 0,
    }

    # 1) 收集视频列表
    print("\n[1/4] 收集视频列表")
    targets = []
    for v in load_whitelist():
        targets.append({
            "bvid": v.get("bvid"), "cid": v.get("cid"),
            "title": v.get("title"), "up": v.get("up_name"),
        })
    print(f"  whitelist.json 内视频 {len(targets)} 个")

    # 第 5 个：候选列表逐个 view 验证，取第一个 code=0（仅探测，不入库）
    extra = None
    for cand in EXTRA_BVIDS:
        print(f"  候选 view: {cand}")
        vrec = probe_view(http, cand)
        out["videos"].append(vrec)
        if vrec["code"] == 0:
            print(f"  OK {cand} title={vrec['title']!r} cid={vrec['cid']} "
                  f"up={vrec['up']!r}")
            extra = vrec
            break
        print(f"  SKIP {cand} code={vrec['code']} http={vrec['http_status']} "
              f"msg={vrec['message']}")
        if http.stopped:
            break
    if extra is None:
        print("!! 候选全部不可用，仅测 whitelist 内 4 个")
    else:
        targets.append({
            "bvid": extra["bvid"], "cid": extra["cid"],
            "title": extra["title"], "up": extra["up"],
        })
    print(f"  共 {len(targets)} 个目标视频")

    # 2) nav 拿 wbi key（登录态）
    print("\n[2/4] nav 获取 wbi key（登录态）")
    wbi = probe_nav_wbi(http)
    print(f"  nav http={wbi['http_status']} code={wbi['code']} "
          f"isLogin={wbi['login']} mixin_key={wbi['mixin_key']}")
    if not wbi["mixin_key"]:
        print("!! 拿不到 wbi key，终止")
        out["total_requests"] = http.total_requests
        out["stop_reason"] = http.stop_reason
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(out, f, ensure_ascii=False, indent=2)
        sys.exit(1)

    # 3) 逐个视频 wbi playurl（qn=80, fnval=0）
    print("\n[3/4] wbi playurl 逐视频探测（qn=80 & fnval=0 mp4 单流）")
    playurls = []
    durl_urls = {}  # bvid -> 第一条 durl 完整 URL（仅内存，不入 JSON）
    for t in targets:
        rec, first_url = probe_playurl_wbi(http, t["bvid"], t["cid"],
                                           wbi["img_key"], wbi["sub_key"])
        rec["title"] = t["title"]
        rec["up"] = t["up"]
        playurls.append(rec)
        if first_url:
            durl_urls[t["bvid"]] = first_url
        durl_mark = "有" if rec["durl_count"] > 0 else "无"
        print(f"  {t['bvid']} [{t['up']}] code={rec['code']} "
              f"http={rec['http_status']} quality={rec['quality']} "
              f"durl={rec['durl_count']}({durl_mark}) "
              f"support_q80={rec['support_q80']} dash={rec['dash_present']} "
              f"msg={rec['message']}")
        if http.stopped:
            print(f"  !! 触发停止码 {http.stop_reason}，停止后续探测")
            break

    # 4) 对返回了 durl 的视频验证流 URL 可访问性
    print("\n[4/4] 流 URL 可访问性验证（带 Referer 读前 1KB）")
    streams = []
    for rec in playurls:
        if rec.get("code") != 0:
            streams.append({"bvid": rec["bvid"], "skipped": True,
                            "reason": f"code={rec['code']}"})
            continue
        if rec["durl_count"] == 0:
            streams.append({"bvid": rec["bvid"], "skipped": True,
                            "reason": "no durl"})
            continue
        url = durl_urls.get(rec["bvid"])
        if url is None:
            streams.append({"bvid": rec["bvid"], "skipped": True,
                            "reason": "cannot resolve durl url"})
            continue
        sr = probe_stream(http, url)
        sr["bvid"] = rec["bvid"]
        streams.append(sr)
        print(f"  {rec['bvid']} stream status={sr['status']} "
              f"bytes={sr['bytes_read']} reachable={sr['reachable']}")
        if http.stopped:
            print(f"  !! 触发停止码 {http.stop_reason}，停止")
            break

    out["playurl"] = playurls
    out["streams"] = streams

    # 5) 对照实验：mp4 单流拿不到 80 的视频，用 DASH(fnval=16) 再看一次
    print("\n[5/4] DASH 对照：mp4 未给 1080P 的视频用 fnval=16 复测")
    dash_checks = []
    for rec in playurls:
        if rec.get("code") != 0 or rec.get("quality", 0) >= 80:
            continue
        dc = probe_dash_qn80(http, rec["bvid"], rec["cid"],
                             wbi["img_key"], wbi["sub_key"])
        dc["title"] = rec["title"]
        dc["up"] = rec["up"]
        dash_checks.append(dc)
        print(f"  {rec['bvid']} [{rec['up']}] DASH code={dc['code']} "
              f"quality={dc['quality']} video_ids={dc['dash_video_ids']} "
              f"has_q80={dc['dash_has_q80']}")
        if http.stopped:
            print(f"  !! 触发停止码 {http.stop_reason}，停止")
            break
    out["dash_checks"] = dash_checks

    out["stop_reason"] = http.stop_reason
    out["total_requests"] = http.total_requests
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)

    print(f"\n== 完成 == 总请求 {http.total_requests} 次，"
          f"停止: {http.stop_reason}")
    print(f"JSON 已写入: {args.out}")


if __name__ == "__main__":
    main()
