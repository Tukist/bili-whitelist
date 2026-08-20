#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
probe.py — B 站 API 技术侦察探针脚本（M0 阶段）
================================================

用途
----
为「B 站白名单点播安卓 App」做技术侦察，实测 B 站 API 的真实行为：
  1. 视频信息接口 view：匿名能否拿到 cid/title/pic/duration/owner.name
  2. 播放流接口 playurl：匿名下 mp4(durl) 最高清晰度、DASH 结构、qn=127 实际给什么
  3. 防盗链：mp4 流 URL 对 Referer / User-Agent 的依赖
  4. WBI 签名：nav 拿 key → 置换表生成 mixinKey → wts + 排序 + urlencode + md5，
     验证带签名与不带签名的差异，确认 view/playurl 是否强制 wbi
  5. 风控观察：连续 5 次 playurl 请求，观察 -352/-412

注意事项
--------
- 请求间隔默认 >= 1.5s（--interval 可覆盖）
- 遇到 -352 / -412 立即停止本阶段并记录，不硬闯
- 纯标准库 urllib，无第三方依赖；个人自用，请克制使用

用法
----
    python probe.py                          # 全流程，使用内置候选 BV
    python probe.py --bvid BV1xxx,BV2yyy     # 用指定 BV 列表（逗号分隔，可重复）
    python probe.py --interval 2.0           # 覆盖请求间隔
    python probe.py --out probe_out.json     # 指定 JSON 结果输出文件
    python probe.py --video-only             # 只跑视频验证，跳过播放流/防盗链
    python probe.py --no-risk                # 跳过风控连测

