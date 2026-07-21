vcl 4.1;

# Minimal test VCL — local development only.
# Production VCL is mounted via ConfigMap in k8s.

backend default {
    .host = "127.0.0.1";
    .port = "9999";
}

sub vcl_recv {
    # Reject dangerous/non-standard methods before they ever reach a backend
    # (mirrors the production VCL's intent -- see front-home/overlay/varnish).
    if (req.method == "TRACE") {
        return (synth(405, "Method Not Allowed"));
    }

    # Healthcheck endpoint (always synthetic 200). Two paths on purpose:
    # /healthcheck is what scripts/test.sh curls, /__health is what the Go
    # init's own --healthcheck (and Docker's HEALTHCHECK, which drives
    # `docker inspect`'s Health.Status) queries by default -- production's
    # real VCL (front-home/varnish/templates/statefulset.yaml) already
    # handles /__health; this dev/test VCL never did, so the container's
    # own healthcheck has been permanently failing (503, no backend) even
    # though scripts/test.sh's direct /healthcheck check always passed.
    if (req.url == "/healthcheck" || req.url == "/__health") {
        return (synth(200, "OK"));
    }
}

sub vcl_deliver {
    unset resp.http.Via;
}

sub vcl_synth {
    if (resp.status == 200) {
        set resp.http.Content-Type = "text/plain; charset=utf-8";
        set resp.http.Cache-Control = "no-store";
        synthetic("OK");
        return (deliver);
    }
}
