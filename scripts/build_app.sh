#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
vendor_dir="$project_dir/work/7zip-26.02"
output_dir="$project_dir/outputs"
download_url="https://github.com/ip7z/7zip/releases/download/26.02/7z2602-mac.tar.xz"
archive_sha256="1cf6760579502f87e591ff5c73a005ec50b3e4d6f507e8b038382d563c3175b9"
binary_sha256="9c56cf3379a0d8544e9244958b96fdc7c17f9ce70f5a160eb2b41f5f3df96d8c"
license_sha256="1790374e5352329cedb46ee3808930a88e9ca2f08b82b10fcf5cf605d2c301b1"
app_path="$output_dir/万能解压.app"
archive_path="$output_dir/万能解压-macOS-arm64.zip"
source_archive_path="$output_dir/万能解压-源代码.zip"
release_archive_path="$output_dir/Universal-Extractor-v1.5.0-macOS-arm64.zip"
release_source_path="$output_dir/Universal-Extractor-v1.5.0-Source.zip"
checksums_path="$output_dir/SHA256SUMS.txt"
package_dir=$(mktemp -d /tmp/universal-extractor-package.XXXXXX)
packaged_app_path="$package_dir/万能解压.app"
contents_path="$packaged_app_path/Contents"
module_cache="$project_dir/work/swift-module-cache"

mkdir -p "$module_cache" "$output_dir"
export CLANG_MODULE_CACHE_PATH="$module_cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$module_cache"

# Some Command Line Tools updates can briefly leave the default macOS SDK and
# Swift compiler on different patch releases.  This app targets macOS 14, so a
# concrete macOS 15.4 SDK is a safe local fallback when it is available.  An
# explicitly supplied SDKROOT always wins (including in CI).
if [[ -z "${SDKROOT:-}" && -x /Library/Developer/CommandLineTools/usr/bin/swift \
      && -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]]; then
    export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
fi

verify_sha256() {
    local expected_sha256=$1
    local file_path=$2
    local actual_sha256

    if [[ ! -f "$file_path" ]]; then
        echo "校验失败，文件不存在：$file_path" >&2
        return 1
    fi

    actual_sha256=$(/usr/bin/shasum -a 256 "$file_path" | /usr/bin/awk '{print $1}')
    if [[ "$actual_sha256" != "$expected_sha256" ]]; then
        echo "SHA-256 校验失败：$file_path" >&2
        echo "期望：$expected_sha256" >&2
        echo "实际：$actual_sha256" >&2
        return 1
    fi
}

ditto_clean() {
    /usr/bin/ditto --norsrc --noextattr --noqtn --noacl --nopersistRootless "$@"
}

mkdir -p "$vendor_dir"
if [[ -e "$vendor_dir/7zz" ]]; then
    echo "校验缓存的 7-Zip 26.02…"
    verify_sha256 "$binary_sha256" "$vendor_dir/7zz"
fi
if [[ -e "$vendor_dir/License.txt" ]]; then
    verify_sha256 "$license_sha256" "$vendor_dir/License.txt"
fi

if [[ ! -x "$vendor_dir/7zz" || ! -f "$vendor_dir/License.txt" ]]; then
    download_dir=$(mktemp -d /tmp/universal-extractor-download.XXXXXX)
    echo "下载官方 7-Zip 26.02…"
    curl -fsSL "$download_url" -o "$download_dir/7zip.tar.xz"
    verify_sha256 "$archive_sha256" "$download_dir/7zip.tar.xz"
    tar -xJf "$download_dir/7zip.tar.xz" -C "$download_dir"
    verify_sha256 "$binary_sha256" "$download_dir/7zz"
    verify_sha256 "$license_sha256" "$download_dir/License.txt"
    install -m 755 "$download_dir/7zz" "$vendor_dir/7zz"
    install -m 644 "$download_dir/License.txt" "$vendor_dir/License.txt"
fi
verify_sha256 "$binary_sha256" "$vendor_dir/7zz"
verify_sha256 "$license_sha256" "$vendor_dir/License.txt"

echo "运行核心检查…"
swift run --disable-sandbox --package-path "$project_dir" CoreChecks

echo "运行实际压缩与解压引擎检查…"
SEVENZIP_BIN="$vendor_dir/7zz" swift run --disable-sandbox --package-path "$project_dir" EngineChecks

echo "构建 arm64 发布版本…"
swift build --disable-sandbox --package-path "$project_dir" -c release --arch arm64 --product UniversalExtractorApp -Xswiftc -warnings-as-errors
binary_path=$(swift build --disable-sandbox --package-path "$project_dir" -c release --arch arm64 --show-bin-path)/UniversalExtractorApp

if [[ -e "$app_path" ]]; then
    backup_path="$project_dir/work/万能解压-previous-$(date +%Y%m%d-%H%M%S).app"
    mv "$app_path" "$backup_path"
