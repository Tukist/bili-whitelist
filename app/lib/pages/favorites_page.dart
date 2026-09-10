/// 我的 B 站收藏夹总览页（v2.17.7+ 首页「收藏夹」卡落点，三级浏览第二层）。
///
/// - AppBar「收藏夹」；列表 = 我的收藏夹（[BiliApi.fetchMyFavorites]：
///   封面 / 名称 / 「N 个视频」，样式与收藏夹导入弹层一致）
/// - 登录门禁：无 SESSDATA / 会话已失效（接口 -101）→ 展示「去登录」引导
///   （收藏夹属个人账号数据），登录成功后自动重新加载
/// - 下拉刷新；错误（风控 -412 / 其他 / 网络）可重试；空态（还没有收藏夹）
/// - 点某收藏夹 → [FavoriteVideosPage]（第三层：夹内视频直接点播）
/// - 本页只读浏览：不写 Gist、不入白名单（与 UP 主页同模式）
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../api/bilibili_api.dart' hide FavoriteVideosPage;
import '../widgets/app_state_view.dart';
import '../widgets/cover_image.dart';
import '../widgets/staggered_entrance.dart';
import 'favorite_videos_page.dart';
import 'login_page.dart';

/// 我的 B 站收藏夹总览页。
///
/// [api] / [openLogin] / [openPlayer] 供 widget 测试注入（缺省走真实实现）：
/// 与夹内视频页 [FavoriteVideosPage] 同模式——测试避免真推含 WebView 的
/// 登录页与含原生播放器的播放页，注入替身记录行为即可。
class FavoritesPage extends StatefulWidget {
  /// 注入 B 站 API（widget 测试用 mock；缺省走真实实现）。
  final BiliApi? api;

  /// 登录页导航替身（缺省推真实 [LoginPage]）。
  final Future<void> Function(BuildContext context, {String? banner})?
      openLogin;

  /// 播放页导航替身（透传给夹内视频页；缺省 = 推真实 [PlayerPage]）。
  final OpenPlayerFn? openPlayer;

  const FavoritesPage({super.key, this.api, this.openLogin, this.openPlayer});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  late final BiliApi _api = widget.api ?? BiliApi();

  /// null = 加载中；非 null = 已加载（空列表 = 空态）。
  List<FavoriteFolder>? _folders;

  /// 常规错误文案（-412 / 其他业务码 / 网络）；非 null → 错误视图 + 重试。
  String? _error;

  /// 未登录 / 登录已失效提示文案；非 null → 「去登录」引导视图。
  String? _needLogin;

  /// 入场记账本：**由 State 持有**（活在列表项之外），列表项被回收再建时不重播。
  final EntranceLedger _entranceLedger = EntranceLedger();

  /// 加载代际号（作 [StaggeredListScope.generation]）：拉到新数据 → 自增。
  int _reloadToken = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 拉我的收藏夹列表（首次加载 / 下拉刷新 / 重试 / 登录返回共用）。
  Future<void> _load() async {
    // 首次加载默认即加载中（字段全 null）；后续刷新先复位为加载中
    if (_folders != null || _error != null || _needLogin != null) {
      setState(() {
        _folders = null;
        _error = null;
        _needLogin = null;
      });
    }
    // 登录门禁：无 SESSDATA 视为未登录（fetchMyFavorites 内部同样会抛
    // -101，但接口消息是「再导入收藏夹」的导入风格，这里先拦截给浏览文案）
    String? sess;
    try {
      sess = await _api.readSessdata();
    } catch (_) {
      sess = null; // 存储异常按未登录处理（视图内仍可点「去登录」）
    }
    if (sess == null || sess.isEmpty) {
      if (!mounted) return;
      setState(() => _needLogin = '收藏夹属于个人账号数据，需先登录 B 站账号');
      return;
    }
    try {
      final folders = await _api.fetchMyFavorites();
      if (!mounted) return;
      setState(() {
        _folders = folders;
        // 数据换新 → 记账作废，列表项重建时可再演一次交错入场
        _reloadToken++;
        _entranceLedger.clear();
      });
    } on BiliApiException catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.code == -101) {
          // 残留过期 SESSDATA → 引导重新登录
          _needLogin = '登录已失效，请重新登录后继续浏览收藏夹';
        } else if (e.code == -412) {
          _error = e.message; // 「收藏夹接口被风控拦截，请稍后再试」
        } else {
          _error = '获取收藏夹失败：${e.message}';
        }
      });
    } on DioException {
      if (!mounted) return;
      setState(() => _error = '网络请求失败，请检查网络后重试');
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = '获取收藏夹失败，请重试');
    }
  }

  /// 去登录：推登录页（测试可注入替身）→ 返回后自动重载。
  Future<void> _goLogin() async {
    final injected = widget.openLogin;
    if (injected != null) {
      await injected(context);
    } else {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const LoginPage()),
      );
    }
    if (mounted) _load();
  }

  /// 点某收藏夹 → 夹内视频页（第三层；透传注入的 api/openLogin/openPlayer
  /// 供测试替身使用）。
  Future<void> _openFolder(FavoriteFolder folder) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FavoriteVideosPage(
          mediaId: folder.mediaId,
          folderName: folder.title,
          api: widget.api,
          openLogin: widget.openLogin,
          openPlayer: widget.openPlayer,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('收藏夹')),
      body: RefreshIndicator(
        onRefresh: _load,
        // 列表项交错入场的 scope（InheritedWidget，不参与布局）
        child: StaggeredListScope(
          generation: 'favorites#$_reloadToken',
          ledger: _entranceLedger,
          child: _buildBody(theme),
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    // 加载中（首次 / 刷新 / 重试期间）
    if (_folders == null && _error == null && _needLogin == null) {
      // 本页 body 在 RefreshIndicator 宿主内 → **必须 scrollable: true**，
      // 否则加载态下没有可滚动区域，下拉刷新失效
      return const AppLoadingHero(seed: 'favorites', scrollable: true);
    }
    if (_needLogin != null) {
      // 登录门禁不是「错误」→ 走空态的克制配色，只给一个「去登录」动作
      return AppStateView(
        kind: AppStateKind.empty,
        title: _needLogin!,
        actionLabel: '去登录',
        onAction: _goLogin,
        illustrationSeed: 'favorites',
        scrollable: true,
      );
    }
    if (_error != null) {
      return AppErrorView(
        message: _error!,
        onRetry: _load,
        illustrationSeed: 'favorites',
        scrollable: true,
      );
    }
    final folders = _folders!;
    if (folders.isEmpty) {
      return const AppStateView(
        kind: AppStateKind.empty,
        copyId: 'empty.favorites',
        illustrationSeed: 'favorites',
        scrollable: true,
      );
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: folders.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final f = folders[i];
        return StaggeredEntrance(
          // 稳定标识：media_id 是收藏夹的身份，刷新后不乱序重播
          entryKey: 'fav#${f.mediaId}',
          index: i,
          child: ListTile(
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: CoverImage(cover: f.cover, width: 64, height: 40),
            ),
            title: Text(
              f.title.isEmpty ? '未命名收藏夹' : f.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${f.mediaCount} 个视频',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            trailing: const Icon(Icons.chevron_right, size: 20),
            onTap: () => _openFolder(f),
          ),
        );
      },
    );
  }
}
