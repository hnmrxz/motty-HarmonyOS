//go:build windows

// rfb_fixture.go —— 最小 RFB 3.8 服务端（夹具用）
//
// 为什么自己写：上游 Motty 的 VNC 是自研 `internal/rfb`，不是 LibVNC。
// LibVNC 是 GPL-2.0，链进应用会传染整个产品，直接堵死上架路径。
// 所以对端也用自研的最小实现，只覆盖本轮要验证的部分：
//   - 协议版本 3.8（也接受 3.3 的降级路径未实现，明确拒绝）
//   - 安全类型：None(1) 一种
//   - 编码：Raw(0) 一种
//   - 固定测试图案：左半红、右半蓝，左上角红、中心蓝
//
// 明确不做：VNC Auth(DES)、Hextile/ZRLE/CopyRect、多客户端、剪贴板、resize。
package main

import (
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"net"
	"time"
)

const (
	rfbWidth  = 64
	rfbHeight = 48
)

type pointerMark struct {
	valid bool
	x, y  int
}

// serveRFB 处理一个 VNC 客户端连接
func serveRFB(conn net.Conn) {
	defer conn.Close()
	log.Printf("rfb: client %s connected", conn.RemoteAddr())

	if _, err := conn.Write([]byte("RFB 003.008\n")); err != nil {
		return
	}
	ver := make([]byte, 12)
	if _, err := io.ReadFull(conn, ver); err != nil {
		return
	}
	log.Printf("rfb: client version %q", string(ver))

	// 安全类型列表：只有 None(1)
	if _, err := conn.Write([]byte{1, 1}); err != nil {
		return
	}
	sel := make([]byte, 1)
	if _, err := io.ReadFull(conn, sel); err != nil {
		return
	}
	if sel[0] != 1 {
		log.Printf("rfb: client picked unsupported security type %d", sel[0])
		return
	}
	// 3.8 的 SecurityResult
	if err := binary.Write(conn, binary.BigEndian, uint32(0)); err != nil {
		return
	}

	// ClientInit：shared 标志
	shared := make([]byte, 1)
	if _, err := io.ReadFull(conn, shared); err != nil {
		return
	}

	// ServerInit
	buf := make([]byte, 0, 32)
	buf = binary.BigEndian.AppendUint16(buf, rfbWidth)
	buf = binary.BigEndian.AppendUint16(buf, rfbHeight)
	// PIXEL_FORMAT: bpp=32 depth=24 bigendian=0 truecolor=1
	buf = append(buf, 32, 24, 0, 1)
	buf = binary.BigEndian.AppendUint16(buf, 255) // red max
	buf = binary.BigEndian.AppendUint16(buf, 255) // green max
	buf = binary.BigEndian.AppendUint16(buf, 255) // blue max
	buf = append(buf, 16, 8, 0)                   // red/green/blue shift
	buf = append(buf, 0, 0, 0)                    // padding
	name := "motty-fixture"
	buf = binary.BigEndian.AppendUint32(buf, uint32(len(name)))
	buf = append(buf, []byte(name)...)
	if _, err := conn.Write(buf); err != nil {
		return
	}

	var mark pointerMark

	// 消息循环
	for {
		_ = conn.SetReadDeadline(time.Now().Add(60 * time.Second))
		head := make([]byte, 1)
		if _, err := io.ReadFull(conn, head); err != nil {
			log.Printf("rfb: read ended: %v", err)
			return
		}
		switch head[0] {
		case 0: // SetPixelFormat: 3 pad + 16 pixelformat
			if _, err := io.ReadFull(conn, make([]byte, 19)); err != nil {
				return
			}
			log.Printf("rfb: SetPixelFormat")
		case 2: // SetEncodings
			hdr := make([]byte, 3)
			if _, err := io.ReadFull(conn, hdr); err != nil {
				return
			}
			count := int(binary.BigEndian.Uint16(hdr[1:]))
			body := make([]byte, count*4)
			if _, err := io.ReadFull(conn, body); err != nil {
				return
			}
			log.Printf("rfb: SetEncodings count=%d", count)
		case 3: // FramebufferUpdateRequest
			req := make([]byte, 9)
			if _, err := io.ReadFull(conn, req); err != nil {
				return
			}
			x := binary.BigEndian.Uint16(req[1:])
			y := binary.BigEndian.Uint16(req[3:])
			w := binary.BigEndian.Uint16(req[5:])
			h := binary.BigEndian.Uint16(req[7:])
			log.Printf("rfb: FBUpdateRequest inc=%d %d,%d %dx%d", req[0], x, y, w, h)
			if err := sendRawUpdate(conn, mark); err != nil {
				log.Printf("rfb: send update failed: %v", err)
				return
			}
		case 4: // KeyEvent
			ke := make([]byte, 7)
			if _, err := io.ReadFull(conn, ke); err != nil {
				return
			}
			ks := binary.BigEndian.Uint32(ke[3:])
			log.Printf("rfb: KeyEvent down=%d keysym=%d", ke[0], ks)
		case 5: // PointerEvent：type(1)+pad(1)+x(2)+y(2)+mask(1) = 共 7 字节
			// 曾经只读 5 字节（少读 mask），导致下一个字节被当成消息类型，报 unsupported message type
			pe := make([]byte, 6)
			if _, err := io.ReadFull(conn, pe); err != nil {
				return
			}
			px := int(binary.BigEndian.Uint16(pe[1:]))
			py := int(binary.BigEndian.Uint16(pe[3:]))
			mask := int(pe[5] & 1)
			log.Printf("rfb: PointerEvent x=%d y=%d mask=%d", px, py, mask)
			if mask == 1 {
				mark = pointerMark{valid: true, x: px, y: py}
			}
		default:
			log.Printf("rfb: unsupported message type %d", head[0])
			return
		}
	}
}