结果
----
- 全部实测结果写入 --out 指定的 JSON 文件（默认 probe_out.json）
- 控制台同时打印可读摘要，便于人工核对
"""

import argparse
import hashlib
import json
import re
import ssl
import sys
import time
import urllib.parse
import urllib.request

# ---------------------------------------------------------------------------
# 常量
# ---------------------------------------------------------------------------

UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
)

API = "https://api.bilibili.com"

# 候选视频：挑选理由（存在多年、头部 UP 主、不易删稿）
# 脚本会自动逐个验证，取前 N 个有效的继续后续测试
CANDIDATE_BVIDS = [
    "BV1xx411c7mD",  # 【东方】Bad Apple!! 影绘 (2009) — B 站镇站之宝，存在 15+ 年
    "BV1JE411e7WG",  # 何同学《5G 有多快》(2019) — 头部 UP 主何同学，播放 3000w+，多年未删
    "BV1xW411J7tu",  # 老番茄《史上最骚孙悟空》(2017) — 头部 UP 主老番茄，经典动画配音
    "BV1aZ4y1a7KJ",  # 罗翔说刑法 (2020) — 头部 UP 主罗翔，法律科普，长期保留
    "BV1Es411v7Vr",  # 千本樱 (2012) — 经典 VOCALOID，V 家代表曲目
]

# B 站公开的 mixinKey 置换表（从 yutto 源码读懂后自行实现的算法，未复制文件）
MIXIN_KEY_ENC_TAB = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5,
    49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55,
    40, 61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57,
    62, 11, 36, 20, 34, 44, 52,
]

RISK_CODES = (-352, -412)  # -352 风控校验 / -412 请求被拦截

# ---------------------------------------------------------------------------
# 请求工具（标准库 urllib + 请求间隔控制）
# ---------------------------------------------------------------------------


class HttpClient:
    """带请求间隔控制的 urllib 封装。"""

    def __init__(self, interval: float = 1.5):
        self.interval = interval
        self._last_ts = 0.0
        self.total_requests = 0
        self.risk_hit = False  # 是否已触发风控（-352/-412）
        self.risk_records = []

    def _throttle(self):
        """保证与上一次请求的间隔 >= interval 秒。"""
        now = time.time()
        wait = self.interval - (now - self._last_ts)
        if wait > 0:
            time.sleep(wait)
        self._last_ts = time.time()

    def get_json(self, url: str, params: dict | None = None,
                 referer: str | None = None, ua: bool = True,
                 extra_headers: dict | None = None, timeout: float = 10.0):
        """GET 一个 JSON 接口。

        返回 (http_status, json_obj 或 None)。
        """
        self._throttle()
        self.total_requests += 1
        if params:
            url = url + "?" + urllib.parse.urlencode(params)
        headers = {"Accept": "application/json"}
        if ua:
            headers["User-Agent"] = UA
        if referer:
            headers["Referer"] = referer
        if extra_headers:
            headers.update(extra_headers)
        req = urllib.request.Request(url, headers=headers, method="GET")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                body = resp.read()
                http_status = resp.status
        except urllib.error.HTTPError as e:
            http_status = e.code
            body = e.read()
        except Exception as e:  # noqa: BLE001 — 网络异常都记下来
            return ("EXC:" + type(e).__name__, str(e))
        try:
            data = json.loads(body.decode("utf-8"))
        except Exception:
            data = None
        # 风控检测：只针对 API 层（body 是 json 且有 code 字段）的情况
        if isinstance(data, dict) and data.get("code") in RISK_CODES:
            self.risk_hit = True
            self.risk_records.append({"url": url, "code": data.get("code"),
                                      "message": data.get("message")})
        return http_status, data

    def get_bytes(self, url: str, referer: str | None = None, ua: bool = True,
                 extra_headers: dict | None = None, timeout: float = 10.0):
        """GET 一个非 JSON 资源（如 mp4 流），只读取前 1KB 即断开。

        用于防盗链测试，避免下载整个文件。
        返回 (http_status, 实际读取到的字节数)。
        """
        self._throttle()
        self.total_requests += 1
        headers = {}
        if ua:
            headers["User-Agent"] = UA
        if referer:
            headers["Referer"] = referer
        if extra_headers:
            headers.update(extra_headers)
        req = urllib.request.Request(url, headers=headers, method="GET")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                status = resp.status
                n = len(resp.read(1024))  # 只读 1KB 就关，够判断能拿到数据即可
        except urllib.error.HTTPError as e:
            status = e.code
            n = 0
        except Exception as e:  # noqa: BLE001
            return "EXC:" + type(e).__name__, str(e)
        return status, n


# ---------------------------------------------------------------------------
# WBI 签名（算法读懂后自行实现）
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

    - with_dm=True 时额外附带 dm_img_list / dm_img_str / dm_cover_img_str，
      这是 yutto 新版为对抗风控附加的参数；本探针两种都验证。
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
    query = urllib.parse.urlencode(sorted(cleaned.items()))
    p["w_rid"] = hashlib.md5((query + mixin_key).encode()).hexdigest()
    return p


# ---------------------------------------------------------------------------
# 各阶段探针
# ---------------------------------------------------------------------------


def probe_view(http: HttpClient, bvid: str) -> dict:
    """阶段 1：视频信息接口，匿名调用。"""
    status, data = http.get_json(f"{API}/x/web-interface/view", {"bvid": bvid})
    rec = {"bvid": bvid, "http_status": status, "code": None, "title": None,
           "cid": None, "pic": None, "duration": None, "owner": None,
           "message": None}
    if isinstance(data, dict):
        rec["code"] = data.get("code")
        rec["message"] = data.get("message")
        d = data.get("data") or {}
        rec["title"] = d.get("title")
        rec["cid"] = d.get("cid")
        rec["pic"] = d.get("pic")
        rec["duration"] = d.get("duration")
        owner = d.get("owner") or {}
        rec["owner"] = owner.get("name")
    return rec


def probe_playurl(http: HttpClient, bvid: str, cid: int,
                  qn: int = 80, fnval: int = 0) -> dict:
    """阶段 2：播放流接口。

    fnval=0   → 传统 mp4 (durl)
    fnval=16  → DASH 结构
    """
    params = {"bvid": bvid, "cid": cid, "qn": qn, "fnval": fnval,
              "fnver": 0, "fourk": 1}
    status, data = http.get_json(f"{API}/x/player/playurl", params)
    rec = {"bvid": bvid, "cid": cid, "qn": qn, "fnval": fnval,
           "http_status": status, "code": None, "message": None,
           "quality": None, "accept_quality": None, "durl_count": 0,
           "durl_top_quality": None, "durl_first_url": None,
           "dash": None}
    if isinstance(data, dict):
        rec["code"] = data.get("code")
        rec["message"] = data.get("message")
        d = data.get("data") or {}
        rec["quality"] = d.get("quality")
        rec["accept_quality"] = d.get("accept_quality")
        durl = d.get("durl") or []
        rec["durl_count"] = len(durl)
        if durl:
            rec["durl_top_quality"] = durl[0].get("quality")
            rec["durl_first_url"] = durl[0].get("url")
        dash = d.get("dash")
        if isinstance(dash, dict):
            videos = dash.get("video") or []
            rec["dash"] = {
                "video_count": len(videos),
                "audio_count": len(dash.get("audio") or []),
                "videos": [
                    {"id": v.get("id"), "width": v.get("width"),
                     "height": v.get("height"), "codecid": v.get("codecid"),
                     "baseUrl_head": (v.get("baseUrl") or "")[:80]}
                    for v in videos
                ],
                "audios": [
                    {"id": a.get("id"), "bandwidth": a.get("bandwidth"),
                     "codecs": a.get("codecs"),
                     "baseUrl_head": (a.get("baseUrl") or "")[:80]}
                    for a in (dash.get("audio") or [])
                ],
            }
    return rec


def probe_antileech(http: HttpClient, mp4_url: str) -> list[dict]:
    """阶段 3：防盗链测试。

    对同一条 mp4 流 URL 分别做：
      a) 无 Referer（带 UA）       → 预期 403
      b) Referer: www.bilibili.com → 预期 200
      c) 无 User-Agent（带 Referer）→ 验证 UA 是否必需
    """
    results = []
    for name, kwargs in [
        ("无 Referer（带 UA）", {"referer": None, "ua": True}),
        ("Referer=bilibili（带 UA）", {"referer": "https://www.bilibili.com/", "ua": True}),
        ("Referer=bilibili（无 UA）", {"referer": "https://www.bilibili.com/", "ua": False}),
    ]:
        status, n = http.get_bytes(mp4_url, **kwargs)
        results.append({"case": name, "status": status, "bytes_read": n})
    return results


def probe_wbi(http: HttpClient, bvid: str) -> dict:
    """阶段 4：WBI 签名。

    1) nav 匿名拿 wbi_img（img_key / sub_key）
    2) 生成 mixinKey，构造 w_rid
    3) 用带签名请求 view，与不带签名的结果对比
    """
    rec = {"nav_status": None, "nav_code": None, "img_key": None,
           "sub_key": None, "mixin_key": None, "signed_view": None,
           "plain_view": None, "extra": []}
    status, data = http.get_json(f"{API}/x/web-interface/nav")
    rec["nav_status"] = status
    if not isinstance(data, dict) or not isinstance(data.get("data"), dict):
        rec["nav_error"] = data
        return rec
    # 注意：匿名访问 nav 返回 code=-101（账号未登录），但 data.wbi_img 依然存在，
    # 因此这里不要求 code==0，只要 data.wbi_img 在就解析
    rec["nav_code"] = data.get("code")
    wbi_img = (data.get("data") or {}).get("wbi_img") or {}
    img_key = get_key_from_url(wbi_img.get("img_url", ""))
    sub_key = get_key_from_url(wbi_img.get("sub_url", ""))
    rec["img_key"] = img_key
    rec["sub_key"] = sub_key
    rec["mixin_key"] = get_mixin_key(img_key + sub_key)

    # 对比：不带签名（刚才阶段 1 已测过，这里重新取一次作严格对比）
    plain = probe_view(http, bvid)
    rec["plain_view"] = plain

    # 带签名（基本版）
    params = encode_wbi({"bvid": bvid}, img_key, sub_key, with_dm=False)
    status, data = http.get_json(f"{API}/x/web-interface/view", params)
    rec["signed_view"] = {
        "http_status": status,
        "code": data.get("code") if isinstance(data, dict) else None,
        "message": data.get("message") if isinstance(data, dict) else None,
        "title": (data.get("data") or {}).get("title") if isinstance(data, dict) else None,
    }

    # 如果基本版签名失败，再试带 dm 风控参数版本（yutto 新版做法）
    if rec["signed_view"]["code"] not in (0,):
        params2 = encode_wbi({"bvid": bvid}, img_key, sub_key, with_dm=True)
        status2, data2 = http.get_json(f"{API}/x/web-interface/view", params2)
        rec["signed_view_dm"] = {
            "http_status": status2,
            "code": data2.get("code") if isinstance(data2, dict) else None,
            "message": data2.get("message") if isinstance(data2, dict) else None,
            "title": (data2.get("data") or {}).get("title") if isinstance(data2, dict) else None,
        }
    return rec


def probe_risk(http: HttpClient, bvid: str, cid: int, rounds: int = 5) -> list[dict]:
    """阶段 5：连续 rounds 次 playurl 请求，观察风控。"""
    records = []
    for i in range(rounds):
        rec = probe_playurl(http, bvid, cid, qn=64, fnval=0)
        records.append({"round": i + 1, "code": rec["code"],
                        "message": rec["message"],
                        "http_status": rec["http_status"]})
        if http.risk_hit:  # 触发 -352/-412 立即停
            records.append({"round": i + 1, "note": "RISK HIT, stop"})
            break
    return records


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------


def main():
    ap = argparse.ArgumentParser(description="B 站 API 技术侦察探针（M0）")
    ap.add_argument("--bvid", action="append", default=[],
                    help="指定 BV 列表（可多次，逗号分隔），覆盖内置候选")
    ap.add_argument("--interval", type=float, default=1.5,
                    help="请求间隔秒数（默认 1.5）")
    ap.add_argument("--out", default="probe_out.json",
                    help="JSON 结果输出文件（默认 probe_out.json）")
    ap.add_argument("--video-only", action="store_true",
                    help="只做视频信息验证，跳过播放流/防盗链/wbi")
    ap.add_argument("--no-risk", action="store_true",
                    help="跳过风控连测（阶段 5）")
    ap.add_argument("--stage", default="all",
                    help="只跑指定阶段，逗号分隔，如 '2,4'；默认 all")
    ap.add_argument("--limit-videos", type=int, default=3,
                    help="最多使用几个有效视频（默认 3）")
    args = ap.parse_args()

    stages = set(s.strip() for s in args.stage.split(",") if s.strip())
    if stages != {"all"}:
        # all 与具体阶段混用没有意义，直接视为指定阶段
        pass

    # 收集 BV 候选
    bvids = []
    for group in args.bvid:
        bvids.extend([b.strip() for b in group.split(",") if b.strip()])
    if not bvids:
        bvids = list(CANDIDATE_BVIDS)

    print(f"== B 站 API 探针（M0）== 间隔={args.interval}s 候选BV={bvids} 阶段={sorted(stages)}")
    print("目标：匿名下 mp4 最高清晰度 / DASH 可用性 / 防盗链 / wbi 强制情况 / 风控阈值")

    http = HttpClient(interval=args.interval)
    out = {
        "meta": {
            "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
            "python": sys.version.split()[0],
            "interval": args.interval,
            "candidates": bvids,
            "stages": sorted(stages),
        },
        "videos": [],
        "playurl": [],
        "antileech": [],
        "wbi": None,
        "risk": [],
        "total_requests": 0,
    }

    # ---- 阶段 1：视频验证，筛选有效视频 ----
    print("\n[阶段1] 验证候选视频（view 接口，匿名）")
    valid = []
    for bv in bvids:
        rec = probe_view(http, bv)
        out["videos"].append(rec)
        if rec["code"] == 0:
            valid.append(rec)
            print(f"  OK  {bv}  title={rec['title']!r} cid={rec['cid']} "
                  f"duration={rec['duration']}s owner={rec['owner']!r}")
        else:
            print(f"  SKIP {bv}  code={rec['code']} http={rec['http_status']} "
                  f"message={rec['message']}")
        if len(valid) >= args.limit_videos:
            break
        if http.risk_hit:
            print("  !! 触发风控，停止阶段1")
            break

    if not valid:
        print("!! 没有有效视频，终止。")
        out["total_requests"] = http.total_requests
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(out, f, ensure_ascii=False, indent=2)
        return

    print(f"  有效视频 {len(valid)} 个，使用: {[v['bvid'] for v in valid]}")

    # ---- 阶段 2：播放流 ----
    if not args.video_only and ("2" in stages or "all" in stages):
        print("\n[阶段2] 播放流接口 playurl（匿名）")
        bv0, cid0 = valid[0]["bvid"], valid[0]["cid"]
        combos = [
            ("fnval=0  qn=80  传统mp4", dict(qn=80, fnval=0)),
            ("fnval=16 qn=80  DASH", dict(qn=80, fnval=16)),
            ("fnval=16 qn=127 全高清", dict(qn=127, fnval=16)),
            ("fnval=0  qn=127 传统mp4全高清", dict(qn=127, fnval=0)),
        ]
        for label, kw in combos:
            rec = probe_playurl(http, bv0, cid0, **kw)
            out["playurl"].append(rec)
            print(f"  [{label}] code={rec['code']} http={rec['http_status']} "
                  f"quality={rec['quality']} accept_quality={rec['accept_quality']} "
                  f"durl_count={rec['durl_count']} "
                  f"dash_video_count={rec['dash']['video_count'] if rec['dash'] else '-'}")
            if rec["dash"]:
                for v in rec["dash"]["videos"]:
                    print(f"      dash.video id={v['id']} {v['width']}x{v['height']} "
                          f"codecid={v['codecid']} baseUrl={v['baseUrl_head']}...")
            if rec["durl_first_url"]:
                print(f"      durl.url={rec['durl_first_url'][:110]}...")
            if http.risk_hit:
                print("  !! 触发风控，停止阶段2")
                break

        # ---- 阶段 3：防盗链（取第一条 mp4 durl URL 测试）----
        if "3" in stages or "all" in stages:
            mp4_rec = next((r for r in out["playurl"]
                            if r["durl_first_url"] and r["code"] == 0), None)
            if mp4_rec:
                print("\n[阶段3] 防盗链测试（Range 只读 1KB）")
                mp4_url = mp4_rec["durl_first_url"]
                out["antileech"] = probe_antileech(http, mp4_url)
                for r in out["antileech"]:
                    print(f"  {r['case']}: status={r['status']} bytes_read={r['bytes_read']}")

        # ---- 阶段 4：WBI ----
        if "4" in stages or "all" in stages:
            print("\n[阶段4] WBI 签名验证")
            out["wbi"] = probe_wbi(http, valid[0]["bvid"])
            w = out["wbi"]
            print(f"  nav_status={w['nav_status']} nav_code={w.get('nav_code')} "
                  f"img_key={w['img_key']} sub_key={w['sub_key']} "
                  f"mixin_key={w['mixin_key']}")
            sv = w.get("signed_view") or {}
            pv = w.get("plain_view") or {}
            print(f"  不带签名 view: code={pv.get('code')}")
            print(f"  带签名   view: code={sv.get('code')} message={sv.get('message')} "
                  f"title={sv.get('title')}")
            if "signed_view_dm" in w:
                dm = w["signed_view_dm"]
                print(f"  带签名+dm view: code={dm.get('code')} message={dm.get('message')} "
                      f"title={dm.get('title')}")

        # ---- 阶段 5：风控连测 ----
        if not args.no_risk and ("5" in stages or "all" in stages):
            print("\n[阶段5] 风控观察：连续 5 次 playurl（间隔 1.5s）")
            out["risk"] = probe_risk(http, bv0, cid0, rounds=5)
            for r in out["risk"]:
                print(f"  round={r['round']} code={r.get('code')} "
                      f"message={r.get('message')} http={r.get('http_status')}")

    # ---- 收尾 ----
    out["total_requests"] = http.total_requests
    out["risk_hit"] = http.risk_hit
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)

    print(f"\n== 完成 == 总请求 {http.total_requests} 次，风控触发: {http.risk_hit}")
    print(f"原始 JSON 已写入: {args.out}")


if __name__ == "__main__":
    main()
