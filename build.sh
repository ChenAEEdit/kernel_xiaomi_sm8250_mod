#!/usr/bin/env bash
# Redmi K40 / alioth: Linux 4.19 + SukiSU Ultra builtin build script.
# Based on the build flow and MIUI panel adjustments from ChenAEEdit/kernel_xiaomi_sm8250_mod.
# Builds AOSP and MIUI zips; SukiSU enabled with `ksu`, SUSFS & KPM intentionally disabled.
set -Eeuo pipefail

cd "$(dirname "$0")"
TARGET_DEVICE="${1:-}"
KSU_ENABLE=0
[[ "${2:-}" == "ksu" ]] && KSU_ENABLE=1
[[ -n "$TARGET_DEVICE" ]] || { echo 'Usage: bash build.sh alioth [ksu]'; exit 2; }
[[ -f "arch/arm64/configs/${TARGET_DEVICE}_defconfig" ]] || { echo "Unknown device: $TARGET_DEVICE"; exit 2; }

TOOLCHAIN_PATH="${TOOLCHAIN_PATH:-$HOME/zyc-clang/bin}"
[[ -d "$TOOLCHAIN_PATH" ]] || { echo "Toolchain missing: $TOOLCHAIN_PATH"; exit 2; }
export PATH="$TOOLCHAIN_PATH:/usr/lib/ccache:$PATH"
for program in clang aarch64-linux-gnu-ld arm-linux-gnueabi-ld curl python3 zip; do
    command -v "$program" >/dev/null || { echo "Missing program: $program"; exit 2; }
done

export CCACHE_DIR="$HOME/.cache/ccache_mikernel"
mkdir -p "$CCACHE_DIR"
GIT_COMMIT_ID="$(git rev-parse --short=8 HEAD)"
MAKE_ARGS=(ARCH=arm64 SUBARCH=arm64 O=out CC=clang
    CROSS_COMPILE=aarch64-linux-gnu-
    CROSS_COMPILE_ARM32=arm-linux-gnueabi-
    CROSS_COMPILE_COMPAT=arm-linux-gnueabi-
    CLANG_TRIPLE=aarch64-linux-gnu-)
JOBS="${JOBS:-$(nproc)}"
KSU_ZIP_STR=NoKernelSU
[[ "$KSU_ENABLE" -eq 1 ]] && KSU_ZIP_STR=SukiSU-noSUSFS-noKPM

echo "Target: $TARGET_DEVICE | SukiSU: $KSU_ENABLE | jobs: $JOBS"
clang --version | head -n 2

if [[ "$KSU_ENABLE" -eq 1 ]]; then
    # The builtin branch is required for this non-GKI 4.19 kernel.
    curl -fLsS --retry 3 \
        'https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh' \
        -o /tmp/sukisu-setup.sh
    # Pin a verified builtin revision so future upstream changes do not
    # silently invalidate the compatibility patches. Override when updating.
    SUKISU_REF="${SUKISU_REF:-b16e899a555e9b96aa1225f049cd7274820ca5b8}"
    bash /tmp/sukisu-setup.sh "$SUKISU_REF"
    [[ -e drivers/kernelsu/ksu_main.c ]] || {
        echo 'SukiSU builtin source was not linked into drivers/kernelsu'; exit 1;
    }

    # These patches are deliberately checked: a changed upstream API should fail
    # loudly instead of generating a kernel with nonfunctional hooks.
    python3 - <<'PY'
from pathlib import Path


def replace_once(path, old, new):
    f = Path(path)
    content = f.read_text()
    if new in content:
        print('Already patched:', path)
        return
    n = content.count(old)
    if n != 1:
        raise SystemExit(f'Compatibility patch mismatch in {path}: expected 1, found {n}')
    f.write_text(content.replace(old, new, 1))
    print('Patched:', path)

ksu = Path('KernelSU/kernel')
if not (ksu / 'ksu_main.c').exists():
    raise SystemExit('SukiSU builtin source is missing')

# Old kernel API fixes (same fixes as the previous test branch, without
# disabling the manual faccessat/stat/execveat hooks).
if not Path('include/linux/static_call.h').exists():
    p = ksu / 'kernel_includes.h'
    t = p.read_text()
    if '#include <linux/static_call.h>\n' in t:
        p.write_text(t.replace('#include <linux/static_call.h>\n', '', 1))

