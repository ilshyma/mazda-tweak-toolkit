#ifndef HTTPD_H
#define HTTPD_H

#define HTTP_PORT       8035
#define HTTP_BACKLOG    4
#define HTTP_BUF_SIZE   4096
#define HTTP_BODY_MAX   8192

typedef enum { HTTP_GET, HTTP_POST, HTTP_UNKNOWN } http_method_t;

typedef struct {
    http_method_t method;
    char path[256];
    char body[HTTP_BODY_MAX];
    int body_len;
    int client_fd;
} http_request_t;

typedef void (*http_handler_t)(http_request_t *req);

typedef struct {
    const char *prefix;
    http_method_t method;
    http_handler_t handler;
} http_route_t;

int  httpd_init(void);
void httpd_add_route(const char *prefix, http_method_t method, http_handler_t handler);
void httpd_run(void);
void httpd_stop(void);

void http_respond(http_request_t *req, int status, const char *content_type, const char *body);
void http_respond_json(http_request_t *req, int status, const char *json);
void http_respond_error(http_request_t *req, int status, const char *message);

#endif
