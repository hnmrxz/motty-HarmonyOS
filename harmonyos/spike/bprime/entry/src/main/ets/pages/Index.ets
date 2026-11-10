import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import bprobe from 'libbprobe.so';

const DOMAIN: number = 0x0000;
const TAG: string = 'BPROBE';

@Entry
@Component
struct Index {
  @State log: string = 'probing...';

  aboutToAppear(): void {
    this.probe();
  }

  probe(): void {
    const lines: string[] = [];
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      lines.push('filesDir : ' + ctx.filesDir);
      lines.push('codeDir  : ' + ctx.bundleCodeDir);

      // 候选 1：伪装成 .so 放在 native 库目录（该目录 SELinux 标签通常允许 execute）
      const libPath: string = ctx.bundleCodeDir + '/libs/x86_64/libgoprobe.so';
      lines.push('--- [1] lib dir exec: ' + libPath);
      lines.push(bprobe.run(libPath));

      // 候选 2：复制到私有 files 目录（上一轮已知 EACCES，作为对照保留）
      const data: Uint8Array = ctx.resourceManager.getRawFileContentSync('go-probe');
      const target: string = ctx.filesDir + '/go-probe';
      const file = fs.openSync(target, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, data.buffer as ArrayBuffer);
      fs.closeSync(file);
      lines.push('--- [2] data dir exec: ' + target);
      lines.push(bprobe.run(target));
    } catch (e) {
      lines.push('ERR: ' + JSON.stringify(e));
    }
    this.log = lines.join('\n');
    hilog.info(DOMAIN, TAG, '%{public}s', this.log);
  }

  build() {
    Column({ space: 8 }) {
      Text('B′ probe: lib-dir exec vs data-dir exec')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
      Scroll() {
        Text(this.log)
          .fontSize(11)
          .fontFamily('monospace')
          .width('100%')
      }
      .layoutWeight(1)
      .width('100%')
      .border({ width: 1, color: '#888888' })
      .padding(8)

      Button('Re-run').onClick(() => this.probe())
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .alignItems(HorizontalAlign.Start)
  }
}