replace_once(ksu / 'extension/kpm/kpm.c',
    'if (!access_ok(u64_to_user_ptr(cmd.result_code), sizeof(result)))',
    'if (!ksu_access_ok(u64_to_user_ptr(cmd.result_code), sizeof(result)))')
replace_once(ksu / 'sulog/event.c',
    'strncpy_from_user_nofault(arg,', 'ksu_strncpy_from_user_nofault(arg,')
replace_once(ksu / 'manager/pkg_observer.c',
    '    susfs_parse_priority_app_strings();',
    '#ifdef CONFIG_KSU_SUSFS\n    susfs_parse_priority_app_strings();\n#endif')
replace_once(ksu / 'extension/cpu_spoof.c',
    '                        (*curr_cs_ptr)->vdso_clock_mode =\n'
    '                            VDSO_CLOCKMODE_ARCHTIMER;',
    '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n'
    '                        (*curr_cs_ptr)->vdso_clock_mode =\n'
    '                            VDSO_CLOCKMODE_ARCHTIMER;\n#endif')
replace_once(ksu / 'preinit/common/preinit.h',
    '#define KSU_NO_PREINIT\n',
    '#ifndef KSU_NO_PREINIT\n#define KSU_NO_PREINIT\n#endif\n')
replace_once(ksu / 'selinux/rules.c',
    'void apply_kernelsu_rules(void)\n{\n'
    '    struct selinux_policy *pol, *old_pol;\n'
    '    struct policydb *db;',
    'void apply_kernelsu_rules(void)\n{\n'
    '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n'
    '    struct selinux_policy *pol, *old_pol;\n'
    '#endif\n    struct policydb *db;')

# fs/open.c: retain KSU faccessat hook; only the SUSFS pre-check is optional.
replace_once('fs/open.c',
    '#ifdef CONFIG_KSU_SUSFS\n'
    'extern bool __ksu_is_allow_uid_for_current(uid_t uid);',
    '#ifdef CONFIG_KSU\n'
    'extern bool __ksu_is_allow_uid_for_current(uid_t uid);')
replace_once('fs/open.c',
    '#ifdef CONFIG_KSU\n'
    '    if (likely(susfs_is_current_proc_umounted())) {\n'
    '        goto orig_flow;\n'
    '    }\n\n'
    '    if (unlikely(__ksu_is_allow_uid_for_current(current_uid().val))) {\n'
    '        ksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n'
    '    }\n\n'
    'orig_flow:\n'
    '#endif',
    '#ifdef CONFIG_KSU\n'
    '#ifdef CONFIG_KSU_SUSFS\n'
    '    if (likely(susfs_is_current_proc_umounted()))\n'
    '        goto ksu_faccessat_orig;\n'
    '#endif\n'
    '    if (unlikely(__ksu_is_allow_uid_for_current(current_uid().val)))\n'
    '        ksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n'
    '#ifdef CONFIG_KSU_SUSFS\n'
    'ksu_faccessat_orig:\n'
    '#endif\n'
    '#endif')

# fs/stat.c: SUSFS-only pre-check must not gate the basic SukiSU stat hook.
replace_once('fs/stat.c',
    '#ifdef CONFIG_KSU\n'
    '\tif (likely(susfs_is_current_proc_umounted())) {\n'
    '\t\tgoto orig_flow;\n'
    '\t}\n\n'
    '\tif (unlikely(__ksu_is_allow_uid_for_current(current_uid().val))) {\n'
    '\t\tksu_handle_stat(&dfd, &filename, &flags);\n'
    '\t}\n'
    'orig_flow:\n'
    '#endif',
    '#ifdef CONFIG_KSU\n'
    '#ifdef CONFIG_KSU_SUSFS\n'
    '\tif (likely(susfs_is_current_proc_umounted()))\n'
    '\t\tgoto ksu_stat_orig;\n'
    '#endif\n'
    '\tif (unlikely(__ksu_is_allow_uid_for_current(current_uid().val)))\n'
    '\t\tksu_handle_stat(&dfd, &filename, &flags);\n'
    '#ifdef CONFIG_KSU_SUSFS\n'
    'ksu_stat_orig:\n'
    '#endif\n'
    '#endif')

