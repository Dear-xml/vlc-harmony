#!/bin/bash

# Copyright (c) 2024 Huawei Device Co., Ltd.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# 可在任意目录执行。优先 OHOS_SDK（含 native）或 OHOS_SDK_HOME/API_VERSION。
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$SCRIPT_DIR
cd "$ROOT_DIR" || exit 1

API_VERSION=${API_VERSION:-18}
if [ -d "${OHOS_SDK:-}/native" ]; then
    SDK_DIR=$OHOS_SDK
else
    SDK_DIR=${OHOS_SDK_HOME:-$HOME/Library/Huawei/Sdk/openharmony}/$API_VERSION
    if [ ! -d "$SDK_DIR/native" ] && [ -d "$HOME/Library/Huawei/Sdk/openharmony/22/native" ]; then
        SDK_DIR=$HOME/Library/Huawei/Sdk/openharmony/22
    fi
fi
LYCIUM_TOOLS_URL=https://gitcode.com/openharmony-sig/tpc_c_cplusplus.git
LYCIUM_ROOT_DIR=$ROOT_DIR/tpc_c_cplusplus
# vlc-harmony 可复用工作区已有 tpc 检出，避免再 clone 一份。
WORKSPACE_TPC=$(cd "$ROOT_DIR/../.." && pwd)/openharmony_tpc_samples/ohos_vlc/tpc_c_cplusplus
if [ ! -d "$LYCIUM_ROOT_DIR" ] && [ -d "$WORKSPACE_TPC" ]; then
    LYCIUM_ROOT_DIR=$WORKSPACE_TPC
    echo "Reuse workspace tpc: $LYCIUM_ROOT_DIR"
fi
LYCIUM_TOOLS_DIR=$LYCIUM_ROOT_DIR/lycium
LYCIUM_THIRDPARTY_DIR=$LYCIUM_ROOT_DIR/thirdparty
FORCE_CLONE=${FORCE_CLONE:-0}
OS_NAME=$(uname -s)

function prepare_lycium_tools()
{
    local commands=("gcc" "make" "cmake" "pkg-config" "autoconf" "autoreconf" "automake" "patch" "libtool" "autopoint" "gperf" \
    "tcl8.6-dev" "wget" "unzip" "gccgo-go" "flex " "bison" "premake4" "python3" "python3-pip" \
    "ninja-build" "meson" "sox" "gfortran" "subversion" "build-essential" "module-assistant" " gcc-multilib" \
    "g++-multilib" "libltdl7-dev" "cabextract" "libboost-all-dev" "libxml2-utils" "gettext" "libxml-libxml-perl" \
    "libxml2" "libxml2-dev" "libxml-parser-perl" "texinfo" "libtool-bin" "xmlto" "po4a" "yasm" "nasm" "xutils-dev" \
    "libx11-dev" "xtrans-dev" "gfortran-arm-linux-gnueabi" "gfortran-aarch64-linux-gnu")

    if [ "$OS_NAME" != "Linux" ] || ! command -v apt >/dev/null 2>&1
    then
        echo "Skip apt package install on $OS_NAME"
        return 0
    fi

    apt update >> /dev/null

    for cmd in ${commands[@]}
    do
        which $cmd >> /dev/null
        if [ $? -ne 0 ]
        then
            echo "install $cmd"
            apt install $cmd -y >> /dev/null
        fi
    done
}

