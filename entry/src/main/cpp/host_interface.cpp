/*
 * host_interface.cpp
 *
 * Host-side bridge between the 8086tiny core and OpenHarmony:
 *  - ANSI terminal emulator for 80x25 text mode (renders to BGRA)
 *  - RGB332 -> BGRA conversion for CGA/Hercules graphics mode
 *  - Keyboard queue (XT scancodes injected from the ArkTS layer)
 *  - Emulator thread + pause/resume/reset/stop control
 *  - Frame buffer + sequence counter shared with the NAPI bridge
 */
#include "host_interface.h"
#include "third_party/8086tiny/font8x8_cp437.h"

#include <thread>
#include <mutex>
#include <atomic>
#include <vector>
#include <cstring>
#include <ctime>
#include <unistd.h>

#define TEXT_COLS 80
#define TEXT_ROWS 25
#define FONT_W 8
#define FONT_H 8

/* ------------------------------------------------------------------ */
/* Terminal emulator (text mode)                                       */
/* ------------------------------------------------------------------ */

struct Cell {
    unsigned char ch;
    unsigned char fg;   // 0..15
    unsigned char bg;   // 0..7
};

/* Standard CGA/VGA 16-color palette (RGB). */
static const unsigned char PAL[16][3] = {
    {0,   0,   0},   /* 0  black        */
    {0,   0,   170}, /* 1  blue         */
    {0,   170, 0},   /* 2  green        */
    {0,   170, 170}, /* 3  cyan         */
    {170, 0,   0},   /* 4  red          */
    {170, 0,   170}, /* 5  magenta      */
    {170, 85,  0},   /* 6  brown/yellow */
    {170, 170, 170}, /* 7  white        */
    {85,  85,  85},  /* 8  bright black */
    {85,  85,  255}, /* 9  bright blue  */
    {85,  255, 85},  /* 10 bright green */
    {85,  255, 255}, /* 11 bright cyan  */
    {255, 85,  85},  /* 12 bright red   */
    {255, 85,  255}, /* 13 bright mag.  */
    {255, 255, 85},  /* 14 bright brown */
    {255, 255, 255}  /* 15 bright white */
};

class Terminal {
public:
    Cell grid[TEXT_COLS * TEXT_ROWS];
    int curX;
    int curY;
    int scrollTop;
    int scrollBottom;
    unsigned char fg;
    unsigned char bg;
    bool bright;
    bool cursorVisible;

    /* ANSI parser state */
    int pstate;         // 0 normal, 1 after ESC, 2 in CSI
    bool pprivate;      // seen '?'
    std::vector<int> params;
    int curParam;
    bool haveParam;

    Terminal() { reset(); }

    void reset() {
        for (int i = 0; i < TEXT_COLS * TEXT_ROWS; i++) {
            grid[i].ch = ' ';
            grid[i].fg = 7;
            grid[i].bg = 0;
        }
        curX = 0;
        curY = 0;
        scrollTop = 0;
        scrollBottom = TEXT_ROWS - 1;
        fg = 7;
        bg = 0;
        bright = false;
        cursorVisible = true;
        pstate = 0;
        pprivate = false;
        params.clear();
        curParam = 0;
        haveParam = false;
    }

    Cell &cellAt(int x, int y) { return grid[y * TEXT_COLS + x]; }

    void feed(unsigned char c);

private:
    void scrollUp(int n);
    void scrollDown(int n);
    void carriageReturn();
    void lineFeed();
    void backspace();
    void putChar(unsigned char c);
    void advanceCol();
    void applySgr();
    void executeCsi(char cmd);
    void setCursor(int row, int col);   // 1-based as received
};

void Terminal::setCursor(int row, int col) {
    int r = (row <= 0) ? 0 : row - 1;
    int c = (col <= 0) ? 0 : col - 1;
    if (r >= TEXT_ROWS) r = TEXT_ROWS - 1;
    if (c >= TEXT_COLS) c = TEXT_COLS - 1;
    curY = r;
    curX = c;
}

void Terminal::advanceCol() {
    curX++;
    if (curX >= TEXT_COLS) {
        curX = 0;
        curY++;
        if (curY > scrollBottom) {
            curY = scrollBottom;
            scrollUp(1);
        }
    }
}