# fs/exec.c: the entire execveat hook was incorrectly hidden behind SUSFS.
replace_once('fs/exec.c',
    '#ifdef CONFIG_KSU_SUSFS\n'
    'extern bool ksu_execveat_hook __read_mostly;',
    '#ifdef CONFIG_KSU\n'
    'extern bool ksu_execveat_hook __read_mostly;')
replace_once('fs/exec.c',
    '#ifdef CONFIG_KSU_SUSFS\n'
    '\tif (likely(susfs_is_current_proc_umounted())) {\n'
    '\t\tgoto orig_flow;\n'
    '\t}\n'
    '\tif (unlikely(ksu_execveat_hook)) {\n'
    '\t\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n'
    '\t} else if ((__ksu_is_allow_uid_for_current(current_uid().val))) {\n'
    '\t\tksu_handle_execveat_sucompat(&fd, &filename, &argv, &envp, &flags);\n'
    '\t}\n'
    'orig_flow:\n'
    '#endif',
    '#ifdef CONFIG_KSU\n'
    '#ifdef CONFIG_KSU_SUSFS\n'
    '\tif (likely(susfs_is_current_proc_umounted()))\n'
    '\t\tgoto ksu_exec_orig;\n'
    '#endif\n'
    '\tif (unlikely(ksu_execveat_hook))\n'
    '\t\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n'
    '\telse if (unlikely(__ksu_is_allow_uid_for_current(current_uid().val)))\n'
    '\t\tksu_handle_execveat_sucompat(&fd, &filename, &argv, &envp, &flags);\n'
    '#ifdef CONFIG_KSU_SUSFS\n'
    'ksu_exec_orig:\n'
    '#endif\n'
    '#endif')

# kernel/reboot.c: the non-SUSFS builtin branch uses this syscall to
# install the manager's control fd; do not accidentally disable it.
replace_once('kernel/reboot.c',
    '#ifdef CONFIG_KSU_SUSFS\n'
    '    ret = ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n'
    '    if (ret) {\n'
    '        goto orig_flow;\n'
    '    }\n'
    '    return ret;\n'
    'orig_flow:\n'
    '#endif',
    '#ifdef CONFIG_KSU\n'
    '    ret = ksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n'
    '    if (ret == 0)\n'
    '        return 0;\n'
    '#endif')

print('SukiSU builtin compatibility patches applied.')
PY
    git -C KernelSU rev-parse HEAD
    grep 'KERNEL_SU_UAPI_VERSION' KernelSU/kernel/include/uapi/supercall.h || true
fi

# Build artifacts and source version tweaks are temporary. Restore the originals.
DEFCONFIG="arch/arm64/configs/${TARGET_DEVICE}_defconfig"
DEFCONFIG_BACKUP="$(mktemp)"
cp "$DEFCONFIG" "$DEFCONFIG_BACKUP"
DTS_SOURCE=arch/arm64/boot/dts/vendor/qcom
DTS_BACKUP=.dts.bak
cleanup() {
    if [[ -d "$DTS_BACKUP" ]]; then
        rm -rf "$DTS_SOURCE"
        mv "$DTS_BACKUP" "$DTS_SOURCE"
    fi
    if [[ -f "$DEFCONFIG_BACKUP" ]]; then
        cp "$DEFCONFIG_BACKUP" "$DEFCONFIG"
        rm -f "$DEFCONFIG_BACKUP"
    fi
}
trap cleanup EXIT

rm -rf out anykernel

git clone -q --depth=1 --single-branch -b kona \
    https://github.com/liyafe1997/AnyKernel3 anykernel

LOCAL_VERSION_SUFFIX="-aptusitu-$(date +%Y%m%d)-${GIT_COMMIT_ID}-perf"
# Preserve the original project's temporary localversion substitution.
sed -i "s/-perf/${LOCAL_VERSION_SUFFIX}/g" "$DEFCONFIG"

