import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/schedule.dart';

/// 日程表存储（v2.33.0）：shared_preferences 单 key 存 [ScheduleData] 的
/// JSON 字符串。
///
/// **只存本地，绝不进 Gist**（与 `SearchHistoryStore` / `HistoryStore` /
/// `WatchStats` 同介质）。为什么这条要写死在注释里：日程是**私人数据**，
/// 而本 App 的 Gist 里躺的是白名单（合集/UP 主/视频）——那是一份**PC 端
/// 脚本也会读写的共享结构**。把日程塞进去有三重坏处：
/// 1. 污染同步：白名单文件的字段结构是 PC 端脚本按 schema 解析的，多一棵
///    计划外的子树要么被脚本忽略（那还不如不写，白同步一趟），要么在老版本
///    脚本上触发解析失败；
/// 2. 隐私：Gist 默认是公开的（用户配置的 gist_id 大多为 public），
///    "大三上要交实验报告 / 校党校 / 面试"这类内容不该跟着白名单一起公开；
/// 3. 冲突：多设备并发编辑同一张表没有合并策略，最后写入者赢，会静默丢数据。
/// 所以本 store 只有 [SharedPreferences] 一条路，卸载/清数据即丢——
/// 这是刻意接受的取舍（要跨设备就自己导出，本轮不做）。
///
/// 与其他 store 一致的容错口径：**读失败一律降级成"一张能用的空表"、
/// 写失败静默**（本次内存生效，下次启动回到上次成功保存的值），
/// 任何情况都不抛——日程页是主页 PageView 的一页，store 抛异常会连累整个
/// App 启动。
class ScheduleStore {
  /// shared_preferences 存储 key。
  static const String storageKey = 'schedule:data_v1';

  /// 全局单例（日程页读写共用一份）。
  static final ScheduleStore instance = ScheduleStore();

  /// 取 SharedPreferences 的方式。**测试注入点**：默认走真实插件，
  /// 测试可传一个会抛的实现来验证"存储通道坏了也不抛"这条硬要求
  /// （不注入的话根本没法让 `SharedPreferences.getInstance()` 抛，
  /// 那条容错分支就永远没被实测过）。
  final Future<SharedPreferences> Function() _prefs;

  /// 公开构造：便于测试新建实例模拟"重启后重读同一份存储"。
  ScheduleStore({Future<SharedPreferences> Function()? prefs})
      : _prefs = prefs ?? SharedPreferences.getInstance;

  /// 读取日程表。**永不抛**，返回的一定是一张能直接用的表。
  ///
  /// 三种情形分开处理（这是本方法存在的全部意义）：
  /// - **本机存过且能解析** → 原样返回（哪怕它是空表——那是用户自己删空的）；
  /// - **本机压根没存过**（首次使用）→ 返回默认表 [ScheduleData.initial]
  ///   并**立刻落库**：列头日期锚在"本周一"，落库后就不会下次打开又跳一周；
  /// - **存过但坏了**（JSON 截断 / 结构全错 / 读取本身抛）→ 返回默认表，
  ///   但**不落库**：把坏数据留在盘上。万一是手改坏的，用户还有机会捞回来；
  ///   等他真的编辑了，新表自然会把它换掉。
  Future<ScheduleData> load() async {
    String? raw;
    try {
      final prefs = await _prefs();
      raw = prefs.getString(storageKey);
    } catch (_) {
      // 存储通道异常（原生插件缺失 / 读取失败）：给默认表，不落库，不抛
      debugPrint('[schedule] 本地日程读取失败，按首次使用处理');
      return ScheduleData.initial();
    }
    if (raw == null || raw.isEmpty) {
      // 首次使用：铺默认表并落库
      final seeded = ScheduleData.initial();
      await save(seeded);
      return seeded;
    }
    try {
      return ScheduleData.fromJson(jsonDecode(raw));
    } catch (_) {
      // JSON 本身坏了（截断 / 手改成非法 JSON）：给默认表但不覆盖原值
      debugPrint('[schedule] 本地日程 JSON 解析失败，按首次使用处理（不覆盖原值）');
      return ScheduleData.initial();
    }
  }

  /// 保存整张表（覆盖写）。写失败静默（本次已生效，下次启动回退）。
  Future<void> save(ScheduleData data) async {
    try {
      final prefs = await _prefs();
      await prefs.setString(storageKey, jsonEncode(data.toJson()));
    } catch (_) {
      // 写入失败静默
    }
  }

  /// 清空本地日程（测试 / 将来的"清空日程"入口用；页面本轮不暴露该入口）。
  Future<void> clear() async {
    try {
      final prefs = await _prefs();
      await prefs.remove(storageKey);
    } catch (_) {
      // 删除失败静默
    }
  }
}
