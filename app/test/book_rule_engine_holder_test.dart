// 引擎宿主测试（R3）：`buildHost()` 必须自己把引擎带起来。
//
// 为什么单独验这一件事：搜索页只在点「搜索」时才第一次取 `engine`，若
// `buildHost()` 读的是裸字段，首帧会拿到 `SizedBox.shrink()`，WebView 要等
// 下一次 setState 才进树 —— 「点了搜索但引擎还没挂上」的隐性时序 bug 不会
// 报错，只会表现为第一次搜索莫名其妙地慢 / 失败。
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bili_whitelist_app/services/book_rule/engine_holder.dart';
import 'package:bili_whitelist_app/services/book_rule/rule_engine.dart';

void main() {
  test('构造后不建引擎（懒建），buildHost() 会把引擎建出来', () {
    var created = 0;
    final holder = RuleEngineHolder(engineFactory: () {
      created++;
      return FakeRuleEngine();
    });

    // 构造本身不能建引擎：打开 App 就建 WebView 是明确要避免的
    expect(created, 0);
    expect(holder.hasWebViewEngine, isFalse);

    // 这里就是修复点：页面首帧 build 之前没取过 engine，也要拿到真宿主
    final widget = holder.buildHost();
    expect(created, 1);
    // 假引擎不碰原生接口，给一个空盒子占位
    expect(widget, isA<SizedBox>());
    expect((widget as SizedBox).width, 0);

    // 再 build 一次不重复建
    holder.buildHost();
    expect(created, 1);
  });

  test('已释放的宿主 buildHost() 返回空盒子，不在 build 期抛异常', () async {
    final holder = RuleEngineHolder.withEngine(FakeRuleEngine());
    await holder.dispose();
    expect(holder.buildHost(), isA<SizedBox>());
  });
}
