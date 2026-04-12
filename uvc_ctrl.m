/*
 * uvc_ctrl – Logitech Orbit AF controller for macOS
 *
 * Single binary: USB control via IOKit + built-in HTTP server.
 *   ./uvc_ctrl                   ← start PTZ server on http://localhost:9090
 *   ./uvc_ctrl pantilt 3 0      ← CLI pan/tilt
 *   ./uvc_ctrl reset            ← CLI reset
 *
 * Compile:
 *   clang -o uvc_ctrl uvc_ctrl.m -framework IOKit -framework CoreFoundation \
 *         -framework AVFoundation -framework CoreMedia -fobjc-arc
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <signal.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/IOCFPlugIn.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

/* ── USB identifiers & UVC constants ───────────────────────────── */

#define VID 0x046d
#define PID 0x0994

#define UVC_SET_CUR 0x01
#define UVC_GET_CUR 0x81
#define UVC_GET_MIN 0x82
#define UVC_GET_MAX 0x83
#define UVC_GET_DEF 0x87

#define UVC_PU_ID  0x02   /* Processing Unit */
#define UVC_CT_ID  0x01   /* Camera Terminal */

/* Processing Unit selectors */
#define PU_BRIGHTNESS           0x02
#define PU_CONTRAST             0x03
#define PU_GAIN                 0x04
#define PU_POWER_LINE_FREQ      0x05
#define PU_SATURATION           0x07
#define PU_SHARPNESS            0x08
#define PU_WB_TEMP              0x0A
#define PU_WB_TEMP_AUTO         0x0B
#define PU_BACKLIGHT_COMP       0x01

/* Camera Terminal selectors */
#define CT_AE_MODE              0x02
#define CT_EXPOSURE_TIME_ABS    0x04
#define CT_FOCUS_ABS            0x06
#define CT_FOCUS_AUTO           0x08

/* Logitech extension units */
#define LOGITECH_MOTOR_UNIT   0x09
#define LXU_PANTILT_RELATIVE  0x01
#define LXU_PANTILT_RESET     0x02

#define LOGITECH_HW_CTRL_UNIT 0x0A
#define LXU_HW_LED1           0x01

#define LXU_MOTOR_ENABLE      0x80
#define LXU_RESET_VALUE       0x03

#define LED_OFF   0x00
#define LED_ON    0x01
#define LED_BLINK 0x02
#define LED_AUTO  0x03

/* ── HTTP server constants ─────────────────────────────────────── */

#define HTTP_PORT 9090
#define HTTP_BUF  16384

/* ── Camera settings table ─────────────────────────────────────── */

typedef struct {
    const char *name;
    int unit;
    int selector;
    int size;
} uvc_setting_t;

static const uvc_setting_t SETTINGS[] = {
    { "brightness",         UVC_PU_ID, PU_BRIGHTNESS,      2 },
    { "contrast",           UVC_PU_ID, PU_CONTRAST,        2 },
    { "saturation",         UVC_PU_ID, PU_SATURATION,      2 },
    { "sharpness",          UVC_PU_ID, PU_SHARPNESS,       2 },
};
#define NUM_SETTINGS (sizeof(SETTINGS) / sizeof(SETTINGS[0]))

/* ── IOKit: find and talk to the camera ────────────────────────── */

static IOUSBDeviceInterface187 **find_device(void) {
    CFMutableDictionaryRef match = IOServiceMatching(kIOUSBDeviceClassName);
    if (!match) return NULL;

    long vid = VID, pid = PID;
    CFNumberRef vr = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &vid);
    CFNumberRef pr = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &pid);
    CFDictionarySetValue(match, CFSTR(kUSBVendorID), vr);
    CFDictionarySetValue(match, CFSTR(kUSBProductID), pr);
    CFRelease(vr);
    CFRelease(pr);

    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, match);
    if (!svc) return NULL;

    IOCFPlugInInterface **plugIn = NULL;
    SInt32 score;
    kern_return_t kr = IOCreatePlugInInterfaceForService(
        svc, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID,
        &plugIn, &score);
    IOObjectRelease(svc);
    if (kr != kIOReturnSuccess || !plugIn) return NULL;

    IOUSBDeviceInterface187 **dev = NULL;
    (*plugIn)->QueryInterface(plugIn,
        CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID187), (LPVOID *)&dev);
    (*plugIn)->Release(plugIn);
    return dev;
}

