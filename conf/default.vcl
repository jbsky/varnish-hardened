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

    # Healthcheck endpoint (always synthetic 200)
    if (req.url == "/healthcheck") {
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
