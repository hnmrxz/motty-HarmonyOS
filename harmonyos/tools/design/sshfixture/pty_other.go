//go:build !windows

// pty_other.go —— 非 Windows 平台没有 ConPTY 绑定；这里明确返回不可用，
// 而不是提供一个"看起来能跑"的假 pty。pty 相关 spec 会因此响亮失败。
package main

import (
	"errors"
	"io"
)

type ptySession struct{}

func startPty(cols, rows int) (*ptySession, error) {
	return nil, errors.New("pty is only implemented for the Windows fixture (ConPTY)")
}

func (p *ptySession) Read(b []byte) (int, error)  { return 0, io.EOF }
func (p *ptySession) Write(b []byte) (int, error) { return 0, io.ErrClosedPipe }
func (p *ptySession) Resize(cols, rows int) error { return errors.New("not supported") }
func (p *ptySession) Close() error                { return nil }

var _ io.ReadWriteCloser = (*ptySession)(nil)
