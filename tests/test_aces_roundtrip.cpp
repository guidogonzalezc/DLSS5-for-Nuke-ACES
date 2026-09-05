// Standalone verification for src/AcesColor.h.
//
// The whole promise of the ACES pipeline is "DLSS may change the picture, the
// color pipeline may not". This test checks that promise numerically: it runs
// values through forward() and inverse() with no neural pass in between and
// asserts the result comes back unchanged.
//
// It needs no Nuke NDK, no GPU and no NVIDIA runtime.
//
//   cl /EHsc /O2 /std:c++17 /I..\src tests\test_aces_roundtrip.cpp
//   g++ -O2 -std=c++17 -I src tests/test_aces_roundtrip.cpp -o test_aces
//
// or just: tests/run_tests.ps1

#include "AcesColor.h"

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <vector>
#include <string>
#include <cmath>

using namespace aces;

static int g_failures = 0;
static int g_checks   = 0;

static void report(bool ok, const std::string& what, const std::string& detail = "") {
    ++g_checks;
    if (ok) {
        std::printf("  [ ok ] %s\n", what.c_str());
    } else {
        ++g_failures;
        std::printf("  [FAIL] %s%s%s\n", what.c_str(),
                    detail.empty() ? "" : " -- ", detail.c_str());
    }
}

static bool close(float a, float b, float absTol, float relTol) {
    const float d = std::fabs(a - b);
    return d <= absTol || d <= relTol * std::max(std::fabs(a), std::fabs(b));
}

// ---------------------------------------------------------------------------
// The half-float conversion used by the IPC transport, copied from
// src/DLSS5Live.cpp so the test measures the real precision of the pipe.
// ---------------------------------------------------------------------------

static uint16_t floatToHalf(float f) {
    uint32_t x;
    std::memcpy(&x, &f, 4);
    const uint32_t sign = (x >> 16) & 0x8000;
    const int32_t  exp  = ((x >> 23) & 0xff) - 127;
    uint32_t mant = x & 0x7fffff;

    if (exp > 15) return (uint16_t)(sign | 0x7c00);
    if (exp < -14) {
        if (exp < -24) return (uint16_t)sign;
        mant |= 0x800000;
        return (uint16_t)(sign | (mant >> (-exp - 14 + 13)));
    }
    return (uint16_t)(sign | ((exp + 15) << 10) | (mant >> 13));
}

static float halfToFloat(uint16_t h) {
    const uint32_t sign = (h >> 15) & 1;
    const uint32_t expo = (h >> 10) & 0x1f;
    const uint32_t mant = h & 0x3ff;
    uint32_t bits;
    if (expo == 0) {
        if (mant == 0) {
            bits = sign << 31;
        } else {
            int e = -1;
            uint32_t m = mant;
            do { ++e; m <<= 1; } while ((m & 0x400) == 0);
            m &= 0x3ff;
            bits = (sign << 31) | ((127 - 15 - e) << 23) | (m << 13);
        }
    } else if (expo == 0x1f) {
        bits = (sign << 31) | 0x7f800000u | (mant << 13);
    } else {
        bits = (sign << 31) | ((expo + 112) << 23) | (mant << 13);
    }
    float v;
    std::memcpy(&v, &bits, sizeof(v));
    return v;
}

// ---------------------------------------------------------------------------
// Test data: a spread of ACEScg values that a real ACES render actually
// produces, including the awkward ones.
// ---------------------------------------------------------------------------

struct RGB { float r, g, b; };

// Colour error relative to the pixel's own magnitude.
//
// Per-channel relative error is the wrong yardstick here: inside a bright
// saturated pixel like (2.5, 0.02, 0.02) a 0.001 absolute drift in the blue
// channel is invisible, yet scores as 5% against 0.02. What matters is the
// error as a fraction of how bright the pixel is, which is what a colourist
// would actually see.
static float pixelError(const RGB& want, float r, float g, float b) {
    const float mag = std::max({std::fabs(want.r), std::fabs(want.g), std::fabs(want.b), 1e-3f});
    return std::max({std::fabs(r - want.r), std::fabs(g - want.g), std::fabs(b - want.b)}) / mag;
}

