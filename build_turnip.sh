#!/usr/bin/env bash
set -euo pipefail

green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="$REPO_ROOT/turnip_workdir"
NDKVER="android-ndk-r29"
NDK="$WORKDIR/$NDKVER/toolchains/llvm/prebuilt/linux-x86_64/bin"
BUILD_VERSION="${BUILD_VERSION:-1.0}"
VARIANT="${VARIANT:-a7xx}"
MESA_COMMIT="${MESA_COMMIT:-}"
# Performance knobs (all optional):
#   ENABLE_LTO=1      thin-LTO build (smaller/faster driver, longer build)
#   CPU_TUNE=...      e.g. "-mcpu=cortex-a76" ; leave empty for max device compatibility
ENABLE_LTO="${ENABLE_LTO:-0}"
CPU_TUNE="${CPU_TUNE:-}"
#   DEFAULT_TU_DEBUG  TU_DEBUG flags baked into the driver as default (a6xx).
#                     A TU_DEBUG set by the app/user at runtime still overrides it.
DEFAULT_TU_DEBUG="${DEFAULT_TU_DEBUG:-}"
#   FLUSH_EXTRA       comma list of cache flushes/waits added at every flush point
#                     (finer-grained "flushall"): ccu_color,ccu_depth,uche_clean,
#                     uche_inval,wmw,wfi,wfm,bindless
FLUSH_EXTRA="${FLUSH_EXTRA:-}"
#   SYNC_MODE         cheaper "syncdraw": add waits only on some draws.
#                     state | program | desc | ps | nops | zw | zro | nodepth | stencil | every:N
#   SYNC_BITS         which waits to add: wfi,wmw,wfm (default all three = syncdraw)
SYNC_MODE="${SYNC_MODE:-}"
SYNC_BITS="${SYNC_BITS:-wfi,wmw,wfm}"
#   SYNC_NONDRAW      waits/flushes added ONLY at non-draw flush points (copies, blits,
#                     clears, dispatch, events, pass boundaries). Items: wfi,wmw,wfm,flushall
SYNC_NONDRAW="${SYNC_NONDRAW:-}"

# tu/a6xx: Work around D32S8 EARLY_Z_LATE_Z hang
REVERT_COMMIT="a70d2af590db192f87b3af01f83a68b450edb4c3"

log() { echo -e "${green}$*${nocolor}"; }
die() { echo -e "${red}$*${nocolor}" >&2; exit 1; }

check_deps() {
    local deps="git meson ninja patchelf unzip curl pip flex bison zip glslangValidator python3 patch"
    for dep in $deps; do
        command -v "$dep" >/dev/null 2>&1 || die "Falta a dependência: $dep"
    done
    pip install mako --break-system-packages >/dev/null 2>&1 || true
}

prepare_workdir() {
    mkdir -p "$WORKDIR"
    if [ ! -d "$WORKDIR/$NDKVER" ]; then
        log "Baixando Android NDK r29..."
        curl -sL "https://dl.google.com/android/repository/${NDKVER}-linux.zip" -o "$WORKDIR/${NDKVER}-linux.zip"
        unzip -q "$WORKDIR/${NDKVER}-linux.zip" -d "$WORKDIR"
    fi

    rm -rf "$WORKDIR/mesa"
    mkdir -p "$WORKDIR/mesa"
    git -C "$WORKDIR/mesa" init -q
    git -C "$WORKDIR/mesa" remote add origin https://gitlab.freedesktop.org/mesa/mesa.git

    if [ -n "$MESA_COMMIT" ]; then
        log "Buscando Mesa fixado em $MESA_COMMIT..."
        git -C "$WORKDIR/mesa" fetch -q --depth=1 origin "$MESA_COMMIT"
    else
        log "Buscando Mesa main..."
        git -C "$WORKDIR/mesa" fetch -q --depth=1 origin refs/heads/main
    fi
    git -C "$WORKDIR/mesa" checkout -q --detach FETCH_HEAD
}

revert_d32s8_commit() {
    log "A7xx: revertendo workaround D32S8 EARLY_Z_LATE_Z..."
    if ! git cat-file -e "${REVERT_COMMIT}^{commit}" 2>/dev/null; then
        git fetch -q --depth=2 origin "$REVERT_COMMIT"
    fi
    git revert --no-commit "$REVERT_COMMIT" || {
        git revert --abort 2>/dev/null || true
        git reset --hard HEAD
        die "Falha ao reverter $REVERT_COMMIT"
    }
}