void Terminal::putChar(unsigned char c) {
    Cell &cell = cellAt(curX, curY);
    cell.ch = c;
    cell.fg = fg;
    cell.bg = bg;
    advanceCol();
}

void Terminal::carriageReturn() { curX = 0; }

void Terminal::lineFeed() {
    curY++;
    if (curY > scrollBottom) {
        curY = scrollBottom;
        scrollUp(1);
    }
}

void Terminal::backspace() {
    if (curX > 0) curX--;
}

void Terminal::scrollUp(int n) {
    for (int k = 0; k < n; k++) {
        for (int y = scrollTop; y < scrollBottom; y++) {
            for (int x = 0; x < TEXT_COLS; x++)
                cellAt(x, y) = cellAt(x, y + 1);
        }
        for (int x = 0; x < TEXT_COLS; x++) {
            Cell &c = cellAt(x, scrollBottom);
            c.ch = ' ';
            c.fg = fg;
            c.bg = bg;
        }
    }
}

void Terminal::scrollDown(int n) {
    for (int k = 0; k < n; k++) {
        for (int y = scrollBottom; y > scrollTop; y--) {
            for (int x = 0; x < TEXT_COLS; x++)
                cellAt(x, y) = cellAt(x, y - 1);
        }
        for (int x = 0; x < TEXT_COLS; x++) {
            Cell &c = cellAt(x, scrollTop);
            c.ch = ' ';
            c.fg = fg;
            c.bg = bg;
        }
    }
}

void Terminal::applySgr() {
    if (params.empty()) {
        fg = 7; bg = 0; bright = false;
        return;
    }
    for (size_t i = 0; i < params.size(); i++) {
        int p = params[i];
        if (p == 0) { fg = 7; bg = 0; bright = false; }
        else if (p == 1) { bright = true; }
        else if (p >= 30 && p <= 37) { fg = (unsigned char)(p - 30 + (bright ? 8 : 0)); }
        else if (p >= 40 && p <= 47) { bg = (unsigned char)(p - 40); }
    }
}

void Terminal::executeCsi(char cmd) {
    int p0 = params.empty() ? 1 : params[0];
    int p1 = params.size() > 1 ? params[1] : 1;
    switch (cmd) {
        case 'H': /* CUP */
            setCursor(p0, p1);
            break;
        case 'm':
            applySgr();
            break;
        case 'J':
            if (p0 == 2) {
                for (int i = 0; i < TEXT_COLS * TEXT_ROWS; i++) {
                    grid[i].ch = ' ';
                    grid[i].fg = fg;
                    grid[i].bg = bg;
                }
            }
            break;
        case 'r':
            if (params.empty()) { scrollTop = 0; scrollBottom = TEXT_ROWS - 1; }
            else {
                int t = p0 <= 0 ? 0 : p0 - 1;
                int b = p1 <= 0 ? 0 : p1 - 1;
                if (t < 0) t = 0;
                if (b >= TEXT_ROWS) b = TEXT_ROWS - 1;
                if (t <= b) { scrollTop = t; scrollBottom = b; }
            }
            break;
        case 'S':
            scrollUp(p0);
            break;
        case 'T':
            scrollDown(p0);
            break;
        case 'M':
            scrollUp(1);
            break;
        case 'D':
            scrollDown(1);
            break;
        case 'h':
            if (pprivate && p0 == 25) cursorVisible = true;
            break;
        case 'l':
            if (pprivate && p0 == 25) cursorVisible = false;
            break;
        default:
            break;
    }
}

void Terminal::feed(unsigned char c) {
    switch (pstate) {
        case 0: /* normal */
            if (c == 0x1B) { pstate = 1; }
            else if (c == '\n') { lineFeed(); }
            else if (c == '\r') { carriageReturn(); }
            else if (c == '\b') { backspace(); }
            else if (c >= 0x20) { putChar(c); }
            break;
        case 1: /* after ESC */
            if (c == '[') {
                pstate = 2;
                pprivate = false;
                params.clear();
                curParam = 0;
                haveParam = false;
            } else {
                pstate = 0;
            }
            break;
        case 2: /* in CSI */
            if (c >= '0' && c <= '9') {
                curParam = curParam * 10 + (c - '0');
                haveParam = true;
            } else if (c == ';') {
                params.push_back(curParam);
                curParam = 0;
                haveParam = false;
            } else if (c == '?') {
                pprivate = true;
            } else {
                if (haveParam) params.push_back(curParam);
                executeCsi((char)c);
                pstate = 0;
            }
            break;
    }
}

