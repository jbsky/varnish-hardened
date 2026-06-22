// Varnish hardened init — replaces shell entrypoint + curl healthcheck.
// Static binary, zero shell dependency at runtime.
//
// Usage:
//
//	init --healthcheck      run Docker/k8s healthcheck (exit 0/1)
//	init --setup-dirs       create runtime directories (build-time)
//	init [ARGS...]          entrypoint: exec varnishd with args
package main

import (
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"strconv"
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
		case "--setup-dirs":
			if err := setupDirs(); err != nil {
				fmt.Fprintf(os.Stderr, "[init][ERROR] setup-dirs: %v\n", err)
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

func setupDirs() error {
	dirs := []struct {
		path string
		mode os.FileMode
		uid  int
		gid  int
	}{
		{"/var/lib/varnish", 0755, varnishUID, varnishGID},
		{"/var/log/varnish", 0755, varnishUID, varnishGID},
		{"/etc/varnish", 0755, varnishUID, varnishGID},
		{"/tmp", 01777, 0, 0},
	}
	for _, d := range dirs {
		fmt.Printf("[init] mkdir %s (mode=%04o uid=%d gid=%d)\n", d.path, d.mode, d.uid, d.gid)
		if err := os.MkdirAll(d.path, d.mode); err != nil {
			return fmt.Errorf("mkdir %s: %w", d.path, err)
		}
		if err := os.Chmod(d.path, d.mode); err != nil {
			return fmt.Errorf("chmod %s: %w", d.path, err)
		}
		if err := os.Chown(d.path, d.uid, d.gid); err != nil {
			return fmt.Errorf("chown %s: %w", d.path, err)
		}
	}
	fmt.Println("[init] setup-dirs complete")
	return nil
}

// ---------------------------------------------------------------------------
// Healthcheck: HTTP GET /healthcheck on varnish
// ---------------------------------------------------------------------------

func healthcheck() int {
	url := envGet("VARNISH_HEALTH_URL", healthURL)
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
	vclFile := envGet("VARNISH_VCL", defaultVCL)
	cacheSize := envGet("VARNISH_SIZE", defaultSize)
	httpPort := envGet("VARNISH_HTTP_PORT", "8080")
	proxyPort := envGet("VARNISH_PROXY_PORT", "8443")

	if !fileExists(vclFile) {
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
		envGet("VARNISH_VERSION", "?"), vclFile, cacheSize, httpPort, proxyPort)
	log("Workdir: %s", workdir)
	log("Starting: %s", strings.Join(args, " "))

	return execProcess(args)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func envGet(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func envGetInt(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		if i, err := strconv.Atoi(v); err == nil {
			return i
		}
	}
	return fallback
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
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
