//go:build windows

// pty_windows.go —— 用 Windows ConPTY 提供真正的 pty。
//
// 为什么需要它：此前的对端拒绝 pty，交互语义只能用"行回显"近似。ConPTY 让对端
// 有一个真 shell（cmd.exe）跑在伪终端后面，客户端因此可以真正走 pty-req + shell，
// 并且 window-change 能真的改变远端尺寸。
//
// 注意：这是**对端夹具**的实现，不进入产品代码。产品侧只需要 libssh2 的 pty-req。
package main

import (
	"fmt"
	"io"
	"sync"
	"unsafe"

	"golang.org/x/sys/windows"
)

type ptySession struct {
	hpc windows.Handle
	inW windows.Handle  // 客户端写入 -> shell 读
	outR windows.Handle // shell 写 -> 客户端读
	// 交给 ConPTY 的两个句柄必须保持打开，直到 Close。
	// 提前关闭会让控制台失去客户端：实测表现为子进程把输出写回父控制台，
	// 而我们从管道里只读到 16 字节的初始化序列。
	ptyIn  windows.Handle
	ptyOut windows.Handle
	pi  windows.ProcessInformation
	mu  sync.Mutex
}

func startPty(cols, rows int) (*ptySession, error) {
	if cols <= 0 {
		cols = 80
	}
	if rows <= 0 {
		rows = 24
	}
	sa := &windows.SecurityAttributes{
		Length:        uint32(unsafe.Sizeof(windows.SecurityAttributes{})),
		InheritHandle: 1,
	}
	var inR, inW, outR, outW windows.Handle
	if err := windows.CreatePipe(&inR, &inW, sa, 0); err != nil {
		return nil, fmt.Errorf("CreatePipe(in): %w", err)
	}
	if err := windows.CreatePipe(&outR, &outW, sa, 0); err != nil {
		return nil, fmt.Errorf("CreatePipe(out): %w", err)
	}

	var hpc windows.Handle
	size := windows.Coord{X: int16(cols), Y: int16(rows)}
	if err := windows.CreatePseudoConsole(size, inR, outW, 0, &hpc); err != nil {
		return nil, fmt.Errorf("CreatePseudoConsole: %w", err)
	}

	attrs, err := windows.NewProcThreadAttributeList(1)
	if err != nil {
		return nil, fmt.Errorf("NewProcThreadAttributeList: %w", err)
	}
	// lpValue 传 HPC 句柄本身（按值转指针）。传 &hpc 会让 ConPTY 收不到有效句柄，
	// 子进程会退回到继承父进程的控制台——实测表现为"只收到 16 字节初始化序列"。
	if err := attrs.Update(windows.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
		unsafe.Pointer(hpc), unsafe.Sizeof(hpc)); err != nil {
		return nil, fmt.Errorf("Update(pseudoconsole): %w", err)
	}

	si := &windows.StartupInfoEx{
		StartupInfo: windows.StartupInfo{Cb: uint32(unsafe.Sizeof(windows.StartupInfoEx{}))},
	}
	// 与已知可用实现对齐：置 STARTF_USESTDHANDLES，真正的控制台由 ConPTY 属性注入。
	si.StartupInfo.Flags |= windows.STARTF_USESTDHANDLES
	si.ProcThreadAttributeList = attrs.List()

	shell, err := windows.UTF16PtrFromString(`C:\Windows\System32\cmd.exe`)
	if err != nil {
		return nil, err
	}
	var pi windows.ProcessInformation
	flags := uint32(windows.EXTENDED_STARTUPINFO_PRESENT | windows.CREATE_UNICODE_ENVIRONMENT)
	// 直接调 CreateProcessW：不经过任何包装，确保 STARTUPINFOEXW（含属性表）原样传入。
	// 之前用 windows.CreateProcess 时子进程仍挂在父控制台上（只收到 ConPTY 的初始化序列），
	// 说明属性表没有生效——直呼可以排除包装层这一变量。
	procCreateProcessW := windows.NewLazySystemDLL("kernel32.dll").NewProc("CreateProcessW")
	r1, _, e1 := procCreateProcessW.Call(
		0,
		uintptr(unsafe.Pointer(shell)),
		0, 0,
		0, // inheritHandles = false
		uintptr(flags),
		0,
		0,
		uintptr(unsafe.Pointer(si)),
		uintptr(unsafe.Pointer(&pi)))
	if r1 == 0 {
		windows.ClosePseudoConsole(hpc)
		return nil, fmt.Errorf("CreateProcessW: %w", e1)
	}
	return &ptySession{hpc: hpc, inW: inW, outR: outR, ptyIn: inR, ptyOut: outW, pi: pi}, nil
}

func (p *ptySession) Read(b []byte) (int, error) {
	var n uint32
	if err := windows.ReadFile(p.outR, b, &n, nil); err != nil {
		return 0, err
	}
	return int(n), nil
}

func (p *ptySession) Write(b []byte) (int, error) {
	var n uint32
	if err := windows.WriteFile(p.inW, b, &n, nil); err != nil {
		return 0, err
	}
	return int(n), nil
}

func (p *ptySession) Resize(cols, rows int) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if cols <= 0 || rows <= 0 {
		return nil
	}
	return windows.ResizePseudoConsole(p.hpc, windows.Coord{X: int16(cols), Y: int16(rows)})
}

func (p *ptySession) Close() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	windows.TerminateProcess(p.pi.Process, 0)
	windows.CloseHandle(p.pi.Process)
	windows.CloseHandle(p.pi.Thread)
	windows.ClosePseudoConsole(p.hpc)
	windows.CloseHandle(p.inW)
	windows.CloseHandle(p.outR)
	windows.CloseHandle(p.ptyIn)
	windows.CloseHandle(p.ptyOut)
	return nil
}

var _ io.ReadWriteCloser = (*ptySession)(nil)