apply_a7xx_base() {
    revert_d32s8_commit

    log "A7xx: aplicando has_early_preamble=False..."
    if ! grep -A20 'a7xx_gen1 = GPUProps(' src/freedreno/common/freedreno_devices.py | grep -q 'has_early_preamble = False'; then
        sed -i '/a7xx_gen1 = GPUProps(/a \\        has_early_preamble = False,' src/freedreno/common/freedreno_devices.py
    fi
    python3 -m py_compile src/freedreno/common/freedreno_devices.py
}

apply_oneui_glitch() {
    log "A7xx OneUI: aplicando 8g2_ui_glitch.patch..."
    patch -p1 --forward < "$REPO_ROOT/8g2_ui_glitch.patch"
}

apply_Gen8_a8xx() {
    log "A8xx Gen8: aplicando whitebelyash turnip/gen8 stack..."
    patch -p1 -N --fuzz=4 --no-backup-if-mismatch < "$REPO_ROOT/patches/patchsv2/a8xx_gen8.patch"

    log "A8xx Gen8: shared memory 32 KiB -> 64 KiB..."
    python3 "$REPO_ROOT/patches/patchsv2/a8xx_shared_mem.py"

    # Compatibility Android gralloc/UBWC support is already ported in our
    # Patched Android recipe. Reuse the same implementation for Gen8.
    log "A8xx Gen8: enabling modern Qualcomm gralloc and UBWC..."
    python3 "$REPO_ROOT/patches/patchsv1/android/fix_gralloc_flushall.py"
    python3 "$REPO_ROOT/patches/patchsv1/android/add_aimapper_gralloc.py"
    python3 "$REPO_ROOT/patches/patchsv1/android/add_ubwc_swapchain_usage.py"
}

apply_Patched_android_scripts() {
    log "A8xx Patched: aplicando recipe Android/Bionic production..."
    local scripts=(
        fix_gralloc_flushall.py
        fix_a8xx_dev_info.py
        apply_a8xx_gpus.py
        apply_a7xx_gen1_quirks.py
        apply_a7xx_gen2_ubwc_hint.py
        add_aimapper_gralloc.py
        add_ubwc_swapchain_usage.py
    )
    local script
    for script in "${scripts[@]}"; do
        log "Patched: $script"
        python3 "$REPO_ROOT/patches/patchsv1/android/$script"
    done

    log "Patched: usando variante balanced..."
    python3 "$REPO_ROOT/patches/patchsv1/android/apply_balance_variant.py"
}

apply_Patched_extra_patches() {
    log "A8xx Patched: aplicando patchset extra 0001-0005..."
    local patch_file
    local count=0
    for patch_file in "$REPO_ROOT"/patches/patchsv1/000*.patch; do
        [ -f "$patch_file" ] || continue
        log "Verificando $(basename "$patch_file")..."
        if ! git apply --check "$patch_file"; then
            git apply --check --verbose "$patch_file" || true
            die "Patch Patched não aplica limpo: $(basename "$patch_file")"
        fi
        git apply "$patch_file"
        count=$((count + 1))
    done
    [ "$count" -eq 5 ] || die "Esperados 5 patches Patched, encontrados $count"
}

# Compatibility-derived A8xx register adjustments. Existing Patched scope.
# These are not the A8xx-17 Turnip-Z mutable/BGRA patches.
apply_Compatibility_Patched_registers_only() {
    log "A8xx Patched: applying Compatibility A8xx register adjustments..."
    local dd="$REPO_ROOT/patches/patchsv3/scripts"

    python3 "$dd/a8xx_resolve_cr_cntl.py"
    # Disabled: on A830 the hysteresis registers reduced DriverLab card FPS by
    # ~6% without a demonstrated correctness gain (Gen8 4ccd4e9).
    python3 "$dd/a8xx_lrz_color_mask.py"

    grep -Fq 'A6XXRegs.REG_A8XX_RB_RESOLVE_CR_CNTL' src/freedreno/common/freedreno_devices.py \
        || die "A8xx A8xx: RB_RESOLVE_CR_CNTL preamble missing"
    grep -Fq 'GRAS_LRZ_COLOR_COMP_MASK(CHIP, .dword = lrz_color_comp_mask)' src/freedreno/vulkan/tu_pipeline.cc \
        || die "A8xx A8xx: LRZ color mask missing"
}

