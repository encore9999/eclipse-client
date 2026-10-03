package xraybridge

import (
	"errors"
	"fmt"
	"os"
	"runtime/debug"
	"sync"

	"github.com/xtls/xray-core/core"
	_ "github.com/xtls/xray-core/main/distro/all"
	_ "github.com/xtls/xray-core/main/json"
)

var (
	mu       sync.Mutex
	instance *core.Instance
)

// Start запускает Xray из JSON. assetDir — каталог для geo-файлов (мы их не используем).
func Start(config string, assetDir string) (err error) {
	mu.Lock()
	defer mu.Unlock()
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("xray panic: %v", r)
		}
	}()
	if instance != nil {
		return errors.New("xray already running")
	}
	// Лимит памяти для extension (~50 МБ на весь процесс)
	debug.SetGCPercent(40)
	debug.SetMemoryLimit(32 << 20)
	os.Setenv("XRAY_LOCATION_ASSET", assetDir)

	inst, e := core.StartInstance("json", []byte(config))
	if e != nil {
		return e
	}
	instance = inst
	return nil
}

func Stop() {
	mu.Lock()
	defer mu.Unlock()
	if instance != nil {
		_ = instance.Close()
		instance = nil
	}
	debug.FreeOSMemory()
}

func IsRunning() bool {
	mu.Lock()
	defer mu.Unlock()
	return instance != nil
}

func Version() string { return core.Version() }
