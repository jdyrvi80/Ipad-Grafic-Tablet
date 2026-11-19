#!/usr/bin/env python3
"""
Genera iPadGraphicTablet.xcodeproj senza strumenti esterni.

Il progetto incluso nello zip è già generato: questo script serve solo se
aggiungi o rinomini file Swift e non vuoi usare XcodeGen (project.yml).

    python3 Tools/generate_xcodeproj.py

Target:
  • TabletMac        — app macOS (Mac/ + Shared/Sources/*)
  • TabletPad        — app iPadOS (iPad/ + Shared/Sources/*)
  • TabletCoreTests  — test unitari macOS (Shared/Tests + Shared/Sources/TabletCore)
"""

import hashlib
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT = os.path.join(ROOT, "iPadGraphicTablet.xcodeproj")


def oid(*parts):
    """ID deterministico a 24 cifre esadecimali."""
    return hashlib.md5("|".join(parts).encode()).hexdigest()[:24].upper()


def q(value):
    """Quota sempre le stringhe: è sempre valido nel formato pbxproj."""
    if isinstance(value, list):
        return "(" + "".join(f"\n\t\t\t\t\t{q(v)}," for v in value) + "\n\t\t\t\t)"
    s = str(value).replace("\\", "\\\\").replace('"', '\\"')
    return f'"{s}"'


FILE_TYPES = {
    ".swift": "sourcecode.swift",
    ".plist": "text.plist.xml",
    ".entitlements": "text.plist.entitlements",
    ".md": "net.daringfireball.markdown",
    ".yml": "text.yaml",
    ".html": "text.html",
    ".png": "image.png",
    ".xcassets": "folder.assetcatalog",
}

objects = {}          # id -> (sezione, testo)
file_refs = {}        # percorso relativo -> id


def add(section, ident, body, comment=""):
    c = f" /* {comment} */" if comment else ""
    objects[ident] = (section, f"\t\t{ident}{c} = {body};\n")


def file_ref(rel_path):
    if rel_path in file_refs:
        return file_refs[rel_path]
    ident = oid("fileref", rel_path)
    name = os.path.basename(rel_path)
    ext = os.path.splitext(name)[1]
    ftype = FILE_TYPES.get(ext, "text")
    add("PBXFileReference", ident,
        f'{{isa = PBXFileReference; lastKnownFileType = {ftype}; path = {q(name)}; sourceTree = "<group>"; }}', name)
    file_refs[rel_path] = ident
    return ident


# ---------------------------------------------------------------- gruppi

group_children = {}   # percorso gruppo -> [id figli]
group_ids = {}


def group_id(rel_dir):
    if rel_dir not in group_ids:
        group_ids[rel_dir] = oid("group", rel_dir)
        group_children[rel_dir] = []
    return group_ids[rel_dir]


resources = {}   # gruppo radice -> file risorsa


def register_tree(rel_dir, extensions):
    """Registra ricorsivamente file e sottogruppi; restituisce i .swift trovati."""
    gid = group_id(rel_dir)
    swift_files = []
    abs_dir = os.path.join(ROOT, rel_dir)
    for entry in sorted(os.listdir(abs_dir)):
        if entry.startswith("."):
            continue
        rel = os.path.join(rel_dir, entry)
        if entry.endswith(".xcassets"):
            # Catalogo risorse (icona dell'app): una sola voce, compilata da actool.
            ref = file_ref(rel)
            if ref not in group_children[rel_dir]:
                group_children[rel_dir].append(ref)
            resources.setdefault(rel.split("/")[0], []).append(rel)
            continue
        if os.path.isdir(os.path.join(ROOT, rel)):
            sub_files = register_tree(rel, extensions)
            child = group_id(rel)
            if child not in group_children[rel_dir]:
                group_children[rel_dir].append(child)
            swift_files += sub_files
        elif os.path.splitext(entry)[1] in extensions:
            ref = file_ref(rel)
            if ref not in group_children[rel_dir]:
                group_children[rel_dir].append(ref)
            if entry.endswith(".swift"):
                swift_files.append(rel)
            elif os.path.splitext(entry)[1] in resource_exts:
                resources.setdefault(rel.split("/")[0], []).append(rel)
    return swift_files


exts = {".swift", ".plist", ".entitlements", ".html", ".png"}
resource_exts = {".html", ".png"}
mac_files = register_tree("Mac", exts)
pad_files = register_tree("iPad", exts)
core_files = register_tree("Shared/Sources/TabletCore", exts)
link_files = register_tree("Shared/Sources/TabletLink", exts)
test_files = register_tree("Shared/Tests/TabletCoreTests", exts)