/* ------------------------------------------------------------------ */
/* Shared state (emulator thread <-> NAPI bridge <-> audio thread)     */
/* ------------------------------------------------------------------ */

static Terminal g_term;
static std::mutex g_mtx;

static std::vector<unsigned char> g_frame_bgra;
static int g_frame_w = TEXT_COLS * FONT_W;
static int g_frame_h = TEXT_ROWS * FONT_H;
static int g_frame_mode = HOST_VIDEO_TEXT;
static unsigned int g_seq = 0;
static bool g_frame_dirty = true;

static std::atomic<bool> g_running(false);
static std::atomic<bool> g_paused(false);
static std::atomic<bool> g_stop_requested(false);
static std::atomic<bool> g_reset_requested(false);

static std::string g_bios_path;
static std::string g_floppy_path;
static std::thread g_emu_thread;

/* Speed governor state (reset on start/reset). */
static uint64_t g_pace_insts = 0;
static struct timespec g_pace_start = { 0, 0 };

/* Keyboard queue (ring buffer of 16-bit XT key values). */
#define KEY_QUEUE_SIZE 256
static unsigned short g_key_queue[KEY_QUEUE_SIZE];
static int g_key_head = 0;
static int g_key_tail = 0;

/* ------------------------------------------------------------------ */
/* Rendering helpers                                                   */
/* ------------------------------------------------------------------ */

static void renderTextFrame() {
    int w = TEXT_COLS * FONT_W;
    int h = TEXT_ROWS * FONT_H;
    g_frame_bgra.resize((size_t)w * h * 4);
    unsigned char *dst = g_frame_bgra.data();

    // Primary source: the ANSI terminal grid fed by host_putchar(). The
    // 8086tiny BIOS routes console output (BIOS INT 10h teletype) through a
    // special opcode into this terminal; FreeDOS never touches the CGA
    // framebuffer directly, so B800:0 stays zero while the real boot text
    // lives here.
    unsigned char *vram = host_text_framebuffer();

    for (int y = 0; y < TEXT_ROWS; y++) {
        for (int x = 0; x < TEXT_COLS; x++) {
            Cell &tc = g_term.cellAt(x, y);
            unsigned char ch = tc.ch;
            unsigned char fg = tc.fg;
            unsigned char bg = tc.bg;

            // Secondary source: software that writes B800:0 directly (bypassing
            // the BIOS teletype path). Overlay its cell only where the terminal
            // grid is still blank so BIOS-driven console output wins.
            int idx = (y * TEXT_COLS + x) * 2;
            unsigned char vch = vram[idx];
            unsigned char attr = vram[idx + 1];
            if (ch == ' ' && vch != 0 && vch != ' ') {
                ch = vch;
                fg = attr & 0x0F;
                bg = (attr >> 4) & 0x07;
            }

            bool isCursor = g_term.cursorVisible && (x == g_term.curX) && (y == g_term.curY);
            const unsigned char *fgc = PAL[fg & 15];
            const unsigned char *bgc = PAL[bg & 7];
            if (isCursor) {
                const unsigned char *t = fgc; fgc = bgc; bgc = t;
            }
            const unsigned char *glyph = font8x8_cp437[ch];
            for (int fy = 0; fy < FONT_H; fy++) {
                unsigned char rowbits = glyph[fy];
                for (int fx = 0; fx < FONT_W; fx++) {
                    bool on = (rowbits >> (7 - fx)) & 1;
                    const unsigned char *col = on ? fgc : bgc;
                    int px = x * FONT_W + fx;
                    int py = y * FONT_H + fy;
                    unsigned char *p = dst + ((size_t)py * w + px) * 4;
                    p[0] = col[2]; /* B */
                    p[1] = col[1]; /* G */
                    p[2] = col[0]; /* R */
                    p[3] = 255;    /* A */
                }
            }
        }
    }
}

