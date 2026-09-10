#!/bin/bash
# ==============================================================================
# Script: patch_webui.sh
# Purpose: Transform Padavan Web UI Top-Right "关机" (Shutdown) button into "释放内存" (Free Memory)
# Reason:
# 1. MT7621 / K2P has no soft-poweroff circuit. Clicking shutdown only hangs CPU
#    with power LED still on, requiring pulling the AC plug to reboot.
# 2. Replacing it with "释放内存" (drop_caches) immediately frees kernel buffers,
#    directory caches, and RAM, making the router much smoother!
# ==============================================================================

set -e
PADAVAN_ROOT="${1:-/opt/padavan}"

echo "=========================================================="
echo ">> Patching Padavan Web UI: Transforming Shutdown into Free Memory..."
echo ">> Root Directory: ${PADAVAN_ROOT}"
echo "=========================================================="

WWW_DIR="${PADAVAN_ROOT}/trunk/user/www"
DICT_CN="${WWW_DIR}/dict/CN.dict"
HEADER_ASP="${WWW_DIR}/n56u_ribbon_fixed/header.asp"
TOP_ASP="${WWW_DIR}/n56u_ribbon_fixed/top.asp"
STATE_JS="${WWW_DIR}/n56u_ribbon_fixed/state.js"

# 1. Update Chinese dictionary entries
if [ -f "$DICT_CN" ]; then
    echo ">> Updating CN.dict labels..."
    sed -i 's/CTL_shutdown="关机"/CTL_shutdown="释放内存"/g' "$DICT_CN"
    sed -i 's/CTL_poweroff="关机"/CTL_poweroff="释放内存"/g' "$DICT_CN"
    sed -i 's/JS_shutdown="确定关机？"/JS_shutdown="确定立即释放系统运行内存与内核缓存？"/g' "$DICT_CN"
fi

# 2. Create the executable backend CGI for Free Memory
cat << 'EOF' > "${WWW_DIR}/free_mem.cgi"
#!/bin/sh
echo "Content-Type: text/plain; charset=utf-8"
echo "Cache-Control: no-cache"
echo ""
sync
echo 3 > /proc/sys/vm/drop_caches
FREE_KB=$(awk '/MemFree/ {print $2}' /proc/meminfo 2>/dev/null || echo "0")
logger -t "WebUI" "Manual memory free triggered from Web UI top-right button. Free RAM: ${FREE_KB} kB"
echo "OK:${FREE_KB}"
EOF
chmod +x "${WWW_DIR}/free_mem.cgi"

# Also symlink to sub-theme if needed
[ -d "${WWW_DIR}/n56u_ribbon_fixed" ] && ln -sf ../free_mem.cgi "${WWW_DIR}/n56u_ribbon_fixed/free_mem.cgi" 2>/dev/null || true

# 3. Patch state.js / shutdown() function in Web UI
for f in "$STATE_JS" "${WWW_DIR}/state.js"; do
    if [ -f "$f" ]; then
        echo ">> Patching $f shutdown() handler..."
        cat << 'EOF' > /tmp/free_mem_func.js
function shutdown(){
    if(!confirm("确定要释放系统运行内存与缓存吗？\n(将执行 sync && echo 3 > /proc/sys/vm/drop_caches)")) return false;
    var xhr = new XMLHttpRequest();
    xhr.open("GET", "/free_mem.cgi?t=" + new Date().getTime(), true);
    xhr.onreadystatechange = function(){
        if(xhr.readyState === 4){
            alert("✨ 内存与缓存已成功释放！\n系统运行更轻快。");
            top.location.reload();
        }
    };
    xhr.send();
    return false;
}
EOF
        if grep -q "function shutdown" "$f"; then
            sed -i '/function shutdown()/,/}/d' "$f"
            cat /tmp/free_mem_func.js >> "$f"
        else
            cat /tmp/free_mem_func.js >> "$f"
        fi
        rm -f /tmp/free_mem_func.js
    fi
done

# 4. Patch header.asp and top.asp tooltip and title
for h in "$HEADER_ASP" "$TOP_ASP" "${WWW_DIR}/header.asp"; do
    if [ -f "$h" ]; then
        echo ">> Updating $h title attribute..."
        sed -i 's/title="关机"/title="释放内存"/g' "$h"
        sed -i 's/title="<#CTL_shutdown#>"/title="释放内存"/g' "$h"
    fi
done

echo ">> Web UI top-right button successfully transformed into Free Memory (释放内存)!"
