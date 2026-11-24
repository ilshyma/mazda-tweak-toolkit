#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/stat.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <signal.h>
#include <errno.h>
#include <fcntl.h>
#include "httpd.h"

#define MAX_ROUTES 32

static int server_fd = -1;
static volatile int running = 1;
static http_route_t routes[MAX_ROUTES];
static int route_count = 0;
static char static_dir[256] = "";

int httpd_init(void) {
    struct sockaddr_in addr;
    int opt = 1;

    server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) return -1;

    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(HTTP_PORT);

    if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(server_fd);
        return -1;
    }

    if (listen(server_fd, HTTP_BACKLOG) < 0) {
        close(server_fd);
        return -1;
    }

    return 0;
}

void httpd_set_static_dir(const char *dir) {
    /* Resolve symlinks so serve_static's realpath check can match */
    char resolved[256];
    if (realpath(dir, resolved)) {
        snprintf(static_dir, sizeof(static_dir), "%s", resolved);
    } else {
        snprintf(static_dir, sizeof(static_dir), "%s", dir);
    }
    int len = strlen(static_dir);
    if (len > 0 && static_dir[len - 1] == '/')
        static_dir[len - 1] = '\0';
}

void httpd_add_route(const char *prefix, http_method_t method, http_handler_t handler) {
    if (route_count >= MAX_ROUTES) return;
    routes[route_count].prefix = prefix;
    routes[route_count].method = method;
    routes[route_count].handler = handler;
    route_count++;
}

static int parse_request(int fd, http_request_t *req) {
    char buf[HTTP_BUF_SIZE];
    int total = 0;
    int n;

    memset(req, 0, sizeof(*req));
    req->client_fd = fd;
    req->method = HTTP_UNKNOWN;

    n = recv(fd, buf, sizeof(buf) - 1, 0);
    if (n <= 0) return -1;
    buf[n] = '\0';
    total = n;

    if (strncmp(buf, "GET ", 4) == 0) {
        req->method = HTTP_GET;
        char *end = strchr(buf + 4, ' ');
        if (!end) return -1;
        int plen = end - (buf + 4);
        if (plen >= (int)sizeof(req->path)) plen = sizeof(req->path) - 1;
        memcpy(req->path, buf + 4, plen);
        req->path[plen] = '\0';
    } else if (strncmp(buf, "POST ", 5) == 0) {
        req->method = HTTP_POST;
        char *end = strchr(buf + 5, ' ');
        if (!end) return -1;
        int plen = end - (buf + 5);
        if (plen >= (int)sizeof(req->path)) plen = sizeof(req->path) - 1;
        memcpy(req->path, buf + 5, plen);
        req->path[plen] = '\0';
    } else if (strncmp(buf, "OPTIONS ", 8) == 0) {
        req->method = HTTP_OPTIONS;
        char *end = strchr(buf + 8, ' ');
        if (!end) return -1;
        int plen = end - (buf + 8);
        if (plen >= (int)sizeof(req->path)) plen = sizeof(req->path) - 1;
        memcpy(req->path, buf + 8, plen);
        req->path[plen] = '\0';
    } else {
        return -1;
    }

    char *body_start = strstr(buf, "\r\n\r\n");
    if (body_start) {
        body_start += 4;
        int body_in_buf = total - (body_start - buf);

        char *cl = strcasestr(buf, "Content-Length:");
        int content_length = 0;
        if (cl) content_length = atoi(cl + 15);
        if (content_length > HTTP_BODY_MAX - 1) content_length = HTTP_BODY_MAX - 1;

        if (body_in_buf > 0) {
            int copy = body_in_buf;
            if (copy > content_length) copy = content_length;
            memcpy(req->body, body_start, copy);
            req->body_len = copy;
        }

        while (req->body_len < content_length) {
            n = recv(fd, req->body + req->body_len,
                     content_length - req->body_len, 0);
            if (n <= 0) break;
            req->body_len += n;
        }
        req->body[req->body_len] = '\0';
    }

    return 0;
}