configure_ksu() {
    if [[ "$KSU_ENABLE" -eq 1 ]]; then
        scripts/config --file out/.config \
            -e KSU -d KSU_SUSFS -d KPM -e THREAD_INFO_IN_TASK \
            -d KSU_SUSFS_SUS_PATH \
            -d KSU_SUSFS_SUS_MOUNT \
            -d KSU_SUSFS_SUS_KSTAT \
            -d KSU_SUSFS_SPOOF_UNAME \
            -d KSU_SUSFS_ENABLE_LOG \
            -d KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
            -d KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
            -d KSU_SUSFS_OPEN_REDIRECT \
            -d KSU_SUSFS_SUS_MAP
    else
        scripts/config --file out/.config -d KSU -d KSU_SUSFS -d KPM
    fi
}

verify_config() {
    if [[ "$KSU_ENABLE" -eq 1 ]]; then
        grep -qx 'CONFIG_KSU=y' out/.config || { echo 'ERROR: KSU is not enabled'; exit 1; }
        grep -qx '# CONFIG_KSU_SUSFS is not set' out/.config || { echo 'ERROR: SUSFS is unexpectedly enabled'; exit 1; }
        grep -qx '# CONFIG_KPM is not set' out/.config || { echo 'ERROR: KPM is unexpectedly enabled'; exit 1; }
    fi
}

package_kernel() {
    local flavor="$1"
    local outname="Kernel_${flavor}_${TARGET_DEVICE}_${KSU_ZIP_STR}_$(date +'%Y%m%d_%H%M%S')_anykernel3_${GIT_COMMIT_ID}.zip"
    local kernel_img='out/arch/arm64/boot/Image'
    [[ -s "$kernel_img" ]] || { echo "No kernel image found for $flavor"; exit 1; }
    # Match the original build's DTB concatenation order.
    find out/arch/arm64/boot/dts -name '*.dtb' -exec cat {} + > out/arch/arm64/boot/dtb
    [[ -s out/arch/arm64/boot/dtb ]] || { echo "No DTB found for $flavor"; exit 1; }
    rm -rf anykernel/kernels
    mkdir -p anykernel/kernels
    cp "$kernel_img" out/arch/arm64/boot/dtb anykernel/kernels/
    (
        cd anykernel
        zip -q -r9 "../$outname" . \
            -x '.git/*' './.git/*' '*.zip' 'out/*'
    )
    unzip -tq "$outname" >/dev/null
    echo "Created: $outname"
}

echo '=== Building AOSP kernel ==='
make "${MAKE_ARGS[@]}" "${TARGET_DEVICE}_defconfig"
configure_ksu
make "${MAKE_ARGS[@]}" olddefconfig
verify_config
make "${MAKE_ARGS[@]}" -j"$JOBS"
package_kernel AOSP