apply_a8xx_game_profiles() {
    log "A8xx: installing game-specific SSBO emulation profiles..."
    python3 "$REPO_ROOT/patches/a8xx/game_ssbo_profiles.py"
}

# Compatibility Android fixes, scoped to A8xx Gen8 and A8xx Patched only.
# Preserve the existing variant-specific GPU recipes and Patched patches.
apply_Compatibility_a8xx() {
    log "A8xx: applying Compatibility compatibility fixes (without KGSL PWR_MAX)..."
    local dd="$REPO_ROOT/patches/patchsv3"

    # The two A8xx recipes already supply A825 and most A810/A829 settings;
    # add only missing KGSL aliases, plus A845/A850, not a duplicate GPU stack.
    python3 "$dd/scripts/a8xx_gpu_ids.py"
    python3 "$dd/scripts/apply_a8xx_cat4_rpt.py"
    python3 "$dd/scripts/process_heap_usage.py"

    # Existing Patched IMapper/UBWC changes also run for Gen8.
    grep -Fq 'u_gralloc_aimapper.c' src/util/u_gralloc/meson.build \
        || die "A8xx: IMapper5 backend not built"
    grep -Fq 'U_GRALLOC_TYPE_AIMAPPER' src/util/u_gralloc/u_gralloc.h \
        || die "A8xx: IMapper5 backend enum missing"
    grep -Fq 'ahb_vendor_usage_compressed = 0x10000000ull' src/freedreno/vulkan/tu_device.cc \
        || die "A8xx: vendor UBWC allocation usage missing"
    grep -Fq 'UBWC flag detection - bypass legacy gmsm magic check for A8XX/A840.' src/util/u_gralloc/u_gralloc_fallback.c \
        || die "A8xx: bounds-checked Qualcomm gralloc UBWC detection missing"
    grep -Fq 'tu_process_heap_used' src/freedreno/vulkan/tu_device.cc \
        || die "A8xx: process-wide memory budget fix missing"
    grep -Fq '0x44041430' src/freedreno/common/freedreno_devices.py \
        || die "A8xx: A845 ID missing"
    grep -Fq '0x44051431' src/freedreno/common/freedreno_devices.py \
        || die "A8xx: A850 ID missing"
}

# MR !44838 (Mesa main, 2026-10-08):
# 1da50a1b: correctly merge KGSL timestamp syncobjs and sync-file fds.
# e984ef29: poll retired GPU timestamps for zero-timeout checks without blocking.
# These fixes are upstream. Never apply the obsolete local zero-timeout patch.
verify_mesa_mr_44838() {
    local kgsl="src/freedreno/vulkan/tu_knl_kgsl.cc"
    log "Common: verifying upstream Mesa MR !44838 KGSL fixes..."

    [ -f "$kgsl" ] || die "Missing $kgsl"
    grep -Fq 'kgsl_syncobj_merge(struct tu_device *device' "$kgsl" \
        || die "Mesa is missing MR !44838 mixed timestamp/sync-file merge fix (1da50a1b)"
    grep -Fq 'return kgsl_poll_timestamp(device, context_id, timestamp);' "$kgsl" \
        || die "Mesa is missing MR !44838 zero-timeout nonblocking poll fix (e984ef29)"
    log "Mesa MR !44838: both upstream KGSL fixes verified"
}

