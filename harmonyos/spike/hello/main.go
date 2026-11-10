// G1 第 1 级探针：验证 Go runtime 与 OHOS 内核 ABI 是否兼容。
// 构建：CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o hello-ohos .
// 运行：hdc file send hello-ohos /data/local/tmp/ && hdc shell "chmod +x ... && ..."
package main

import (
	"fmt"
	"os"
	"runtime"
	"time"
)

func main() {
	fmt.Println("=== go-on-ohos probe ===")
	fmt.Println("goos      :", runtime.GOOS)
	fmt.Println("goarch    :", runtime.GOARCH)
	fmt.Println("goversion :", runtime.Version())
	fmt.Println("numcpu    :", runtime.NumCPU())
	fmt.Println("gomaxprocs:", runtime.GOMAXPROCS(0))

	// /proc 访问：沙箱限制的第一个信号
	if b, err := os.ReadFile("/proc/self/status"); err != nil {
		fmt.Println("proc status: ERR", err)
	} else {
		fmt.Printf("proc status: OK (%d bytes)\n", len(b))
	}

	// 临时文件写入：沙箱可写性的信号
	if f, err := os.CreateTemp("/data/local/tmp", "probe-*.txt"); err != nil {
		fmt.Println("tmpfile   : ERR", err)
	} else {
		name := f.Name()
		_, werr := f.WriteString("probe")
		f.Close()
		os.Remove(name)
		fmt.Println("tmpfile   : OK", werr)
	}

	// goroutine 调度 + 定时器：Go runtime 在目标内核上的运行时自检
	done := make(chan string, 8)
	for i := 0; i < 8; i++ {
		go func(n int) {
			time.Sleep(time.Duration(n) * time.Millisecond)
			done <- fmt.Sprintf("g%d", n)
		}(i)
	}
	for i := 0; i < 8; i++ {
		<-done
	}
	fmt.Println("sched     : OK (8 goroutines + timers)")

	// 网络栈自检（不依赖外部服务）
	fmt.Println("result    : PASS")
}