static int uvc_control(uint8_t bmReqType, uint8_t bRequest,
                       int unitId, int selector, void *data, int length) {
    IOUSBDeviceInterface187 **dev = find_device();
    if (!dev) { fprintf(stderr, "error: camera not found\n"); return 1; }

    kern_return_t kr = (*dev)->USBDeviceOpen(dev);
    if (kr == (kern_return_t)0xe00002c5)
        kr = (*dev)->USBDeviceOpenSeize(dev);
    if (kr != kIOReturnSuccess) {
        fprintf(stderr, "error: USBDeviceOpen failed (0x%08x)\n", kr);
        (*dev)->Release(dev);
        return 1;
    }

    IOUSBDevRequest req = {
        .bmRequestType = bmReqType,
        .bRequest      = bRequest,
        .wValue        = (uint16_t)(selector << 8),
        .wIndex        = (uint16_t)(unitId   << 8),
        .wLength       = (uint16_t)length,
        .wLenDone      = 0,
        .pData         = data,
    };
    kr = (*dev)->DeviceRequest(dev, &req);
    (*dev)->USBDeviceClose(dev);
    (*dev)->Release(dev);

    if (kr != kIOReturnSuccess) {
        fprintf(stderr, "error: DeviceRequest failed (0x%08x)\n", kr);
        return 1;
    }
    return 0;
}

/* Helper: read a signed value from the camera */
static int uvc_get_val(uint8_t request, int unit, int sel, int sz, int32_t *out) {
    int32_t val = 0;
    int ret = uvc_control(USBmakebmRequestType(kUSBIn, kUSBClass, kUSBInterface),
                          request, unit, sel, &val, sz);
    if (ret == 0 && out) {
        if (sz == 1) *out = (int32_t)(int8_t)(val & 0xFF);
        else if (sz == 2) *out = (int32_t)(int16_t)(val & 0xFFFF);
        else *out = val;
    }
    return ret;
}

/* ── Camera commands ───────────────────────────────────────────── */

static int cmd_pantilt(int pan, int tilt) {
    uint8_t buf[4] = {0, 0, 0, 0};
    if (pan != 0) {
        buf[0] = LXU_MOTOR_ENABLE;
        int8_t v = (int8_t)(pan);
        buf[1] = (uint8_t)(v < 0 ? v : v - 1);
    }
    if (tilt != 0) {
        buf[2] = LXU_MOTOR_ENABLE;
        int8_t v = (int8_t)(-tilt);
        buf[3] = (uint8_t)(v < 0 ? v : v - 1);
    }
    return uvc_control(USBmakebmRequestType(kUSBOut, kUSBClass, kUSBInterface),
                       UVC_SET_CUR, LOGITECH_MOTOR_UNIT, LXU_PANTILT_RELATIVE, buf, 4);
}

static int cmd_reset(void) {
    uint8_t val = LXU_RESET_VALUE;
    int ret = uvc_control(USBmakebmRequestType(kUSBOut, kUSBClass, kUSBInterface),
                          UVC_SET_CUR, LOGITECH_MOTOR_UNIT, LXU_PANTILT_RESET, &val, 1);
    if (ret != 0) {
        uint8_t val2[2] = {LXU_RESET_VALUE, 0};
        ret = uvc_control(USBmakebmRequestType(kUSBOut, kUSBClass, kUSBInterface),
                          UVC_SET_CUR, LOGITECH_MOTOR_UNIT, LXU_PANTILT_RESET, val2, 2);
    }
    return ret;
}

static int cmd_led(const char *m) {
    uint8_t buf[3] = {0, 0, 0};
    if      (strcmp(m, "off")  == 0) buf[0] = LED_OFF;
    else if (strcmp(m, "on")   == 0) buf[0] = LED_ON;
    else if (strcmp(m, "blink")== 0) buf[0] = LED_BLINK;
    else if (strcmp(m, "auto") == 0) buf[0] = LED_AUTO;
    else { fprintf(stderr, "error: unknown LED mode: %s\n", m); return 1; }
    return uvc_control(USBmakebmRequestType(kUSBOut, kUSBClass, kUSBInterface),
                       UVC_SET_CUR, LOGITECH_HW_CTRL_UNIT, LXU_HW_LED1, buf, 3);
}