# Bake default TU_DEBUG flags into the driver itself, so no emulator/app
# setting is needed. Implemented as a library constructor (runs at dlopen,
# before Turnip parses TU_DEBUG) and only applies when TU_DEBUG is unset.
apply_default_tu_debug() {
    [ -n "$DEFAULT_TU_DEBUG" ] || return 0
    log "Baking default TU_DEBUG=$DEFAULT_TU_DEBUG into the driver..."
    local f="src/freedreno/vulkan/tu_util.cc"
    [ -f "$f" ] || die "Missing $f"
    # Unknown TU_DEBUG names are silently ignored by Mesa: refuse them here.
    local flag
    for flag in ${DEFAULT_TU_DEBUG//,/ }; do
        grep -rqF "\"$flag\"" src/freedreno/vulkan \
            || die "TU_DEBUG flag '$flag' not found in this Mesa (tu_util.cc option table)"
    done
    cat >> "$f" <<EOF2

/* Added by build script: default TU_DEBUG, overridable by the environment. */
#include <stdlib.h>
__attribute__((constructor(101)))
static void tu_default_debug_ctor(void)
{
   setenv("TU_DEBUG", "$DEFAULT_TU_DEBUG", 0);
}
EOF2
    tail -8 "$f"
}

apply_flush_extra() {
    [ -n "$FLUSH_EXTRA" ] || return 0
    log "Adding extra flushes at every flush point: $FLUSH_EXTRA"
    FLUSH_EXTRA="$FLUSH_EXTRA" python3 - <<'PYEOF'
import os, sys
m = {
 "ccu_color":  "TU_CMD_FLAG_CCU_CLEAN_COLOR | TU_CMD_FLAG_CCU_INVALIDATE_COLOR",
 "ccu_depth":  "TU_CMD_FLAG_CCU_CLEAN_DEPTH | TU_CMD_FLAG_CCU_INVALIDATE_DEPTH",
 "uche_clean": "TU_CMD_FLAG_CACHE_CLEAN",
 "uche_inval": "TU_CMD_FLAG_CACHE_INVALIDATE",
 "wmw":        "TU_CMD_FLAG_WAIT_MEM_WRITES",
 "wfi":        "TU_CMD_FLAG_WAIT_FOR_IDLE",
 "wfm":        "TU_CMD_FLAG_WAIT_FOR_ME",
 "bindless":   "TU_CMD_FLAG_BINDLESS_DESCRIPTOR_INVALIDATE",
}
names = [n for n in os.environ["FLUSH_EXTRA"].split(",") if n]
bad = [n for n in names if n not in m]
if bad:
    sys.exit("unknown flush_extra item(s): %s (valid: %s)" % (bad, ",".join(m)))
expr = " |\n                 ".join(m[n] for n in names)

p = "src/freedreno/vulkan/tu_cmd_buffer.cc"
s = open(p).read()

a1 = """   if (TU_DEBUG(SYNCDRAW))
      flushes |= TU_CMD_FLAG_WAIT_MEM_WRITES |
                 TU_CMD_FLAG_WAIT_FOR_IDLE |
                 TU_CMD_FLAG_WAIT_FOR_ME;
"""
assert s.count(a1) == 1, "anchor 1 (SYNCDRAW block) not found exactly once"
s = s.replace(a1, a1 + "\n   /* build-time extra flushes (FLUSH_EXTRA) */\n   flushes |= " + expr + ";\n")

a2 = """   if (!cmd_buffer->state.renderpass_cache.flush_bits &&
       likely(!tu_env.debug))
      return;
"""
assert s.count(a2) == 1, "anchor 2 (renderpass early return) not found exactly once"
s = s.replace(a2, """   if (!cmd_buffer->state.renderpass_cache.flush_bits &&
       likely(!tu_env.debug) && false)
      return;
""")
open(p, "w").write(s)
print("patched", p)
PYEOF
}

apply_sync_mode() {
    [ -n "$SYNC_MODE" ] || return 0
    log "Selective draw sync: mode=$SYNC_MODE bits=$SYNC_BITS"
    SYNC_MODE="$SYNC_MODE" SYNC_BITS="$SYNC_BITS" python3 - <<'PYEOF'
import os, sys
bits = {"wfi": "TU_CMD_FLAG_WAIT_FOR_IDLE", "wmw": "TU_CMD_FLAG_WAIT_MEM_WRITES",
        "wfm": "TU_CMD_FLAG_WAIT_FOR_ME"}
names = [n for n in os.environ["SYNC_BITS"].split(",") if n]
bad = [n for n in names if n not in bits]
if bad or not names:
    sys.exit("bad SYNC_BITS %r (valid: wfi,wmw,wfm)" % names)
flags = " | ".join(bits[n] for n in names)

mode = os.environ["SYNC_MODE"]
if mode == "state":
    cond = "(tu_sync_dyn || (tu_sync_dirty & ~TU_CMD_DIRTY_COMPUTE_DESC_SETS))"
elif mode == "program":
    cond = ("(tu_sync_dirty & (TU_CMD_DIRTY_PROGRAM | TU_CMD_DIRTY_VS | "
            "TU_CMD_DIRTY_FS | TU_CMD_DIRTY_TCS | TU_CMD_DIRTY_TES))")
elif mode == "desc":
    cond = "(tu_sync_dirty & TU_CMD_DIRTY_DESC_SETS)"
elif mode == "zw":      # draws that write depth
    cond = "(cmd->vk.dynamic_graphics_state.ds.depth.write_enable)"
elif mode == "zro":     # depth test without depth write (read-only depth)
    cond = ("(cmd->vk.dynamic_graphics_state.ds.depth.test_enable && "
            "!cmd->vk.dynamic_graphics_state.ds.depth.write_enable)")
elif mode == "nodepth": # no depth test and no depth write
    cond = ("(!cmd->vk.dynamic_graphics_state.ds.depth.test_enable && "
            "!cmd->vk.dynamic_graphics_state.ds.depth.write_enable)")
elif mode == "stencil": # stencil test enabled
    cond = "(cmd->vk.dynamic_graphics_state.ds.stencil.test_enable)"
elif mode == "ps":      # only draws that have a fragment shader
    cond = "(cmd->state.shaders[MESA_SHADER_FRAGMENT] && !cmd->state.disable_fs)"
elif mode == "nops":    # only depth-only draws (no fragment shader)
    cond = "(!cmd->state.shaders[MESA_SHADER_FRAGMENT] || cmd->state.disable_fs)"
elif mode.startswith("every:"):
    n = int(mode.split(":")[1]); assert n > 0
    cond = "((++tu_sync_ctr %% %d) == 0)" % n
else:
    sys.exit("bad SYNC_MODE " + mode)

p = "src/freedreno/vulkan/tu_cmd_buffer.cc"
s = open(p).read()

a1 = "   uint32_t dynamic_draw_state_dirty = 0;\n"
assert s.count(a1) == 1, "anchor 1 not unique/found"
s = s.replace(a1, """   /* build-time selective draw sync (SYNC_MODE) */
   static thread_local uint32_t tu_sync_ctr;
   const uint32_t tu_sync_dirty = cmd->state.dirty;
   const bool tu_sync_dyn = !BITSET_IS_EMPTY(cmd->vk.dynamic_graphics_state.dirty);
   (void) tu_sync_ctr; (void) tu_sync_dirty; (void) tu_sync_dyn;
""" + a1)

a2 = """   if (cmd->state.dirty & TU_CMD_DIRTY_FS)
      tu_flush_dynamic_input_attachments<CHIP>(cmd);

   tu_emit_cache_flush_renderpass<CHIP>(cmd);
"""
assert s.count(a2) == 1, "anchor 2 not unique/found"
s = s.replace(a2, """   if (cmd->state.dirty & TU_CMD_DIRTY_FS)
      tu_flush_dynamic_input_attachments<CHIP>(cmd);

   if (%s)
      cmd->state.renderpass_cache.flush_bits |= %s;

   tu_emit_cache_flush_renderpass<CHIP>(cmd);
""" % (cond, flags))
open(p, "w").write(s)
print("patched sync mode", mode, flags)
PYEOF
}

apply_nondraw_sync() {
    [ -n "$SYNC_NONDRAW" ] || return 0
    log "Sync only at non-draw flush points: $SYNC_NONDRAW"
    SYNC_NONDRAW="$SYNC_NONDRAW" python3 - <<'PYEOF'
import os, sys
m = {"wfi": "TU_CMD_FLAG_WAIT_FOR_IDLE", "wmw": "TU_CMD_FLAG_WAIT_MEM_WRITES",
     "wfm": "TU_CMD_FLAG_WAIT_FOR_ME",
     "flushall": "TU_CMD_FLAG_ALL_CLEAN | TU_CMD_FLAG_ALL_INVALIDATE"}
names = [n for n in os.environ["SYNC_NONDRAW"].split(",") if n]
bad = [n for n in names if n not in m]
if bad or not names:
    sys.exit("bad SYNC_NONDRAW %r (valid: %s)" % (names, ",".join(m)))
expr = " |\n                 ".join(m[n] for n in names)

p = "src/freedreno/vulkan/tu_cmd_buffer.cc"
s = open(p).read()

# 1. flag + extra flushes inside tu6_emit_flushes, skipped for draw-time flushes
a0 = "template <chip CHIP>\nstatic void\ntu6_emit_flushes("
assert s.count(a0) == 1, "anchor 0 not found"
s = s.replace(a0, "static thread_local bool tu_in_draw_flush;\n\n" + a0)

a1 = """   if (TU_DEBUG(SYNCDRAW))
      flushes |= TU_CMD_FLAG_WAIT_MEM_WRITES |
                 TU_CMD_FLAG_WAIT_FOR_IDLE |
                 TU_CMD_FLAG_WAIT_FOR_ME;
"""
assert s.count(a1) == 1, "anchor 1 not found"
s = s.replace(a1, a1 + "\n   /* build-time: sync only at non-draw flush points */\n"
              "   if (!tu_in_draw_flush)\n      flushes |= " + expr + ";\n")

# 2. mark the draw-time flush in tu6_draw_common
a2 = "   tu_emit_cache_flush_renderpass<CHIP>(cmd);\n\n  if (BITSET_TEST("
assert s.count(a2) == 1, "anchor 2 not found"
s = s.replace(a2, "   tu_in_draw_flush = true;\n   tu_emit_cache_flush_renderpass<CHIP>(cmd);\n"
              "   tu_in_draw_flush = false;\n\n  if (BITSET_TEST(")

# 3. make sure renderpass flush point is not skipped when nothing is pending
a3 = """   if (!cmd_buffer->state.renderpass_cache.flush_bits &&
       likely(!tu_env.debug))
      return;
"""
if s.count(a3) == 1:
    s = s.replace(a3, """   if (!cmd_buffer->state.renderpass_cache.flush_bits &&
       likely(!tu_env.debug) && false)
      return;
""")
else:
    assert "likely(!tu_env.debug) && false" in s, "anchor 3 not found"
open(p, "w").write(s)
print("patched nondraw sync:", names)
PYEOF
}

apply_android_ndk_fixes() {
    log "Aplicando fixes Android/NDK r29..."
    sed -i 's/typedef const native_handle_t\* buffer_handle_t;/typedef void* buffer_handle_t;/g' include/android_stub/cutils/native_handle.h || true
    sed -i 's/, hnd->handle/, (void *)hnd->handle/g' src/util/u_gralloc/u_gralloc_fallback.c || true
    sed -i -E 's/([a-z_]+)->handle->/((const native_handle_t *)\1->handle)->/g' src/vulkan/runtime/vk_android.c || true
    sed -i 's/anb->handle->/((const native_handle_t *)anb->handle)->/g' src/vulkan/runtime/vk_android.c || true
    sed -i "/-Werror=gnu-empty-initializer/d" meson.build || true
}

clean_a7xx_driver_names() {
    find src/freedreno/vulkan -type f -name "*.c*" -exec sed -i         's/"Turnip Adreno (TM) %s[^"]*"/"Turnip Adreno (TM) %s%.0s"/g' {} + || true
    find src/freedreno/vulkan -type f -name "*.c*" -exec sed -i         's/"turnip Mesa driver (whitebelyash branch)"/"Turnip"/g' {} + || true
    find src/freedreno/vulkan -type f -name "*.c*" -exec sed -i         's/"turnip Mesa driver"/"Turnip"/g' {} + || true
}

configure_variant() {
    case "$VARIANT" in
        a6xx)
            # Adreno 6xx: plain upstream Mesa. Do NOT revert the D32S8
            # EARLY_Z_LATE_Z workaround (a70d2af5) - it prevents GPU hangs on a6xx.
            clean_a7xx_driver_names
            ;;
        a7xx)
            apply_a7xx_base
            clean_a7xx_driver_names
            ;;
        a7xx-oneui)
            apply_a7xx_base
            apply_oneui_glitch
            clean_a7xx_driver_names
            ;;
        a8xx-gen8)
            revert_d32s8_commit
            apply_Gen8_a8xx
            ;;
        a8xx-patched)
            apply_Patched_android_scripts
            apply_Patched_extra_patches
            apply_Compatibility_Patched_registers_only
            ;;
        *)
            die "VARIANT inválido: $VARIANT"
            ;;
    esac
}