# Gruppi intermedi Shared/Sources e Shared/Tests
for parent, child in [("Shared/Sources", "Shared/Sources/TabletCore"), ("Shared/Sources", "Shared/Sources/TabletLink"),
                      ("Shared/Tests", "Shared/Tests/TabletCoreTests"), ("Shared", "Shared/Sources"),
                      ("Shared", "Shared/Tests")]:
    group_id(parent)
    cid = group_id(child)
    if cid not in group_children[parent]:
        group_children[parent].append(cid)

docs = [f for f in ["README.md", "project.yml"] if os.path.exists(os.path.join(ROOT, f))]
for d in sorted(os.listdir(os.path.join(ROOT, "docs"))) if os.path.isdir(os.path.join(ROOT, "docs")) else []:
    if d.endswith(".md"):
        docs.append(os.path.join("docs", d))
group_id("docs")
for d in docs:
    if d.startswith("docs/"):
        group_children["docs"].append(file_ref(d))

# ---------------------------------------------------------------- prodotti

products = {
    "TabletMac": ("iPad Graphic Tablet.app", "wrapper.application"),
    "TabletPad": ("Graphic Tablet.app", "wrapper.application"),
    "TabletCoreTests": ("TabletCoreTests.xctest", "wrapper.cfbundle"),
}
product_refs = {}
for target, (name, ftype) in products.items():
    ident = oid("product", target)
    product_refs[target] = ident
    add("PBXFileReference", ident,
        f"{{isa = PBXFileReference; explicitFileType = {ftype}; includeInIndex = 0; path = {q(name)}; sourceTree = BUILT_PRODUCTS_DIR; }}",
        name)

# ---------------------------------------------------------------- build settings

COMMON_PROJECT = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "CLANG_ANALYZER_NONNULL": "YES",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "CLANG_WARN_DOCUMENTATION_COMMENTS": "YES",
    "COPY_PHASE_STRIP": "NO",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
    "GCC_C_LANGUAGE_STANDARD": "gnu17",
    "GCC_NO_COMMON_BLOCKS": "YES",
    "SWIFT_VERSION": "5.0",
    "SWIFT_STRICT_CONCURRENCY": "minimal",
    "MARKETING_VERSION": "1.0.0",
    "CURRENT_PROJECT_VERSION": "1",
    "CODE_SIGN_STYLE": "Automatic",
    "DEVELOPMENT_TEAM": "",
    "MACOSX_DEPLOYMENT_TARGET": "14.0",
    "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
    "LOCALIZATION_PREFERS_STRING_CATALOGS": "YES",
}
DEBUG_PROJECT = {
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_TESTABILITY": "YES",
    "GCC_DYNAMIC_NO_PIC": "NO",
    "GCC_OPTIMIZATION_LEVEL": "0",
    "GCC_PREPROCESSOR_DEFINITIONS": ["DEBUG=1", "$(inherited)"],
    "ONLY_ACTIVE_ARCH": "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
    "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
}
RELEASE_PROJECT = {
    "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
    "ENABLE_NS_ASSERTIONS": "NO",
    "SWIFT_COMPILATION_MODE": "wholemodule",
    "SWIFT_OPTIMIZATION_LEVEL": "-O",
}

TARGET_SETTINGS = {
    "TabletMac": {
        "SDKROOT": "macosx",
        "PRODUCT_NAME": "iPad Graphic Tablet",
        "PRODUCT_MODULE_NAME": "TabletMac",
        "PRODUCT_BUNDLE_IDENTIFIER": "com.jodyriva.ipadtablet.mac",
        "INFOPLIST_FILE": "Mac/Resources/Info.plist",
        "GENERATE_INFOPLIST_FILE": "NO",
        "CODE_SIGN_ENTITLEMENTS": "Mac/Resources/TabletMac.entitlements",
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "CODE_SIGN_IDENTITY": "-",
        "ENABLE_HARDENED_RUNTIME": "YES",
        "COMBINE_HIDPI_IMAGES": "YES",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks"],
    },
    "TabletPad": {
        "SDKROOT": "iphoneos",
        "PRODUCT_NAME": "Graphic Tablet",
        "PRODUCT_MODULE_NAME": "TabletPad",
        "PRODUCT_BUNDLE_IDENTIFIER": "com.jodyriva.ipadtablet.pad",
        "INFOPLIST_FILE": "iPad/Resources/Info.plist",
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "GENERATE_INFOPLIST_FILE": "NO",
        "TARGETED_DEVICE_FAMILY": "2",
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
        "SUPPORTS_MACCATALYST": "NO",
        "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
        "SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD": "NO",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks"],
    },
    "TabletCoreTests": {
        "SDKROOT": "macosx",
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "PRODUCT_BUNDLE_IDENTIFIER": "com.jodyriva.ipadtablet.tests",
        "GENERATE_INFOPLIST_FILE": "YES",
        "CODE_SIGN_IDENTITY": "-",
        "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/../Frameworks", "@loader_path/../Frameworks"],
    },
}
RELEASE_EXTRA = {"TabletPad": {"VALIDATE_PRODUCT": "YES"}}