static std::vector<RGB> sceneSamples() {
    return {
        {0.0f,      0.0f,      0.0f     },   // pure black
        {0.18f,     0.18f,     0.18f    },   // 18% mid grey
        {1.0f,      1.0f,      1.0f     },   // diffuse white
        {0.5f,      0.25f,     0.1f     },
        {0.02f,     0.03f,     0.05f    },   // deep shadow
        {0.0001f,   0.0002f,   0.00005f },   // near-black noise floor
        {4.0f,      3.5f,      3.0f     },   // practical light
        {12.0f,     11.0f,     9.0f     },   // window blow-out
        {60.0f,     55.0f,     40.0f    },   // fire
        {0.9f,      0.05f,     0.02f    },   // saturated red
        {0.05f,     0.9f,      0.05f    },   // saturated green (goes negative in 709)
        {0.02f,     0.05f,     0.95f    },   // saturated blue
        {0.75f,     0.6f,      0.45f    },   // caucasian skin
        {0.32f,     0.19f,     0.13f    },   // darker skin
        {-0.01f,    0.4f,      0.6f     },   // already-negative AP1 component
        {2.5f,      0.02f,     0.02f    },   // bright saturated red (laser / neon)
    };
}

// ---------------------------------------------------------------------------
// 1. Derived matrices must equal the published ACES matrices
// ---------------------------------------------------------------------------

static void testMatrices() {
    std::printf("\n[1] Colour matrices derived from chromaticities\n");

    const Mat3 ap1_709 = primariesMatrix(kAP1, kRec709);
    const float expect_ap1[9] = {
         1.7050516f, -0.6217908f, -0.0832588f,
        -0.1302564f,  1.1408047f, -0.0105483f,
        -0.0240034f, -0.1289690f,  1.1529723f
    };
    bool ok = true;
    for (int i = 0; i < 9; ++i) ok = ok && close(ap1_709.m[i], expect_ap1[i], 2e-5f, 1e-4f);
    char buf[256];
    std::snprintf(buf, sizeof(buf), "got %.7f %.7f %.7f", ap1_709.m[0], ap1_709.m[1], ap1_709.m[2]);
    report(ok, "ACEScg (AP1) -> linear Rec.709 matches the ACES 1.x matrix", buf);

    const Mat3 ap0_709 = primariesMatrix(kAP0, kRec709);
    const float expect_ap0[9] = {
         2.5216862f, -1.1341310f, -0.3875552f,
        -0.2764799f,  1.3727191f, -0.0962392f,
        -0.0153781f, -0.1529753f,  1.1683534f
    };
    ok = true;
    for (int i = 0; i < 9; ++i) ok = ok && close(ap0_709.m[i], expect_ap0[i], 2e-5f, 1e-4f);
    report(ok, "ACES2065-1 (AP0) -> linear Rec.709 matches the ACES 1.x matrix");

    // Round trip through the inverse.
    const Mat3 back = invert(ap1_709);
    const Mat3 id   = mul(ap1_709, back);
    ok = true;
    for (int i = 0; i < 9; ++i) {
        const float want = (i % 4 == 0) ? 1.0f : 0.0f;
        ok = ok && close(id.m[i], want, 1e-5f, 1e-5f);
    }
    report(ok, "M * M^-1 == identity");

    // Rec.709 -> Rec.709 must be an exact no-op, not a near-identity.
    const Mat3 noop = primariesMatrix(kRec709, kRec709);
    ok = true;
    for (int i = 0; i < 9; ++i) {
        const float want = (i % 4 == 0) ? 1.0f : 0.0f;
        ok = ok && close(noop.m[i], want, 1e-6f, 1e-6f);
    }
    report(ok, "Rec.709 -> Rec.709 is the identity");
}

// ---------------------------------------------------------------------------
// 2. Individual transfer functions and curves
// ---------------------------------------------------------------------------

