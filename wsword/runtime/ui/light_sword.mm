// (WSword PS5) On the console only the WSword shirt is made (LS_SHIRT_ONLY, below: Mods > WSword Shirt - make_shirt_mod):
// the Nintendo Switch Shirt's colour picture and inventory picture made the WSword shirt's from the player's own game
// files, with the WSword emblem (assets/wsword-emblem.png in the title folder), and its name and description in every
// language - no sword, no chest, nothing in the saves. The rest of this file is the Android / PC sword's, compiled out.
//
// (WSword, experimental) The Sword of Light: a sword infused with light, made like the Master Sword - its strength runs
// out with use, it rests, and its light comes back after a while - lying on the Great Plateau for Link to pick up.
//
// Nothing of the game's ships with WSword: Mods > Sword of Light makes a mod from the player's own game files, on the
// device - mods/WSword Sword of Light/romfs (runtime/mods.c serves it over the game's files):
//   - Actor/Pack/Weapon_Sword_L01.sbactorpack (and L02, L03): the Master Sword's three (Weapon_Sword_070, its resting
//     071 and its awakened 072, from Pack/TitleBG.pack where the game loads them) copied; each shares the Master
//     Sword's parts (model, physics, animations) but its parameters, which get a name of their own: its MasterSword
//     parameters (resting form, awakened form, recovery time) point at the copies, so it runs out, rests and comes
//     back as the Master Sword does - stronger and lasting longer;
//   - Actor/ActorInfo.product.sbyml: the three added (the game's list of actors, sorted by their names' CRC32), with
//     their stats as the inventory shows them;
//   - UI/StockItem/<name>.sbitemico: the Master Sword's inventory pictures under the new names;
//   - Pack/Bootup.pack's GameData: the save flags each item has (IsGet_, EquipTime_, PorchTime_, PictureBook...),
//     the Master Sword's copied for the new names, and their places in the save;
//   - Pack/Bootup_<language>.pack's Message/Msg_<language>.product.ssarc: "Sword of Light", its description;
//   - one Great Plateau map unit (Map/MainField/<section>/<section>_Static or _Dynamic.smubin): a new treasure chest
//     beside one that's there (its contents the sword) - or, without one, the sword lying beside a weapon placed
//     there (with the DLC set up the game reads the DLC's copy of the map from its Pack/AocMainField.pack: then the
//     DLC's loose copy, and an empty AocMainField.pack so it's read, in a second mod folder for the DLC);
//   - System/Resource/ResourceSizeTable.product.srsizetable: an entry for each file made, with room to spare (the
//     actor list's taken out: the game works its size out itself).
// Before it's first turned on the saves are copied to save_backup_sword_of_light/. Turned off, the mod folders go (a
// save that has the sword in its inventory needs it on to load - the note says so).
//
// The formats (little-endian, the Switch's): Yaz0 (written uncompressed: literal runs), SARC, BYML v2/v3, AAMP (read
// and written whole: values can share their bytes), MSBT (LBL1 / ATR1 / TXT2 rebuilt), RSTB. Checked against a
// working mod's files of each kind; every step checks what it reads, and the mod is written only when all worked.
#include <dirent.h>
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <algorithm>
#include <atomic>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "imgui.h"
#define STB_IMAGE_STATIC
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#include "../../third_party/stb/stb_image.h"

#include "i18n.h"
#include "option_rows.h"
#ifdef __PROSPERO__
#define LS_SHIRT_ONLY 1   // (the PS5: the shirt only - see the top)
#endif
extern "C" {
#include "../paths.h"
#include "../romfs_build.h"
#ifndef LS_SHIRT_ONLY
const char *fs_aoc_image(void);
#endif
}

typedef std::vector<uint8_t> Bytes;

namespace ls {
// ------------------------------------------------------------------ little helpers
static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t rd24(const uint8_t *p) { return (uint32_t)(p[0] | p[1] << 8 | p[2] << 16); }
static uint32_t rd32(const uint8_t *p) { return (uint32_t)(p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24); }
static uint32_t rd32be(const uint8_t *p) { return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }
static void put16(Bytes &b, uint16_t v) { b.push_back(v & 255), b.push_back(v >> 8); }
static void put24(Bytes &b, uint32_t v) { b.push_back(v & 255), b.push_back(v >> 8 & 255), b.push_back(v >> 16 & 255); }
static void put32(Bytes &b, uint32_t v) { for (int i = 0; i < 4; i++) b.push_back(v >> (8 * i) & 255); }
static void set32(Bytes &b, size_t at, uint32_t v) { for (int i = 0; i < 4; i++) b[at + i] = v >> (8 * i) & 255; }
static void pad_to(Bytes &b, size_t align, uint8_t fill = 0) { while (b.size() % align) b.push_back(fill); }

static uint32_t crc32(const std::string &s) {
    static uint32_t t[256];
    if (!t[1])
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            t[i] = c;
        }
    uint32_t c = 0xFFFFFFFFu;
    for (unsigned char ch : s) c = t[(c ^ ch) & 255] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
}

struct Fail {
    std::string why;
};
[[noreturn]] static void fail(const std::string &w) { throw Fail{w}; }

// ------------------------------------------------------------------ Yaz0
static bool is_yaz0(const Bytes &b) { return b.size() >= 16 && !memcmp(b.data(), "Yaz0", 4); }
static Bytes yaz0_decode(const Bytes &in) {
    if (!is_yaz0(in)) return in;
    uint32_t n = rd32be(&in[4]);
    Bytes out;
    out.reserve(n);
    size_t i = 16;
    while (out.size() < n) {
        if (i >= in.size()) fail("Yaz0 data cut short");
        uint8_t code = in[i++];
        for (int bit = 7; bit >= 0 && out.size() < n; bit--) {
            if (code >> bit & 1) {
                if (i >= in.size()) fail("Yaz0 data cut short");
                out.push_back(in[i++]);
            } else {
                if (i + 1 >= in.size()) fail("Yaz0 data cut short");
                uint8_t b0 = in[i++], b1 = in[i++];
                size_t dist = ((size_t)(b0 & 15) << 8 | b1) + 1, len = b0 >> 4;
                if (len == 0) {
                    if (i >= in.size()) fail("Yaz0 data cut short");
                    len = (size_t)in[i++] + 0x12;
                } else len += 2;
                if (dist > out.size()) fail("Yaz0 reference out of range");
                size_t from = out.size() - dist;
                for (size_t k = 0; k < len && out.size() < n; k++) out.push_back(out[from + k]);
            }
        }
    }
    return out;
}
static Bytes yaz0_encode(const Bytes &in) {   // (literal runs only: valid Yaz0 the game reads, ~12% larger)
    Bytes out = {'Y', 'a', 'z', '0'};
    uint32_t n = (uint32_t)in.size();
    out.push_back(n >> 24), out.push_back(n >> 16 & 255), out.push_back(n >> 8 & 255), out.push_back(n & 255);
    for (int i = 0; i < 8; i++) out.push_back(0);
    for (size_t i = 0; i < in.size(); i += 8) {
        out.push_back(0xFF);
        for (size_t k = i; k < i + 8; k++) out.push_back(k < in.size() ? in[k] : 0);
    }
    return out;
}

// ------------------------------------------------------------------ SARC
struct Sarc {
    std::vector<std::pair<std::string, Bytes>> files;
    Bytes *get(const std::string &name) {
        for (auto &f : files) if (f.first == name) return &f.second;
        return NULL;
    }
};
static uint32_t sarc_hash(const std::string &s, uint32_t key) {
    uint32_t h = 0;
    for (unsigned char c : s) h = h * key + (uint32_t)(signed char)c;
    return h;
}
static Sarc sarc_read(const Bytes &b) {
    if (b.size() < 0x20 || memcmp(b.data(), "SARC", 4)) fail("not a SARC archive");
    if (rd16(&b[6]) != 0xFEFF) fail("a big-endian SARC (not the Switch's)");
    uint32_t data_off = rd32(&b[0xC]);
    size_t fat = rd16(&b[4]);
    if (memcmp(&b[fat], "SFAT", 4)) fail("SARC without SFAT");
    uint16_t count = rd16(&b[fat + 6]);
    size_t nodes = fat + 0xC, fnt = nodes + (size_t)count * 16;
    if (fnt + 8 > b.size() || memcmp(&b[fnt], "SFNT", 4)) fail("SARC without SFNT");
    size_t names = fnt + 8;
    Sarc s;
    for (int i = 0; i < count; i++) {
        const uint8_t *n = &b[nodes + (size_t)i * 16];
        uint32_t attr = rd32(n + 4), start = rd32(n + 8), end = rd32(n + 12);
        std::string name;
        if (attr >> 24) {
            size_t at = names + (size_t)(attr & 0xFFFFFF) * 4;
            while (at < b.size() && b[at]) name += (char)b[at++];
        } else name = "unnamed_" + std::to_string(i);
        if ((size_t)data_off + end > b.size() || start > end) fail("SARC file out of range");
        s.files.push_back({name, Bytes(b.begin() + data_off + start, b.begin() + data_off + end)});
    }
    return s;
}
static Bytes sarc_write(const Sarc &s, size_t align) {
    std::vector<size_t> order(s.files.size());
    for (size_t i = 0; i < order.size(); i++) order[i] = i;
    std::sort(order.begin(), order.end(), [&](size_t a, size_t b) {
        return sarc_hash(s.files[a].first, 0x65) < sarc_hash(s.files[b].first, 0x65);
    });
    Bytes names;
    std::vector<uint32_t> name_off(s.files.size());
    for (size_t i : order) {
        name_off[i] = (uint32_t)names.size();
        names.insert(names.end(), s.files[i].first.begin(), s.files[i].first.end());
        names.push_back(0);
        pad_to(names, 4);
    }
    Bytes data;
    std::vector<std::pair<uint32_t, uint32_t>> range(s.files.size());
    for (size_t i : order) {
        pad_to(data, align);
        range[i] = {(uint32_t)data.size(), (uint32_t)(data.size() + s.files[i].second.size())};
        data.insert(data.end(), s.files[i].second.begin(), s.files[i].second.end());
    }
    Bytes out = {'S', 'A', 'R', 'C'};
    put16(out, 0x14), put16(out, 0xFEFF), put32(out, 0), put32(out, 0), put16(out, 0x100), put16(out, 0);
    out.insert(out.end(), {'S', 'F', 'A', 'T'});
    put16(out, 0xC), put16(out, (uint16_t)s.files.size()), put32(out, 0x65);
    for (size_t i : order) {
        put32(out, sarc_hash(s.files[i].first, 0x65));
        put32(out, 0x01000000u | (name_off[i] / 4));
        put32(out, range[i].first), put32(out, range[i].second);
    }
    out.insert(out.end(), {'S', 'F', 'N', 'T'});
    put16(out, 8), put16(out, 0);
    out.insert(out.end(), names.begin(), names.end());
    size_t data_start = (out.size() + align - 1) / align * align;
    if (data_start < 0x100 && align < 0x100) data_start = (out.size() + 0xFF) & ~(size_t)0xFF;
    out.resize(data_start, 0);
    out.insert(out.end(), data.begin(), data.end());
    set32(out, 8, (uint32_t)out.size());
    set32(out, 0xC, (uint32_t)data_start);
    return out;
}

// ------------------------------------------------------------------ BYML (v2 / v3, little-endian)
struct Node;
typedef std::shared_ptr<Node> NodeP;
struct Node {
    uint8_t type = 0xFF;   // A0 string, C0 array, C1 hash, D0 bool, D1 int, D2 float, D3 uint, D4 i64, D5 u64, D6 f64, FF null
    std::string str;
    uint64_t num = 0;      // (ints, floats as their bits)
    std::vector<NodeP> arr;
    std::vector<std::pair<std::string, NodeP>> hash;   // (kept sorted by key when written)
    NodeP get(const std::string &k) const {
        for (auto &e : hash) if (e.first == k) return e.second;
        return NULL;
    }
    void set(const std::string &k, NodeP v) {
        for (auto &e : hash) if (e.first == k) { e.second = v; return; }
        hash.push_back({k, v});
    }
};
static NodeP clone(const NodeP &n) {
    NodeP c = std::make_shared<Node>(*n);
    for (auto &e : c->arr) e = clone(e);
    for (auto &e : c->hash) e.second = clone(e.second);
    return c;
}
static NodeP mkstr(const std::string &s) { NodeP n = std::make_shared<Node>(); n->type = 0xA0; n->str = s; return n; }
static NodeP mkuint(uint32_t v) { NodeP n = std::make_shared<Node>(); n->type = 0xD3; n->num = v; return n; }
static NodeP mkint(int32_t v) { NodeP n = std::make_shared<Node>(); n->type = 0xD1; n->num = (uint32_t)v; return n; }
static NodeP mkfloat(float f) { NodeP n = std::make_shared<Node>(); n->type = 0xD2; uint32_t u; memcpy(&u, &f, 4); n->num = u; return n; }
static float getfloat(const NodeP &n) {
    if (!n) return 0;
    if (n->type == 0xD2) { float f; uint32_t u = (uint32_t)n->num; memcpy(&f, &u, 4); return f; }
    if (n->type == 0xD1) return (float)(int32_t)n->num;
    return (float)n->num;
}

struct BymlReader {
    const Bytes &b;
    std::vector<std::string> keys, strs;
    uint16_t version = 2;
    explicit BymlReader(const Bytes &d) : b(d) {}
    std::vector<std::string> table(uint32_t off) {
        std::vector<std::string> out;
        if (!off) return out;
        if (off + 4 > b.size() || b[off] != 0xC2) fail("BYML string table damaged");
        uint32_t n = rd24(&b[off + 1]);
        for (uint32_t i = 0; i < n; i++) {
            uint32_t s = off + rd32(&b[off + 4 + 4 * i]);
            std::string str;
            while (s < b.size() && b[s]) str += (char)b[s++];
            out.push_back(str);
        }
        return out;
    }
    NodeP value(uint8_t type, uint32_t raw) {
        NodeP n = std::make_shared<Node>();
        n->type = type;
        switch (type) {
        case 0xA0: if (raw >= strs.size()) fail("BYML string index out of range"); n->str = strs[raw]; break;
        case 0xC0: case 0xC1: return node(raw);
        case 0xD0: case 0xD1: case 0xD2: case 0xD3: n->num = raw; break;
        case 0xD4: case 0xD5: case 0xD6:
            if (raw + 8 > b.size()) fail("BYML 64-bit value out of range");
            n->num = (uint64_t)rd32(&b[raw]) | (uint64_t)rd32(&b[raw + 4]) << 32;
            break;
        case 0xFF: break;
        default: fail("BYML node type " + std::to_string(type) + " not known");
        }
        return n;
    }
    NodeP node(uint32_t off) {
        if (off + 4 > b.size()) fail("BYML node out of range");
        NodeP n = std::make_shared<Node>();
        n->type = b[off];
        uint32_t count = rd24(&b[off + 1]);
        if (n->type == 0xC0) {
            uint32_t vals = off + 4 + ((count + 3) & ~3u);
            for (uint32_t i = 0; i < count; i++) n->arr.push_back(value(b[off + 4 + i], rd32(&b[vals + 4 * i])));
        } else if (n->type == 0xC1) {
            for (uint32_t i = 0; i < count; i++) {
                const uint8_t *e = &b[off + 4 + 8 * i];
                uint32_t k = rd24(e);
                if (k >= keys.size()) fail("BYML key index out of range");
                n->hash.push_back({keys[k], value(e[3], rd32(e + 4))});
            }
        } else fail("BYML root isn't a container");
        return n;
    }
    NodeP read() {
        if (b.size() < 16 || memcmp(b.data(), "YB", 2)) fail("not a little-endian BYML");
        version = rd16(&b[2]);
        if (version < 2 || version > 4) fail("BYML version " + std::to_string(version) + " not known");
        keys = table(rd32(&b[4]));
        strs = table(rd32(&b[8]));
        return node(rd32(&b[12]));
    }
};