def settings_block(d):
    lines = "".join(f"\t\t\t\t{q(k) if not k.replace('_', '').isalnum() else k} = {q(v)};\n"
                    for k, v in sorted(d.items()))
    return "{\n" + lines + "\t\t\t}"


def config_list(owner, settings_debug, settings_release, comment):
    d_id, r_id, l_id = oid("cfg", owner, "Debug"), oid("cfg", owner, "Release"), oid("cfglist", owner)
    add("XCBuildConfiguration", d_id,
        f"{{isa = XCBuildConfiguration; buildSettings = {settings_block(settings_debug)}; name = Debug; }}", "Debug")
    add("XCBuildConfiguration", r_id,
        f"{{isa = XCBuildConfiguration; buildSettings = {settings_block(settings_release)}; name = Release; }}", "Release")
    add("XCConfigurationList", l_id,
        f"{{isa = XCConfigurationList; buildConfigurations = ({d_id} /* Debug */, {r_id} /* Release */, ); "
        f"defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }}",
        f"Build configuration list for {comment}")
    return l_id


# ---------------------------------------------------------------- target

target_sources = {
    "TabletMac": mac_files + core_files + link_files,
    "TabletPad": pad_files + core_files + link_files,
    "TabletCoreTests": test_files + core_files,
}
product_types = {
    "TabletMac": "com.apple.product-type.application",
    "TabletPad": "com.apple.product-type.application",
    "TabletCoreTests": "com.apple.product-type.bundle.unit-test",
}

target_ids = {}
for target, files in target_sources.items():
    build_files = []
    for rel in files:
        bf = oid("buildfile", target, rel)
        ref = file_refs[rel]
        name = os.path.basename(rel)
        add("PBXBuildFile", bf, f"{{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }}", f"{name} in Sources")
        build_files.append(f"{bf} /* {name} in Sources */")
    src_phase = oid("sources", target)
    add("PBXSourcesBuildPhase", src_phase,
        "{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (" +
        "".join(f"\n\t\t\t\t{b}," for b in build_files) +
        "\n\t\t\t); runOnlyForDeploymentPostprocessing = 0; }", "Sources")
    fw_phase = oid("frameworks", target)
    add("PBXFrameworksBuildPhase", fw_phase,
        "{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ( ); runOnlyForDeploymentPostprocessing = 0; }",
        "Frameworks")
    res_phase = oid("resources", target)
    res_files = []
    root = {"TabletMac": "Mac", "TabletPad": "iPad"}.get(target)
    for rel in resources.get(root, []):
        bf = oid("resfile", target, rel)
        name = os.path.basename(rel)
        add("PBXBuildFile", bf, f"{{isa = PBXBuildFile; fileRef = {file_refs[rel]} /* {name} */; }}", f"{name} in Resources")
        res_files.append(f"{bf} /* {name} in Resources */")
    add("PBXResourcesBuildPhase", res_phase,
        "{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (" +
        "".join(f"\n\t\t\t\t{b}," for b in res_files) +
        "\n\t\t\t); runOnlyForDeploymentPostprocessing = 0; }", "Resources")

    debug = dict(TARGET_SETTINGS[target])
    release = dict(TARGET_SETTINGS[target])
    release.update(RELEASE_EXTRA.get(target, {}))
    cl = config_list(target, debug, release, f'PBXNativeTarget "{target}"')

    tid = oid("target", target)
    target_ids[target] = tid
    add("PBXNativeTarget", tid,
        f"{{isa = PBXNativeTarget; buildConfigurationList = {cl}; "
        f"buildPhases = ({src_phase} /* Sources */, {fw_phase} /* Frameworks */, {res_phase} /* Resources */, ); "
        f"buildRules = ( ); dependencies = ( ); name = {target}; productName = {target}; "
        f"productReference = {product_refs[target]}; productType = {q(product_types[target])}; }}", target)

# ---------------------------------------------------------------- gruppi principali

products_group = oid("group", "Products")
add("PBXGroup", products_group,
    "{isa = PBXGroup; children = (" + "".join(f"\n\t\t\t\t{product_refs[t]}," for t in products) +
    '\n\t\t\t); name = Products; sourceTree = "<group>"; }', "Products")

for rel_dir, gid in group_ids.items():
    name = os.path.basename(rel_dir)
    children = "".join(f"\n\t\t\t\t{c}," for c in group_children[rel_dir])
    add("PBXGroup", gid,
        f'{{isa = PBXGroup; children = ({children}\n\t\t\t); path = {q(name)}; sourceTree = "<group>"; }}', name)