static void renderGraphicsFrame(const unsigned char *rgb332, int w, int h) {
    g_frame_bgra.resize((size_t)w * h * 4);
    unsigned char *dst = g_frame_bgra.data();
    for (int i = 0; i < w * h; i++) {
        unsigned char c = rgb332[i];
        unsigned char r = (c >> 5) & 7;
        unsigned char g = (c >> 2) & 7;
        unsigned char b = c & 7;
        dst[i * 4 + 0] = (unsigned char)(b * 255 / 7);
        dst[i * 4 + 1] = (unsigned char)(g * 255 / 7);
        dst[i * 4 + 2] = (unsigned char)(r * 255 / 7);
        dst[i * 4 + 3] = 255;
    }
}

/* ------------------------------------------------------------------ */
/* Core -> host callbacks (called from the emulator thread)            */
/* ------------------------------------------------------------------ */

extern "C" void host_putchar(unsigned char ch) {
    std::lock_guard<std::mutex> lock(g_mtx);
    g_term.feed(ch);
    g_frame_dirty = true;
}

extern "C" void host_text_dirty(void) {
    std::lock_guard<std::mutex> lock(g_mtx);
    g_frame_dirty = true;
}

extern "C" int host_keyboard_poll(unsigned short *target) {
    std::lock_guard<std::mutex> lock(g_mtx);
    if (g_key_head == g_key_tail)
        return 0;
    *target = g_key_queue[g_key_head];
    g_key_head = (g_key_head + 1) % KEY_QUEUE_SIZE;
    return 1;
}

extern "C" void host_video_frame(const unsigned char *gfx8, int w, int h) {
    std::lock_guard<std::mutex> lock(g_mtx);
    renderGraphicsFrame(gfx8, w, h);
    g_frame_w = w;
    g_frame_h = h;
    g_frame_mode = HOST_VIDEO_GRAPHICS;
    g_frame_dirty = false;
    g_seq++;
}

/* Clear the text screen when a reset is processed, so a reboot starts on a
 * clean display (the terminal grid would otherwise accumulate boot banners). */
static void clearTerminalForReset() {
    std::lock_guard<std::mutex> lock(g_mtx);
    g_term.reset();
    g_frame_dirty = true;
}

extern "C" int host_control(void) {
    if (g_stop_requested.load(std::memory_order_acquire))
        return HOST_CTL_STOP;
    if (g_reset_requested.exchange(false, std::memory_order_acq_rel)) {
        clearTerminalForReset();
        return HOST_CTL_RESET;
    }
    while (g_paused.load(std::memory_order_acquire)) {
        /* A reset requested while paused must still be honoured: unpause and
         * take the reset; otherwise the machine stays frozen forever. */
        if (g_reset_requested.exchange(false, std::memory_order_acq_rel)) {
            g_paused.store(false, std::memory_order_release);
            clearTerminalForReset();
            return HOST_CTL_RESET;
        }
        usleep(1000);
        if (g_stop_requested.load(std::memory_order_acquire))
            return HOST_CTL_STOP;
    }

    /* Speed governor: 8086tiny paces the emulated PIT timer by instruction
     * count (one INT 8 every 20000 instructions ~= 55ms), so a real-time
     * target is ~360k instructions/second. Without throttling, a modern ARM
     * core runs this tight loop orders of magnitude too fast and pegs a CPU.
     * We sleep in small windows to hold that ~360k-400k IPS rate. */
    g_pace_insts++;
    if ((g_pace_insts & 0x1FFF) == 0) { /* every 8192 instructions */
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        double elapsed =
            (double)(now.tv_sec - g_pace_start.tv_sec) +
            (double)(now.tv_nsec - g_pace_start.tv_nsec) / 1e9;
        const double target = 8192.0 / 400000.0; /* seconds per window */
        double remain = target - elapsed;
        if (remain > 0.0) {
            usleep((useconds_t)(remain * 1e6));
        }
        clock_gettime(CLOCK_MONOTONIC, &g_pace_start);
    }
    return HOST_CTL_CONTINUE;
}