static const char *mime_for_ext(const char *path) {
    const char *dot = strrchr(path, '.');
    if (!dot) return "application/octet-stream";
    if (strcasecmp(dot, ".html") == 0 || strcasecmp(dot, ".htm") == 0)
        return "text/html; charset=utf-8";
    if (strcasecmp(dot, ".css") == 0)
        return "text/css; charset=utf-8";
    if (strcasecmp(dot, ".js") == 0)
        return "application/javascript; charset=utf-8";
    if (strcasecmp(dot, ".json") == 0)
        return "application/json";
    if (strcasecmp(dot, ".png") == 0)
        return "image/png";
    if (strcasecmp(dot, ".svg") == 0)
        return "image/svg+xml";
    if (strcasecmp(dot, ".ico") == 0)
        return "image/x-icon";
    if (strcasecmp(dot, ".woff2") == 0)
        return "font/woff2";
    if (strcasecmp(dot, ".woff") == 0)
        return "font/woff";
    return "application/octet-stream";
}

void http_respond(http_request_t *req, int status, const char *content_type,
                  const char *body) {
    char header[512];
    const char *reason = "OK";
    if (status == 400) reason = "Bad Request";
    else if (status == 404) reason = "Not Found";
    else if (status == 409) reason = "Conflict";
    else if (status == 500) reason = "Internal Server Error";
    else if (status == 503) reason = "Service Unavailable";

    int body_len = body ? strlen(body) : 0;
    int hlen = snprintf(header, sizeof(header),
        "HTTP/1.1 %d %s\r\n"
        "Content-Type: %s\r\n"
        "Content-Length: %d\r\n"
        "Access-Control-Allow-Origin: *\r\n"
        "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        "Access-Control-Allow-Headers: Content-Type\r\n"
        "Connection: close\r\n"
        "\r\n",
        status, reason, content_type, body_len);

    send(req->client_fd, header, hlen, 0);
    if (body && body_len > 0)
        send(req->client_fd, body, body_len, 0);
}

void http_respond_json(http_request_t *req, int status, const char *json) {
    http_respond(req, status, "application/json", json);
}

void http_respond_html(http_request_t *req, int status, const char *html) {
    http_respond(req, status, "text/html; charset=utf-8", html);
}

void http_respond_error(http_request_t *req, int status, const char *message) {
    char buf[512];
    char escaped[256];
    int j = 0;
    for (int i = 0; message[i] && j < (int)sizeof(escaped) - 2; i++) {
        if (message[i] == '"' || message[i] == '\\') escaped[j++] = '\\';
        escaped[j++] = message[i];
    }
    escaped[j] = '\0';
    snprintf(buf, sizeof(buf), "{\"error\":\"%s\"}", escaped);
    http_respond_json(req, status, buf);
}

void http_respond_file(http_request_t *req, const char *filepath) {
    struct stat st;
    if (stat(filepath, &st) != 0 || !S_ISREG(st.st_mode)) {
        http_respond_error(req, 404, "not found");
        return;
    }

    int fd = open(filepath, O_RDONLY);
    if (fd < 0) {
        http_respond_error(req, 500, "cannot open file");
        return;
    }

    const char *ct = mime_for_ext(filepath);
    char header[512];
    int hlen = snprintf(header, sizeof(header),
        "HTTP/1.1 200 OK\r\n"
        "Content-Type: %s\r\n"
        "Content-Length: %ld\r\n"
        "Access-Control-Allow-Origin: *\r\n"
        "Cache-Control: no-cache\r\n"
        "Connection: close\r\n"
        "\r\n",
        ct, (long)st.st_size);

    send(req->client_fd, header, hlen, 0);

    char fbuf[HTTP_FILE_BUF];
    ssize_t r;
    while ((r = read(fd, fbuf, sizeof(fbuf))) > 0) {
        send(req->client_fd, fbuf, r, 0);
    }
    close(fd);
}