struct BymlWriter {
    std::vector<std::string> keys, strs;
    std::map<std::string, uint32_t> kix, six;
    Bytes out;
    void collect(const NodeP &n) {
        if (n->type == 0xA0) strs.push_back(n->str);
        for (auto &e : n->arr) collect(e);
        for (auto &e : n->hash) keys.push_back(e.first), collect(e.second);
    }
    static void uniq(std::vector<std::string> &v) { std::sort(v.begin(), v.end()); v.erase(std::unique(v.begin(), v.end()), v.end()); }
    void write_table(const std::vector<std::string> &t) {
        size_t start = out.size();
        out.push_back(0xC2), put24(out, (uint32_t)t.size());
        size_t offs = out.size();
        for (size_t i = 0; i <= t.size(); i++) put32(out, 0);
        for (size_t i = 0; i < t.size(); i++) {
            set32(out, offs + 4 * i, (uint32_t)(out.size() - start));
            out.insert(out.end(), t[i].begin(), t[i].end());
            out.push_back(0);
        }
        set32(out, offs + 4 * t.size(), (uint32_t)(out.size() - start));
        pad_to(out, 4);
    }
    bool container(uint8_t t) { return t == 0xC0 || t == 0xC1; }
    bool wide(uint8_t t) { return t == 0xD4 || t == 0xD5 || t == 0xD6; }
    // writes a container; returns its offset. Children containers and 64-bit values after it.
    uint32_t write_node(const NodeP &n) {
        pad_to(out, 4);
        uint32_t at = (uint32_t)out.size();
        std::vector<std::pair<std::string, NodeP>> entries = n->hash;
        if (n->type == 0xC1)
            std::sort(entries.begin(), entries.end(), [](const auto &a, const auto &b) { return a.first < b.first; });
        std::vector<std::pair<size_t, NodeP>> later;   // (value slots to fill with an offset)
        out.push_back(n->type);
        if (n->type == 0xC0) {
            put24(out, (uint32_t)n->arr.size());
            for (auto &e : n->arr) out.push_back(e->type);
            pad_to(out, 4);
            for (auto &e : n->arr) {
                if (container(e->type) || wide(e->type)) later.push_back({out.size(), e}), put32(out, 0);
                else put32(out, inline_value(e));
            }
        } else {
            put24(out, (uint32_t)entries.size());
            for (auto &e : entries) {
                put24(out, kix[e.first]);
                out.push_back(e.second->type);
                if (container(e.second->type) || wide(e.second->type)) later.push_back({out.size(), e.second}), put32(out, 0);
                else put32(out, inline_value(e.second));
            }
        }
        for (auto &l : later) {
            uint32_t off;
            if (wide(l.second->type)) {
                pad_to(out, 4);
                off = (uint32_t)out.size();
                put32(out, (uint32_t)l.second->num), put32(out, (uint32_t)(l.second->num >> 32));
            } else off = write_node(l.second);
            set32(out, l.first, off);
        }
        return at;
    }
    uint32_t inline_value(const NodeP &n) {
        if (n->type == 0xA0) return six[n->str];
        return (uint32_t)n->num;
    }
    Bytes write(const NodeP &root, uint16_t version) {
        collect(root);
        uniq(keys), uniq(strs);
        for (size_t i = 0; i < keys.size(); i++) kix[keys[i]] = (uint32_t)i;
        for (size_t i = 0; i < strs.size(); i++) six[strs[i]] = (uint32_t)i;
        out = {'Y', 'B'};
        put16(out, version), put32(out, 0), put32(out, 0), put32(out, 0);
        if (!keys.empty()) set32(out, 4, (uint32_t)out.size()), write_table(keys);
        if (!strs.empty()) set32(out, 8, (uint32_t)out.size()), write_table(strs);
        uint32_t r = write_node(root);
        set32(out, 12, r);
        return out;
    }
};
static NodeP byml_read(const Bytes &b, uint16_t *version) {
    BymlReader r(b);
    NodeP n = r.read();
    if (version) *version = r.version;
    return n;
}
static Bytes byml_write(const NodeP &n, uint16_t version) { BymlWriter w; return w.write(n, version); }

// ------------------------------------------------------------------ AAMP (read in place, for numbers)
// The root list: after the 0x30-byte header and the type name ("xml\0"...), whose length the header gives at 0x14
static size_t aamp_root(const Bytes &b) { return 0x30 + (size_t)rd32(&b[0x14]); }
// The parameter `param` of the object `obj` (anywhere in the tree), as a pointer into the file; type out
[[maybe_unused]] static uint8_t *aamp_find(Bytes &b, const std::string &obj, const std::string &param, uint8_t *type) {
    if (b.size() < 0x30 || memcmp(b.data(), "AAMP", 4)) return NULL;
    uint32_t ho = crc32(obj), hp = crc32(param);
    std::function<uint8_t *(size_t)> list = [&](size_t at) -> uint8_t * {
        if (at + 12 > b.size()) return (uint8_t *)NULL;
        size_t lists = at + (size_t)rd16(&b[at + 4]) * 4, objs = at + (size_t)rd16(&b[at + 8]) * 4;
        uint16_t nl = rd16(&b[at + 6]), no = rd16(&b[at + 10]);
        for (int i = 0; i < no; i++) {
            size_t o = objs + (size_t)i * 8;
            if (o + 8 > b.size()) break;
            if (rd32(&b[o]) != ho) continue;
            size_t ps = o + (size_t)rd16(&b[o + 4]) * 4;
            for (int k = 0; k < rd16(&b[o + 6]); k++) {
                size_t p = ps + (size_t)k * 8;
                if (p + 8 > b.size()) break;
                if (rd32(&b[p]) != hp) continue;
                size_t d = p + (size_t)rd24(&b[p + 4]) * 4;
                if (d + 4 > b.size()) return (uint8_t *)NULL;
                *type = b[p + 7];
                return &b[d];
            }
        }
        for (int i = 0; i < nl; i++) if (uint8_t *r = list(lists + (size_t)i * 12)) return r;
        return (uint8_t *)NULL;
    };
    return list(aamp_root(b));
}
// AAMP read whole and written again (values may share their bytes in the file - two parameters of 40 at one offset -
// so they're changed in this tree, never in place)
struct AParam {
    uint32_t h;
    uint8_t type;
    Bytes data;   // (a string's text without its 0; a buffer's elements without their count)
};
struct AObj {
    uint32_t h;
    std::vector<AParam> params;
};
struct AList {
    uint32_t h;
    std::vector<AList> lists;
    std::vector<AObj> objs;
};
struct Aamp {
    uint32_t version, flags, pio_version;
    Bytes type_name;   // ("xml\0", as in the file: padded)
    AList root;
};
static bool aamp_is_string(uint8_t t) { return t == 7 || t == 8 || t == 15 || t == 20; }
static bool aamp_is_buffer(uint8_t t) { return t == 13 || t == 14 || t == 18 || t == 19; }
static size_t aamp_fixed_size(uint8_t t) {
    switch (t) {
    case 0: case 1: case 2: case 17: return 4;
    case 3: return 8;
    case 4: return 12;
    case 5: case 6: case 16: return 16;
    case 9: return 0x80; case 10: return 0x100; case 11: return 0x180; case 12: return 0x200;
    default: return 0;
    }
}
static Aamp aamp_read(const Bytes &b) {
    if (b.size() < 0x30 || memcmp(b.data(), "AAMP", 4)) fail("not an AAMP parameter file");
    Aamp a;
    a.version = rd32(&b[4]), a.flags = rd32(&b[8]), a.pio_version = rd32(&b[0x10]);
    if (a.version != 2 || !(a.flags & 1)) fail("an AAMP parameter file not of the Switch's kind");
    size_t root = aamp_root(b);
    if (root + 12 > b.size()) fail("AAMP parameter file cut short");
    a.type_name.assign(b.begin() + 0x30, b.begin() + root);
    auto need = [&](size_t at, size_t n) { if (at + n > b.size()) fail("AAMP parameter file damaged"); };
    std::function<AList(size_t, int)> list = [&](size_t at, int depth) -> AList {
        need(at, 12);
        if (depth > 32) fail("AAMP parameter file too deep");
        AList l;
        l.h = rd32(&b[at]);
        size_t lists = at + (size_t)rd16(&b[at + 4]) * 4, objs = at + (size_t)rd16(&b[at + 8]) * 4;
        for (int i = 0; i < rd16(&b[at + 6]); i++) l.lists.push_back(list(lists + (size_t)i * 12, depth + 1));
        for (int i = 0; i < rd16(&b[at + 10]); i++) {
            size_t o = objs + (size_t)i * 8;
            need(o, 8);
            AObj ob;
            ob.h = rd32(&b[o]);
            size_t ps = o + (size_t)rd16(&b[o + 4]) * 4;
            for (int k = 0; k < rd16(&b[o + 6]); k++) {
                size_t p = ps + (size_t)k * 8;
                need(p, 8);
                AParam pr;
                pr.h = rd32(&b[p]), pr.type = b[p + 7];
                size_t d = p + (size_t)rd24(&b[p + 4]) * 4;
                if (aamp_is_string(pr.type)) {
                    size_t e = d;
                    while (e < b.size() && b[e]) e++;
                    need(d, e - d);
                    pr.data.assign(b.begin() + d, b.begin() + e);
                } else if (aamp_is_buffer(pr.type)) {
                    need(d - 4, 4);
                    size_t n = (size_t)rd32(&b[d - 4]) * (pr.type == 19 ? 1 : 4);
                    need(d, n);
                    pr.data.assign(b.begin() + d, b.begin() + d + n);
                } else {
                    size_t n = aamp_fixed_size(pr.type);
                    if (!n) fail("AAMP parameter type " + std::to_string(pr.type) + " not known");
                    need(d, n);
                    pr.data.assign(b.begin() + d, b.begin() + d + n);
                }
                ob.params.push_back(pr);
            }
            l.objs.push_back(ob);
        }
        return l;
    };
    a.root = list(root, 0);
    return a;
}
static Bytes aamp_write(const Aamp &a) {
    // lists (breadth first: each list's children side by side), then objects, parameters, data, strings
    std::vector<const AList *> lists = {&a.root};
    for (size_t i = 0; i < lists.size(); i++) for (auto &c : lists[i]->lists) lists.push_back(&c);
    std::vector<size_t> first_child(lists.size()), first_obj(lists.size());
    std::vector<const AObj *> objs;
    for (size_t i = 0, next = 1; i < lists.size(); i++) {
        first_child[i] = next, next += lists[i]->lists.size();
        first_obj[i] = objs.size();
        for (auto &o : lists[i]->objs) objs.push_back(&o);
    }
    std::vector<size_t> first_param(objs.size());
    std::vector<const AParam *> params;
    for (size_t i = 0; i < objs.size(); i++) {
        first_param[i] = params.size();
        for (auto &p : objs[i]->params) params.push_back(&p);
    }
    size_t tn = (a.type_name.size() + 3) & ~(size_t)3;
    size_t lists_at = 0x30 + tn, objs_at = lists_at + lists.size() * 12, params_at = objs_at + objs.size() * 8,
           data_at = params_at + params.size() * 8;
    Bytes data, strs;
    std::vector<size_t> where(params.size());
    for (size_t i = 0; i < params.size(); i++) {
        const AParam &p = *params[i];
        if (aamp_is_string(p.type)) continue;
        if (aamp_is_buffer(p.type)) put32(data, (uint32_t)(p.data.size() / (p.type == 19 ? 1 : 4)));
        where[i] = data_at + data.size();
        data.insert(data.end(), p.data.begin(), p.data.end());
        pad_to(data, 4);
    }
    size_t strs_at = data_at + data.size();
    for (size_t i = 0; i < params.size(); i++) {
        const AParam &p = *params[i];
        if (!aamp_is_string(p.type)) continue;
        where[i] = strs_at + strs.size();
        strs.insert(strs.end(), p.data.begin(), p.data.end());
        strs.push_back(0);
        pad_to(strs, 4);
    }
    Bytes out(0x30, 0);
    memcpy(out.data(), "AAMP", 4);
    set32(out, 4, a.version), set32(out, 8, a.flags), set32(out, 0x10, a.pio_version), set32(out, 0x14, (uint32_t)tn);
    set32(out, 0x18, (uint32_t)lists.size()), set32(out, 0x1C, (uint32_t)objs.size()), set32(out, 0x20, (uint32_t)params.size());
    set32(out, 0x24, (uint32_t)data.size()), set32(out, 0x28, (uint32_t)strs.size()), set32(out, 0x2C, 0);
    out.insert(out.end(), a.type_name.begin(), a.type_name.end());
    out.resize(0x30 + tn, 0);
    auto rel = [](size_t to, size_t from) {
        if (to < from || (to - from) / 4 > 0xFFFF) fail("AAMP parameter file too big to write");
        return (uint16_t)((to - from) / 4);
    };
    for (size_t i = 0; i < lists.size(); i++) {
        size_t at = lists_at + i * 12;
        put32(out, lists[i]->h);
        put16(out, lists[i]->lists.empty() ? 0 : rel(lists_at + first_child[i] * 12, at));
        put16(out, (uint16_t)lists[i]->lists.size());
        put16(out, lists[i]->objs.empty() ? 0 : rel(objs_at + first_obj[i] * 8, at));
        put16(out, (uint16_t)lists[i]->objs.size());
    }
    for (size_t i = 0; i < objs.size(); i++) {
        size_t at = objs_at + i * 8;
        put32(out, objs[i]->h);
        put16(out, objs[i]->params.empty() ? 0 : rel(params_at + first_param[i] * 8, at));
        put16(out, (uint16_t)objs[i]->params.size());
    }
    for (size_t i = 0; i < params.size(); i++) {
        size_t at = params_at + i * 8;
        put32(out, params[i]->h);
        size_t r = (where[i] - at) / 4;
        if (r > 0xFFFFFF) fail("AAMP parameter file too big to write");
        put24(out, (uint32_t)r);
        out.push_back(params[i]->type);
    }
    out.insert(out.end(), data.begin(), data.end());
    out.insert(out.end(), strs.begin(), strs.end());
    set32(out, 0xC, (uint32_t)out.size());
    return out;
}
static void aamp_each(AList &l, const std::function<void(AObj &)> &f) {
    for (auto &o : l.objs) f(o);
    for (auto &c : l.lists) aamp_each(c, f);
}
static AParam *aamp_param(Aamp &a, const std::string &obj, const std::string &param) {
    AParam *found = NULL;
    uint32_t ho = crc32(obj), hp = crc32(param);
    aamp_each(a.root, [&](AObj &o) {
        if (o.h == ho) for (auto &p : o.params) if (p.h == hp && !found) found = &p;
    });
    return found;
}
static bool aamp_tree_scale(Aamp &a, const std::string &obj, const std::string &param, float k, float add, bool only_if_positive) {
    AParam *p = aamp_param(a, obj, param);
    if (!p || p->data.size() < 4) return false;
    if (p->type == 1) {
        float f; memcpy(&f, p->data.data(), 4);
        if (only_if_positive && f <= 0) return true;
        f = f * k + add; memcpy(p->data.data(), &f, 4);
        return true;
    }
    if (p->type == 2 || p->type == 17) {
        int32_t v; memcpy(&v, p->data.data(), 4);
        if (only_if_positive && v <= 0) return true;
        v = (int32_t)lroundf(v * k + add); memcpy(p->data.data(), &v, 4);
        return true;
    }
    return false;
}
static std::string aamp_text(const AParam &p) { return std::string(p.data.begin(), p.data.end()); }
static void aamp_set_text(AParam &p, const std::string &t) { p.data.assign(t.begin(), t.end()); }

static std::string replace_str(std::string s, const std::string &from, const std::string &to) {
    for (size_t at = s.find(from); at != std::string::npos; at = s.find(from, at + to.size())) s.replace(at, from.size(), to);
    return s;
}

