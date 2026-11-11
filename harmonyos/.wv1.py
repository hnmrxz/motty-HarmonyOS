import pathlib
p = pathlib.Path("harmonyos/ohos/app/entry/src/main/ets/pages/Index.ets")
lines = p.read_text(encoding="utf-8").splitlines()
diag = next(i for i,l in enumerate(lines) if "diagPanel() {" in l)
open_i = next(i for i in range(diag, diag+5) if lines[i].strip() == "Column({ space: 10 }) {")
close_i = next(i for i in range(open_i, len(lines)) if ".id('diag/panel')" in lines[i])
# 1) 包 Scroll
lines.insert(open_i, "    Scroll() {")
close_i += 1  # 插入后索引偏移
lines[close_i-1] = "      }.width('100%')"   # 原 Column 收尾改为 .width
lines.insert(close_i, "    }")               # Scroll 收尾
lines[close_i+1] = "    .id('diag/panel').width(680).height(900).scrollBar(BarState.Auto)"
# 2) 拆按钮行
start = next(i for i,l in enumerate(lines) if "Button('term-echo')" in l) - 1
end = next(i for i,l in enumerate(lines) if "id('rdp/probe-ssh')" in l)
while lines[end].strip() != "}.width('100%')":
    end += 1
new_block = pathlib.Path(r"E:\motty-HarmonyOS\.block.txt")
if not new_block.exists():
    raise SystemExit("先写 block 文件")
lines[start:end+1] = new_block.read_text(encoding="utf-8").splitlines()
# 3) 预览条移动
lines = [l for l in lines if l.strip() != "this.rdpPreviewStrip()"]
i = next(k for k,l in enumerate(lines) if "id('rdp/srv-status')" in l)
while lines[i].strip() != "}.width('100%')":
    i += 1
lines.insert(i+1, "      this.rdpPreviewStrip()")
p.write_text("\n".join(lines) + "\n", encoding="utf-8")
print("结构改动完成")
