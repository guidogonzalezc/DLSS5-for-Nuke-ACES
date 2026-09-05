// Minimal DD::Image stand-in, for compile-checking src/DLSS5Live.cpp without a
// Nuke NDK installation.
//
// This is NOT a Nuke emulation and it never links against or ships with the
// plug-in. It declares just enough of the API surface the node touches for the
// compiler to type-check the node's own logic: signatures, channel handling,
// knob calls, row access. It catches the mistakes that are otherwise only found
// on a machine with the NDK -- wrong override signatures, missing members,
// type errors in the pixel loops.
//
// Real builds use the NDK headers; nothing here affects them.

#pragma once

#include <cstddef>
#include <cstring>
#include <vector>
#include <set>

namespace DD {
namespace Image {

// ---- channels --------------------------------------------------------------

typedef int Channel;

static const Channel Chan_Black = 0;
static const Channel Chan_Red   = 1;
static const Channel Chan_Green = 2;
static const Channel Chan_Blue  = 3;
static const Channel Chan_Alpha = 4;

class ChannelSet {
public:
    ChannelSet() {}
    ChannelSet(int mask) { if (mask) { for (int c = 1; c <= 4; ++c) m_set.insert(c); } }
    bool empty() const { return m_set.empty(); }
    void insert(Channel c) { m_set.insert(c); }
    bool contains(Channel c) const { return m_set.count(c) != 0; }
    ChannelSet& operator+=(const ChannelSet& o) { m_set.insert(o.m_set.begin(), o.m_set.end()); return *this; }
    ChannelSet& operator+=(Channel c) { m_set.insert(c); return *this; }
    ChannelSet& operator=(int mask) { m_set.clear(); if (mask) for (int c = 1; c <= 4; ++c) m_set.insert(c); return *this; }
    bool operator==(const ChannelSet& o) const { return m_set == o.m_set; }
    bool operator!=(const ChannelSet& o) const { return m_set != o.m_set; }
    std::set<Channel>::const_iterator begin() const { return m_set.begin(); }
    std::set<Channel>::const_iterator end() const { return m_set.end(); }
private:
    std::set<Channel> m_set;
};

typedef ChannelSet ChannelMask;

static const int Mask_None = 0;
static const int Mask_RGB  = 1;
static const int Mask_RGBA = 2;

// The NDK spells channel iteration with a macro; mirror the shape so the node's
// loops compile unchanged.
#define foreach(VAR, SET) for (Channel VAR : (SET))

inline Channel channel(const char*) { return Chan_Black; }

// ---- rows ------------------------------------------------------------------

class Iop;

class Row {
public:
    Row(int x, int r) : m_x(x), m_r(r), m_data(5) {
        for (auto& c : m_data) c.assign((size_t)(r > x ? r - x : 0) + 64, 0.0f);
    }
    void get(Iop&, int, int, int, const ChannelSet&) {}
    void get(Iop*, int, int, int, const ChannelSet&) {}
    const float* operator[](Channel c) const { return m_data[(size_t)c].data(); }
    float* writable(Channel c) { return m_data[(size_t)c].data(); }
private:
    int m_x, m_r;
    std::vector<std::vector<float> > m_data;
};

// ---- format / info ---------------------------------------------------------

class Format {
public:
    Format() {}
    Format(int w, int h, double pa) : m_w(w), m_h(h), m_pa(pa) {}
    int w() const { return m_w; }
    int h() const { return m_h; }
    double pixel_aspect() const { return m_pa; }
    void add(const char*) {}
    static Format* findExisting(int, int, double) { return nullptr; }
private:
    int m_w = 0, m_h = 0;
    double m_pa = 1.0;
};

class Info {
public:
    int w() const { return m_w; }
    int h() const { return m_h; }
    const Format& format() const { return m_format; }
    void format(const Format& f) { m_format = f; }
    void full_size_format(const Format& f) { m_format = f; }
    void set(int, int, int r, int t) { m_w = r; m_h = t; }
    ChannelSet channels() const { return ChannelSet(Mask_RGBA); }
private:
    int m_w = 0, m_h = 0;
    Format m_format;
};

class OutputContext {
public:
    double frame() const { return 1.0; }
};

// ---- knobs -----------------------------------------------------------------

class Knob {
public:
    static Knob& showPanel;
    enum Flags { HIDDEN = 1 };
    bool is(const char*) const { return false; }
    void visible(bool) {}
    void set_flag(int, bool) {}
};

typedef void* Knob_Callback;

inline void Named_Text_knob(Knob_Callback, const char*, const char*) {}
inline void Divider(Knob_Callback, const char* = nullptr) {}
inline void Tooltip(Knob_Callback, const char*) {}
inline void SetRange(Knob_Callback, double, double) {}
inline void Enumeration_knob(Knob_Callback, int*, const char* const*, const char*, const char* = nullptr) {}
inline void Int_knob(Knob_Callback, int*, const char*, const char* = nullptr) {}
inline void Float_knob(Knob_Callback, float*, const char*, const char* = nullptr) {}
inline void Bool_knob(Knob_Callback, bool*, const char*, const char* = nullptr) {}
inline void File_knob(Knob_Callback, const char**, const char*, const char* = nullptr) {}
inline void Input_ChannelSet_knob(Knob_Callback, ChannelSet*, int, const char*, const char* = nullptr) {}

// ---- Iop -------------------------------------------------------------------

class Node;

class Iop {
public:
    class Description {
    public:
        Description(const char*, const char*, Iop* (*)(Node*)) {}
    };

    Iop(Node*) {}
    virtual ~Iop() {}

    virtual int minimum_inputs() const { return 1; }
    virtual int maximum_inputs() const { return 1; }
    virtual int optional_input() const { return 1; }
    virtual const char* input_label(int, char*) const { return ""; }
    virtual void knobs(Knob_Callback) {}
    virtual int knob_changed(Knob*) { return 0; }
    virtual void _validate(bool) {}
    virtual void _request(int, int, int, int, ChannelMask, int) {}
    virtual void engine(int, int, int, ChannelMask, Row&) {}
    virtual const char* Class() const { return "Iop"; }
    virtual const char* node_help() const { return ""; }

    void inputs(int) {}
    Node* node_input(int) { return m_node; }
    Iop* input(int) { return this; }
    Iop& input0() { return *this; }
    const Info& info() const { return info_; }
    void copy_info() {}
    void request(int, int, int, int, ChannelMask, int) {}
    Knob* knob(const char*) { return nullptr; }
    const OutputContext& outputContext() const { return m_ctx; }

protected:
    Info info_;

private:
    Node* m_node = nullptr;
    OutputContext m_ctx;
};

} // namespace Image
} // namespace DD