// ------------------------------------------------------------------ MSBT
struct Msbt {
    std::vector<std::string> labels;      // (label i -> string index idx[i])
    std::vector<uint32_t> idx;
    std::vector<std::u16string> texts;
    Bytes atr_entries;                    // (count x entry size)
    Bytes atr_extra;                      // (what follows the entries: their strings)
    uint32_t atr_size = 0;
    uint32_t buckets = 101;
    Bytes header_rest;                    // (sections other than these three, kept as they are)
    std::vector<std::pair<std::string, Bytes>> other;
    std::vector<std::string> order;       // section order
    uint8_t encoding = 1, version = 3;
};
static uint32_t msbt_hash(const std::string &l, uint32_t n) {
    uint32_t h = 0;
    for (unsigned char c : l) h = h * 0x492 + c;
    return h % n;
}
static Msbt msbt_read(const Bytes &b) {
    if (b.size() < 0x20 || memcmp(b.data(), "MsgStdBn", 8)) fail("not an MSBT");
    if (rd16(&b[8]) != 0xFEFF) fail("a big-endian MSBT");
    Msbt m;
    m.encoding = b[0xC], m.version = b[0xD];
    if (m.encoding != 1) fail("MSBT not in UTF-16");
    uint16_t nsec = rd16(&b[0xE]);
    size_t at = 0x20;
    for (int s = 0; s < nsec; s++) {
        if (at + 16 > b.size()) fail("MSBT section out of range");
        std::string magic((const char *)&b[at], 4);
        uint32_t size = rd32(&b[at + 4]);
        size_t d = at + 16;
        if (d + size > b.size()) fail("MSBT section cut short");
        m.order.push_back(magic);
        if (magic == "LBL1") {
            m.buckets = rd32(&b[d]);
            std::vector<std::pair<uint32_t, std::string>> found;
            for (uint32_t k = 0; k < m.buckets; k++) {
                uint32_t cnt = rd32(&b[d + 4 + 8 * k]), off = rd32(&b[d + 8 + 8 * k]);
                size_t p = d + off;
                for (uint32_t j = 0; j < cnt; j++) {
                    uint8_t len = b[p];
                    std::string l((const char *)&b[p + 1], len);
                    uint32_t i = rd32(&b[p + 1 + len]);
                    found.push_back({i, l});
                    p += 1 + len + 4;
                }
            }
            for (auto &f : found) m.labels.push_back(f.second), m.idx.push_back(f.first);
        } else if (magic == "ATR1") {
            uint32_t cnt = rd32(&b[d]);
            m.atr_size = rd32(&b[d + 4]);
            size_t e = d + 8, end = e + (size_t)cnt * m.atr_size;
            m.atr_entries.assign(b.begin() + e, b.begin() + end);
            m.atr_extra.assign(b.begin() + end, b.begin() + d + size);
        } else if (magic == "TXT2") {
            uint32_t cnt = rd32(&b[d]);
            for (uint32_t i = 0; i < cnt; i++) {
                uint32_t s0 = rd32(&b[d + 4 + 4 * i]), s1 = i + 1 < cnt ? rd32(&b[d + 8 + 4 * i]) : size;
                std::u16string t;
                for (size_t p = d + s0; p + 1 < d + s1; p += 2) t.push_back((char16_t)rd16(&b[p]));
                if (!t.empty() && t.back() == 0) t.pop_back();   // (its terminator; a tag's zero parameter stays)
                m.texts.push_back(t);
            }
        } else m.other.push_back({magic, Bytes(b.begin() + d, b.begin() + d + size)});
        at = (d + size + 15) & ~(size_t)15;
    }
    return m;
}
static Bytes msbt_write(const Msbt &m) {
    Bytes out = {'M', 's', 'g', 'S', 't', 'd', 'B', 'n'};
    put16(out, 0xFEFF), put16(out, 0);
    out.push_back(m.encoding), out.push_back(m.version);
    put16(out, (uint16_t)m.order.size()), put16(out, 0), put32(out, 0);
    while (out.size() < 0x20) out.push_back(0);
    auto section = [&](const char *magic, const Bytes &d) {
        out.insert(out.end(), magic, magic + 4);
        put32(out, (uint32_t)d.size());
        for (int i = 0; i < 8; i++) out.push_back(0);
        out.insert(out.end(), d.begin(), d.end());
        pad_to(out, 16, 0xAB);
    };
    for (const std::string &s : m.order) {
        Bytes d;
        if (s == "LBL1") {
            std::vector<std::vector<size_t>> bk(m.buckets);
            for (size_t i = 0; i < m.labels.size(); i++) bk[msbt_hash(m.labels[i], m.buckets)].push_back(i);
            put32(d, m.buckets);
            size_t table = d.size();
            for (uint32_t k = 0; k < m.buckets; k++) put32(d, 0), put32(d, 0);
            for (uint32_t k = 0; k < m.buckets; k++) {
                set32(d, table + 8 * k, (uint32_t)bk[k].size());
                set32(d, table + 8 * k + 4, (uint32_t)d.size());
                for (size_t i : bk[k]) {
                    d.push_back((uint8_t)m.labels[i].size());
                    d.insert(d.end(), m.labels[i].begin(), m.labels[i].end());
                    put32(d, m.idx[i]);
                }
            }
        } else if (s == "ATR1") {
            put32(d, m.atr_size ? (uint32_t)(m.atr_entries.size() / m.atr_size) : (uint32_t)m.texts.size());
            put32(d, m.atr_size);
            d.insert(d.end(), m.atr_entries.begin(), m.atr_entries.end());
            d.insert(d.end(), m.atr_extra.begin(), m.atr_extra.end());
        } else if (s == "TXT2") {
            put32(d, (uint32_t)m.texts.size());
            size_t table = d.size();
            for (size_t i = 0; i < m.texts.size(); i++) put32(d, 0);
            for (size_t i = 0; i < m.texts.size(); i++) {
                set32(d, table + 4 * i, (uint32_t)d.size());
                for (char16_t c : m.texts[i]) put16(d, c);
                put16(d, 0);
            }
        } else {
            for (auto &o : m.other) if (o.first == s) d = o.second;
        }
        section(s.c_str(), d);
    }
    set32(out, 0x12, (uint32_t)out.size());
    return out;
}
static std::u16string u16(const std::string &s) { std::u16string r; for (unsigned char c : s) r.push_back(c); return r; }

// ------------------------------------------------------------------ RSTB
// The size table holds, per file (by its name's CRC32, or by name where two collide), the memory the game sets aside
// to load it. Each changed or new file gets an entry: its source's (the Master Sword's, or the file's own) grown as the
// file did, with room to spare - never smaller than it was.
struct RstbWant {
    std::string name, from;   // (name: the entry; from: whose size to start from)
    double grow;              // (new size / source size)
};
static Bytes rstb_update(const Bytes &b, const std::vector<RstbWant> &want, int *set) {
    if (b.size() < 12 || memcmp(b.data(), "RSTB", 4)) fail("not a resource size table");
    uint32_t ncrc = rd32(&b[4]), nname = rd32(&b[8]);
    size_t crc_at = 12, name_at = crc_at + (size_t)ncrc * 8;
    if (name_at + (size_t)nname * 132 > b.size()) fail("resource size table cut short");
    std::map<uint32_t, uint32_t> crcs;
    std::map<std::string, uint32_t> names;
    for (uint32_t i = 0; i < ncrc; i++) crcs[rd32(&b[crc_at + 8 * i])] = rd32(&b[crc_at + 8 * i + 4]);
    for (uint32_t i = 0; i < nname; i++) {
        const char *n = (const char *)&b[name_at + 132 * i];
        names[std::string(n, strnlen(n, 128))] = rd32(&b[name_at + 132 * i + 128]);
    }
    auto lookup = [&](const std::string &n, uint32_t *v) {
        if (names.count(n)) return *v = names[n], true;
        if (crcs.count(crc32(n))) return *v = crcs[crc32(n)], true;
        return false;
    };
    for (auto &w : want) {
        if (w.grow < 0) {   // (out of the table: the game works its size out itself - as mods do for the actor list)
            if (crcs.erase(crc32(w.name)) + names.erase(w.name)) (*set)++;
            continue;
        }
        uint32_t src;
        if (!lookup(w.from, &src)) continue;   // (no entry to start from: the game works it out)
        uint32_t old = 0;
        bool had = lookup(w.name, &old);
        double v = std::max((double)src * w.grow * 1.1 + 0x1000, (double)std::max(src, old));
        uint32_t nv = (uint32_t)std::min(v, 4.0e9);
        nv = (nv + 31) & ~31u;
        if (had && names.count(w.name)) names[w.name] = nv;
        else crcs[crc32(w.name)] = nv;
        (*set)++;
    }
    Bytes out = {'R', 'S', 'T', 'B'};
    put32(out, (uint32_t)crcs.size()), put32(out, (uint32_t)names.size());
    for (auto &c : crcs) put32(out, c.first), put32(out, c.second);   // (std::map: sorted by CRC, as the game looks up)
    for (auto &n : names) {
        size_t at = out.size();
        out.resize(at + 128, 0);
        memcpy(&out[at], n.first.data(), std::min<size_t>(n.first.size(), 127));
        put32(out, n.second);
    }
    return out;
}
// "Actor/Pack/X.sbactorpack" -> "Actor/Pack/X.bactorpack" (the table names files as they are decompressed)
static std::string rstb_name(const std::string &p) {
    size_t dot = p.rfind('.');
    if (dot != std::string::npos && dot + 1 < p.size() && p[dot + 1] == 's') return p.substr(0, dot + 1) + p.substr(dot + 2);
    return p;
}

// ------------------------------------------------------------------ its look: the models (BFRES) and textures (BNTX)
// (WSword 0.2.8-slate.32) A copy of each of the Master Sword's models, made white and glowing white:
//  - the colour textures (<model>_Alb, BC1): every 4x4 block's two end colours mapped to white - the mapping is the
//    same for every colour, so the blocks' own mixes of them follow and the detail stays (no re-encoding, no layout);
//  - the blade's material: its glow colour (const_color0, the Master Sword's sky blue 0, 0.6, 1) white;
//  - with its glow animations (<model>_LightOn / _LightOff_fsp - the glow's strength, const_value1: near evil a flash
//    to 100 settling at 30, and back to 0): those held at the steady 30, and the material's own strength 30 - it always
//    glows.
// Layouts read from the game's own files (Switch BFRES v0.5: FMAT +0x58 the parameters (0x20 each: +8 name, +0x10
// type, +0x12 the value's offset), +0x68 their values, +0xaa their count; FMAA +0x10 name, +0x28 its material
// animations (+0x20 their curves: +0 frames, +8 keys, +0x10 flags, +0x12 key count, +0x20 scale, +0x24 offset, +0x28
// delta; cubic f32 keys, four coefficients each); BNTX: NX +8 the textures (BRTI: +0x1c format, +0x50 size, +0x60
// name, +0x70 the levels' offsets)), checked as they're read.
struct LookFail {};
static const char kFMAA[] = "FMAA", kFMAT[] = "FMAT", kBNTX[] = "BNTX";
static uint64_t rd64(const uint8_t *p) { return (uint64_t)rd32(p) | (uint64_t)rd32(p + 4) << 32; }
static std::string bfres_name(const Bytes &b, uint64_t p) {   // (a string of the file's pool: u16 length, then text)
    if (p + 2 > b.size()) throw LookFail{};
    size_t n = rd16(&b[p]);
    if (p + 2 + n > b.size()) throw LookFail{};
    return std::string((const char *)&b[p + 2], n);
}
static float rdf(const Bytes &b, size_t at) { float f; memcpy(&f, &b[at], 4); return f; }
static void wrf(Bytes &b, size_t at, float f) { memcpy(&b[at], &f, 4); }
// The model: white glow; always_on - full strength held. Returns how many materials were changed.
static int look_model(Bytes &b, bool always_on) {
    if (b.size() < 0x100 || memcmp(b.data(), "FRES    ", 8)) throw LookFail{};
    int changed = 0;
    float full = 0;   // (the glow's strength when on, from its animations)
    // the glow animations: their curves held at their highest value
    for (size_t a = 0; (a = std::search(b.begin() + a, b.end(), kFMAA, kFMAA + 4) - b.begin()) + 0x70 < b.size(); a += 4) {
        std::string name;
        try { name = bfres_name(b, rd64(&b[a + 0x10])); } catch (const LookFail &) { continue; }
        if (name.find("_Light") == std::string::npos) continue;
        uint64_t ma = rd64(&b[a + 0x28]);
        if (!ma || ma + 0x28 > b.size()) continue;
        uint64_t cv = rd64(&b[ma + 0x20]);
        if (!cv || cv + 0x2c > b.size()) continue;
        uint16_t flags = rd16(&b[cv + 0x10]), nkeys = rd16(&b[cv + 0x12]);
        uint64_t keys = rd64(&b[cv + 8]);
        // (cubic, f32 keys: flags' bits 2-3 and 4-6 zero)
        if ((flags & 0x7c) || !nkeys || nkeys > 64 || keys + (size_t)nkeys * 16 > b.size()) continue;
        // (the glow held: its steady value - LightOn flashes to 100 and settles at 30, LightOff starts at 30 and fades
        // out - the larger of a curve's first and last key's)
        float scale = rdf(b, cv + 0x20), offset = rdf(b, cv + 0x24);
        float hi = std::max(rdf(b, keys), rdf(b, keys + (size_t)(nkeys - 1) * 16));
        if (!(hi > 0 && hi < 1000)) continue;
        full = std::max(full, offset + scale * hi);
        if (!always_on) continue;
        for (int k = 0; k < nkeys; k++) {
            wrf(b, keys + k * 16, hi);
            for (int c = 1; c < 4; c++) wrf(b, keys + k * 16 + c * 4, 0);
        }
        wrf(b, cv + 0x28, 0);   // (no change from end to start)
    }
    // the materials
    for (size_t m = 0; (m = std::search(b.begin() + m, b.end(), kFMAT, kFMAT + 4) - b.begin()) + 0xb0 < b.size(); m += 4) {
        uint64_t arr = rd64(&b[m + 0x58]), data = rd64(&b[m + 0x68]);
        uint16_t count = rd16(&b[m + 0xaa]);
        if (!arr || !data || !count || count > 512 || arr + (size_t)count * 0x20 > b.size() || data >= b.size()) continue;
        size_t color = 0, strength = 0;
        for (int k = 0; k < count; k++) {
            size_t e = arr + (size_t)k * 0x20;
            std::string n;
            try { n = bfres_name(b, rd64(&b[e + 8])); } catch (const LookFail &) { break; }
            uint8_t type = b[e + 0x10];
            size_t at = data + rd16(&b[e + 0x12]);
            if (n == "const_color0" && type == 15 && at + 16 <= b.size()) color = at;
            if (n == "const_value1" && type == 12 && at + 4 <= b.size()) strength = at;
        }
        // (the blade's: its glow colour not white - the Master Sword's sky blue)
        if (!color || (rdf(b, color) > 0.99f && rdf(b, color + 4) > 0.99f && rdf(b, color + 8) > 0.99f)) continue;
        for (int c = 0; c < 3; c++) wrf(b, color + c * 4, 1.0f);
        if (always_on && strength && full > 0) wrf(b, strength, full);
        changed++;
    }
    if (!changed) throw LookFail{};
    return changed;
}
// The textures: the colour ones (<name>_Alb, BC1) white. Returns how many.
static int look_textures(Bytes &b) {
    size_t base = std::search(b.begin(), b.end(), kBNTX, kBNTX + 4) - b.begin();
    if (base + 0x40 > b.size() || memcmp(&b[base + 0x20], "NX  ", 4)) throw LookFail{};
    uint32_t count = rd32(&b[base + 0x24]);
    uint64_t tab = rd64(&b[base + 0x28]);
    if (count > 256 || base + tab + count * 8 > b.size()) throw LookFail{};
    // white, the detail kept: a colour's brightness (0..1) onto 192..255, neutral - green (6 bits) the 5-bit red and
    // blue's own value, so no block tints apart from its neighbours
    auto white = [](uint16_t c) {
        int r = (c >> 11 & 31) * 255 / 31, g = (c >> 5 & 63) * 255 / 63, bl = (c & 31) * 255 / 31;
        float l = (0.299f * r + 0.587f * g + 0.114f * bl) / 255.0f, v = 192 + 63 * l;
        int q = (int)lroundf(v * 31 / 255), v8 = q << 3 | q >> 2, G = (int)lroundf(v8 * 63 / 255.0f);
        return (uint16_t)(q << 11 | G << 5 | q);
    };
    int done = 0;
    for (uint32_t i = 0; i < count; i++) {
        size_t t = base + rd64(&b[base + tab + i * 8]);
        if (t + 0x78 > b.size() || memcmp(&b[t], "BRTI", 4)) throw LookFail{};
        uint32_t fmt = rd32(&b[t + 0x1c]), size = rd32(&b[t + 0x50]);
        std::string name = bfres_name(b, base + rd64(&b[t + 0x60]));
        size_t levels = base + rd64(&b[t + 0x70]);
        if (levels + 8 > b.size()) throw LookFail{};
        size_t data = base + rd64(&b[levels]);
        if ((fmt != 0x1a01 && fmt != 0x1a06) || name.size() < 4 || name.compare(name.size() - 4, 4, "_Alb")) continue;
        if (data + size > b.size() || size % 8) throw LookFail{};
        for (size_t o = data; o < data + size; o += 8) {   // (every level's blocks: the mapping is the same anywhere)
            uint16_t c0 = rd16(&b[o]), c1 = rd16(&b[o + 2]);
            uint32_t idx = rd32(&b[o + 4]);
            bool four = c0 > c1;   // (four colours; else three and transparent - kept so)
            uint16_t n0 = white(c0), n1 = white(c1);
            if (four && n0 <= n1) {
                if (n0 == n1) {   // (one colour now: every texel it, the ends kept apart - four colours need c0 > c1)
                    idx = 0;
                    if (n0 < 0xFFFF) n0++;
                    else n1--;
                } else {   // (the order swapped: the indices with it - 0<->1, 2<->3)
                    std::swap(n0, n1);
                    idx ^= 0x55555555u;
                }
            } else if (!four && n0 > n1) {
                std::swap(n0, n1);   // (0<->1; 2, the middle, and 3, transparent, stay)
                uint32_t x = 0;
                for (int k = 0; k < 16; k++) {
                    uint32_t v = idx >> (2 * k) & 3;
                    x |= (v < 2 ? v ^ 1 : v) << (2 * k);
                }
                idx = x;
            }
            b[o] = n0 & 255, b[o + 1] = n0 >> 8, b[o + 2] = n1 & 255, b[o + 3] = n1 >> 8;
            for (int k = 0; k < 4; k++) b[o + 4 + k] = idx >> (8 * k) & 255;
        }
        done++;
    }
    if (!done) throw LookFail{};
    return done;
}

