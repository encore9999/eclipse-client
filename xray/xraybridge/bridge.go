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
	mu          sync.Mutex
	instance    *core.Instance
	memoryLimit int64 = 50 << 20 // по умолчанию 50 МБ
)

// SetMemoryLimit — вызывается из Swift до Start().
// mb — лимит памяти в мегабайтах. Если <= 0 — игнорируется.
// Это ЖЁСТКИЙ лимит рантайма Go: при превышении процесс падает с fatal error.
func SetMemoryLimit(mb int32) {
	mu.Lock()
	defer mu.Unlock()
	if mb > 0 {
		memoryLimit = int64(mb) << 20
	}
}

// Start запускает Xray из JSON. assetDir — каталог для geo-файлов.
func Start(config string, assetDir string) (err error) {
	mu.Lock()
	defer mu.Unlock()
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("xray panic: %v", r)
		}
	}()
	if instance != nil || sbInstance != nil {
		return errors.New("core already running")
	}

	// Лимит памяти для extension: берём из SetMemoryLimit (или 50 МБ по умолчанию).
	// GC агрессивнее обычного — расширению iOS нельзя раздувать RSS.
	debug.SetGCPercent(40)
	debug.SetMemoryLimit(memoryLimit)

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
	stopSingbox()
	debug.FreeOSMemory()
}

func IsRunning() bool {
	mu.Lock()
	defer mu.Unlock()
	return instance != nil || sbInstance != nil
}

func Version() string { return core.Version() }
