package xraybridge

import (
	"context"
	"errors"
	"fmt"
	"runtime/debug"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/option"
)

// sing-box используется ТОЛЬКО для протоколов, которых нет в Xray-core (сейчас - TUIC).
// Он слушает локальный SOCKS5, как и Xray, поэтому Tun2SocksKit работает без изменений.
var (
	sbInstance *box.Box
	sbCancel   context.CancelFunc
)

// StartSingbox запускает sing-box из JSON. workDir зарезервирован под кэш/данные.
func StartSingbox(config string, workDir string) (err error) {
	mu.Lock()
	defer mu.Unlock()
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("sing-box panic: %v", r)
		}
	}()
	if sbInstance != nil || instance != nil {
		return errors.New("core already running")
	}
	_ = workDir

	debug.SetGCPercent(40)
	debug.SetMemoryLimit(memoryLimit)

	ctx, cancel := context.WithCancel(box.Context(
		context.Background(),
		include.InboundRegistry(),
		include.OutboundRegistry(),
		include.EndpointRegistry(),
		include.DNSTransportRegistry(),
		include.ServiceRegistry(),
	))

	var opts option.Options
	if e := opts.UnmarshalJSONContext(ctx, []byte(config)); e != nil {
		cancel()
		return fmt.Errorf("config: %w", e)
	}
	inst, e := box.New(box.Options{Context: ctx, Options: opts})
	if e != nil {
		cancel()
		return e
	}
	if e := inst.Start(); e != nil {
		_ = inst.Close()
		cancel()
		return e
	}
	sbInstance = inst
	sbCancel = cancel
	return nil
}

// stopSingbox вызывается из Stop() под уже взятым mu.
func stopSingbox() {
	if sbInstance != nil {
		_ = sbInstance.Close()
		sbInstance = nil
	}
	if sbCancel != nil {
		sbCancel()
		sbCancel = nil
	}
}