// The inventory picture (UI/StockItem/<name>.sbitemico: BNTX, one RGBA8 picture, 96 x 96 in the Switch's block-linear
// layout): the sword white, a soft white glow around it.
// Block-linear: 64-byte x 8-row GOBs, in columns of `bh` GOBs (the picture's block height, smaller for short levels).
static size_t bl_addr(size_t x, size_t y, size_t wgobs, size_t bpb, size_t bh) {
    size_t xb = x * bpb;
    size_t gob = (y / (8 * bh)) * 512 * bh * wgobs + (xb / 64) * 512 * bh + ((y % (8 * bh)) / 8) * 512;
    return gob + ((xb % 64) / 32) * 256 + ((y % 8) / 2) * 64 + ((xb % 32) / 16) * 32 + (y % 2) * 16 + (xb % 16);
}
// An inventory picture's RGBA8 levels: each picture of the BNTX (RGBA8 / its sRGB form) read whole into straight-alpha
// 0..1 pixels, changed by `fn`, and written back - the first level as made, every smaller one from the one above
// (alpha-weighted 2 x 2 averages), so whichever level the game draws shows the change. The number changed.
static size_t mip_bh(size_t hb, size_t bh);  // (below: a level's block height)
template <class F> static int icon_edit(Bytes &b, F fn) {
    size_t base = std::search(b.begin(), b.end(), kBNTX, kBNTX + 4) - b.begin();
    if (base + 0x40 > b.size() || memcmp(&b[base + 0x20], "NX  ", 4)) throw LookFail{};
    uint32_t count = rd32(&b[base + 0x24]);
    uint64_t tab = rd64(&b[base + 0x28]);
    if (count > 16 || base + tab + count * 8 > b.size()) throw LookFail{};
    int done = 0;
    for (uint32_t i = 0; i < count; i++) {
        size_t t = base + rd64(&b[base + tab + i * 8]);
        if (t + 0x78 > b.size() || memcmp(&b[t], "BRTI", 4)) throw LookFail{};
        uint32_t fmt = rd32(&b[t + 0x1c]), w = rd32(&b[t + 0x24]), h = rd32(&b[t + 0x28]), size = rd32(&b[t + 0x50]);
        uint16_t mips = rd16(&b[t + 0x16]), tile = rd16(&b[t + 0x12]);
        size_t bh0 = 1u << std::min<uint32_t>(rd32(&b[t + 0x34]), 5);
        size_t levels = base + rd64(&b[t + 0x70]);
        if (!mips) mips = 1;
        if ((fmt != 0x0b01 && fmt != 0x0b06) || tile != 0 || !w || !h || w > 1024 || h > 1024 || mips > 11 ||
            levels + 8 * mips > b.size())
            continue;
        size_t first = base + rd64(&b[levels]), end = first + size;
        if (end > b.size()) throw LookFail{};
        auto level_at = [&](int m, size_t *lend) {
            size_t d = base + rd64(&b[levels + 8 * m]);
            *lend = m + 1 < mips ? base + rd64(&b[levels + 8 * (m + 1)]) : end;
            if (d < first || *lend > end || *lend <= d) throw LookFail{};
            return d;
        };
        std::vector<float> px((size_t)w * h * 4);   // (0..1, straight alpha)
        {
            size_t lend, data = level_at(0, &lend), wgobs = (w * 4 + 63) / 64, bh = mip_bh(h, bh0);
            if (data + bl_addr(w - 1, h - 1, wgobs, 4, bh) + 4 > lend) throw LookFail{};
            for (uint32_t y = 0; y < h; y++)
                for (uint32_t x = 0; x < w; x++)
                    for (int c = 0; c < 4; c++) px[((size_t)y * w + x) * 4 + c] = b[data + bl_addr(x, y, wgobs, 4, bh) + c] / 255.0f;
        }
        fn(px, w, h);
        uint32_t lw = w, lh = h;
        for (int m = 0; m < mips; m++) {
            size_t lend, data = level_at(m, &lend), wgobs = (lw * 4 + 63) / 64, bh = mip_bh(lh, bh0);
            if (data + bl_addr(lw - 1, lh - 1, wgobs, 4, bh) + 4 > lend) break;   // (a level laid out otherwise: left as it is)
            for (uint32_t y = 0; y < lh; y++)
                for (uint32_t x = 0; x < lw; x++)
                    for (int c = 0; c < 4; c++)
                        b[data + bl_addr(x, y, wgobs, 4, bh) + c] =
                            (uint8_t)lroundf(std::min(1.0f, std::max(0.0f, px[((size_t)y * lw + x) * 4 + c])) * 255);
            uint32_t nw = std::max(1u, lw / 2), nh = std::max(1u, lh / 2);
            std::vector<float> nxt((size_t)nw * nh * 4);
            for (uint32_t y = 0; y < nh; y++)
                for (uint32_t x = 0; x < nw; x++) {
                    float s[4] = {0, 0, 0, 0};
                    for (int dy = 0; dy < 2; dy++)
                        for (int dx = 0; dx < 2; dx++) {
                            const float *q = &px[((size_t)std::min(lh - 1, y * 2 + dy) * lw + std::min(lw - 1, x * 2 + dx)) * 4];
                            for (int c = 0; c < 3; c++) s[c] += q[c] * q[3];
                            s[3] += q[3];
                        }
                    float *o = &nxt[((size_t)y * nw + x) * 4];
                    for (int c = 0; c < 3; c++) o[c] = s[3] > 0 ? s[c] / s[3] : 0;
                    o[3] = s[3] / 4;
                }
            px.swap(nxt), lw = nw, lh = nh;
        }
        done++;
    }
    if (!done) throw LookFail{};
    return done;
}

// A picture's alpha blurred (three box passes each way, radius r): a soft halo around what is drawn
static std::vector<float> alpha_blur(const std::vector<float> &px, uint32_t w, uint32_t h, int r) {
    std::vector<float> a((size_t)w * h), tmp(a.size());
    for (size_t k = 0; k < a.size(); k++) a[k] = px[k * 4 + 3];
    for (int pass = 0; pass < 3; pass++)
        for (int dir = 0; dir < 2; dir++) {
            for (uint32_t y = 0; y < h; y++)
                for (uint32_t x = 0; x < w; x++) {
                    float sum = 0;
                    int n = 0;
                    for (int d = -r; d <= r; d++) {
                        int xx = (int)x + (dir ? 0 : d), yy = (int)y + (dir ? d : 0);
                        if (xx < 0 || yy < 0 || xx >= (int)w || yy >= (int)h) continue;
                        sum += a[(size_t)yy * w + xx], n++;
                    }
                    tmp[(size_t)y * w + x] = sum / n;
                }
            a.swap(tmp);
        }
    return a;
}

// The WSword's inventory picture: the sword white, glowing white (0.2.8-slate.40: the glow sized by the picture - a
// fixed 3 texels left it a hair's width once the inventory drew the picture smaller - a bright halo close in and a
// wide soft one, like the Master Sword's blue)
static int look_icon(Bytes &b) {
    return icon_edit(b, [](std::vector<float> &px, uint32_t w, uint32_t h) {
        int r = std::max(3, (int)(std::min(w, h) / 22));
        std::vector<float> wide = alpha_blur(px, w, h, r), near = alpha_blur(px, w, h, std::max(1, r / 3));
        for (size_t k = 0; k < wide.size(); k++) {
            float *p = &px[k * 4];
            float l = 0.299f * p[0] + 0.587f * p[1] + 0.114f * p[2], v = 0.88f + 0.12f * l;   // (white, its shading kept)
            float g = std::min(1.0f, std::max(std::min(1.0f, near[k] * 2.2f) * 0.95f, std::min(1.0f, wide[k] * 2.6f) * 0.8f));
            float sa = p[3], oa = sa + g * (1 - sa);
            for (int c = 0; c < 3; c++) p[c] = oa > 0 ? (v * sa + 1.0f * g * (1 - sa)) / oa : 1;
            p[3] = oa;
        }
    });
}

// The Nintendo Switch Shirt's inventory picture (UI/StockItem/Armor_170_Upper.sbitemico) made the WSword shirt's, as
// its model (look_shirt): the fabric the emblem's navy, its shading kept; the Switch logo - found by its colours, the
// neon red and blue on a dark shirt - covered by the emblem, its edges faded in; the outline (alpha) as it was.
static int look_shirt_icon(Bytes &b, const std::vector<uint8_t> &emb, int ew, int eh, float nr, float ng, float nb) {
    return icon_edit(b, [&](std::vector<float> &px, uint32_t w, uint32_t h) {
        auto lum = [](const float *p) { return 0.299f * p[0] + 0.587f * p[1] + 0.114f * p[2]; };
        auto chroma = [](const float *p) { return std::max(p[0], std::max(p[1], p[2])) - std::min(p[0], std::min(p[1], p[2])); };
        // the shirt's extent, its fabric's brightness (the median of its grey texels), and the logo's (coloured) texels
        uint32_t sx0 = w, sy0 = h, sx1 = 0, sy1 = 0, lx0 = w, ly0 = h, lx1 = 0, ly1 = 0;
        std::vector<float> ls;
        int nlogo = 0;
        for (uint32_t y = 0; y < h; y++)
            for (uint32_t x = 0; x < w; x++) {
                const float *p = &px[((size_t)y * w + x) * 4];
                if (p[3] < 0.5f) continue;
                sx0 = std::min(sx0, x), sy0 = std::min(sy0, y), sx1 = std::max(sx1, x), sy1 = std::max(sy1, y);
                if (chroma(p) > 0.28f) { lx0 = std::min(lx0, x), ly0 = std::min(ly0, y), lx1 = std::max(lx1, x), ly1 = std::max(ly1, y); nlogo++; }
                else ls.push_back(lum(p));
            }
        if (sx1 <= sx0 || sy1 <= sy0) throw LookFail{};
        float base_l = 0.2f;
        if (!ls.empty()) {
            std::nth_element(ls.begin(), ls.begin() + ls.size() / 2, ls.end());
            base_l = std::max(0.02f, ls[ls.size() / 2]);
        }
        float shirt_w = (float)(sx1 - sx0 + 1), shirt_h = (float)(sy1 - sy0 + 1);
        // where the emblem goes: the logo's middle (a logo of a few texels or a far-flung one: the chest's)
        float cx, cy, side;
        bool logo = nlogo >= 12 && (lx1 - lx0 + 1) < shirt_w * 0.7f && (ly1 - ly0 + 1) < shirt_h * 0.7f;
        if (logo) {
            cx = (lx0 + lx1 + 1) * 0.5f, cy = (ly0 + ly1 + 1) * 0.5f;
            side = std::max((float)(lx1 - lx0 + 1), (float)(ly1 - ly0 + 1)) * 1.7f;
        } else {
            cx = (sx0 + sx1 + 1) * 0.5f, cy = sy0 + shirt_h * 0.38f, side = shirt_w * 0.34f;
        }
        side = std::min(std::max(side, shirt_w * 0.28f), shirt_w * 0.45f);
        for (uint32_t y = 0; y < h; y++)
            for (uint32_t x = 0; x < w; x++) {
                float *p = &px[((size_t)y * w + x) * 4];
                if (p[3] <= 0) continue;
                float k = std::min(1.8f, std::max(0.35f, lum(p) / base_l));
                float u = (x + 0.5f - (cx - side / 2)) / side, v = (y + 0.5f - (cy - side / 2)) / side;
                bool in = u >= 0 && v >= 0 && u < 1 && v < 1;
                if (in || chroma(p) > 0.28f) k = 1.0f;   // (the logo's texels: the plain fabric under the emblem)
                p[0] = nr * k, p[1] = ng * k, p[2] = nb * k;
                if (!in) continue;
                float edge = std::min(std::min(u, 1 - u), std::min(v, 1 - v)), a = std::min(1.0f, edge / 0.2f);
                a = a * a * (3 - 2 * a);
                float fx = u * ew - 0.5f, fy = v * eh - 0.5f;
                int x0 = std::max(0, std::min(ew - 1, (int)floorf(fx))), y0 = std::max(0, std::min(eh - 1, (int)floorf(fy)));
                int x1 = std::min(ew - 1, x0 + 1), y1 = std::min(eh - 1, y0 + 1);
                float tx = std::min(1.0f, std::max(0.0f, fx - x0)), ty = std::min(1.0f, std::max(0.0f, fy - y0));
                for (int ch = 0; ch < 3; ch++) {
                    float p00 = emb[((size_t)y0 * ew + x0) * 4 + ch], p10 = emb[((size_t)y0 * ew + x1) * 4 + ch];
                    float p01 = emb[((size_t)y1 * ew + x0) * 4 + ch], p11 = emb[((size_t)y1 * ew + x1) * 4 + ch];
                    float e = ((p00 * (1 - tx) + p10 * tx) * (1 - ty) + (p01 * (1 - tx) + p11 * tx) * ty) / 255.0f;
                    p[ch] = p[ch] * (1 - a) + e * a;
                }
            }
    });
}

