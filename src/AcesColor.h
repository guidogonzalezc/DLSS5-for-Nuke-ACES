// AcesColor.h - ACES-aware, analytically invertible color pipeline for DLSS5Live.
//
// Why this exists
// ---------------
// The DLSS neural models are trained on display-referred content: Rec.709/sRGB
// primaries, a display transfer function, and a nominal 0..1 range. Nuke's ACES
// working space is the opposite: scene-linear, AP1 primaries, unbounded range.
// Feeding scene-linear ACEScg straight into the model is what shifts hue,
// desaturates and crushes highlights.
//
// This header wraps the neural pass in a round trip:
//
//     working space -> exposure -> [primaries] -> [gamut compress]
//                   -> [tone map] -> [transfer function] -> DLSS
//                   -> inverse transfer -> inverse tone map
//                   -> inverse gamut compress -> [primaries] -> inverse exposure
//
// Every stage has a closed-form inverse, so with the neural pass bypassed the
// round trip is the identity to within float precision. That is the property
// that keeps the node from breaking color: it only ever adds what DLSS did.
//
// Deliberately dependency-free (only <cmath>/<algorithm>) so it builds without
// the Nuke NDK and can be unit-tested standalone. See
// tests/test_aces_roundtrip.cpp.

#pragma once

#include <cmath>
#include <algorithm>

namespace aces {

// ---------------------------------------------------------------------------
// Enumerations (must match the knob order in DLSS5Live.cpp)
// ---------------------------------------------------------------------------

enum WorkingSpace {
    WS_ACESCG = 0,      // AP1 primaries, scene-linear  (Nuke ACES default)
    WS_ACES2065_1,      // AP0 primaries, scene-linear  (ACES interchange)
    WS_ACESCCT,         // AP1 primaries, ACEScct log
    WS_ACESCC,          // AP1 primaries, ACEScc log
    WS_LINEAR_REC709,   // Rec.709/sRGB primaries, scene-linear
    WS_LINEAR_P3D65,    // P3-D65 primaries, scene-linear
    WS_COUNT
};

enum Encoding {
    ENC_SRGB = 0,       // Rec.709 primaries + sRGB EOTF^-1   (recommended)
    ENC_REC709,         // Rec.709 primaries + BT.709 OETF
    ENC_GAMMA22,        // Rec.709 primaries + gamma 2.2
    ENC_ACESCCT,        // AP1 primaries + ACEScct log (no primary change)
    ENC_LINEAR,         // no encoding at all (legacy / upstream behaviour)
    ENC_COUNT
};

enum ToneMap {
    TM_REINHARD = 0,    // extended Reinhard, white point W maps to exactly 1.0
    TM_ACES_FILMIC,     // Narkowicz ACES fit, inverted via the quadratic formula
    TM_NONE,            // no highlight roll-off
    TM_COUNT
};

// ---------------------------------------------------------------------------
// 3x3 matrix helpers
// ---------------------------------------------------------------------------

struct Mat3 {
    float m[9];

    static Mat3 identity() {
        Mat3 r;
        r.m[0] = 1.0f; r.m[1] = 0.0f; r.m[2] = 0.0f;
        r.m[3] = 0.0f; r.m[4] = 1.0f; r.m[5] = 0.0f;
        r.m[6] = 0.0f; r.m[7] = 0.0f; r.m[8] = 1.0f;
        return r;
    }