function prepare_lycium()
{
    if [ -d "$LYCIUM_ROOT_DIR/.git" ] && [ "$FORCE_CLONE" != "1" ]
    then
        echo "Reuse existing $LYCIUM_ROOT_DIR (set FORCE_CLONE=1 to re-clone)"
    elif [ -d "$LYCIUM_ROOT_DIR" ] && [ "$FORCE_CLONE" != "1" ]
    then
        echo "Reuse existing $LYCIUM_ROOT_DIR"
    else
        if [ -d "$LYCIUM_ROOT_DIR" ]
        then
            rm -rf "$LYCIUM_ROOT_DIR"
        fi
        git clone $LYCIUM_TOOLS_URL --depth=1 "$LYCIUM_ROOT_DIR"
        if [ $? -ne 0 ]
        then
            return 1
        fi
    fi

    if [ ! -d "$LYCIUM_TOOLS_DIR/Buildtools" ]
    then
        echo "ERROR: $LYCIUM_TOOLS_DIR/Buildtools not found"
        return 1
    fi

    if [ ! -x "$SDK_DIR/native/llvm/bin/aarch64-linux-ohos-clang" ] && \
       [ ! -x "$SDK_DIR/native/llvm/bin/aarch64-unknown-linux-ohos-clang" ]
    then
        (
            cd "$LYCIUM_TOOLS_DIR/Buildtools" || exit 1
            tar -zxvf toolchain.tar.gz
            mkdir -p "$SDK_DIR/native/llvm/bin"
            cp -f toolchain/* "$SDK_DIR/native/llvm/bin/" || echo "WARNING: cannot copy clang wrappers into SDK; using SDK clang names"
            rm -rf toolchain
        ) || return 1
    else
        echo "SDK clang already present, skip toolchain unpack"
    fi

    prepare_lycium_tools
    return $?
}

function copy_depends()
{
    local dir="$1"
    local name="$2"

    if [ -d "$LYCIUM_THIRDPARTY_DIR/$name" ]
    then
        rm -rf "$LYCIUM_THIRDPARTY_DIR/$name"
    fi
    cp -arf "$dir/$name" "$LYCIUM_THIRDPARTY_DIR/"
}

function check_sdk()
{
    if [ ! -d "$SDK_DIR/native" ]
    then
        echo "ERROR: SDK native not found: $SDK_DIR"
        echo "Set OHOS_SDK to the API dir that contains native/, e.g."
        echo "  export OHOS_SDK=\$HOME/Library/Huawei/Sdk/openharmony/22"
        return 1
    fi

    export OHOS_SDK=$SDK_DIR
    echo "OHOS_SDK=$OHOS_SDK"
    return 0
}

function check_copy_shasum()
{
    local libpath=$1
    local pack_name=$2
    local libname=$3

    cd $LYCIUM_THIRDPARTY_DIR/$libpath
    if [ ! -f ./SHA512SUM ]
    then
        sha512sum $pack_name > ./SHA512SUM
    fi
    cp ./SHA512SUM $LYCIUM_TOOLS_DIR/usr/$libname/

    cd $OLDPWD
}

function install_shasum()
{
    return 0
}

function start_build()
{
    local result=0
    cd "$LYCIUM_TOOLS_DIR" || return 1

    export PATH="$LYCIUM_TOOLS_DIR/wrapper-bin:$PATH"
    export LYCIUM_ARCHS=${LYCIUM_ARCHS:-arm64-v8a}
    export LYCIUM_ROOT="$LYCIUM_TOOLS_DIR"
    export LYCIUM_BUILD_CHECK=false
    export MAKE="${MAKE:-make -j8}"
    export OHOS_SDK="$SDK_DIR"
    local ffmpeg_recipe_dir=$LYCIUM_ROOT_DIR/community/FFmpeg-surface-dev
    if [ -d "$ffmpeg_recipe_dir" ]
    then
        echo "Rebuild FFmpeg ($LYCIUM_ARCHS) with ohosavcodec poll fix"
        ln -fs "$LYCIUM_TOOLS_DIR/script/build_hpk.sh" "$ffmpeg_recipe_dir/build_hpk.sh"
        ln -fs "$LYCIUM_TOOLS_DIR/script/envset.sh" "$ffmpeg_recipe_dir/envset.sh"
        local deps
        deps=$(awk -F, '{print $1}' "$LYCIUM_TOOLS_DIR/usr/hpk_build.csv" 2>/dev/null | grep -v '^FFmpeg$' | sort -u | tr '\n' ' ')
        (cd "$ffmpeg_recipe_dir" && bash ./build_hpk.sh $deps)
        result=$?
        if [ $result -ne 0 ]
        then
            cd "$ROOT_DIR" || true
            return $result
        fi
    fi

    bash build.sh vlc
    result=$?
    cd "$ROOT_DIR" || true
    return $result
}

function install_vlc_patches()
{
    local vlc_recipe_dir=$LYCIUM_THIRDPARTY_DIR/vlc
    cp -f "$ROOT_DIR/patches/0001-avcodec-respect-disabled-hardware-decoding.patch" "$vlc_recipe_dir/"
    cp -f "$ROOT_DIR/patches/0002-avcodec-fallback-to-software-on-hw-start-failure.patch" "$vlc_recipe_dir/"
    cp -f "$ROOT_DIR/patches/0003-vcd-mode1-2048-iso.patch" "$vlc_recipe_dir/"
    cp -f "$ROOT_DIR/patches/0004-bluray-seek-fix.patch" "$vlc_recipe_dir/"
    cp -f "$ROOT_DIR/patches/0005-vcd-iso9660-no-cue.patch" "$vlc_recipe_dir/"
    cp -f "$ROOT_DIR/patches/0007-ohoscodec-attach-surface-context.patch" "$vlc_recipe_dir/"
    if ! grep -q "0001-avcodec-respect-disabled-hardware-decoding.patch" "$vlc_recipe_dir/HPKBUILD"
    then
        patch -d "$vlc_recipe_dir" -p0 < "$ROOT_DIR/patches/vlc-hpkbuild-apply-local-patches.patch" || return 1
    fi
    if ! grep -q "enable-dvbpsi" "$vlc_recipe_dir/HPKBUILD"
    then
        patch -d "$vlc_recipe_dir" -p0 < "$ROOT_DIR/patches/vlc-hpkbuild-build-dvbpsi.patch" || return 1
    fi
    return 0
}

function install_ffmpeg_patches()
{
    local ffmpeg_recipe_dir=""
    if [ -d "$LYCIUM_ROOT_DIR/community/FFmpeg-surface-dev" ]
    then
        ffmpeg_recipe_dir=$LYCIUM_ROOT_DIR/community/FFmpeg-surface-dev
    elif [ -d "$LYCIUM_THIRDPARTY_DIR/FFmpeg-surface-dev" ]
    then
        ffmpeg_recipe_dir=$LYCIUM_THIRDPARTY_DIR/FFmpeg-surface-dev
    else
        echo "ERROR: FFmpeg-surface-dev recipe not found under $LYCIUM_ROOT_DIR"
        return 1
    fi

    cp -f "$ROOT_DIR/patches/0006-ohosavcodec-avoid-zero-timeout-busy-poll.patch" "$ffmpeg_recipe_dir/"
    if grep -q "0006-ohosavcodec-avoid-zero-timeout-busy-poll.patch" "$ffmpeg_recipe_dir/HPKBUILD"
    then
        echo "FFmpeg HPKBUILD already applies 0006, skip"
        return 0
    fi
    patch -d "$ffmpeg_recipe_dir" -p0 < "$ROOT_DIR/patches/ffmpeg-hpkbuild-apply-hwdec-poll.patch"
    return $?
}

function install_depends()
{
    mkdir -p $ROOT_DIR/library/libs/arm64-v8a/
    local install_dir=$ROOT_DIR/library/libs/arm64-v8a/
    cp -arf $LYCIUM_TOOLS_DIR/usr/vlc/arm64-v8a/lib/vlc "$install_dir"
    cp -f $LYCIUM_TOOLS_DIR/usr/vlc/arm64-v8a/lib/libvlc.so.5 "$install_dir"
    cp -f $LYCIUM_TOOLS_DIR/usr/vlc/arm64-v8a/lib/libvlccore.so.9 "$install_dir"
    cp -f $LYCIUM_TOOLS_DIR/usr/a52dec/arm64-v8a/lib/liba52.so.0 "$install_dir"
    cp -f $LYCIUM_TOOLS_DIR/usr/aribb24/arm64-v8a/lib/libaribb24.so.0 "$install_dir"
    cp -f $LYCIUM_TOOLS_DIR/usr/FFmpeg/arm64-v8a/lib/libavcodec.so.60 "$install_dir"
    cp -f $LYCIUM_TOOLS_DIR/usr/FFmpeg/arm64-v8a/lib/libavformat.so.60 "$install_dir"
    cp -f $LYCIUM_TOOLS_DIR/usr/FFmpeg/arm64-v8a/lib/libavutil.so.58 "$install_dir"
    cp -f $LYCIUM_TOOLS_DIR/usr/libdca/arm64-v8a/lib/libdca.so.0 "$install_dir"
    cp -f $LYCIUM_TOOLS_DIR/usr/libkate/arm64-v8a/lib/libkate.so.1 "$install_dir"
    cp -f $LYCIUM_TOOLS_DIR/usr/libpng/arm64-v8a/lib/libpng16.so.16 "$install_dir"
    cp -f $LYCIUM_TOOLS_DIR/usr/speex/arm64-v8a/lib/libspeex.so.1 "$install_dir"
    cp -f $LYCIUM_TOOLS_DIR/usr/speexdsp/arm64-v8a/lib/libspeexdsp.so.1 "$install_dir"
    cp -f $LYCIUM_TOOLS_DIR/usr/FFmpeg/arm64-v8a/lib/libswresample.so.4 "$install_dir"
    cp -f $LYCIUM_TOOLS_DIR/usr/FFmpeg/arm64-v8a/lib/libswscale.so.7 "$install_dir"
    cp -f $LYCIUM_TOOLS_DIR/usr/libtheora/arm64-v8a/lib/libtheoradec.so.1 "$install_dir"
    cp -f $LYCIUM_TOOLS_DIR/usr/libtheora/arm64-v8a/lib/libtheoraenc.so.1 "$install_dir"
    # Transitive deps of libavcodec.so (required for h264/aac decode)
    cp -f $LYCIUM_TOOLS_DIR/usr/dav1d/arm64-v8a/lib/libdav1d.so.7 "$install_dir"
    cp -f $LYCIUM_TOOLS_DIR/usr/lame/arm64-v8a/lib/libmp3lame.so.0 "$install_dir"
    cp -f $LYCIUM_TOOLS_DIR/usr/openh264/arm64-v8a/lib/libopenh264.so.8 "$install_dir"
    cp -f $LYCIUM_TOOLS_DIR/usr/zlib/arm64-v8a/lib/libz.so.1 "$install_dir"

    mkdir -p $ROOT_DIR/library/src/main/cpp/thirdpart/include/
    cp -arf $LYCIUM_TOOLS_DIR/usr/vlc/arm64-v8a/include/* $ROOT_DIR/library/src/main/cpp/thirdpart/include/
    return 0
}

function prebuild()
{
    check_sdk
    if [ $? -ne 0 ]
    then
        echo "ERROR: check_sdk failed!!!"
        return 1
    fi
    prepare_lycium
    if [ $? -ne 0 ]
    then
        echo "ERROR: prepare_lycium failed!!!"
        return 1
    fi

    install_vlc_patches
    if [ $? -ne 0 ]
    then
        echo "ERROR: install vlc patches failed!!!"
        return 1
    fi

    install_ffmpeg_patches
    if [ $? -ne 0 ]
    then
        echo "ERROR: install ffmpeg patches failed!!!"
        return 1
    fi

    start_build
    if [ $? -ne 0 ]
    then
        echo "ERROR: start_build failed!!!"
        return 1
    fi

    install_depends
    if [ $? -ne 0 ]
    then
        echo "ERROR: install depends failed!!!"
        return 1
    fi
    echo "prebuild success!!"
    return 0
}

prebuild $*
ret=$?
echo "ret = $ret"
exit $ret

#EOF