static void testCurves() {
    std::printf("\n[2] Transfer functions and tone curves\n");

    bool ok = true;
    float worst = 0.0f;
    for (float x = -4.0f; x <= 4.0f; x += 0.013f) {
        const float a = srgbDecode(srgbEncode(x));
        const float b = rec709Decode(rec709Encode(x));
        const float c = gamma22Decode(gamma22Encode(x));
        worst = std::max(worst, std::fabs(a - x));
        worst = std::max(worst, std::fabs(b - x));
        worst = std::max(worst, std::fabs(c - x));
        ok = ok && close(a, x, 1e-5f, 1e-5f) && close(b, x, 1e-5f, 1e-5f) && close(c, x, 1e-5f, 1e-5f);
    }
    char buf[128];
    std::snprintf(buf, sizeof(buf), "worst abs error %.3e", worst);
    report(ok, "sRGB / Rec.709 / gamma 2.2 invert exactly, including negatives", buf);

    ok = true;
    worst = 0.0f;
    for (float e = -14.0f; e <= 16.0f; e += 0.1f) {
        const float x = std::pow(2.0f, e);
        const float a = acesCctDecode(acesCctEncode(x));
        worst = std::max(worst, std::fabs(a - x) / x);
        ok = ok && close(a, x, 1e-6f, 2e-5f);
    }
    std::snprintf(buf, sizeof(buf), "worst rel error %.3e over 2^-14..2^16", worst);
    report(ok, "ACEScct inverts across the full log range", buf);

    // Extended Reinhard: W must land exactly on 1.0, and the curve must be
    // strictly increasing (otherwise the inverse is ambiguous).
    for (float W : {2.0f, 4.0f, 16.0f, 100.0f}) {
        const float atW = reinhardEncode(W, W);
        std::snprintf(buf, sizeof(buf), "W=%.1f -> %.7f", W, atW);
        report(close(atW, 1.0f, 1e-6f, 1e-6f), "extended Reinhard maps the white point to exactly 1.0", buf);
    }

    ok = true;
    float prev = -1e30f;
    for (float x = 0.0f; x <= 200.0f; x += 0.05f) {
        const float y = reinhardEncode(x, 16.0f);
        ok = ok && (y > prev);
        prev = y;
    }
    report(ok, "extended Reinhard is strictly increasing on [0, 200]");

    ok = true;
    worst = 0.0f;
    for (float x = 0.0f; x <= 200.0f; x += 0.017f) {
        const float a = reinhardDecode(reinhardEncode(x, 16.0f), 16.0f);
        worst = std::max(worst, std::fabs(a - x) / std::max(x, 1e-3f));
        ok = ok && close(a, x, 1e-4f, 5e-5f);
    }
    std::snprintf(buf, sizeof(buf), "worst rel error %.3e", worst);
    report(ok, "extended Reinhard inverts on [0, 200]", buf);

    ok = true;
    worst = 0.0f;
    for (float W : {1.0f, 16.0f, 128.0f}) {
        for (float x = 0.0f; x <= W; x += W / 400.0f) {
            const float a = filmicDecode(filmicEncode(x, W), W);
            worst = std::max(worst, std::fabs(a - x) / std::max(W, 1e-3f));
            ok = ok && close(a, x, 2e-4f * W, 5e-4f);
        }
    }
    std::snprintf(buf, sizeof(buf), "worst error %.3e of the white point", worst);
    report(ok, "Narkowicz ACES fit inverts on [0, W] once scaled by the white point", buf);

    // f(W) must sit just under 1.0 so the frame maximum lands at the top of the
    // encoded range rather than clipping.
    for (float W : {1.0f, 16.0f, 128.0f}) {
        const float atW = filmicEncode(W, W);
        std::snprintf(buf, sizeof(buf), "W=%.1f -> %.5f", W, atW);
        report(atW > 0.98f && atW <= 1.0f, "Narkowicz fit maps the white point just below 1.0", buf);
    }

    // Gamut compression must be reversible for the distances it actually
    // produces.
    ok = true;
    worst = 0.0f;
    GamutCompressParams gp;
    for (float d = 0.0f; d <= 2.5f; d += 0.001f) {
        const float c = gcCompress(d, gp.limit_m, gp.threshold, gp.power);
        const float u = gcUncompress(c, gp.limit_m, gp.threshold, gp.power);
        if (d <= gp.limit_m) {
            worst = std::max(worst, std::fabs(u - d));
            ok = ok && close(u, d, 2e-3f, 2e-3f);
        }
    }
    std::snprintf(buf, sizeof(buf), "worst abs error %.3e up to the limit", worst);
    report(ok, "ACES reference gamut compression inverts inside its limit", buf);
}