/* ------------------------------------------------------------------ */
/* Emulator thread entry                                               */
/* ------------------------------------------------------------------ */

static void emulatorThreadMain() {
    emulator_run(g_bios_path.c_str(), g_floppy_path.c_str(), nullptr);
}

/* ------------------------------------------------------------------ */
/* Host lifecycle (called from the NAPI bridge / JS thread)            */
/* ------------------------------------------------------------------ */

extern "C" int host_init(const char *bios_path) {
    std::lock_guard<std::mutex> lock(g_mtx);
    g_bios_path = bios_path ? bios_path : "";
    g_term.reset();
    g_frame_mode = HOST_VIDEO_TEXT;
    g_frame_w = TEXT_COLS * FONT_W;
    g_frame_h = TEXT_ROWS * FONT_H;
    g_frame_dirty = true;
    g_seq = 0;
    g_key_head = g_key_tail = 0;
    return 0;
}

extern "C" void host_shutdown(void) {
    g_stop_requested.store(true, std::memory_order_release);
    if (g_emu_thread.joinable())
        g_emu_thread.join();
}

extern "C" int host_start(const char *floppy_path) {
    if (g_running.load(std::memory_order_acquire))
        return 0;
    {
        std::lock_guard<std::mutex> lock(g_mtx);
        g_floppy_path = floppy_path ? floppy_path : "";
    }
    g_stop_requested.store(false, std::memory_order_release);
    g_reset_requested.store(false, std::memory_order_release);
    g_paused.store(false, std::memory_order_release);
    g_running.store(true, std::memory_order_release);
    g_pace_insts = 0;
    clock_gettime(CLOCK_MONOTONIC, &g_pace_start);
    g_emu_thread = std::thread(emulatorThreadMain);
    return 0;
}

extern "C" void host_stop(void) {
    if (!g_running.load(std::memory_order_acquire))
        return;
    g_stop_requested.store(true, std::memory_order_release);
    if (g_emu_thread.joinable())
        g_emu_thread.join();
    g_running.store(false, std::memory_order_release);
    g_paused.store(false, std::memory_order_release);
}

extern "C" void host_reset(void) {
    g_pace_insts = 0;
    clock_gettime(CLOCK_MONOTONIC, &g_pace_start);
    g_reset_requested.store(true, std::memory_order_release);
    /* A reset is a restart: clear any pause so the emulator thread picks the
     * request up immediately instead of blocking in the paused loop. */
    g_paused.store(false, std::memory_order_release);
}

extern "C" void host_pause(void) {
    g_paused.store(true, std::memory_order_release);
}

extern "C" void host_resume(void) {
    g_paused.store(false, std::memory_order_release);
}

extern "C" void host_inject_key(unsigned int value) {
    std::lock_guard<std::mutex> lock(g_mtx);
    int next = (g_key_tail + 1) % KEY_QUEUE_SIZE;
    if (next == g_key_head)
        return; /* queue full */
    g_key_queue[g_key_tail] = (unsigned short)value;
    g_key_tail = next;
}

extern "C" int host_get_frame(unsigned char *dst, int dst_capacity,
                              int *w, int *h, int *mode, unsigned int *seq) {
    std::lock_guard<std::mutex> lock(g_mtx);
    if (g_frame_dirty) {
        if (g_frame_mode == HOST_VIDEO_TEXT) {
            renderTextFrame();
        }
        g_frame_dirty = false;
        g_seq++;
    }
    int bytes = (int)g_frame_bgra.size();
    if (bytes > dst_capacity) {
        *w = 0; *h = 0;
        return -1;
    }
    memcpy(dst, g_frame_bgra.data(), (size_t)bytes);
    *w = g_frame_w;
    *h = g_frame_h;
    *mode = g_frame_mode;
    *seq = g_seq;
    return 0;
}

extern "C" void host_get_status(int *running, int *paused) {
    *running = g_running.load(std::memory_order_acquire) ? 1 : 0;
    *paused = g_paused.load(std::memory_order_acquire) ? 1 : 0;
}