// ------------------------------------------------------------------ the WSword shirt (0.2.8-slate.34)
// The Nintendo Switch Shirt (Armor_170_Upper: Model/Armor_170.Tex.sbfres, its colour picture Armor_170_Upper_Alb -
// BC1, 512 x 512, ten levels) made the WSword's: dark navy (its shading kept), the two Nintendo marks covered, the
// WSword's emblem (the app's own picture, shipped: res/wsword-emblem.png) printed on the chest. The picture is decoded
// whole, changed, and encoded again (BC1, each level from the one above).
struct Rgba { float r, g, b; };
static void bc1_decode_block(const uint8_t *blk, Rgba out[16]) {
    uint16_t c0 = rd16(blk), c1 = rd16(blk + 2);
    uint32_t idx = rd32(blk + 4);
    auto col = [](uint16_t c) { return Rgba{(c >> 11 & 31) * 255.0f / 31, (c >> 5 & 63) * 255.0f / 63, (c & 31) * 255.0f / 31}; };
    Rgba p[4] = {col(c0), col(c1), {}, {}};
    if (c0 > c1) {
        p[2] = {(2 * p[0].r + p[1].r) / 3, (2 * p[0].g + p[1].g) / 3, (2 * p[0].b + p[1].b) / 3};
        p[3] = {(p[0].r + 2 * p[1].r) / 3, (p[0].g + 2 * p[1].g) / 3, (p[0].b + 2 * p[1].b) / 3};
    } else {
        p[2] = {(p[0].r + p[1].r) / 2, (p[0].g + p[1].g) / 2, (p[0].b + p[1].b) / 2};
        p[3] = {0, 0, 0};
    }
    for (int i = 0; i < 16; i++) out[i] = p[idx >> (2 * i) & 3];
}
static uint16_t to565(Rgba c) {
    auto q = [](float v, int m) { return (int)lroundf(std::min(255.0f, std::max(0.0f, v)) * m / 255); };
    return (uint16_t)(q(c.r, 31) << 11 | q(c.g, 63) << 5 | q(c.b, 31));
}
static void bc1_encode_block(const Rgba in[16], uint8_t *blk) {
    // the two ends: along the colours' main direction (their bounding box's diagonal, oriented by covariance), inset
    Rgba lo = in[0], hi = in[0], mean = {0, 0, 0};
    for (int i = 0; i < 16; i++) {
        lo.r = std::min(lo.r, in[i].r), lo.g = std::min(lo.g, in[i].g), lo.b = std::min(lo.b, in[i].b);
        hi.r = std::max(hi.r, in[i].r), hi.g = std::max(hi.g, in[i].g), hi.b = std::max(hi.b, in[i].b);
        mean.r += in[i].r / 16, mean.g += in[i].g / 16, mean.b += in[i].b / 16;
    }
    float crg = 0, cbg = 0;
    for (int i = 0; i < 16; i++) crg += (in[i].r - mean.r) * (in[i].g - mean.g), cbg += (in[i].b - mean.b) * (in[i].g - mean.g);
    if (crg < 0) std::swap(lo.r, hi.r);
    if (cbg < 0) std::swap(lo.b, hi.b);
    Rgba d = {(hi.r - lo.r) / 16, (hi.g - lo.g) / 16, (hi.b - lo.b) / 16};
    Rgba e0 = {hi.r - d.r, hi.g - d.g, hi.b - d.b}, e1 = {lo.r + d.r, lo.g + d.g, lo.b + d.b};
    uint16_t c0 = to565(e0), c1 = to565(e1);
    if (c0 == c1) {   // (one colour: every texel the first, four-colour kept - c0 > c1)
        if (c0 < 0xFFFF) c0++; else c1--;
        blk[0] = c0 & 255, blk[1] = c0 >> 8, blk[2] = c1 & 255, blk[3] = c1 >> 8;
        blk[4] = blk[5] = blk[6] = blk[7] = 0;
        return;
    }
    if (c0 < c1) std::swap(c0, c1);
    Rgba p[4];
    uint8_t b0[2] = {(uint8_t)(c0 & 255), (uint8_t)(c0 >> 8)}, b1[2] = {(uint8_t)(c1 & 255), (uint8_t)(c1 >> 8)};
    uint8_t probe[8] = {b0[0], b0[1], b1[0], b1[1], 0xE4, 0, 0, 0};   // (indices 0,1,2,3: the palette as decoded)
    Rgba dec[16];
    bc1_decode_block(probe, dec);
    for (int k = 0; k < 4; k++) p[k] = dec[k];
    uint32_t idx = 0;
    for (int i = 0; i < 16; i++) {
        int best = 0;
        float bd = 1e30f;
        for (int k = 0; k < 4; k++) {
            float dr = in[i].r - p[k].r, dg = in[i].g - p[k].g, db = in[i].b - p[k].b, dd = dr * dr + dg * dg * 1.5f + db * db;
            if (dd < bd) bd = dd, best = k;
        }
        idx |= (uint32_t)best << (2 * i);
    }
    blk[0] = b0[0], blk[1] = b0[1], blk[2] = b1[0], blk[3] = b1[1];
    for (int k = 0; k < 4; k++) blk[4 + k] = idx >> (8 * k) & 255;
}
// A BC1 level <-> pixels (block-linear: blocks of 8 bytes; `bh` the level's block height in GOBs)
static size_t mip_bh(size_t hb, size_t bh) {
    while (bh > 1 && hb <= bh * 8 / 2) bh /= 2;
    return bh;
}
static std::vector<Rgba> bc1_read_level(const Bytes &b, size_t data, uint32_t w, uint32_t h, size_t bh0) {
    size_t wb = (w + 3) / 4, hb = (h + 3) / 4, bh = mip_bh(hb, bh0), wgobs = (wb * 8 + 63) / 64;
    std::vector<Rgba> px((size_t)wb * 4 * hb * 4);
    Rgba blk[16];
    for (size_t y = 0; y < hb; y++)
        for (size_t x = 0; x < wb; x++) {
            size_t a = data + bl_addr(x, y, wgobs, 8, bh);
            if (a + 8 > b.size()) throw LookFail{};
            bc1_decode_block(&b[a], blk);
            for (int i = 0; i < 16; i++) px[(y * 4 + i / 4) * wb * 4 + x * 4 + i % 4] = blk[i];
        }
    return px;
}
static void bc1_write_level(Bytes &b, size_t data, size_t end, const std::vector<Rgba> &px, uint32_t w, uint32_t h, size_t bh0) {
    size_t wb = (w + 3) / 4, hb = (h + 3) / 4, bh = mip_bh(hb, bh0), wgobs = (wb * 8 + 63) / 64;
    Rgba blk[16];
    for (size_t y = 0; y < hb; y++)
        for (size_t x = 0; x < wb; x++) {
            for (int i = 0; i < 16; i++) {
                size_t py = std::min<size_t>(y * 4 + i / 4, h - 1), pxx = std::min<size_t>(x * 4 + i % 4, w - 1);
                blk[i] = px[py * w + pxx];
            }
            size_t a = data + bl_addr(x, y, wgobs, 8, bh);
            if (a + 8 > end) throw LookFail{};
            bc1_encode_block(blk, &b[a]);
        }
}
// (the shirt's colour: the emblem's own night sky - the average of its border - so its edges melt into it; 0..255)
static Rgba emblem_navy(const std::vector<uint8_t> &emb, int ew, int eh) {
    double sr = 0, sg = 0, sb = 0;
    int n = 0;
    for (int y = 0; y < eh; y++)
        for (int x = 0; x < ew; x++) {
            if (x > 8 && y > 8 && x < ew - 9 && y < eh - 9) continue;
            const uint8_t *q = &emb[((size_t)y * ew + x) * 4];
            sr += q[0], sg += q[1], sb += q[2], n++;
        }
    return n ? Rgba{(float)(sr / n), (float)(sg / n), (float)(sb / n)} : Rgba{0, 0, 0};
}
static void look_shirt(Bytes &b, const std::vector<uint8_t> &emb, int ew, int eh) {
    size_t base = std::search(b.begin(), b.end(), kBNTX, kBNTX + 4) - b.begin();
    if (base + 0x40 > b.size() || memcmp(&b[base + 0x20], "NX  ", 4)) throw LookFail{};
    uint32_t count = rd32(&b[base + 0x24]);
    uint64_t tab = rd64(&b[base + 0x28]);
    if (count > 64 || base + tab + count * 8 > b.size()) throw LookFail{};
    for (uint32_t i = 0; i < count; i++) {
        size_t t = base + rd64(&b[base + tab + i * 8]);
        if (t + 0x78 > b.size() || memcmp(&b[t], "BRTI", 4)) throw LookFail{};
        if (bfres_name(b, base + rd64(&b[t + 0x60])) != "Armor_170_Upper_Alb") continue;
        uint32_t fmt = rd32(&b[t + 0x1c]), w = rd32(&b[t + 0x24]), h = rd32(&b[t + 0x28]), size = rd32(&b[t + 0x50]);
        uint16_t mips = rd16(&b[t + 0x16]), tile = rd16(&b[t + 0x12]);
        size_t bh0 = 1u << std::min<uint32_t>(rd32(&b[t + 0x34]), 5), levels = base + rd64(&b[t + 0x70]);
        if ((fmt != 0x1a01 && fmt != 0x1a06) || tile || w != h || w < 64 || w > 2048 || !mips || mips > 12 ||
            levels + 8 * mips > b.size())
            throw LookFail{};
        size_t first = base + rd64(&b[levels]), end = first + size;
        if (end > b.size()) throw LookFail{};
        std::vector<Rgba> px = bc1_read_level(b, first, w, h, bh0);
        size_t pw = (w + 3) / 4 * 4;
        auto at = [&](uint32_t x, uint32_t y) -> Rgba & { return px[(size_t)y * pw + x]; };
        // the shirt's own colour: the median brightness of the picture (its fabric), for the shading
        std::vector<float> ls;
        for (uint32_t y = 0; y < h; y += 4)
            for (uint32_t x = 0; x < w; x += 4) { Rgba c = at(x, y); ls.push_back(0.299f * c.r + 0.587f * c.g + 0.114f * c.b); }
        std::nth_element(ls.begin(), ls.begin() + ls.size() / 2, ls.end());
        float base_l = std::max(1.0f, ls[ls.size() / 2]);
        Rgba navy = emblem_navy(emb, ew, eh);
        auto box = [&](float x0, float y0, float x1, float y1, uint32_t x, uint32_t y) {
            return x >= x0 * w && x < x1 * w && y >= y0 * h && y < y1 * h;
        };
        std::vector<Rgba> out((size_t)w * h);
        for (uint32_t y = 0; y < h; y++)
            for (uint32_t x = 0; x < w; x++) {
                Rgba c = at(x, y);
                float l = 0.299f * c.r + 0.587f * c.g + 0.114f * c.b, k = std::min(1.8f, l / base_l);
                // the two Nintendo marks (the front's logo, the back's tag): the plain fabric there
                if (box(0.17f, 0.18f, 0.54f, 0.55f, x, y) || box(0.24f, 0.85f, 0.45f, 0.93f, x, y)) k = 1.0f;
                out[(size_t)y * w + x] = {navy.r * k, navy.g * k, navy.b * k};
            }
        // the emblem on the chest: centred where the logo was, its edges faded into the shirt
        float cx = 0.352f * w, cy = 0.365f * h, side = 0.37f * w;
        for (uint32_t y = 0; y < h; y++)
            for (uint32_t x = 0; x < w; x++) {
                float u = (x + 0.5f - (cx - side / 2)) / side, v = (y + 0.5f - (cy - side / 2)) / side;
                if (u < 0 || v < 0 || u >= 1 || v >= 1) continue;
                float edge = std::min(std::min(u, 1 - u), std::min(v, 1 - v)), a = std::min(1.0f, edge / 0.2f);
                a = a * a * (3 - 2 * a);
                // (bilinear from the emblem)
                float fx = u * ew - 0.5f, fy = v * eh - 0.5f;
                int x0 = std::max(0, std::min(ew - 1, (int)floorf(fx))), y0 = std::max(0, std::min(eh - 1, (int)floorf(fy)));
                int x1 = std::min(ew - 1, x0 + 1), y1 = std::min(eh - 1, y0 + 1);
                float tx = std::min(1.0f, std::max(0.0f, fx - x0)), ty = std::min(1.0f, std::max(0.0f, fy - y0));
                float e[3];
                for (int ch = 0; ch < 3; ch++) {
                    float p00 = emb[((size_t)y0 * ew + x0) * 4 + ch], p10 = emb[((size_t)y0 * ew + x1) * 4 + ch];
                    float p01 = emb[((size_t)y1 * ew + x0) * 4 + ch], p11 = emb[((size_t)y1 * ew + x1) * 4 + ch];
                    e[ch] = (p00 * (1 - tx) + p10 * tx) * (1 - ty) + (p01 * (1 - tx) + p11 * tx) * ty;
                }
                Rgba &o = out[(size_t)y * w + x];
                o.r = o.r * (1 - a) + e[0] * a, o.g = o.g * (1 - a) + e[1] * a, o.b = o.b * (1 - a) + e[2] * a;
            }
        // every level from the one above (2 x 2 averages), encoded into its place
        uint32_t lw = w, lh = h;
        std::vector<Rgba> lev = out;
        for (int m = 0; m < mips; m++) {
            size_t data = base + rd64(&b[levels + 8 * m]);
            size_t lend = m + 1 < mips ? base + rd64(&b[levels + 8 * (m + 1)]) : end;
            if (data >= end || lend > end || lend <= data) throw LookFail{};
            bc1_write_level(b, data, lend, lev, lw, lh, bh0);
            uint32_t nw = std::max(1u, lw / 2), nh = std::max(1u, lh / 2);
            std::vector<Rgba> nxt((size_t)nw * nh);
            for (uint32_t y = 0; y < nh; y++)
                for (uint32_t x = 0; x < nw; x++) {
                    Rgba s = {0, 0, 0};
                    for (int dy = 0; dy < 2; dy++)
                        for (int dx = 0; dx < 2; dx++) {
                            const Rgba &q = lev[(size_t)std::min(lh - 1, y * 2 + dy) * lw + std::min(lw - 1, x * 2 + dx)];
                            s.r += q.r / 4, s.g += q.g / 4, s.b += q.b / 4;
                        }
                    nxt[(size_t)y * nw + x] = s;
                }
            lev.swap(nxt), lw = nw, lh = nh;
        }
        return;
    }
    throw LookFail{};
}

// ------------------------------------------------------------------ the game's files (read only)
struct Rom {
    std::string dir;                       // a romfs/ folder, or
    int fd = -1;                           // an image (romfs.bin)
    std::map<std::string, std::pair<uint64_t, uint64_t>> index;
    bool open(const std::string &root) {
        struct stat st;
        std::string link = root + "/extracted/romfs.link", bin = root + "/extracted/romfs.bin", folder = root + "/extracted/romfs";
        if (FILE *f = fopen(link.c_str(), "rb")) {
            char t[1100] = "";
            size_t n = fread(t, 1, sizeof t - 1, f);
            fclose(f);
            t[n] = 0;
            while (n && (t[n - 1] == '\n' || t[n - 1] == '\r')) t[--n] = 0;
            if (stat(t, &st) == 0 && S_ISDIR(st.st_mode)) { dir = t; return true; }
            return open_image(t);
        }
        if (stat(bin.c_str(), &st) == 0) return open_image(bin);
        if (stat(folder.c_str(), &st) == 0 && S_ISDIR(st.st_mode)) { dir = folder; return true; }
        return false;
    }
    static void each(void *ud, const char *path, uint64_t off, uint64_t size) {
        ((Rom *)ud)->index[path[0] == '/' ? path + 1 : path] = {off, size};
    }
    bool open_image(const std::string &p) {
#ifdef LS_SHIRT_ONLY
        (void)p;
        return false;   // (the PS5: the game files are a folder, extracted/romfs)
#else
        fd = ::open(p.c_str(), O_RDONLY);
        if (fd < 0) return false;
        char why[200];
        return romfs_image_files(fd, each, this, why, sizeof why);
#endif
    }
    bool has(const std::string &p) {
        if (fd >= 0) return index.count(p) > 0;
        struct stat st;
        return stat((dir + "/" + p).c_str(), &st) == 0;
    }
    Bytes read(const std::string &p) {
        Bytes b;
        if (fd >= 0) {
            auto it = index.find(p);
            if (it == index.end()) fail("the game has no " + p);
            b.resize(it->second.second);
            if (pread(fd, b.data(), b.size(), (off_t)it->second.first) != (ssize_t)b.size()) fail("can't read " + p);
        } else {
            FILE *f = fopen((dir + "/" + p).c_str(), "rb");
            if (!f) fail("the game has no " + p);
            fseek(f, 0, SEEK_END);
            b.resize((size_t)ftell(f));
            fseek(f, 0, SEEK_SET);
            if (fread(b.data(), 1, b.size(), f) != b.size()) { fclose(f); fail("can't read " + p); }
            fclose(f);
        }
        return b;
    }
    std::vector<std::string> list(const std::string &prefix) {
        std::vector<std::string> out;
        if (fd >= 0) {
            for (auto &e : index) if (!e.first.compare(0, prefix.size(), prefix)) out.push_back(e.first);
        } else {
            std::string d = dir + "/" + prefix;
            if (DIR *dd = opendir(d.c_str())) {
                while (dirent *e = readdir(dd)) if (e->d_name[0] != '.') out.push_back(prefix + e->d_name);
                closedir(dd);
            }
        }
        return out;
    }
    ~Rom() { if (fd >= 0) close(fd); }
};

// ------------------------------------------------------------------ the mod
[[maybe_unused]] static const char *const kMod = "WSword Sword of Light";
[[maybe_unused]] static const char *const kModDlc = "WSword Sword of Light (DLC 01007EF00011F001)";   // (its map, when the DLC has it)
[[maybe_unused]] static const struct { const char *from, *to; } kNames[] = {
    {"Weapon_Sword_070", "Weapon_Sword_L01"},   // the sword
    {"Weapon_Sword_071", "Weapon_Sword_L02"},   // resting (its light spent)
    {"Weapon_Sword_072", "Weapon_Sword_L03"},   // awakened
};

static std::mutex g_mu;
static std::string g_status;
static std::atomic<bool> g_busy{false};
static void status(const std::string &s) { std::lock_guard<std::mutex> l(g_mu); g_status = s; fprintf(stderr, "[sword of light] %s\n", s.c_str()); }

