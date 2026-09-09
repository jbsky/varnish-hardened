// Varnish hardened init — replaces shell entrypoint + curl healthcheck.
// Static binary, zero shell dependency at runtime.
//
// Usage:
//
//	init --healthcheck      run Docker/k8s healthcheck (exit 0/1)
//	init [ARGS...]          entrypoint: exec varnishd with args
package main

import (
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

const (
	varnishUID  = 6081
	varnishGID  = 65534
	varnishBin  = "/usr/sbin/varnishd"
	defaultVCL  = "/etc/varnish/default.vcl"
	defaultSize = "256M"
	healthURL   = "http://127.0.0.1:8080/__health"
)

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "--healthcheck":
			os.Exit(healthcheck())
		case "--export-tools":
			dest := "/tools"
			if len(os.Args) > 2 {
				dest = os.Args[2]
			}
			if err := exportTools(dest); err != nil {
				fmt.Fprintf(os.Stderr, "[init][ERROR] export-tools: %v\n", err)
				os.Exit(1)
			}
			return
		}
	}
	if err := entrypoint(); err != nil {
		fmt.Fprintf(os.Stderr, "[init][ERROR] %v\n", err)
		os.Exit(1)
	}
}

// ---------------------------------------------------------------------------
// Setup directories
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Healthcheck: HTTP GET /healthcheck on varnish
// ---------------------------------------------------------------------------

func healthcheck() int {
	url := env("VARNISH_HEALTH_URL", healthURL)
	client := &http.Client{Timeout: 3 * time.Second}

	resp, err := client.Get(url)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[healthcheck] GET %s failed: %v\n", url, err)
		return 1
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 400 {
		fmt.Fprintf(os.Stderr, "[healthcheck] GET %s returned %d\n", url, resp.StatusCode)
		return 1
	}
	return 0
}

// ---------------------------------------------------------------------------
// Entrypoint: build varnishd command line and exec
// ---------------------------------------------------------------------------

func entrypoint() error {
	// If raw varnishd flags passed (from k8s args/CMD), exec varnishd directly
	if len(os.Args) > 1 && strings.HasPrefix(os.Args[1], "-") {
		args := append([]string{varnishBin, "-F"}, os.Args[1:]...)
		log("Exec (raw args): %s", strings.Join(args, " "))
		return execProcess(args)
	}

	// If a full command passed (e.g., varnishd -F ...)
	if len(os.Args) > 1 {
		return execProcess(os.Args[1:])
	}

	// Default: build varnishd command from env vars
	vclFile := env("VARNISH_VCL", defaultVCL)
	cacheSize := env("VARNISH_SIZE", defaultSize)
	httpPort := env("VARNISH_HTTP_PORT", "8080")
	proxyPort := env("VARNISH_PROXY_PORT", "8443")

	if !exists(vclFile) {
		return fmt.Errorf("VCL file not found: %s", vclFile)
	}

	// Ensure workdir exists
	hostname, _ := os.Hostname()
	workdir := "/var/lib/varnish/" + hostname
	os.MkdirAll(workdir, 0755)

	args := []string{
		varnishBin,
		"-F",
		"-f", vclFile,
		"-a", "http=:" + httpPort + ",HTTP",
		"-a", "proxy=:" + proxyPort + ",PROXY",
		"-p", "feature=+http2",
		"-s", "malloc," + cacheSize,
		"-n", workdir,
	}

	// Append extra args from VARNISH_OPTS env
	if opts := os.Getenv("VARNISH_OPTS"); opts != "" {
		args = append(args, strings.Fields(opts)...)
	}

	log("Varnish %s | VCL=%s | cache=%s | http=:%s | proxy=:%s",
		env("VARNISH_VERSION", "?"), vclFile, cacheSize, httpPort, proxyPort)
	log("Workdir: %s", workdir)
	log("Starting: %s", strings.Join(args, " "))

	return execProcess(args)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// writeOK dit si un repertoire accepte reellement une ecriture. mkdir + chmod
// + chown peuvent tous reussir sur un point de montage en lecture seule :
// seule une ecriture le prouve.
func writeOK(dir string) bool {
	tmp, err := os.CreateTemp(dir, ".write-test-*")
	if err != nil {
		return false
	}
	name := tmp.Name()
	tmp.Close()
	os.Remove(name)
	return true
}

func execProcess(args []string) error {
	var bin string
	var err error
	if len(args[0]) > 0 && args[0][0] == '/' {
		bin = args[0]
	} else {
		bin, err = exec.LookPath(args[0])
		if err != nil {
			return fmt.Errorf("command not found: %s", args[0])
		}
	}
	return syscall.Exec(bin, args, os.Environ())
}

func log(format string, a ...any) {
	fmt.Printf("[init] "+format+"\n", a...)
}

// ---------------------------------------------------------------------------
// Export tools: copy varnishadm and varnishstat to a shared volume so that
// sidecar containers (busybox) can use them for hot-reload and monitoring.
// Called by an init-container: init --export-tools /var/lib/varnish
// ---------------------------------------------------------------------------

func exportTools(dest string) error {
	tools := []string{
		"/usr/bin/varnishadm",
		"/usr/bin/varnishstat",
	}

	if err := os.MkdirAll(dest, 0755); err != nil {
		return fmt.Errorf("mkdir %s: %w", dest, err)
	}

	for _, src := range tools {
		if !exists(src) {
			log("skip %s (not found)", src)
			continue
		}
		data, err := os.ReadFile(src)
		if err != nil {
			return fmt.Errorf("read %s: %w", src, err)
		}
		dstPath := dest + "/" + src[strings.LastIndex(src, "/")+1:]
		if err := os.WriteFile(dstPath, data, 0755); err != nil {
			return fmt.Errorf("write %s: %w", dstPath, err)
		}
		log("exported %s -> %s (%d bytes)", src, dstPath, len(data))
	}
	return nil
}