    inline void apply(float& r, float& g, float& b) const {
        const float x = r, y = g, z = b;
        r = m[0] * x + m[1] * y + m[2] * z;
        g = m[3] * x + m[4] * y + m[5] * z;
        b = m[6] * x + m[7] * y + m[8] * z;
    }
};

inline Mat3 mul(const Mat3& a, const Mat3& b) {
    Mat3 r;
    for (int i = 0; i < 3; ++i) {
        for (int j = 0; j < 3; ++j) {
            double s = 0.0;
            for (int k = 0; k < 3; ++k) s += (double)a.m[i * 3 + k] * (double)b.m[k * 3 + j];
            r.m[i * 3 + j] = (float)s;
        }
    }
    return r;
}

inline Mat3 invert(const Mat3& a) {
    const double m0 = a.m[0], m1 = a.m[1], m2 = a.m[2];
    const double m3 = a.m[3], m4 = a.m[4], m5 = a.m[5];
    const double m6 = a.m[6], m7 = a.m[7], m8 = a.m[8];
    const double c0 = m4 * m8 - m5 * m7;
    const double c1 = m5 * m6 - m3 * m8;
    const double c2 = m3 * m7 - m4 * m6;
    const double det = m0 * c0 + m1 * c1 + m2 * c2;
    if (det == 0.0) return Mat3::identity();
    const double id = 1.0 / det;
    Mat3 r;
    r.m[0] = (float)(c0 * id);
    r.m[1] = (float)((m2 * m7 - m1 * m8) * id);
    r.m[2] = (float)((m1 * m5 - m2 * m4) * id);
    r.m[3] = (float)(c1 * id);
    r.m[4] = (float)((m0 * m8 - m2 * m6) * id);
    r.m[5] = (float)((m2 * m3 - m0 * m5) * id);
    r.m[6] = (float)(c2 * id);
    r.m[7] = (float)((m1 * m6 - m0 * m7) * id);
    r.m[8] = (float)((m0 * m4 - m1 * m3) * id);
    return r;
}

// ---------------------------------------------------------------------------
// Primaries -> XYZ, and Bradford chromatic adaptation
//
// Matrices are derived from published chromaticities rather than transcribed, so
// there is no risk of a typo in a hard-coded constant. The derivation reproduces
// the canonical ACES matrices; tests/test_aces_roundtrip.cpp asserts that
// AP1 -> Rec.709 equals {1.7050516, -0.6217908, -0.0832588, ...}.
// ---------------------------------------------------------------------------

struct Chromaticities {
    double rx, ry, gx, gy, bx, by, wx, wy;
};

// SMPTE ST 2065-1 / ACES, Rec.709 and P3-D65 primaries.
static const Chromaticities kAP0    = { 0.73470, 0.26530, 0.00000, 1.00000, 0.00010, -0.07700, 0.32168, 0.33767 };
static const Chromaticities kAP1    = { 0.71300, 0.29300, 0.16500, 0.83000, 0.12800,  0.04400, 0.32168, 0.33767 };
static const Chromaticities kRec709 = { 0.64000, 0.33000, 0.30000, 0.60000, 0.15000,  0.06000, 0.31270, 0.32900 };
static const Chromaticities kP3D65  = { 0.68000, 0.32000, 0.26500, 0.69000, 0.15000,  0.06000, 0.31270, 0.32900 };

inline Mat3 rgbToXYZ(const Chromaticities& c) {
    // Column-scaled primary matrix such that (1,1,1) maps to the white point.
    const double Xr = c.rx / c.ry, Yr = 1.0, Zr = (1.0 - c.rx - c.ry) / c.ry;
    const double Xg = c.gx / c.gy, Yg = 1.0, Zg = (1.0 - c.gx - c.gy) / c.gy;
    const double Xb = c.bx / c.by, Yb = 1.0, Zb = (1.0 - c.bx - c.by) / c.by;

    Mat3 P;
    P.m[0] = (float)Xr; P.m[1] = (float)Xg; P.m[2] = (float)Xb;
    P.m[3] = (float)Yr; P.m[4] = (float)Yg; P.m[5] = (float)Yb;
    P.m[6] = (float)Zr; P.m[7] = (float)Zg; P.m[8] = (float)Zb;

    const double Xw = c.wx / c.wy, Yw = 1.0, Zw = (1.0 - c.wx - c.wy) / c.wy;
    const Mat3 Pi = invert(P);
    const double sr = Pi.m[0] * Xw + Pi.m[1] * Yw + Pi.m[2] * Zw;
    const double sg = Pi.m[3] * Xw + Pi.m[4] * Yw + Pi.m[5] * Zw;
    const double sb = Pi.m[6] * Xw + Pi.m[7] * Yw + Pi.m[8] * Zw;

    Mat3 M;
    M.m[0] = (float)(Xr * sr); M.m[1] = (float)(Xg * sg); M.m[2] = (float)(Xb * sb);
    M.m[3] = (float)(Yr * sr); M.m[4] = (float)(Yg * sg); M.m[5] = (float)(Yb * sb);
    M.m[6] = (float)(Zr * sr); M.m[7] = (float)(Zg * sg); M.m[8] = (float)(Zb * sb);
    return M;
}

inline Mat3 bradfordCAT(const Chromaticities& src, const Chromaticities& dst) {
    if (src.wx == dst.wx && src.wy == dst.wy) return Mat3::identity();

    Mat3 B;
    B.m[0] =  0.8951f; B.m[1] =  0.2664f; B.m[2] = -0.1614f;
    B.m[3] = -0.7502f; B.m[4] =  1.7135f; B.m[5] =  0.0367f;
    B.m[6] =  0.0389f; B.m[7] = -0.0685f; B.m[8] =  1.0296f;

    float sX = (float)(src.wx / src.wy), sY = 1.0f, sZ = (float)((1.0 - src.wx - src.wy) / src.wy);
    float dX = (float)(dst.wx / dst.wy), dY = 1.0f, dZ = (float)((1.0 - dst.wx - dst.wy) / dst.wy);
    B.apply(sX, sY, sZ);
    B.apply(dX, dY, dZ);

    Mat3 S = Mat3::identity();
    S.m[0] = dX / sX;
    S.m[4] = dY / sY;
    S.m[8] = dZ / sZ;

    return mul(invert(B), mul(S, B));
}

// Linear RGB conversion between two sets of primaries, white-point adapted.
inline Mat3 primariesMatrix(const Chromaticities& from, const Chromaticities& to) {
    return mul(invert(rgbToXYZ(to)), mul(bradfordCAT(from, to), rgbToXYZ(from)));
}

// ---------------------------------------------------------------------------
// Transfer functions
//
// Every curve is extended oddly (f(-x) = -f(x)). Converting AP1 to Rec.709 sends
// saturated colors negative; an odd extension keeps the curve strictly monotonic
// through zero, so those pixels survive the round trip instead of clipping to
// black or turning into NaN inside a pow().
// ---------------------------------------------------------------------------

inline float sgnf(float x) { return (x < 0.0f) ? -1.0f : 1.0f; }

inline float srgbEncode(float x) {
    const float s = sgnf(x), a = std::fabs(x);
    return s * ((a <= 0.0031308f) ? (12.92f * a)
                                  : (1.055f * std::pow(a, 1.0f / 2.4f) - 0.055f));
}
inline float srgbDecode(float y) {
    const float s = sgnf(y), a = std::fabs(y);
    return s * ((a <= 0.04045f) ? (a / 12.92f)
                                : std::pow((a + 0.055f) / 1.055f, 2.4f));
}

inline float rec709Encode(float x) {
    const float s = sgnf(x), a = std::fabs(x);
    return s * ((a < 0.018f) ? (4.5f * a) : (1.099f * std::pow(a, 0.45f) - 0.099f));
}
inline float rec709Decode(float y) {
    const float s = sgnf(y), a = std::fabs(y);
    return s * ((a < 0.081f) ? (a / 4.5f) : std::pow((a + 0.099f) / 1.099f, 1.0f / 0.45f));
}

inline float gamma22Encode(float x) { return sgnf(x) * std::pow(std::fabs(x), 1.0f / 2.2f); }
inline float gamma22Decode(float y) { return sgnf(y) * std::pow(std::fabs(y), 2.2f); }

// ACEScct (S-2016-001). Linear below the break, log above; exactly invertible.
static const float kCctA      = 10.5402377416545f;
static const float kCctB      = 0.0729055341958355f;
static const float kCctBreak  = 0.0078125f;          // linear side
static const float kCctYBreak = 0.155251141552511f;  // log side

inline float acesCctEncode(float x) {
    if (x <= kCctBreak) return kCctA * x + kCctB;
    return (std::log2(x) + 9.72f) / 17.52f;
}
inline float acesCctDecode(float y) {
    if (y <= kCctYBreak) return (y - kCctB) / kCctA;
    if (y < (std::log2(65504.0f) + 9.72f) / 17.52f) return std::pow(2.0f, y * 17.52f - 9.72f);
    return 65504.0f;
}

// ACEScc (S-2014-003). Pure log, so it cannot represent zero exactly; the
// standard clamps at 2^-16. Offered for parity with Nuke's colorspace list.
inline float acesCcEncode(float x) {
    if (x <= 0.0f) return (-16.0f + 9.72f) / 17.52f;
    if (x < std::pow(2.0f, -15.0f)) return (std::log2(std::pow(2.0f, -16.0f) + x * 0.5f) + 9.72f) / 17.52f;
    return (std::log2(x) + 9.72f) / 17.52f;
}
inline float acesCcDecode(float y) {
    const float yMin = (-16.0f + 9.72f) / 17.52f;
    const float yMid = (-15.0f + 9.72f) / 17.52f;
    if (y <= yMin) return 0.0f;
    if (y < yMid)  return (std::pow(2.0f, y * 17.52f - 9.72f) - std::pow(2.0f, -16.0f)) * 2.0f;
    if (y < (std::log2(65504.0f) + 9.72f) / 17.52f) return std::pow(2.0f, y * 17.52f - 9.72f);
    return 65504.0f;
}

// ---------------------------------------------------------------------------
// Tone mapping
// ---------------------------------------------------------------------------

// Extended Reinhard: f(W) == 1 exactly, f'(x) > 0 for all x >= 0.
//   f(x) = x * (1 + x / W^2) / (1 + x)
inline float reinhardEncode(float x, float W) {
    const float s = sgnf(x), a = std::fabs(x);
    const float w2 = W * W;
    return s * (a * (1.0f + a / w2) / (1.0f + a));
}
inline float reinhardDecode(float y, float W) {
    // Solve a^2/W^2 + a(1 - y) - y = 0 for a >= 0.
    //
    // The textbook root 0.5*W^2*(sqrt(D) - k) loses almost every significant
    // digit for small y: sqrt(D) and k agree to ~8 digits and the difference is
    // then multiplied by W^2/2, which for W=128 is 8192. Below the white point
    // the conjugate form  2y / (sqrt(D) + k)  computes the same root without any
    // subtraction of near-equal numbers. Above it (y > 1, k < 0) the textbook
    // form is a sum of positives and is the stable one.
    const float s = sgnf(y);
    const double b = std::fabs((double)y);
    const double w2 = (double)W * (double)W;
    const double k = 1.0 - b;
    const double disc = k * k + 4.0 * b / w2;
    const double root = std::sqrt(disc);
    const double a = (k > 0.0) ? (2.0 * b / (root + k))
                               : (0.5 * w2 * (root - k));
    return s * (float)a;
}

// Narkowicz ACES fit. f(x) = x(2.51x + 0.03) / (x(2.43x + 0.59) + 0.14),
// a rational quadratic, so the inverse is the quadratic formula. The fit is
// only strictly increasing up to x ~= 6.6, so the input is pre-scaled by
// kFilmicMaxIn / W: with the white point tracking the frame maximum, the whole
// frame lands inside the invertible domain and f(W) ~= 0.996.
static const float kFilmicMaxIn = 6.5f;

inline float filmicFit(float a) {
    return (a * (2.51f * a + 0.03f)) / (a * (2.43f * a + 0.59f) + 0.14f);
}

inline float filmicEncode(float x, float W) {
    const float s = sgnf(x);
    const float k = kFilmicMaxIn / std::max(W, 1e-4f);
    const float a = std::min(std::fabs(x) * k, kFilmicMaxIn);
    return s * filmicFit(a);
}

inline float filmicDecode(float y, float W) {
    const float s = sgnf(y);
    const float b = std::fabs(y);
    const float A = 2.43f * b - 2.51f;
    const float B = 0.59f * b - 0.03f;
    const float C = 0.14f * b;
    const float k = std::max(W, 1e-4f) / kFilmicMaxIn;

    float a;
    if (std::fabs(A) < 1e-6f) {
        a = (B != 0.0f) ? std::max(-C / B, 0.0f) : 0.0f;
    } else {
        const float disc = B * B - 4.0f * A * C;
        if (disc < 0.0f) return s * kFilmicMaxIn * k;
        // The "minus" root is the branch that passes through the origin.
        a = (-B - std::sqrt(disc)) / (2.0f * A);
    }
    return s * std::min(std::max(a, 0.0f), kFilmicMaxIn) * k;
}

// ---------------------------------------------------------------------------
// ACES 1.3 Reference Gamut Compression (ACES RGC)
//
// Applied in the model's own primaries, it pulls out-of-gamut (negative)
// components back inside the cube before encoding, and pushes them back out
// afterwards. Exposure-invariant (it works on distances from the achromatic
// axis) and exactly invertible inside the compressed range.
// ---------------------------------------------------------------------------

struct GamutCompressParams {
    float threshold = 0.815f;   // distance below which nothing is touched
    float limit_c   = 1.147f;   // furthest distance compressed, per channel
    float limit_m   = 1.264f;
    float limit_y   = 1.312f;
    float power     = 1.2f;
};

inline float gcScale(float lim, float thr, float p) {
    const float d = lim - thr;
    if (d <= 1e-6f) return 1.0f;
    return d / std::pow(std::pow((1.0f - thr) / d, -p) - 1.0f, 1.0f / p);
}

inline float gcCompress(float dist, float lim, float thr, float p) {
    if (dist < thr || lim < 1.0001f) return dist;
    const float s = gcScale(lim, thr, p);
    const float scl = (dist - thr) / s;
    return thr + s * scl / std::pow(1.0f + std::pow(scl, p), 1.0f / p);
}

inline float gcUncompress(float dist, float lim, float thr, float p) {
    if (dist < thr || lim < 1.0001f) return dist;
    const float s = gcScale(lim, thr, p);
    // Distances at or beyond thr + s are the asymptote; nothing maps there.
    if (dist >= thr + s) return lim;
    const float scl = (dist - thr) / s;
    const float sp = std::pow(scl, p);
    return thr + s * std::pow(-(sp / (sp - 1.0f)), 1.0f / p);
}

inline void gamutCompress(float& r, float& g, float& b, const GamutCompressParams& p, bool inverse) {
    const float ac = std::max(r, std::max(g, b));
    const float aac = std::fabs(ac);
    if (aac < 1e-9f) return;

    float dr = (ac - r) / aac;
    float dg = (ac - g) / aac;
    float db = (ac - b) / aac;

    if (inverse) {
        dr = gcUncompress(dr, p.limit_c, p.threshold, p.power);
        dg = gcUncompress(dg, p.limit_m, p.threshold, p.power);
        db = gcUncompress(db, p.limit_y, p.threshold, p.power);
    } else {
        dr = gcCompress(dr, p.limit_c, p.threshold, p.power);
        dg = gcCompress(dg, p.limit_m, p.threshold, p.power);
        db = gcCompress(db, p.limit_y, p.threshold, p.power);
    }

    r = ac - dr * aac;
    g = ac - dg * aac;
    b = ac - db * aac;
}

// ---------------------------------------------------------------------------
// Pipeline parameters and transform
// ---------------------------------------------------------------------------

struct Params {
    bool  enabled        = true;
    int   working_space  = WS_ACESCG;
    int   encoding       = ENC_SRGB;
    int   tonemap        = TM_REINHARD;
    float exposure_stops = 0.0f;
    float white_point    = 16.0f;   // scene-linear value mapped to 1.0
    bool  gamut_compress = true;
    GamutCompressParams gc;
};

// Splits the round trip into two halves so the caller can measure the frame
// between them (auto white point needs the scene-linear maximum):
//
//   toModel()          working space -> model-space scene-linear
//   encodeFromModel()  model-space scene-linear -> what DLSS sees
//   decodeToModel()    inverse of encodeFromModel()
//   fromModel()        inverse of toModel()
class Transform {
public:
    Transform() { Params p; init(p); }
    explicit Transform(const Params& p) { init(p); }

