// Command smoke-proxy is a minimal path-based reverse proxy used by the
// OpenStrata cross-repo smoke test. aictl assumes a SINGLE control-plane
// endpoint (OPENSTRATA_ENDPOINT); this proxy fans requests out by path prefix
// to the individual services so a unified E2E can be exercised.
//
// It is stdlib-only and reads its route table from PROXY_ROUTES_JSON.
package main

import (
	"encoding/json"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
)

type entry struct {
	prefix string
	target *url.URL
	exact  bool
}

func main() {
	routesPath := os.Getenv("PROXY_ROUTES_JSON")
	if routesPath == "" {
		log.Fatal("PROXY_ROUTES_JSON must point to a route-table JSON file")
	}
	b, err := os.ReadFile(routesPath)
	if err != nil {
		log.Fatalf("read routes: %v", err)
	}
	var raw map[string]string
	if err := json.Unmarshal(b, &raw); err != nil {
		log.Fatalf("parse routes: %v", err)
	}

	entries := make([]entry, 0, len(raw))
	for k, v := range raw {
		u, err := url.Parse(v)
		if err != nil {
			log.Fatalf("bad target %q: %v", v, err)
		}
		exact := len(k) == 0 || k[len(k)-1] != '/'
		entries = append(entries, entry{prefix: k, target: u, exact: exact})
	}

	addr := os.Getenv("ADDR")
	if addr == "" {
		addr = ":8079"
	}

	handler := func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		var best *entry
		for i := range entries {
			e := &entries[i]
			if e.exact {
				if e.prefix == path {
					best = e
					break
				}
				continue
			}
			if len(path) >= len(e.prefix) && path[:len(e.prefix)] == e.prefix {
				if best == nil || len(e.prefix) > len(best.prefix) {
					best = e
				}
			}
		}
		if best == nil {
			http.NotFound(w, r)
			return
		}
		httputil.NewSingleHostReverseProxy(best.target).ServeHTTP(w, r)
	}

	log.Printf("smoke-proxy listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, http.HandlerFunc(handler)))
}