// ---------------------------------------------------------------------------
// 3. Full pipeline round trip, every combination of knobs
// ---------------------------------------------------------------------------

static const char* kSpaceNames[]  = { "ACEScg", "ACES2065-1", "ACEScct", "ACEScc", "Linear Rec.709", "Linear P3-D65" };
static const char* kEncNames[]    = { "sRGB", "Rec.709", "Gamma 2.2", "ACEScct", "Linear" };
static const char* kTmNames[]     = { "Reinhard", "ACES Filmic", "None" };

static void testFullRoundTrip() {
    std::printf("\n[3] Full pipeline round trip (no neural pass in between)\n");

    const std::vector<RGB> samples = sceneSamples();

    for (int enc = 0; enc < ENC_COUNT; ++enc) {
        for (int tm = 0; tm < TM_COUNT; ++tm) {
            // The Narkowicz fit is only defined up to ~6.5; the pipeline pre-
            // scales into that range with exposure, so test it that way.
            if (tm == TM_ACES_FILMIC && enc == ENC_ACESCCT) continue;   // tone curve unused

            Params p;
            p.enabled        = true;
            p.working_space  = WS_ACESCG;
            p.encoding       = enc;
            p.tonemap        = tm;
            p.gamut_compress = true;
            p.exposure_stops = 0.0f;
            p.white_point    = 128.0f;

            Transform t(p);

            bool ok = true;
            float worst = 0.0f;
            RGB worstSample{};
            for (const RGB& s : samples) {
                float r = s.r, g = s.g, b = s.b;
                t.forward(r, g, b);
                t.inverse(r, g, b);
                const float e = pixelError(s, r, g, b);
                if (e > worst) { worst = e; worstSample = s; }
                ok = ok && (e < 2e-3f);
            }

            char name[192], detail[192];
            std::snprintf(name, sizeof(name), "encoding=%-9s tonemap=%-11s", kEncNames[enc], kTmNames[tm]);
            std::snprintf(detail, sizeof(detail), "worst rel error %.3e at (%.4g, %.4g, %.4g)",
                          worst, worstSample.r, worstSample.g, worstSample.b);
            report(ok, name, detail);
        }
    }

    std::printf("\n    working spaces, with the recommended sRGB / Reinhard settings\n");
    for (int ws = 0; ws < WS_COUNT; ++ws) {
        Params p;
        p.working_space = ws;
        p.encoding      = ENC_SRGB;
        p.tonemap       = TM_REINHARD;
        p.white_point   = 128.0f;
        Transform t(p);

        bool ok = true;
        float worst = 0.0f;
        for (const RGB& s0 : samples) {
            // Log working spaces receive log-encoded pixels, so encode first.
            RGB s = s0;
            if (ws == WS_ACESCCT) { s = { acesCctEncode(std::max(s0.r, 0.0f)), acesCctEncode(std::max(s0.g, 0.0f)), acesCctEncode(std::max(s0.b, 0.0f)) }; }
            if (ws == WS_ACESCC)  { s = { acesCcEncode(std::max(s0.r, 0.0f)),  acesCcEncode(std::max(s0.g, 0.0f)),  acesCcEncode(std::max(s0.b, 0.0f)) }; }

            float r = s.r, g = s.g, b = s.b;
            t.forward(r, g, b);
            t.inverse(r, g, b);
            const float e = pixelError(s, r, g, b);
            worst = std::max(worst, e);
            ok = ok && (e < 2e-3f);
        }
        char name[160], detail[96];
        std::snprintf(name, sizeof(name), "working space = %-15s", kSpaceNames[ws]);
        std::snprintf(detail, sizeof(detail), "worst rel error %.3e", worst);
        report(ok, name, detail);
    }
}

// ---------------------------------------------------------------------------
// 4. Round trip through the real fp16 IPC transport
// ---------------------------------------------------------------------------

