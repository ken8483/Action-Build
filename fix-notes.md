# 真我 GT Neo5 SE (SM7475/waipio) GKI 内核构建修复说明

针对 `ken8483/Action-Build` 的 `Build Kernel OnePlus.yml`，
参照失败的 run [42871536015 / job 130023766962](https://github.com/ken8483/Action-Build/actions/runs/42871536015/job/130023766962) 做的定位与修复。

---

## 1. 你的设备对应哪些参数（已写进 workflow 默认值）

| 项 | 值 | 来源 |
|---|---|---|
| 机型 | `realme_gt_neo5se_v` | 清单在 `Numbersf/Kernel_Manifest_Appendix` 的 `realme/sm7475` 分支 |
| SoC / 平台 | SM7475 / **waipio** | 清单 README：`./kernel_platform/oplus/build/oplus_build_kernel.sh waipio gki` |
| KMI | `android12-5.10`，KMI_GENERATION=9 | `build.config.common`（`BRANCH=android12-5.10` / `KMI_GENERATION=9`） |
| 内核版本串 | `5.10.246-android12-9-0-g931a7e2ba585` | 你给的 `uname -r` |
| 构建时间戳 | `Thu Aug 13 10:46:39 UTC 2026` | 你给的原厂内核编译时间 |
| 管理器 | SukiSU Ultra（内核侧用 `builtin` 分支） | `KSU_META=main/builtin/SukiSUUltra/` |

源码仓库（公开）：`realme-kernel-opensource/realme_gt_neo5se-AndroidV-{common,kernel,vendor}-source`

---

## 2. 原来的 run 为什么失败

失败步骤是 **Build Kernel FAST**（`make` 退出码 2）。根因不是玄学编译错误，而是**这条工作流对"厂商混合构建机型"的 FAST 路径根本不适用**：

### 2.1 FAST 路径编错了树

`Build Kernel FAST` 里写死了：

```bash
cd kernel_workspace/kernel_platform
cd ./common
make O=out gki_defconfig
```

但真我这份清单里除了 `kernel_platform/common`，还有一棵厂商树 `kernel_platform/msm-kernel`，
而 realme 自己的 `build.config.msm.waipio` 明确写着：

```sh
MSM_ARCH=waipio
VARIANTS=(consolidate gki)
if [ -e "${ROOT_DIR}/msm-kernel" -a "${KERNEL_DIR}" = "common" ]; then
        KERNEL_DIR="msm-kernel"      # ← 官方构建根本不用 common 当内核树
fi
```

官方 GKI 构建是 **mixed build**：`common` 提供 GKI 内核，`msm-kernel` 提供厂商模块，
并且还要叠加 `msm-kernel/arch/arm64/configs/vendor/waipio_GKI.config` 片段、
KMI symbol list（`abi_gki_aarch64_qcom` + `abi_gki_aarch64_oplus`）、厂商 dtb 等。
FAST 路径这些全都没有 → 配置与原厂不一致，编不过 / 编出来也不对。

### 2.2 FAST 一挂，兜底路径根本没机会跑

`Fallback to Build Kernel` 的触发条件只有 `FAST_BUILD == 'false'` 或 `fast_build.outputs.fallback == 'true'`。
FAST 步骤是硬失败（没有 `continue-on-error`）→ job 直接死掉 → 官方脚本路径永远轮不到。

### 2.3 版本号只改了一棵树

`RESUBLEVEL`（内核等级欺骗）原来只改 `./common/Makefile`。
混合构建下实际参与编译的是 `msm-kernel`，两棵树版本号必须同时改。

### 2.4 官方路径下后缀注入会产出错误版本串（实测）

`Custom Kernel Suffix if set` 用格式匹配来改 `scripts/setlocalversion`：

* `FAST_BUILD=true` 分支：改写所有 `^res=` 行 → **结果正确**
* `FAST_BUILD=false` 分支（官方脚本路径）：用 `cut -d- -f1-2` 拼接 →
  厂商片段里的 `CONFIG_LOCALVERSION="-gki"` 没被清掉，产出 **`5.10.246-gki-9-0-g931a7e2ba585`** ❌

实测矩阵（用真机真实的 `scripts/setlocalversion` 跑）：

```
原版 FAST_BUILD=true   ✅ 5.10.246-android12-9-0-g931a7e2ba585
原版 FAST_BUILD=false  ❌ 5.10.246-gki-9-0-g931a7e2ba585
```

**为什么这个必须一模一样**：`vendor_dlkm` 里每个模块的 vermagic 里写死了 `UTS_RELEASE`。
差一个字符 → 模块全部 `version magic '...' should be '...'` 加载失败 →
没有 WiFi / 相机 / 触摸 / 指纹，整机等于半残。

---

## 3. 改了什么（共 7 处，全部带注释）

文件：`output/Build Kernel OnePlus.yml`（相对原版 +5959 字节）

1. **默认输入改成你的机型**
   `FILE=realme_gt_neo5se_v`、`BUILD_TIME=Thu Aug 13 10:46:39 UTC 2026`、
   `SUFFIX=9-0-g931a7e2ba585`、`RESUBLEVEL=246`、`KSU_META=main/builtin/SukiSUUltra/`。

2. **FAST 路径加机型守卫**
   检测到厂商树（`$KERNEL_REPOS != common` 或存在 `msm-kernel`）→ 直接跳过 FAST，
   打印 warning 并置 `fallback=true`，交给官方 `oplus_build_kernel.sh` 混合构建。

3. **FAST 失败不再杀死整个 job**
   `continue-on-error: true` + 编译输出 `tee` 到日志 + 失败时打印最后 200 行；
   `Fallback to Build Kernel` 的条件加上 `steps.fast_build.outcome == 'failure'`。

4. **官方构建路径也留日志**
   `official_build.log` + `LOGDIR/build_*.log` 尾部输出，失败不再"黑箱"。

5. **SUBLEVEL 伪装改到两棵树**
   `common/Makefile` 与 `$KERNEL_REPOS/Makefile` 同时改，版本号计算以实际编译的树为准。

6. **版本串确定性写入**（核心修复）
   在原有格式匹配之后，**直接用固定的 `scripts/setlocalversion` 覆盖**内核树的版本脚本：

   ```sh
   #!/bin/sh
   if [ "$1" = "--save-scmversion" ]; then
     echo "-android12-9-0-g931a7e2ba585" > .scmversion
     exit 0
   fi
   echo "-android12-9-0-g931a7e2ba585"
   ```

   这样绕开 `CONFIG_LOCALVERSION="-gki"`、`scm_version`、`^res=` 格式差异等所有不确定因素。
   `external/dtc` 的脚本不动。

7. **Image 查找更稳 + 版本自检**
   按 `common/out` → `kernel_platform/out` → `$KERNEL_REPOS/out` → `dist` 逐级找，
   **GKI Image（路径含 `/common/`）优先**，避免混进厂商整合版；
   打包前打印 `strings Image | grep "Linux version"` 与真机版本对比，不一致会发 warning。

---

## 4. 验证

```bash
node verify_e2e_version.js
```

直接从修好的 YAML 里抽出 "Custom Kernel Suffix if set" 步骤的脚本，
在用**真机真实 `scripts/setlocalversion`** 搭出来的 `common/` + `msm-kernel/` 目录上跑，
再执行生成版本：

```
=== FAST_BUILD=true ===
  common       ✅ 5.10.246-android12-9-0-g931a7e2ba585
  msm-kernel   ✅ 5.10.246-android12-9-0-g931a7e2ba585
=== FAST_BUILD=false ===
  common       ✅ 5.10.246-android12-9-0-g931a7e2ba585
  msm-kernel   ✅ 5.10.246-android12-9-0-g931a7e2ba585
```

YAML 语法也已用 js-yaml 解析校验通过（53 个 step）。

---

## 5. 怎么跑

### 方式 A：GitHub Actions（推荐，产物就是 AnyKernel3 刷机包）

```bash
# 1) 把 output/Build Kernel OnePlus.yml 覆盖到仓库
#    .github/workflows/Build Kernel OnePlus.yml   （分支 SukiSU-Ultra）
git add .github/workflows/"Build Kernel OnePlus.yml"
git commit -m "fix: realme GT Neo5 SE gki build (vendor mixed-build path + exact version string)"
git push

# 2) 触发并自动下载产物
export GITHUB_TOKEN=ghp_xxx     # 需要 repo + workflow 权限
bash output/dispatch_and_fetch.sh ken8483/Action-Build SukiSU-Ultra
```

或直接在 Actions 页面手动 "Run workflow"，参数已设为默认值：

| 参数 | 值 |
|---|---|
| FILE | `realme_gt_neo5se_v` |
| BUILD_TIME | `Thu Aug 13 10:46:39 UTC 2026` |
| SUFFIX | `9-0-g931a7e2ba585` |
| RESUBLEVEL | `246` |
| KSU_META | `main/builtin/SukiSUUltra/` |
| FAST_BUILD | `true`（对厂商树会自动跳过并走官方混合构建） |
| SUSFS_CI | `N/A`（SukiSU Ultra 自带 susfs 模块，不用额外下） |
| ZRAM | `0/lz4kd/8589934592`（默认关闭） |

产物：`AnyKernel3_SukiSUUltra_<版本>_RealME_GT_Neo5SE_Android13.0.0.5.10.246_...zip`

### 方式 B：本地机器跑（Linux，>=16 核 / 32G 内存更舒服）

```bash
mkdir kernel_workspace && cd kernel_workspace
repo init -u https://github.com/Numbersf/Kernel_Manifest_Appendix.git \
          -b realme/sm7475 -m realme_gt_neo5se_v.xml --depth=1 --no-clone-bundle --no-tags
repo sync -c -j$(nproc) --no-clone-bundle --no-tags
LTO=thin SYSTEM_DLKM_RE_SIGN=0 BUILD_SYSTEM_DLKM=0 KMI_SYMBOL_LIST_STRICT_MODE=0 \
  ./kernel_platform/oplus/build/oplus_build_kernel.sh waipio gki
```
再按上面第 2、5、6 条的说明手动注入版本串与构建时间。

---

## 6. 刷机前必读（重要）

1. **先备份原厂 `boot.img`**（fastboot flash boot 之前一定要有）：
   ```bash
   fastboot flash boot boot_stock.img     # 备份
   ```
   有问题就 `fastboot flash boot boot_stock.img` 回滚。

2. **这个包是 GKI 内核**（boot 分区），不是 init_boot。
   - 刷：`fastboot flash boot <AnyKernel3 里的 Image 打包出的 boot.img>`
   - 或用 AnyKernel3 zip 在 Recovery 里刷
   - 或用 SukiSU Ultra 管理器的 "GKI 安装" 选这个 zip。

3. **开机后第一件事看 dmesg**：
   ```bash
   su -c dmesg | grep -iE "version magic|disagrees|taint|module" | head -50
   ```
   如果看到大量 `version magic ... should be ...`，说明 vendor_dlkm 模块没加载上
   （多半是 CRC/配置差异，不是版本串问题），此时**立即回刷原厂 boot**。

4. **SukiSU Ultra** 需要在管理器里选对 KMI：`Android 12-5.10`。

5. **已知风险**：公开源码的 `common` 是 5.10.209，而真机原厂内核是 5.10.246。
   版本串我们对齐了，但 GKI 内部的符号 CRC 是否与原厂完全一致无法离线验证，
   属于第 3 条要检查的点。
