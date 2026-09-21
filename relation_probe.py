#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""relation_probe.py — v2.41.0 只读探针：archive/relation 的字段与取值。

背景
----
`view` 接口不下发 `req_user`（v2.40.0 已三处确认：匿名 curl + 真机登录 logcat +
真实浏览器），所以点赞/投币/收藏的真实初始态拿不到，只能"会话内乐观切换 +
UI 标注降级"。本探针验证社区文档所述的只读接口

    GET https://api.bilibili.com/x/web-interface/archive/relation?bvid=...

能否补上这一课。

两次尝试（都在 relation_probe_out.json 里）
-----------------------------------------
1. **本机 curl（pass1_host_curl）**：cookie.txt / cookie_new.txt 里的 SESSDATA
   已过期（两文件内容一致，都是 2026-08 那一批）→ 两条请求都只拿到
   `{"code":-101,"message":"账号未登录"}`。**据此判断不了字段**，如实记录。
2. **真机内置探针（pass2_device_logcat）**：模拟器上的 App 是已登录会话，
   于是让 App 自己打这一次 GET（`BiliApi.fetchVideoRelation` 把**原始
   data** debugPrint 出来），从 logcat 取原文。这是只读请求、零写操作。

结论（字段名以实测为准，不照文档写）
----------------------------------
- 必须登录：无有效 SESSDATA → `code=-101 账号未登录`；**不需要 WBI 签名**。
- `like`     → **bool**（true = 已赞）。
- `coin`     → **int 枚数**（0 = 未投，上限 2）——**不是布尔**。
- `favorite` → **bool**（true = 已收藏）。⚠️ **键名是 `favorite`，不是 `fav`**
  ——第一版照文档写成 `fav`，"已收藏"会永远显示成"未收藏"（比不显示更糟：
  它看起来像确定的事实）。已改为**优先 favorite、fav 兜底**。
- 另有 `attention`（关注 UP）/ `dislike`（点踩）/ `season_fav`（追番），本版不用。

真机原文（logcat 摘录，见 OUT 里的 device_logcat 段）
--------------------------------------------------
    未赞/未投/未收藏 → data={attention: true, favorite: false, season_fav: false,
                              like: false, dislike: false, coin: 0}
    已收藏（用户自己收藏夹里的视频）→ data={attention: false, favorite: true,
                              season_fav: false, like: false, dislike: false, coin: 0}

纪律
----
- **只读**：脚本本身只发 GET；写路径只有在"点赞并还原"的真机验证里出现过
  （`archive/like` like=1 → like=2），**投币一次都没发**。
- 请求数：脚本固定 2 次（间隔 ≥2s），不做重试风暴。
- cookie **绝不落盘**：OUT 里只记长度。

