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
	"crypto/des"
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"net"
	"time"
)

// 尺寸可变：DesktopSize 伪编码会在连接中途改变桌面大小
var (
	rfbWidth  = 64
	rfbHeight = 48
)

var rfbPassword string

// vncResizeOnRequest：只有显式开启时，第 3 次请求后才发 DesktopSize。
// 默认关闭——否则会打断 vnc.session 这类期望固定 64x48 的用例。
var vncResizeOnRequest bool

// setVncResizeOnRequest 由 main 在解析参数后调用（保持 rfb_fixture.go 与 main.go 解耦）
func setVncResizeOnRequest(on bool) { vncResizeOnRequest = on }

// reverseBits 与客户端保持一致：VNC Auth 的 key 是口令每字节位反序
func reverseBits(b byte) byte {
	var r byte
	for i := 0; i < 8; i++ {
		r = (r << 1) | ((b >> uint(i)) & 1)
	}
	return r
}

// vncAuthExpect 计算期望响应：DES-ECB(key=位反序口令, challenge 两段)
func vncAuthExpect(challenge []byte, password string) []byte {
	key := make([]byte, 8)
	copy(key, []byte(password))
	for i := 0; i < 8; i++ {
		key[i] = reverseBits(key[i])
	}
	block, err := des.NewCipher(key)
	if err != nil {
		return nil
	}
	out := make([]byte, 16)
	block.Encrypt(out[0:8], challenge[0:8])
	block.Encrypt(out[8:16], challenge[8:16])
	return out
}

type pointerMark struct {
	valid bool
	x, y  int
}