build_android() {
    local cver=36
    [ -f "$NDK/aarch64-linux-android${cver}-clang" ] || cver=35
    [ -f "$NDK/aarch64-linux-android${cver}-clang" ] || cver=34
    [ -f "$NDK/aarch64-linux-android${cver}-clang" ] || die "Clang Android aarch64 não encontrado"

    mkdir -p "$WORKDIR/bin"
    ln -sf "$NDK/clang" "$WORKDIR/bin/cc"
    ln -sf "$NDK/clang++" "$WORKDIR/bin/c++"

    export PATH="$WORKDIR/bin:$NDK:$PATH"
    export CC=clang
    export CXX=clang++
    export AR=llvm-ar
    export RANLIB=llvm-ranlib
    export STRIP=llvm-strip
    export OBJDUMP=llvm-objdump
    export OBJCOPY=llvm-objcopy
    export LDFLAGS="-fuse-ld=lld -Wl,-O2 -Wl,--gc-sections -Wl,--as-needed"
    export CFLAGS="-O3 -fno-semantic-interposition ${CPU_TUNE} -D__ANDROID__ -Wno-error -Wno-error=gnu-empty-initializer -Wno-gnu-empty-initializer -Wno-deprecated-declarations -Wno-incompatible-pointer-types-discards-qualifiers -Wno-incompatible-pointer-types"
    export CXXFLAGS="-O3 -fno-semantic-interposition ${CPU_TUNE} -D__ANDROID__ -Wno-error -Wno-error=gnu-empty-initializer -Wno-gnu-empty-initializer -Wno-deprecated-declarations -Wno-incompatible-pointer-types-discards-qualifiers -Wno-incompatible-pointer-types"

    cat > android-aarch64.txt <<EOF
[binaries]
ar = '$NDK/llvm-ar'
c = ['$NDK/aarch64-linux-android${cver}-clang']
cpp = ['$NDK/aarch64-linux-android${cver}-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
c_ld = '$NDK/ld.lld'
cpp_ld = '$NDK/ld.lld'
strip = '$NDK/llvm-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=$NDK/pkg-config', '/usr/bin/pkg-config']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

    cat > native.txt <<EOF
[build_machine]
c = ['clang']
cpp = ['clang++']
ar = 'llvm-ar'
strip = 'llvm-strip'
c_ld = 'ld.lld'
cpp_ld = 'ld.lld'
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

    local build_dir="build-android-aarch64"
    local output_dir="/tmp/turnip-$VARIANT"
    rm -rf "$build_dir" "$output_dir"

    local extra_meson=(-Db_ndebug=true)
    if [ "$ENABLE_LTO" = "1" ]; then
        extra_meson+=(-Db_lto=true -Db_lto_mode=thin)
    fi

    meson setup "$build_dir"         --cross-file android-aarch64.txt         --native-file native.txt         --prefix "$output_dir"         -Dbuildtype=release         -Dstrip=true         -Dplatforms=android         -Dvideo-codecs=         -Dplatform-sdk-version=36         -Dandroid-stub=true         -Dgallium-drivers=         -Dvulkan-drivers=freedreno         -Dvulkan-beta=true         -Dfreedreno-kmds=kgsl         -Degl=disabled         -Dandroid-libbacktrace=disabled "${extra_meson[@]}"

    ninja -C "$build_dir" install

    [ -f "$output_dir/lib/libvulkan_freedreno.so" ] || die "libvulkan_freedreno.so não foi gerada"

    if [ -n "$DEFAULT_TU_DEBUG" ] && [ "$VARIANT" = "a6xx" ]; then
        local dynsyms
        dynsyms="$("$NDK/llvm-objdump" -T "$output_dir/lib/libvulkan_freedreno.so")"
        grep -qw setenv <<<"$dynsyms" \
            || die "Default TU_DEBUG was NOT baked into the driver (setenv missing)"
        log "Verified: default TU_DEBUG=$DEFAULT_TU_DEBUG is inside the driver"
    fi
}