    void init(const Params& p) {
        m_p = p;

        // ACEScct keeps AP1 primaries; every display encoding targets Rec.709.
        const bool modelIsAP1 = (p.encoding == ENC_ACESCCT);
        const Chromaticities& model = modelIsAP1 ? kAP1 : kRec709;

        const Chromaticities* src = &kAP1;
        switch (p.working_space) {
            case WS_ACES2065_1:    src = &kAP0;    break;
            case WS_LINEAR_REC709: src = &kRec709; break;
            case WS_LINEAR_P3D65:  src = &kP3D65;  break;
            case WS_ACESCG:
            case WS_ACESCCT:
            case WS_ACESCC:
            default:               src = &kAP1;    break;
        }

        const bool same = (src->rx == model.rx && src->ry == model.ry &&
                           src->gx == model.gx && src->wx == model.wx);
        m_needMatrix = !same;
        m_toModel    = same ? Mat3::identity() : primariesMatrix(*src, model);
        m_fromModel  = same ? Mat3::identity() : invert(m_toModel);

        m_gain    = std::pow(2.0f, p.exposure_stops);
        m_invGain = 1.0f / m_gain;
        setWhitePoint(p.white_point);
    }

    // The white point can be re-derived per frame without rebuilding matrices.
    void  setWhitePoint(float w) { m_white = std::max(w, 1e-4f); }
    float whitePoint() const { return m_white; }
    bool  enabled() const { return m_p.enabled; }
    const Params& params() const { return m_p; }

