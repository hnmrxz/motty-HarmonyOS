//go:build windows

// pty_manual_test.go —— 把 ConPTY 从 SSH 链路里隔离出来单独验证。
//
// 存在理由：端到端 spec 失败时，"ConPTY 没输出"和"SSH 通道没转发"看起来一样。
// 这个测试直接 startPty + 写入 + 读取，能在几秒内区分两者。
//
// 注意：pty 的 Read 是阻塞的，所以所有读取都放到 goroutine 里 + select 超时，
// 否则测试会永久挂住（第一次写这个测试时就挂住了 5 分钟）。
package main

import (
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/windows"
)

type readResult struct {
	data []byte
	err  error
}

// readWithTimeout 在一个 goroutine 里做阻塞读，超时就返回 nil（那一笔数据留在管道里，不影响后续）
func readWithTimeout(p *ptySession, d time.Duration) ([]byte, error, bool) {
	ch := make(chan readResult, 1)
	go func() {
		buf := make([]byte, 4096)
		n, err := p.Read(buf)
		if n > 0 {
			ch <- readResult{data: buf[:n]}
			return
		}
		ch <- readResult{err: err}
	}()
	select {
	case r := <-ch:
		return r.data, r.err, true
	case <-time.After(d):
		return nil, nil, false
	}
}

func TestPtyManual(t *testing.T) {
	p, err := startPty(80, 24)
	if err != nil {
		t.Fatalf("startPty: %v", err)
	}
	defer p.Close()

	// cmd.exe 是否还活着？
	if code, gerr := getExitCode(p.pi.Process); gerr == nil {
		t.Logf("cmd.exe 退出码: %d（259 = still active）", code)
	}

	var all strings.Builder
	// 先等初始输出（ConPTY 一般立刻吐 banner/prompt）
	for i := 0; i < 4; i++ {
		data, rerr, ok := readWithTimeout(p, 2*time.Second)
		if !ok {
			t.Logf("第 %d 次读超时（无输出）", i+1)
			continue
		}
		if len(data) > 0 {
			all.Write(data)
		}
		if rerr != nil {
			t.Logf("读错误: %v", rerr)
			break
		}
	}
	t.Logf("初始输出 %d 字节: %q", all.Len(), all.String())

	if all.Len() == 0 {
		// 再看一眼进程状态：如果已退出，说明 ConPTY 没把控制台接上
		if code, gerr := getExitCode(p.pi.Process); gerr == nil {
			t.Logf("无输出时 cmd.exe 退出码: %d", code)
		}
		t.Fatalf("ConPTY 没有任何输出 —— pty 不可用（不要把它当作 pty 已支持）")
	}

	if _, werr := p.Write([]byte("echo pty-manual-ok\r\n")); werr != nil {
		t.Fatalf("write: %v", werr)
	}
	got := all.String()
	for i := 0; i < 5 && !strings.Contains(got, "pty-manual-ok"); i++ {
		data, _, ok := readWithTimeout(p, 2*time.Second)
		if !ok {
			continue
		}
		all.Write(data)
		got = all.String()
	}
	if !strings.Contains(got, "pty-manual-ok") {
		t.Fatalf("没有看到命令回显；末尾: %q", tail(got, 400))
	}

	if rerr := p.Resize(100, 30); rerr != nil {
		t.Logf("resize 失败: %v", rerr)
	}
	if _, werr := p.Write([]byte("echo after-resize\r\n")); werr != nil {
		t.Fatalf("write after resize: %v", werr)
	}
	for i := 0; i < 5 && !strings.Contains(all.String(), "after-resize"); i++ {
		data, _, ok := readWithTimeout(p, 2*time.Second)
		if !ok {
			continue
		}
		all.Write(data)
	}
	if !strings.Contains(all.String(), "after-resize") {
		t.Fatalf("resize 之后 shell 无响应；末尾: %q", tail(all.String(), 400))
	}
}

func getExitCode(h windows.Handle) (uint32, error) {
	var code uint32
	err := windows.GetExitCodeProcess(h, &code)
	return code, err
}

func tail(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[len(s)-n:]
}