static int cmd_set(int unit, int sel, int sz, long val) {
    return uvc_control(USBmakebmRequestType(kUSBOut, kUSBClass, kUSBInterface),
                       UVC_SET_CUR, unit, sel, &val, sz);
}

static int cmd_get(uint8_t rq, int unit, int sel, int sz) {
    long val = 0;
    int ret = uvc_control(USBmakebmRequestType(kUSBIn, kUSBClass, kUSBInterface),
                          rq, unit, sel, &val, sz);
    if (ret == 0) printf("%ld\n", val);
    return ret;
}

/* ── HTTP helpers ──────────────────────────────────────────────── */

static char *slurp_file(const char *path, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = malloc((size_t)len + 1);
    if (buf) {
        fread(buf, 1, (size_t)len, f);
        buf[len] = '\0';
    }
    fclose(f);
    if (out_len) *out_len = (size_t)len;
    return buf;
}

static void http_respond(int fd, int code, const char *ctype,
                         const char *body, size_t body_len) {
    const char *status = code == 200 ? "OK" : code == 404 ? "Not Found" : "Error";
    char hdr[512];
    int hlen = snprintf(hdr, sizeof(hdr),
        "HTTP/1.1 %d %s\r\n"
        "Content-Type: %s\r\n"
        "Content-Length: %zu\r\n"
        "Access-Control-Allow-Origin: *\r\n"
        "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        "Access-Control-Allow-Headers: Content-Type\r\n"
        "Connection: close\r\n"
        "\r\n", code, status, ctype, body_len);
    write(fd, hdr, (size_t)hlen);
    if (body_len > 0) write(fd, body, body_len);
}

static void json_ok(int fd, int ok) {
    const char *y = "{\"ok\":true}";
    const char *n = "{\"ok\":false}";
    const char *r = ok ? y : n;
    http_respond(fd, ok ? 200 : 500, "application/json", r, strlen(r));
}

static int json_int(const char *json, const char *key, int fallback) {
    if (!json) return fallback;
    char needle[64];
    snprintf(needle, sizeof(needle), "\"%s\"", key);
    const char *p = strstr(json, needle);
    if (!p) return fallback;
    p = strchr(p, ':');
    if (!p) return fallback;
    p++;
    while (*p == ' ') p++;
    return atoi(p);
}

static void json_str(const char *json, const char *key, char *out, int maxlen) {
    out[0] = '\0';
    if (!json) return;
    char needle[64];
    snprintf(needle, sizeof(needle), "\"%s\"", key);
    const char *p = strstr(json, needle);
    if (!p) return;
    p = strchr(p, ':');
    if (!p) return;
    p++;
    while (*p == ' ' || *p == '"') p++;
    int i = 0;
    while (*p && *p != '"' && *p != '}' && i < maxlen - 1) out[i++] = *p++;
    out[i] = '\0';
}

/* ── Build settings JSON ───────────────────────────────────────── */

static void handle_get_settings(int fd) {
    char json[4096];
    int pos = 0;
    pos += snprintf(json + pos, sizeof(json) - (size_t)pos, "{\"settings\":[");

    int first = 1;
    for (size_t i = 0; i < NUM_SETTINGS; i++) {
        const uvc_setting_t *s = &SETTINGS[i];
        int32_t cur = 0, mn = 0, mx = 0;
        if (uvc_get_val(UVC_GET_CUR, s->unit, s->selector, s->size, &cur) != 0) continue;
        if (uvc_get_val(UVC_GET_MIN, s->unit, s->selector, s->size, &mn) != 0) continue;
        if (uvc_get_val(UVC_GET_MAX, s->unit, s->selector, s->size, &mx) != 0) continue;
        if (mn == mx) continue;

        if (!first) pos += snprintf(json + pos, sizeof(json) - (size_t)pos, ",");
        first = 0;
        pos += snprintf(json + pos, sizeof(json) - (size_t)pos,
            "{\"name\":\"%s\",\"unit\":%d,\"selector\":%d,\"size\":%d,"
            "\"min\":%d,\"max\":%d,\"current\":%d}",
            s->name, s->unit, s->selector, s->size, mn, mx, cur);
    }

    pos += snprintf(json + pos, sizeof(json) - (size_t)pos, "]}");
    http_respond(fd, 200, "application/json", json, (size_t)pos);
}