    // ---- working space -> model-space scene-linear -------------------------
    inline void toModel(float& r, float& g, float& b) const {
        if (!m_p.enabled) return;

        if (m_p.working_space == WS_ACESCCT) {
            r = acesCctDecode(r); g = acesCctDecode(g); b = acesCctDecode(b);
        } else if (m_p.working_space == WS_ACESCC) {
            r = acesCcDecode(r); g = acesCcDecode(g); b = acesCcDecode(b);
        }

        if (m_gain != 1.0f) { r *= m_gain; g *= m_gain; b *= m_gain; }
        if (m_needMatrix) m_toModel.apply(r, g, b);
        if (m_p.gamut_compress) gamutCompress(r, g, b, m_p.gc, false);
    }

    inline void fromModel(float& r, float& g, float& b) const {
        if (!m_p.enabled) return;

        if (m_p.gamut_compress) gamutCompress(r, g, b, m_p.gc, true);
        if (m_needMatrix) m_fromModel.apply(r, g, b);
        if (m_gain != 1.0f) { r *= m_invGain; g *= m_invGain; b *= m_invGain; }

        if (m_p.working_space == WS_ACESCCT) {
            r = acesCctEncode(r); g = acesCctEncode(g); b = acesCctEncode(b);
        } else if (m_p.working_space == WS_ACESCC) {
            r = acesCcEncode(r); g = acesCcEncode(g); b = acesCcEncode(b);
        }
    }