用法：`python relation_probe.py` → 覆盖写 relation_probe_out.json。
"""
import io
import json
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.bilibili.com"
REF = "https://www.bilibili.com/"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36")

HEADERS = {
    "User-Agent": UA,
    "Referer": REF,
    "Origin": "https://www.bilibili.com",
    "Accept": "application/json, text/plain, */*",
    "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
    "Sec-Fetch-Dest": "empty",
    "Sec-Fetch-Mode": "cors",
    "Sec-Fetch-Site": "same-site",
}

# 待探的两条 BV：
#  - BV1ok8F6BENj：「无职转生 第三季 08 满弹幕版」，来自**用户自己**的白名单
#    （whitelist.json.gistbak3），用户真实看过/收过，最有可能出现非零值 →
#    用来确认「非零长什么样」；
#  - BV1xx411c7mD：碧诗 2012 年的镇站之宝，用户几乎不可能互动过 →
#    对照组，确认「零长什么样」。
CASES = [
    ("user_own", "BV1ok8F6BENj"),
    ("control", "BV1xx411c7mD"),
]

# 真机（已登录会话）内置探针的 logcat 原文——**手动抄录、脚本只做归档**，
# 因为那一次请求是 App 自己发的（见文件头第 2 点）。留在这里是为了让
# relation_probe_out.json 一份文件就能自证结论，重跑脚本也不会丢掉这段证据。
DEVICE_LOGCAT = {
    "note": "模拟器（已登录）跑 v2.41.0 debug 包，打开视频后取 "
            "fetchVideoRelation 的 debugPrint 原文。只读 GET，零写请求。",
    "samples": [
        {
            "bvid": "BV1zkYe6EEM8",
            "raw_data": "{attention: true, favorite: false, season_fav: false, "
                        "like: false, dislike: false, coin: 0}",
            "parsed": "VideoRelation(like=false, coin=0, fav=false)",
            "meaning": "未赞/未投/未收藏的零值形态",
        },
        {
            "bvid": "BV1uVem6zEBY",
            "raw_data": "{attention: true, favorite: false, season_fav: false, "
                        "like: false, dislike: false, coin: 0}",
            "parsed": "VideoRelation(like=false, coin=0, fav=false)",
            "meaning": "点赞前基线",
        },
        {
            "bvid": "BV1uVem6zEBY",
            "raw_data": "{attention: true, favorite: false, season_fav: false, "
                        "like: false, dislike: false, coin: 0}",
            "parsed": "VideoRelation(like=false, coin=0, fav=false)",
            "meaning": "点赞→取消点赞（还原）→force-stop 重进（新进程真拉一次）"
                       "仍 like=false：取消点赞在服务端确实生效、已还原",
        },
        {
            "bvid": "BV1W14AzYEiy",
            "raw_data": "{attention: false, favorite: true, season_fav: false, "
                        "like: false, dislike: false, coin: 0}",
            "parsed": "VideoRelation(like=false, coin=0, fav=true)",
            "meaning": "**正例**：来自用户自己的收藏夹「奇怪工具」→ "
                       "favorite=true 被正确解析成「已收藏」",
        },
    ],
    "coin_positive_sample": "无。投币一律不真测（不可撤回、扣真硬币）→ `coin` 的"
                            "非零形态没有实测样本；解析对「数字即枚数」与"
                            "「bool → 1/0」两种形态都兜住。",
}

CONCLUSION = {
    "endpoint": "GET /x/web-interface/archive/relation?bvid=...",
    "auth": "必须登录（SESSDATA）；无有效 cookie → code=-101 账号未登录",
    "wbi": "不需要 WBI 签名",
    "fields": {
        "like": "bool（true = 已赞）",
        "coin": "int 枚数（0 = 未投，上限 2）——不是布尔",
        "favorite": "bool（true = 已收藏）。⚠️ 键名是 favorite，不是 fav",
        "attention": "bool 是否关注 UP（本版不用）",
        "dislike": "bool 是否点踩（本版不用）",
        "season_fav": "bool 是否追番（本版不用）",
    },
    "impl_note": "第一版按文档把收藏字段写成 fav → 真机探针发现真实键名是 "
                 "favorite；已改为优先读 favorite、fav 兜底",
}


def load_cookie():
    with io.open("cookie.txt", encoding="utf-8") as f:
        return f.read().strip()


def probe(tag, bvid, cookie):
    url = API + "/x/web-interface/archive/relation?" + \
        urllib.parse.urlencode({"bvid": bvid})
    h = dict(HEADERS)
    h["Cookie"] = cookie
    req = urllib.request.Request(url, headers=h, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            status, body = r.status, r.read()
    except urllib.error.HTTPError as e:
        status, body = e.code, e.read()
    except Exception as e:  # noqa: BLE001
        print("[%s] EXC %s: %s" % (tag, type(e).__name__, e))
        return {"tag": tag, "bvid": bvid, "http": None, "raw": None}
    raw = body.decode("utf-8", "replace")
    print("[%s] bvid=%s http=%s" % (tag, bvid, status))
    print("     raw: %s" % raw[:600])
    return {"tag": tag, "bvid": bvid, "http": status, "raw": raw, "url": url}


if __name__ == "__main__":
    ck = load_cookie()
    out = []
    for i, (tag, bvid) in enumerate(CASES):
        if i:
            time.sleep(2.0)
        out.append(probe(tag, bvid, ck))
    payload = {
        "probe": "archive/relation 只读探针（v2.41.0）",
        "conclusion": CONCLUSION,
        # Cookie 绝不落盘（只记长度，便于确认确实带上了）
        "pass1_host_curl": {
            "note": "cookie.txt / cookie_new.txt 的 SESSDATA 已过期（两文件内容"
                    "一致）→ 两条请求都只拿到 -101，判断不了字段。故改走"
                    "真机内置探针（见 pass2_device_logcat）。",
            "requests": len(out),
            "cookie_len": len(ck),
            "results": out,
        },
        "pass2_device_logcat": DEVICE_LOGCAT,
    }
    with io.open("relation_probe_out.json", "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2)
    print("\n-> relation_probe_out.json (cookie_len=%d)" % len(ck))