// keyMark：收到 KeyEvent 后画洋红块，作为"键盘事件真的到了对端"的观测面
var keyMark bool

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

	// 安全类型：配置了口令就只提供 VNC Auth(2)，否则提供 None(1)
	offerAuth := rfbPassword != ""
	if offerAuth {
		if _, err := conn.Write([]byte{1, 2}); err != nil {
			return
		}
	} else {
		if _, err := conn.Write([]byte{1, 1}); err != nil {
			return
		}
	}
	log.Printf("rfb: offered auth=%v", offerAuth)
	sel := make([]byte, 1)
	if _, err := io.ReadFull(conn, sel); err != nil {
		log.Printf("rfb: reading security choice failed: %v", err)
		return
	}
	log.Printf("rfb: client chose security type %d", sel[0])
	if offerAuth {
		if sel[0] != 2 {
			log.Printf("rfb: client picked unsupported security type %d", sel[0])
			return
		}
		// 16 字节挑战
		challenge := make([]byte, 16)
		for i := range challenge {
			challenge[i] = byte(i*7 + 3)
		}
		if _, err := conn.Write(challenge); err != nil {
			return
		}
		resp := make([]byte, 16)
		if _, err := io.ReadFull(conn, resp); err != nil {
			return
		}
		if string(resp) != string(vncAuthExpect(challenge, rfbPassword)) {
			log.Printf("rfb: vnc auth FAILED (wrong password)")
			_ = binary.Write(conn, binary.BigEndian, uint32(1))
			// 3.8: 失败后还会发一段原因字符串
			_ = binary.Write(conn, binary.BigEndian, uint32(0))
			return
		}
		log.Printf("rfb: vnc auth ok")
	} else if sel[0] != 1 {
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
	buf = binary.BigEndian.AppendUint16(buf, uint16(rfbWidth))
	buf = binary.BigEndian.AppendUint16(buf, uint16(rfbHeight))
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
	useHextile := false
	reqCount := 0

	// 握手完成后先发一条固定的服务端剪贴板内容：让"客户端能收 ServerCutText"可断言
	if err := sendServerCutText(conn, "fixture-clip"); err != nil {
		log.Printf("rfb: initial cut text failed: %v", err)
		return
	}

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
			useHextile = false
			for i := 0; i < count; i++ {
				if int32(binary.BigEndian.Uint32(body[i*4:])) == 5 {
					useHextile = true
				}
			}
			log.Printf("rfb: SetEncodings count=%d hextile=%v", count, useHextile)
		case 3: // FramebufferUpdateRequest
			reqCount++
			if vncResizeOnRequest && reqCount == 3 {
				// DesktopSize 伪编码：通知客户端桌面尺寸变为 80x60（没有像素数据）
				hdr := []byte{0, 0, 0, 1} // type 0 + padding + 1 rect
				rect := []byte{0, 0, 0, 0, 0, 80, 0, 60, 0xFF, 0xFF, 0xFF, 0x21}
				if _, err := conn.Write(append(hdr, rect...)); err != nil {
					log.Printf("rfb: send DesktopSize failed: %v", err)
					return
				}
				rfbWidth, rfbHeight = 80, 60
				log.Printf("rfb: DesktopSize -> %dx%d", rfbWidth, rfbHeight)
			}
			req := make([]byte, 9)
			if _, err := io.ReadFull(conn, req); err != nil {
				return
			}
			x := binary.BigEndian.Uint16(req[1:])
			y := binary.BigEndian.Uint16(req[3:])
			w := binary.BigEndian.Uint16(req[5:])
			h := binary.BigEndian.Uint16(req[7:])
			log.Printf("rfb: FBUpdateRequest inc=%d %d,%d %dx%d", req[0], x, y, w, h)
			var uerr error
			if useHextile {
				uerr = sendHextileUpdate(conn, mark)
			} else {
				uerr = sendRawUpdate(conn, mark)
			}
			if err := uerr; err != nil {
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
			if ke[0] == 1 {
				keyMark = true
			}
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
		case 6: // ClientCutText锛歱ad(3)+len(4)+text
			padding := make([]byte, 3)
			if _, err := io.ReadFull(conn, padding); err != nil {
				return
			}
			lenBuf := make([]byte, 4)
			if _, err := io.ReadFull(conn, lenBuf); err != nil {
				return
			}
			n := binary.BigEndian.Uint32(lenBuf)
			if n > 1<<20 {
				log.Printf("rfb: cut text too long: %d", n)
				return
			}
			text := make([]byte, n)
			if n > 0 {
				if _, err := io.ReadFull(conn, text); err != nil {
					return
				}
			}
			log.Printf("rfb: ClientCutText %q", string(text))
			// 回一条 ServerCutText，内容是 "got:<收到的文本>"，便于客户端断言
			if err := sendServerCutText(conn, "got:"+string(text)); err != nil {
				log.Printf("rfb: send cut text failed: %v", err)
				return
			}
		default:
			log.Printf("rfb: unsupported message type %d", head[0])
			return
		}
	}
}
// sendServerCutText 发送 ServerCutText（message type 3），
// 用于让「客户端能接收对端剪贴板」这件事可断言。
func sendServerCutText(conn net.Conn, text string) error {
	buf := make([]byte, 0, 8+len(text))
	buf = append(buf, 3, 0, 0, 0)
	var lenBuf [4]byte
	binary.BigEndian.PutUint32(lenBuf[:], uint32(len(text)))
	buf = append(buf, lenBuf[:]...)
	buf = append(buf, []byte(text)...)
	_, err := conn.Write(buf)
	return err
}

// sendRawUpdate 发送一帧 Raw 编码的固定图案：左半红、右半蓝。
// 若收到过按下事件，再在该位置画 8x8 绿色方块——这样「输入到达对端」就是可断言的。
func sendRawUpdate(conn net.Conn, mark pointerMark) error {
	head := make([]byte, 0, 16)
	head = append(head, 0, 0)                          // message type 0, padding
	head = binary.BigEndian.AppendUint16(head, 1)      // 1 rect
	head = binary.BigEndian.AppendUint16(head, 0)      // x
	head = binary.BigEndian.AppendUint16(head, 0)      // y
	head = binary.BigEndian.AppendUint16(head, uint16(rfbWidth))
	head = binary.BigEndian.AppendUint16(head, uint16(rfbHeight))
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
			if keyMark && x >= 26 && x <= 34 && y >= 26 && y <= 34 {
				pixels[i+0] = 0xFF // B
				pixels[i+1] = 0x00
				pixels[i+2] = 0xFF // R -> FF00FF 洋红
				pixels[i+3] = 0x00
			}
		}
	}
	_, err := conn.Write(pixels)
	return err
}