# Restore the MIUI-specific DTS modifications from the original project.
# They are essential to avoid changing the display behavior on Xiaomi ROMs.
apply_miui_panel_fixes() {
    cp -a "$DTS_SOURCE" "$DTS_BACKUP"
    local dts_source="$DTS_SOURCE"
    sed -i 's/<154>/<1537>/g' "${dts_source}"/dsi-panel-j1s*
    sed -i 's/<154>/<1537>/g' "${dts_source}"/dsi-panel-j2*
    sed -i 's/<155>/<1544>/g' "${dts_source}"/dsi-panel-j3s-37-02-0a-dsc-video.dtsi
    sed -i 's/<155>/<1545>/g' "${dts_source}"/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
    sed -i 's/<155>/<1546>/g' "${dts_source}"/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi
    sed -i 's/<155>/<1546>/g' "${dts_source}"/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi
    sed -i 's/<70>/<695>/g' "${dts_source}"/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
    sed -i 's/<70>/<695>/g' "${dts_source}"/dsi-panel-j3s-37-02-0a-dsc-video.dtsi
    sed -i 's/<70>/<695>/g' "${dts_source}"/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi
    sed -i 's/<70>/<695>/g' "${dts_source}"/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi
    sed -i 's/<71>/<710>/g' "${dts_source}"/dsi-panel-j1s*
    sed -i 's/<71>/<710>/g' "${dts_source}"/dsi-panel-j2*

    sed -i 's/\/\/ mi,mdss-dsi-pan-enable-smart-fps/mi,mdss-dsi-pan-enable-smart-fps/g' "${dts_source}"/dsi-panel*
    sed -i 's/\/\/ mi,mdss-dsi-smart-fps-max_framerate/mi,mdss-dsi-smart-fps-max_framerate/g' "${dts_source}"/dsi-panel*
    sed -i 's/\/\/ qcom,mdss-dsi-pan-enable-smart-fps/qcom,mdss-dsi-pan-enable-smart-fps/g' "${dts_source}"/dsi-panel*
    sed -i 's/qcom,mdss-dsi-qsync-min-refresh-rate/\/\/qcom,mdss-dsi-qsync-min-refresh-rate/g' "${dts_source}"/dsi-panel*
    sed -i 's/120 90 60/120 90 60 50 30/g' "${dts_source}"/dsi-panel-g7a-36-02-0c-dsc-video.dtsi
    sed -i 's/120 90 60/120 90 60 50 30/g' "${dts_source}"/dsi-panel-g7a-37-02-0a-dsc-video.dtsi
    sed -i 's/120 90 60/120 90 60 50 30/g' "${dts_source}"/dsi-panel-g7a-37-02-0b-dsc-video.dtsi
    sed -i 's/144 120 90 60/144 120 90 60 50 48 30/g' "${dts_source}"/dsi-panel-j3s-37-02-0a-dsc-video.dtsi

    sed -i 's/\/\/39 00 00 00 00 00 03 51 03 FF/39 00 00 00 00 00 03 51 03 FF/g' "${dts_source}"/dsi-panel-j9-38-0a-0a-fhd-video.dtsi
    sed -i 's/\/\/39 00 00 00 00 00 03 51 0D FF/39 00 00 00 00 00 03 51 0D FF/g' "${dts_source}"/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi
    for name in dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi; do
        sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' "${dts_source}/$name"
    done
    sed -i 's/\/\/39 01 00 00 00 00 03 51 00 00/39 01 00 00 00 00 03 51 00 00/g' "${dts_source}"/dsi-panel-j2-38-0c-0a-dsc-cmd.dtsi
    for name in dsi-panel-j11-38-08-0a-fhd-cmd.dtsi dsi-panel-j9-38-0a-0a-fhd-video.dtsi; do
        sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' "${dts_source}/$name"
    done
    for name in dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi dsi-panel-j2-42-02-0b-dsc-cmd.dtsi dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi; do
        sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' "${dts_source}/$name"
        sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' "${dts_source}/$name"
    done
    for name in dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi; do
        sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' "${dts_source}/$name"
    done
    sed -i 's/\/\/39 01 00 00 01 00 03 51 03 FF/39 01 00 00 01 00 03 51 03 FF/g' "${dts_source}"/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
    sed -i 's/\/\/39 01 00 00 11 00 03 51 03 FF/39 01 00 00 11 00 03 51 03 FF/g' "${dts_source}"/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi
}

echo '=== Building MIUI / HyperOS kernel ==='
rm -rf out
apply_miui_panel_fixes
make "${MAKE_ARGS[@]}" "${TARGET_DEVICE}_defconfig"
configure_ksu
scripts/config --file out/.config \
    --set-str STATIC_USERMODEHELPER_PATH /system/bin/micd \
    -e PERF_CRITICAL_RT_TASK -e SF_BINDER -e OVERLAY_FS -d DEBUG_FS \
    -e MIGT -e MIGT_ENERGY_MODEL -e MIHW -e PACKAGE_RUNTIME_INFO \
    -e BINDER_OPT -e KPERFEVENTS -e MILLET -e PERF_HUMANTASK \
    -d LTO_CLANG -d LOCALVERSION_AUTO -e XIAOMI_MIUI \
    -d MI_MEMORY_SYSFS -e TASK_DELAY_ACCT -e MIUI_ZRAM_MEMORY_TRACKING \
    -d MODULE_SIG_SHA512 -d MODULE_SIG_HASH \
    -e MI_FRAGMENTION -e PERF_HELPER -e BOOTUP_RECLAIM -e MI_RECLAIM -e RTMM
make "${MAKE_ARGS[@]}" olddefconfig
verify_config
if ! grep -qx 'CONFIG_XIAOMI_MIUI=y' out/.config; then
    echo 'ERROR: CONFIG_XIAOMI_MIUI is not enabled'; exit 1
fi
make "${MAKE_ARGS[@]}" -j"$JOBS"
package_kernel MIUI

echo 'DONE. For HyperOS/MIUI use Kernel_MIUI_alioth_...zip (after separate compatibility verification).'