static void testHalfTransport() {
    std::printf("\n[4] Round trip through the RGBA16F transport (the real path)\n");

    const std::vector<RGB> samples = sceneSamples();

    // A display encoding spends its fp16 mantissa evenly across 0..1, but the
    // tone curve packs everything from the white point upwards into the last
    // sliver of that range. So the higher the white point, the coarser the
    // highlights come back. These bounds are measured, not aspirational: they
    // exist to catch a regression, and the numbers they print are the honest
    // cost of each setting. ACEScct is log, so its precision is flat.
    struct Case { int enc; int tm; float white; float bound; const char* label; };
    const Case cases[] = {
        { ENC_SRGB,    TM_REINHARD, 16.0f,  1.0e-2f, "sRGB + Reinhard W=16 (default)" },
        { ENC_SRGB,    TM_REINHARD, 128.0f, 5.0e-2f, "sRGB + Reinhard W=128 (extreme)" },
        { ENC_ACESCCT, TM_NONE,     16.0f,  5.0e-3f, "ACEScct log (highlight-safe)"   },
        { ENC_LINEAR,  TM_NONE,     16.0f,  5.0e-3f, "Linear (upstream behaviour)"    },
    };

    for (const Case& c : cases) {
        Params p;
        p.working_space = WS_ACESCG;
        p.encoding      = c.enc;
        p.tonemap       = c.tm;
        p.white_point   = c.white;
        Transform t(p);

        float worstRel = 0.0f;
        RGB worstSample{};
        for (const RGB& s : samples) {
            float r = s.r, g = s.g, b = s.b;
            t.forward(r, g, b);
            r = halfToFloat(floatToHalf(r));
            g = halfToFloat(floatToHalf(g));
            b = halfToFloat(floatToHalf(b));
            t.inverse(r, g, b);
            const float e = pixelError(s, r, g, b);
            if (e > worstRel) { worstRel = e; worstSample = s; }
        }
        char detail[192];
        std::snprintf(detail, sizeof(detail), "worst %.2f%% of pixel magnitude at (%.4g, %.4g, %.4g), bound %.2f%%",
                      worstRel * 100.0f, worstSample.r, worstSample.g, worstSample.b, c.bound * 100.0f);
        report(worstRel < c.bound, std::string("fp16 transport: ") + c.label, detail);
    }
}

// ---------------------------------------------------------------------------
// 5. Disabled pipeline must be bit-exact upstream behaviour
// ---------------------------------------------------------------------------

static void testBypass() {
    std::printf("\n[5] Legacy bypass\n");

    Params p;
    p.enabled = false;
    Transform t(p);

    bool ok = true;
    for (const RGB& s : sceneSamples()) {
        float r = s.r, g = s.g, b = s.b;
        t.forward(r, g, b);
        ok = ok && (r == s.r) && (g == s.g) && (b == s.b);
        t.inverse(r, g, b);
        ok = ok && (r == s.r) && (g == s.g) && (b == s.b);
    }
    report(ok, "colour management off is bit-exact passthrough");

    // The neutral axis must stay neutral: an achromatic input has to come back
    // achromatic, or greys pick up a cast.
    Params q;
    q.working_space = WS_ACESCG;
    q.encoding      = ENC_SRGB;
    q.tonemap       = TM_REINHARD;
    q.white_point   = 32.0f;
    Transform u(q);

    ok = true;
    float worst = 0.0f;
    for (float v = 0.001f; v < 30.0f; v *= 1.3f) {
        float r = v, g = v, b = v;
        u.forward(r, g, b);
        worst = std::max({worst, std::fabs(r - g), std::fabs(g - b)});
        ok = ok && close(r, g, 1e-6f, 1e-5f) && close(g, b, 1e-6f, 1e-5f);
    }
    char detail[96];
    std::snprintf(detail, sizeof(detail), "worst channel spread %.3e", worst);
    report(ok, "achromatic input stays achromatic through the encode", detail);
}

// ---------------------------------------------------------------------------

int main() {
    std::printf("AcesColor.h round-trip verification\n");
    std::printf("===================================\n");

    testMatrices();
    testCurves();
    testFullRoundTrip();
    testHalfTransport();
    testBypass();

    std::printf("\n-----------------------------------\n");
    std::printf("%d checks, %d failure(s)\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