package_variant() {
    local mesa_short
    mesa_short="$(git rev-parse --short=12 HEAD)"

    local pretty_name desc suffix
    case "$VARIANT" in
        a6xx)
            pretty_name="Turnip A6xx"
            desc="Adreno 6xx Android/Bionic, upstream Mesa with D32S8 hang workaround kept, -O3"
            suffix="A6xx"
            ;;
        a7xx)
            pretty_name="Turnip A7xx"
            desc="StevenMXZ A7xx Android/Bionic — revert D32S8 + has_early_preamble=False"
            suffix="A7xx"
            ;;
        a7xx-oneui)
            pretty_name="Turnip A7xx OneUI Glitch"
            desc="StevenMXZ A7xx Android/Bionic + OneUI 8g2 UI glitch fix"
            suffix="A7xx-OneUI-Glitch"
            ;;
        a8xx-gen8)
            pretty_name="Turnip A8xx Gen8"
            desc="A8xx Gen8 Android/Bionic GPU configuration, 64 KiB shared memory and A840v2 support"
            suffix="A8xx-Gen8"
            ;;
        a8xx-patched)
            pretty_name="Turnip A8xx Patched"
            desc="A8xx Android/Bionic balanced configuration with additional 0001-0005 patches"
            suffix="A8xx-Patched"
            ;;
    esac

    local output_dir="/tmp/turnip-$VARIANT"
    cd "$output_dir/lib"

    cat > meta.json <<EOF
{
  "schemaVersion": 1,
  "name": "$pretty_name",
  "description": "$desc — Mesa $mesa_short",
  "author": "StevenMXZ",
  "packageVersion": "$BUILD_VERSION",
  "vendor": "Mesa",
  "driverVersion": "Mesa-$mesa_short",
  "minApi": 28,
  "libraryName": "libvulkan_freedreno.so"
}
EOF

    if [ "$VARIANT" = "a6xx" ] && [ -n "$DEFAULT_TU_DEBUG" ]; then
        suffix="${suffix}-${DEFAULT_TU_DEBUG//,/-}"
        desc="$desc [TU_DEBUG=$DEFAULT_TU_DEBUG baked in]"
        pretty_name="$pretty_name ($DEFAULT_TU_DEBUG)"
        sed -i "s|\"name\": \".*\"|\"name\": \"$pretty_name\"|; s|\"description\": \".*\"|\"description\": \"$desc — Mesa $mesa_short\"|" meta.json
    fi
    if [ "$VARIANT" = "a6xx" ] && [ -n "$FLUSH_EXTRA" ]; then
        suffix="${suffix}-fx-${FLUSH_EXTRA//,/-}"
        desc="$desc [extra flushes: $FLUSH_EXTRA]"
        pretty_name="$pretty_name (fx: $FLUSH_EXTRA)"
        sed -i "s|\"name\": \".*\"|\"name\": \"$pretty_name\"|; s|\"description\": \".*\"|\"description\": \"$desc — Mesa $mesa_short\"|" meta.json
    fi
    if [ "$VARIANT" = "a6xx" ] && [ -n "$SYNC_MODE" ]; then
        local sm="${SYNC_MODE//:/}-${SYNC_BITS//,/-}"
        suffix="${suffix}-sync-${sm}"
        desc="$desc [selective sync: $SYNC_MODE $SYNC_BITS]"
        pretty_name="$pretty_name (sync $SYNC_MODE $SYNC_BITS)"
        sed -i "s|\"name\": \".*\"|\"name\": \"$pretty_name\"|; s|\"description\": \".*\"|\"description\": \"$desc — Mesa $mesa_short\"|" meta.json
    fi
    if [ "$VARIANT" = "a6xx" ] && [ -n "$SYNC_NONDRAW" ]; then
        suffix="${suffix}-nondraw-${SYNC_NONDRAW//,/-}"
        desc="$desc [sync only at non-draw points: $SYNC_NONDRAW]"
        pretty_name="$pretty_name (nondraw $SYNC_NONDRAW)"
        sed -i "s|\"name\": \".*\"|\"name\": \"$pretty_name\"|; s|\"description\": \".*\"|\"description\": \"$desc — Mesa $mesa_short\"|" meta.json
    fi
    local zip_name="Turnip_${suffix}_V${BUILD_VERSION}_${mesa_short}.zip"
    rm -f "$WORKDIR/$zip_name"
    zip -9 -q "$WORKDIR/$zip_name" libvulkan_freedreno.so meta.json
    log "Gerado: $WORKDIR/$zip_name"
}

main() {
    check_deps
    prepare_workdir
    cd "$WORKDIR/mesa"

    log "Mesa: $(git rev-parse HEAD)"
    log "Variante: $VARIANT"

    verify_mesa_mr_44838
    configure_variant
    if [ "$VARIANT" = "a8xx-gen8" ] || [ "$VARIANT" = "a8xx-patched" ]; then
        apply_Compatibility_a8xx
        apply_a8xx_game_profiles
    fi
    if [ "$VARIANT" = "a6xx" ]; then
        apply_default_tu_debug
        apply_flush_extra
        apply_sync_mode
        apply_nondraw_sync
    fi
    apply_android_ndk_fixes
    build_android
    package_variant
}

main "$@"