static bool mkdirs(const std::string &path) {   // the folders of a file's path
    for (size_t at = path.find('/', 1); at != std::string::npos; at = path.find('/', at + 1)) mkdir(path.substr(0, at).c_str(), 0755);
    return true;
}
static void write_file(const std::string &path, const Bytes &b) {
    mkdirs(path);
    FILE *f = fopen(path.c_str(), "wb");
    if (!f) fail("can't write " + path);
    bool ok = b.empty() || fwrite(b.data(), 1, b.size(), f) == b.size();   // (an empty one: AocMainField.pack)
    if (fclose(f) != 0 || !ok) fail("can't write " + path);
}
static void remove_tree(const std::string &p) {
    struct stat st;
    if (lstat(p.c_str(), &st) != 0) return;
    if (S_ISDIR(st.st_mode)) {
        if (DIR *d = opendir(p.c_str())) {
            while (dirent *e = readdir(d)) if (strcmp(e->d_name, ".") && strcmp(e->d_name, "..")) remove_tree(p + "/" + e->d_name);
            closedir(d);
        }
        rmdir(p.c_str());
    } else unlink(p.c_str());
}
static void copy_tree(const std::string &from, const std::string &to) {
    struct stat st;
    if (stat(from.c_str(), &st) != 0) return;
    if (S_ISDIR(st.st_mode)) {
        mkdir(to.c_str(), 0755);
        if (DIR *d = opendir(from.c_str())) {
            while (dirent *e = readdir(d)) if (strcmp(e->d_name, ".") && strcmp(e->d_name, "..")) copy_tree(from + "/" + e->d_name, to + "/" + e->d_name);
            closedir(d);
        }
    } else {
        FILE *a = fopen(from.c_str(), "rb"), *b = fopen(to.c_str(), "wb");
        char buf[65536];
        size_t n;
        while (a && b && (n = fread(buf, 1, sizeof buf, a)) > 0) fwrite(buf, 1, n, b);
        if (a) fclose(a);
        if (b) fclose(b);
    }
}

static std::string g_where;   // (where the sword lies, for the note)
static std::map<std::string, std::string> g_models;        // ("<folder>|<glow>" -> its copy's folder)
static std::map<std::string, std::string> g_actor_model;   // (the copy actor -> its model's folder: ActorInfo's bfres)
static std::string g_look_note;                            // (why its look is the Master Sword's, if it is)
static bool g_shirt;                                       // (the WSword shirt made)
static bool g_shirt_icon;                                  // (its inventory picture too)
static std::string g_shirt_note;                           // (why not)
// A copy of the model folder `f` (Model/<f>.sbfres and its textures, Model/<f>.Tex.sbfres - loose, or in TitleBG.pack),
// white, glowing (always) or not: Model/<f>_WSword[Rest].sbfres. Its folder's name.
static std::string look_copy(Rom &rom, Sarc *title, const std::string &f, bool glow, std::map<std::string, Bytes> &files,
                             std::vector<RstbWant> &sizes) {
    std::string to = f + (glow ? "_WSword" : "_WSwordRest");
    auto get = [&](const std::string &p) {
        if (rom.has(p)) return rom.read(p);
        if (title)
            if (Bytes *b = title->get(p)) return *b;
        throw LookFail{};
    };
    Bytes model = yaz0_decode(get("Model/" + f + ".sbfres")), tex = yaz0_decode(get("Model/" + f + ".Tex.sbfres"));
    look_model(model, glow);
    look_textures(tex);
    files["Model/" + to + ".sbfres"] = yaz0_encode(model);
    files["Model/" + to + ".Tex.sbfres"] = yaz0_encode(tex);
    sizes.push_back({"Model/" + to + ".bfres", "Model/" + f + ".bfres", 1.0});
    sizes.push_back({"Model/" + to + ".Tex.bfres", "Model/" + f + ".Tex.bfres", 1.0});
    return to;
}

