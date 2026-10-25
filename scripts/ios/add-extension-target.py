#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# 一次性工程改造：为 Runner.xcodeproj 增加 PacketTunnelProvider 网络扩展目标。
# 幂等：重复执行会先移除上一次添加的扩展目标再重建。
# 依赖：pip install pbxproj
import os
import re
import sys
import uuid

from pbxproj import XcodeProject
from pbxproj.PBXKey import PBXKey
import pbxproj

PROJECT = os.path.join(os.path.dirname(__file__), "..", "..", "ios", "Runner.xcodeproj", "project.pbxproj")

APP_BUNDLE_ID = "dev.proxypilot.proxypilot_mobile"
EXT_BUNDLE_ID = APP_BUNDLE_ID + ".PacketTunnelProvider"
EXT_NAME = "PacketTunnelProvider"
EXT_DIR = "PacketTunnelProvider"
VERSION = "1.1.0"
BUILD = "2"


def new_id():
    return uuid.uuid4().hex[:24].upper()


def main():
    project = XcodeProject.load(PROJECT)
    objs = project.objects

    def create(isa, **fields):
        cls = getattr(pbxproj, isa)
        obj = cls(objs)
        obj.parse({"isa": isa, **fields})
        oid = new_id()
        # 必须用 PBXKey 包裹 _id：纯 str 的 repr() 会带单引号，
        # 而 openstep_parser 只剥双引号，重载后键与引用对不上。
        obj["_id"] = PBXKey(oid, objs)
        objs[oid] = obj
        return oid

    def obj(oid):
        return objs[oid]

    # ---------- 0. 安全检查：已存在扩展目标则中止（一次性迁移脚本） ----------
    for t in objs.get_targets():
        if t.name == EXT_NAME:
            print(f"ERROR: target {EXT_NAME} already exists; restore project.pbxproj from backup first")
            return 1

    root = objs[project["rootObject"]]
    main_group = root.mainGroup
    runner = next(t for t in objs.get_targets() if t.name == "Runner")

    # ---------- 1. Bundle ID 规范化 ----------
    for t in objs.get_targets():
        bcl = objs[t.buildConfigurationList]
        for cid in bcl.buildConfigurations:
            bs = obj(cid)["buildSettings"]
            if bs is None:
                continue
            if bs.get("PRODUCT_BUNDLE_IDENTIFIER", None) == "dev.proxypilot.proxypilotMobile":
                bs["PRODUCT_BUNDLE_IDENTIFIER"] = APP_BUNDLE_ID

    # ---------- 2. 文件引用 ----------
    # 2a. Shared 组 + SharedBridge.swift
    shared_dir = os.path.join(os.path.dirname(PROJECT), "..", "..", "ios", "Shared")
    os.makedirs(shared_dir, exist_ok=True)
    shared_src = os.path.join(os.path.dirname(PROJECT), "..", "..", "ios", "SharedBridge.swift")
    if os.path.exists(shared_src) and not os.path.exists(os.path.join(shared_dir, "SharedBridge.swift")):
        os.rename(shared_src, os.path.join(shared_dir, "SharedBridge.swift"))
        print("moved SharedBridge.swift -> ios/Shared/")

    shared_group = create(
        "PBXGroup", children=[], name="Shared", path="Shared", sourceTree="<group>")
    shared_bridge_ref = create(
        "PBXFileReference", lastKnownFileType="sourcecode.swift",
        path="SharedBridge.swift", sourceTree="<group>")
    obj(shared_group).children.append(shared_bridge_ref)
    obj(main_group).children.append(shared_group)

    # 2b. Runner 组：VpnManager.swift / ProxyVpnPlugin.swift
    runner_group = next(
        g for g in [objs[c] for c in obj(main_group).children]
        if g.isa == "PBXGroup" and getattr(g, "path", None) == "Runner")
    for fname in ("VpnManager.swift", "ProxyVpnPlugin.swift"):
        src = os.path.join(os.path.dirname(PROJECT), "..", "..", "ios", fname)
        dst = os.path.join(os.path.dirname(PROJECT), "..", "..", "ios", "Runner", fname)
        if os.path.exists(src) and not os.path.exists(dst):
            os.rename(src, dst)
            print(f"moved {fname} -> ios/Runner/")
    runner_new_refs = {}
    for fname in ("VpnManager.swift", "ProxyVpnPlugin.swift"):
        ref = create(
            "PBXFileReference", lastKnownFileType="sourcecode.swift",
            path=fname, sourceTree="<group>")
        runner_group.children.append(ref)
        runner_new_refs[fname] = ref

    # 2c. PacketTunnelProvider 组
    ext_group = create(
        "PBXGroup", children=[], name=EXT_NAME, path=EXT_DIR, sourceTree="<group>")
    ext_file_refs = {}
    for fname, ftype in (
        ("PacketTunnelProvider.swift", "sourcecode.swift"),
        ("ExtensionPlatformInterface.swift", "sourcecode.swift"),
        ("Info.plist", "text.plist.xml"),
        ("PacketTunnelProvider.entitlements", "text.plist.entitlements"),
    ):
        ref = create(
            "PBXFileReference", lastKnownFileType=ftype, path=fname, sourceTree="<group>")
        obj(ext_group).children.append(ref)
        ext_file_refs[fname] = ref
    obj(main_group).children.append(ext_group)

    # 2d. Libbox.xcframework 引用（由 scripts/build-libbox-ios.sh 生成到 ios/ 下）
    libbox_ref = create(
        "PBXFileReference", explicitFileType="wrapper.xcframework",
        name="Libbox.xcframework", path="Libbox.xcframework", sourceTree="<group>")
    obj(main_group).children.append(libbox_ref)

    # 2e. NetworkExtension.framework（SDK 系统框架）
    ne_ref = create(
        "PBXFileReference", lastKnownFileType="wrapper.framework",
        name="NetworkExtension.framework",
        path="System/Library/Frameworks/NetworkExtension.framework",
        sourceTree="SDKROOT")

    # ---------- 3. 扩展目标构建阶段 ----------
    ext_sources = create("PBXSourcesBuildPhase", buildActionMask="2147483647",
                         files=[], runOnlyForDeploymentPostprocessing="0")
    ext_frameworks = create("PBXFrameworksBuildPhase", buildActionMask="2147483647",
                            files=[], runOnlyForDeploymentPostprocessing="0")
    ext_resources = create("PBXResourcesBuildPhase", buildActionMask="2147483647",
                           files=[], runOnlyForDeploymentPostprocessing="0")

    def add_build_file(phase_id, file_ref, **settings):
        bf = create("PBXBuildFile", fileRef=file_ref, **({"settings": settings} if settings else {}))
        obj(phase_id).files.append(bf)
        return bf

    add_build_file(ext_sources, ext_file_refs["PacketTunnelProvider.swift"])
    add_build_file(ext_sources, ext_file_refs["ExtensionPlatformInterface.swift"])
    add_build_file(ext_sources, shared_bridge_ref)
    add_build_file(ext_frameworks, libbox_ref)
    add_build_file(ext_frameworks, ne_ref)

    # ---------- 4. 扩展目标 ----------
    ext_debug = create("XCBuildConfiguration", buildSettings={
        "CLANG_ENABLE_MODULES": "YES",
        "CODE_SIGN_ENTITLEMENTS": f"{EXT_DIR}/{EXT_NAME}.entitlements",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": BUILD,
        "ENABLE_BITCODE": "NO",
        "INFOPLIST_FILE": f"{EXT_DIR}/Info.plist",
        "IPHONEOS_DEPLOYMENT_TARGET": "15.0",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"],
        "MARKETING_VERSION": VERSION,
        "PRODUCT_BUNDLE_IDENTIFIER": EXT_BUNDLE_ID,
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SDKROOT": "iphoneos",
        "SKIP_INSTALL": "YES",
        "SWIFT_VERSION": "5.0",
        "TARGETED_DEVICE_FAMILY": '"1,2"',
    }, name="Debug")
    ext_release = create("XCBuildConfiguration", buildSettings={
        "CLANG_ENABLE_MODULES": "YES",
        "CODE_SIGN_ENTITLEMENTS": f"{EXT_DIR}/{EXT_NAME}.entitlements",
        "CODE_SIGN_STYLE": "Automatic",
        "CURRENT_PROJECT_VERSION": BUILD,
        "ENABLE_BITCODE": "NO",
        "INFOPLIST_FILE": f"{EXT_DIR}/Info.plist",
        "IPHONEOS_DEPLOYMENT_TARGET": "15.0",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"],
        "MARKETING_VERSION": VERSION,
        "PRODUCT_BUNDLE_IDENTIFIER": EXT_BUNDLE_ID,
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SDKROOT": "iphoneos",
        "SKIP_INSTALL": "YES",
        "SWIFT_VERSION": "5.0",
        "TARGETED_DEVICE_FAMILY": '"1,2"',
    }, name="Release")
    ext_bcl = create("XCConfigurationList", buildConfigurations=[ext_debug, ext_release],
                     defaultConfigurationIsVisible="0",
                     defaultConfigurationName="Release")

    ext_product = create(
        "PBXFileReference", explicitFileType="wrapper.app-extension",
        includeInIndex="0", path=f"{EXT_NAME}.appex",
        sourceTree="BUILT_PRODUCTS_DIR")
    products_group = next(
        g for g in [objs[c] for c in obj(main_group).children]
        if g.isa == "PBXGroup" and getattr(g, "name", None) == "Products")
    products_group.children.append(ext_product)

    ext_target = create(
        "PBXNativeTarget", buildConfigurationList=ext_bcl,
        buildPhases=[ext_sources, ext_frameworks, ext_resources],
        buildRules=[], dependencies=[], name=EXT_NAME,
        productName=EXT_NAME, productReference=ext_product,
        productType="com.apple.product-type.app-extension")
    # 关键：必须把目标登记进 project.targets，否则 Xcode 不构建该扩展
    root["targets"] = list(root["targets"]) + [ext_target]

    # ---------- 5. Runner 目标增强 ----------
    runner_sources = next(objs[p] for p in runner.buildPhases
                          if objs[p].isa == "PBXSourcesBuildPhase")
    add_build_file(runner_sources._id, runner_new_refs["VpnManager.swift"])
    add_build_file(runner_sources._id, runner_new_refs["ProxyVpnPlugin.swift"])
    add_build_file(runner_sources._id, shared_bridge_ref)

    runner_frameworks = next(objs[p] for p in runner.buildPhases
                             if objs[p].isa == "PBXFrameworksBuildPhase")
    add_build_file(runner_frameworks._id, libbox_ref)

    # Runner entitlements 设置
    for cid in objs[runner.buildConfigurationList].buildConfigurations:
        obj(cid)["buildSettings"]["CODE_SIGN_ENTITLEMENTS"] = "Runner/Runner.entitlements"

    # ---------- 6. 嵌入阶段（appex + Libbox） ----------
    embed_ext = create(
        "PBXCopyFilesBuildPhase", buildActionMask="2147483647",
        dstPath="", dstSubfolderSpec="13", files=[],
        name="Embed Foundation Extensions", runOnlyForDeploymentPostprocessing="0")
    add_build_file(embed_ext, ext_product)
    # 插到 Thin Binary 之前
    phases = list(runner.buildPhases)
    insert_at = len(phases)
    for i, p in enumerate(phases):
        if getattr(objs[p], "name", None) == "Thin Binary":
            insert_at = i
            break
    phases.insert(insert_at, embed_ext)
    runner.buildPhases = phases

    embed_fw = next(objs[p] for p in runner.buildPhases
                    if objs[p].isa == "PBXCopyFilesBuildPhase"
                    and getattr(objs[p], "dstSubfolderSpec", None) == "10")
    add_build_file(embed_fw._id, libbox_ref, ATTRIBUTES=["CodeSignOnCopy"])

    # ---------- 7. 目标依赖 ----------
    container_proxy = create(
        "PBXContainerItemProxy", containerPortal=project["rootObject"],
        proxyType="1", remoteGlobalIDString=ext_target,
        remoteInfo=EXT_NAME)
    dep = create("PBXTargetDependency", target=ext_target,
                 targetProxy=container_proxy)
    runner.dependencies = list(runner.dependencies) + [dep]

    # ---------- 8. Project attributes ----------
    proj_obj = obj(project["rootObject"])
    attrs = proj_obj["attributes"]
    if attrs is None:
        attrs = pbxproj.PBXGenericObject(proj_obj)
        attrs.parse({})
        proj_obj["attributes"] = attrs
    ta = attrs["TargetAttributes"]
    if ta is None:
        ta = pbxproj.PBXGenericObject(attrs)
        ta.parse({})
        attrs["TargetAttributes"] = ta
    # 注意：不能直接塞 Python dict——__setitem__ 不走 parse，
    # 序列化会变成字符串字面量。必须包一层 PBXGenericObject。
    ext_attr = pbxproj.PBXGenericObject(ta)
    ext_attr.parse({"CreatedOnToolsVersion": "15.0"})
    ta[ext_target] = ext_attr

    project.save()
    print("saved:", PROJECT)


if __name__ == "__main__":
    sys.exit(main())
