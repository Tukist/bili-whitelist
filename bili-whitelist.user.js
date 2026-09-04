// ==UserScript==
// @name         白名单助手 (Bili-Whitelist) 直连版
// @namespace    https://github.com/Tukist/bili-whitelist
// @version      2.3.1
// @description  B站视频页一键加入白名单（支持多P合集/自定义合集）：直连 GitHub Gist API 读写白名单，零本地服务依赖
// @match        https://www.bilibili.com/video/*
// @grant        GM_xmlhttpRequest
// @grant        GM_getValue
// @grant        GM_setValue
// @connect      api.github.com
// @connect      api.bilibili.com
// @connect      www.bilibili.com
// ==/UserScript==

/*
 * ==================== 功能 / 使用 / 配置 ====================
 * 【功能】
 *   在 B 站视频页点按钮，把当前视频信息（bvid/cid/title/cover/duration/up_name/pages）
 *   直接写入 GitHub Gist 里的 whitelist.json，手机白名单点播 App 拉取 Gist 即见。
 *   完全直连，不再需要本机 whitelist.py / serve 服务。
 *   v2.2.0 起支持多 P 合集：pages 字段存全部分 P（cid/part/duration），
 *   供 App 端选集；单 P 视频 pages 仅 1 项，与旧数据兼容。
 *   v2.3.0 起支持自定义合集（collection）：新增视频带 collection:""（未分类），
 *   合并写入时保留 Gist 顶层 collections 数组原样不破坏；version 保留读到的值
 *   （v2 保持 2、v3 保持 3，仅从空列表初始化时写 3）。
 *   v2.3.1 起支持 App v4 白名单 UP 主：parse/build 同步保留顶层 upowners 数组
 *   （此前只认识 collections/videos，PATCH 覆盖写回会把 App 加的 upowners 清空——
 *   与历史「合集消失」同款 bug，见 whitelist_video.dart v4 说明）。
 *
 * 【使用】
 *   1. 浏览器安装 Tampermonkey（油猴），新建脚本粘贴保存
 *   2. 打开任意 B 站视频页，【双击】标题右侧按钮 → 弹出配置面板，填写：
 *        - github_token：GitHub Personal Access Token（需 gist 权限，最小授权即可）
 *        - gist_id：白名单 Gist 的 ID（用户 Tukist 的 secret gist：
 *          73a6e23f94d55dc7a1f88e4a2a7557d5）
 *   3. 之后【单击】按钮，即可把当前视频加入白名单
 *
 * 【配置存储与安全提示】
 *   - token / gist_id 只存 Tampermonkey 本地存储（GM_setValue），不进脚本文件
 *   - 本脚本文件内不含任何默认 token，请勿把 token 写入/提交到脚本或公开仓库
 *   - token 权限只需勾选 gist 一项（最小权限原则）
 *   - 需要撤销/修改：油猴管理面板 → 本脚本 → 值，删除/修改 github_token 即可
 * ========================================================
 */