main_group = oid("group", "<main>")
top_level = [file_ref(d) for d in docs if "/" not in d] + [group_ids["Mac"], group_ids["iPad"], group_ids["Shared"],
                                                            group_ids["docs"], products_group]
add("PBXGroup", main_group,
    "{isa = PBXGroup; children = (" + "".join(f"\n\t\t\t\t{c}," for c in top_level) +
    '\n\t\t\t); sourceTree = "<group>"; }')

# ---------------------------------------------------------------- progetto

project_debug = dict(COMMON_PROJECT); project_debug.update(DEBUG_PROJECT)
project_release = dict(COMMON_PROJECT); project_release.update(RELEASE_PROJECT)
project_cl = config_list("project", project_debug, project_release, 'PBXProject "iPadGraphicTablet"')
project_id = oid("project")
target_attrs = "".join(f"\n\t\t\t\t\t{tid} = {{ CreatedOnToolsVersion = 15.0; }};" for tid in target_ids.values())
add("PBXProject", project_id,
    "{isa = PBXProject; attributes = { BuildIndependentTargetsInParallel = 1; LastSwiftUpdateCheck = 1500; "
    f"LastUpgradeCheck = 1500; TargetAttributes = {{{target_attrs}\n\t\t\t\t}}; }}; "
    f"buildConfigurationList = {project_cl}; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = it; "
    "hasScannedForEncodings = 0; knownRegions = ( it, en, Base, ); "
    f"mainGroup = {main_group}; productRefGroup = {products_group}; projectDirPath = \"\"; projectRoot = \"\"; "
    "targets = (" + "".join(f"\n\t\t\t\t{tid} /* {t} */," for t, tid in target_ids.items()) + "\n\t\t\t); }",
    'Project object')

# ---------------------------------------------------------------- scrittura

SECTION_ORDER = ["PBXBuildFile", "PBXFileReference", "PBXFrameworksBuildPhase", "PBXGroup", "PBXNativeTarget",
                 "PBXProject", "PBXResourcesBuildPhase", "PBXSourcesBuildPhase", "XCBuildConfiguration",
                 "XCConfigurationList"]

out = ["// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 56;\n\tobjects = {\n"]
for section in SECTION_ORDER:
    entries = sorted((i, t) for i, (s, t) in objects.items() if s == section)
    if not entries:
        continue
    out.append(f"\n/* Begin {section} section */\n")
    out.extend(t for _, t in entries)
    out.append(f"/* End {section} section */\n")
out.append(f"\t}};\n\trootObject = {project_id} /* Project object */;\n}}\n")

os.makedirs(PROJECT, exist_ok=True)
with open(os.path.join(PROJECT, "project.pbxproj"), "w", encoding="utf-8") as f:
    f.write("".join(out))

ws = os.path.join(PROJECT, "project.xcworkspace")
os.makedirs(ws, exist_ok=True)
with open(os.path.join(ws, "contents.xcworkspacedata"), "w", encoding="utf-8") as f:
    f.write('<?xml version="1.0" encoding="UTF-8"?>\n<Workspace\n   version = "1.0">\n'
            '   <FileRef\n      location = "self:">\n   </FileRef>\n</Workspace>\n')

# ---------------------------------------------------------------- schemi condivisi
# Schemi espliciti: TabletMac (avvio + test unitari) e TabletPad. Senza schemi Xcode ne crea
# uno anche per il bundle di test, che non si può "avviare" (⌘R) ma solo testare (⌘U).

def buildable(target):
    return (f'<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{target_ids[target]}" '
            f'BuildableName = "{products[target][0]}" BlueprintName = "{target}" '
            f'ReferencedContainer = "container:iPadGraphicTablet.xcodeproj"></BuildableReference>')


def scheme(target, tests):
    testables = "".join(f'<TestableReference skipped = "NO">{buildable(t)}</TestableReference>' for t in tests)
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1500" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            {buildable(target)}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>{testables}</Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         {buildable(target)}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         {buildable(target)}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug"></AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"></ArchiveAction>
</Scheme>
"""


schemes_dir = os.path.join(PROJECT, "xcshareddata", "xcschemes")
os.makedirs(schemes_dir, exist_ok=True)
for old in os.listdir(schemes_dir):
    os.remove(os.path.join(schemes_dir, old))
with open(os.path.join(schemes_dir, "TabletMac.xcscheme"), "w", encoding="utf-8") as f:
    f.write(scheme("TabletMac", ["TabletCoreTests"]))
with open(os.path.join(schemes_dir, "TabletPad.xcscheme"), "w", encoding="utf-8") as f:
    f.write(scheme("TabletPad", []))

print(f"Generato {PROJECT}")
print(f"  TabletMac: {len(target_sources['TabletMac'])} file · TabletPad: {len(target_sources['TabletPad'])} file · "
      f"TabletCoreTests: {len(target_sources['TabletCoreTests'])} file")