static void handle_reset_settings(int fd) {
    int ok = 1;
    for (size_t i = 0; i < NUM_SETTINGS; i++) {
        const uvc_setting_t *s = &SETTINGS[i];
        int32_t def = 0;
        /* Try UVC GET_DEF for factory default, fall back to midpoint */
        if (uvc_get_val(UVC_GET_DEF, s->unit, s->selector, s->size, &def) != 0) {
            int32_t mn = 0, mx = 0;
            if (uvc_get_val(UVC_GET_MIN, s->unit, s->selector, s->size, &mn) != 0) continue;
            if (uvc_get_val(UVC_GET_MAX, s->unit, s->selector, s->size, &mx) != 0) continue;
            def = (mn + mx) / 2;
        }
        if (uvc_control(USBmakebmRequestType(kUSBOut, kUSBClass, kUSBInterface),
                        UVC_SET_CUR, s->unit, s->selector, &def, s->size) != 0)
            ok = 0;
    }
    json_ok(fd, ok);
}

static void handle_set_setting(int fd, const char *body) {
    char name[64];
    json_str(body, "name", name, sizeof(name));
    int value = json_int(body, "value", 0);

    for (size_t i = 0; i < NUM_SETTINGS; i++) {
        if (strcmp(SETTINGS[i].name, name) == 0) {
            int32_t v32 = (int32_t)value;
            int ret = uvc_control(
                USBmakebmRequestType(kUSBOut, kUSBClass, kUSBInterface),
                UVC_SET_CUR, SETTINGS[i].unit, SETTINGS[i].selector,
                &v32, SETTINGS[i].size);
            json_ok(fd, ret == 0);
            return;
        }
    }
    const char *err = "{\"ok\":false,\"error\":\"unknown setting\"}";
    http_respond(fd, 400, "application/json", err, strlen(err));
}

/* ── AVFoundation: enumerate camera formats ────────────────────── */

static void handle_get_formats(int fd) {
    @autoreleasepool {
        char json[32768];
        int pos = 0;
        pos += snprintf(json + pos, sizeof(json) - (size_t)pos, "{\"cameras\":[");

        AVCaptureDeviceDiscoverySession *session = [AVCaptureDeviceDiscoverySession
            discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeExternal, AVCaptureDeviceTypeBuiltInWideAngleCamera]
            mediaType:AVMediaTypeVideo
            position:AVCaptureDevicePositionUnspecified];

        int firstCam = 1;
        for (AVCaptureDevice *dev in session.devices) {
            if (!firstCam) pos += snprintf(json + pos, sizeof(json) - (size_t)pos, ",");
            firstCam = 0;

            const char *name = [dev.localizedName UTF8String];
            const char *uid = [dev.uniqueID UTF8String];
            pos += snprintf(json + pos, sizeof(json) - (size_t)pos,
                "{\"name\":\"%s\",\"id\":\"%s\",\"formats\":[", name, uid);

            /* Collect unique resolution+fps combos */
            typedef struct { int w, h; double fps; } fmt_entry;
            fmt_entry entries[512];
            int count = 0;

            for (AVCaptureDeviceFormat *fmt in dev.formats) {
                CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription);
                for (AVFrameRateRange *range in fmt.videoSupportedFrameRateRanges) {
                    double fps = range.maxFrameRate;
                    /* Deduplicate */
                    int dup = 0;
                    for (int k = 0; k < count; k++) {
                        if (entries[k].w == dims.width && entries[k].h == dims.height &&
                            (int)(entries[k].fps * 100) == (int)(fps * 100)) { dup = 1; break; }
                    }
                    if (!dup && count < 512) {
                        entries[count++] = (fmt_entry){ dims.width, dims.height, fps };
                    }
                }
            }

            /* Sort: resolution descending, fps descending */
            for (int a = 0; a < count - 1; a++) {
                for (int b = a + 1; b < count; b++) {
                    int area_a = entries[a].w * entries[a].h;
                    int area_b = entries[b].w * entries[b].h;
                    if (area_b > area_a || (area_b == area_a && entries[b].fps > entries[a].fps)) {
                        fmt_entry tmp = entries[a]; entries[a] = entries[b]; entries[b] = tmp;
                    }
                }
            }

            for (int k = 0; k < count; k++) {
                if (k > 0) pos += snprintf(json + pos, sizeof(json) - (size_t)pos, ",");
                int fps_int = (int)(entries[k].fps + 0.5);
                pos += snprintf(json + pos, sizeof(json) - (size_t)pos,
                    "[%d,%d,%d]", entries[k].w, entries[k].h, fps_int);
            }

            pos += snprintf(json + pos, sizeof(json) - (size_t)pos, "]}");
        }

        pos += snprintf(json + pos, sizeof(json) - (size_t)pos, "]}");
        http_respond(fd, 200, "application/json", json, (size_t)pos);
    }
}

