#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
TiebaLite iOS 15 移植 · 静态自查（跨平台：macOS / Linux / Windows 都能跑）

作用：在没有 Xcode 的机器上，把「部署底线降到 15.0 之后会编译不过的点」先扫出来。
原理：Swift 的可用性检查只有编译器说了算，但「用了 iOS >= 16/17/18/26 才有的 API，
而外面没有 #available(iOS N, *) 或 @available(iOS N, *) 兜住」这件事可以静态判定 ——
这种位置在 min 15.0 下必然是编译错误，扫出来就是待补的清单。

用法：
    python3 scripts/verify-port.py              # 只报「未兜住」的命中
    python3 scripts/verify-port.py --all        # 连已兜住的命中一起打印
    python3 scripts/verify-port.py --self-test  # 用内置样例验证扫描器本身没坏

退出码：0 = 全部兜住；1 = 有未兜住的命中（附文件:行号）。

可选：装了 tree_sitter + tree_sitter_swift 时会顺带做一遍语法解析
（本仓 768 个 .swift 在上游基线上有 8 个文件报 parser 误报，均为 tree-sitter 语法缺口，
故语法解析只作为「改动没引入新错」的对比参考，不参与退出码）。
"""

import argparse
import os
import re
import sys

# Windows 控制台默认 GBK，打印中文/破折号会炸；统一成 UTF-8 + 替换非法字符。
try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

# 已从 //:App 目标摘除的目录：里面的代码不参与 app 构建，扫描时跳过。
# （Extensions/TiebaLiveActivity 是 ActivityKit 扩展，移植版不内嵌；保留源码只为将来恢复）
SKIP_PATHS = ['Extensions' + os.sep + 'TiebaLiveActivity']

# ── 需要兜住的 API 表 ────────────────────────────────────────────────────────
# (正则, 起始 iOS 版本, 说明)
# 只收「本仓真的用到过 / 同类 UIKit 客户端几乎一定会用」的系统件；宁可少收也不要错收。
API = [
    # SwiftUI（本仓是 UIKit 客户端，这几条用于防止后续混入 SwiftUI）
    (r'(?<![\w.])NavigationStack\b', '16.0', 'SwiftUI NavigationStack'),
    (r'(?<![\w.])NavigationPath\b', '16.0', 'SwiftUI NavigationPath'),
    (r'\.presentationDetents\b', '16.0', 'SwiftUI presentationDetents'),
    (r'\.presentationBackground\b', '16.4', 'SwiftUI presentationBackground'),
    (r'\.presentationCornerRadius\b', '16.4', 'SwiftUI presentationCornerRadius'),
    (r'\.scrollContentBackground\b', '16.0', 'SwiftUI scrollContentBackground'),
    (r'\.toolbarBackground\b', '16.0', 'SwiftUI toolbarBackground'),
    (r'\.toolbarRole\b', '16.0', 'SwiftUI toolbarRole'),
    (r'(?<![\w])ShareLink\b', '16.0', 'SwiftUI ShareLink'),
    (r'(?<![\w])LabeledContent\b', '16.0', 'SwiftUI LabeledContent'),
    (r'(?<![\w])ViewThatFits\b', '16.0', 'SwiftUI ViewThatFits'),
    (r'\.contentTransition\b', '16.0', 'SwiftUI contentTransition'),
    (r'\.scrollDisabled\b', '16.0', 'SwiftUI scrollDisabled'),
    (r'\.scrollBounceBehavior\b', '16.4', 'SwiftUI scrollBounceBehavior'),
    (r'\.symbolEffect\b', '17.0', 'SwiftUI symbolEffect'),
    (r'\.scrollTargetBehavior\b', '17.0', 'SwiftUI scrollTargetBehavior'),
    (r'\.scrollPosition\b', '17.0', 'SwiftUI scrollPosition（注意：本仓 scrollDirection.scrollPosition 是自有属性）'),
    (r'\.contentMargins\b', '17.0', 'SwiftUI contentMargins'),
    (r'\.containerRelativeFrame\b', '17.0', 'SwiftUI containerRelativeFrame'),
    (r'\.inspector\b', '17.0', 'SwiftUI inspector'),
    (r'\.sensoryFeedback\b', '17.0', 'SwiftUI sensoryFeedback'),
    (r'\.phaseAnimator\b', '17.0', 'SwiftUI phaseAnimator'),
    (r'\.onGeometryChange\b', '18.0', 'SwiftUI onGeometryChange'),
    (r'(?<![\w])ContentUnavailableView\b', '17.0', 'SwiftUI ContentUnavailableView'),
    # UIKit：空态 / trait / 编辑菜单 / 文本交互
    (r'(?<![\w])UIContentUnavailable', '17.0', 'UIContentUnavailableView/Configuration'),
    (r'(?<![\w])registerForTraitChanges\b', '17.0', 'UIView.registerForTraitChanges'),
    (r'(?<![\w])UITraitChangeRegistration\b', '17.0', 'UITraitChangeRegistration'),
    (r'(?<![\w])UITraitOverrides\b', '17.0', 'UITraitOverrides'),
    (r'(?<![\w])UIEditMenuInteraction\b', '16.0', 'UIEditMenuInteraction'),
    (r'(?<![\w])UIEditMenu\w*', '16.0', 'UIEditMenu*'),
    (r'(?<![\w])UITextItem\b', '17.0', 'UITextItem'),
    (r'editMenuForTextIn', '16.0', 'UITextViewDelegate.editMenuForTextIn'),
    (r'primaryActionFor', '17.0', 'UITextViewDelegate.primaryActionFor'),
    (r'(?<![\w])UIHostingConfiguration\b', '16.0', 'UIHostingConfiguration'),
    (r'(?<![\w])UIFont\.Width\b', '16.0', 'UIFont.Width'),
    (r'TraitKey\.width', '16.0', 'UIFontDescriptor.TraitKey.width'),
    (r'\.width\(\.(condensed|expanded|compressed)', '16.0', 'UIFont.Width 字宽'),
    (r'\.effectiveGeometry\b', '16.0', 'UIWindowScene.effectiveGeometry'),
    (r'(?<![\w])UIWindowSceneGeometry\b', '16.0', 'UIWindowSceneGeometry'),
    (r'\.custom\(identifier:', '16.0', 'UISheetPresentationController.Detent.custom'),
    (r'(?<![\w])UIFindInteraction\b', '16.0', 'UIFindInteraction'),
    (r'(?<![\w])UICalendarView\b', '16.0', 'UICalendarView'),
    (r'\.sizingOptions\b', '16.0', 'UIHostingController.sizingOptions'),
    (r'(?<![\w])ImageRenderer\b', '16.0', 'SwiftUI ImageRenderer'),
    # 框架 / 并发 / 语言设施
    (r'(?<![\w])import ActivityKit', '16.1', 'ActivityKit'),
    (r'(?<![\w])import AppIntents', '16.0', 'AppIntents'),
    (r'(?<![\w])import Charts', '16.0', 'Charts'),
    (r'(?<![\w])import SwiftData', '17.0', 'SwiftData'),
    (r'(?<![\w])import Observation', '17.0', 'Observation'),
    (r'Task\.sleep\(for:', '16.0', 'Task.sleep(for:)'),
    # iOS 26 液态玻璃（移植版一律关掉；开关是 TiebaGlass.isEnabled）
    (r'\.glassEffect\b', '26.0', 'SwiftUI glassEffect'),
    (r'(?<![\w])GlassEffectContainer\b', '26.0', 'GlassEffectContainer'),
    (r'\.glass\(\)', '26.0', 'UIButton.Configuration.glass()'),
    (r'\.prominentGlass\(\)', '26.0', 'UIButton.Configuration.prominentGlass()'),
    (r'\.clearGlass\(\)', '26.0', 'UIButton.Configuration.clearGlass()'),
    (r'\.glassProminent\b', '26.0', 'glassProminent'),
    (r'(?<![\w])UIGlassEffect\b', '26.0', 'UIGlassEffect'),
    (r'(?<![\w])UIGlassContainerEffect\b', '26.0', 'UIGlassContainerEffect'),
]

# 已知误报（名字撞车，不是系统 API）
ALLOW = [
    # JXPhotoBrowser 的 ScrollDirection.scrollPosition（自有属性）
    re.compile(r'\.scrollPosition\b'),
]

GUARD_AVAILABLE = re.compile(r'#available\(iOS\s+([0-9]+(?:\.[0-9]+)?)')
GUARD_ATTR = re.compile(r'@available\(iOS\s+([0-9]+(?:\.[0-9]+)?)')
LOOKBACK = 60


def ver(s):
    p = [int(x) for x in s.split('.')[:2]]
    while len(p) < 2:
        p.append(0)
    return tuple(p)


def strip_comments(text):
    """把 // 与 /* */ 注释、字符串字面量抹成空格（保留换行与列宽），避免注释里提到 API 名就误报。"""
    out, i, n = [], 0, len(text)
    in_block = in_line = in_str = False
    while i < n:
        c, two = text[i], text[i:i + 2]
        if in_block:
            if two == '*/':
                in_block = False; out.append('  '); i += 2; continue
            if two == '/*':
                in_block = True; out.append('  '); i += 2; continue
            out.append('\n' if c == '\n' else ' '); i += 1; continue
        if in_line:
            if c == '\n':
                in_line = False; out.append('\n')
            else:
                out.append(' ')
            i += 1; continue
        if in_str:
            if c == '\\':
                out.append('  '); i += 2; continue
            if c == '"':
                in_str = False
            out.append('\n' if c == '\n' else ' '); i += 1; continue
        if two == '//':
            in_line = True; out.append('  '); i += 2; continue
        if two == '/*':
            in_block = True; out.append('  '); i += 2; continue
        if c == '"':
            in_str = True; out.append(' '); i += 1; continue
        out.append(c); i += 1
    return ''.join(out)


