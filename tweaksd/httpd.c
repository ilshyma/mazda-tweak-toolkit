#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <signal.h>
#include <errno.h>
#include "httpd.h"

#define MAX_ROUTES 32

static int server_fd = -1;
static volatile int running = 1;
static http_route_t routes[MAX_ROUTES];
static int route_count = 0;

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

void http_respond_error(http_request_t *req, int status, const char *message) {
    char buf[512];
    snprintf(buf, sizeof(buf), "{\"error\":\"%s\"}", message);
    http_respond_json(req, status, buf);
}

static void dispatch(http_request_t *req) {
    for (int i = 0; i < route_count; i++) {
        if (routes[i].method == req->method &&
            strncmp(req->path, routes[i].prefix, strlen(routes[i].prefix)) == 0) {
            routes[i].handler(req);
            return;
        }
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
