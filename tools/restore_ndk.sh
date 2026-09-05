set -e
NDK_ROOT=/d/AndroidSDK/ndk
T=/c/Users/hyc50/AppData/Local/Temp
dl() {
  local ver=$1 url=$2 rel=$3
  local zip="$T/ndk_${ver}.zip"
  local ext="$T/ndk_ext_${ver}"
  echo ">> [$(date +%H:%M:%S)] 下载 NDK $ver ($rel) ..."
  rm -f "$zip"; curl -fSL "$url" -o "$zip"
  ls -la "$zip"
  echo ">> 解压 $ver ..."
  rm -rf "$NDK_ROOT/$ver"; mkdir -p "$NDK_ROOT/$ver"
  rm -rf "$ext"; mkdir -p "$ext"
  unzip -q "$zip" -d "$ext"
  mv "$ext/android-ndk-$rel"/* "$NDK_ROOT/$ver/"
  rm -rf "$ext" "$zip"
  echo ">> $ver 完成。source.properties 版本："
  grep -i "Pkg.Revision" "$NDK_ROOT/$ver/source.properties"
}
dl "27.0.12077973" "https://dl.google.com/android/repository/android-ndk-r27b-windows.zip" "r27b"
dl "26.1.10909125" "https://dl.google.com/android/repository/android-ndk-r26b-windows.zip" "r26b"
echo "NDK_RESTORE_ALL_DONE"
ls -d "$NDK_ROOT"/*
