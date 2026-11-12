#!/bin/zsh
# 发布一个版本，让已安装的 Bar Control 能检测到更新。
#
# 用法：
#   scripts/publish-release.sh            # 真正发布
#   DRY_RUN=1 scripts/publish-release.sh  # 只打印将执行的步骤
#
# 前提：
#   1. Info.plist 的版本号已经改好
#   2. docs/updates.json 的 latest 与新版本一致
#   3. docs/release-notes/<version>.md 已写好
set -euo pipefail

PROJECT_DIR=${0:A:h:h}
cd "$PROJECT_DIR"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)
TAG="v$VERSION"
NOTES="docs/release-notes/$VERSION.md"
DRY_RUN=${DRY_RUN:-0}

fail() { print -u2 "错误：$1"; exit 1; }

[[ -f "$NOTES" ]] || fail "缺少更新说明 $NOTES"
MANIFEST_LATEST=$(python3 -c "import json;print(json.load(open('docs/updates.json'))['latest'])")
[[ "$MANIFEST_LATEST" == "$VERSION" ]] || fail "docs/updates.json 的 latest=$MANIFEST_LATEST，与 Info.plist 的 $VERSION 不一致"
git rev-parse --git-dir >/dev/null || fail "当前目录不是 git 仓库"

if git rev-parse "$TAG" >/dev/null 2>&1; then
    fail "标签 $TAG 已存在"
fi

run() {
    if [[ "$DRY_RUN" == "1" ]]; then
        print "[dry-run] $*"
    else
        "$@"
    fi
}

print "发布 Bar Control $VERSION (build $BUILD)"

APP_BUNDLE="$PROJECT_DIR/dist/Bar Control.app"
ZIP="$PROJECT_DIR/dist/BarControl-$VERSION.zip"
ASSET_URL="https://github.com/cth123456/bar-control/releases/download/$TAG/BarControl-$VERSION.zip"

if [[ "$DRY_RUN" == "1" ]]; then
    print "[dry-run] $PROJECT_DIR/build.command"
    print "[dry-run] ditto -c -k --sequesterRsrc --keepParent '$APP_BUNDLE' $ZIP"
    print "[dry-run] 写入 asset_url / sha256 / asset_size 到 docs/updates.json"
else
    "$PROJECT_DIR/build.command" >/dev/null
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP"
    SHA256=$(/usr/bin/shasum -a 256 "$ZIP" | /usr/bin/awk '{print $1}')
    VERSION="$VERSION" ASSET_URL="$ASSET_URL" SHA256="$SHA256" ZIP="$ZIP" python3 - <<'PY'
import json, os, sys
version = os.environ["VERSION"]
path = "docs/updates.json"
data = json.load(open(path))
matched = False
for release in data["releases"]:
    if release.get("version") == version:
        release["asset_url"] = os.environ["ASSET_URL"]
        release["sha256"] = os.environ["SHA256"]
        release["asset_size"] = os.path.getsize(os.environ["ZIP"])
        matched = True
if not matched:
    raise SystemExit(f"docs/updates.json 里没有 {version} 的条目")
with open(path, "w") as handle:
    json.dump(data, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
fi

run git add docs/updates.json "$NOTES"
run git commit -m "release: Bar Control $VERSION"
run git tag -a "$TAG" -m "Bar Control $VERSION"
run git push origin HEAD
run git push origin "$TAG"
run gh release create "$TAG" "$ZIP" --title "Bar Control $VERSION" --notes-file "$NOTES"

print "完成：https://github.com/cth123456/bar-control/releases/tag/$TAG"