static void handle_cors_preflight(http_request_t *req) {
    char header[256];
    int hlen = snprintf(header, sizeof(header),
        "HTTP/1.1 204 No Content\r\n"
        "Access-Control-Allow-Origin: *\r\n"
        "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        "Access-Control-Allow-Headers: Content-Type\r\n"
        "Access-Control-Max-Age: 86400\r\n"
        "Connection: close\r\n"
        "\r\n");
    send(req->client_fd, header, hlen, 0);
}

static const char fallback_page[] =
    "<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
    "<meta name=\"viewport\" content=\"width=device-width\">"
    "<title>Tweaks Manager</title>"
    "<style>body{font-family:sans-serif;background:#1a1a2e;color:#e0e0e0;"
    "display:flex;align-items:center;justify-content:center;min-height:100vh;"
    "margin:0}div{text-align:center;max-width:400px;padding:2em}"
    "h1{color:#ff6b6b;font-size:1.4em}p{line-height:1.6;color:#aaa}"
    "code{background:#2a2a4a;padding:2px 6px;border-radius:3px}</style>"
    "</head><body><div>"
    "<h1>&#9888; Wizard UI not found</h1>"
    "<p>The web interface files are missing.<br>"
    "Re-run <code>prepare-usb.sh</code> to rebuild the USB with the wizard.</p>"
    "<p style=\"margin-top:2em;font-size:.85em\">"
    "API is still available at <code>/api/</code></p>"
    "</div></body></html>";

static void serve_static(http_request_t *req) {
    if (static_dir[0] == '\0') {
        /* No wizard dir — serve a helpful fallback page instead of bare 404 */
        if (strcmp(req->path, "/") == 0 || strcmp(req->path, "/index.html") == 0) {
            http_respond_html(req, 200, fallback_page);
        } else {
            http_respond_error(req, 404, "no static dir configured");
        }
        return;
    }

    const char *path = req->path;
    if (strcmp(path, "/") == 0) path = "/index.html";

    if (strstr(path, "..")) {
        http_respond_error(req, 403, "forbidden");
        return;
    }

    char fullpath[512];
    snprintf(fullpath, sizeof(fullpath), "%s%s", static_dir, path);

    /* Resolve symlinks and verify path stays under static_dir */
    char resolved[512];
    if (!realpath(fullpath, resolved)) {
        http_respond_error(req, 404, "not found");
        return;
    }
    int slen = strlen(static_dir);
    if (strncmp(resolved, static_dir, slen) != 0 ||
        (resolved[slen] != '/' && resolved[slen] != '\0')) {
        http_respond_error(req, 403, "forbidden");
        return;
    }

    http_respond_file(req, resolved);
}

static void dispatch(http_request_t *req) {
    if (req->method == HTTP_OPTIONS) {
        handle_cors_preflight(req);
        return;
    }

    for (int i = 0; i < route_count; i++) {
        if (routes[i].method == req->method &&
            strncmp(req->path, routes[i].prefix, strlen(routes[i].prefix)) == 0) {
            routes[i].handler(req);
            return;
        }
    }

    if (req->method == HTTP_GET && static_dir[0] != '\0' &&
        strncmp(req->path, "/api/", 5) != 0) {
        serve_static(req);
        return;
    }

    http_respond_error(req, 404, "not found");
}

void httpd_run(void) {
    while (running) {
        struct sockaddr_in client_addr;
        socklen_t client_len = sizeof(client_addr);
        int client_fd = accept(server_fd, (struct sockaddr *)&client_addr,
                               &client_len);
        if (client_fd < 0) {
            if (errno == EINTR) continue;
            break;
        }

        struct timeval tv = {5, 0};
        setsockopt(client_fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(client_fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

        http_request_t req;
        if (parse_request(client_fd, &req) == 0) {
            dispatch(&req);
        }
        close(client_fd);
    }
}

void httpd_stop(void) {
    running = 0;
    if (server_fd >= 0) {
        close(server_fd);
        server_fd = -1;
    }
}
