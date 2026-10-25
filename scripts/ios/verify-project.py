#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""iOS 工程静态完整性校验：pbxproj 引用闭合 + 结构断言 + 磁盘文件存在性 + 往返重载。"""
import os
import re
import sys
import tempfile

from pbxproj import XcodeProject

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PROJECT = os.path.join(REPO, "ios", "Runner.xcodeproj", "project.pbxproj")

fails = []


def check(cond, msg):
    tag = "PASS" if cond else "FAIL"
    print(f"[{tag}] {msg}")
    if not cond:
        fails.append(msg)


def verify(path):
    project = XcodeProject.load(path)
    objs = project.objects
    check(len(objs.get_keys()) > 0, f"对象数 = {len(objs.get_keys())}")

    # ---- 1. 引用闭合：所有被引用 ID 均有定义 ----
    # 顶层对象定义固定为 2 个 tab 缩进；attributes.TargetAttributes 等嵌套键
    # 也用 24-hex 作键但缩进更深，必须排除，否则误报重复定义。
    text_ids = set(re.findall(
        r"^\t\t([0-9A-F]{24})(?:\s*/\*.*?\*/)?\s*=\s*\{", open(path).read(), re.M))
    registered = set(str(k) for k in objs.get_keys())
    missing_defs = registered - text_ids
    check(not missing_defs, f"内存注册对象均有文本定义（缺失 {len(missing_defs)}）")
    undef_text = text_ids - registered
    check(not undef_text, f"文本定义均已注册（未注册 {len(undef_text)}）")

    dangling = []
    for oid in list(objs.get_keys()):
        o = objs[oid]
        if o is None:
            dangling.append(oid)
            continue
        for attr in ("fileRef", "productRef", "productReference", "target",
                     "targetProxy", "containerPortal", "remoteGlobalIDString",
                     "buildConfigurationList", "mainGroup", "rootObject"):
            v = getattr(o, attr, None) if attr != "rootObject" else None
            if v is not None and re.fullmatch(r"[0-9A-F]{24}", str(v)):
                if objs[str(v)] is None:
                    dangling.append(f"{oid}.{attr} -> {v}")
        for attr in ("buildPhases", "buildConfigurations", "files", "children",
                     "dependencies"):
            lst = getattr(o, attr, None)
            if lst:
                for item in lst:
                    if re.fullmatch(r"[0-9A-F]{24}", str(item)) and objs[str(item)] is None:
                        dangling.append(f"{oid}.{attr} -> {item}")
    check(not dangling, f"无悬空引用（{len(dangling)} 个）")
    for d in dangling[:10]:
        print("       dangling:", d)

    # ---- 2. 目标结构 ----
    names = sorted(t.name for t in objs.get_targets())
    check(names == ["PacketTunnelProvider", "Runner", "RunnerTests"],
          f"目标集合 = {names}")

    ext = next((t for t in objs.get_targets() if t.name == "PacketTunnelProvider"), None)
    runner = next((t for t in objs.get_targets() if t.name == "Runner"), None)
    check(ext is not None and runner is not None, "Runner / 扩展目标均存在")
    if ext is None or runner is None:
        return project

    phases = [objs[p] for p in ext.buildPhases]
    isas = sorted(p.isa for p in phases)
    check(isas == ["PBXFrameworksBuildPhase", "PBXResourcesBuildPhase",
                   "PBXSourcesBuildPhase"], f"扩展构建阶段 = {isas}")

    srcs = [str(objs[f].fileRef) for f in phases if f.isa == "PBXSourcesBuildPhase"
            for f in objs[f].files] if False else None
    ext_src_phase = next(p for p in phases if p.isa == "PBXSourcesBuildPhase")
    ext_src_files = [objs[bf].fileRef for bf in ext_src_phase.files]
    ext_src_names = sorted(objs[r].path for r in ext_src_files)
    check(ext_src_names == ["ExtensionPlatformInterface.swift",
                            "PacketTunnelProvider.swift", "SharedBridge.swift"],
          f"扩展 Sources = {ext_src_names}")

    ext_fw_phase = next(p for p in phases if p.isa == "PBXFrameworksBuildPhase")
    ext_fw_refs = [objs[bf].fileRef for bf in ext_fw_phase.files]
    ext_fw_names = sorted(objs[r].name or objs[r].path for r in ext_fw_refs)
    check(ext_fw_names == ["Libbox.xcframework", "NetworkExtension.framework"],
          f"扩展 Frameworks = {ext_fw_names}")

    # ---- 3. Runner 增强 ----
    r_phases = [objs[p] for p in runner.buildPhases]
    r_src = next(p for p in r_phases if p.isa == "PBXSourcesBuildPhase")
    r_src_names = sorted(objs[objs[bf].fileRef].path
                         for bf in r_src.files
                         if getattr(objs[objs[bf].fileRef], "path", None))
    for need in ("VpnManager.swift", "ProxyVpnPlugin.swift", "SharedBridge.swift",
                 "AppDelegate.swift"):
        check(need in r_src_names, f"Runner Sources 含 {need}")

    embed_ext = [p for p in r_phases
                 if p.isa == "PBXCopyFilesBuildPhase" and p.name == "Embed Foundation Extensions"]
    check(len(embed_ext) == 1, "Runner 有 Embed Foundation Extensions 阶段")
    if embed_ext:
        ee = embed_ext[0]
        check(ee.dstSubfolderSpec == "13", "Embed Extensions dstSubfolderSpec = 13")
        check(ee.dstPath in ("", None), "Embed Extensions dstPath 为空")
        refs = [objs[bf].fileRef for bf in ee.files]
        check(len(refs) == 1 and objs[refs[0]].path == "PacketTunnelProvider.appex",
              "Embed Extensions 含 PacketTunnelProvider.appex")
        # 插入位置必须在 Thin Binary 之前
        names_in_order = [getattr(p, "name", None) or p.isa for p in r_phases]
        thin_idx = names_in_order.index("Thin Binary")
        check(names_in_order.index("Embed Foundation Extensions") < thin_idx,
              f"Embed Extensions 位于 Thin Binary 之前（{names_in_order}）")

    embed_fw = [p for p in r_phases if p.isa == "PBXCopyFilesBuildPhase"
                and p.name == "Embed Frameworks"]
    check(len(embed_fw) == 1, "Runner 有 Embed Frameworks 阶段")
    if embed_fw:
        for bf in embed_fw[0].files:
            bfo = objs[bf]
            r = objs[bfo.fileRef]
            if getattr(r, "name", None) == "Libbox.xcframework":
                attrs = (bfo.settings or {}).get("ATTRIBUTES", [])
                check("CodeSignOnCopy" in attrs,
                      f"Libbox 入 Embed Frameworks 带 CodeSignOnCopy（实际 {attrs}）")

    # ---- 4. 构建配置 ----
    for cid in objs[ext.buildConfigurationList].buildConfigurations:
        c = objs[cid]
        bs = c.buildSettings
        check(bs.get("CODE_SIGN_ENTITLEMENTS", None) == "PacketTunnelProvider/PacketTunnelProvider.entitlements",
              f"扩展 {c.name}: CODE_SIGN_ENTITLEMENTS")
        check(bs.get("INFOPLIST_FILE", None) == "PacketTunnelProvider/Info.plist",
              f"扩展 {c.name}: INFOPLIST_FILE")
        check(bs.get("PRODUCT_BUNDLE_IDENTIFIER", None) == "dev.proxypilot.proxypilot_mobile.PacketTunnelProvider",
              f"扩展 {c.name}: Bundle ID")
        check(bs.get("SKIP_INSTALL", None) == "YES", f"扩展 {c.name}: SKIP_INSTALL=YES")
        check(bs.get("IPHONEOS_DEPLOYMENT_TARGET", None) == "15.0", f"扩展 {c.name}: iOS 15.0")
        check("@executable_path/../../Frameworks" in (bs.get("LD_RUNPATH_SEARCH_PATHS", None) or []),
              f"扩展 {c.name}: rpath 含 ../../Frameworks")

    for cid in objs[runner.buildConfigurationList].buildConfigurations:
        c = objs[cid]
        check(c.buildSettings.get("CODE_SIGN_ENTITLEMENTS", None) == "Runner/Runner.entitlements",
              f"Runner {c.name}: CODE_SIGN_ENTITLEMENTS")
        check(c.buildSettings.get("PRODUCT_BUNDLE_IDENTIFIER", None) == "dev.proxypilot.proxypilot_mobile",
              f"Runner {c.name}: Bundle ID 规范化")

    # ---- 5. 依赖链 ----
    deps = [objs[d] for d in runner.dependencies]
    check(any(objs[objs[d.targetProxy].remoteGlobalIDString].name == "PacketTunnelProvider"
              for d in deps), "Runner 依赖 PacketTunnelProvider")

    # ---- 6. Products 组 ----
    root = objs[project["rootObject"]]
    main_group = objs[root.mainGroup]
    products = None
    for cid in main_group.children:
        g = objs[cid]
        if g is not None and g.isa == "PBXGroup" and getattr(g, "name", None) == "Products":
            products = g
    check(products is not None, "Products 组存在")
    if products:
        paths = [getattr(objs[c], "path", None) for c in products.children]
        check("PacketTunnelProvider.appex" in paths, f"Products 含 appex（{paths}）")

    # ---- 7. 磁盘文件 ----
    for rel in ("ios/Shared/SharedBridge.swift",
                "ios/Runner/VpnManager.swift",
                "ios/Runner/ProxyVpnPlugin.swift",
                "ios/PacketTunnelProvider/PacketTunnelProvider.swift",
                "ios/PacketTunnelProvider/ExtensionPlatformInterface.swift",
                "ios/PacketTunnelProvider/Info.plist",
                "ios/PacketTunnelProvider/PacketTunnelProvider.entitlements",
                "ios/Runner/Runner.entitlements"):
        check(os.path.exists(os.path.join(REPO, rel)), f"磁盘文件 {rel}")

    # ---- 8. 无残留单引号键 / 无重复 ID ----
    raw = open(path).read()
    check(not re.search(r"^\s*'[0-9A-F]{24}'\s*=", raw, re.M), "无单引号 24-hex 键")
    all_defs = re.findall(r"^\t\t([0-9A-F]{24})(?:\s*/\*.*?\*/)?\s*=\s*\{", raw, re.M)
    check(len(all_defs) == len(set(all_defs)),
          f"无重复 ID（{len(all_defs)} 个定义）")

    return project


def main():
    print("=" * 60)
    print("第一遍：加载与结构校验")
    print("=" * 60)
    verify(PROJECT)

    print()
    print("=" * 60)
    print("第二遍：往返重载（保存到临时文件后再校验）")
    print("=" * 60)
    with tempfile.TemporaryDirectory() as td:
        rt = os.path.join(td, "roundtrip.pbxproj")
        project = XcodeProject.load(PROJECT)
        project.save(rt)
        verify(rt)

    print()
    if fails:
        print(f"✗ {len(fails)} 项失败")
        return 1
    print("✓ 全部校验通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