// sendRawUpdate 发一帧 Raw 编码的固定图案：左半红、右半蓝。
// 若收到过按下事件，再在该位置画 8x8 绿色方块——这样"输入到达对端"就是可断言的。
func sendRawUpdate(conn net.Conn, mark pointerMark) error {
	head := make([]byte, 0, 16)
	head = append(head, 0, 0)                          // message type 0, padding
	head = binary.BigEndian.AppendUint16(head, 1)      // 1 rect
	head = binary.BigEndian.AppendUint16(head, 0)      // x
	head = binary.BigEndian.AppendUint16(head, 0)      // y
	head = binary.BigEndian.AppendUint16(head, rfbWidth)
	head = binary.BigEndian.AppendUint16(head, rfbHeight)
	head = binary.BigEndian.AppendUint32(head, 0) // encoding = Raw
	if _, err := conn.Write(head); err != nil {
		return err
	}

	// 32bpp little-endian，rshift=16 gshift=8 bshift=0 => 字节序 B,G,R,X
	pixels := make([]byte, rfbWidth*rfbHeight*4)
	for y := 0; y < rfbHeight; y++ {
		for x := 0; x < rfbWidth; x++ {
			i := (y*rfbWidth + x) * 4
			if x < rfbWidth/2 {
				pixels[i+0] = 0x00 // B
				pixels[i+1] = 0x00 // G
				pixels[i+2] = 0xFF // R  -> FF0000
				pixels[i+3] = 0x00
			} else {
				pixels[i+0] = 0xFF // B -> 0000FF
				pixels[i+1] = 0x00
				pixels[i+2] = 0x00
				pixels[i+3] = 0x00
			}
			if mark.valid &&
				x >= mark.x-4 && x <= mark.x+4 && y >= mark.y-4 && y <= mark.y+4 {
				pixels[i+0] = 0x00 // B
				pixels[i+1] = 0xFF // G -> 00FF00
				pixels[i+2] = 0x00
				pixels[i+3] = 0x00
			}
		}
	}
	_, err := conn.Write(pixels)
	return err
}

// startRFBFixture 在指定地址起 RFB 监听（每连接一个 goroutine）
func startRFBFixture(addr string) (net.Listener, error) {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, err
	}
	go func() {
		for {
			conn, aerr := ln.Accept()
			if aerr != nil {
				return
			}
			log.Printf("rfb: accepted from %s", conn.RemoteAddr())
			go serveRFB(conn)
		}
	}()
	log.Printf("rfb fixture listening on %s (pattern: left red, right blue, %dx%d)",
		addr, rfbWidth, rfbHeight)
	return ln, nil
}

var _ = fmt.Sprintf