    // ---- model-space scene-linear -> DLSS input ----------------------------
    inline void encodeFromModel(float& r, float& g, float& b) const {
        if (!m_p.enabled) return;

        if (m_p.encoding == ENC_ACESCCT) {
            // Log already carries the full range; a tone curve would be redundant.
            r = acesCctEncode(std::max(r, 0.0f));
            g = acesCctEncode(std::max(g, 0.0f));
            b = acesCctEncode(std::max(b, 0.0f));
            return;
        }

        switch (m_p.tonemap) {
            case TM_REINHARD:
                r = reinhardEncode(r, m_white);
                g = reinhardEncode(g, m_white);
                b = reinhardEncode(b, m_white);
                break;
            case TM_ACES_FILMIC:
                r = filmicEncode(r, m_white);
                g = filmicEncode(g, m_white);
                b = filmicEncode(b, m_white);
                break;
            default: break;
        }

        switch (m_p.encoding) {
            case ENC_SRGB:    r = srgbEncode(r);    g = srgbEncode(g);    b = srgbEncode(b);    break;
            case ENC_REC709:  r = rec709Encode(r);  g = rec709Encode(g);  b = rec709Encode(b);  break;
            case ENC_GAMMA22: r = gamma22Encode(r); g = gamma22Encode(g); b = gamma22Encode(b); break;
            default: break;
        }
    }

