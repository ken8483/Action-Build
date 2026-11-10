#!/usr/bin/env bash
# 一键触发 + 等待 + 下载 真我 GT Neo5 SE 的 GKI 内核产物
#
# 用法：
#   export GITHUB_TOKEN=ghp_xxx        # 需要 repo + workflow 权限
#   bash dispatch_and_fetch.sh [owner/repo] [ref]
#
# 默认：ken8483/Action-Build  分支 SukiSU-Ultra
set -uo pipefail

REPO="${1:-ken8483/Action-Build}"
REF="${2:-SukiSU-Ultra}"
WORKFLOW="Build Kernel OnePlus.yml"
OUT_DIR="${OUT_DIR:-./out}"
API="https://api.github.com"

[ -n "${GITHUB_TOKEN:-}" ] || { echo "❌ 请先 export GITHUB_TOKEN=..."; exit 1; }
command -v jq >/dev/null || { echo "❌ 需要 jq"; exit 1; }

mkdir -p "$OUT_DIR"

cat > "$OUT_DIR/inputs.json" <<'JSON'
{
  "FILE": "realme_gt_neo5se_v",
  "SUSFS_CI": "N/A",
  "KPM": "N/A",
  "SUSFS_META": "",
  "DYNAMIC_REPO": "Numbersf",
  "BUILD_TIME": "Thu Aug 13 10:46:39 UTC 2026",
  "KSU_META": "main/builtin/SukiSUUltra/",
  "LZ4_UPDATE": false,
  "ZRAM": "0/lz4kd/8589934592",
  "SUFFIX": "9-0-g931a7e2ba585",
  "RESUBLEVEL": "246",
  "FAST_BUILD": true,
  "LSM_BBG": true,
  "NETFILTER": true,
  "CCM": true,
  "UNICODE_BYPASS": false,
  "SCHED_HMBIRD": false,
  "DROID_SPACES": false,
  "RE_KERNEL": false,
  "SUSFS_DEV": false,
  "SPACE_NOCLEAN": false,
  "BUILD_NOCACHE": false
}
JSON

echo "▶ 触发工作流: $REPO @ $REF"
RESP=$(curl -sS -X POST \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "$API/repos/$REPO/actions/workflows/$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$WORKFLOW")/dispatches" \
  -d "{\"ref\":\"$REF\",\"inputs\":$(cat "$OUT_DIR/inputs.json")}")
if [ -n "$RESP" ]; then
  echo "  响应: $RESP"
  echo "$RESP" | jq -e '.message' >/dev/null 2>&1 && { echo "❌ 触发失败"; exit 1; }
fi

echo "▶ 等待 run 启动..."
RUN_ID=""
for i in $(seq 1 30); do
  sleep 5
  RUN_ID=$(curl -sS -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" \
    "$API/repos/$REPO/actions/runs?event=workflow_dispatch&branch=$REF&per_page=5" \
    | jq -r '.workflow_runs[] | select(.name|test("realme_gt_neo5se_v")) | .id' | head -n1)
  [ -n "$RUN_ID" ] && [ "$RUN_ID" != "null" ] && break
done
[ -z "$RUN_ID" ] && { echo "❌ 没等到 run 启动，去 Actions 页面手动看"; exit 1; }
echo "  run_id = $RUN_ID"
echo "  页面: $API/repos/$REPO/actions/runs/$RUN_ID  → https://github.com/$REPO/actions/runs/$RUN_ID"

echo "▶ 等待构建完成（内核编译约 20~50 分钟）..."
STATUS=""
for i in $(seq 1 240); do
  sleep 30
  INFO=$(curl -sS -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" \
    "$API/repos/$REPO/actions/runs/$RUN_ID")
  STATUS=$(echo "$INFO" | jq -r '.status')
  CONC=$(echo "$INFO" | jq -r '.conclusion')
  STEP=$(echo "$INFO" | jq -r '[.jobs[].steps[]? | select(.status=="in_progress") | .name] | join(",")' 2>/dev/null)
  echo "  [$i] status=$STATUS conclusion=$CONC  当前步骤: ${STEP:-—}"
  [ "$STATUS" = "completed" ] && break
done

if [ "$CONC" != "success" ]; then
  echo "❌ 构建未成功 (conclusion=$CONC)，请看日志："
  echo "   https://github.com/$REPO/actions/runs/$RUN_ID"
  exit 2
fi

echo "▶ 下载产物"
ART=$(curl -sS -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" \
  "$API/repos/$REPO/actions/runs/$RUN_ID/artifacts" | jq -r '.artifacts[0].id')
NAME=$(curl -sS -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" \
  "$API/repos/$REPO/actions/runs/$RUN_ID/artifacts" | jq -r '.artifacts[0].name')
echo "  artifact: $NAME (id=$ART)"
curl -sSL -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" \
  "$API/repos/$REPO/actions/artifacts/$ART/zip" -o "$OUT_DIR/$NAME.zip"
cd "$OUT_DIR" && unzip -o -q "$NAME.zip" -d "${NAME}_extracted"
echo "✅ 产物在: $OUT_DIR/${NAME}_extracted/"
ls -la "$OUT_DIR/${NAME}_extracted" || true
