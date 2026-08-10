#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
vendor_dir="$project_dir/work/7zip-26.02"
download_url="https://github.com/ip7z/7zip/releases/download/26.02/7z2602-mac.tar.xz"
app_path="$project_dir/outputs/万能解压.app"
archive_path="$project_dir/outputs/万能解压-macOS-arm64.zip"
source_archive_path="$project_dir/outputs/万能解压-源代码.zip"
package_dir=$(mktemp -d /tmp/universal-extractor-package.XXXXXX)
packaged_app_path="$package_dir/万能解压.app"
contents_path="$packaged_app_path/Contents"

mkdir -p "$vendor_dir"
if [[ ! -x "$vendor_dir/7zz" ]]; then
    download_dir=$(mktemp -d /tmp/universal-extractor-download.XXXXXX)
    echo "下载官方 7-Zip 26.02…"
    curl -fsSL "$download_url" -o "$download_dir/7zip.tar.xz"
    tar -xJf "$download_dir/7zip.tar.xz" -C "$download_dir"
    install -m 755 "$download_dir/7zz" "$vendor_dir/7zz"
    install -m 644 "$download_dir/License.txt" "$vendor_dir/License.txt"
fi

echo "运行核心检查…"
swift run --package-path "$project_dir" CoreChecks

echo "运行实际解压引擎检查…"
SEVENZIP_BIN="$vendor_dir/7zz" swift run --package-path "$project_dir" EngineChecks

echo "构建 arm64 发布版本…"
swift build --package-path "$project_dir" -c release --arch arm64 --product UniversalExtractorApp
binary_path=$(swift build --package-path "$project_dir" -c release --arch arm64 --show-bin-path)/UniversalExtractorApp

if [[ -e "$app_path" ]]; then
    backup_path="$project_dir/work/万能解压-previous-$(date +%Y%m%d-%H%M%S).app"
    mv "$app_path" "$backup_path"
fi

mkdir -p "$contents_path/MacOS" "$contents_path/Resources"
install -m 755 "$binary_path" "$contents_path/MacOS/UniversalExtractorApp"
install -m 755 "$vendor_dir/7zz" "$contents_path/Resources/7zz"
install -m 644 "$project_dir/Packaging/Info.plist" "$contents_path/Info.plist"
install -m 644 "$project_dir/Sources/UniversalExtractorApp/Resources/ThirdPartyNotices.txt" "$contents_path/Resources/ThirdPartyNotices.txt"
install -m 644 "$vendor_dir/License.txt" "$contents_path/Resources/7-Zip-License.txt"
ditto --norsrc "$project_dir/Packaging/Localization/en.lproj" "$contents_path/Resources/en.lproj"
ditto --norsrc "$project_dir/Packaging/Localization/zh-Hans.lproj" "$contents_path/Resources/zh-Hans.lproj"

# 在 /tmp 中完成签名，避免 Documents/iCloud 文件提供器异步附加 Finder 元数据。
xattr -cr "$packaged_app_path"
codesign --force --deep --sign - "$packaged_app_path"
codesign --verify --deep --strict "$packaged_app_path"

if [[ -e "$archive_path" ]]; then
    mv "$archive_path" "$project_dir/work/万能解压-macOS-arm64-previous-$(date +%Y%m%d-%H%M%S).zip"
fi
ditto -c -k --norsrc --keepParent "$packaged_app_path" "$archive_path"
ditto --norsrc "$packaged_app_path" "$app_path"

# 让当前 Mac 的 Finder 立即刷新“打开方式”列表；其他 Mac 首次启动 App 时会自动注册。
lsregister_path="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$lsregister_path" ]]; then
    "$lsregister_path" -f "$app_path" || true
fi

source_package_dir=$(mktemp -d /tmp/universal-extractor-source.XXXXXX)
source_root="$source_package_dir/万能解压-源代码"
mkdir -p "$source_root"
ditto --norsrc "$project_dir/Package.swift" "$source_root/Package.swift"
ditto --norsrc "$project_dir/README.md" "$source_root/README.md"
ditto --norsrc "$project_dir/README.zh-CN.md" "$source_root/README.zh-CN.md"
ditto --norsrc "$project_dir/.gitignore" "$source_root/.gitignore"
ditto --norsrc "$project_dir/Packaging" "$source_root/Packaging"
ditto --norsrc "$project_dir/Sources" "$source_root/Sources"
ditto --norsrc "$project_dir/scripts" "$source_root/scripts"
if [[ -e "$source_archive_path" ]]; then
    mv "$source_archive_path" "$project_dir/work/万能解压-源代码-previous-$(date +%Y%m%d-%H%M%S).zip"
fi
ditto -c -k --norsrc --keepParent "$source_root" "$source_archive_path"

echo "构建完成：$app_path"
echo "签名归档：$archive_path"
echo "源代码归档：$source_archive_path"