def scan(root, show_all=False):
    rules = [(re.compile(p), v, d) for p, v, d in API]
    hits = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in ('.git', 'build', 'dist', 'bazel-out')]
        for name in filenames:
            if not name.endswith('.swift'):
                continue
            path = os.path.join(dirpath, name)
            if any(skip in path for skip in SKIP_PATHS):
                continue
            raw = open(path, encoding='utf-8', errors='replace').read()
            code = strip_comments(raw)
            code_lines = code.split('\n')
            raw_lines = raw.split('\n')
            rel = os.path.relpath(path, root)
            for idx, line in enumerate(code_lines):
                for rx, minv, desc in rules:
                    m = rx.search(line)
                    if not m:
                        continue
                    lo = max(0, idx - LOOKBACK)
                    window = '\n'.join(code_lines[lo:idx + 1])
                    guards = [ver(x) for x in GUARD_AVAILABLE.findall(window)]
                    guards += [ver(x) for x in GUARD_ATTR.findall(window)]
                    guarded = any(g >= ver(minv) for g in guards)
                    if not guarded and any(a.search(m.group(0)) for a in ALLOW):
                        guarded = True
                    hits.append({
                        'file': rel, 'line': idx + 1, 'token': m.group(0),
                        'min': minv, 'desc': desc, 'guarded': guarded,
                        'text': raw_lines[idx].strip() if idx < len(raw_lines) else '',
                    })
    bad = [h for h in hits if not h['guarded']]
    print('扫描 .swift 文件命中：%d 处；已兜住：%d；**未兜住：%d**'
          % (len(hits), len(hits) - len(bad), len(bad)))
    if bad:
        print('\n未兜住的命中（min 15.0 下会编译不过，必须补 #available/@available）：')
        for h in bad:
            print('  %s:%d  [%s >= iOS %s]  %s' % (h['file'], h['line'], h['token'], h['min'], h['text'][:110]))
    if show_all:
        print('\n全部命中：')
        for h in hits:
            print('  %s%s:%d  %s >= %s  (%s)' % ('[OK] ' if h['guarded'] else '[!!] ',
                                                h['file'], h['line'], h['token'], h['min'], h['desc']))
    return bad