    inline void decodeToModel(float& r, float& g, float& b) const {
        if (!m_p.enabled) return;

        if (m_p.encoding == ENC_ACESCCT) {
            r = acesCctDecode(r); g = acesCctDecode(g); b = acesCctDecode(b);
            return;
        }

        switch (m_p.encoding) {
            case ENC_SRGB:    r = srgbDecode(r);    g = srgbDecode(g);    b = srgbDecode(b);    break;
            case ENC_REC709:  r = rec709Decode(r);  g = rec709Decode(g);  b = rec709Decode(b);  break;
            case ENC_GAMMA22: r = gamma22Decode(r); g = gamma22Decode(g); b = gamma22Decode(b); break;
            default: break;
        }

        switch (m_p.tonemap) {
            case TM_REINHARD:
                r = reinhardDecode(r, m_white);
                g = reinhardDecode(g, m_white);
                b = reinhardDecode(b, m_white);
                break;
            case TM_ACES_FILMIC:
                r = filmicDecode(r, m_white);
                g = filmicDecode(g, m_white);
                b = filmicDecode(b, m_white);
                break;
            default: break;
        }
    }

    // ---- convenience: full round trip --------------------------------------
    inline void forward(float& r, float& g, float& b) const { toModel(r, g, b); encodeFromModel(r, g, b); }
    inline void inverse(float& r, float& g, float& b) const { decodeToModel(r, g, b); fromModel(r, g, b); }

    // True when the encoded signal handed to DLSS is display-referred, i.e. the
    // NGX IsHDR feature flag should be cleared.
    bool producesDisplayReferred() const {
        return m_p.enabled && (m_p.encoding == ENC_SRGB ||
                               m_p.encoding == ENC_REC709 ||
                               m_p.encoding == ENC_GAMMA22);
    }

    // Whether the frame maximum should drive the tone curve's white point.
    bool usesWhitePoint() const {
        return m_p.enabled && m_p.encoding != ENC_ACESCCT &&
               (m_p.tonemap == TM_REINHARD || m_p.tonemap == TM_ACES_FILMIC);
    }

private:
    Params m_p;
    Mat3   m_toModel    = Mat3::identity();
    Mat3   m_fromModel  = Mat3::identity();
    bool   m_needMatrix = false;
    float  m_gain       = 1.0f;
    float  m_invGain    = 1.0f;
    float  m_white      = 16.0f;
};

} // namespace aces