/* ── HTTP request handler ──────────────────────────────────────── */

static char *g_img_data = NULL;
static size_t g_img_len = 0;

static void handle_request(int fd, const char *html, size_t html_len) {
    char buf[HTTP_BUF];
    ssize_t n = recv(fd, buf, sizeof(buf) - 1, 0);
    if (n <= 0) return;
    buf[n] = '\0';

    char method[16] = {0}, path[256] = {0};
    sscanf(buf, "%15s %255s", method, path);

    char *body = strstr(buf, "\r\n\r\n");
    if (body) body += 4;

    /* CORS preflight */
    if (strcmp(method, "OPTIONS") == 0) {
        http_respond(fd, 200, "text/plain", "", 0);
        return;
    }

    /* GET / */
    if (strcmp(method, "GET") == 0 && strcmp(path, "/") == 0) {
        http_respond(fd, 200, "text/html; charset=utf-8", html, html_len);
        return;
    }

    /* GET /tv-bg.png */
    if (strcmp(method, "GET") == 0 && strcmp(path, "/tv-bg.png") == 0 && g_img_data) {
        http_respond(fd, 200, "image/png", g_img_data, g_img_len);
        return;
    }

    /* GET /api/status */
    if (strcmp(path, "/api/status") == 0) {
        IOUSBDeviceInterface187 **dev = find_device();
        if (dev) {
            (*dev)->Release(dev);
            const char *r = "{\"connected\":true}";
            http_respond(fd, 200, "application/json", r, strlen(r));
        } else {
            const char *r = "{\"connected\":false,\"error\":\"camera not found\"}";
            http_respond(fd, 200, "application/json", r, strlen(r));
        }
        return;
    }

    /* GET /api/formats */
    if (strcmp(method, "GET") == 0 && strcmp(path, "/api/formats") == 0) {
        handle_get_formats(fd);
        return;
    }

    /* GET /api/settings */
    if (strcmp(method, "GET") == 0 && strcmp(path, "/api/settings") == 0) {
        handle_get_settings(fd);
        return;
    }

    /* POST /api/setting */
    if (strcmp(method, "POST") == 0 && strcmp(path, "/api/setting") == 0) {
        handle_set_setting(fd, body);
        return;
    }

    /* POST /api/settings/reset */
    if (strcmp(method, "POST") == 0 && strcmp(path, "/api/settings/reset") == 0) {
        handle_reset_settings(fd);
        return;
    }

    /* POST /api/ptz */
    if (strcmp(method, "POST") == 0 && strcmp(path, "/api/ptz") == 0) {
        int pan  = json_int(body, "pan", 0);
        int tilt = json_int(body, "tilt", 0);
        json_ok(fd, cmd_pantilt(pan, tilt) == 0);
        return;
    }

    /* POST /api/reset */
    if (strcmp(method, "POST") == 0 && strcmp(path, "/api/reset") == 0) {
        json_ok(fd, cmd_reset() == 0);
        return;
    }

    /* POST /api/led */
    if (strcmp(method, "POST") == 0 && strcmp(path, "/api/led") == 0) {
        char mode[16] = "auto";
        json_str(body, "mode", mode, sizeof(mode));
        json_ok(fd, cmd_led(mode) == 0);
        return;
    }

    const char *nf = "Not Found";
    http_respond(fd, 404, "text/plain", nf, strlen(nf));
}

/* ── HTTP server ───────────────────────────────────────────────── */