(function () {
    'use strict';

    // 轮询间隔：B 站是单页应用，切视频 URL 变但页面不刷新，靠它重建按钮
    const POLL_MS = 1000;
    // 按钮反馈恢复时间（成功/失败提示显示多久后复原）
    const RESET_MS = 1500;
    // GitHub Gist API 请求超时（统一 10s）
    const GIST_TIMEOUT = 10000;
    // B站 view API 回退请求超时（8s）
    const VIEW_TIMEOUT = 8000;
    // 双击判定阈值：两次点击间隔 < 该值视为双击
    const DBLCLICK_MS = 300;
    // 单击延迟执行时间：略大于双击阈值，给双击留出判定窗口
    const CLICK_DELAY_MS = 320;
    // 按钮默认 title
    const BTN_TITLE_DEFAULT = '单击加入白名单 · 双击配置';

    let currentBvid = '';   // 当前已挂载按钮对应的 bvid
    let btn = null;         // 当前按钮 DOM 引用
    let lastClickTime = 0;  // 上次点击时间戳（双击检测用）
    let clickToken = 0;     // 单击延迟令牌：双击时递增，取消挂起的单击动作

    // 从当前页面 URL 提取 bvid，提取不到返回空串
    function bvidFromUrl() {
        const m = window.location.pathname.match(/\/video\/(BV[0-9A-Za-z]{10})/);
        return m ? m[1] : '';
    }

    // 读取配置（GM 本地存储，未配置返回空串）
    function getToken() { return GM_getValue('github_token', ''); }
    function getGistId() { return GM_getValue('gist_id', ''); }

    // 新建一个按钮（含基础样式，与 v1 一致），不挂载
    function createButton() {
        const b = document.createElement('button');
        b.id = 'bili-whitelist-btn';
        b.textContent = '⭐ 加入白名单';
        b.title = BTN_TITLE_DEFAULT;
        b.style.cssText = [
            'display:inline-flex',
            'align-items:center',
            'gap:4px',
            'margin:0 0 0 12px',
            'padding:5px 14px',
            'border:none',
            'border-radius:6px',
            'background:#fb7299',
            'color:#fff',
            'font-size:13px',
            'line-height:1.6',
            'cursor:pointer',
            'white-space:nowrap',
            'vertical-align:middle',
            'transition:background .2s',
        ].join(';');
        b.addEventListener('mouseenter', () => { b.style.background = '#f7598a'; });
        b.addEventListener('mouseleave', () => { b.style.background = '#fb7299'; });
        return b;
    }

    // 把按钮挂到视频标题旁边（标题容器内，flex 与标题文本并排）
    function mountButton(b) {
        const title = document.querySelector('#viewbox_report h1, .video-info-title h1');
        if (!title) return false;
        title.style.display = 'flex';
        title.style.alignItems = 'center';
        title.style.flexWrap = 'wrap';
        title.appendChild(b);
        return true;
    }

    // 按钮临时状态：只改文字 + 可选原因（title），RESET_MS 后恢复原样。
    // 注意：不再设置 disabled —— disabled 按钮不派发 click/dblclick 事件，
    // 会把双击的第二击吞掉，导致处理中/未配置时无法再触发配置弹窗。
    function setBtnState(text, disabled, title) {
        if (!btn) return;
        btn.textContent = text;
        if (title) btn.title = title;
        clearTimeout(btn._timer);
        btn._timer = setTimeout(() => {
            if (btn) {
                btn.textContent = '⭐ 加入白名单';
                btn.title = BTN_TITLE_DEFAULT;
            }
        }, RESET_MS);
    }

    // 移除旧按钮，防止重复挂载；同时重置双击检测状态，避免新按钮首次点击被误判
    function cleanup() {
        if (btn && btn.parentNode) {
            btn.parentNode.removeChild(btn);
        }
        btn = null;
        currentBvid = '';
        lastClickTime = 0;
        clickToken = 0;
    }

    // 归一化 pages 数组为 [{cid, part, duration}]（多P合集用，App 端选集）。
    // 页面状态 / view API 的 pages 每项含 cid/part/duration；缺失时用单P兜底，
    // 保证返回对象恒有 pages 字段（兼容旧数据 / 页面状态异常）。
    function normalizePages(pages, fallbackCid, fallbackTitle, fallbackDuration) {
        if (Array.isArray(pages) && pages.length > 0) {
            return pages.map(p => ({
                cid: p.cid || 0,
                part: p.part || '',
                duration: p.duration || 0,
            }));
        }
        return [{
            cid: fallbackCid || 0,
            part: fallbackTitle || '',
            duration: fallbackDuration || 0,
        }];
    }

    // ==================== 拿视频信息 ====================
    // 优先读页面全局状态 window.__INITIAL_STATE__.videoData（同源零请求）；
    // 读不到则回退 B站 view API（带页面 UA，GM_xmlhttpRequest 默认带）
    function fetchVideoInfo(bvid) {
        return new Promise((resolve, reject) => {
            try {
                const vd = window.__INITIAL_STATE__ && window.__INITIAL_STATE__.videoData;
                if (vd && vd.bvid) {
                    resolve({
                        bvid: vd.bvid,
                        cid: vd.cid || 0,
                        title: vd.title || '',
                        cover: vd.pic || '',
                        duration: vd.duration || 0,
                        up_name: (vd.owner && vd.owner.name) || '',
                        pages: normalizePages(vd.pages, vd.cid, vd.title, vd.duration),
                    });
                    return;
                }
            } catch (e) {
                // 全局状态异常，继续走 API 回退
            }
            GM_xmlhttpRequest({
                method: 'GET',
                url: 'https://api.bilibili.com/x/web-interface/view?bvid=' + encodeURIComponent(bvid),
                timeout: VIEW_TIMEOUT,
                onload: (res) => {
                    if (res.status === 412) {
                        reject({ kind: 'bili_412', msg: 'B站 view API 触发风控(412)，请刷新页面后重试' });
                    } else if (res.status === 0 || res.status >= 500) {
                        reject({ kind: 'bili_network', msg: '网络错误：B站 view API 不可达' });
                    } else if (res.status !== 200) {
                        reject({ kind: 'bili_http', msg: 'B站 view API 返回 ' + res.status });
                    } else {
                        try {
                            const d = JSON.parse(res.responseText);
                            if (d.code !== 0) {
                                reject({ kind: 'bili_api', msg: 'B站 view API 返回 code=' + d.code });
                            } else {
                                const v = d.data;
                                resolve({
                                    bvid: v.bvid,
                                    cid: v.cid || 0,
                                    title: v.title || '',
                                    cover: v.pic || '',
                                    duration: v.duration || 0,
                                    up_name: (v.owner && v.owner.name) || '',
                                    pages: normalizePages(v.pages, v.cid, v.title, v.duration),
                                });
                            }
                        } catch (e) {
                            reject({ kind: 'parse', msg: 'B站 view API 响应解析失败' });
                        }
                    }
                },
                onerror: () => reject({ kind: 'bili_network', msg: '网络错误：B站 view API 不可达' }),
                ontimeout: () => reject({ kind: 'bili_timeout', msg: 'B站 view API 请求超时(8s)' }),
            });
        });
    }

    // ==================== GitHub Gist API ====================
    // GET https://api.github.com/gists/{gist_id}
    function gistGet(gistId, token) {
        return new Promise((resolve, reject) => {
            GM_xmlhttpRequest({
                method: 'GET',
                url: 'https://api.github.com/gists/' + encodeURIComponent(gistId),
                headers: {
                    'Authorization': 'Bearer ' + token,
                    'Accept': 'application/vnd.github+json',
                },
                timeout: GIST_TIMEOUT,
                onload: (res) => {
                    if (res.status === 0) reject({ kind: 'network', msg: '网络错误：无法访问 api.github.com' });
                    else resolve({ status: res.status, text: res.responseText });
                },
                onerror: () => reject({ kind: 'network', msg: '网络错误：无法访问 api.github.com' }),
                ontimeout: () => reject({ kind: 'gist_timeout', msg: '请求 api.github.com 超时(10s)' }),
            });
        });
    }

    // PATCH https://api.github.com/gists/{gist_id}，只更新 whitelist.json 内容
    function gistPatch(gistId, token, content) {
        return new Promise((resolve, reject) => {
            GM_xmlhttpRequest({
                method: 'PATCH',
                url: 'https://api.github.com/gists/' + encodeURIComponent(gistId),
                headers: {
                    'Authorization': 'Bearer ' + token,
                    'Content-Type': 'application/json',
                    'Accept': 'application/vnd.github+json',
                },
                data: JSON.stringify({ files: { 'whitelist.json': { content: content } } }),
                timeout: GIST_TIMEOUT,
                onload: (res) => {
                    if (res.status === 0) reject({ kind: 'network', msg: '网络错误：无法访问 api.github.com' });
                    else resolve({ status: res.status, text: res.responseText });
                },
                onerror: () => reject({ kind: 'network', msg: '网络错误：无法访问 api.github.com' }),
                ontimeout: () => reject({ kind: 'gist_timeout', msg: '请求 api.github.com 超时(10s)' }),
            });
        });
    }

    // 把 GitHub 状态码归类为人类可读原因
    function classifyGistError(status) {
        if (status === 401) return { msg: '401: token 无效或已过期（双击按钮重新配置）' };
        if (status === 403) return { msg: '403: token 权限不足或触发速率限制' };
        if (status === 404) return { msg: '404: gist_id 不存在或无权访问（双击按钮检查配置）' };
        return { msg: 'GitHub API 返回 ' + status };
    }

    // 从 Gist 响应 JSON 里取 whitelist.json 的 content；文件不存在返回空串（从空列表开始）
    function parseGistContent(text) {
        try {
            const d = JSON.parse(text);
            const f = d.files && d.files['whitelist.json'];
            return { content: (f && f.content) || '', fromGist: !!f };
        } catch (e) {
            return null; // Gist 响应解析失败
        }
    }

    // 解析 whitelist JSON；非法或空则返回空列表结构（空列表初始化 → version 3）
    // v3/v4：保留顶层 collections 与 upowners 数组原样（合并时不破坏）；
    // v1/v2 无该字段视为 []（v4 字段缺失由 buildWhitelistJson 补空数组兜底）
    function parseWhitelist(text) {
        if (!text) return { version: 3, updated_at: '', collections: [], videos: [], upowners: [] };
        try {
            const d = JSON.parse(text);
            return {
                version: typeof d.version === 'number' ? d.version : 1,
                updated_at: d.updated_at || '',
                collections: Array.isArray(d.collections) ? d.collections : [],
                videos: Array.isArray(d.videos) ? d.videos : [],
                upowners: Array.isArray(d.upowners) ? d.upowners : [],
            };
        } catch (e) {
            return { version: 3, updated_at: '', collections: [], videos: [], upowners: [] };
        }
    }

    // 合并：按 bvid 查重；不存在则追加并按 added_at 倒序排列
    function mergeVideo(wl, video) {
        if (wl.videos.some(v => v.bvid === video.bvid)) return false;
        wl.videos.push(video);
        wl.videos.sort((a, b) => (b.added_at || '').localeCompare(a.added_at || ''));
        return true;
    }

    // 组装新 whitelist JSON 字符串（2 空格缩进，与 whitelist.py 输出风格一致）
    function buildWhitelistJson(wl) {
        // 用 +00:00 后缀，与现有数据格式保持一致（toISOString 是 Z 后缀）
        wl.updated_at = new Date().toISOString().replace('Z', '+00:00');
        // v4：顶层 collections / upowners 缺失时补空数组（整对象序列化，
        // 保证不丢字段）；v1/v2/v3 已有数据保持其原样（不存在则 []）
        if (!Array.isArray(wl.collections)) wl.collections = [];
        if (!Array.isArray(wl.upowners)) wl.upowners = [];
        // version 保留读到的值：v2 保持 2、v3 保持 3；空列表初始化已在
        // parseWhitelist 写成 3；仅旧 v1 数据（无 pages）合并时升级到 v2
        if (typeof wl.version !== 'number' || wl.version < 1) wl.version = 3;
        else if (wl.version === 1) wl.version = 2;
        return JSON.stringify(wl, null, 2);
    }

    // ==================== 核心流程 ====================
    async function onAdd(bvid) {
        const token = getToken();
        const gistId = getGistId();
        if (!token || !gistId) {
            setBtnState('⚠️ 未配置', true, '未配置 token/gist_id，双击按钮进行配置');
            console.warn('[Bili-Whitelist] 未配置 github_token / gist_id，请双击按钮配置');
            return;
        }
        setBtnState('⏳ 处理中…', true);
        try {
            // 1. 拿视频信息（页面全局状态优先，view API 回退）
            const info = await fetchVideoInfo(bvid);

            // 2. 拉取 Gist 当前 whitelist.json
            let wl = null;
            let fromCache = false;
            try {
                const g = await gistGet(gistId, token);
                if (g.status !== 200) throw classifyGistError(g.status);
                const parsed = parseGistContent(g.text);
                if (!parsed) throw { kind: 'parse', msg: 'Gist 响应解析失败' };
                wl = parseWhitelist(parsed.content);
            } catch (err) {
                // GET 失败：本地 GM 缓存兜底（缓存存在则用缓存合并后 PATCH）
                const cache = GM_getValue('cache_whitelist', '');
                if (cache) {
                    wl = parseWhitelist(cache);
                    fromCache = true;
                    console.warn('[Bili-Whitelist] Gist GET 失败，改用本地缓存合并:', err.msg || err.kind || err);
                } else {
                    throw err;
                }
            }

            // 3. 合并（查重 + 追加 + 按 added_at 倒序）
            //    v3：新增视频带 collection:""（未分类）；collections 由 buildWhitelistJson 原样保留
            const video = Object.assign({}, info, {
                added_at: new Date().toISOString().replace('Z', '+00:00'),
                collection: '',
            });
            if (!mergeVideo(wl, video)) {
                setBtnState('已在白名单', true);
                console.log('[Bili-Whitelist] 已在白名单，跳过:', bvid);
                return;
            }

            // 4. PATCH 更新 Gist
            const content = buildWhitelistJson(wl);
            const p = await gistPatch(gistId, token, content);
            if (p.status === 200) {
                GM_setValue('cache_whitelist', content);
                setBtnState('✅ 已加入', true, fromCache ? '已加入（Gist读取失败，基于本地缓存合并）' : '已加入白名单');
                console.log('[Bili-Whitelist] 加入成功:', bvid, fromCache ? '(基于本地缓存合并)' : '');
            } else {
                const e = classifyGistError(p.status);
                setBtnState('❌ 失败', true, e.msg);
                console.error('[Bili-Whitelist] PATCH 失败:', p.status, e.msg);
            }
        } catch (err) {
            // 错误分类展示：401 / 404 / 网络 / B站412 等
            const msg = (err && (err.msg || err.kind)) || String(err);
            setBtnState('❌ 失败', true, msg);
            console.error('[Bili-Whitelist] 加入失败:', msg);
        }
    }

    // ==================== 挂载 / 重建按钮 ====================
    // ==================== 配置弹窗（自定义 DOM，不依赖 prompt/alert/confirm） ====================
    // 双击按钮：弹出配置面板，填写 github_token / gist_id，保存到 GM 本地存储
    function onConfig() {
        openConfigModal();
    }

    // 关闭配置弹窗（移除遮罩节点）
    function closeConfigModal() {
        const m = document.getElementById('bili-whitelist-modal');
        if (m && m.parentNode) {
            m.parentNode.removeChild(m);
        }
    }

    // 新建配置弹窗并挂到 body；已存在则忽略（防止重复打开）
    function openConfigModal() {
        if (document.getElementById('bili-whitelist-modal')) return;

        // 全屏半透明遮罩：覆盖在 B 站所有元素之上，点击遮罩关闭
        const mask = document.createElement('div');
        mask.id = 'bili-whitelist-modal';
        mask.style.cssText = [
            'position:fixed',
            'inset:0',
            'background:rgba(0,0,0,.5)',
            'z-index:999999',
            'display:flex',
            'align-items:center',
            'justify-content:center',
        ].join(';');
        mask.addEventListener('click', (e) => {
            if (e.target === mask) closeConfigModal();
        });

        // 居中卡片：B 站风格（白底、圆角、粉色主按钮）
        const card = document.createElement('div');
        card.style.cssText = [
            'width:400px',
            'max-width:88vw',
            'max-height:88vh',
            'overflow:auto',
            'background:#fff',
            'border-radius:10px',
            'padding:22px 24px',
            'box-sizing:border-box',
            'box-shadow:0 8px 32px rgba(0,0,0,.3)',
            'font-family:"Microsoft YaHei","PingFang SC",sans-serif',
            'color:#18191c',
        ].join(';');

        // 标题
        const title = document.createElement('div');
        title.textContent = '白名单助手 · 配置';
        title.style.cssText = 'font-size:17px;font-weight:700;margin-bottom:8px;';
        card.appendChild(title);

        // 说明文字
        const tip = document.createElement('div');
        tip.textContent = 'token 需 gist 权限，仅存本机 Tampermonkey（GM_setValue），不会写入脚本或上传。留空=保持原值。';
        tip.style.cssText = 'font-size:12px;color:#9499a0;line-height:1.6;margin-bottom:16px;';
        card.appendChild(tip);

        // token 输入框（预填当前值，placeholder 提示）
        const tokenLabel = document.createElement('div');
        tokenLabel.textContent = 'GitHub Token（github_token）';
        tokenLabel.style.cssText = 'font-size:13px;color:#61666d;margin-bottom:6px;';
        card.appendChild(tokenLabel);

        const tokenInput = document.createElement('input');
        tokenInput.type = 'text';
        tokenInput.value = getToken();
        tokenInput.placeholder = 'ghp_xxxxxxxxxxxxxxxxxxxx（需 gist 权限）';
        tokenInput.style.cssText = [
            'width:100%',
            'box-sizing:border-box',
            'padding:8px 10px',
            'border:1px solid #e3e5e7',
            'border-radius:6px',
            'font-size:13px',
            'color:#18191c',
            'background:#fff',
            'outline:none',
            'margin-bottom:14px',
        ].join(';');
        card.appendChild(tokenInput);

        // gist_id 输入框
        const gistLabel = document.createElement('div');
        gistLabel.textContent = 'Gist ID（gist_id）';
        gistLabel.style.cssText = 'font-size:13px;color:#61666d;margin-bottom:6px;';
        card.appendChild(gistLabel);

        const gistInput = document.createElement('input');
        gistInput.type = 'text';
        gistInput.value = getGistId();
        gistInput.placeholder = 'Gist ID，如 73a6e23f94d55dc7a1f88e4a2a7557d5';
        gistInput.style.cssText = [
            'width:100%',
            'box-sizing:border-box',
            'padding:8px 10px',
            'border:1px solid #e3e5e7',
            'border-radius:6px',
            'font-size:13px',
            'color:#18191c',
            'background:#fff',
            'outline:none',
            'margin-bottom:20px',
        ].join(';');
        card.appendChild(gistInput);

        // 按钮行：保存（粉色主按钮）+ 取消（灰色）
        const actions = document.createElement('div');
        actions.style.cssText = 'display:flex;gap:10px;justify-content:flex-end;';
        card.appendChild(actions);

        function modalBtnStyle(bg) {
            return [
                'padding:7px 18px',
                'border:none',
                'border-radius:6px',
                'background:' + bg,
                'color:#fff',
                'font-size:13px',
                'cursor:pointer',
            ].join(';');
        }

        // 保存：写入 GM 存储 → 卡片内显示"✅ 已保存" 1.2s 后自动关闭
        const saveBtn = document.createElement('button');
        saveBtn.textContent = '保存';
        saveBtn.style.cssText = modalBtnStyle('#fb7299');
        saveBtn.addEventListener('click', () => {
            const tok = tokenInput.value.trim();
            const gid = gistInput.value.trim();
            if (tok) GM_setValue('github_token', tok);
            if (gid) GM_setValue('gist_id', gid);
            card.innerHTML = '';
            const ok = document.createElement('div');
            ok.textContent = '✅ 已保存';
            ok.style.cssText = 'text-align:center;font-size:16px;font-weight:700;color:#fb7299;padding:26px 0;';
            card.appendChild(ok);
            setTimeout(closeConfigModal, 1200);
        });
        actions.appendChild(saveBtn);

        const cancelBtn = document.createElement('button');
        cancelBtn.textContent = '取消';
        cancelBtn.style.cssText = modalBtnStyle('#9499a0');
        cancelBtn.addEventListener('click', closeConfigModal);
        actions.appendChild(cancelBtn);

        mask.appendChild(card);
        document.body.appendChild(mask);
        // 默认聚焦 token 输入框，方便直接粘贴
        tokenInput.focus();
    }

    // 挂载/重建按钮：bvid 与当前 URL 一致且按钮还在就不动，否则重建
    function ensureButton() {
        const bvid = bvidFromUrl();
        if (!bvid) {
            cleanup();
            return;
        }
        if (btn && document.contains(btn) && currentBvid === bvid) {
            return;
        }
        cleanup();
        const b = createButton();
        currentBvid = bvid;
        // 双击检测：在 click 事件里用时间戳判定，不依赖 dblclick 事件。
        // 单击延迟 CLICK_DELAY_MS 再执行 onAdd；期间若来第二击（间隔 < DBLCLICK_MS）
        // 则判定为双击，递增 clickToken 取消挂起的单击动作，并打开配置弹窗。
        b.addEventListener('click', () => {
            const now = Date.now();
            if (now - lastClickTime < DBLCLICK_MS) {
                // 第二击：双击 → 配置；同时取消可能挂起的单击
                lastClickTime = 0;
                clickToken++;
                onConfig();
                return;
            }
            // 第一击：记录时间，延迟执行单击动作（双击窗口内可被取消）
            lastClickTime = now;
            const token = ++clickToken;
            setTimeout(() => {
                if (token === clickToken) onAdd(bvid);
            }, CLICK_DELAY_MS);
        });
        btn = b;
        if (!mountButton(b)) {
            // 标题还没渲染出来（B 站 SPA 加载较慢），下个轮询再试
            cleanup();
        }
    }

    // 定期检查 + 页面完全加载后再挂一次，保证按钮尽早出现
    setInterval(ensureButton, POLL_MS);
    window.addEventListener('load', ensureButton);
})();
