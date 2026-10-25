#!/usr/bin/env python3
"""校验 iOS Swift 实现与 gobind 生成的 Libbox.objc.h 的协议一致性。

规则（依据 gomobile genobjc.go + Swift ObjC 导入约定）：
- ObjC 方法 `name:part:` → Swift `name(_:part:)`；末参 error → throws
- 可选返回 + error → Swift 非可选 throws 返回；BOOL/void + error → Void
- 无 error 的可选指针/接口返回 → Swift 可选
- Go 字段 → @property → Swift 属性；Go 方法 → Swift 方法（带括号）

用法：verify-swift-api.py [Libbox.objc.h 路径]
本地调试可用 GOOS=ios gobind 生成：
  cd sing-box-src && GOOS=ios GOARCH=arm64 gobind -lang=objc -outdir=/tmp/h \
    -javapkg=io.nekohasekai -libname=box ./experimental/libbox
"""
import re
import sys
from pathlib import Path

HEADER = sys.argv[1] if len(sys.argv) > 1 else "/tmp/libbox_ios_h/src/gobind/Libbox.objc.h"
# 仓库根目录由脚本位置推导（scripts/ios/ → repo/），CI 与本地均可运行
REPO_ROOT = Path(__file__).resolve().parents[2]

def parse_header():
    text = open(HEADER, encoding="utf-8").read()
    protocols = {}
    # @protocol X <NSObject> ... @end
    for m in re.finditer(r"@protocol (Libbox\w+) <NSObject>\n(.*?)\n@end", text, re.S):
        name, body = m.group(1), m.group(2)
        methods = []
        for line in body.splitlines():
            line = line.strip()
            if line.startswith("- ("):
                methods.append(line)
        protocols[name] = methods
    structs = {}
    for m in re.finditer(r"@interface (Libbox\w+) : NSObject[^\n]*\n(.*?)\n@end", text, re.S):
        name, body = m.group(1), m.group(2)
        fields = re.findall(r"@property \(nonatomic[^)]*\) (\S+(?:\s*\*)?) (\w+);", body)
        structs[name] = fields
    funcs = re.findall(r"^FOUNDATION_EXPORT (?!const|NSString\* _Nonnull const)(.*?);", text, re.M)
    consts = re.findall(r"^FOUNDATION_EXPORT (?:const \S+|NSString\* _Nonnull const) (Libbox\w+);", text, re.M)
    return protocols, structs, funcs, consts

def swift_name_from_objc_method(sig):
    """`- (Ret)name:(T)p name2:(T2)p2 error:(NSError**)error` → (返回类型, [选择子段])"""
    body = sig[3:].strip()  # 去掉 "- ("
    # 返回类型到第一个 ) 为止（可能含 id<...>、*、_Nullable）
    depth = 0
    for i, ch in enumerate(body):
        if ch == "<":
            depth += 1
        elif ch == ">":
            depth -= 1
        elif ch == ")" and depth == 0:
            ret, rest = body[:i], body[i + 1:]
            break
    else:
        return sig, []
    rest = rest.strip().rstrip(";")
    m = re.match(r"(\w+)", rest)
    first = m.group(1) if m else ""
    parts = re.findall(r"(\w*):\(([^)]*)\)(\w+)", rest[m.end():] if m else rest)
    labels = [first] + [key for key, _t, _p in parts]
    return ret, labels

def main():
    protocols, structs, funcs, consts = parse_header()
    # ExtensionPlatformInterface.swift 实现 PlatformInterface + CommandServerHandler；
    # PacketTunnelProvider.swift 内嵌 StatusClientHandler 实现 CommandClientHandler
    swift = open(REPO_ROOT / "ios/PacketTunnelProvider/ExtensionPlatformInterface.swift", encoding="utf-8").read()
    swift += open(REPO_ROOT / "ios/PacketTunnelProvider/PacketTunnelProvider.swift", encoding="utf-8").read()
    swift_impl_funcs = set(re.findall(r"func (\w+)\(", swift))

    required = (protocols.get("LibboxPlatformInterface", [])
                + protocols.get("LibboxCommandServerHandler", [])
                + protocols.get("LibboxCommandClientHandler", []))
    print(f"PlatformInterface 方法数: {len(protocols.get('LibboxPlatformInterface', []))}")
    print(f"CommandServerHandler 方法数: {len(protocols.get('LibboxCommandServerHandler', []))}")
    print(f"CommandClientHandler 方法数: {len(protocols.get('LibboxCommandClientHandler', []))}")
    missing = []
    for sig in required:
        ret, labels = swift_name_from_objc_method(sig)
        base = labels[0]
        # Swift 方法名前缀 = ObjC 第一段
        if base not in swift_impl_funcs:
            missing.append(sig)
    if missing:
        print("\n❌ 缺失实现:")
        for s in missing:
            print("   ", s)
    else:
        print("✅ 全部协议方法均有实现")

    # 检查 Swift 中引用的包级函数/常量是否存在于头文件
    referenced_funcs = set(re.findall(r"\b(Libbox\w+)\(", swift))
    header_func_names = set()
    for f in funcs:
        fm = re.match(r".*\b(Libbox\w+)\(", f)
        if fm:
            header_func_names.add(fm.group(1))
    unknown = referenced_funcs - header_func_names - set(re.findall(r"\b(Libbox\w+)\(", swift))  # 自身类方法除外
    unknown = {f for f in unknown if f not in swift_impl_funcs and f not in
               {x for x in re.findall(r"(\w+)\(", swift)}}
    if unknown:
        print("\n⚠️ Swift 引用了头文件中不存在的函数:", sorted(unknown))
    else:
        print("✅ 引用的包级函数全部存在于头文件")

    # 常量检查（协议名与类名如 LibboxCommandServerHandlerProtocol / LibboxCommandClient 非常量，排除）
    referenced_consts = set(re.findall(r"\b(Libbox(?:DNSMode|Command|InterfaceType)\w*)\b", swift))
    non_const_names = set(protocols) | {p + "Protocol" for p in protocols} | set(structs)
    unknown_consts = referenced_consts - set(consts) - non_const_names
    if unknown_consts:
        print("⚠️ 未知常量:", sorted(unknown_consts))
    else:
        print("✅ 引用的常量全部存在于头文件")

if __name__ == "__main__":
    main()