#ifndef LS_SHIRT_ONLY
static void make_mod(void) {
    char root_c[1024];
    if (!rt_version_root(rt_game_version(), root_c, sizeof root_c)) fail("no game version set up");
    std::string root = root_c, out = root + "/mods/" + kMod + "/romfs/";
    Rom rom;
    if (!rom.open(root)) fail("the game files aren't set up");
    g_models.clear(), g_actor_model.clear(), g_look_note.clear(), g_shirt_note.clear();
    std::map<std::string, Bytes> files;   // (the mod's files, by their romfs path)
    std::map<std::string, Bytes> dlc_files;   // (the DLC's, for the DLC's mod folder)
    std::vector<RstbWant> sizes;          // (their entries in the resource size table)
    auto grew = [](const Bytes &now, const Bytes &was) { return was.empty() ? 1.0 : (double)now.size() / (double)was.size(); };

    // 1. the three actor packs
    status("Copying the Master Sword...");
    // The game reads these three from Pack/TitleBG.pack (loaded at boot), so that copy first; else the loose one.
    std::unique_ptr<Sarc> title;
    if (rom.has("Pack/TitleBG.pack")) {
        try { title.reset(new Sarc(sarc_read(rom.read("Pack/TitleBG.pack")))); } catch (const Fail &) {}
    }
    // Its parts ("users": parameters, model list, physics...) are named in its actor link, each in the pack named
    // after its user. The copies share them all with the Master Sword but their parameters (GParamUser), which change:
    // those get a name of their own (the game caches resources by path: the same name would share them)
    for (auto &n : kNames) {
        std::string src = std::string("Actor/Pack/") + n.from + ".sbactorpack";
        Bytes packed;
        if (title) {
            if (Bytes *b = title->get(src)) packed = *b;
            else if (Bytes *b2 = title->get(std::string("Actor/Pack/") + n.from + ".bactorpack")) packed = *b2;
        }
        if (packed.empty()) packed = rom.read(src);
        Bytes src_raw = yaz0_decode(packed);
        Sarc pack = sarc_read(src_raw);
        Bytes *link = NULL;
        std::string link_name;
        for (auto &f : pack.files)
            if (f.first.find("ActorLink/") != std::string::npos) link = &f.second, link_name = f.first;
        if (!link) fail(std::string("the pack of ") + n.from + " has no actor link");
        Aamp al = aamp_read(*link);
        AParam *gp = aamp_param(al, "LinkTarget", "GParamUser");
        if (!gp || !aamp_is_string(gp->type)) fail(std::string("the actor link of ") + n.from + " names no parameters");
        std::string old_user = aamp_text(*gp);
        std::string old_path = "Actor/GeneralParamList/" + old_user + ".bgparamlist";
        Bytes *params = pack.get(old_path);
        // (a form without parameters of its own - the awakened one's are "Dummy": copied as it is, its link renamed)
        bool own_params = params && old_user != "Dummy";
        if (!own_params && !strcmp(n.from, "Weapon_Sword_070"))
            fail(std::string("the parameters of ") + n.from + " (" + old_user + ") aren't in its pack");
        std::string new_user = old_user.find(n.from) != std::string::npos ? replace_str(old_user, n.from, n.to) : n.to;
        std::string new_path = "Actor/GeneralParamList/" + new_user + ".bgparamlist";
        Bytes params_was;
        if (own_params) {
            aamp_set_text(*gp, new_user);
            // its parameters: the copies' names for its other forms; stronger, lasting longer, back sooner
            Aamp pl = aamp_read(*params);
            aamp_each(pl.root, [&](AObj &o) {
                for (auto &pr : o.params)
                    if (aamp_is_string(pr.type))
                        for (auto &m : kNames) if (aamp_text(pr) == m.from) aamp_set_text(pr, m.to);
            });
            aamp_tree_scale(pl, "Attack", "Power", 1.0f, 12, true);                   // (+12: 42 for the Master Sword's 30)
            aamp_tree_scale(pl, "General", "Life", 1.5f, 0, false);                   // (lasts half again as long)
            aamp_tree_scale(pl, "MasterSword", "RecoverTime", 0.5f, 0, false);        // (its light back in half the time)
            aamp_tree_scale(pl, "MasterSword", "TrueFormAttackPower", 1.0f, 12, true);
            params_was = *params;
            *params = aamp_write(pl);
        }
        // its look (0.2.8-slate.32): a model list of its own (ModelUser), naming copies of the Master Sword's models made
        // white and glowing white (look_model / look_textures) - the sword and its awakened form always glowing, the
        // resting one not; if any of it can't be made, the Master Sword's look is kept and the note says why
        std::string ml_old, ml_new;
        Bytes ml_made;
        if (AParam *mu = aamp_param(al, "LinkTarget", "ModelUser"); mu && aamp_is_string(mu->type) && aamp_text(*mu) != "Dummy") {
            std::string old_mu = aamp_text(*mu);
            ml_old = "Actor/ModelList/" + old_mu + ".bmodellist";
            Bytes *ml = pack.get(ml_old);
            bool glow = strcmp(n.to, "Weapon_Sword_L02") != 0;
            try {
                if (!ml) throw LookFail{};
                Aamp mla = aamp_read(*ml);
                int folders = 0;
                std::string first;
                aamp_each(mla.root, [&](AObj &o) {
                    for (auto &pr : o.params) {
                        if (pr.h != crc32("Folder") || !aamp_is_string(pr.type)) continue;
                        std::string f = aamp_text(pr), key = f + (glow ? "|1" : "|0");
                        if (f.empty() || f == "Dummy") continue;
                        if (!g_models.count(key)) g_models[key] = look_copy(rom, title.get(), f, glow, files, sizes);
                        aamp_set_text(pr, g_models[key]);
                        if (first.empty()) first = g_models[key];
                        folders++;
                    }
                });
                if (!folders) throw LookFail{};
                ml_new = "Actor/ModelList/" + std::string(n.to) + ".bmodellist";
                ml_made = aamp_write(mla);
                aamp_set_text(*mu, n.to);
                g_actor_model[n.to] = first;
            } catch (const LookFail &) {
                ml_new.clear();
                if (g_look_note.empty()) g_look_note = std::string("its white look couldn't be made from the model of ") + n.from;
            } catch (const Fail &f) {
                ml_new.clear();
                if (g_look_note.empty()) g_look_note = "its white look couldn't be made: " + f.why;
            }
        }
        *link = aamp_write(al);
        if (!ml_new.empty()) {   // (the model list: its own name, its own models)
            for (auto &f : pack.files)
                if (f.first == ml_old) f.first = ml_new, f.second = ml_made;
            sizes.push_back({ml_new, ml_old, 1.2});
        }
        for (auto &f : pack.files) {
            if (f.first == link_name) f.first = "Actor/ActorLink/" + std::string(n.to) + ".bxml";
            else if (own_params && f.first == old_path) f.first = new_path;
        }
        // (the game sizes each file it loads: the renamed ones from the ones they were)
        if (own_params) sizes.push_back({new_path, old_path, grew(*pack.get(new_path), params_was)});
        sizes.push_back({"Actor/ActorLink/" + std::string(n.to) + ".bxml", link_name, 1.3});
        std::string dst = std::string("Actor/Pack/") + n.to + ".sbactorpack";
        Bytes made = sarc_write(pack, 0x80);
        files[dst] = yaz0_encode(made);
        sizes.push_back({rstb_name(dst), rstb_name(src), grew(made, src_raw)});
        // its inventory picture
        std::string ico = std::string("UI/StockItem/") + n.from + ".sbitemico";
        if (rom.has(ico)) {
            std::string to = std::string("UI/StockItem/") + n.to + ".sbitemico";
            files[to] = rom.read(ico);
            try {   // (white, glowing white - 0.2.8-slate.33; else the Master Sword's picture as it is)
                Bytes pic = yaz0_decode(files[to]);
                look_icon(pic);
                files[to] = yaz0_encode(pic);
            } catch (const LookFail &) {
            } catch (const Fail &) {
            }
            sizes.push_back({rstb_name(to), rstb_name(ico), 1.0});
        }
    }

    // 1b. the WSword shirt: the Nintendo Switch Shirt's colour picture made the WSword's (look_shirt), with the app's
    // emblem; without it (or the shirt's files), the sword is made all the same and the note says so
    status("Making the WSword shirt...");
    g_shirt = false, g_shirt_icon = false;
    try {
        char ep[1100];
        if (!rt_resource("wsword-emblem.png", "assets/artwork/wsword-emblem.png", ep, sizeof ep)) throw Fail{"the WSword emblem isn't in the app"};
        int ew, eh, en;
        unsigned char *e = stbi_load(ep, &ew, &eh, &en, 4);
        if (!e) throw Fail{"the WSword emblem can't be read"};
        std::vector<uint8_t> emb(e, e + (size_t)ew * eh * 4);
        stbi_image_free(e);
        const std::string tp = "Model/Armor_170.Tex.sbfres";
        if (!rom.has(tp)) throw Fail{"the game has no Nintendo Switch Shirt"};
        Bytes t = yaz0_decode(rom.read(tp));
        look_shirt(t, emb, ew, eh);
        files[tp] = yaz0_encode(t);   // (the same size decompressed: its size table entry holds)
        g_shirt = true;
        // its inventory picture too (0.2.8-slate.40): the WSword shirt's, not the Switch's logo; else as it was
        const std::string ip = "UI/StockItem/Armor_170_Upper.sbitemico";
        if (rom.has(ip)) {
            try {
                Bytes pic = yaz0_decode(rom.read(ip));
                Rgba nv = emblem_navy(emb, ew, eh);
                look_shirt_icon(pic, emb, ew, eh, nv.r / 255, nv.g / 255, nv.b / 255);
                files[ip] = yaz0_encode(pic);   // (the same size: its size table entry holds)
                g_shirt_icon = true;
            } catch (const LookFail &) {
            } catch (const Fail &) {
            }
        }
    } catch (const LookFail &) {
        g_shirt_note = "the shirt's picture isn't as expected";
    } catch (const Fail &f) {
        g_shirt_note = f.why;
    }

    // 2. the game's list of actors
    status("Adding it to the game's actors...");
    {
        const std::string path = "Actor/ActorInfo.product.sbyml";
        uint16_t ver;
        Bytes was = yaz0_decode(rom.read(path));
        NodeP info = byml_read(was, &ver);
        NodeP actors = info->get("Actors"), hashes = info->get("Hashes");
        if (!actors || !hashes || actors->type != 0xC0 || hashes->type != 0xC0 || actors->arr.size() != hashes->arr.size())
            fail("the game's actor list isn't as expected");
        for (auto &n : kNames) {
            NodeP src;
            for (auto &a : actors->arr) if (a->get("name") && a->get("name")->str == n.from) src = a;
            if (!src) fail(std::string("the game's actor list has no ") + n.from);
            NodeP add = clone(src);
            add->set("name", mkstr(n.to));
            auto bump = [&](const char *k, float mul, int plus) {   // (its copy of the stats: what the inventory shows)
                NodeP v = add->get(k);
                if (v && v->type == 0xD1 && (plus == 0 || (int32_t)v->num > 0))   // (a resting form's 0 attack stays)
                    v->num = (uint32_t)(int32_t)lroundf((float)(int32_t)v->num * mul + plus);
            };
            if (g_actor_model.count(n.to) && add->get("bfres")) add->set("bfres", mkstr(g_actor_model[n.to]));   // (its model)
            bump("attackPower", 1.0f, 12);
            bump("generalLife", 1.5f, 0);
            bump("masterSwordTrueFormAttackPower", 1.0f, 12);
            uint32_t h = crc32(n.to);
            size_t at = 0;
            while (at < hashes->arr.size() && (uint32_t)hashes->arr[at]->num < h) at++;
            if (at < hashes->arr.size() && (uint32_t)hashes->arr[at]->num == h) continue;   // (there already)
            actors->arr.insert(actors->arr.begin() + at, add);
            hashes->arr.insert(hashes->arr.begin() + at, h > 0x7FFFFFFFu ? mkuint(h) : mkint((int32_t)h));
        }
        Bytes made = byml_write(info, ver);
        files[path] = yaz0_encode(made);
        sizes.push_back({rstb_name(path), rstb_name(path), -1});
        (void)grew(made, was);
    }

    // 3. its name, in every language the game has
    status("Naming it...");
    for (const std::string &pk : rom.list("Pack/")) {
        if (pk.find("Pack/Bootup_") != 0 || pk.size() < 17 || pk.compare(pk.size() - 5, 5, ".pack")) continue;
        std::string lang = pk.substr(12, pk.size() - 12 - 5);   // ("USen", "EUfr"...)
        if (lang.size() != 4) continue;
        Sarc boot = sarc_read(rom.read(pk));
        std::string inner = "Message/Msg_" + lang + ".product.ssarc";
        Bytes *msg = boot.get(inner);
        if (!msg) continue;
        Bytes ms_was = yaz0_decode(*msg);
        Sarc ms = sarc_read(ms_was);
        bool done = false;
        for (auto &f : ms.files) {
            if (f.first.find(".msbt") == std::string::npos) continue;
            Msbt m = msbt_read(f.second);
            bool has = false, shirt = false;
            for (auto &l : m.labels) {
                if (!l.compare(0, 17, "Weapon_Sword_070_")) has = true;
                if (g_shirt && !l.compare(0, 16, "Armor_170_Upper_")) shirt = true;
            }
            if (shirt) {   // (the WSword shirt's name and description, in place)
                for (size_t i = 0; i < m.labels.size(); i++) {
                    if (m.labels[i] == "Armor_170_Upper_Name") m.texts[m.idx[i]] = u16("WSword Shirt");
                    else if (m.labels[i] == "Armor_170_Upper_Desc" || m.labels[i] == "Armor_170_Upper_PictureBook")
                        m.texts[m.idx[i]] = u16("A shirt bearing the WSword's emblem:\n"
                                                "the sword of light, wrapped in\n"
                                                "blooming flowers under a starry sky.\n"
                                                "Wear it with pride!");
                }
                if (!has) {
                    f.second = msbt_write(m);
                    done = true;
                    continue;
                }
            }
            if (!has) continue;
            size_t nl = m.labels.size();
            for (size_t i = 0; i < nl; i++) {
                for (auto &n : kNames) {
                    std::string pre = std::string(n.from) + "_";
                    if (m.labels[i].compare(0, pre.size(), pre)) continue;
                    std::string what = m.labels[i].substr(pre.size());
                    std::u16string text = m.texts[m.idx[i]];
                    bool awake = !strcmp(n.to, "Weapon_Sword_L03"), rest = !strcmp(n.to, "Weapon_Sword_L02");
                    (void)awake;
                    // (the game's own layout: four lines of about 40 characters, as the Master Sword's)
                    if (what == "Name") text = u16("WSword");
                    else if (what == "Desc" || what == "PictureBook")
                        text = u16(rest ? "The WSword's light is spent, and its\n"
                                          "blade has gone dim and cold. Give it\n"
                                          "time to rest, and its radiance will\n"
                                          "return to the blade in full."
                                        : "A blade of pure white light, born of the\n"
                                          "WSword itself. Each strike spends its\n"
                                          "radiance; give it time to rest, and the\n"
                                          "light will flood back into the blade.");
                    uint32_t si = m.idx[i];
                    m.labels.push_back(std::string(n.to) + "_" + what);
                    m.idx.push_back((uint32_t)m.texts.size());
                    m.texts.push_back(text);
                    if (m.atr_size && !m.atr_extra.empty()) {   // (entries with strings after them: their offsets move)
                        size_t cnt = m.atr_entries.size() / m.atr_size, sec = 8 + m.atr_entries.size() + m.atr_extra.size();
                        bool offsets = m.atr_size >= 4;
                        for (size_t e = 0; e < cnt && offsets; e++) {
                            uint32_t o = rd32(&m.atr_entries[e * m.atr_size]);
                            offsets = o >= 8 + m.atr_entries.size() && o < sec;
                        }
                        if (!offsets) fail("the game's message attributes aren't as expected");
                        for (size_t e = 0; e < cnt; e++)
                            set32(m.atr_entries, e * m.atr_size, rd32(&m.atr_entries[e * m.atr_size]) + m.atr_size);
                    }
                    if (m.atr_size) {   // (its attributes: the Master Sword's)
                        size_t a = (size_t)si * m.atr_size;
                        if (a + m.atr_size <= m.atr_entries.size())
                            m.atr_entries.insert(m.atr_entries.end(), m.atr_entries.begin() + a, m.atr_entries.begin() + a + m.atr_size);
                        else m.atr_entries.resize(m.atr_entries.size() + m.atr_size, 0);
                    }
                }
            }
            f.second = msbt_write(m);
            done = true;
        }
        if (!done) continue;
        Bytes ms_made = sarc_write(ms, 0x80);
        *msg = yaz0_encode(ms_made);
        files[pk] = sarc_write(boot, 0x2000);
        sizes.push_back({rstb_name(inner), rstb_name(inner), grew(ms_made, ms_was)});
    }

    // 3b. its save data: each item has flags of its own (IsGet_<name>, EquipTime_<name>, PorchTime_<name>,
    // PictureBookSize_<name>...) in Pack/Bootup.pack's GameData/gamedata.ssarc, and their place in the save in
    // GameData/savedataformat.ssarc: the Master Sword's, copied for the new names
    status("Adding its save data...");
    {
        const std::string pk = "Pack/Bootup.pack";
        Sarc boot = sarc_read(rom.read(pk));
        auto own = [&](const std::string &dn, const char **to) {   // ("<Prefix>_Weapon_Sword_07x" -> the copy's name)
            for (auto &n : kNames) {
                size_t l = strlen(n.from);
                if (dn.size() > l && dn[dn.size() - l - 1] == '_' && !dn.compare(dn.size() - l, l, n.from)) { *to = n.to; return n.from; }
            }
            return (const char *)NULL;
        };
        int added = 0;
        for (const char *inner : {"GameData/gamedata.ssarc", "GameData/savedataformat.ssarc"}) {
            Bytes *packed = boot.get(inner);
            if (!packed) fail(std::string("the game has no ") + inner);
            Bytes was = yaz0_decode(*packed);
            Sarc g = sarc_read(was);
            bool save = strstr(inner, "savedataformat") != NULL;
            struct Table { size_t file; NodeP list; };   // (one list of entries in one of its files)
            std::vector<NodeP> roots;
            std::vector<uint16_t> vers;
            std::map<std::string, std::vector<NodeP>> fresh;   // (by table: "bool_data"... or a save file's name)
            std::map<std::string, Table> roomiest;             // (each table's file with the fewest entries)
            std::map<std::string, bool> have;
            for (size_t fi = 0; fi < g.files.size(); fi++) {
                uint16_t ver = 2;
                NodeP r = byml_read(g.files[fi].second, &ver);
                roots.push_back(r), vers.push_back(ver);
                for (auto &t : r->hash) {
                    if (t.second->type != 0xC0) continue;
                    NodeP list = t.second;
                    std::string key = t.first;
                    if (save) {   // ({file_list: [{file_name...}, [entries]]})
                        if (t.first != "file_list" || list->arr.size() < 2 || list->arr[0]->type != 0xC1 || list->arr[1]->type != 0xC0)
                            continue;
                        NodeP fn = list->arr[0]->get("file_name");
                        key = fn ? fn->str : "";
                        list = list->arr[1];
                    }
                    for (auto &e : list->arr) {
                        NodeP dn = e->type == 0xC1 ? e->get("DataName") : NULL;
                        if (!dn || dn->type != 0xA0) continue;
                        have[dn->str] = true;
                        const char *to;
                        if (const char *from = own(dn->str, &to)) {
                            NodeP c = clone(e);
                            std::string name = dn->str.substr(0, dn->str.size() - strlen(from)) + to;
                            c->set("DataName", mkstr(name));
                            c->set("HashValue", mkint((int32_t)crc32(name)));
                            fresh[key].push_back(c);
                        }
                    }
                    auto it = roomiest.find(key);
                    if (it == roomiest.end() || list->arr.size() < it->second.list->arr.size()) roomiest[key] = {fi, list};
                }
            }
            std::vector<bool> dirty(g.files.size());
            for (auto &kv : fresh)
                for (auto &c : kv.second) {
                    std::string dn = c->get("DataName")->str;
                    if (have[dn]) continue;   // (there already: made before, or the game has it)
                    Table &t = roomiest[kv.first];
                    t.list->arr.push_back(c), dirty[t.file] = true, have[dn] = true, added++;
                }
            for (size_t fi = 0; fi < g.files.size(); fi++)
                if (dirty[fi]) g.files[fi].second = byml_write(roots[fi], vers[fi]);
            Bytes made = sarc_write(g, 0x80);
            *packed = yaz0_encode(made);
            std::string rn = rstb_name(inner);   // (GameData/gamedata.sarc...)
            sizes.push_back({rn, rn, grew(made, was)});
        }
        if (!added) fail("the game's save data has no flags for the Master Sword");
        files[pk] = sarc_write(boot, 0x2000);
    }

    // 4. on the Great Plateau, inside the Shrine of Resurrection: a new chest in the chamber where Link wakes, just in
    // front of where travelling there puts him (Map/MainField/Static.smubin's StartPos "StartPoint_Start");
    // a copy of a chest of the plateau's, the sword in it. Without that spot: beside the chest nearest the plateau's
    // middle (or, with no chest, the sword beside a weapon lying there).
    status("Placing it on the Great Plateau...");
    {
        Rom dlc;   // (the DLC has its own copies of the map: with it set up, the game reads those)
        const char *aoc = fs_aoc_image();
        bool have_dlc = aoc && dlc.open_image(aoc);
        auto find_unit = [&](std::string p, bool *in_dlc) {   // (the DLC's copy first; "" when neither has it)
            *in_dlc = false;
            if (have_dlc)
                for (auto &e : dlc.index)
                    if (e.first.size() >= p.size() && !e.first.compare(e.first.size() - p.size(), p.size(), p) &&
                        (e.first.size() == p.size() || e.first[e.first.size() - p.size() - 1] == '/')) {
                        *in_dlc = true;
                        return e.first;
                    }
            return rom.has(p) ? p : std::string();
        };
        // where the game starts
        bool start_found = false;
        float sx = 0, sy = 0, sz = 0, srot = 0;
        std::string start_sec;
        {
            // (the field's start positions: loose on some versions; on the Switch's, inside Pack/Bootup.pack)
            bool d;
            std::string sp = find_unit("Map/MainField/Static.smubin", &d);
            Bytes raw;
            try {
                if (!sp.empty()) raw = d ? dlc.read(sp) : rom.read(sp);
                else if (rom.has("Pack/Bootup.pack")) {
                    Sarc boot = sarc_read(rom.read("Pack/Bootup.pack"));
                    if (Bytes *b = boot.get("Map/MainField/Static.smubin")) raw = *b;
                }
            } catch (const Fail &) {}
            if (!raw.empty()) {
                try {
                    NodeP st = byml_read(yaz0_decode(raw), NULL);
                    NodeP list = st->get("StartPos");
                    if (list && list->type == 0xC0)
                        for (auto &e : list->arr) {
                            NodeP pn = e->get("PosName"), mp = e->get("Map"), tr = e->get("Translate"), rt = e->get("Rotate");
                            if (!pn || pn->str != "StartPoint_Start" || !mp || !tr || tr->type != 0xC1) continue;
                            sx = getfloat(tr->get("X")), sy = getfloat(tr->get("Y")), sz = getfloat(tr->get("Z"));
                            if (rt && rt->type == 0xC1) srot = getfloat(rt->get("Y"));
                            start_sec = mp->str;
                            start_found = sx > -1700 && sx < -100 && sz > 1200 && sz < 2800 && start_sec.size() == 3;
                        }
                } catch (const Fail &) {}
            }
        }
        const float cx = start_found ? sx : -900, cz = start_found ? sz : 1950;
        std::string best_path;
        bool best_in_dlc = false;
        Bytes best_was;
        NodeP best_root, best_obj;
        uint16_t best_ver = 2;
        float best_d = 1e9f;
        bool best_chest = false;
        for (int unit = 0; unit < 12; unit++) {
            static const char *const secs[] = {"D-6", "D-7", "E-6", "E-7", "D-5", "E-5"};
            const char *sec = secs[unit / 2];
            bool in_dlc;
            std::string p = find_unit(std::string("Map/MainField/") + sec + "/" + sec + (unit & 1 ? "_Dynamic.smubin" : "_Static.smubin"), &in_dlc);
            if (p.empty()) continue;
            uint16_t ver;
            Bytes was = yaz0_decode(in_dlc ? dlc.read(p) : rom.read(p));
            NodeP r = byml_read(was, &ver);
            NodeP objs = r->get("Objs");
            if (!objs || objs->type != 0xC0) continue;
            for (auto &o : objs->arr) {
                NodeP name = o->get("UnitConfigName"), tr = o->get("Translate");
                if (!name || !tr || tr->type != 0xC0 || tr->arr.size() < 3) continue;
                bool chest = name->str.rfind("TBox_Field", 0) == 0, weapon = name->str.rfind("Weapon_Sword_", 0) == 0;
                if (!chest && !weapon) continue;
                float x = getfloat(tr->arr[0]), z = getfloat(tr->arr[2]);
                NodeP prm = o->get("!Parameters"), buried = prm && prm->type == 0xC1 ? prm->get("IsInGround") : NULL;
                // (a chest first; one on the ground before a buried one - dug up with Magnesis - though the copy is
                // put on the ground either way)
                float d = hypotf(x - cx, z - cz) + (chest ? 0 : 2000) + (buried && buried->num ? 500 : 0);
                if (x < -1700 || x > -100 || z < 1200 || z > 2800) continue;
                if (d < best_d)
                    best_d = d, best_path = p, best_root = r, best_obj = o, best_ver = ver, best_chest = chest, best_in_dlc = in_dlc,
                    best_was = was;
            }
        }
        if (!best_obj) fail("no chest or weapon found on the Great Plateau to copy");
        NodeP add = clone(best_obj);
        NodeP tr = add->get("Translate");
        float x, y, z;
        bool at_start = start_found && best_chest;
        if (at_start) {   // (2.5 m in front of where he appears: Rotate Y in degrees, he faces (sin, cos))
            const float k = 3.14159265f / 180.0f;
            x = sx + sinf(srot * k) * 2.5f, y = sy, z = sz + cosf(srot * k) * 2.5f;
            // the chest goes in that spot's own map unit (units load by area), of the kind the copied chest was in
            bool in_dlc;
            bool dynamic = best_path.find("_Dynamic") != std::string::npos;
            std::string p = find_unit("Map/MainField/" + start_sec + "/" + start_sec + (dynamic ? "_Dynamic.smubin" : "_Static.smubin"), &in_dlc);
            if (p.empty()) at_start = false;
            else if (p != best_path) {
                uint16_t ver;
                best_was = yaz0_decode(in_dlc ? dlc.read(p) : rom.read(p));
                best_root = byml_read(best_was, &ver);
                best_ver = ver, best_path = p, best_in_dlc = in_dlc;
                if (!best_root->get("Objs") || best_root->get("Objs")->type != 0xC0) at_start = false;
            }
        }
        if (!at_start) {
            x = getfloat(tr->arr[0]) + 2.5f, y = getfloat(tr->arr[1]) + (best_chest ? 0.0f : 0.5f), z = getfloat(tr->arr[2]);
            if (start_found && best_chest) fail("the map where the game starts couldn't be read");   // (no half-placed chest)
        }
        tr->arr[0] = mkfloat(x), tr->arr[1] = mkfloat(y), tr->arr[2] = mkfloat(z);
        if (at_start)   // (upright - the copied chest may sit tilted on a slope - turned back toward where Link appears;
                        // a map object's Rotate: one angle about Y, in radians)
            add->set("Rotate", mkfloat((srot + 180.0f) * 3.14159265f / 180.0f));
        add->set("HashId", mkuint(0x7A5E0003u));   // (its own: the game remembers an opened chest by it)
        if (add->get("SRTHash")) add->set("SRTHash", mkint(0x2A5E0003));
        add->hash.erase(std::remove_if(add->hash.begin(), add->hash.end(),
                                       [](const auto &e) { return e.first == "LinksToObj" || e.first == "LinksToRail"; }),
                        add->hash.end());
        if (best_chest) {
            NodeP params = add->get("!Parameters");
            if (!params || params->type != 0xC1) { params = std::make_shared<Node>(); params->type = 0xC1; add->set("!Parameters", params); }
            params->set("DropActor", mkstr("Weapon_Sword_L01"));
            // on the ground, not buried (IsInGround: dug up with Magnesis), and there in every mode (not only Master Mode)
            NodeP no = std::make_shared<Node>();
            no->type = 0xD0, no->num = 0;
            params->set("IsInGround", no);
            params->set("IsHardModeActor", clone(no));
        } else add->set("UnitConfigName", mkstr("Weapon_Sword_L01"));
        NodeP objs = best_root->get("Objs");
        for (auto &o : objs->arr) if (o->get("HashId") && (uint32_t)o->get("HashId")->num == 0x7A5E0003u) fail("the map already has its id");
        objs->arr.push_back(add);
        Bytes made = byml_write(best_root, best_ver);
        (best_in_dlc ? dlc_files : files)[best_path] = yaz0_encode(made);
        if (best_in_dlc) {   // (with the DLC, the game reads the map from its Pack/AocMainField.pack: an empty one makes it
                             // read the DLC's loose map files - this one among them - as mods for the DLC do)
            for (auto &e : dlc.index)
                if (e.first.size() >= 22 && !e.first.compare(e.first.size() - 22, 22, "Pack/AocMainField.pack")) dlc_files[e.first] = Bytes();
        }
        // (the size table names the DLC's files Aoc/0010/...)
        std::string rn = rstb_name(best_path);
        if (best_in_dlc) rn = rn.compare(0, 5, "0010/") ? "Aoc/0010/" + rn : "Aoc/" + rn;
        sizes.push_back({rn, rn, grew(made, best_was)});
        char w[240];
        if (at_start)
            snprintf(w, sizeof w, "In a new chest inside the Shrine of Resurrection, in the chamber where Link wakes - travel "
                                  "there and it's just in front of you (map x %.0f, z %.0f)", x, z);
        else
            snprintf(w, sizeof w, "%s on the Great Plateau (map x %.0f, z %.0f)", best_chest ? "In a new chest beside a chest" : "Beside a weapon lying",
                     x, z);
        g_where = w;
    }

    // 5. the resource size table: room for each file made
    status("Updating the size table...");
    {
        const std::string path = "System/Resource/ResourceSizeTable.product.srsizetable";
        int set = 0;
        Bytes t = rstb_update(yaz0_decode(rom.read(path)), sizes, &set);
        files[path] = yaz0_encode(t);
    }

    // 6. the mod, written whole (an older one replaced)
    status("Writing the mod...");
    remove_tree(root + "/mods/" + kMod);
    remove_tree(root + "/mods/" + kModDlc);
    for (auto &f : files) write_file(out + f.first, f.second);
    for (auto &f : dlc_files) write_file(root + "/mods/" + kModDlc + "/romfs/" + f.first, f.second);
    FILE *n = fopen((root + "/mods/" + kMod + "/about.txt").c_str(), "w");
    if (n) {
        fprintf(n, "The WSword (experimental): a sword of white light that runs out with use and comes back after a "
                   "rest, as the Master Sword does. %s. %s Made on this device from your own game files.\n\nWith the sword "
                   "in your inventory, a save needs this mod on to load: keep it on, or load the backup in "
                   "save_backup_sword_of_light.\n", g_where.c_str(),
                g_look_note.empty() ? "White, glowing white." : ("The Master Sword's look: " + g_look_note + ".").c_str());
        fclose(n);
    }
}

