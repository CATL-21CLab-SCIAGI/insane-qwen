#!/usr/bin/env python3
"""Generate a deterministic Xcode project using only Python's standard library."""
from pathlib import Path
import hashlib
import json
import os
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "Embryo.xcodeproj"
objects = {}
existing_teams = {}


def read_project(path):
    return json.loads(subprocess.check_output([
        "plutil", "-convert", "json", "-o", "-", str(path)
    ]))["objects"]


existing_project = PROJECT / "project.pbxproj"
if existing_project.exists():
    previous = read_project(existing_project)
    for target in previous.values():
        if target["isa"] != "PBXNativeTarget":
            continue
        for configuration in previous[target["buildConfigurationList"]]["buildConfigurations"]:
            config = previous[configuration]
            team = config["buildSettings"].get("DEVELOPMENT_TEAM")
            if team:
                existing_teams[(target["name"], config["name"])] = team

# Signing stays local: choose a team in Xcode or pass DEVELOPMENT_TEAM.
default_team = ""


def identifier(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()


def add(object_name, isa, **values):
    key = identifier(object_name)
    objects[key] = dict(isa=isa, **values)
    return key


def encode(value, depth=0):
    pad = "\t" * depth
    if isinstance(value, dict):
        return "{\n" + "".join(
            "\t" * (depth + 1) + json.dumps(key) + " = "
            + encode(item, depth + 1) + ";\n" for key, item in value.items()
        ) + pad + "}"
    if isinstance(value, list):
        return "(\n" + "".join(
            "\t" * (depth + 1) + encode(item, depth + 1) + ",\n" for item in value
        ) + pad + ")"
    return str(value) if isinstance(value, int) else json.dumps(value, ensure_ascii=False)


def configurations(name, common, debug=None, release=None):
    refs = []
    for label, additions in [("Debug", debug or {}), ("Release", release or {})]:
        settings = {**common, **additions}
        if name != "project":
            team = os.environ.get("DEVELOPMENT_TEAM") or existing_teams.get((name, label)) or default_team
            if team:
                settings["DEVELOPMENT_TEAM"] = team
        refs.append(add(f"{name}-{label}", "XCBuildConfiguration", buildSettings=settings, name=label))
    return add(f"{name}-configurations", "XCConfigurationList", buildConfigurations=refs,
               defaultConfigurationIsVisible=0, defaultConfigurationName="Release")


def phase(name, kind, files):
    return add(name, kind, buildActionMask=2147483647, files=files,
               runOnlyForDeploymentPostprocessing=0)


app_id = identifier("target-Embryo")
tests_id = identifier("target-EmbryoUITests")
project_id = identifier("project")
app_product = add("product-Embryo", "PBXFileReference", explicitFileType="wrapper.application",
                  includeInIndex=0, path="Embryo.app", sourceTree="BUILT_PRODUCTS_DIR")
tests_product = add("product-EmbryoUITests", "PBXFileReference", explicitFileType="wrapper.cfbundle",
                    includeInIndex=0, path="EmbryoUITests.xctest", sourceTree="BUILT_PRODUCTS_DIR")

source_refs, source_builds, test_refs, test_builds = [], [], [], []
native_sources = sorted((ROOT / "Embryo").rglob("*.swift"))
test_sources = sorted((ROOT / "EmbryoUITests").rglob("*.swift"))
if not native_sources or not test_sources:
    raise SystemExit("App Swift sources and UI tests must exist before project generation.")
for files, refs, builds, group in [
    (native_sources, source_refs, source_builds, "Embryo"),
    (test_sources, test_refs, test_builds, "EmbryoUITests"),
]:
    for file in files:
        path = file.relative_to(ROOT / group).as_posix()
        ref = add(f"file-{group}/{path}", "PBXFileReference", lastKnownFileType="sourcecode.swift",
                  path=path, sourceTree="<group>")
        refs.append(ref)
        builds.append(add(f"build-{group}/{path}", "PBXBuildFile", fileRef=ref))

resource_builds = []
for path, kind in [("Assets.xcassets", "folder.assetcatalog"), ("PrivacyInfo.xcprivacy", "text.xml")]:
    ref = add(f"file-{path}", "PBXFileReference", lastKnownFileType=kind, path=path, sourceTree="<group>")
    source_refs.append(ref)
    resource_builds.append(add(f"build-{path}", "PBXBuildFile", fileRef=ref))
source_refs.append(add("file-Info.plist", "PBXFileReference", lastKnownFileType="text.plist.xml",
                       path="Info.plist", sourceTree="<group>"))

main_group = add("main-group", "PBXGroup", children=[
    add("sources-group", "PBXGroup", children=source_refs, path="Embryo", sourceTree="<group>"),
    add("tests-group", "PBXGroup", children=test_refs, path="EmbryoUITests", sourceTree="<group>"),
    add("products-group", "PBXGroup", children=[app_product, tests_product], name="Products", sourceTree="<group>"),
], sourceTree="<group>")

project_config = configurations("project", {
    "ALWAYS_SEARCH_USER_PATHS": "NO", "CLANG_ENABLE_MODULES": "YES",
    "CLANG_ENABLE_OBJC_ARC": "YES", "CLANG_WARN_UNREACHABLE_CODE": "YES",
    "GCC_C_LANGUAGE_STANDARD": "gnu17", "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
    "SDKROOT": "iphoneos", "SWIFT_VERSION": "5.0", "SWIFT_STRICT_CONCURRENCY": "targeted",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "EMBRYO_LIVE_DEVICE_TEST": "0",
}, {
    "DEBUG_INFORMATION_FORMAT": "dwarf", "ENABLE_TESTABILITY": "YES",
    "GCC_OPTIMIZATION_LEVEL": "0", "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)",
}, {
    "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym", "SWIFT_OPTIMIZATION_LEVEL": "-O",
    "VALIDATE_PRODUCT": "YES",
})
shared = {
    "CODE_SIGN_STYLE": "Automatic", "CURRENT_PROJECT_VERSION": "2", "MARKETING_VERSION": "0.2.0",
    "PRODUCT_NAME": "$(TARGET_NAME)", "TARGETED_DEVICE_FAMILY": "1,2",
    "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "SUPPORTS_MACCATALYST": "NO",
    "SWIFT_EMIT_LOC_STRINGS": "YES", "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
}
app_config = configurations("Embryo", {**shared,
    "INFOPLIST_FILE": "Embryo/Info.plist", "GENERATE_INFOPLIST_FILE": "NO",
    "PRODUCT_BUNDLE_IDENTIFIER": "dev.evergreen.embryo", "ENABLE_PREVIEWS": "YES",
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon", "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
})
tests_config = configurations("EmbryoUITests", {**shared,
    "GENERATE_INFOPLIST_FILE": "YES", "PRODUCT_BUNDLE_IDENTIFIER": "dev.evergreen.embryo.uitests",
    "TEST_TARGET_NAME": "Embryo", "SKIP_INSTALL": "YES",
})
proxy = add("tests-proxy", "PBXContainerItemProxy", containerPortal=project_id, proxyType=1,
            remoteGlobalIDString=app_id, remoteInfo="Embryo")
dependency = add("tests-dependency", "PBXTargetDependency", target=app_id, targetProxy=proxy)
add("target-Embryo", "PBXNativeTarget", buildConfigurationList=app_config, buildPhases=[
    phase("app-sources", "PBXSourcesBuildPhase", source_builds),
    phase("app-frameworks", "PBXFrameworksBuildPhase", []),
    phase("app-resources", "PBXResourcesBuildPhase", resource_builds),
], buildRules=[], dependencies=[], name="Embryo", productName="Embryo", productReference=app_product,
    productType="com.apple.product-type.application")
add("target-EmbryoUITests", "PBXNativeTarget", buildConfigurationList=tests_config, buildPhases=[
    phase("tests-sources", "PBXSourcesBuildPhase", test_builds),
    phase("tests-frameworks", "PBXFrameworksBuildPhase", []),
    phase("tests-resources", "PBXResourcesBuildPhase", []),
], buildRules=[], dependencies=[dependency], name="EmbryoUITests", productName="EmbryoUITests",
    productReference=tests_product, productType="com.apple.product-type.bundle.ui-testing")
add("project", "PBXProject", attributes={
    "BuildIndependentTargetsInParallel": "YES", "LastSwiftUpdateCheck": "1600", "LastUpgradeCheck": "1600",
    "TargetAttributes": {
        app_id: {"CreatedOnToolsVersion": "16.0", "ProvisioningStyle": "Automatic"},
        tests_id: {"CreatedOnToolsVersion": "16.0", "TestTargetID": app_id},
    },
}, buildConfigurationList=project_config, compatibilityVersion="Xcode 14.0", developmentRegion="en",
    hasScannedForEncodings=0, knownRegions=["en", "Base"], mainGroup=main_group,
    productRefGroup=identifier("products-group"), projectDirPath="", projectRoot="", targets=[app_id, tests_id])
PROJECT.mkdir(exist_ok=True)
(PROJECT / "project.pbxproj").write_text("// !$*UTF8*$!\n" + encode({
    "archiveVersion": 1, "classes": {}, "objectVersion": 56, "objects": objects, "rootObject": project_id,
}) + "\n")


def reference(target, product):
    return (f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" '
            f'BuildableName="{product}" BlueprintName="{product.split(".")[0]}" '
            'ReferencedContainer="container:Embryo.xcodeproj"/>')


scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.7">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference(app_id, "Embryo.app")}</BuildActionEntry>
    <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{reference(tests_id, "EmbryoUITests.xctest")}</BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES" codeCoverageEnabled="NO"><Testables><TestableReference skipped="NO">{reference(tests_id, "EmbryoUITests.xctest")}</TestableReference></Testables><EnvironmentVariables><EnvironmentVariable key="EMBRYO_LIVE_DEVICE_TEST" value="$(EMBRYO_LIVE_DEVICE_TEST)" isEnabled="YES"/></EnvironmentVariables></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference(app_id, "Embryo.app")}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference(app_id, "Embryo.app")}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
scheme_dir = PROJECT / "xcshareddata/xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
(scheme_dir / "Embryo.xcscheme").write_text(scheme)
print(f"Generated {PROJECT} with {len(native_sources)} app Swift files and {len(test_sources)} UI test files.")