fi

mkdir -p "$contents_path/MacOS" "$contents_path/Resources"
install -m 755 "$binary_path" "$contents_path/MacOS/UniversalExtractorApp"
install -m 755 "$vendor_dir/7zz" "$contents_path/Resources/7zz"
install -m 644 "$project_dir/Packaging/AppIcon.icns" "$contents_path/Resources/AppIcon.icns"
install -m 644 "$project_dir/Packaging/Info.plist" "$contents_path/Info.plist"
install -m 644 "$project_dir/LICENSE" "$contents_path/Resources/Project-License.txt"
install -m 644 "$project_dir/Sources/UniversalExtractorApp/Resources/ThirdPartyNotices.txt" "$contents_path/Resources/ThirdPartyNotices.txt"
install -m 644 "$vendor_dir/License.txt" "$contents_path/Resources/7-Zip-License.txt"
mkdir -p "$contents_path/Resources/en.lproj" "$contents_path/Resources/zh-Hans.lproj"
/bin/cp -X "$project_dir/Packaging/Localization/en.lproj/"*.strings "$contents_path/Resources/en.lproj/"
/bin/cp -X "$project_dir/Packaging/Localization/zh-Hans.lproj/"*.strings "$contents_path/Resources/zh-Hans.lproj/"

# 在 /tmp 中完成签名，避免 Documents/iCloud 文件提供器异步附加 Finder 元数据。
xattr -cr "$packaged_app_path"
codesign --force --options runtime --sign - "$contents_path/Resources/7zz"
codesign --force --deep --options runtime --sign - "$packaged_app_path"
codesign --verify --strict "$contents_path/Resources/7zz"
codesign --verify --deep --strict "$packaged_app_path"

if [[ -e "$archive_path" ]]; then
    mv "$archive_path" "$project_dir/work/万能解压-macOS-arm64-previous-$(date +%Y%m%d-%H%M%S).zip"
fi
ditto_clean -c -k --keepParent "$packaged_app_path" "$archive_path"
/bin/cp -R -X "$packaged_app_path" "$app_path"
# Documents 的文件提供器可能在复制时附加元数据。发布 App 不携带这些扩展属性；
# 首次正常启动会自动完成 Launch Services 注册，无需在构建期间扫描输出目录。
xattr -cr "$app_path"
# 裸 App 是本机便捷副本，文件提供器可能在清理与校验之间重新写入 FinderInfo；
# 这里验证代码封印，公开下载 ZIP 则在下一步以普通用户解包方式做严格校验。
codesign --verify --deep "$app_path"

# 归档才是公开下载资产，因此也要验证一次真实的“解包后”签名，而不只验证暂存目录。
archive_validation_dir=$(mktemp -d /tmp/universal-extractor-archive-check.XXXXXX)
/usr/bin/ditto -x -k "$archive_path" "$archive_validation_dir"
codesign --verify --deep --strict "$archive_validation_dir/万能解压.app"

source_package_dir=$(mktemp -d /tmp/universal-extractor-source.XXXXXX)
source_root="$source_package_dir/万能解压-源代码"
mkdir -p "$source_root"
install -m 644 "$project_dir/Package.swift" "$source_root/Package.swift"
install -m 644 "$project_dir/README.md" "$source_root/README.md"
install -m 644 "$project_dir/README.zh-CN.md" "$source_root/README.zh-CN.md"
install -m 644 "$project_dir/LICENSE" "$source_root/LICENSE"
install -m 644 "$project_dir/SECURITY.md" "$source_root/SECURITY.md"
install -m 644 "$project_dir/.gitignore" "$source_root/.gitignore"
/bin/cp -R -X "$project_dir/.github" "$source_root/.github"
/bin/cp -R -X "$project_dir/Packaging" "$source_root/Packaging"
/bin/cp -R -X "$project_dir/Sources" "$source_root/Sources"
/bin/cp -R -X "$project_dir/scripts" "$source_root/scripts"
if [[ -e "$source_archive_path" ]]; then
    mv "$source_archive_path" "$project_dir/work/万能解压-源代码-previous-$(date +%Y%m%d-%H%M%S).zip"
fi
ditto_clean -c -k --keepParent "$source_root" "$source_archive_path"
/bin/cp -X "$archive_path" "$release_archive_path"
/bin/cp -X "$source_archive_path" "$release_source_path"
(
    cd "$output_dir"
    /usr/bin/shasum -a 256 "${release_archive_path:t}" "${release_source_path:t}"
) > "$checksums_path"

echo "构建完成：$app_path"
echo "签名归档：$archive_path"
echo "源代码归档：$source_archive_path"
echo "GitHub Release：$release_archive_path"
echo "GitHub Source：$release_source_path"
echo "发布校验和：$checksums_path"