static void *run(void *) {
    try {
        char root_c[1024];
        if (rt_version_root(rt_game_version(), root_c, sizeof root_c)) {
            std::string root = root_c, backup = root + "/save_backup_sword_of_light";
            struct stat st;
            if (stat(backup.c_str(), &st) != 0) { status("Backing up your saves..."); copy_tree(root + "/save", backup); }
        }
        make_mod();
        status("Ready: " + g_where + "." + (g_look_note.empty() ? std::string() : " (The Master Sword's look: " + g_look_note + ".)") +
               (g_shirt ? std::string(" The Nintendo Switch Shirt is the WSword shirt") +
                              (g_shirt_icon ? ", its inventory picture too." : " (its inventory picture as it was).")
                        : " (No WSword shirt: " + g_shirt_note + ".)") +
               " It applies when the game starts again.");
    } catch (const Fail &f) {
        status("Couldn't make it: " + f.why + ". Nothing was changed.");
    } catch (...) {
        status("Couldn't make it (an error). Nothing was changed.");
    }
    g_busy = false;
    return NULL;
}

static bool mod_present(void) {
    char root_c[1024];
    if (!rt_version_root(rt_game_version(), root_c, sizeof root_c)) return false;
    struct stat st;
    return stat((std::string(root_c) + "/mods/" + kMod + "/romfs").c_str(), &st) == 0;
}
#else   // LS_SHIRT_ONLY
// ------------------------------------------------------------------ (the PS5) the WSword shirt alone
static const char *const kShirtMod = "WSword Shirt";
// (the PS5's data folder - the title folder: extracted/romfs the game's files, mods/ the mods - paths.h)
static bool shirt_root(char *out, size_t n) {
    const char *r = rt_data_root();
    return r && *r && (size_t)snprintf(out, n, "%s", r) < n;
}
static void make_shirt_mod(void) {
    char root_c[1024];
    if (!shirt_root(root_c, sizeof root_c)) fail("no game version set up");
    std::string root = root_c, out = root + "/mods/" + kShirtMod + "/romfs/";
    Rom rom;
    if (!rom.open(root)) fail("the game files aren't set up");
    std::map<std::string, Bytes> files;
    std::vector<RstbWant> sizes;
    auto grew = [](const Bytes &now, const Bytes &was) { return was.empty() ? 1.0 : (double)now.size() / (double)was.size(); };
    g_shirt = false, g_shirt_icon = false;

    // 1. its pictures: the shirt's colour picture (look_shirt) and its inventory picture (look_shirt_icon)
    status("Making the WSword shirt...");
    char ep[1100] = "";
    {   // (the title folder's assets/, where ps5/assets.json puts it: the executable's folder, else /app0)
        struct stat st;
        for (std::string c : {std::string(rt_exe_dir()) + "/assets/wsword-emblem.png", std::string("/app0/assets/wsword-emblem.png")})
            if (!ep[0] && stat(c.c_str(), &st) == 0) snprintf(ep, sizeof ep, "%s", c.c_str());
        if (!ep[0] && !rt_resource("assets/wsword-emblem.png", "assets/artwork/wsword-emblem.png", ep, sizeof ep))
            fail("the WSword emblem isn't in the title folder (assets/wsword-emblem.png)");
    }
    int ew, eh, en;
    unsigned char *e = stbi_load(ep, &ew, &eh, &en, 4);
    if (!e) fail("the WSword emblem can't be read");
    std::vector<uint8_t> emb(e, e + (size_t)ew * eh * 4);
    stbi_image_free(e);
    const std::string tp = "Model/Armor_170.Tex.sbfres";
    if (!rom.has(tp)) fail("the game has no Nintendo Switch Shirt");
    try {
        Bytes t = yaz0_decode(rom.read(tp));
        look_shirt(t, emb, ew, eh);
        files[tp] = yaz0_encode(t);   // (the same size decompressed: its size table entry holds)
    } catch (const LookFail &) {
        fail("the shirt's picture isn't as expected");
    }
    g_shirt = true;
    const std::string ip = "UI/StockItem/Armor_170_Upper.sbitemico";
    if (rom.has(ip)) {
        try {
            Bytes pic = yaz0_decode(rom.read(ip));
            Rgba nv = emblem_navy(emb, ew, eh);
            look_shirt_icon(pic, emb, ew, eh, nv.r / 255, nv.g / 255, nv.b / 255);
            files[ip] = yaz0_encode(pic);   // (the same size: its size table entry holds)
            g_shirt_icon = true;
        } catch (const LookFail &) {
        }
    }

    // 2. its name and description, in every language the game has
    status("Naming it...");
    for (const std::string &pk : rom.list("Pack/")) {
        if (pk.find("Pack/Bootup_") != 0 || pk.size() < 17 || pk.compare(pk.size() - 5, 5, ".pack")) continue;
        std::string lang = pk.substr(12, pk.size() - 12 - 5);   // ("USen", "EUfr"...)
        if (lang.size() != 4) continue;
        Sarc boot = sarc_read(rom.read(pk));
        std::string inner = "Message/Msg_" + lang + ".product.ssarc";
        Bytes *msg = boot.get(inner);
        if (!msg) continue;
        Bytes ms_was = yaz0_decode(*msg);
        Sarc ms = sarc_read(ms_was);
        bool done = false;
        for (auto &f : ms.files) {
            if (f.first.find(".msbt") == std::string::npos) continue;
            Msbt m = msbt_read(f.second);
            bool shirt = false;
            for (auto &l : m.labels) if (!l.compare(0, 16, "Armor_170_Upper_")) shirt = true;
            if (!shirt) continue;
            for (size_t i = 0; i < m.labels.size(); i++) {
                if (m.labels[i] == "Armor_170_Upper_Name") m.texts[m.idx[i]] = u16("WSword Shirt");
                else if (m.labels[i] == "Armor_170_Upper_Desc" || m.labels[i] == "Armor_170_Upper_PictureBook")
                    m.texts[m.idx[i]] = u16("A shirt bearing the WSword's emblem:\n"
                                            "the sword of light, wrapped in\n"
                                            "blooming flowers under a starry sky.\n"
                                            "Wear it with pride!");
            }
            f.second = msbt_write(m);
            done = true;
        }
        if (!done) continue;
        Bytes ms_made = sarc_write(ms, 0x80);
        *msg = yaz0_encode(ms_made);
        files[pk] = sarc_write(boot, 0x2000);
        sizes.push_back({rstb_name(inner), rstb_name(inner), grew(ms_made, ms_was)});
    }

    // 3. the resource size table: room for the messages made
    status("Updating the size table...");
    {
        const std::string path = "System/Resource/ResourceSizeTable.product.srsizetable";
        int set = 0;
        Bytes t = rstb_update(yaz0_decode(rom.read(path)), sizes, &set);
        files[path] = yaz0_encode(t);
    }

    // 4. the mod, written whole (an older one replaced)
    status("Writing the mod...");
    remove_tree(root + "/mods/" + kShirtMod);
    for (auto &f : files) write_file(out + f.first, f.second);
    if (FILE *n = fopen((root + "/mods/" + kShirtMod + "/about.txt").c_str(), "w")) {
        fprintf(n, "The WSword Shirt: the Nintendo Switch Shirt with the WSword's emblem, navy, its name and description "
                   "too. Made on this console from your own game files. Nothing in your saves depends on it: turn it "
                   "off and the shirt is the Switch's again.\n");
        fclose(n);
    }
}
static void *run(void *) {
    try {
        make_shirt_mod();
        status(std::string("Ready: the Nintendo Switch Shirt is the WSword shirt") +
               (g_shirt_icon ? ", its inventory picture too." : " (its inventory picture as it was).") +
               " It applies when the game starts again.");
    } catch (const Fail &f) {
        status("Couldn't make it: " + f.why + ". Nothing was changed.");
    } catch (...) {
        status("Couldn't make it (an error). Nothing was changed.");
    }
    g_busy = false;
    return NULL;
}
static bool mod_present(void) {
    char root_c[1024];
    if (!shirt_root(root_c, sizeof root_c)) return false;
    struct stat st;
    return stat((std::string(root_c) + "/mods/" + kShirtMod + "/romfs").c_str(), &st) == 0;
}
#endif  // LS_SHIRT_ONLY
}  // namespace ls

// The Mods page's rows (ui/mods_tab.mm)
#ifdef LS_SHIRT_ONLY
void light_sword_rows(void) {   // (the PS5: the WSword shirt)
    using namespace ls;
    opt_section("WSword");
    bool have = mod_present(), busy = g_busy;
    bool on = have;
    if (busy) opt_disable_next();
    if (opt_toggle("WSword Shirt", &on, false,
                   "The Nintendo Switch Shirt becomes the WSword shirt: navy, with the WSword's emblem over the Switch "
                   "logo - on Link and in the inventory - and named WSword Shirt. Turned on, WSword makes it as a mod from "
                   "your own game files on the console (under a minute). Nothing in your saves depends on it. Applies "
                   "when the game starts again.") &&
        !busy) {
        if (on) {
            g_busy = true;
            pthread_t t;
            if (pthread_create(&t, NULL, run, NULL) == 0) pthread_detach(t);
            else g_busy = false;
        } else {
            char root_c[1024];
            if (shirt_root(root_c, sizeof root_c)) remove_tree(std::string(root_c) + "/mods/" + kShirtMod);
            status("Turned off: the shirt is the Switch's again from the game's next start.");
        }
    }
    std::string s;
    { std::lock_guard<std::mutex> l(g_mu); s = g_status; }
    if (!s.empty()) {
        ImGui::PushTextWrapPos(0);
        ImGui::TextDisabled("%s", s.c_str());
        ImGui::PopTextWrapPos();
    }
}
#else
void light_sword_rows(void) {
    using namespace ls;
    opt_section("WSword: Sword of Light (experimental)");
    bool have = mod_present(), busy = g_busy;
    bool on = have;
    if (busy) opt_disable_next();
    if (opt_toggle("Sword of Light", &on, false,
                   "A sword infused with light, made like the Master Sword: strong, its light runs out with use, it rests, and "
                   "the light comes back after a while. It lies on the Great Plateau, in a new chest beside one that's there. "
                   "Turned on, WSword makes it as a mod from your own game files on this device (a minute or so) and first "
                   "copies your saves to save_backup_sword_of_light. Experimental: made without the game to test against - "
                   "if the game misbehaves, turn it off. A save with the sword in its inventory needs it on to load (or use "
                   "the backup). Applies when the game starts again.") &&
        !busy) {
        if (on) {
            g_busy = true;
            pthread_t t;
            if (pthread_create(&t, NULL, run, NULL) == 0) pthread_detach(t);
            else g_busy = false;
        } else {
            char root_c[1024];
            if (shirt_root(root_c, sizeof root_c))
                remove_tree(std::string(root_c) + "/mods/" + kMod), remove_tree(std::string(root_c) + "/mods/" + kModDlc);
            status("Turned off: the mod is gone. Your save backup stays in save_backup_sword_of_light.");
        }
    }
    std::string s;
    { std::lock_guard<std::mutex> l(g_mu); s = g_status; }
    if (!s.empty()) {
        ImGui::PushTextWrapPos(0);
        ImGui::TextDisabled("%s", s.c_str());
        ImGui::PopTextWrapPos();
    }
}

#endif  // !LS_SHIRT_ONLY (the sword's rows)

#ifndef LS_SHIRT_ONLY
// (tests: a desktop build runs the steps on a folder - LARECOMP_SWORD_TEST)
extern "C" int light_sword_selftest(void) {
    using namespace ls;
    try {
        // Yaz0 both ways
        Bytes raw;
        for (int i = 0; i < 1000; i++) raw.push_back((uint8_t)(i * 7));
        if (yaz0_decode(yaz0_encode(raw)) != raw) return 1;
        // SARC both ways
        Sarc s;
        s.files.push_back({"Actor/A.bxml", Bytes{1, 2, 3}});
        s.files.push_back({"Actor/B.bgparamlist", Bytes{4, 5}});
        Sarc t = sarc_read(sarc_write(s, 0x80));
        if (t.files.size() != 2 || !t.get("Actor/A.bxml") || *t.get("Actor/B.bgparamlist") != Bytes({4, 5})) return 2;
        // BYML both ways
        NodeP r = std::make_shared<Node>();
        r->type = 0xC1;
        NodeP arr = std::make_shared<Node>();
        arr->type = 0xC0;
        arr->arr.push_back(mkuint(0xF0000000u)), arr->arr.push_back(mkint(5)), arr->arr.push_back(mkfloat(1.5f));
        r->set("Hashes", arr), r->set("name", mkstr("Weapon_Sword_L01"));
        uint16_t v;
        NodeP q = byml_read(byml_write(r, 2), &v);
        if (!q->get("Hashes") || q->get("Hashes")->arr.size() != 3 || q->get("Hashes")->arr[0]->num != 0xF0000000u ||
            getfloat(q->get("Hashes")->arr[2]) != 1.5f || q->get("name")->str != "Weapon_Sword_L01")
            return 3;
        // MSBT both ways
        Msbt m;
        m.order = {"LBL1", "ATR1", "TXT2"};
        m.labels = {"Weapon_Sword_070_Name"};
        m.idx = {0};
        m.texts = {u16("Master Sword")};
        m.atr_size = 4;
        m.atr_entries = {1, 2, 3, 4};
        Msbt n2 = msbt_read(msbt_write(m));
        if (n2.labels.size() != 1 || n2.texts[0] != u16("Master Sword") || n2.atr_entries != Bytes({1, 2, 3, 4})) return 4;
    } catch (const Fail &f) {
        fprintf(stderr, "selftest: %s\n", f.why.c_str());
        return 9;
    }
    return 0;
}
#endif  // !LS_SHIRT_ONLY (the selftest)