def syntax_check(root):
    try:
        import tree_sitter
        import tree_sitter_swift
    except ImportError:
        print('（跳过语法解析：未安装 tree_sitter / tree_sitter_swift）')
        return
    lang = tree_sitter.Language(tree_sitter_swift.language())
    parser = tree_sitter.Parser(lang)
    total, bad = 0, []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in ('.git', 'build', 'dist', 'bazel-out')]
        for name in filenames:
            if name.endswith('.swift'):
                p = os.path.join(dirpath, name)
                total += 1
                tree = parser.parse(open(p, 'rb').read())
                if tree.root_node.has_error:
                    bad.append(os.path.relpath(p, root))
    print('语法解析：%d 个文件，%d 个报错（上游基线本身有 8 个 tree-sitter 误报，比对用）'
          % (total, len(bad)))
    for b in bad:
        print('   ', b)


def self_test():
    """用内置样例确认扫描器能区分「兜住」与「没兜住」。"""
    import tempfile
    cases = {
        'ok_guard.swift': 'func f() {\n  if #available(iOS 17.0, *) {\n    let v = UIContentUnavailableView()\n  }\n}\n',
        'ok_attr.swift': '@available(iOS 16.0, *)\nfunc f(_ x: UIEditMenuInteraction) {}\n',
        'bad_plain.swift': 'func f() {\n  let v = UIContentUnavailableView()\n}\n',
        'ok_comment.swift': '// UIContentUnavailableView 在 17 起\nfunc f() {}\n',
        'ok_ownprop.swift': 'let a = scrollDirection.scrollPosition\n',
    }
    expect = {'ok_guard.swift': 0, 'ok_attr.swift': 0, 'bad_plain.swift': 1,
              'ok_comment.swift': 0, 'ok_ownprop.swift': 0}
    with tempfile.TemporaryDirectory() as tmp:
        for name, body in cases.items():
            open(os.path.join(tmp, name), 'w', encoding='utf-8').write(body)
        bad = scan(tmp)
    got = {}
    for b in bad:
        got[b['file']] = got.get(b['file'], 0) + 1
    failed = False
    for name, n in expect.items():
        g = got.get(name, 0)
        flag = 'OK ' if g == n else 'FAIL'
        if g != n:
            failed = True
        print('  [%s] %s：期望 %d，实际 %d' % (flag, name, n, g))
    print('self-test:', 'FAILED' if failed else 'PASSED')
    return 1 if failed else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    ap.add_argument('--all', action='store_true', help='连已兜住的命中一起打印')
    ap.add_argument('--self-test', action='store_true', help='用内置样例验证扫描器')
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    root = os.path.abspath(args.root)
    print('根目录：', root)
    bad = scan(root, show_all=args.all)
    syntax_check(root)
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