// sendHextileUpdate 用 Hextile(5) 编码发同一图案。
// 每个 16x16 瓦片：BackgroundSpecified + AnySubrects + SubrectsColoured，
// 于是"左红右蓝 + 指针绿块"用少量 subrect 表达，客户端必须真的解码 Hextile。
func sendHextileUpdate(conn net.Conn, mark pointerMark) error {
	head := make([]byte, 0, 16)
	head = append(head, 0, 0)
	head = binary.BigEndian.AppendUint16(head, 1)
	head = binary.BigEndian.AppendUint16(head, 0)
	head = binary.BigEndian.AppendUint16(head, 0)
	head = binary.BigEndian.AppendUint16(head, uint16(rfbWidth))
	head = binary.BigEndian.AppendUint16(head, uint16(rfbHeight))
	head = binary.BigEndian.AppendUint32(head, 5) // encoding = Hextile
	if _, err := conn.Write(head); err != nil {
		return err
	}

	redPx := []byte{0x00, 0x00, 0xFF, 0x00}
	bluePx := []byte{0xFF, 0x00, 0x00, 0x00}
	greenPx := []byte{0x00, 0xFF, 0x00, 0x00}
	magentaPx := []byte{0xFF, 0x00, 0xFF, 0x00}

	for ty := 0; ty < rfbHeight; ty += 16 {
		for tx := 0; tx < rfbWidth; tx += 16 {
			tileW := 16
			if tx+tileW > rfbWidth {
				tileW = rfbWidth - tx
			}
			tileH := 16
			if ty+tileH > rfbHeight {
				tileH = rfbHeight - ty
			}
			// 以瓦片左列颜色作为背景，其它颜色用 subrect 覆盖
			isLeft := tx+tileW/2 <= rfbWidth/2
			var bg []byte
			if isLeft {
				bg = redPx
			} else {
				bg = bluePx
			}
			// subencoding: BackgroundSpecified(2) | AnySubrects(8) | SubrectsColoured(16)
			sub := byte(2 | 8 | 16)
			if _, err := conn.Write([]byte{sub}); err != nil {
				return err
			}
			if _, err := conn.Write(bg); err != nil {
				return err
			}
			// 收集需要覆盖的 subrect：跨色的半瓦片 + 绿块
			type subrect struct {
				px          []byte
				x, y, w, h  int
			}
			var subs []subrect
			// 跨色：瓦片横跨中线时，右半用蓝色覆盖
			if tx < rfbWidth/2 && tx+tileW > rfbWidth/2 {
				half := rfbWidth/2 - tx
				subs = append(subs, subrect{bluePx, half, 0, tileW - half, tileH})
			}
			// 绿块：与 Raw 路径保持一致的 8x8
			if mark.valid {
				x0 := mark.x - 4
				y0 := mark.y - 4
				// 与本瓦片求交
				ix := x0
				if ix < tx {
					ix = tx
				}
				iy := y0
				if iy < ty {
					iy = ty
				}
				ix2 := x0 + 9
				if ix2 > tx+tileW {
					ix2 = tx + tileW
				}
				iy2 := y0 + 9
				if iy2 > ty+tileH {
					iy2 = ty + tileH
				}
				if ix2 > ix && iy2 > iy {
					subs = append(subs, subrect{greenPx, ix - tx, iy - ty, ix2 - ix, iy2 - iy})
				}
			}
			// 键盘标记：洋红块固定在 (26..34, 26..34)，与 Raw 路径保持一致
			if keyMark {
				ix := 26
				if ix < tx {
					ix = tx
				}
				iy := 26
				if iy < ty {
					iy = ty
				}
				ix2 := 35
				if ix2 > tx+tileW {
					ix2 = tx + tileW
				}
				iy2 := 35
				if iy2 > ty+tileH {
					iy2 = ty + tileH
				}
				if ix2 > ix && iy2 > iy {
					subs = append(subs, subrect{magentaPx, ix - tx, iy - ty, ix2 - ix, iy2 - iy})
				}
			}
			if err := binary.Write(conn, binary.BigEndian, byte(len(subs))); err != nil {
				return err
			}
			for _, sr := range subs {
				if _, err := conn.Write(sr.px); err != nil {
					return err
				}
				if _, err := conn.Write([]byte{byte(sr.x<<4 | sr.y)}); err != nil {
					return err
				}
				if _, err := conn.Write([]byte{byte((sr.w - 1) << 4 | (sr.h - 1))}); err != nil {
					return err
				}
			}
		}
	}
	return nil
}

// startRFBFixture 在指定地址起 RFB 监听（每连接一个 goroutine）。
// password 非空时只提供 VNC Auth，用于验证 DES 认证路径。
func startRFBFixture(addr, password string) (net.Listener, error) {
	rfbPassword = password
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