static int cmd_serve(const char *argv0) {
    char html_path[1024];
    const char *slash = strrchr(argv0, '/');
    if (slash) {
        size_t dir_len = (size_t)(slash - argv0);
        snprintf(html_path, sizeof(html_path), "%.*s/index.html", (int)dir_len, argv0);
    } else {
        snprintf(html_path, sizeof(html_path), "index.html");
    }

    size_t html_len = 0;
    char *html = slurp_file(html_path, &html_len);
    if (!html) {
        fprintf(stderr, "error: cannot read %s\n", html_path);
        return 1;
    }

    /* Load TV background image */
    char img_path[1024];
    if (slash) {
        snprintf(img_path, sizeof(img_path), "%.*s/tv-bg.png", (int)(slash - argv0), argv0);
    } else {
        snprintf(img_path, sizeof(img_path), "tv-bg.png");
    }
    g_img_data = slurp_file(img_path, &g_img_len);
    if (!g_img_data) fprintf(stderr, "note: tv-bg.png not found (UI will still work via file://)\n");

    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) { perror("socket"); return 1; }

    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port        = htons(HTTP_PORT);

    if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        close(server_fd);
        return 1;
    }
    listen(server_fd, 8);

    IOUSBDeviceInterface187 **dev = find_device();
    if (dev) {
        fprintf(stderr, "✓ Logitech Orbit AF detected\n");
        (*dev)->Release(dev);
    } else {
        fprintf(stderr, "⚠ Camera not found — plug it in before using PTZ\n");
    }
    fprintf(stderr, "→ Open http://localhost:%d in Chrome\n", HTTP_PORT);

    signal(SIGPIPE, SIG_IGN);

    for (;;) {
        int client = accept(server_fd, NULL, NULL);
        if (client < 0) continue;
        handle_request(client, html, html_len);
        close(client);
    }

    free(html);
    close(server_fd);
    return 0;
}

/* ── CLI entry point ───────────────────────────────────────────── */

int main(int argc, char *argv[]) {
    /* No arguments → start PTZ server */
    if (argc < 2)
        return cmd_serve(argv[0]);

    const char *cmd = argv[1];

    if (strcmp(cmd, "help") == 0 || strcmp(cmd, "--help") == 0 || strcmp(cmd, "-h") == 0) {
        fprintf(stderr,
            "usage: uvc_ctrl [command] [args...]\n\n"
            "  (no args)                       Start PTZ server (default)\n"
            "  pantilt <pan> <tilt>            Relative pan/tilt\n"
            "  reset                           Reset to center\n"
            "  led off|on|blink|auto           Control LED\n"
            "  set <unit> <sel> <size> <val>   SET_CUR\n"
            "  get <unit> <sel> <size>         GET_CUR\n"
            "  getmin <unit> <sel> <size>      GET_MIN\n"
            "  getmax <unit> <sel> <size>      GET_MAX\n"
            "  status                          Check connection\n");
        return 0;
    }

    if (strcmp(cmd, "serve") == 0)
        return cmd_serve(argv[0]);
    if (strcmp(cmd, "pantilt") == 0 && argc == 4)
        return cmd_pantilt(atoi(argv[2]), atoi(argv[3]));
    if (strcmp(cmd, "reset") == 0)
        return cmd_reset();
    if (strcmp(cmd, "led") == 0 && argc == 3)
        return cmd_led(argv[2]);
    if (strcmp(cmd, "set") == 0 && argc == 6)
        return cmd_set(atoi(argv[2]), atoi(argv[3]), atoi(argv[4]), atol(argv[5]));
    if (strcmp(cmd, "get") == 0 && argc == 5)
        return cmd_get(UVC_GET_CUR, atoi(argv[2]), atoi(argv[3]), atoi(argv[4]));
    if (strcmp(cmd, "getmin") == 0 && argc == 5)
        return cmd_get(UVC_GET_MIN, atoi(argv[2]), atoi(argv[3]), atoi(argv[4]));
    if (strcmp(cmd, "getmax") == 0 && argc == 5)
        return cmd_get(UVC_GET_MAX, atoi(argv[2]), atoi(argv[3]), atoi(argv[4]));
    if (strcmp(cmd, "getdef") == 0 && argc == 5)
        return cmd_get(UVC_GET_DEF, atoi(argv[2]), atoi(argv[3]), atoi(argv[4]));
    if (strcmp(cmd, "status") == 0)
        return (find_device() ? (printf("connected\n"), 0) : 1);

    fprintf(stderr, "error: unknown command: %s\n", cmd);
    return 1;
}
